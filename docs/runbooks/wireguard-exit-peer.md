# Runbook: giving someone an exit-VPN config

How to hand a person a WireGuard config that puts their traffic on this
server's German IP — a phone in Israel that needs to look like it is in
Germany — without giving them any access to the lab at all.

The server half is code: `ansible/roles/wireguard` renders
`/etc/wireguard/wg1.conf` from `wireguard_exit_peers`
(`ansible/inventory/group_vars/all.yml`), and `ansible/roles/network_nat`
renders the nftables forward-chain rules that wall those peers off from
every internal address. What the tunnel is and why it is a second interface
rather than a second subnet: [`docs/networking.md`](../networking.md#wireguard-guest-exit-plane).

The client half is generated on your own machine by
[`scripts/wg-exit-peer.sh`](../../scripts/wg-exit-peer.sh) and never enters
this repo. That script writes one file containing a private key *and* a
preshared key in plaintext; it defaults to a path outside the working tree
and refuses an `--out-dir` inside it — comparing physically resolved paths,
so a symlink pointing back into the tree is refused too — and `.gitignore`
carries a `*.conf` backstop for a copy that gets hand-carried in anyway.

The management tunnel is a different thing with a different runbook:
[`wireguard-peer.md`](wireguard-peer.md).

---

## 0. `0.0.0.0/0` is correct here and wrong next door

The single most common way to get this wrong, and it is worse than a typo
because the mistake is *reading the other runbook and applying it*.
[`wireguard-peer.md`](wireguard-peer.md) says in as many words: do not use
`0.0.0.0/0`. That advice is about `wg0`, where a default route buys nothing
and breaks Plex direct-play. On `wg1` a default route **is the feature**.

| | `wg0` — management | `wg1` — guest exit |
|---|---|---|
| Runbook | [`wireguard-peer.md`](wireguard-peer.md) | this one |
| Peer list | `wireguard_peers` | `wireguard_exit_peers` |
| Endpoint port | `51820/udp` | `51821/udp` |
| Client `AllowedIPs` | `10.10.20.0/24, 10.10.10.0/24` | `0.0.0.0/0, ::/0` |
| Client `DNS =` | absent — keep your own resolver | `1.1.1.1` |
| Server-side `address` | the peer's own `/32` | the peer's own `/32` **and** `/128` |
| Reaches the lab | yes, that is the point | no, by firewall |

Two rows deserve spelling out.

**The server side is not mirrored.** A peer's `address` in this repo stays
one `/32` (plus one `/128`) no matter which tunnel it is on, because on the
host that field is cryptokey routing *plus* the anti-spoof source filter —
not the client's route list. Putting `0.0.0.0/0` there would let a guest
forge a source address inside `10.10.10.0/24` and would make a second guest
impossible, since a prefix belongs to exactly one peer. `roles/wireguard`
asserts the shape before rendering, so this fails the converge rather than
shipping.

**Do not copy `DNS = 1.1.1.1` back into a `wg0` config** to make the two
match. A `wg0` peer resolves `pve.lab.tomkatom.com` to an RFC1918 address,
and some resolvers strip private answers as DNS-rebinding protection
([`docs/networking.md#name-resolution`](../networking.md#name-resolution)).
`wg0` deliberately carries no `DNS =` line so it keeps using whatever
resolver already works for you.

---

## 1. Get the `wg1` server public key (once, ever)

The script needs it and this repo does not have it — by design. `wg1`'s
private key is generated in place on the host with `wg genkey` and never
leaves it (`ansible/roles/wireguard/tasks/main.yml`), so the public half is
something you read off the server, once, and keep.

Read it off the host over your existing `wg0` tunnel. This changes nothing —
it is one read of a public value:

```sh
ssh root@pve.lab.tomkatom.com wg show wg1 public-key
```

Then keep it out of the argument list for good:

```sh
export WG_EXIT_SERVER_PUBKEY='<that key>'
```

It is a public key — there is nothing to protect. It is only awkward to
obtain, which is why it is worth exporting once.

Every converge also prints it, in the task **"Show each instance's WireGuard
public key"**, one line per interface:

```
wg1 host WireGuard public key: <key> — give this to peers configuring their own client tunnel.
```

**Do not run a converge in order to read it.** Server changes go through CI
here, and `./run.sh playbooks/proxmox-host.yml` from a laptop is not a read:
it converges the whole host — `pve_repos`, `hardening`, `wireguard`,
`network_nat`, the lot — outside CI. If `/etc/wireguard/wg0.conf` has drifted
for any reason, that run re-renders it and the "Restart only the interfaces
whose config actually changed" task bounces `wg-quick@wg0`, which is the
tunnel the play's own SSH session is riding; the play dies mid-run and the
host is left part-converged. Recoverable — the tunnel comes back — but a
pointless risk to take for a value one `ssh` away. The converge line above is
here so you recognise the output when a legitimate converge scrolls past, not
as a way to fetch the key.

## 2. Generate the guest's peer (on your machine)

```sh
./scripts/wg-exit-peer.sh alices-phone
```

That mints a keypair and a preshared key locally, picks the next free
address out of `network.wireguard_exit_subnet` by reading the peers already
in `all.yml`, writes the client config to
`~/.local/state/lab/wg-exit/alices-phone.conf` (mode `600`), and prints it
as a QR code. Useful flags:

| | |
|---|---|
| `--address 10.10.30.7/32` | pin the address instead of taking the next free one |
| `--out-dir <dir>` | somewhere else, still outside the repo |
| `--stdout` | print the config instead of writing a file, so piping it into `pbcopy` yields exactly the config and nothing else |
| `--no-qr` | write the file, print no QR |
| `--force` | overwrite an existing file for that name |

`qrencode` is optional. Without it the script prints the config text and
tells you how to install it; nothing fails. Everything that is *not* the
config — the file path, the YAML to commit, the `sops` command — goes to
stderr, which is what keeps the piped forms clean.

The script refuses a name already used by *either* peer list.
`wireguard_peer_psks` is one flat map with no notion of which tunnel a peer
is on, so a name reused across the two would hand a guest the management
peer's preshared key.

## 3. PR the peer into the repo

The script prints both blocks ready to paste. Two files, one PR — the same
shape as a `wg0` peer:

```yaml
# ansible/inventory/group_vars/all.yml
wireguard_exit_peers:
  - name: alices-phone
    public_key: "<printed by the script>"
    address: 10.10.30.2/32
    address_v6: fd00:10:30::2/128
```

```sh
# ansible/inventory/group_vars/proxmox_host.sops.yml — encrypted; edit via sops
sops ansible/inventory/group_vars/proxmox_host.sops.yml
```

```yaml
wireguard_peer_psks:
  alices-phone: "<printed by the script>"    # keyed by the peer's `name` above
```

Merging runs the gated converge, which re-renders `wg1.conf` and restarts
`wg-quick@wg1` — and **only** `wg-quick@wg1`. The role restarts an interface
only when that interface's own config file changed
(`roles/wireguard/tasks/main.yml`, "Restart only the interfaces whose config
actually changed"), so adding a guest cannot bounce the management tunnel
this server's SSH access depends on.

The config you generated in §2 does not work until this lands. The host has
never seen that public key, so the handshake gets no reply — which looks
exactly like a network problem. Converge first, hand over second.

## 4. Hand the config over

The QR code is the intended path: it never leaves your screen and their
camera, so the key material touches no cloud service, no chat history and no
second device.

If you must send the file, send it over something end-to-end encrypted, and
**delete your copy afterwards** — that file is a bearer credential for an
exit VPN, and the private key in it is not recoverable or revocable except
by removing the peer (§7).

Do not reuse one config for two people. Two devices sharing a peer is a
`/32` claimed twice: WireGuard hands the prefix to whichever handshake
happened last and the other device goes dark, intermittently, in a way that
looks like bad signal.

## 5. Set up the client

Every platform below uses the **official** WireGuard app, by the WireGuard
Development Team. Third-party clients are not worth the risk on a config
carrying a private key.

### iOS

1. Run the script and leave the QR code on screen.
2. Tap **+** at the top right. The sheet is titled **Add a new WireGuard
   tunnel**; choose **Create from QR code**. (**Create from file or
   archive** takes the `.conf` if you AirDrop it instead — but the file then
   exists in two places, so delete it from the phone afterwards.)
3. The scanner is titled **Scan QR code**. On success it asks **Please name
   the scanned tunnel** — call it `lab-exit`, so it is never confused with a
   `lab` management tunnel on the same phone.
4. Tap the tunnel, then **Edit**, and check three things:
   - **Allowed IPs** reads `0.0.0.0/0, ::/0`. Both halves matter — §0.
   - **DNS servers** reads `1.1.1.1`. The app labels this field **Strongly
     recommended** whenever Allowed IPs is a default route, and it is right:
     without it the phone keeps using the carrier's resolver and leaks which
     sites it is visiting from an Israeli address, even though the packets
     leave from Germany.
   - **Exclude private IPs** — expect this one to be **missing**, and do not
     go looking for it. The app offers that toggle for a plain `0.0.0.0/0`
     default route; this config's Allowed IPs is `0.0.0.0/0, ::/0`, so on
     current versions there is no toggle to check. That is the expected
     state, not a sign the import went wrong — the two fields above are the
     whole checklist.

     If it *is* present, leave it off. Switching it on rewrites Allowed IPs
     into a long prefix list that skips RFC1918 — protection the host
     firewall already enforces far more reliably — and it rewrites the whole
     field, which is how the `::/0` half gets lost. That is the exact failure
     §8's "the exit IP is still Israel" describes, and it is invisible from
     an IPv4-only test page. If a home printer or Chromecast stops working
     while tunnelled, turn the tunnel off for that moment rather than
     reaching for this.
5. Optional, and the reason to bother with the app at all: in the same
   **Edit** screen, **On-Demand Activation** turns the tunnel on by itself.
   Enable **Cellular** and **Wi-Fi** and it is always up; enable **Wi-Fi**
   only and an **SSIDs** row appears offering **Any SSID**, **Only these
   SSIDs** and **Except these SSIDs** — `Except these SSIDs` with the home
   network listed is the usual shape.

   One caveat, and it is the common way this goes wrong: **enable On-Demand
   on exactly one tunnel.** If both `lab` and `lab-exit` have it, iOS flips
   between them unpredictably. It belongs on `lab-exit`.
6. Toggle the tunnel on and verify — §6.

### Android

1. Run the script and leave the QR code on screen.
2. Tap the **+** floating button, then **Scan from QR code**, and grant the
   camera permission. Name it `lab-exit`. (**Import from file or archive**
   takes the `.conf` — delete the file from the phone afterwards.)
3. Open the tunnel and tap the pencil (**Edit**). Confirm **Addresses**,
   **DNS servers** = `1.1.1.1`, and the peer's **Allowed IPs** =
   `0.0.0.0/0, ::/0`.
4. Per-app routing, which Android has and iOS does not. Still in **Edit**,
   scroll the Interface card to the button directly **below MTU**. It reads
   **All Applications** until you change it. Tap it; a dialog opens with two
   tabs:
   - **Exclude** — everything tunnels except the apps you tick. This is the
     tab it opens on and usually the one you want. Tick the banking app, the
     carrier's app, and anything that geo-locks *to* Israel — those break or
     get suspicious when they see a German IP.
   - **Include only** — nothing tunnels except the apps you tick. Cleaner if
     the exclude list starts getting long, or if only one streaming app
     needs Germany.

   The confirm button relabels itself as you select: **Use all apps** with
   nothing ticked, otherwise **Exclude N apps** / **Include N apps**.
   **Toggle all** selects everything, **Cancel** discards. Once saved, the
   button under MTU reads **N Excluded Applications** — that count is how
   you confirm it stuck.
5. Save, toggle the tunnel on, and verify — §6.

   Android has no on-demand equivalent to the iOS section above; the app
   connects when you toggle it. Always-on is an OS setting, not an app one:
   **Settings → Network & internet → VPN → WireGuard → Always-on VPN**, with
   **Block connections without VPN** as the kill-switch. Turning the
   kill-switch on *and* keeping a per-app **Exclude** list is contradictory —
   excluded apps then have no path at all — so pick one.

### Desktop

`wg-quick` takes the file directly:

```sh
sudo wg-quick up ./alices-phone.conf
sudo wg show                 # expect: "latest handshake: N seconds ago"
sudo wg-quick down ./alices-phone.conf
```

**On Linux, `wg-quick` needs a resolvconf implementation for the `DNS =`
line, and every config this script generates has one.** `wg-quick(8)` applies
that line by shelling out to `resolvconf`; on a stock Debian or Ubuntu box
with neither `openresolv` nor `systemd-resolved` installed, `wg-quick up`
prints `resolvconf: command not found`, runs its own rollback, and tears the
interface straight back down. What you see is the tunnel coming up and
vanishing with no handshake — which reads exactly like §8's "no handshake at
all" and sends you looking at the converge, the PSK and UDP/51821, none of
which is the cause. Either `apt install openresolv` (or enable
`systemd-resolved`, whose shim satisfies it), or delete the `DNS =` line and
set the resolver yourself — and if you delete it, point the resolver
somewhere that is not the local ISP's, for the reason the **DNS servers**
bullet in the iOS steps above gives: a full tunnel with the client's own
resolver still leaks which sites it is visiting from its real address, even
though the packets egress in Germany.

macOS and Windows use the official app's **Import tunnel(s) from file**; both
handle `DNS =` natively and need nothing installed.

Per-app routing does not exist on any desktop platform. A desktop on this
tunnel routes everything, which for a laptop means SSH, git and work traffic
too — usually a reason to prefer a browser profile or a VM over a
system-wide tunnel.

## 6. Verify, from the client

Two checks, and the second one is not a fault report:

1. A "what is my IP" page must show `145.239.3.55` and Germany.
2. An IPv6 test page must report **no IPv6**. That is the design
   ([`docs/networking.md`](../networking.md#wireguard-guest-exit-plane)): the
   tunnel carries a ULA so the client routes `::/0` into it rather than
   leaking IPv6 destinations around it over the carrier's own address, and
   the host then forwards no IPv6 at all. Every connection falls back to
   IPv4 through Germany.

Run both **on the client**, not on your laptop. And if the client is using
Android's **Include only** mode, the browser you check with must itself be
in the include list, or the check silently tests nothing.

`plex.tomkatom.com` and the other published hostnames keep working while
tunnelled. They resolve to the public IP like they do for anyone, so the
packet arrives on `wg1` addressed to `145.239.3.55`, matches the prerouting
DNAT — which is qualified on that address, `iifname { "eno1", "wg1" } ip
daddr 145.239.3.55 tcp dport 443 dnat to 10.10.10.10` — and hairpins back out
to the k3s VM. What lets it through the forward chain afterwards is
`iifname "wg1" oifname "vmbr1" ct status dnat accept`.

Two things about that rule are worth having right, because both of them get
misremembered:

- **It is the first `accept` in the isolation block, not the first rule.**
  Two MSS-clamp rules sit above it. They are not a decision: `tcp option
  maxseg size set` is a non-terminal statement, so they rewrite and fall
  through, which is precisely why they have to be above every `accept` —
  a packet that has already been accepted never reaches them.
- **Without it, nothing "RFC1918" would drop the packet — there is no such
  rule.** The block allows by exception. The only other `accept` in it
  requires `oifname "<uplink>"`, and a hairpinned packet is on its way to
  `vmbr1`, so it would fall through to the catch-all `iifname "wg1" drop`
  that closes the block. The deny list is a *negated set* on the internet
  accept (`ip daddr != { 10.0.0.0/8, ... }`), not a drop rule of its own; if
  you grep `nft list table ip lab-nat` for a private-ranges drop you will not
  find one, and the reason that shape was chosen is
  `network_nat_exit_denied_destinations` in `roles/network_nat/defaults`.

Either way the symptom is the same and misleading: Plex looks down, from that
client only, while tunnelled.

## 7. Revoke

Delete the peer's entry from `wireguard_exit_peers`, delete its key from
`wireguard_peer_psks`, PR, merge, converge. `wg1.conf` is rendered whole
from that list every run, so removing the entry *is* the revocation — there
is no partial state to clean up and nothing to expire.

Revocation takes effect at the converge, not at the merge. Until the play
runs, the old config still works.

There is no other lever. A guest config has no expiry date, no usage counter
and no per-peer disable switch — see §9.

## 8. Troubleshooting

**No handshake at all.** In order of likelihood: the converge from §3 has
not run yet, so the host has never heard of this public key; PSK present on
one side only, or mismatched; the `wg1` server public key is actually
`wg0`'s (they are different keys on purpose — a leaked guest config must
reveal nothing about the admin tunnel); UDP/51821 blocked by the network the
client is on. `wg show` reporting a handshake timestamp that never updates
means packets are leaving and nothing is coming back.

**Handshake fine, no internet.** Almost always the client's `AllowedIPs` is
not `0.0.0.0/0, ::/0` — some importers helpfully "fix" a default route into
a split tunnel. Check it in the app.

**Handshake fine, internet fine, but the exit IP is still Israel.** IPv6
leaking around the tunnel. `::/0` is missing from the client's `AllowedIPs`,
so IPv6-capable destinations — Google, Cloudflare, most CDNs — never enter
it. This is the failure this design exists to prevent and it is invisible
unless you look: an IPv4-only "what is my IP" page will happily report
Germany while the sites that matter see Israel.

**Some sites hang for several seconds, then load.** The other side of the
same coin. The host drops IPv6 in `ip6_forward()`, before any nftables hook,
so it cannot be a fast `reject`. Clients implementing Happy Eyeballs
recover in ~250 ms; clients without it (many native mobile apps, `curl`,
plenty of SDKs) wait out a full TCP connect timeout on the IPv6 attempt
first.

**A `lab.tomkatom.com` name resolves but nothing answers.** Working as
intended — those are public records with RFC1918 targets, so they resolve
from anywhere and answer almost nowhere. It looks like DNS; it is the
firewall. But *which* firewall depends on the name, and the difference is
not cosmetic: the two layers live in different files and fail differently.

- `k3s.lab.tomkatom.com` (`10.10.10.10`) and `runner.lab.tomkatom.com`
  (`10.10.10.20`) are addresses this host **forwards** to. Those packets do
  traverse `lab-nat`'s forward chain, match no `accept` in the isolation
  block — the DNAT accept needs `ct status dnat`, which a directly-addressed
  packet does not carry, and the internet accept needs the uplink as
  `oifname` — and are stopped by the block's catch-all `iifname "wg1" drop`.
- `pve.lab.tomkatom.com` (`10.10.10.1`) is one of the **host's own**
  addresses. Packets addressed to the host are delivered locally and go to
  the **input** hook; they never reach the forward hook, so `lab-nat`'s
  isolation block is not what stops them and never was — the template says as
  much in its own forward-chain comment. What stops them is the Tofu-owned
  PVE filter firewall: the cluster `input_policy` is `DROP`, and each
  management accept (SSH, `8006`, PBS, `node_exporter`) carries
  `source = "+mgmt"` — it does so once `restrict_management` is `true`, which
  it has been since the anti-lockout gate passed — an ipset built from
  `local.management_sources` in
  [`infra/tofu/locals.tf`](../../infra/tofu/locals.tf) — `internal_subnet`
  and `wireguard_subnet`, deliberately not `wireguard_exit_subnet`.

Why care, at 2am, when the packet is dropped either way: because the moment
you are debugging a `wg1` guest that *can* reach something on the host, the
answer is in Tofu and not in `nft list table ip lab-nat`, and you will burn
the night in the wrong table. And because a PVE input accept that gets
widened later has no `lab-nat` backstop underneath it — that omission from
the ipset is the whole of the access control, which is why it carries a
`lifecycle.precondition` (§9) rather than a comment.

**A phone can be on `lab` or `lab-exit`, never both.** iOS runs one
WireGuard tunnel at a time. The fix is switching tunnels, not widening
`wg1`.

**Everything works but throughput is poor.** Check that the MSS clamps are
present (`nft list table ip lab-nat` — two `tcp option maxseg size > 1380`
rules, one per direction); a tunnelled path with no clamp typically shows as
small requests working and large transfers stalling.

Check them **by hand**, because nothing else does.
[`verify-wireguard.yml`](../../ansible/playbooks/verify-wireguard.yml) asserts
the isolation rules — the guest-to-guest drop, the outbound catch-all drop,
the negated destination set on the internet accept, and both reverse-direction
rules (`oifname "wg1"`: the established/related accept and its catch-all drop)
— and deliberately not the clamps: a missing clamp is a performance fault,
while each of those five is a hole. So a green verify play says nothing about
throughput.

## 9. What this cannot do

**This is not a Netflix unblocker.** OVH is one of the most aggressively
blocked hosting ASNs there is. Netflix, Prime Video and Disney+ fingerprint
datacenter ASNs *independently of geolocation* — they will read the exit as
Germany and still refuse to play, or drop to a much smaller catalogue. If a
big streamer is the actual goal, this design does not deliver it and no
amount of tuning here will; that needs residential IP space, which this
server does not have and cannot get.

**Expect more CAPTCHAs, and the reason is the seedbox.** The exit IP is the
same public IP Deluge announces and seeds from
([`docs/networking.md`](../networking.md#single-ip-nat-model)). Cloudflare,
Google and a number of shopping and banking sites score torrent-announcing
datacenter addresses harshly, so a tunnelled client sees interstitials that
the same device does not see on its carrier. That is inherent to sharing one
IP, not a misconfiguration.

**Latency goes up by roughly 60–80 ms.** Israel to Germany and back is a
real round trip and it is added to every request. Fine for streaming and
browsing; noticeable in video calls and unusable for anything twitchy.

**Nothing expires.** There is no key lifetime, no session limit, no usage
cap and no per-peer disable. A config works until someone deletes the peer
and a converge runs (§7). Treat every handover as permanent until you
revoke it, and keep `wireguard_exit_peers` short enough that you recognise
every name in it.

**Guests reach nothing in the lab, and this is not adjustable per guest.**
The isolation is one block of nftables rules keyed on the `wg1` interface
(`ansible/roles/network_nat`), not a per-peer ACL — five matching `iifname`
for traffic leaving the tunnel, two matching `oifname` for traffic travelling
toward it, so neither direction rests on the chain's `policy accept`. For
anything addressed to the host itself it is not even that, but the PVE input
policy (§8). One gap the `oifname` pair cannot close: the Proxmox host's own
locally generated packets leave via the output hook and never enter the
forward chain, so the host itself can still open a connection to a guest. The exit subnet is deliberately absent from Tofu's `+mgmt` ipset, and
`infra/tofu/firewall.tf` carries a `lifecycle.precondition` that fails the
apply if anyone ever adds it. That precondition sits on
`proxmox_virtual_environment_firewall_ipset.mgmt` — the resource that writes
those CIDRs — rather than on the cluster policy, so the apply aborts before
the exposure exists instead of after. If a guest needs something in the lab,
the answer is a `wg0` peer ([`wireguard-peer.md`](wireguard-peer.md)) or a
published service, never a hole in `wg1`.

**Per-app include/exclude is client-side and advisory.** Android's
Applications list is a routing convenience, not a security boundary — it is
a setting on a device you handed to someone else. The host firewall is the
boundary.

**No IPv6 egress.** Deliberate, and covered in §6 and §8. It is enforced
twice, so making it real means undoing both: `roles/network_nat` pins
`net.ipv6.conf.all.forwarding` to `0` on every converge, *and* its ruleset
carries an `ip6 lab-nat` table dropping both directions across `wg1` for the
case where something else flips that knob. Real egress would be those two
reversed plus an `ip6` masquerade rule and a forward accept, once the host's
OVH IPv6 allocation is verified — and plus renumbering the ULA off RFC 4193's
all-zero global ID, which `config/lab.yml` records as a precondition of that
work. It is not a one-line change and it is not on anyone's list.
