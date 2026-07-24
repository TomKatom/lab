# Runbook: provisioning a new server from scratch

How to take a clean Proxmox install and end with this repo fully deployed:
firewalled single-IP host, WireGuard-only management, self-hosted CI
runner, k3s, and Argo CD reconciling `clusters/` from git. Also covers the
**rebuild** case (same repo, replacement or wiped server) — see the
[appendix](#appendix-rebuilding-a-replacement-server), whose extra steps
are marked `[rebuild]` inline throughout.

This is the ordering document. The two dangerous applies keep their own
runbooks and are only referenced here:
[`tofu-apply.md`](tofu-apply.md) (first, firewall-enabling apply) and
[`restrict-management-flip.md`](restrict-management-flip.md) (dropping
public management). [`lockout-recovery.md`](lockout-recovery.md) is the
escape hatch if either goes wrong. There is no IPMI/console on this
server; every step below is written around that.

---

## 0. Why there are stages at all

Almost everything is code, but the code cannot apply itself in one shot.
Four cycles force an ordering, and each stage below exists to break one:

1. **The CI runner lives on the server it provisions.** Every post-lockdown
   apply runs on the `ci-runner` VM — which Tofu creates and Ansible
   registers. Until it exists, applies run on GitHub-hosted `ubuntu-latest`
   over the host's still-public SSH/API (`LAB_RUNNER` unset), which is why
   the runner inventory group deliberately jumps via the host's *public* IP
   (see `ansible/inventory/hosts.yml`) and why `restrict_management` must
   stay `false` until Stage D.
2. **Tofu's credential is created by Ansible.** The `bpg` provider
   authenticates with a PVE API token whose role/user are provisioned by
   `ansible/roles/pve_permissions` (over root SSH — no API needed). So the
   host converge runs before the first `tofu apply` can.
3. **The guest-agent grant needs running guests.** `VM.GuestAgent.Audit`
   is only granted once every running VM answers a qemu-guest-agent ping
   (granting earlier makes `tofu plan` wait on dead agent sockets), and
   the agent is installed by `hardening-vms.yml` — which needs the VMs
   Tofu created with the token from cycle 2. A later converge pass picks
   the grant up automatically.
4. **Management lockdown needs a proven tunnel.** WireGuard is verified
   end-to-end from the operator's own peer before `restrict_management`
   drops public SSH — the anti-lockout gate. The first firewall-enabling
   apply and the flip are the two applies that stay manual/supervised by
   policy.

| Stage | What | Runs where | Operator does |
|---|---|---|---|
| [1](#1-prerequisites-off-server) | Secrets, GitHub setup, Proxmox install | laptop / consoles | one-time setup |
| [2](#2-server-identity-checklist) | Per-server values into the repo | PR | edit + merge |
| [A](#3-stage-a--host-base-config) | Host converge + PVE role/user + token | CI `ubuntu-latest`, public SSH | approve; run one script |
| [B](#4-stage-b--first-tofu-apply) | vmbr1, VMs, firewall (open), image | **laptop, dead-man switch** | manual apply |
| [C](#5-stage-c--guests-and-the-runner) | VM hardening, runner, virtiofs, k3s | CI `ubuntu-latest`, public jump | approve; set `LAB_RUNNER` |
| [D](#6-stage-d--wireguard-verify-and-the-flip) | WG peer, verify, `restrict_management` | laptop + gated CI | verify; approve flip |
| [E](#7-stage-e--argo-cd-bootstrap) | Argo CD + root-app | gated CI dispatch | approve |

After Stage E the repo is in [steady state](#8-steady-state--what-runs-when):
merging is deploying, and the only recurring operator action is approving
gated runs.

---

## 1. Prerequisites (off-server)

### 1.1 Durable secrets and identities (survive any server)

All of these live in the password manager and are reused across servers —
generate once, restore forever (see [`docs/secrets.md`](../secrets.md) and
[`docs/ssh-keys.md`](../ssh-keys.md)):

- **age keypair** — private key at `~/.config/sops/age/keys.txt` locally;
  public key is `.sops.yaml`'s recipient. Everything SOPS-encrypted in the
  repo depends on it.
- **Personal admin SSH key** (agent/password-manager-backed) and the
  **`ci-tofu-apply` automation SSH keypair** — public halves of both listed
  in `config/lab.yml` `admin_ssh_public_keys`.
- **Cloudflare API token** (`Zone:DNS:Edit` + `Zone:Read` on the zone) and
  the **zone ID**. Only exercised against the zone once `manage_dns`
  flips at cutover, but Tofu requires the variables populated from day one.
- **`GH_RUNNER_PAT`** — fine-grained PAT with repo **Administration**
  permission (mints runner registration tokens; also read by the
  `tofu-apply.yml` flip guard to list runners). Note its expiry.
- **`STATE_PASSPHRASE`** (in `infra/tofu/state.sops.env`) — the Tofu
  state-encryption passphrase.

Operator laptop toolchain for the manual steps: `tofu`, `sops`, `age`,
`ansible-core` + collections (`ansible-galaxy collection install -r
ansible/requirements.yml -p ~/.ansible/collections`), `wireguard-tools`,
`gh`. See `ansible/README.md` and `infra/tofu/README.md`.

### 1.2 GitHub repo state (order matters)

> **Do this in the order written.** Referencing a GitHub Environment from a
> workflow auto-creates it *with no protection rules* — if the repository
> secrets exist while `production` has no required reviewer, the very first
> PR's apply job runs **unattended**. Reviewer first, secrets second.

1. Private repo, `master` protected, **squash-merge only**, and the squash
   commit message setting = **pull request title**. (The message setting is
   load-bearing: a default that inlines the PR's commit list would inherit
   `tofu-apply.yml`'s `[skip ci]` state commits on mixed PRs and silently
   skip the post-merge ansible converge.)
2. **Settings → Environments**: create `production`, add yourself as
   **required reviewer**.
3. **Repository secrets**: `SOPS_AGE_KEY` (full contents of
   `~/.config/sops/age/keys.txt`), `PROXMOX_SSH_PRIVATE_KEY` (the
   automation key's private half), `GH_RUNNER_PAT`. Delete any stale
   `PROXMOX_API_TOKEN` / `CLOUDFLARE_API_TOKEN` / `STATE_PASSPHRASE` —
   retired, nothing reads them.
4. **`LAB_RUNNER` repository variable: must be unset** (or absent) so
   apply jobs fall back to `ubuntu-latest` during bootstrap.
   `[rebuild]` **This is the very first step of any rebuild** — with it
   still set, every CI job queues forever against the dead runner. Also
   cancel any queued runs it stranded.
5. Renovate app installed on the repo.
6. (Stage E prerequisite, can wait) Read-only **deploy key** for Argo —
   see [`docs/bootstrap.md`](../bootstrap.md#the-one-manual-github-step-the-argo-deploy-key).

### 1.3 Proxmox install (the one truly out-of-band step)

Via the OVH installer/rescue console:

- Proxmox VE, **`rpool` ZFS mirror on the 2×500 GB NVMe** as root; the
  2×2 TB HDDs untouched (Stage A builds `tank` on them).
- Seed `/root/.ssh/authorized_keys` with **both** the personal admin key
  and the `ci-tofu-apply` automation public key (installer SSH-key field,
  or by hand right after first login). CI's very first contact
  authenticates with the automation key — nothing in the repo can install
  the key it logs in with.
- Note: **public IP**, **node name** (`hostname`), and datastore names
  (`pvesm status` — typically `local` + `local-zfs`).

---

## 2. Server identity checklist

Every per-server literal in the repo, in one PR (call it the *identity
PR*). Hand-synced duplicates are deliberate (inventory parses before
vars load) — update **all** of them:

| File | Field(s) |
|---|---|
| `infra/tofu/terraform.tfvars` | `ovh_public_ip`, `proxmox_endpoint`, `node_name`, `cloudflare_zone_id`, `system_storage_pool` / `data_storage_pool` / `image_datastore`, `debian_image_checksum` |
| `infra/tofu/terraform.tfvars` | **`restrict_management = false`** (flips back in Stage D) and `manage_dns = false` until cutover |
| `ansible/inventory/hosts.yml` | `server.ansible_host` (public IP) |
| `ansible/inventory/group_vars/all.yml` | `ovh_public_ip` |
| `ansible/inventory/host_vars/server.yml` | `zfs_tank_pool_disks` by-id paths — from `report-disks`, see Stage A |
| `config/lab.yml` | `admin_ssh_public_keys` **complete** (personal + automation) |
| `infra/tofu/secrets.sops.tfvars.json` | `cloudflare_api_token` (`sops` edit); `proxmox_api_token` stays placeholder until Stage A mints it |

Notes:

- **`debian_image_checksum` goes stale**: the URL tracks Debian's `latest`
  image, which is republished regularly. Fetch the current value from the
  matching `SHA512SUMS` before every fresh provision.
- **`admin_ssh_public_keys` must be complete *before* the first converge.**
  The hardening role reconciles `authorized_keys` *exclusively* — a key
  missing from the list is pruned from the host, including the very key CI
  logs in with. And cloud-init only seeds VM keys at first boot, so a key
  added after Stage B needs a hardening re-run to reach the VMs.
- **Tofu state**, brand-new vs rebuild:
  - Brand-new everything (no surviving DNS zone contents): delete
    `infra/tofu/terraform.tfstate` in the identity PR; the first plan is
    all-create.
  - `[rebuild]` Same zone still live: **do not blank the state.** Remove
    only the Proxmox-scoped resources and keep the `cloudflare_dns_record`
    entries, so Tofu *updates* the surviving records to the new IP instead
    of colliding with them:

    ```sh
    cd infra/tofu
    ./tofu.sh state list | grep -v '^cloudflare_' \
      | while read -r r; do ./tofu.sh state rm "$r"; done
    ```

    Commit the surgically-edited state in the identity PR.

Expect the identity PR's `tofu plan` check to be red until Stage A mints
the API token (and, `[rebuild]`, while the old endpoint is dead) — the
`ci.yml` lint checks are what gate the merge; don't approve any waiting
`tofu apply` yet.

---

## 3. Stage A — host base config

Everything here runs over the host's still-public SSH, on GitHub-hosted
runners, with the `production` approval as the gate.

1. **Discover the tank disks** (new hardware only): push the identity
   branch, then dispatch `ansible-apply.yml` → playbook `report-disks`,
   **"Use workflow from" = the identity branch** (so it targets the new
   IP), approve. Copy the two 2 TB by-id paths from the job summary into
   `zfs_tank_pool_disks` on the same branch. This must land **in** the
   identity PR: the host converge fails at `zfs_tank`'s assert without
   real paths, and `pve_permissions` (which runs after it) would never
   create the Tofu credential.
2. **Merge the identity PR.** The push to `master` triggers the gated
   auto-converge (`site.yml`); approve it. The guest groups are
   unreachable (no VMs yet) so the reachability probe limits the run to
   the host: apt repos → firewall backend → WireGuard (zero peers is
   fine) → NAT → hardening → `tank` → PVE permissions. The run log will
   say the **API token is missing** and that the **guest-agent grant is
   deferred** — both expected here.
3. **Mint the Tofu API token** (one command, operator laptop):

   ```sh
   ./scripts/mint-pve-token.sh root@<public-ip>
   ```

   It creates `terraform@pve!tofu` (role/user already exist from step 2)
   and re-encrypts the token into `secrets.sops.tfvars.json`. Commit on a
   branch, open a PR — the PR's green `tofu plan` is the proof the token
   authenticates. Merge (cancel the run's waiting `apply`; the first apply
   is Stage B, manual).

---

## 4. Stage B — first Tofu apply

The first apply enables the Proxmox firewall on a console-less box —
**manual, supervised, dead-man switch armed**, per
[`tofu-apply.md`](tofu-apply.md) §2–4. In short: `./tofu.sh init && plan`
locally (scoped agent with the automation key, see
[`docs/ssh-keys.md`](../ssh-keys.md)), review — expect vmbr1, image
download, both VMs, cluster/node firewall + `mgmt` ipset with
**unrestricted** management sources, DNS only if `manage_dns=true` — arm
the switch, apply, verify no lockout, cancel the switch, commit the
updated `terraform.tfstate` via PR.

Quirks to expect on a fresh box:

- Two ~15 s waits per plan/apply while the VMs' guest agents don't exist
  yet (bounded by the `agent { timeout = "15s" }` blocks) — noise, not a
  hang. The real agent hang this repo once hit can only occur *after* the
  guest-agent grant, which Stage C's converge withholds until agents
  respond.
- A checksum failure on the Debian image download means `SHA512SUMS`
  moved again — refresh `debian_image_checksum`, re-plan.

---

## 5. Stage C — guests and the runner

1. **Dispatch `ansible-apply.yml` → playbook `site`** (branch `master`),
   approve. The probe now reaches both VMs, so the full converge runs:
   guest hardening (installs qemu-guest-agent; cloud-init already seeded
   all keys — no manual key-enrollment run is ever needed on a fresh
   build), runner registration (uses `GH_RUNNER_PAT`), virtiofs mount,
   k3s install.
2. **Route CI onto the runner** once it shows Idle:

   ```sh
   gh api repos/:owner/:repo/actions/runners \
     --jq '.runners[] | {name,status,labels:[.labels[].name]}'   # expect: online
   gh variable set LAB_RUNNER --body lab
   ```

   Harmless while management is still public — and mandatory before the
   flip (the `tofu-apply.yml` flip guard hard-fails a flip PR without it).
3. **Dispatch `site` once more**, approve. This second pass runs on the
   self-hosted runner (proving its NAT egress + hairpin path works) and
   `pve_permissions` now finds every running guest answering agent pings —
   the log should show the `VM.GuestAgent.Audit` grant landing. From here
   the converge is fully idempotent at every future merge.

---

## 6. Stage D — WireGuard verify and the flip

1. Generate a WG keypair + preshared key locally; PR your peer's public key
   and its own `/32` `address` into `wireguard_peers`
   (`ansible/inventory/group_vars/all.yml`) and the PSK into
   `wireguard_peer_psks`
   (`ansible/inventory/group_vars/proxmox_host.sops.yml`); merge; approve
   the converge (re-renders `wg0` with your peer). Grab the host's WG public
   key from the converge output. Full peer procedure:
   [`wireguard-peer.md`](wireguard-peer.md).
2. Bring the tunnel up locally (endpoint `<public-ip>:51820`) and run the
   anti-lockout gate **from your laptop** (it proves *your* tunnel, which
   CI structurally cannot):

   ```sh
   cd ansible && ./run.sh playbooks/verify-wireguard.yml
   ```

   All four checks must pass. `[rebuild]` The host's WG private key was
   generated in-place on the old server and died with it — your laptop
   peer config needs the *new* host public key before this passes.
3. Open the flip PR (`restrict_management = true`) and execute
   [`restrict-management-flip.md`](restrict-management-flip.md) — dead-man
   switch, runner-placement verification, off-tunnel negative checks. The
   workflow's flip guard machine-checks `LAB_RUNNER` + runner liveness,
   but the runbook's human steps are not optional.

Management is now WireGuard-only; every subsequent CI job runs on the
internal runner.

---

## 7. Stage E — Argo CD bootstrap

**Prerequisite (one-time, GitHub side):** the read-only **deploy key**'s
public half must be added to the repo (Settings → Deploy keys, write access
unchecked) before dispatching — the `argocd_secrets` role injects its
private half as the in-cluster Argo repository credential. See §1.2.6 /
`docs/bootstrap.md`.

**Run it exactly once**, at the end of provisioning: dispatch
`ansible-apply.yml` → **`argocd-bootstrap`** → approve. In one gated run it
creates the two trust-root secrets in-cluster (`sops-age-key`, the Argo
repository credential), helm-installs Argo CD with the ksops repo-server
patch, and applies `root-app.yaml`. `root-app` then reconciles
`clusters/lab/platform/`, which includes the self-manage `Application`
(`argo-cd.yaml`) — from that point Argo owns its own release and `clusters/`
deploys by merge.

**Why this is a one-time dispatch and *not* part of `site.yml`.** Once the
self-manage Application is reconciling, the bootstrap's `helm upgrade
--install` + `kubectl apply root-app.yaml` would **fight Argo for ownership
of the same release** if replayed on every converge. So `argocd-bootstrap`
is deliberately excluded from the steady-state `site.yml` auto-converge
(its header documents this) and lives only as an operator-picked
`workflow_dispatch`. You do **not** re-run it as maintenance.

**Re-dispatch is safe only for a failed/partial bootstrap.** The role is
built on the existence-check idiom (read state → act only if needed →
read-back assert), so re-dispatching to finish an interrupted first run is
idempotent and safe. That is the *only* reason to run it a second time — not
to reconcile drift (Argo does that) and not to bump the chart (a Renovate PR
to `argocd_chart_version` + `argo-cd.yaml`'s `targetRevision` rolls out via
Argo's self-managed sync, never via this dispatch).

> [`docs/bootstrap.md`](../bootstrap.md) owns the full step-by-step for this
> stage — deploy-key upload, the dispatch, verification (`argocd app list`
> Synced/Healthy + the ksops smoke test), and re-dispatch/upgrade caveats.
> This section stays the authoritative pointer into it; the
> `argocd`/`argocd_secrets` roles already fail loudly at a missing-trust-root
> assert rather than misconfigure.

---

## 8. Steady state — what runs when

The operator approves; the pipelines decide what runs.

| You merge a change to… | What deploys it | Your actions |
|---|---|---|
| `infra/tofu/**` | `tofu-apply.yml`: plan on the PR → **approve** → applies pre-merge, state rides the squash-merge | review plan, approve, merge |
| `ansible/**`, `config/lab.yml` | merge triggers the gated `site.yml` auto-converge on `master` | merge, **approve** |
| `clusters/**` | Argo CD auto-sync (after Stage E) | merge |
| firewall-affecting Tofu diffs | **not CI** — manual per [`tofu-apply.md`](tofu-apply.md) §3 / the flip runbook | supervised apply |
| verification / discovery / bootstrap playbooks | `workflow_dispatch`, operator-picked | dispatch, approve |

Cross-layer ordering still exists (e.g. a new host dataset consumed by a
new Tofu virtiofs mapping): land it as two PRs in dependency order —
ansible first, tofu second — the same way this runbook stages them.

---

## 9. Verification (end of provision)

- External scan: only `443`, `32400`, `51413` (tcp+udp), `51820/udp` open;
  SSH/`8006`/`6443` refused off-tunnel, reachable over WG.
- `pve-firewall status` says `enabled/running` (a dead daemon enforces
  nothing — check it, don't assume it).
- `zpool status`: `rpool` mirror + `tank` stripe both `ONLINE`.
- Runner **Idle** in GitHub; a trivial ansible PR merge → converge runs on
  it and reports zero changes (full idempotency).
- `tofu plan` (CI, any PR): no diff.
- k3s node `Ready`; after Stage E, `argocd app list` all Synced/Healthy.
- `[rebuild]` `dig` the apex/`vpn` records → new IP (after the
  `manage_dns` cutover apply).

---

## Appendix: rebuilding a replacement server

The stages above apply unchanged; the deltas, in order:

1. **Unset `LAB_RUNNER` before anything else** (§1.2.4) and cancel
   stranded queued runs. Optionally delete the dead runner registration
   (Settings → Actions → Runners); the role re-registers under the same
   name with `--replace` either way.
2. `restrict_management` back to `false` **in the identity PR** (§2) — the
   old value is the live end-state, and replaying it onto a clean box
   creates the management rules already narrowed to a WG network that
   doesn't exist yet: a guaranteed first-apply self-strand.
3. Tofu **state surgery, not reset** (§2): keep Cloudflare records, remove
   Proxmox-scoped resources.
4. Expect red `tofu plan` checks on PRs while the old endpoint is dead —
   `ci.yml` still gates merges; the plan goes green at Stage A step 3.
5. New WG host key (§6.2) — update your laptop peer config before
   verify-wireguard.
6. Partial rebuilds (one VM recreated, host untouched): the runner VM's
   `~/.ssh/known_hosts` still pins the old host key of the rebuilt VM —
   `accept-new` then fails closed on every CI apply touching it. Clear
   that entry (a dispatch of `site` will fail loudly at exactly that
   host; fixing it is currently a manual step on the runner VM — over WG,
   as the operator).
7. Secrets that die with the server: the host WG private key (regenerated
   in place), the k3s node token / kubeconfig (regenerated), the runner
   registration (re-minted from `GH_RUNNER_PAT`). Nothing in the password
   manager changes; `proxmox_api_token` is re-minted in Stage A step 3
   (the old one died with the host).
