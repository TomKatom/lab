# Architecture

Living reference for how the lab is built. `../master-plan.md` is the
planning record — decisions and their rationale, frozen at the point they
were made. This document is meant to stay in sync with what's actually
implemented as each phase lands; where the two disagree, trust this file
and the code, and update `master-plan.md`'s decision log if a call changed.

**Status:** Phase 1 (repo scaffold) — nothing below is provisioned yet.

## Overview

Single OVH dedicated server (Proxmox 8, E5-1650v4, 128 GB RAM, 2×500 GB
NVMe + 2×2 TB HDD), single public IP. Proxmox host is already installed;
`rpool` (NVMe ZFS mirror) serves as its root. Everything else — VM,
networking, cluster, apps — is built as code from this repo.

Domain: `tomkatom.com` (Cloudflare DNS). Access is WireGuard-only; there is
no public SSH and no IPMI/console, so the management plane must never be
self-strandable — see [Management plane](#management-plane).

## Three IaC layers, one repo

1. **Provision** — [`infra/tofu/`](../infra/tofu/), OpenTofu (`bpg/proxmox`
   + `cloudflare`). The `k3s-node` VM on `vmbr1`, disks, the Proxmox
   *filtering* firewall, foundational Cloudflare records. State is local
   and natively encrypted (OpenTofu ≥1.7), committed to git.
2. **Configure** — [`ansible/`](../ansible/). WireGuard management plane,
   single-IP NAT/DNAT, host + VM OS hardening, the `tank` ZFS mirror, the
   virtiofs share, k3s install (bundled Traefik disabled).
3. **Deliver** — [`clusters/lab/`](../clusters/lab/), Argo CD app-of-apps.
   Everything in-cluster is reconciled from git; no manual `kubectl apply`.

## Target topology

```
OVH dedicated (Proxmox 8) — SINGLE public IP
│  Public inbound: 443 · 32400 · torrent-port  (DNAT → VM)  ·  51820/udp (WireGuard, host)
│  Management (SSH/8006/6443): WireGuard-only, never public
│  Egress: VM → internet via host masquerade (appears as the OVH IP)
│
├─ rpool (ZFS mirror, 2×500GB NVMe)  ── Proxmox root + VM system disks + app CONFIG (fast)
├─ tank  (ZFS mirror, 2×2TB HDD)     ── media library + downloads (bulk, redundant)
│
├─ Proxmox firewall (filtering)      ←── OpenTofu (bpg): datacenter/node/VM rules
├─ WireGuard + NAT/DNAT + OS hardening + ZFS + virtiofs  ←── Ansible
│      └─ WG peers routed into vmbr1 (10.10.10.0/24)
│
└─ VM: k3s-node  (vmbr1 internal IP, behind host NAT)
     ├─ virtiofs mount /data  ← host tank/media (hardlink-friendly single tree)
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
| DNS | **external-dns** (Cloudflare) | Records follow Ingresses |
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

### Management plane

WireGuard listens on public `51820/udp`. SSH(22), Proxmox UI/API(8006), and
the k8s API(6443) are **not** in the public accept list — reachable only
over the WG interface. WG peers are routed into `vmbr1`, so a laptop peer
reaches both host and VM management over the tunnel.

**Bootstrap ordering — never self-strand:** the first Ansible run brings up
WireGuard over the *existing* public SSH, verifies the tunnel end-to-end,
and only then does OpenTofu drop public SSH from the Proxmox firewall.
Reseller-mediated console is the slow last-resort fallback if this ever
goes wrong — see `docs/runbooks/lockout-recovery.md` (Phase 3).

**Exposed public ports:** `443` (Traefik/DNAT) · `32400` (Plex direct/DNAT)
· torrent port (Deluge/DNAT) · `51820/udp` (WireGuard/host). Everything
else default-drop.

### Storage split

- App **configs/DBs** (*arr SQLite, Plex metadata) → VM NVMe via
  **local-path-provisioner**. Fast, doesn't need bulk-disk redundancy at
  this tier (backups cover loss).
- **Media + downloads** → host `tank/media` shared into the VM via
  **virtiofs**, mounted `/data`, exposed to pods as hostPath/local PVs; ZFS
  snapshots/scrubs stay on the host.
- **Single `/data` tree** (`/data/torrents` + `/data/media`, TRaSH layout)
  so Sonarr/Radarr do **atomic hardlink moves** — instant imports, no
  copies, same inode.

## Security / hardening

- **No public management surface** — SSH/PVE/k8s APIs are WireGuard-only;
  the only public ports are 443/32400/torrent/51820-udp.
- OS: SSH key-only + non-root, `fail2ban`, `unattended-upgrades`, sysctl +
  `auditd`, minimal packages (Ansible `hardening` role, host + VM).
- **Firewall in code** — Proxmox filter firewall via Tofu/bpg (default-drop
  posture); NAT via Ansible. WireGuard is verified before SSH is
  restricted (anti-lockout); reseller console is the fallback.
- Least exposure: admin UIs sit behind **Authelia** (TOTP); Plex uses
  plex.tv auth on its own port, outside Traefik/Authelia.
- Secrets are never plaintext: `.sops.yaml` enforces encryption by path,
  `gitleaks` in CI blocks anything that slips through, the age private key
  is held out-of-band (password manager) and injected once at bootstrap.
  Tofu state is natively encrypted even though it's committed. Details:
  [`docs/secrets.md`](secrets.md).
- **Backups** are deferred — later, `vzdump` → NFS on a separate box; the
  age key and the Argo/ksops secret get backed up alongside cluster state.

## Phased implementation

Each phase is its own PR. Full detail and current status in
[`master-plan.md`](../master-plan.md#phased-implementation-each-phase--its-own-pr).

1. **Repo scaffold** *(current)* — structure, `.sops.yaml`, age key, CI
   skeleton, README + this doc.
2. **Provision (Tofu)** — VM, disks, Proxmox filter firewall, Cloudflare
   records.
3. **Configure (Ansible)** — WireGuard first, then NAT/DNAT, hardening,
   `tank`, virtiofs, k3s install.
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
