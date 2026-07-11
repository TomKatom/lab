# ansible

**Layer 2 — Configure.** Brings up the management plane and OS-level state
that OpenTofu doesn't own: WireGuard, single-IP NAT/DNAT, host + VM
hardening, the `tank` ZFS mirror, the virtiofs share, and the k3s install
(bundled Traefik disabled).

Layout:
- `inventory/` — static inventory for the Proxmox host and the k3s VM.
- `group_vars/` — shared, DRY variables; secrets live in `all.sops.yml`
  (SOPS + age, see [`docs/secrets.md`](../docs/secrets.md)).
- `playbooks/` — `proxmox-host.yml`, `k3s-vm.yml`.
- `roles/` — `wireguard`, `network-nat`, `hardening`, `zfs-tank`, `virtiofs`,
  `k3s`.

**Bootstrap ordering matters:** WireGuard is brought up and verified first,
over the still-public SSH; only after the tunnel is confirmed does OpenTofu
drop public SSH access. See
[`docs/architecture.md`](../docs/architecture.md#management-plane).

Not yet implemented — built in Phase 3.
