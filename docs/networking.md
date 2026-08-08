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
  entry in `network_nat_ingress_rules`, each qualified on `ip daddr
  <ovh_public_ip>` and matched on an interface *set*: the uplink, plus `wg1`
  so a guest on the exit tunnel can still reach published services (see
  below).
- `postrouting` (hook priority `srcnat - 5`, ahead of the standard `srcnat`
  hook at 100) — masquerades `network.internal_subnet` and
  `network.wireguard_exit_subnet` traffic leaving the uplink interface, one
  rule each. Running ahead of the standard priority matters: any other
  postrouting chain sharing priority 100 (a legacy iptables-nat table, or
  `proxmox-firewall`'s own) would otherwise be free to commit a null SNAT
  binding first and win the race, silently killing egress masquerade.
- `forward` — two jobs. The `vmbr1` ⇄ uplink accepts are
  belt-and-suspenders, so this role doesn't depend on the PVE firewall's
  `forward_policy` staying `ACCEPT`. The `wg1` block above them is not: it
  is the segmentation of the guest exit tunnel, and it is the only thing
  enforcing it.

The ruleset file declares and immediately deletes its own table before
redefining it, which makes `nft -f` an atomic replace. That matters now that
the forward chain filters: the alternative (the systemd unit's stop/start
pair) would leave a gap on every converge with no isolation rules loaded and
`forward_policy = ACCEPT` in charge.

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

## Two WireGuard tunnels

The host runs two WireGuard interfaces, and they exist for opposite reasons:

| | `wg0` — management | `wg1` — guest exit |
|---|---|---|
| Purpose | reach the lab | reach the internet from Germany |
| Port | `ports.wireguard` (51820/udp) | `ports.wireguard_exit` (51821/udp) |
| Subnet | `network.wireguard_subnet` (10.10.20.0/24) | `network.wireguard_exit_subnet` (10.10.30.0/24) + `network.wireguard_exit_subnet_v6` (fd00:10:30::/64) |
| Client `AllowedIPs` | the two lab subnets (split tunnel) | `0.0.0.0/0, ::/0` (full tunnel) |
| In the `+mgmt` ipset | yes | **never** |
| Reaches the lab | yes, by design | no, by firewall |

Two interfaces rather than two subnets inside one, because the isolation
rules can then match on `iifname "wg1"` — unambiguous, and still correct if
a peer is ever handed the wrong address — and because `wg1` carries its own
server keypair, so a leaked guest config reveals nothing about the admin
tunnel. Both are declared in `config/lab.yml` and rendered from
`wireguard_instances` in `ansible/inventory/group_vars/all.yml`.

## WireGuard management plane

There is no public SSH, no IPMI, and no console — WireGuard is the only way
to reach management surfaces (SSH/22, Proxmox API/8006, k8s API/6443, host
metrics/9100). The tunnel itself is:

- **Interface:** `wg0` on the host (`wireguard_interface` in
  `ansible/inventory/group_vars/all.yml`), listening on public
  `network.ports.wireguard` (`51820/udp`) — the one WireGuard-related port
  that *is* public, since the tunnel has to be reachable to be useful.
- **Subnet:** `network.wireguard_subnet` (`10.10.20.0/24`), host address
  `network.wireguard_host_address` (`10.10.20.1/24`).
- **Peers:** declared in `ansible/inventory/group_vars/all.yml`'s
  `wireguard_peers` — public key + the peer's own `/32` (`address`) only,
  never private key material (each peer generates and holds its own private
  key, the same custody principle used for SSH keys — see
  [`docs/ssh-keys.md`](ssh-keys.md)). An optional per-peer `PresharedKey`
  comes from `wireguard_peer_psks` in the SOPS-encrypted
  `group_vars/proxmox_host.sops.yml`.
- **Peer scoping:** a peer's server-side `AllowedIPs` is its `/32` and
  nothing wider. On the host that field is cryptokey routing *plus* the
  anti-spoof source filter, so a wider value would let a peer forge a source
  inside `internal_subnet` — exactly what the `+mgmt` ipset authorizes by —
  and would collide with any second peer, since a prefix belongs to one peer
  only. `roles/wireguard` asserts the shape before rendering.
- **Routing:** the *client* side is the mirror image: a peer's own config
  routes `network.wireguard_subnet` + `network.internal_subnet`
  (`10.10.10.0/24`, i.e. `vmbr1`) into the tunnel and leaves everything else
  on its local link, so a connected peer reaches both host and VM management
  surfaces over the one tunnel without becoming a default route. Full client
  procedure: [`runbooks/wireguard-peer.md`](runbooks/wireguard-peer.md).

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

## WireGuard guest exit plane

`wg1` is a full-tunnel exit VPN: a guest's default route goes into the
tunnel and its traffic leaves the uplink masqueraded to the host's public
IP, so it appears to originate in Germany. Peers are declared in
`wireguard_exit_peers` (`ansible/inventory/group_vars/all.yml`) — empty in
this repo; the interface listens and nothing can connect without a key.

**The client side is the mirror image of `wg0`'s.** A guest's own config
takes `AllowedIPs = 0.0.0.0/0, ::/0` and `DNS = 1.1.1.1`. The server side is
*not* mirrored: a peer's server-side `AllowedIPs` is still its own `/32` plus
its own `/128`, because on the host that field is cryptokey routing and the
anti-spoof source filter — the same rule and the same reasoning as `wg0`'s
peers.

**Isolation** lives in the `lab-nat` forward chain
([`ansible/roles/network_nat`](../ansible/roles/network_nat)), ordered ahead
of everything else in that chain because nftables is first-match-wins:

1. MSS clamps on both directions of a `wg1` handshake, first because a `set`
   statement is non-terminal and a packet that has already been accepted
   never reaches one. Each rule matches `tcp option maxseg size >
   network_nat_exit_mss` before setting it, so it can only ever clamp
   *down*: `tcp option maxseg size set` is an unconditional write in
   nftables, and raising a correct MSS is worse than not clamping — it
   PMTU-blackholes against any origin that drops ICMP frag-needed. The bound
   is a literal because nftables can only compare against a constant, which
   rules out `rt mtu` (and `rt` resolves the *output* route, so on the
   inbound rule it would resolve the 1500-byte uplink and raise).
2. `iifname "wg1" oifname "vmbr1" ct status dnat accept` — connections that
   prerouting DNAT'd to a published service. A guest resolves
   `plex.tomkatom.com` to the public IP like anyone else, so without this
   (and without `wg1` in the prerouting interface set) the operator's own
   phone could not open Plex while tunnelled. It grants nothing new: those
   ports are world-reachable regardless.
3. `iifname "wg1" oifname "wg1" drop` — peers don't see each other.
4. `iifname "wg1" oifname "<uplink>" ip daddr != { RFC1918, CGNAT,
   link-local, multicast, reserved } accept` — the internet, and only the
   internet.
5. `iifname "wg1" drop` — everything else leaving the tunnel.
6. `oifname "wg1" ct state established,related accept` — the legitimate
   traffic travelling *toward* a guest: internet return packets, and the
   VM's half of a hairpinned service. `related` is load-bearing, because an
   ICMP fragmentation-needed from an origin is RELATED and never
   ESTABLISHED, so omitting it would blackhole path-MTU discovery — the
   failure rule 1 exists to prevent.
7. `oifname "wg1" drop` — no new connection may be opened toward a guest.

Rules 1–5 all match `iifname`, so on their own they would leave the reverse
direction falling through to the chain's `policy accept`: the k3s VM could
open a connection to a guest's tunnel address, and the traffic that
legitimately does reach a guest would be permitted by the absence of a rule
rather than by anything checking a flow exists. Rules 6–7 close that, scoped
to `oifname` rather than written as the more idiomatic unscoped
`ct state established,related accept` + `drop` pair — unscoped, those two
would govern the whole chain, and the first new connection they broke would
be a `wg0` peer's into `vmbr1`, the management path into a host with no
IPMI. This chain must never state-gate that.

Allow-by-exception ending in a `drop`, rather than a blocklist of internal
ranges, specifically so that a subnet added to this lab in future is not
guest-reachable by default. The chain's `policy` is still `accept` (the
`vmbr1` ⇄ uplink accepts rely on it), which is why the block supplies its
own terminators — one per direction.

