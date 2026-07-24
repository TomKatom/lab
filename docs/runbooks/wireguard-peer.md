# Runbook: adding or reconfiguring a WireGuard peer

How an operator machine (laptop, phone) gets a working tunnel into the lab.
WireGuard is the *only* path to SSH(22), the Proxmox UI/API(8006) and the
k8s API(6443) — there is no public SSH and no IPMI/console — so this is also
the procedure whose output the anti-lockout gate
([`verify-wireguard.yml`](../../ansible/playbooks/verify-wireguard.yml))
depends on.

The server half is code: `ansible/roles/wireguard` renders `/etc/wireguard/
wg0.conf` from `wireguard_peers` (`ansible/inventory/group_vars/all.yml`).
The client half is a file on your own machine — deliberately *not* generated
from this repo, because a peer's private key must never leave the device it
belongs to.

---

## 0. The two `AllowedIPs` mean different things

The single most common way to get this wrong. Both sides of a WireGuard
tunnel have an `AllowedIPs` field and they are not the same setting:

| | Server side (`wireguard_peers[].address`) | Client side (your config) |
|---|---|---|
| Written where | this repo, rendered into `wg0.conf` | your own `.conf` / the macOS app |
| Means | which source addresses this peer may send from, and what the host encrypts back to it | which destination prefixes your machine routes *into* the tunnel |
| Correct value | the peer's own `/32`, e.g. `10.10.20.2/32` | `10.10.20.0/24, 10.10.10.0/24` |

Server side must stay one `/32` per peer. A prefix belongs to exactly one
peer, so two peers claiming overlapping ranges is not an error — the last
one configured silently steals it and the earlier peer goes dark. Anything
wider than the peer's own address also lets that peer forge a source inside
`10.10.10.0/24`, which is what the firewall's `+mgmt` ipset authorizes by.
`roles/wireguard` asserts the `/32`-and-unique shape before rendering.

Client side stays a **split tunnel**: only the two lab subnets go through
WireGuard, everything else keeps using your local link. Do not use
`0.0.0.0/0` — it would push all your traffic through the lab, breaking Plex
direct-play from that machine and putting your general browsing behind the
lab's single public IP for no benefit.

---

## 1. Generate the peer's keypair (on the peer, once)

```sh
wg genkey | tee privatekey | wg pubkey > publickey
```

`privatekey` never leaves the machine and never enters this repo (`.gitignore`
covers both filenames as a backstop). Only `publickey` gets committed.

## 2. Generate the peer's preshared key

```sh
wg genpsk
```

A PSK is a symmetric secret mixed into the handshake on top of the public-key
exchange. It means a recorded session stays undecryptable to an attacker who
later breaks Curve25519, and it makes the tunnel unusable to anyone holding
only the two public keys. It is optional per peer — but it costs one line, so
use it.

Unlike the private key, this value is shared: the *same* string goes into the
repo (SOPS-encrypted) and into the peer's own config.

## 3. PR the peer into the repo

Two files, one PR:

```yaml
# ansible/inventory/group_vars/all.yml
wireguard_peers:
  - name: my-laptop
    public_key: "<contents of publickey>"
    address: 10.10.20.3/32        # unique /32 inside network.wireguard_subnet
```

```sh
# ansible/inventory/group_vars/proxmox_host.sops.yml — encrypted; edit via sops
sops ansible/inventory/group_vars/proxmox_host.sops.yml
```

```yaml
wireguard_peer_psks:
  my-laptop: "<output of wg genpsk>"    # keyed by the peer's `name` above
```

Merging runs the gated converge (`site.yml`), which re-renders `wg0.conf` and
restarts `wg-quick@wg0`. That restart is safe to trigger from CI: the
self-hosted runner reaches the host over `vmbr1` (10.10.10.1), not through
the tunnel it is restarting.

**Existing peers keep working across that restart, with one exception —
adding or changing a PSK.** A PSK mismatch is a hard handshake failure, so
the moment the server picks up a PSK your client must have the same one.
Have the client config ready *before* you approve the converge (§4), then
reconnect.

## 4. Write the client config

```ini
[Interface]
PrivateKey = <contents of privatekey>
Address    = 10.10.20.3/32

[Peer]
# lab — OVH / Proxmox host
PublicKey    = <host public key, printed by the wireguard role>
PresharedKey = <the wg genpsk value from §2>
Endpoint     = vpn.lab.tomkatom.com:51820
AllowedIPs   = 10.10.20.0/24, 10.10.10.0/24
PersistentKeepalive = 25
```

