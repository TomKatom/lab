# Runbook: OpenTofu apply

How to run the Phase 2 provisioning layer (`infra/tofu/`) for the first
time, and how to enable the gated CI apply pipeline for every push after
that. See [`docs/architecture.md`](../architecture.md) for the design and
[`master-plan.md`](../../master-plan.md) for the frozen decision record.

There is no IPMI/console on this server — a lockout means a slow reseller
round-trip. Everything below is written around that constraint.

## Prerequisites

- `tofu` (OpenTofu ≥ 1.8), `sops`, and `age` installed locally.
- Your age private key at `~/.config/sops/age/keys.txt` (or
  `SOPS_AGE_KEY_FILE` pointed at it) — see
  [`docs/secrets.md`](../secrets.md).
- An SSH agent with a key loaded that can reach the Proxmox host as
  `root` — `bpg` performs the cloud image download and disk import over
  SSH (`ssh { agent = true }` in `providers.tf`).
- A Proxmox API token (`Sys.Audit`/`Sys.Modify`/`Datastore.AllocateTemplate`
  on the target datastore, plus VM/firewall management privileges) and a
  Cloudflare API token (`Zone:DNS:Edit` + `Zone:Read` on the `tomkatom.com`
  zone).

## 1. Populate the tfvars/env files

- `infra/tofu/terraform.tfvars` (committed, non-secret) — fill in every
  `CHANGE_ME`: the OVH public IP, Cloudflare zone ID, Proxmox endpoint,
  node name, storage pool names, the Debian 13 image checksum, and your SSH
  public key(s).
- `infra/tofu/secrets.sops.tfvars.json` (encrypted) — edit in place with
  `sops infra/tofu/secrets.sops.tfvars.json`, replacing the `CHANGE_ME`
  placeholders with the real Proxmox and Cloudflare API tokens.
- `infra/tofu/state.sops.env` (encrypted) — edit in place with
  `sops infra/tofu/state.sops.env`, replacing `STATE_PASSPHRASE` with real
  random output from `openssl rand -base64 32`. This passphrase encrypts
  `terraform.tfstate` at rest (OpenTofu native state encryption) — losing
  it makes the committed state permanently unreadable, so treat it like any
  other durable secret (password manager entry, same as the age key).

## 2. Init and plan

```sh
cd infra/tofu
./tofu.sh init
./tofu.sh plan
```

Review the plan: 1 bridge (`vmbr1`), 1 image download, 1 VM (2 disks), 3
DNS records (apex/wildcard/vpn), and the cluster/node/VM firewall enable +
`mgmt` ipset + rules — the management rules' `source` should be **empty**
(unrestricted), because `restrict_management` defaults to `false`.

## 3. Arm a dead-man switch, then apply

The first apply enables the Proxmox firewall and changes host networking
for the first time on a server with no recovery console. Even though
`restrict_management=false` means the SSH/API accept rules stay open to any
source (see the anti-lockout note in `infra/tofu/firewall.tf`), a mistake
elsewhere in the diff is still a real risk on the first run — so run it
manually, with a safety net.

In a **separate** SSH session to the Proxmox host (keep this session open
throughout the apply):

```sh
nohup sh -c 'sleep 900; pvesh set /cluster/firewall/options --enable 0' &
```

This auto-disables the cluster firewall in 15 minutes if you lose access.
If the apply succeeds and you can still reach the host afterwards, cancel
it (`kill` the backgrounded `sleep`/`pvesh` job) before it fires.

Then, in your original terminal:

```sh
./tofu.sh apply
```

## 4. Verify

- `ssh debian@10.10.10.10` (or your `vm_ip_address`) works from the host.
- The VM shows the `vm_ip_cidr` address and the 150 GB data disk attached.
- `ping 10.10.10.1` (the vmbr1 gateway) succeeds from the VM.
- `dig +short plex.tomkatom.com @1.1.1.1` resolves to the OVH IP.
- **Public SSH to the host still works** from a machine that isn't the
  dead-man-switch session — confirms no lockout.
- Commit the updated `infra/tofu/terraform.tfstate` (it's an opaque
  encrypted envelope — `git diff` will show binary/ciphertext noise, that's
  expected and is why `.gitattributes` marks it `-diff -merge`). A bare
  `tofu plan` without `./tofu.sh` (i.e. no `TF_ENCRYPTION`) should fail
  with a "cannot decrypt" style error — that's the state encryption
  working.

## 5. Enable the gated CI apply pipeline

Every apply after the first one should go through
[`.github/workflows/tofu-apply.yml`](../../.github/workflows/tofu-apply.yml)
instead of running by hand. This is a one-time setup step:

1. In the GitHub repo, go to **Settings → Environments** and create an
   environment named `production`.
2. Add yourself as a **required reviewer** on that environment. This is
   the *only* gate in the pipeline — there is deliberately no repo
   variable or workflow input that can auto-apply. Until this environment
   exists with a reviewer configured, the `apply` job in the workflow has
   nowhere to run and is inert by construction.
3. Add these as **repository** secrets (Settings → Secrets and variables →
   Actions → Repository secrets) — not environment-scoped. The `plan` job
   runs on every push with no `environment:` key, so environment-scoped
   secrets would be invisible to it; the required-reviewer rule on
   `production` is what gates the pipeline, not secret visibility:
   - `PROXMOX_API_TOKEN`
   - `CLOUDFLARE_API_TOKEN`
   - `STATE_PASSPHRASE` (the same value you put in `state.sops.env`)
   - `PROXMOX_SSH_PRIVATE_KEY` (a private key authorized on the Proxmox
     host for the SSH-based image download/import operations; CI loads it
     into an `ssh-agent`, matching the local `ssh { agent = true }` setup)
4. Optionally set a `TOFU_RUNNER` repository variable once the runner needs
   to change — see the note on runner placement below.

From then on: every push to `master` runs the `plan` job automatically and
posts the plan output to the job summary; the `apply` job then pauses in
the `production` environment until you click **Approve** in the Actions
UI, having reviewed that exact plan. Only after approval does
`tofu apply -auto-approve` run, and only for a plan a human already saw.

**Runner placement:** the workflow runs on
`${{ vars.TOFU_RUNNER || 'ubuntu-latest' }}`. GitHub-hosted runners reach
the Proxmox API over its still-public IP:8006, which is fine for Phase 2
and early Phase 3. Once Phase 3 restricts management to WireGuard-only
(`restrict_management = true`), a GitHub-hosted runner can no longer reach
the API — set the `TOFU_RUNNER` repo variable to a self-hosted runner
reachable over the WG tunnel before that flip lands.

**`restrict_management = true` is a Phase 3 change** (Ansible, after
WireGuard is verified end-to-end) — it still goes through this same
plan → approve → apply gate, it's just a value flip in `terraform.tfvars`
like any other change.

## Tradeoffs (documented, not fixed by this design)

- Committed local state + CI apply works for a single-operator,
  low-frequency repo: the `apply` job's `concurrency` group serializes
  applies, and the commit step rebases before pushing the updated state.
  It is **not** safe for concurrent appliers — there's no locking beyond
  that concurrency group. This was a deliberate trade for "no external
  vendor, git stays the source of truth" (see `master-plan.md`).