**What isolation does not cover, and doesn't need to.** Packets addressed to
the host's own addresses never reach the forward hook, so a guest can still
*reach* the host on its always-public ports — nothing listens there, so it
is noise, not exposure. SSH, the Proxmox API, PBS and `node_exporter` are
closed to guests because `network.wireguard_exit_subnet` is absent from
`local.management_sources` and therefore from the `+mgmt` ipset. That
omission is the access control, so `infra/tofu/firewall.tf` carries a
`lifecycle.precondition` that fails the apply if the exit subnet ever appears
in that list — on the ipset resource itself, the one that writes those CIDRs,
so the apply aborts before the exposure exists rather than after.

Rule 7 has the same shape of limit in the other direction: locally generated
packets leave via the output hook and never enter `forward`, so the Proxmox
host itself can still open a connection to a guest. Only routed sources — the
k3s VM, anything else behind `vmbr1` — are covered, which is the whole
population a forward chain was ever able to speak for.

**IPv6 is a deliberate blackhole.** `wg1` carries a ULA and peers take
`::/0` for one reason: an IPv4-only full tunnel silently leaks. A client on
an IPv6-capable carrier would keep routing every IPv6-capable destination
(Google, Cloudflare, Netflix, most CDNs) outside the tunnel over its own
address, and geolocation would still read the client's country — the feature
would look like it works while doing nothing. Capturing that traffic
requires the tunnel to have a v6 address; nothing then carries it anywhere.
That is enforced on every converge, twice, rather than inherited from a
kernel default: `network_nat` pins `net.ipv6.conf.all.forwarding` to `0`, and
its ruleset defines an `ip6 lab-nat` table dropping both directions across
`wg1` for the case where something else flips that knob (a package
`sysctl.d` drop-in, a copied Proxmox snippet, a future v6 experiment) — the
`ip lab-nat` table is IPv4-only and PVE's `forward_policy` is `ACCEPT`, so
without the second mechanism a flipped sysctl would forward a guest's IPv6
past every isolation rule.
[`verify-wireguard.yml`](../ansible/playbooks/verify-wireguard.yml) checks
both. Two consequences worth knowing:

- The drop happens in `ip6_forward()`, *before* any nftables hook, so it
  cannot be turned into a fast `reject`. RFC 8305 clients recover in ~250 ms;
  clients without Happy Eyeballs (many native mobile apps, `curl`, plenty of
  SDKs) wait out a full TCP connect timeout on the IPv6 attempt first.
- Real IPv6 egress is out of scope here and is cheap to add later — a
  sysctl, an `ip6` masquerade rule and a filter rule, once the host's OVH
  IPv6 allocation is verified. The ULA prefix uses RFC 4193's all-zero
  global ID and should be renumbered to a random one before that happens.

**Two things that will surprise an operator.** `*.lab.tomkatom.com` still
resolves publicly to RFC1918, so a tunnelled guest resolving
`pve.lab.tomkatom.com` gets `10.10.10.1` and is then dropped — expected, but
it looks like DNS. And on iOS only one WireGuard tunnel can be active at a
time, so a phone gets management *or* exit, never both; the fix is a `wg0`
peer for the phone and switching tunnels, not widening `wg1`.

## Name resolution

Management endpoints are addressable by name, not just by internal IP:

| Name | Resolves to | Reachable from |
|---|---|---|
| `pve.lab.tomkatom.com` | `10.10.10.1` (host, vmbr1) | WireGuard peer, or vmbr1 |
| `k3s.lab.tomkatom.com` | `10.10.10.10` (k3s-node) | same |
| `runner.lab.tomkatom.com` | `10.10.10.20` (ci-runner) | same |
| `vpn.lab.tomkatom.com` | the OVH public IP | anywhere — it's the tunnel endpoint |

Declared once in `config/lab.yml` (`management_subdomain`,
`management_hosts`, whose `address` is a key into the same `network:` block
the rest of the repo uses) and rendered by
[`infra/tofu/cloudflare.tf`](../infra/tofu/cloudflare.tf) as grey-cloud
(DNS-only) A records.

