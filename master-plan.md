# Lab — GitOps IaC Architecture for a Proxmox Media Server

## Context

This is a fresh repo that will become the **single source of truth** for a personal
dedicated server (OVH, E5-1650v4 / 128 GB RAM / 2×500 GB NVMe + 2×2 TB HDD) with a
**single public IP**. Goal: run a seedbox + media stack (Deluge, the *arrs, Plex) under
strict IaC/GitOps principles — everything declarative, versioned, reconciled from git,
hardened, with no committed secrets. Domain: **tomkatom.com** (Cloudflare DNS).

Proxmox is already installed; the 2×500 GB NVMe are a ZFS pool `rpool` serving as the
Proxmox root. Everything else is greenfield and must be built as code.

**Access model:** no IPMI/console — access is SSH-based, and physical intervention means a
slow reseller round-trip. So management must not be self-strandable, but a mistake is
recoverable (just slow). Management is via **WireGuard**, not public SSH.

### Decisions locked with the user
- **Runtime:** single-node **k3s** in a hardened VM; **Argo CD** (app-of-apps) as the GitOps engine.
- **Packaging:** **Helm-primary** — apps via `bjw-s/app-template` (one small `values.yaml` each, DRY across ~7 near-identical apps); **Kustomize only for ksops-encrypted Secrets** + light overlays. Apps consume secrets via `existingSecret`.
- **Secrets:** **SOPS + age** — one age key covers k8s Secrets *and* OpenTofu/Ansible secrets. Argo decrypts via the **ksops** Kustomize plugin.
- **Tofu state:** **local backend + OpenTofu native state encryption** (≥1.7), encrypted state committed to git. No external object store.
- **Single public IP → NAT:** the k3s VM sits on an internal bridge and is reached through the host's one OVH IP via **DNAT (inbound) + masquerade (egress)**.
- **Management plane:** **WireGuard on the host** — SSH(22)/Proxmox API(8006)/k8s API(6443) reachable only over the tunnel; **no public SSH**. WG peers get a route into the internal bridge.
- **Firewall split:** packet **filtering** → OpenTofu/`bpg` (Proxmox firewall, filters at the vNIC); **NAT/DNAT port-forwarding** → Ansible (`network-nat` role, nftables). They live in different nftables hooks and coexist.
- **Torrents:** Deluge egresses via host masquerade → seeds from the **direct OVH IP** (no VPN); inbound torrent port DNAT'd to Deluge.
- **HDD layout:** **ZFS mirror** (`tank`, 2 TB usable, 1-disk fault tolerant) for media + downloads.
- **Ingress/auth/TLS:** **Traefik + Authelia** forward-auth on **:443**; **wildcard cert `*.tomkatom.com`** via cert-manager (Let's Encrypt **DNS-01 / Cloudflare**); per-service subdomains (`plex.`, `sonarr.`, `auth.`…). external-dns manages records.
- **Plex:** **direct-play only, no transcoding** → modest resources, no GPU concern, no transcode scratch; served on its own port (not behind Authelia/Traefik auth).
- **Observability:** deferred (placeholder namespace now).
- **Backups:** deferred — later, `vzdump` → NFS share on a separate box.
- Upstream givens: GitHub repo + CI/CD, Cloudflare DNS, trunk-based dev, DRY config.
- **Cross-tool DRY:** facts shared by ≥2 layers (domain, internal/WireGuard
  subnets, VM IP, service ports) live once in `config/lab.yml`; OpenTofu,
  Ansible, and Helm/Argo all read that file rather than redeclaring values.
  `tofu output` still hands Ansible *realized* identifiers (VM id/name) —
  it can't reach the pull-based Argo/Helm layer, which is why the shared
  facts live in a plain file instead.

---

## Target Architecture

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

**Three IaC layers, one repo:**
1. **Provision** (OpenTofu, `bpg/proxmox` + `cloudflare`) — k3s VM (attached to `vmbr1`), disks, **Proxmox filtering firewall**, foundational Cloudflare records. State local + natively encrypted.
2. **Configure** (Ansible) — WireGuard mgmt plane, **NAT/DNAT for the single IP**, Proxmox host + VM OS hardening, `tank` mirror, virtiofs share, k3s install (bundled Traefik off).
3. **Deliver** (Argo CD) — everything in-cluster reconciled from git.

---

## Tooling (all pinned, all declarative)

| Concern | Tool | Why |
|---|---|---|
| Provisioning | **OpenTofu** + `bpg/proxmox`, `cloudflare` | Open-source; bpg is the maintained Proxmox provider (also manages the PVE filter firewall) |
| Tofu state | **local + native state encryption** (OpenTofu ≥1.7), committed to git | No external vendor; git stays source of truth |
| Config mgmt | **Ansible** (+ `community.sops`) | WireGuard, NAT/DNAT, OS hardening, ZFS, k3s bootstrap |
| Mgmt access | **WireGuard** (on host) | SSH/PVE/k8s APIs private; no public SSH |
| Single-IP sharing | **nftables NAT/DNAT** (Ansible `network-nat`) | Forwards 443/32400/torrent to VM; masquerades egress |
| Cluster | **k3s** (single node, bundled Traefik disabled) | Lightweight k8s; Traefik managed via Argo; klipper servicelb (no MetalLB) |
| GitOps | **Argo CD** (app-of-apps) | Chosen; UI + drift/sync visibility |
| Packaging | **Helm** (`bjw-s/app-template`) + **Kustomize** (secrets only) | DRY across near-identical apps; ksops needs Kustomize |
| Secrets | **SOPS + age** + **ksops** | One key for k8s + Tofu + Ansible |
| Ingress/TLS | **Traefik** + **cert-manager** (LE DNS-01 Cloudflare, `*.tomkatom.com`) | Wildcard cert, no open :80 |
| DNS | **external-dns** (Cloudflare) | Records follow Ingresses |
| AuthN/Z | **Authelia** (forward-auth, file users + TOTP, SQLite) | Protects *arr/deluge UIs |
| Dep updates | **Renovate** | Automated chart/image bump PRs |
| CI guards | **GitHub Actions** + **gitleaks** | Validate + block plaintext secrets |

---

## Proposed repo structure

```
lab/
├─ README.md                     # architecture + quickstart
├─ .sops.yaml                    # age recipients + path_regex encryption rules
├─ .github/workflows/ci.yml      # fmt/validate/lint/helm-template|kubeconform/gitleaks
├─ renovate.json
├─ config/lab.yml                # cross-tool shared facts (domain, subnet, ports)
├─ docs/                         # git-tracked workflow + runbooks
│   ├─ architecture.md  bootstrap.md  secrets.md  networking.md
│   └─ runbooks/ (dr, restore, disk-replace, lockout-recovery)
├─ infra/tofu/                   # Layer 1: provisioning
│   ├─ versions.tf providers.tf  # encryption block (age), local backend
│   ├─ vm-k3s.tf storage.tf network.tf firewall.tf cloudflare.tf
│   ├─ variables.tf outputs.tf
│   ├─ terraform.tfstate         # committed, natively ENCRYPTED
│   └─ secrets.sops.tfvars.json  # Proxmox + Cloudflare tokens (encrypted)
├─ ansible/                      # Layer 2: configuration
│   ├─ inventory/hosts.yml
│   ├─ group_vars/all.sops.yml   # shared vars/secrets (DRY, encrypted)
│   ├─ playbooks/{proxmox-host,k3s-vm}.yml
│   └─ roles/{wireguard,network-nat,hardening,zfs-tank,virtiofs,k3s}
└─ clusters/lab/                 # Layer 3: Argo CD (single source of truth)
    ├─ bootstrap/                # argocd helm values + ksops repo-server patch + root app
    │   ├─ argocd-values.yaml  root-app.yaml
    ├─ platform/                 # cert-manager, external-dns, traefik, authelia, secrets(ksops), monitoring(placeholder)
    └─ apps/                     # plex, prowlarr, sonarr, radarr, bazarr, deluge, overseerr (app-template values)
```

DRY: values shared across ≥2 layers (domain `tomkatom.com`, internal subnet,
service ports) are defined once in `config/lab.yml` and referenced by Tofu
locals, Ansible `group_vars`, and cluster-wide Helm/Kustomize values — never
duplicated. Layer-specific values (timezone, storage paths, resource
classes) stay declared in that layer.

---

## Networking & storage (the trickiest parts)

**Single-IP NAT model.** The host owns the one OVH IP on the public interface. The VM is on
an internal NAT bridge `vmbr1` (`10.10.10.0/24`). Host nftables (Ansible `network-nat`):
- **DNAT** public `443 / 32400 / torrent-port` → the VM's internal IP.
- **Masquerade** VM egress → appears as the OVH IP (so Deluge seeds from the datacenter IP).
- The Proxmox **filter** firewall (Tofu/bpg) governs what's accepted on each interface/vNIC; the NAT table (Ansible) governs address translation. Different hooks, no conflict — a DNAT'd packet is still checked by the VM-level accept rule.

**Management plane (WireGuard on the host).** WG listens on public `51820/udp`. SSH(22),
Proxmox UI/API(8006), and k8s API(6443) are **not** in the public accept list — reachable only
over the WG interface. WG peers are routed into `vmbr1`, so your laptop reaches host *and* VM
management over the tunnel. Keys via SOPS; interface via Ansible `wireguard` role.
**Bootstrap ordering:** first Ansible run brings up WG over the *existing* public SSH, verifies
the tunnel end-to-end, and only then Tofu drops public SSH — never strand yourself.
Reseller-mediated console is the slow last-resort fallback.

**Exposed public ports:** `443` (Traefik/DNAT) · `32400` (Plex direct/DNAT) · torrent port
(Deluge/DNAT) · `51820/udp` (WireGuard/host). Everything else default-drop.

**Storage split (performance + correctness):**
- App **configs/DBs** (*arr SQLite, Plex metadata) → VM NVMe via **local-path-provisioner**.
- **Media + downloads** → host `tank/media` shared into the VM via **virtiofs**, mounted `/data`, exposed to pods as hostPath/local PVs; ZFS snapshots/scrubs stay on the host.
- **Single `/data` tree** (`/data/torrents` + `/data/media`) so Sonarr/Radarr do **atomic hardlink moves** (TRaSH layout) — instant imports, no copies.

---

## CI/CD & GitOps flow

- **Pull-based delivery:** merge to `master` → **Argo CD auto-syncs** the cluster. No push into the server for app changes.
- **GitHub Actions (PR gate):** `tofu fmt/validate`, `ansible-lint` + `yamllint`, `helm template | kubeconform` (+ `kustomize build | kubeconform` for secrets/overlays), and **gitleaks** (fails on any unencrypted secret). Trunk-based: short-lived branches → PR → squash to `main`.
- **Infra changes (Tofu/Ansible)** reach the private Proxmox API over **WireGuard** from a self-hosted runner (or your workstation), applied on merge.
- **Renovate** opens dependency-bump PRs; CI validates; you merge; Argo rolls out.

---

## Security / hardening (SecOps)

- **No public management surface** — SSH/PVE/k8s APIs WG-only; public = 443/32400/torrent/51820udp.
- OS: SSH key-only + non-root, `fail2ban`, `unattended-upgrades`, sysctl + `auditd`, minimal packages (Ansible `hardening` role, host + VM).
- **Firewall in code** — Proxmox filter firewall via Tofu/bpg (default-drop); NAT via Ansible. WG verified before SSH is restricted (anti-lockout); reseller console is the fallback.
- **Internal segmentation / DMZ (TODO — not yet implemented):** guests currently run with **no per-VM firewall** (`firewall = false` on the vNIC), because a per-VM firewall bridge is incompatible with host egress NAT — with it enabled the guests lose all internet access (see `infra/tofu/firewall.tf` "VM (guest) firewall — intentionally absent"). Consequence: any WireGuard peer has unrestricted L3 reach into the internal network, and there is no east-west control between guests. **Still needed:** a way to deny/limit access *within* the internal network — host-level forward filtering, or a proper DMZ segment — so guest ingress is least-privilege again without sacrificing egress NAT. The guests are not publicly exposed in the meantime (no public IP; internet reaches them only via host DNAT, management only over WireGuard).
- Least exposure: admin UIs behind **Authelia** (TOTP); Plex uses plex.tv auth on its own port.
- Secrets never plaintext: `.sops.yaml` enforces encryption by path; gitleaks in CI; age private key held **out-of-band** (password manager), injected once at bootstrap; **Tofu state natively encrypted** even though committed.
- **Backups (deferred):** later, `vzdump` → NFS on a separate box; also back up the age key + Argo/ksops secret. `docs/runbooks/lockout-recovery.md` covers the reseller path.

---

## Phased implementation (each phase = its own PR)

1. **Repo scaffold** — structure above, `.sops.yaml`, age key generated, CI skeleton (fmt/lint/gitleaks), README + `docs/architecture.md`.
2. **Provision (Tofu)** — providers + **native state encryption**, `bpg` VM `k3s-node` on `vmbr1`, disks, **Proxmox filter firewall**, foundational Cloudflare records (`*.tomkatom.com`). `tofu plan` green in CI.
3. **Configure (Ansible)** — **WireGuard first** (verify, then Tofu drops public SSH), **NAT/DNAT** for the single IP, host hardening, `tank` mirror, virtiofs, VM hardening, install k3s (Traefik off). Also install/enable `qemu-guest-agent` in the VM, then grant the `Terraform` Proxmox role `VM.GuestAgent.Audit` (see `docs/architecture.md#guest-agent` — granting it before the agent exists hangs `tofu plan`/`apply`).
4. **Bootstrap Argo CD** — helm install + **ksops** repo-server patch; create `sops-age-key` secret from the age key; apply `root-app.yaml`. Documented in `docs/bootstrap.md`.
5. **Platform apps** — cert-manager (Cloudflare DNS-01, wildcard `*.tomkatom.com`), external-dns, Traefik (:443), Authelia (`auth.tomkatom.com`). Verify a test Ingress → valid cert + auth.
6. **Media apps** — Prowlarr → Sonarr/Radarr/Bazarr → Deluge (torrent port) → Plex (direct port) → Overseerr, on the shared `/data` tree with hardlinks.
7. **Observability (later)** — kube-prometheus-stack + Loki + node/pve exporters into the placeholder namespace.
8. **Backups (later)** — `vzdump` → NFS on a separate box.

---

## Open items / prerequisites (confirm during Phase 1–2)

- **Cloudflare API token** (`Zone:DNS:Edit` + `Zone:Read`, for cert-manager + external-dns) and a **Proxmox API token** for Tofu — both SOPS-encrypted.
- **WireGuard**: your laptop peer public key (server port defaults to 51820/udp).
- **Internal subnet** choice for `vmbr1` (default `10.10.10.0/24`), timezone, Authelia user(s).
- Self-hosted Actions runner placement for infra applies (over WG) vs applying from workstation.

---

## Verification

- **CI:** every PR runs `tofu validate`, `helm template | kubeconform`, `kustomize build | kubeconform`, `ansible-lint`, `gitleaks` — all green (manifests render; no plaintext secrets).
- **Management plane:** with WG **down**, SSH/8006/6443 are unreachable from the internet; with WG **up**, all reachable — confirming no public management surface and no lockout.
- **NAT:** from outside, `443/32400/torrent` reach the VM services through the host IP; Deluge's outbound/announce IP equals the OVH IP.
- **Provisioning:** `tofu plan` shows expected VM/DNS/firewall; `tofu apply` on merge; committed state file is unreadable without the age key.
- **Cluster:** `argocd app list` all **Synced/Healthy**; `kubectl get pods -A` all Running.
- **Secrets:** decrypt a `*.sops.yaml`, confirm Argo/ksops materializes the Secret and an app consumes it via `existingSecret`.
- **Ingress/TLS/auth:** browse `sonarr.tomkatom.com` → Authelia login → HTTPS with a valid `*.tomkatom.com` cert; external-dns created the record automatically.
- **Media pipeline:** Prowlarr indexer → Sonarr/Radarr search → Deluge download → **hardlink** import into `/data/media` (same inode, no copy) → **Plex direct-plays** to a remote client (confirm "Direct Play", zero transcode sessions).
- **Security:** external port scan shows only 443/32400/torrent/51820-udp open; `tank` reports a healthy mirror.
