# Architecture

Living reference for how the lab is built. `../master-plan.md` is the
planning record — decisions and their rationale, frozen at the point they
were made. This document is meant to stay in sync with what's actually
implemented as each phase lands; where the two disagree, trust this file
and the code, and update `master-plan.md`'s decision log if a call changed.

**Status:** Phase 3 (configure) — `infra/tofu/` (Phase 2) is applied, and
Ansible (Phase 3) is substantially complete and applied live: WireGuard
management plane, single-IP NAT/DNAT, host + VM hardening, the `tank` ZFS
stripe, the virtiofs share, and k3s are all up on the server. Every apply
goes through the gated CI pipeline described in
[CI/CD](#cicd--gitops-flow) below; the first Tofu apply was the one manual,
operator-run step (dead-man switch, see
[`docs/runbooks/tofu-apply.md`](runbooks/tofu-apply.md)).

## Overview

Single OVH dedicated server (Proxmox 9.2, E5-1650v4, 128 GB RAM, 2×500 GB
NVMe + 2×2 TB HDD), single public IP. Proxmox host is already installed;
`rpool` (NVMe ZFS mirror) serves as its root. Everything else — VM,
networking, cluster, apps — is built as code from this repo.

Domain: `tomkatom.com` (Cloudflare DNS). Access is WireGuard-only; there is
no public SSH and no IPMI/console, so the management plane must never be
self-strandable — see [Management plane](#management-plane).

## Configuration single source of truth

[`config/lab.yml`](../config/lab.yml) holds the non-secret facts shared
across two or more layers — domain, the internal/WireGuard subnets, the VM's
static IP, and the service ports. Each layer reads the same file instead of
re-declaring these values:
- **OpenTofu** (`infra/tofu/locals.tf`) — `yamldecode(file(...))` into
  `local.lab`, feeding the bridge/VM/firewall/DNS resources.
- **Ansible** (Phase 3) — loaded via `vars_files` in `group_vars`, feeding
  WireGuard, NAT/DNAT, and the inventory.
- **Helm/Argo** (Phase 5) — referenced via Argo `Application` `valueFiles`,
  feeding ingress hostnames, cert-manager, and service ports.

Facts used by only one layer (Proxmox endpoint, storage pools, VM sizing,
image checksum) stay declared in that layer, alongside its secrets.

## Three IaC layers, one repo

1. **Provision** — [`infra/tofu/`](../infra/tofu/), OpenTofu (`bpg/proxmox`
   + `cloudflare`). `vmbr1` (Tofu-owned internal bridge), the `k3s-node` VM
   and its disks, the Proxmox *filtering* firewall (with an anti-lockout
   `restrict_management` toggle — see [Management plane](#management-plane)),
   foundational Cloudflare records. State is local and natively encrypted
   (OpenTofu ≥1.7, passphrase injected via `TF_ENCRYPTION`, never in code —
   see [`infra/tofu/README.md`](../infra/tofu/README.md)), committed to git.
2. **Configure** — [`ansible/`](../ansible/). WireGuard management plane,
   single-IP NAT/DNAT, host + VM OS hardening, the `tank` ZFS non-redundant
   stripe, the virtiofs share, k3s install (bundled Traefik disabled).
3. **Deliver** — [`clusters/lab/`](../clusters/lab/), Argo CD app-of-apps.
   Everything in-cluster is reconciled from git; no manual `kubectl apply`.

## Target topology

```
OVH dedicated (Proxmox 9.2) — SINGLE public IP
│  Public inbound: 443 · 32400 · torrent-port  (DNAT → VM)  ·  51820/udp (WireGuard, host)
│  Management (SSH/8006/6443): WireGuard-only, never public
│  Egress: VM → internet via host masquerade (appears as the OVH IP)
│
├─ rpool (ZFS mirror, 2×500GB NVMe)  ── Proxmox root + VM system disks + app CONFIG (fast)
├─ tank  (ZFS stripe, 2×2TB HDD)     ── media library + downloads (bulk, non-redundant)
│
├─ Proxmox firewall (filtering)      ←── OpenTofu (bpg): datacenter/node/VM rules
├─ WireGuard + NAT/DNAT + OS hardening + ZFS + virtiofs  ←── Ansible
│      └─ WG peers routed into vmbr1 (10.10.10.0/24)
│
└─ VM: k3s-node  (vmbr1 internal IP, behind host NAT)
     ├─ virtiofs mount /data  ← host tank/data (hardlink-friendly single tree)
     ├─ local-path PVs        ← VM NVMe disk (app configs/DBs)
     │
     └─ Argo CD  ←──────── pulls git (single source of truth) ── reconciles:
          platform/                       apps/ (media, Helm app-template)
           ├─ cert-manager (DNS-01, *.tomkatom.com)  ├─ plex     (direct-play, own port)
           ├─ external-dns (Cloudflare)              ├─ prowlarr (indexers)
           ├─ traefik (ingress :443)                 ├─ sonarr / radarr / bazarr
           ├─ authelia (auth.tomkatom.com)           ├─ deluge   (OVH IP via NAT, torrent port)
           ├─ ksops secrets (kustomize)              └─ overseerr (requests, optional)
           └─ monitoring/ (placeholder → later)
```

## Tooling

| Concern | Tool | Why |
|---|---|---|
| Provisioning | **OpenTofu** + `bpg/proxmox`, `cloudflare` | Open-source; bpg is the maintained Proxmox provider (also manages the PVE filter firewall) |
| Tofu state | **local + native state encryption** (OpenTofu ≥1.7), committed to git | No external vendor; git stays source of truth |
| Config mgmt | **Ansible** (+ `community.sops`) | WireGuard, NAT/DNAT, OS hardening, ZFS, k3s bootstrap |
| Mgmt access | **WireGuard** (on host) | SSH/PVE/k8s APIs private; no public SSH |
| Single-IP sharing | **nftables NAT/DNAT** (Ansible `network-nat`) | Forwards 443/32400/torrent to VM; masquerades egress |
| Cluster | **k3s** (single node, bundled Traefik disabled) | Lightweight k8s; Traefik managed via Argo; klipper servicelb (no MetalLB) |
| GitOps | **Argo CD** (app-of-apps) | UI + drift/sync visibility |
| Packaging | **Helm** (`bjw-s/app-template`) + **Kustomize** (secrets only) | DRY across near-identical apps; ksops needs Kustomize |
| Secrets | **SOPS + age** + **ksops** | One key for k8s + Tofu + Ansible |
| Ingress/TLS | **Traefik** + **cert-manager** (LE DNS-01 Cloudflare, `*.tomkatom.com`) | Wildcard cert, no open :80 |
| DNS | **external-dns** (Cloudflare), `upsert-only` | Records follow Ingresses; never touches the Tofu-owned apex/wildcard/vpn records |
| AuthN/Z | **Authelia** (forward-auth, file users + TOTP, SQLite) | Protects *arr/deluge UIs |
| Dep updates | **Renovate** | Automated chart/image bump PRs |
| CI guards | **GitHub Actions** + **gitleaks** | Validate + block plaintext secrets |

## Networking & storage

### Single-IP NAT model

The host owns the one OVH IP on the public interface. The VM sits on an
internal NAT bridge `vmbr1` (`10.10.10.0/24`). Host nftables (Ansible
`network-nat` role):
- **DNAT** public `443 / 32400 / torrent-port` → the VM's internal IP.
- **Masquerade** VM egress → appears as the OVH IP (Deluge seeds from the
  datacenter IP, no VPN).

The Proxmox **filter** firewall (Tofu/bpg) governs what's accepted on each
interface/vNIC; the NAT table (Ansible) governs address translation —
different nftables hooks, no conflict. A DNAT'd packet still has to clear
the VM-level accept rule.

This "no conflict" holds only because PVE runs the **nftables firewall
backend** (`proxmox-firewall`), pinned by the Ansible `pve_firewall` role.
Under the legacy **iptables** backend the two collide: that backend forces
`net.bridge.bridge-nf-call-iptables=1` for its per-VM `--physdev-is-bridged`
filtering, which drags a `firewall=1` VM's frames through the ip-family NAT
POSTROUTING hook at the L2 bridging stage and commits a null SNAT binding
before the packet is routed — silently killing egress masquerade. The
nftables backend filters per-VM traffic in the `bridge` family with no such
dependency.

### Management plane

WireGuard listens on public `51820/udp`. SSH(22), Proxmox UI/API(8006), and
the k8s API(6443) are **not** in the public accept list — reachable only
over the WG interface. WG peers are routed into `vmbr1`, so a laptop peer
reaches both host and VM management over the tunnel. Each peer is scoped to
its own `/32` on the host side (that field is the anti-spoof source filter,
not the peer's route list — see
[`docs/networking.md`](networking.md#wireguard-management-plane)), with an
optional preshared key on top of the handshake.

Those endpoints are addressable by name — `pve.lab.tomkatom.com`,
`k3s.lab.tomkatom.com` — via grey-cloud Cloudflare records whose targets are
the internal addresses. Public records, private targets, no split-horizon
resolver to keep alive; see
[`docs/networking.md#name-resolution`](networking.md#name-resolution) for
the trade-offs, and
[`docs/runbooks/wireguard-peer.md`](runbooks/wireguard-peer.md) for the
client side.

**Bootstrap ordering — never self-strand:** the first Ansible run brings up
WireGuard over the *existing* public SSH, verifies the tunnel end-to-end,
and only then does OpenTofu drop public SSH from the Proxmox firewall.
Reseller-mediated console is the slow last-resort fallback if this ever
goes wrong — see `docs/runbooks/lockout-recovery.md` (Phase 3).

**The anti-lockout mechanism, concretely:** it has two independent halves,
and the first version of `infra/tofu/firewall.tf` shipped only one of them
and locked the host out. Both are now enforced in code.

*Half one — who the rules accept from.* The SSH/Proxmox-API/k8s-API accept
rules gate their `source` on a single `restrict_management` variable. Phase
2 ships it `false` — the filter firewall is enabled (default-drop) but
those rules accept from *any* source, so public SSH survives even though
the firewall is live. Phase 3 flips it to `true` only after WireGuard is
verified end-to-end; at that point only the `source` on those rules narrows
to the `mgmt` ipset (`management_sources`). 443/32400/torrent/51820-udp
stay public throughout. `enable_firewall` is a separate master kill-switch.

*Half two — when the DROP policy is allowed to exist.* The default-DROP
policy and the accept rules are **separate API objects**, so having correct
rules in the config guarantees nothing about ordering: OpenTofu will create
the wall before the holes unless the dependency graph forbids it. It did
exactly that once — the rules resource had a `depends_on` upstream that
failed, the rules never ran, and the cluster DROP policy (which depended on
nothing) applied cleanly, leaving default-drop with zero accept rules on a
box with no console. The graph is therefore inverted: **the policy depends
on the rules** (`cluster_firewall` → `firewall_rules.node`, and
`firewall_options.vm` → `firewall_rules.vm`). A failed rule resource now
aborts the apply *before* the DROP lands, so a broken apply leaves the host
open rather than bricked, and destroy tears the policy down first.
`precondition` blocks on both policy resources refuse a DROP policy with an
empty management-rule set, or `restrict_management = true` with an empty
`management_sources`.

**Exposed public ports:** `443` (Traefik/DNAT) · `32400` (Plex direct/DNAT)
· torrent port (Deluge/DNAT) · `51820/udp` (WireGuard/host). Everything
else default-drop.

### Storage split

- App **configs/DBs** (*arr SQLite, Plex metadata) → VM NVMe via
  **local-path-provisioner**. Fast, doesn't need bulk-disk redundancy at
  this tier (backups cover loss).
- **Media + downloads** → host `tank/data` shared into the VM via
  **virtiofs**, mounted `/data`, exposed to pods as hostPath/local PVs; ZFS
  snapshots/scrubs stay on the host.
- **Single `/data` tree** (`/data/torrents` + `/data/media`, TRaSH layout)
  so Sonarr/Radarr do **atomic hardlink moves** — instant imports, no
  copies, same inode.

### Guest agent

`vm-k3s.tf` sets `agent.enabled = true`, which only tells Proxmox to expose
the virtio-serial channel — it does nothing until `qemu-guest-agent` is
actually installed and running inside the guest, which is Ansible's job
(Phase 3), not Tofu's.

Until that package is installed, the Proxmox API's guest-agent endpoints
(e.g. `agent/network-get-interfaces`, used internally by the `bpg` provider
to read the VM's reported IPs) have nothing to talk to. The Terraform API
token's role (`Terraform`, a custom least-privilege role — see
[`docs/secrets.md`](secrets.md)) deliberately excludes `VM.GuestAgent.Audit`
/ `VM.GuestAgent.Unrestricted` for this reason: granting them before the
agent exists doesn't fail fast (a quick, harmless 403) — the Proxmox API
call instead blocks for minutes waiting on a socket nothing is listening on,
which hangs `tofu plan`/`apply` on every run.

**Phase 3 must, in order:**
1. Install and enable `qemu-guest-agent` in the VM (Ansible `hardening` or
   `k3s` role).
2. Only then grant `VM.GuestAgent.Audit` (read-only: network/OS info) to the
   `Terraform` role — `VM.GuestAgent.Unrestricted` allows arbitrary
   guest-exec and should stay unused unless something concrete needs it.
3. Re-verify `tofu plan` stays fast afterward, since the guest agent should
   now actually answer.

## CI/CD & GitOps flow

- **Pull-based delivery** (Phase 4+): merge to `master` → Argo CD auto-syncs
  the cluster. No push into the server for app changes.
- **PR gate** ([`.github/workflows/ci.yml`](../.github/workflows/ci.yml)) —
  `gitleaks`, `yamllint`, `tofu fmt`/`tofu init -backend=false`/
  `tofu validate`, `ansible-lint`, `helm template | kubeconform` +
  `kustomize build | kubeconform`. This is a **validate-only** gate: it has
  no Proxmox credentials and never runs `tofu plan`, by design — reconciling
  `master-plan.md`'s "`tofu plan` green in CI" wording, `plan` actually runs
  in the workflow below (with real credentials) and in the local
  `./tofu.sh plan` wrapper, not in the PR gate.
- **Gated apply pipeline**
  ([`.github/workflows/tofu-apply.yml`](../.github/workflows/tofu-apply.yml))
  — two jobs, split so a bad diff can never apply unattended:
  - `plan` runs automatically on every pull request targeting `master`,
    and posts the plan output to the job summary. Both jobs get their
    credentials by running the same `infra/tofu/tofu.sh` wrapper a local
    apply uses, decrypting the committed SOPS files with the age key held
    as the `SOPS_AGE_KEY` repo secret — so there is no second, hand-synced
    copy of any token. That CI holds the age key at all is a deliberate
    reversal of the earlier "no age key in CI" rule; the blast radius it
    accepts is spelled out in [`docs/secrets.md`](secrets.md#accepted-trade-ci-holds-the-age-key).
  - `apply` (`needs: plan`) runs in the `production` GitHub Environment.
    That environment's required-reviewer rule is the *only* gate: a human
    must click **Approve** in the Actions UI, having reviewed the exact
    plan from the job above, before `tofu apply -auto-approve` runs. There
    is no repo variable or workflow input that can bypass this. Until the
    environment is created and configured (a one-time manual step, see
    [`docs/runbooks/tofu-apply.md`](runbooks/tofu-apply.md)), the `apply`
    job simply has nowhere to run.
  - Runs on `${{ vars.LAB_RUNNER || 'ubuntu-latest' }}` — GitHub-hosted
    reaches the Proxmox API over its still-public IP:8006 for Phase 2/early
    Phase 3; once `restrict_management=true` lands, `LAB_RUNNER` switches
    to a self-hosted runner reachable over WireGuard. Named for the lab as
    a whole, not Tofu specifically — `ansible-apply.yml`
    (`.github/workflows/ansible-apply.yml`) shares the same variable and
    the same eventual self-hosted runner.
  - On a state change, the job pushes `terraform.tfstate` as an extra
    commit onto the PR's own branch (`[skip ci]`) rather than onto
    `master` — `master` is protected and this workflow never pushes to it
    directly. Squash-merging the PR then carries the state update into the
    same commit as the change that produced it.
- **Renovate** opens dependency-bump PRs (chart versions, provider pins via
  the committed `.terraform.lock.hcl`); the same PR gate validates them.

## Security / hardening

- **No public management surface** — SSH/PVE/k8s APIs are WireGuard-only;
  the only public ports are 443/32400/torrent/51820-udp.
- OS: SSH key-only + non-root, `fail2ban`, `unattended-upgrades`, sysctl +
  `auditd`, minimal packages (Ansible `hardening` role, host + VM).
- **Firewall in code** — Proxmox filter firewall via Tofu/bpg (default-drop
  posture, `enable_firewall` kill-switch); NAT via Ansible. The
  `restrict_management` toggle keeps SSH/API rules open-to-any until
  WireGuard is verified (anti-lockout); reseller console is the fallback.
- Least exposure: admin UIs sit behind **Authelia** (TOTP); Plex uses
  plex.tv auth on its own port, outside Traefik/Authelia.
- Secrets are never plaintext: `.sops.yaml` enforces encryption by path,
  `gitleaks` in CI blocks anything that slips through, and the age private
  key is held out-of-band (password manager), as the `SOPS_AGE_KEY` repo
  secret for the gated pipelines, and in-cluster for Argo/ksops. Tofu state
  is natively encrypted even though it's committed. Details:
  [`docs/secrets.md`](secrets.md).
- **Backups** are deferred — later, `vzdump` → NFS on a separate box; the
  age key and the Argo/ksops secret get backed up alongside cluster state.

## Phased implementation

Each phase is its own PR. Full detail and current status in
[`master-plan.md`](../master-plan.md#phased-implementation-each-phase--its-own-pr).

1. **Repo scaffold** — structure, `.sops.yaml`, age key, CI skeleton,
   README + this doc.
2. **Provision (Tofu)** — `vmbr1`, VM + disks, Proxmox filter
   firewall (anti-lockout toggle), Cloudflare records, native state
   encryption, gated CI apply pipeline. Authored + `tofu validate` green;
   first apply is a manual operator step (see
   [`docs/runbooks/tofu-apply.md`](runbooks/tofu-apply.md)).
3. **Configure (Ansible)** *(current)* — WireGuard first, then NAT/DNAT,
   hardening, `tank`, virtiofs, k3s install. Also install/enable
   `qemu-guest-agent` in the VM (see [Guest agent](#guest-agent) below) —
   Phase 2 deliberately leaves this out, since the VM has no OS config yet.
4. **Bootstrap Argo CD** — Helm install + ksops patch, `root-app.yaml`.
5. **Platform apps** — cert-manager, external-dns, Traefik, Authelia.
6. **Media apps** — Prowlarr → Sonarr/Radarr/Bazarr → Deluge → Plex →
   Overseerr.
7. **Observability** *(later)* — kube-prometheus-stack + Loki.
8. **Backups** *(later)* — `vzdump` → NFS on a separate box.

## Verification

See `master-plan.md`'s
[Verification](../master-plan.md#verification) section for the acceptance
checks per layer (CI green, WG up/down reachability test, NAT port checks,
`tofu plan` diff review, Argo `Synced/Healthy`, SOPS decrypt round-trip,
Ingress/TLS/auth browser test, hardlink import + Plex direct-play test,
external port scan).
