# ansible

**Layer 2 — Configure.** Brings up the management plane and OS-level state
that OpenTofu doesn't own: WireGuard, single-IP NAT/DNAT, host + VM
hardening, the `tank` ZFS pool, the virtiofs share, and the k3s install
(bundled Traefik disabled).

Layout:
- `inventory/hosts.yml` — the Proxmox host (`server`) and the k3s VM
  (`k3s-node`, reached via `ProxyJump` through the host).
- `inventory/group_vars/` — shared, DRY variables. Must live next to
  `hosts.yml` (or under `playbooks/`) — that's where Ansible's
  `host_group_vars` plugin actually looks; a sibling `ansible/group_vars/`
  is silently never loaded. No role currently needs a secret, so there's no
  `*.sops.yml` file today; if one ever does, `all.sops.yml` (SOPS + age,
  decrypted in-memory at load time by the `community.sops` vars plugin —
  see [`docs/secrets.md`](../docs/secrets.md)) is the pattern to follow.
- `playbooks/` — `ping.yml` (connectivity smoke test), `proxmox-host.yml`
  (host-side roles), `verify-wireguard.yml` (the anti-lockout gate below),
  `hardening-vms.yml` (VM hardening), `virtiofs.yml` (mounts the tank/data
  share in the k3s VM); `k3s-vm.yml` lands with the `k3s` role.
- `roles/` — `pve_repos` (apt repo fix, runs first), `wireguard`,
  `network_nat`, `hardening`, `zfs_tank`, `virtiofs` done; `k3s` lands
  incrementally, one PR per role. Role directory names use underscores, not
  hyphens (`network_nat`, not `network-nat`) — ansible-lint's `role-name`
  rule (safety profile) rejects hyphens in role names, so later roles should
  follow the same convention.

**Bootstrap ordering matters:** WireGuard is brought up and verified first,
over the still-public SSH; only after the tunnel is confirmed does OpenTofu
drop public SSH access. See
[`docs/architecture.md`](../docs/architecture.md#management-plane).

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
   installs `wireguard-tools`, generates the host's private key **in
   place** (it's created with `wg genkey` directly on the host and never
   leaves it — see `roles/wireguard/tasks/main.yml`), and brings up `wg0`.
   Note the printed host public key.
2. Add your own peer: generate a keypair locally (`wg genkey | tee
   privatekey | wg pubkey > publickey` — keep `privatekey` off this repo
   entirely), add an entry to `wireguard_peers` in `inventory/group_vars/all.yml` with
   your public key, then re-run step 1 so the host picks up the new peer.
3. Bring up your own local WireGuard interface using the host's public key
   from step 1 and an endpoint of `<ovh_public_ip>:<ports.wireguard>`.
4. `./run.sh playbooks/verify-wireguard.yml` — **must pass** before anyone
   flips `restrict_management` in `infra/tofu/terraform.tfvars`. It checks a
   live peer handshake, that the host is reachable over the tunnel itself,
   and that both the host and the VM are reachable over `vmbr1` — read
   `docs/architecture.md#management-plane` for why each check exists.

Only once step 4 passes clean is it safe to move on to dropping public SSH.
