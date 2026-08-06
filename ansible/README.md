# ansible

**Layer 2 — Configure.** Brings up the management plane and OS-level state
that OpenTofu doesn't own: WireGuard, single-IP NAT/DNAT, host + VM
hardening, the `tank` ZFS pool, the virtiofs share, the k3s install
(bundled Traefik disabled), the hypervisor's own metrics, and the backup
tier — Proxmox Backup Server, the host's file-level backup, and the sanoid
ZFS snapshots.

Layout:
- `inventory/hosts.yml` — the Proxmox host (`server`) and the k3s VM
  (`k3s-node`, reached via `ProxyJump` through the host).
- `inventory/group_vars/` — shared, DRY variables. Must live next to
  `hosts.yml` (or under `playbooks/`) — that's where Ansible's
  `host_group_vars` plugin actually looks; a sibling `ansible/group_vars/`
  is silently never loaded. `k3s_node.sops.yml` (SOPS + age, decrypted
  in-memory at load time by the `community.sops` vars plugin — see
  [`docs/secrets.md`](../docs/secrets.md)) holds the Argo CD read-only
  deploy key's private half: the real example of the pattern to follow for
  any future group-scoped secret — group_vars files are named after the
  Ansible inventory *group* they apply to (`k3s_node`, per `hosts.yml`),
  never the individual host.
- `playbooks/` — `site.yml` (the full converge, every configuration
  playbook in dependency order — what a merge to `master` auto-deploys, see
  below), `ping.yml` (connectivity smoke test), `proxmox-host.yml`
  (host-side roles), `verify-wireguard.yml` (the anti-lockout gate below),
  `hardening-vms.yml` (VM hardening), `runner.yml` (registers the
  self-hosted GitHub Actions runner on VM 9001), `virtiofs.yml` (mounts the
  tank/data share in the k3s VM), `k3s-vm.yml` (formats/mounts the scsi1
  data disk and installs single-node k3s in the k3s VM),
  `report-disks.yml` (read-only discovery for new hardware),
  `argocd-bootstrap.yml` (installs Argo CD via a pinned helm binary and
  applies the `root-app` app-of-apps manifest — install only, dispatch-only,
  see `clusters/lab/bootstrap/README.md`).
- `roles/` — role directory names use underscores, not hyphens
  (`network_nat`, not `network-nat`): ansible-lint's `role-name` rule
  (safety profile) rejects hyphens, so new roles follow the same
  convention.

| Role | What it does | Applied by |
|---|---|---|
| `pve_repos` | swaps the subscriber-only PVE/Ceph/PBS enterprise apt sources for the free ones. **Runs first**, before any other role's apt tasks | `proxmox-host.yml` |
| `pve_firewall` | the host-side firewall backend and the sysctl the Proxmox filter firewall needs | `proxmox-host.yml` |
| `wireguard` | one wg-quick interface per `wireguard_instances` entry — `wg0`, the management tunnel, and `wg1`, the guest exit VPN — each interface's host key generated in place and never leaving the box | `proxmox-host.yml` |
| `network_nat` | single-IP NAT/DNAT in nftables (a different hook from the filter firewall Tofu owns), plus the forward-chain rules that isolate `wg1` from the lab | `proxmox-host.yml` |
| `hardening` | SSH, `fail2ban`, `unattended-upgrades`, sysctl, `auditd`. Runs on the host *and* the guests, switched by `hardening_is_pve_host` | `proxmox-host.yml`, `hardening-vms.yml` |
| `zfs_tank` | the `tank` HDD stripe and its datasets | `proxmox-host.yml` |
| `pve_permissions` | the `Terraform` PVE role, user and ACL that Tofu's API token inherits — including the guest-agent grant, which self-gates until the agents answer | `proxmox-host.yml` |
| `zfs_arc` | ARC sizing, host-wide (32 GiB), derived against what the guests reserve | `proxmox-host.yml` |
| `node_exporter` | the hypervisor's own node_exporter plus a textfile collector for ZFS capacity, SMART and the \*arr backup ages — [`docs/observability.md`](../docs/observability.md) | `proxmox-host.yml` |
| `pbs` | Proxmox Backup Server, the B2-backed `lab` datastore, the PVE storage entry, the host's own file-level backup, and the backup metrics collector — [`docs/backups.md`](../docs/backups.md) | `proxmox-host.yml` |
| `zfs_snapshots` | sanoid: the local ZFS rollback tier on `rpool`, derived from PVE's own `backup=` flags | `proxmox-host.yml` |
| `github_runner` | registers the self-hosted Actions runner on VM 9001 | `runner.yml` |
| `virtiofs` | mounts the host's `tank/data` share inside the k3s VM | `virtiofs.yml` |
| `k3s` | formats and mounts the VM's data disks, then installs single-node k3s (bundled Traefik off) | `k3s-vm.yml` |
| `argocd_secrets` | the trust-root cluster Secrets (age key, repo deploy key) | `argocd-bootstrap.yml` |
| `argocd` | installs Argo CD from a pinned helm binary and applies `root-app` | `argocd-bootstrap.yml` |

`proxmox-host.yml`'s role order is a dependency chain, not an accident —
that file's header explains each edge, and the list is deliberately
append-only.

