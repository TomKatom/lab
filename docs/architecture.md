# Architecture

Living reference for how the lab is built. `../master-plan.md` is the
planning record — decisions and their rationale, frozen at the point they
were made. This document is meant to stay in sync with what's actually
implemented as each phase lands; where the two disagree, trust this file
and the code, and update `master-plan.md`'s decision log if a call changed.

**Status:** Phase 6 (media apps). Phases 2–5 are applied and live —
`infra/tofu/`'s VM/firewall/DNS, Ansible's WireGuard management plane,
single-IP NAT/DNAT, host + VM hardening, the `tank` ZFS stripe, the
virtiofs share and k3s, and the Argo CD platform layer (cert-manager,
Traefik, Authelia, external-dns). The media stack in
[`clusters/lab/apps/`](../clusters/lab/apps/) is deployed and reconciling;
**migrating the old server's state onto it is operator work in progress**
([`docs/runbooks/media-migration.md`](runbooks/media-migration.md)).
**Public DNS has moved** — [`docs/runbooks/dns-cutover.md`](runbooks/dns-cutover.md)
has run, external-dns no longer carries `--dry-run`, and it owns and writes
every Ingress hostname in the zone for real. Every apply
goes through the gated CI pipeline described in
[CI/CD](#cicd--gitops-flow) below; the first Tofu apply was the one manual,
operator-run step (dead-man switch, see
[`docs/runbooks/tofu-apply.md`](runbooks/tofu-apply.md)).

## Overview

Single OVH dedicated server (Proxmox 9.2, E5-1650v4, 128 GB RAM, 2×500 GB
NVMe + 2×2 TB HDD), single public IP. Proxmox host is already installed;
`rpool` (NVMe ZFS mirror) serves as its root. Everything else — VM,
networking, cluster, apps — is built as code from this repo.

Domain: `tomkatom.com` (Cloudflare DNS). Management access is `wg0`-only;
there is no public SSH and no IPMI/console, so the management plane must
never be self-strandable — see [Management plane](#management-plane). A
second tunnel, `wg1`, exists for the opposite purpose — giving a guest the
internet from this server's IP — and reaches no management surface at all.

## Configuration single source of truth

[`config/lab.yml`](../config/lab.yml) holds the non-secret facts shared
across two or more layers — domain, the internal/WireGuard subnets, the VM's
static IP, and the service ports. Each layer reads the same file instead of
re-declaring these values:
- **OpenTofu** (`infra/tofu/locals.tf`) — `yamldecode(file(...))` into
  `local.lab`, feeding the bridge/VM/firewall/DNS resources.
- **Ansible** (Phase 3) — loaded via `vars_files` in `group_vars`, feeding
  WireGuard, NAT/DNAT, and the inventory.
- **Helm/Argo** (Phase 5+) — **does not read this file, and cannot.** Argo
  renders `clusters/lab/` straight from git with no templating layer in
  between, and every `Application` carries its values inline in
  `helm.valuesObject`; the only `valueFiles` in the repo is `argo-cd.yaml`
  pointing at its own `bootstrap/argocd-values.yaml`. So the handful of
  `lab.yml` facts the cluster layer needs — the domain in ingress hostnames
  and external-dns's `domainFilters`, `ports.torrent` in Deluge's
  Services and `core.conf`, `network.vmbr1_host_address` in the two
  hypervisor scrape targets — are **hand-copied constants**. Each carries a
  comment naming the `config/lab.yml` key it must track; changing one of
  those facts means editing those manifests by hand, and nothing enforces
  that they agree.

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
│  Public inbound: 443 · 32400 · torrent-port  (DNAT → VM)  ·  51820/udp (wg0, host) · 51821/udp (wg1, host)
│  Management (SSH/8006/6443/9100): wg0-only, never public — wg1 reaches none of it
│  Egress: VM → internet via host masquerade (appears as the OVH IP); wg1 guests likewise
│
├─ rpool (ZFS mirror, 2×500GB NVMe)  ── Proxmox root + VM system disks + app CONFIG (fast)
├─ tank  (ZFS stripe, 2×2TB HDD)     ── media library + downloads (bulk, non-redundant)
│
├─ Proxmox firewall (filtering)      ←── OpenTofu (bpg): datacenter/node/VM rules
├─ WireGuard + NAT/DNAT + OS hardening + ZFS + virtiofs  ←── Ansible
│      ├─ wg0 peers routed into vmbr1 (10.10.10.0/24) — management
│      └─ wg1 guests routed to the internet only (10.10.30.0/24) — exit VPN, firewalled off the lab
│
└─ VM: k3s-node  (vmbr1 internal IP, behind host NAT)
     ├─ virtiofs mount /data  ← host tank/data (hardlink-friendly single tree)
     ├─ local-path PVs        ← VM NVMe disk (app configs/DBs)
     │
     └─ Argo CD  ←──────── pulls git (single source of truth) ── reconciles:
          platform/                       apps/ (media ns, Helm app-template)
           ├─ cert-manager (DNS-01, wildcard+apex)   ├─ media-common (shared secrets/env)
           ├─ external-dns (Cloudflare, live)        ├─ plex      (direct-play, own port)
           ├─ traefik (ingress :443, hostPort)       ├─ prowlarr / flaresolverr (indexers)
           ├─ authelia (auth.tomkatom.com)           ├─ sonarr / radarr / bazarr
           ├─ ksops secrets (kustomize)              ├─ deluge (OVH IP via NAT, torrent port)
           └─ monitoring (metrics + logs + alerts)   ├─ unpackerr / recyclarr
                                                     ├─ seerr (requests) / maintainerr
                                                     └─ tautulli / homepage (apex + www)
                                                    apps/ (share ns)
                                                     └─ filebrowser (files. + share.)
```

## Tooling

| Concern | Tool | Why |
|---|---|---|
| Provisioning | **OpenTofu** + `bpg/proxmox`, `cloudflare` | Open-source; bpg is the maintained Proxmox provider (also manages the PVE filter firewall) |
| Tofu state | **local + native state encryption** (OpenTofu ≥1.7), committed to git | No external vendor; git stays source of truth |
| Config mgmt | **Ansible** (+ `community.sops`) | WireGuard, NAT/DNAT, OS hardening, ZFS, k3s bootstrap |
| Mgmt access | **WireGuard `wg0`** (on host) | SSH/PVE/k8s APIs private; no public SSH |
| Guest exit VPN | **WireGuard `wg1`** (on host, separate keypair) | Full tunnel out of the German IP; isolated from the lab in the `lab-nat` forward chain, never in the `+mgmt` ipset |
| Single-IP sharing | **nftables NAT/DNAT** (Ansible `network-nat`) | Forwards 443/32400/torrent to VM; masquerades egress |
| Cluster | **k3s** (single node, bundled Traefik disabled) | Lightweight k8s; Traefik managed via Argo, bound to `:443` by Pod `hostPort` so it sees real client IPs (klipper servicelb masqueraded them; no MetalLB), with a per-source-IP `rateLimit` on the entrypoint covering every router |
| GitOps | **Argo CD** (app-of-apps) | UI + drift/sync visibility |
| Packaging | **Helm** (`bjw-s/app-template`) + **Kustomize** (secrets only) | DRY across near-identical apps; ksops needs Kustomize |
| Secrets | **SOPS + age** + **ksops** | One key for k8s + Tofu + Ansible |
| Ingress/TLS | **Traefik** + **cert-manager** (LE DNS-01 Cloudflare, `*.tomkatom.com`) | Wildcard cert, no open :80 |
| DNS | **external-dns** (Cloudflare), `policy: sync` + txt registry (`txtOwnerId: lab-k3s`) | Records follow Ingresses, retired ones are cleaned up; ownership TXTs scope deletes to its own records, so it never touches the Tofu-owned apex/wildcard/vpn records or the old server's |
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

WireGuard's management tunnel `wg0` listens on public `51820/udp`. SSH(22),
Proxmox UI/API(8006), the k8s API(6443), and the host node_exporter(9100) are
**not** in the public accept list — reachable only from the `+mgmt` ipset,
which is the internal subnet plus `wg0`'s peer subnet, and that second half
is what lets Prometheus in the k3s VM scrape the host. `wg0` peers are routed
into `vmbr1`, so a laptop peer reaches both host and VM management over the
tunnel. Each peer is scoped to its own `/32` on the host side (that field is
the anti-spoof source filter, not the peer's route list — see
[`docs/networking.md`](networking.md#wireguard-management-plane)), with an
optional preshared key on top of the handshake.

"Reachable over WireGuard" is *not* the rule, and the distinction is
load-bearing now that a second tunnel exists. The host also runs `wg1`, a
guest exit VPN on public `51821/udp` whose peer subnet is deliberately absent
from `management_sources` and therefore from the `+mgmt` ipset — so a guest
holding a valid `wg1` key reaches none of the ports above, and is firewalled
out of the lab entirely in the `lab-nat` forward chain. That omission is the
access control, so `infra/tofu/firewall.tf` carries a
`lifecycle.precondition` that fails the apply if the exit subnet is ever
added to that list. Design:
[`docs/networking.md`](networking.md#wireguard-guest-exit-plane); procedure:
[`docs/runbooks/wireguard-exit-peer.md`](runbooks/wireguard-exit-peer.md).

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
to the `mgmt` ipset (`management_sources`). 443/32400/torrent and the two
WireGuard endpoints (51820-udp, 51821-udp) stay public throughout.
`enable_firewall` is a separate master kill-switch.

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
· torrent port (Deluge/DNAT) · `51820/udp` (WireGuard `wg0`/host) ·
`51821/udp` (WireGuard `wg1`, guest exit/host). Everything else
default-drop.

### Storage split

- App **configs/DBs** (*arr SQLite, Plex metadata) → VM NVMe via
  **local-path-provisioner**. Fast, doesn't need bulk-disk redundancy at
  this tier (backups cover loss — they are inside the nightly VM backup
  from their first write, because `local-path` is the cluster default).
- **Media + downloads** → host `tank/data` shared into the VM via
  **virtiofs**, mounted `/data`, exposed to pods as hostPath/local PVs.
  **`tank` is deliberately not snapshotted and not backed up at all** — 3.6
  TB of re-downloadable content on a non-redundant stripe, and snapshotting
  it would pin deleted media forever on the pool with the least room for it.
  The reasoning, including why the \*arr backup zips on it are redundant
  rather than a gap, is in [`docs/backups.md`](backups.md#deliberately-not-backed-up).
- **Single `/data` tree** (`/data/torrents` + `/data/media`, TRaSH layout)
  so Sonarr/Radarr do **atomic hardlink moves** — instant imports, no
  copies, same inode.
- **ARC is sized once, host-wide** (`ansible/roles/zfs_arc`, 32 GiB) — one
  cache serves both pools. It is declared because the pre-IaC install left
  it at 391 MiB, too small for `tank` to hold even its own metadata, which
  made every partial write to the HDD stripe a read-modify-write of a whole
  128 KiB record. That role's `defaults/main.yml` carries the sizing
  derivation against the memory the guests reserve; change it there, not on
  the host.

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

- **No public management surface** — SSH/PVE/k8s APIs accept only from the
  `+mgmt` ipset, i.e. the internal subnet and `wg0`'s peers; the only public
  ports are 443/32400/torrent/51820-udp/51821-udp. The `wg1` guest exit VPN
  on that last port is not a management path and cannot become one by
  accident: its subnet's absence from `management_sources` is asserted by a
  Tofu `lifecycle.precondition`.
- OS: SSH key-only + non-root, `fail2ban`, `unattended-upgrades`, sysctl +
  `auditd`, minimal packages (Ansible `hardening` role, host + VM).
- **Firewall in code** — Proxmox filter firewall via Tofu/bpg (default-drop
  posture, `enable_firewall` kill-switch); NAT via Ansible. The
  `restrict_management` toggle keeps SSH/API rules open-to-any until
  WireGuard is verified (anti-lockout); reseller console is the fallback.
- Least exposure: admin UIs sit behind **Authelia** (TOTP); Plex uses
  plex.tv auth on its own port, outside Traefik/Authelia. Exactly three
  Ingresses are deliberately un-annotated, and none of the three may be
  "fixed". Two are aimed at people who hold a Plex account and no Authelia
  identity: Seerr's `requests.` (its own Plex OAuth) and Homepage on the
  apex (a page of public links, no credential read and no app polled — see
  [`clusters/lab/apps/README.md`](../clusters/lab/apps/README.md)). The
  third is Authelia's own `auth.` portal, un-annotated for an unrelated
  reason: it has to answer unauthenticated or there is nowhere to
  authenticate, and putting it behind its own forward-auth locks the
  cluster out
  ([`clusters/lab/platform/README.md`](../clusters/lab/platform/README.md)).
- Secrets are never plaintext: `.sops.yaml` enforces encryption by path,
  `gitleaks` in CI blocks anything that slips through, and the age private
  key is held out-of-band (password manager), as the `SOPS_AGE_KEY` repo
  secret for the gated pipelines, and in-cluster for Argo/ksops. Tofu state
  is natively encrypted even though it's committed. Details:
  [`docs/secrets.md`](secrets.md).
- **Backups** run in three tiers: sanoid ZFS snapshots on `rpool` (local
  rollback), a nightly `vzdump` of the k3s VM into Proxmox Backup Server,
  and a nightly file-level backup of the hypervisor's own configuration into
  the same datastore — which is **client-side encrypted and stored in
  Backblaze B2**, so the offsite copy is ciphertext the vendor cannot read.
  The age key and the PBS encryption key are held out-of-band in the
  password manager; everything else reconciles from git. Design, retention,
  cost and the recovery chain: [`docs/backups.md`](backups.md).

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
3. **Configure (Ansible)** — WireGuard first, then NAT/DNAT,
   hardening, `tank`, virtiofs, k3s install. Also install/enable
   `qemu-guest-agent` in the VM (see [Guest agent](#guest-agent) below) —
   Phase 2 deliberately leaves this out, since the VM has no OS config yet.
4. **Bootstrap Argo CD** — Helm install + ksops patch, `root-app.yaml`.
5. **Platform apps** *(done)* — cert-manager, external-dns, Traefik,
   Authelia. All live, external-dns writing for real since
   [`docs/runbooks/dns-cutover.md`](runbooks/dns-cutover.md) ran.
6. **Media apps** *(current)* — deployed and reconciling from
   [`clusters/lab/apps/`](../clusters/lab/apps/): Deluge, Prowlarr,
   FlareSolverr, Sonarr, Radarr, Bazarr, Unpackerr, Recyclarr, Plex,
   Tautulli, Seerr, Maintainerr, Homepage, all in one `media` namespace on the
   shared `/data` tree. What remains is **state migration** from the old
   server (operator-executed —
   [`docs/runbooks/media-migration.md`](runbooks/media-migration.md)).
7. **Observability** — kube-prometheus-stack (Prometheus, Alertmanager,
   Grafana), Loki + Alloy for logs, `prometheus-pve-exporter` and the
   hypervisor's own `node_exporter` for the layer below Kubernetes, alerting
   to Telegram. Component map, alert catalog, retention and rotation
   procedures: [`docs/observability.md`](observability.md).
8. **Backups** — Proxmox Backup Server on the host, S3-backed datastore in
   Backblaze B2 (`ansible/roles/pbs`); the nightly `vzdump` job
   (`infra/tofu/backup.tf`); a file-level backup of the hypervisor itself;
   sanoid ZFS snapshots (`ansible/roles/zfs_snapshots`) as the local
   rollback tier; the monitoring PVCs moved onto an unbacked disk so
   telemetry never reaches the bucket; and alerting on all of it. Tiers,
   retention, cost model and the recovery chain:
   [`docs/backups.md`](backups.md). Restores:
   [`docs/runbooks/restore.md`](runbooks/restore.md) and
   [`docs/runbooks/disaster-recovery.md`](runbooks/disaster-recovery.md).
9. **Outbound file sharing** — FileBrowser Quantum in its own `share`
   namespace, browsing `/data/torrents` in place (read-only) behind Authelia
   on `files.tomkatom.com`, and serving expiring, download-capped links to
   people with no account on `share.tomkatom.com`. The split is enforced at
   Traefik, not in the app: only `/public` is routed on the public hostname,
   so the browse API has no route there at all. A NetworkPolicy restricts
   ingress to the `traefik` namespace, which is what makes trusting
   `Remote-User` safe. Procedure and sharing policy:
   [`docs/runbooks/sharing.md`](runbooks/sharing.md).
10. **Guest exit VPN** — `wg1`, a second WireGuard interface on the host
    (`51821/udp`, its own keypair, its own peer list) giving a guest a full
    tunnel out of the German uplink and nothing else. Isolation is a block at
    the top of the `lab-nat` forward chain that allows by exception and ends
    in a `drop`; the exit subnet is deliberately absent from the `+mgmt`
    ipset, backed by a `lifecycle.precondition`. Peers take `0.0.0.0/0, ::/0`
    — the `::/0` half so that an IPv6-capable client cannot silently route
    half its traffic around the tunnel, since the host forwards no IPv6 and
    that address family is a deterministic blackhole. Ships with zero peers.
    Design: [`docs/networking.md`](networking.md#wireguard-guest-exit-plane).
    Procedure:
    [`docs/runbooks/wireguard-exit-peer.md`](runbooks/wireguard-exit-peer.md).
11. **Personal finance** — Actual Budget on `budget.tomkatom.com` and a
    nightly `moneyman` CronJob that scrapes Bank Hapoalim and Isracard into
    it, both in a `finance` namespace of their own. The namespace is a
    Secret boundary and nothing else: `moneyman-config` holds two real bank
    logins, and no *arr has a path to them. It ships inert — the credential
    blob is a template and the CronJob is merged suspended — because a run
    against placeholders would fail nightly. The scraper exits `0` whatever
    happens, so a Succeeded Job proves nothing and staleness, not failure,
    is what `MoneymanStale` watches. Procedure:
    [`docs/runbooks/finance.md`](runbooks/finance.md).

## Verification

See `master-plan.md`'s
[Verification](../master-plan.md#verification) section for the acceptance
checks per layer (CI green, WG up/down reachability test, NAT port checks,
`tofu plan` diff review, Argo `Synced/Healthy`, SOPS decrypt round-trip,
Ingress/TLS/auth browser test, hardlink import + Plex direct-play test,
external port scan).
