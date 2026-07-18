# ansible

**Layer 2 — Configure.** Brings up the management plane and OS-level state
that OpenTofu doesn't own: WireGuard, single-IP NAT/DNAT, host + VM
hardening, the `tank` ZFS pool, the virtiofs share, and the k3s install
(bundled Traefik disabled).

Layout:
- `inventory/hosts.yml` — the Proxmox host (`server`) and the k3s VM
  (`k3s-node`, reached via `ProxyJump` through the host).
- `group_vars/` — shared, DRY variables; secrets live in `all.sops.yml`
  (SOPS + age, decrypted in-memory at load time by the `community.sops`
  vars plugin — see [`docs/secrets.md`](../docs/secrets.md)).
- `playbooks/` — `ping.yml` (connectivity smoke test), `proxmox-host.yml`,
  `k3s-vm.yml` (the latter two land with their roles).
- `roles/` — `wireguard`, `network-nat`, `hardening`, `zfs-tank`, `virtiofs`,
  `k3s` (land incrementally, one PR per role).

**Bootstrap ordering matters:** WireGuard is brought up and verified first,
over the still-public SSH; only after the tunnel is confirmed does OpenTofu
drop public SSH access. See
[`docs/architecture.md`](../docs/architecture.md#management-plane).

## Running playbooks

```sh
uv tool install --with ansible ansible-core   # or: pip install --user ansible
cd ansible
ansible-galaxy collection install -r requirements.yml
./run.sh playbooks/ping.yml                   # connectivity smoke test
```

`run.sh` just makes sure `ansible-playbook` always runs from this directory,
regardless of the caller's cwd — the same guarantee
[`infra/tofu/tofu.sh`](../infra/tofu/tofu.sh) gives `infra/tofu/`. Unlike
that script, it doesn't decrypt anything itself: `group_vars/*.sops.yml` is
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

Not yet implemented — the roles above land in later Phase 3 PRs.
