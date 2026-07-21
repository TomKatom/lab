# Networking

Reference for how traffic reaches and leaves the lab. This is a networking-
specific companion to [`docs/architecture.md`](architecture.md) — it goes
deeper on the mechanics; `architecture.md` stays the canonical narrative and
this doc cross-references it rather than repeating it. Values quoted below
come from [`config/lab.yml`](../config/lab.yml), the single source of truth
for these facts across Tofu/Ansible/Helm.

## Single-IP NAT model

The host owns the single OVH public IP. There is no per-guest public
address: the `k3s-node` VM sits on the internal bridge `vmbr1`
(`10.10.10.0/24`, `network.internal_subnet` in `config/lab.yml`), and the
host's nftables translates addresses in both directions:

- **Ingress (DNAT):** a handful of public ports are forwarded to the VM's
  internal IP (`network.vm_ip_address`, `10.10.10.10`).
- **Egress (masquerade):** VM-originated traffic leaving via the uplink is
  rewritten to the host's public IP, so e.g. Deluge announces/seeds from the
  real OVH IP rather than an unroutable internal address.

This is implemented by the Ansible `network_nat` role
([`ansible/roles/network_nat`](../ansible/roles/network_nat)), which renders
a dedicated `ip lab-nat` nftables table (deliberately its own table, not
`inet`/`bridge`, so it can never collide with PVE's own
`proxmox-firewall*` tables or `/etc/nftables.conf`):

- `prerouting` (hook priority `dstnat`, before routing) — one DNAT rule per
  entry in `network_nat_ingress_rules`.
- `postrouting` (hook priority `srcnat - 5`, ahead of the standard `srcnat`
  hook at 100) — masquerades `network.internal_subnet` traffic leaving the
  uplink interface. Running ahead of the standard priority matters: any
  other postrouting chain sharing priority 100 (a legacy iptables-nat table,
  or `proxmox-firewall`'s own) would otherwise be free to commit a null SNAT
  binding first and win the race, silently killing egress masquerade.
- `forward` — belt-and-suspenders accept between `vmbr1` and the uplink, so
  this role doesn't depend on the PVE firewall's `forward_policy` staying
  `ACCEPT`.

This NAT/DNAT layer is address translation only. Packet **filtering** —
what's actually allowed to reach an interface or vNIC in the first place —
is a separate concern owned by OpenTofu/`bpg` (the Proxmox filter firewall).
The two live at different nftables hooks and don't conflict, but a DNAT'd
packet still has to clear the VM-level accept rule afterward. See
[`docs/architecture.md#single-ip-nat-model`](architecture.md#single-ip-nat-model)
for why this split exists and how it interacts with PVE's firewall backend
(the `pve_firewall` role pins the nftables backend specifically because the
legacy iptables backend breaks this masquerade — see that role's task
comments for the full failure mode).

## WireGuard management plane

There is no public SSH, no IPMI, and no console — WireGuard is the only way
to reach management surfaces (SSH/22, Proxmox API/8006, k8s API/6443). The
tunnel itself is:

- **Interface:** `wg0` on the host (`wireguard_interface` in
  `ansible/inventory/group_vars/all.yml`), listening on public
  `network.ports.wireguard` (`51820/udp`) — the one WireGuard-related port
  that *is* public, since the tunnel has to be reachable to be useful.
- **Subnet:** `network.wireguard_subnet` (`10.10.20.0/24`), host address
  `network.wireguard_host_address` (`10.10.20.1/24`).
- **Peers:** declared in `ansible/inventory/group_vars/all.yml`'s
  `wireguard_peers` — public key + `allowed_ips` only, never private key
  material (each peer generates and holds its own private key, the same
  custody principle used for SSH keys — see
  [`docs/ssh-keys.md`](ssh-keys.md)).
- **Routing:** peers are routed into `vmbr1`
  (`network.internal_subnet`, `10.10.10.0/24`) as well as the WireGuard
  subnet itself, so a connected peer reaches both host and VM management
  surfaces over the one tunnel.

**Anti-lockout verify gate.** Because there's no console fallback short of a
slow reseller round-trip, the tunnel must be proven live *before* anything
drops public SSH. The sequence, enforced procedurally:

1. The `wireguard` role brings up `wg0` over the host's still-public SSH.
2. [`ansible/playbooks/verify-wireguard.yml`](../ansible/playbooks/verify-wireguard.yml)
   asserts at least one peer has completed a real handshake (`wg show wg0
   latest-handshakes`) — not just that the interface exists.
3. Only once that playbook passes does `infra/tofu`'s `restrict_management`
   variable get flipped to `true`, narrowing the SSH/Proxmox-API/k8s-API
   accept rules' `source` from "any" down to the WireGuard-reachable `mgmt`
   ipset.

See [`docs/architecture.md#management-plane`](architecture.md#management-plane)
for the full anti-lockout mechanism, including the firewall-ordering half of
it (why a correct rule set alone doesn't guarantee safe ordering against the
default-DROP policy).

## Port map

From `config/lab.yml`'s `ports:` block — the single place these numbers are
declared; Tofu's filter firewall, Ansible's DNAT rules, and Helm service
ports all read the same values:

| Name | Port | Exposure |
|---|---|---|
| `https` | 443/tcp | Public (DNAT → VM, Traefik) |
| `plex` | 32400/tcp | Public (DNAT → VM, direct-play) |
| `torrent` | 51413/tcp+udp | Public (DNAT → VM, Deluge) |
| `wireguard` | 51820/udp | Public (host, tunnel endpoint) |
| `ssh` | 22/tcp | WireGuard-only |
| `pve_api` | 8006/tcp | WireGuard-only |
| `k8s_api` | 6443/tcp | WireGuard-only |

Everything not listed as public above is default-drop at the Proxmox filter
firewall.

## DNAT ingress rules

`config/lab.yml`'s `nat_ingress_rules` is the single declared list of
inbound forwards — both Tofu's host firewall accept rules and Ansible's
`network_nat` DNAT rules read it, referencing `ports`/`network` by name
rather than raw numbers/IPs so a port renumber or destination change is one
edit:

| Comment | Proto | Port | Destination |
|---|---|---|---|
| HTTPS | tcp | 443 | `vm_ip_address` (10.10.10.10) |
| Plex | tcp | 32400 | `vm_ip_address` (10.10.10.10) |
| Torrent TCP | tcp | 51413 | `vm_ip_address` (10.10.10.10) |
| Torrent UDP | udp | 51413 | `vm_ip_address` (10.10.10.10) |

All four forward to the k3s VM — there is currently only one guest that
receives public traffic. `ansible/playbooks/proxmox-host.yml`'s `pre_tasks`
is where these name references get resolved to concrete `{proto, port,
destination}` tuples before being handed to the `network_nat` role, which
itself stays a generic DNAT-rule renderer with no knowledge of
`config/lab.yml`'s schema.