**These are public records with private targets.** No split-horizon resolver
runs anywhere in this lab — there is nothing to keep alive, and the names
work identically on a connected laptop, a phone, or CI. The trade-offs
accepted for that simplicity:

- the internal layout is public information (RFC1918 addresses, useless
  without a tunnel);
- a resolver with DNS-rebinding protection (some pi-hole/dnsmasq setups, the
  occasional ISP resolver) may strip the private answer, making these names
  fail on that network specifically while the raw IPs still work.

If either becomes a real problem, the upgrade is a resolver bound to the
WireGuard/vmbr1 addresses only, published to peers as `DNS = 10.10.20.1,
lab.tomkatom.com` — WireGuard treats the non-IP entry as a match domain, so
only `lab.tomkatom.com` lookups would traverse the tunnel. Not built, and
not needed while the above holds.

Everything *else* — `plex.`, `sonarr.`, `auth.`, … — keeps resolving to the
public IP and arrives via the DNAT path above, whether or not a tunnel is
up. Those records are external-dns' job (Phase 5); the `lab.` label exists
partly so the two sets can never collide (a `*.tomkatom.com` wildcard
matches exactly one label).

## Port map

From `config/lab.yml`'s `ports:` block — the single place these numbers are
declared; Tofu's filter firewall, Ansible's DNAT rules, and Helm service
ports all read the same values:

| Name | Port | Exposure |
|---|---|---|
| `https` | 443/tcp | Public (DNAT → VM, Traefik) |
| `plex` | 32400/tcp | Public (DNAT → VM, direct-play) |
| `torrent` | 51413/tcp+udp | Public (DNAT → VM, Deluge) |
| `wireguard` | 51820/udp | Public (host, management tunnel endpoint) |
| `wireguard_exit` | 51821/udp | Public (host, guest exit tunnel endpoint) |
| `ssh` | 22/tcp | WireGuard-only |
| `pve_api` | 8006/tcp | WireGuard-only |
| `k8s_api` | 6443/tcp | WireGuard-only |
| `node_exporter` | 9100/tcp | WireGuard-only |

Everything not listed as public above is default-drop at the Proxmox filter
firewall.

"WireGuard-only" is shorthand for the `+mgmt` ipset behind Tofu's
`node_mgmt_rules`, which is `internal_subnet` **plus** `wireguard_subnet` —
and, pointedly, *not* `wireguard_exit_subnet`: the guest tunnel is
`wireguard`-reachable in the sense that it terminates on this host, and
reaches none of these ports.
That matters for `node_exporter` specifically: Prometheus scrapes the host
exporter from the k3s VM (`10.10.10.10`) and clears the same rule an
operator's tunnel does, so the metrics endpoint needs no rule of its own.
It is deliberately absent from `nat_ingress_rules` below — a DNAT entry
there would publish the host's disk, filesystem and process inventory to
the internet.

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
receives public traffic.

Each rule matches `ip daddr <ovh_public_ip>` as well as the port. That
qualifier is load-bearing, not decorative: a DNAT keyed on destination port
alone rewrites anything carrying that port, which was invisible while these
rules only saw the uplink (where traffic is addressed to this host by
definition) and is a hijack on `wg1`, whose clients route `0.0.0.0/0` into
the interface — an unqualified rule would DNAT a guest's connection to *every*
HTTPS site on the internet into the k3s VM, serving Traefik's certificate and
a 404 in place of the site.

The interface set on top of that is scoping, not safety: a peer on `wg1`
resolves these hostnames to the public IP like anyone else, so its packet
arrives on `wg1` carrying a local destination and, without a DNAT, would be
delivered to the host — where nothing listens, and the connection is
*refused* rather than timing out, a symptom that reads as a broken service.
Keeping the set explicit also keeps these rules off `vmbr1`, so the k3s VM's
own outbound connections are excluded twice over.
`ansible/playbooks/proxmox-host.yml`'s `pre_tasks`
is where these name references get resolved to concrete `{proto, port,
destination}` tuples before being handed to the `network_nat` role, which
itself stays a generic DNAT-rule renderer with no knowledge of
`config/lab.yml`'s schema.