- **`Endpoint` by name** — `vpn.lab.tomkatom.com` is a Tofu-managed record
  (`infra/tofu/cloudflare.tf`) pointing at the OVH public IP, so a change of
  public address doesn't mean re-issuing every peer config. WireGuard
  resolves it when the tunnel comes up, not continuously: after an IP change
  the client needs a reconnect, not an edit. The raw
  `145.239.3.55:51820` still works if you ever need to bypass DNS to
  diagnose something.

- **Host public key** — printed by the converge ("Show the host's WireGuard
  public key"). The host's private key is generated in place on the server
  and never leaves it, so this is the only half you ever handle.
- **`Address`** — the same `/32` you declared in §3. `/32`, not `/24`: your
  machine owns exactly one tunnel address, and a `/24` would make it claim
  the whole peer subnet as directly connected.
- **`PersistentKeepalive = 25`** — belongs on the client, the side behind
  NAT. It keeps the NAT mapping open so the host can reach *you*
  unprompted. The server does not set it.
- **MTU** — leave unset. The default 1420 is right for this path; only
  lower it if you find yourself on a link that fragments (symptom: the
  handshake succeeds and pings work, but SSH or the Proxmox UI hangs after
  a few packets).

## 5. Bring it up and verify

```sh
wg-quick up ./my-laptop.conf     # or import the file into the macOS/iOS app
wg show                          # expect: "latest handshake: N seconds ago"
ping -c2 10.10.10.1              # host over vmbr1
ping -c2 10.10.10.10             # k3s-node, directly over the tunnel
```

Then run the anti-lockout gate from the peer itself — CI structurally
cannot, since it has no tunnel:

```sh
cd ansible && ./run.sh playbooks/verify-wireguard.yml
```

All four checks must pass before anyone flips `restrict_management` (see
[`restrict-management-flip.md`](restrict-management-flip.md)).

---

## 5a. Use the names, not the IPs

With the tunnel up:

| | |
|---|---|
| `ssh root@pve.lab.tomkatom.com` | Proxmox host |
| `https://pve.lab.tomkatom.com:8006` | Proxmox UI |
| `ssh debian@k3s.lab.tomkatom.com` | k3s-node VM |
| `ssh debian@runner.lab.tomkatom.com` | CI runner VM |

These are ordinary public DNS records pointing at internal addresses
(`config/lab.yml` → `infra/tofu/cloudflare.tf`), so they resolve whether or
not you're connected — they simply don't answer without a tunnel. See
[`docs/networking.md#name-resolution`](../networking.md#name-resolution).

Worth putting in `~/.ssh/config` so the names are shorter still:

```
Host pve
  HostName pve.lab.tomkatom.com
  User root

Host k3s
  HostName k3s.lab.tomkatom.com
  User debian
```

Two things that are *not* fixed by having a name:

- **The Proxmox UI certificate.** It's still the node's self-signed cert, so
  the browser still warns. A name is the prerequisite for fixing that
  (Proxmox's built-in ACME with the Cloudflare DNS-01 plugin can issue for
  `pve.lab.tomkatom.com`; an IP literal can never hold a certificate at
  all) — but that's a separate change, not done here.
- **`known_hosts`.** SSH keys hosts by the name you typed, so the first
  connection by hostname prompts to trust the same key you already accepted
  by IP. Expected, not a warning sign — but read the fingerprint anyway.

---

## 6. Troubleshooting

**No handshake at all.** In order of likelihood: PSK present on one side
only (or mismatched); wrong host public key; UDP/51820 blocked by the
network you're on (some corporate/hotel Wi-Fi drops it — tether to test).
`wg show` reporting a handshake timestamp that never updates means packets
are leaving and nothing is coming back.

**Handshake fine, nothing routes.** Check your client `AllowedIPs` actually
lists the subnet you're trying to reach, and that your local network isn't
also `10.10.10.0/24` — an overlapping home LAN is a genuine conflict and the
fix is to renumber one of them.

**It worked, then a second peer was added and it stopped.** The classic
overlapping-`AllowedIPs` symptom. Confirm each entry in `wireguard_peers`
has its own unique `/32`.

**Locked out entirely?** The tunnel is not the only path in: the self-hosted
runner sits inside `10.10.10.0/24`, so a CI-run converge can still reach the
host and fix `wg0.conf`. [`lockout-recovery.md`](lockout-recovery.md) covers
the case where that path is gone too.

## 7. Rotating or removing a peer

Rotation is the same procedure with new key material: generate, PR the new
public key + PSK over the old entries, merge, approve, reconnect. There is
no partial state to clean up — `wg0.conf` is rendered whole from
`wireguard_peers` every converge, so deleting an entry from that list is
what revokes a peer.