**Bootstrap ordering matters:** WireGuard is brought up and verified first,
over the still-public SSH; only after the tunnel is confirmed does OpenTofu
drop public SSH access. See
[`docs/architecture.md`](../docs/architecture.md#management-plane), and
[`docs/runbooks/provision-new-server.md`](../docs/runbooks/provision-new-server.md)
for the full from-scratch ordering.

## Deploying changes

Merging an ansible/config change to `master` **is** the deploy:
[`.github/workflows/ansible-apply.yml`](../.github/workflows/ansible-apply.yml)
runs `playbooks/site.yml` (the full converge, dependency-ordered) behind
the `production` environment's required-reviewer gate — the operator
approves the run in the Actions UI and never picks a playbook. Host groups
that don't exist yet (mid-bootstrap, rebuilds) are excluded by a
reachability probe so a partial topology still converges green.

`workflow_dispatch` remains for what `site.yml` deliberately excludes —
the verification playbooks (`ping`, `verify-wireguard`), read-only
discovery, and the one-time `argocd-bootstrap` — plus targeted re-runs of
a single playbook when diagnosing something specific.

## Running playbooks

```sh
uv tool install --with ansible ansible-core   # or: pip install --user ansible
cd ansible
# -p is explicit on purpose: some install methods (uv tool among them)
# don't default ansible-galaxy's install path to the standard
# ~/.ansible/collections, which is also the one path all of ansible-core,
# ansible-lint, and pre-commit's isolated ansible-lint hook actually search.
ansible-galaxy collection install -r requirements.yml -p ~/.ansible/collections
./run.sh playbooks/ping.yml                   # connectivity smoke test
```

`run.sh` just makes sure `ansible-playbook` always runs from this directory,
regardless of the caller's cwd — the same guarantee
[`infra/tofu/tofu.sh`](../infra/tofu/tofu.sh) gives `infra/tofu/`. Unlike
that script, it doesn't decrypt anything itself: `inventory/group_vars/*.sops.yml` is
decrypted per-value, in-memory, by the `community.sops` vars plugin
(enabled in `ansible.cfg`) the moment a play needs those vars — nothing is
ever written to disk. `sops` must still be on `PATH` and able to find the
age private key (default `~/.config/sops/age/keys.txt`).

**SSH auth:** `server` (the Proxmox host) accepts root login only from the
key authorized in its `/root/.ssh/authorized_keys` out-of-band during the
original manual install — **not** the `debian` VM key from
`infra/tofu/terraform.tfvars`. Load that key into your agent before running
anything against `server` (`ssh-add ~/.ssh/<that-key>`); OpenSSH only tries
non-default-named identity files when they're offered via an agent, the same
way `infra/tofu/providers.tf`'s `ssh { agent = true }` expects it for Tofu's
own image-download/disk-import SSH. `k3s-node` is reached through `server`
via `ProxyJump`, so the same agent covers both hops (plus the `debian` user
key, which — being the conventional `~/.ssh/id_rsa` — SSH offers
automatically).

## Bringing up WireGuard (anti-lockout gate)

This server has no IPMI/console — a mistake here means ~30 minutes of OVH
rescue mode (see `docs/runbooks/lockout-recovery.md`), so this step is
**always run by a human, deliberately** (see `docs/ssh-keys.md`; this also
means an assistant session should author and validate this code but never
execute it against the live server itself).

1. `./run.sh playbooks/proxmox-host.yml` — first swaps this host's
   subscriber-only PVE/Ceph enterprise apt repos for the free
   no-subscription one (`roles/pve_repos`; this host has no paid Proxmox VE
   subscription, so those repos 401 on every apt update otherwise), then
   installs `wireguard-tools`, generates each interface's private key **in
   place** (it's created with `wg genkey` directly on the host and never
   leaves it — see `roles/wireguard/tasks/main.yml`), and brings up every
   entry in `wireguard_instances` — `wg0`, the management tunnel this
   bootstrap is about, and `wg1`, the guest exit VPN (which ships with no
   peers, so it listens and nothing can connect). Note the printed host
   public key for `wg0`; they are printed per interface.
2. Add your own peer: generate a keypair and a preshared key locally (`wg
   genkey | tee privatekey | wg pubkey > publickey`, `wg genpsk` — keep
   `privatekey` off this repo entirely), add an entry to `wireguard_peers`
   in `inventory/group_vars/all.yml` (public key + your own unique `/32`
   `address`) and the PSK to `wireguard_peer_psks` in the SOPS-encrypted
   `inventory/group_vars/proxmox_host.sops.yml`, then re-run step 1 so the
   host picks up the new peer.
3. Bring up your own local WireGuard interface using the host's public key
   from step 1 and an endpoint of `<ovh_public_ip>:<ports.wireguard>`. Your
   *client* `AllowedIPs` is the two lab subnets (split tunnel), which is not
   the same field as the peer's server-side `/32` — see
   [`docs/runbooks/wireguard-peer.md`](../docs/runbooks/wireguard-peer.md)
   for the full client config and why the two differ.
4. `./run.sh playbooks/verify-wireguard.yml` — **must pass** before anyone
   flips `restrict_management` in `infra/tofu/terraform.tfvars`. It checks a
   live peer handshake, that the host is reachable over the tunnel itself,
   and that both the host and the VM are reachable over `vmbr1` — read
   `docs/architecture.md#management-plane` for why each check exists.

Only once step 4 passes clean is it safe to move on to dropping public SSH.
