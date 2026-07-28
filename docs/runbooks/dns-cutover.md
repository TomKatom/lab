# Runbook: DNS cutover to the new server

How to move `tomkatom.com` off the old operational server and onto this
cluster, in two independent flips:

1. **`manage_dns = false → true`** in `infra/tofu/terraform.tfvars` — Tofu
   takes ownership of the apex, wildcard and `vpn.` records and points them
   at the new server. This is the one that moves live traffic.
2. **Removing `--dry-run`** from `clusters/lab/platform/external-dns.yaml` —
   external-dns starts writing a record per Ingress instead of only logging
   what it would write. This one is purely additive.

Between the two there is one thing neither flip does for you: **deleting the
six old-server `CNAME`s that collide with a cluster Ingress host** (§6a).
They are not in git, external-dns cannot touch them, and while they exist
it silently declines to create the records that replace them. Ten more
old-server `CNAME`s are dead for good and get cleared in the same step as
zone hygiene — they block nothing, see §6a.

Everything in Phase 5 was built so that neither flip can be a surprise. This
runbook is the forward procedure; §9 is the rollback ladder.

**This runbook has never been executed.** Every command below is written from
the live zone state and the pinned upstream sources, but the first run is the
first proof — treat unexpected output as a reason to stop, not to improvise.

---

## 0. The state you are starting from

Verified by public `dig`, and cross-checked against the full §4 zone
snapshot pulled from the Cloudflare API rather than sampled name-by-name
(read-only, no server access needed — re-run both before you begin, the
zone is shared and can change under you):

| Name | Today | Serves |
|---|---|---|
| `tomkatom.com` | `A 94.75.211.144` — exactly one record (§5a's duplicate-apex trap is not pre-tripped) | old server (already stopped) — **and, from flip 1 on, the cluster's Homepage** (see below) |
| `sonarr` / `radarr` / `prowlarr` / `deluge` / `bazarr` / `www` | `CNAME → tomkatom.com` | old server (stopped); **collides with a cluster Ingress host — freed in §6a** |
| `authelia` / `request` / `codeowner` / `codeowner-coolify` / `codeowner-pgadmin` / `b2-codeowner` / `realtime` / `proxmox` / `traefik` / `portainer` | `CNAME → tomkatom.com` | old server (stopped); **dead for good — replaced under another name, or an unrelated project on the same box; deleted as zone hygiene in §6a** |
| `*.tomkatom.com` | **NXDOMAIN** | nothing — there is no wildcard *record* yet (the old server has a wildcard *certificate*, which is a different thing) |
| `vpn` / `auth` / `tautulli` / `maintainerr` / `requests` | **NXDOMAIN** | nothing — these are the cluster's own hosts, reachable over WireGuard only |
| `*.lab.tomkatom.com` | `A` (internal addresses) | new server, WireGuard-only, already Tofu-managed and ungated |
| `_externaldns.*` | **NXDOMAIN** everywhere — zero such records exist anywhere on the zone | nothing — external-dns has written zero records since it was deployed |
| `_dmarc` TXT, `*._domainkey` TXT, apex SPF TXT | present | mail, untouched by any of this — ignore these in §7's zone diff |

The zone holds **16** `CNAME`s to the apex today, in two groups for two
different reasons:

- **Six suppress a cluster Ingress host and must be deleted in §6a before
  flip 2, or external-dns silently never creates the record**: `sonarr.`,
  `radarr.`, `prowlarr.`, `deluge.`, `bazarr.` and `www.`. The first five
  collide with the media pipeline's own hosts. `www` collides because a
  separate PR adds `www.tomkatom.com` as a second host on Homepage's
  Ingress (`clusters/lab/apps/homepage.yaml`, plus
  `HOMEPAGE_ALLOWED_HOSTS`) — confirm that PR has merged; precondition 1
  (§2) already requires an Ingress for every host the old server serves,
  and from that PR onward `www` is one of them. `bazarr` is the one that
  catches this out by eye even without the `www` wrinkle: it has a healthy
  cluster Ingress today, so it is easy to assume it is NXDOMAIN like
  `auth`/`tautulli`/`maintainerr`/`requests`. It is not — it is a hand-made
  `CNAME`, and §1/§6a exist because of it.
- **Ten are dead for good and get deleted in §6a as zone hygiene, not
  because anything is blocked**: `authelia`, `request` (singular — the
  cluster spells this host `requests.`, plural), `codeowner`,
  `codeowner-coolify`, `codeowner-pgadmin`, `b2-codeowner`, `realtime`,
  `proxmox`, `traefik` and `portainer`. Five of them were the old server's
  own stack and are superseded by a named cluster replacement — `authelia`
  by the cluster's `auth.`, `request` by `requests.`, `traefik` by the
  Traefik in the `traefik` namespace, `portainer` by Argo CD, and `proxmox`
  by `pve.lab.` on the tunnel (see `media-migration.md` §2.1 for the
  old-server service list). The other five — `codeowner`,
  `codeowner-coolify`, `codeowner-pgadmin`, `b2-codeowner` and `realtime` —
  belonged to an unrelated project that lived on the same box. None has a
  cluster Ingress, so external-dns was never blocked by any of them and
  flip 2 does not need them gone — they are deleted anyway so the zone
  stops advertising names that resolve to a server that no longer exists.
  `proxmox` and `traefik` matter most here: after flip 1 the wildcard would
  otherwise make them resolve to the *new* node, publicly advertising
  management-sounding names for services that are deliberately
  WireGuard-only (`pve.lab.` / `k3s.lab.`).

`plex.tomkatom.com` is absent from that table on purpose: **Plex has no
Ingress and needs no record at all.** Remote clients are brokered by
plex.tv straight to `145.239.3.55:32400`, which the host already DNATs to
the node, so external-dns never sees a Plex host and never creates one —
before or after this cutover.

**The apex is the mirror image of that, and it changes what flip 1 means.**
Homepage's Ingress is `tomkatom.com` itself
(`clusters/lab/apps/homepage.yaml`), so the cluster is ready to serve the
bare domain — but external-dns cannot create or move that record, because
Tofu owns it and ownership is what gates every write (§1). Two things
follow:

- **Flip 1 is no longer only a redirection, it is a launch.** The moment
  the apex A record points at the node, `https://tomkatom.com` stops being
  the old server's front page and becomes this cluster's. That is the
  intent, but it is the most user-visible single second of this runbook —
  do it knowing that, not as a side effect of "moving DNS".
- **The apex answers on a real certificate from that same second**, because
  `clusters/lab/platform/traefik/wildcard-certificate.yaml` carries
  `tomkatom.com` as a second SAN alongside `*.tomkatom.com` (a wildcard
  label does not cover the bare domain). Confirm the Secret really holds
  both names before flipping — §2, precondition 7.

```sh
dig +short tomkatom.com A
dig +short sonarr.tomkatom.com
dig +short authelia.tomkatom.com            # still a CNAME — not the same name as auth.tomkatom.com, see above
dig +short randomname-xyz123.tomkatom.com   # empty = no wildcard record
dig +short _externaldns.a-auth.tomkatom.com TXT
```

## 1. The one idea that makes this safe

**external-dns cannot take a name it does not own.** Not because of
`--dry-run`, and not because of `policy` — because of ownership, enforced at
two independent layers of external-dns v0.21.0:

- `plan/plan.go` — `appendTakenDNSNameChanges` drops a `Create` outright
  unless *every* record already at that name is owned by `lab-k3s`, and
  `calculateChanges` filters `Delete`/`UpdateOld`/`UpdateNew` through
  `FilterEndpointsByOwnerID`.
- `registry/txt/registry.go` — `TXTRegistry.ApplyChanges` re-filters the same
  three the same way.

Ownership is a TXT record beside the record it tracks, containing
`external-dns/owner=lab-k3s`. The old server's records and Tofu's
apex/wildcard/`vpn.` records have no such TXT, so both layers reject any
change to them. **That absence is the entire protection** — it is why
external-dns can be un-inerted on a zone it shares with a production server
at all.

So the only unconditional write external-dns has is a `Create` for a name
with **no** record at all. Today that means the four cluster hosts nothing
else claims — `auth.`, `tautulli.`, `maintainerr.` and `requests.`. That is
what `--dry-run` is standing in for, and it is a timing guard (do not make
new-server services resolve before you mean to), not a safety guard.

The bare apex is **not** on that list, and is in the same position as the
six `CNAME`s the corollary below describes rather than the four names
above it: a record external-dns does not own is already sitting there, so
the `Create` is dropped. Tofu's apex record carries no ownership TXT
either, which is why Homepage's host never appears in external-dns's output
at all.

**Corollary that shapes the whole procedure:** six names either already
collide, or are about to collide, with a cluster Ingress host, and all six
are already `CNAME`s to the apex — `sonarr.`, `radarr.`, `prowlarr.`,
`deluge.`, `bazarr.` and `www.` — so external-dns will *never* adopt
them — and, less obviously, **it will never *create* them either, for as
long as those CNAMEs exist.** `appendTakenDNSNameChanges` drops the
`Create` because a record it does not own is already sitting at the name;
nothing is logged as refused, the host simply never appears. So the CNAMEs
do not just survive the cutover, they suppress it for those six hosts.
Deleting them by hand is therefore a required step of this runbook, not
decommissioning cleanup — §6a. This set of six was confirmed by
enumerating every record actually in the zone (§4/§0), not assumed from the
cluster's app list: `bazarr` has an Ingress today and `www` is gaining one
via a separate PR (§0), so nothing about either *looks* different from any
other cluster host — only `dig` shows they are still the old server's
CNAMEs. Ten more `CNAME`s on the zone are dead for good and get cleared in
the same step for a different reason — §0, §6a.

---

## 2. Preconditions

Do not proceed until every row is green.

| # | Precondition | How to check |
|---|---|---|
| 1 | **Phase 6 apps are live on this cluster**, with an Ingress each | `kubectl get ingress -A` over WG lists every host the old server serves |
| 2 | Each of those Ingresses answers on the real certificate | `curl -sI --resolve <host>:443:10.10.10.10 https://<host>` → 200/302, LE chain |
| 3 | **Every Ingress publishes the public IP, not `10.10.10.10`** | §3 — this is the hard gate |
| 4 | Media data is on the new server and the old server is ready to stop serving | operator judgement; the flip is near-instant to reverse but the traffic is real |
| 5 | Cloudflare token in `secrets.sops.tfvars.json` really carries `Zone:DNS:Edit` | already proven — the `lab.` management records were created with it |
| 6 | The flip PRs are clean, minimal diffs with CI green | `gh pr diff <PR#>`, `gh pr checks <PR#>` |
| 7 | **The issued certificate really carries the apex SAN** | §2a — flip 1 publishes the apex, so this has to be true before it, not after |

---

### 2a. The apex SAN

`kubectl -n traefik get certificate wildcard-tomkatom` reporting `Ready`
only says cert-manager is happy with *some* certificate. Read the one
Traefik is actually serving:

```sh
kubectl -n traefik get secret wildcard-tomkatom-tls \
  -o jsonpath='{.data.tls\.crt}' | base64 -d \
  | openssl x509 -noout -text | grep -A1 'Subject Alternative Name'
# DNS:*.tomkatom.com, DNS:tomkatom.com
```

One name where there should be two means the re-issue that added the SAN
has not landed yet — most likely a pending order (`kubectl -n traefik get
certificaterequest,order,challenge`). Flip 1 with one name and the apex
serves Traefik's self-signed default: every visitor to the new front door
gets a browser interstitial, on the most visible name on the zone.

---

## 3. Hard gate: confirm the published target

**Do not skip this, and do not try to confirm it from external-dns's logs.**
The Cloudflare provider logs `record`/`type`/`ttl`/`action`/`zone` and *never*
the target (`provider/cloudflare/cloudflare.go`), so a clean-looking dry-run
log tells you nothing about what would actually be written. Read the input
external-dns consumes instead — the Ingress status:

```sh
kubectl get ingress -A \
  -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,HOST:.spec.rules[*].host,ADDRESS:.status.loadBalancer.ingress[*].ip
```

Every row's ADDRESS must be **`145.239.3.55`**. If any row shows
`10.10.10.10`, stop: external-dns would publish RFC1918 space into a public
zone for that host.

That address comes from `clusters/lab/platform/traefik.yaml`:

```yaml
providers:
  kubernetesIngress:
    publishedService:
      enabled: false
    ingressEndpoint:
      ip: 145.239.3.55
```

Both settings are load-bearing. Traefik's `updateIngressStatus` returns early
on `publishedService` and never reads `ip`, so re-enabling the former
silently reverts the latter — and the chart defaults it to `true`, which
means a Renovate bump that touches those values is the realistic way this
regresses. Re-run the `kubectl get ingress` check after any Traefik chart
bump, not just here.

---

## 4. Snapshot the zone

Every later verification is a diff against this. Cloudflare dashboard →
`tomkatom.com` → DNS → Records → **Export** gives a BIND zone file; keep it
somewhere durable (not in this repo — it is a full picture of the zone).

Equivalent read-only API call, with the token this repo already holds.
**Mind the extraction:** `sops -d` on this file decrypts to a single
top-level `data` key whose value is the tfvars content as a plain string,
not nested JSON — grepping the raw decrypted output for
`cloudflare_api_token` matches the outer `"data": "..."` line and `cut`
silently returns the literal word `data`, not a token. Unwrap `.data`
first:

```sh
CF_TOKEN=$(sops -d infra/tofu/secrets.sops.tfvars.json | jq -r '.data' | grep cloudflare_api_token | cut -d'"' -f2)
ZONE=096a4bdef4b6f25679ec97e558d04bf4
curl -s -H "Authorization: Bearer $CF_TOKEN" \
  "https://api.cloudflare.com/client/v4/zones/$ZONE/dns_records?per_page=200" \
  | jq -r '.result[] | [.id, .type, .name, .content, (.comment // "-")] | @tsv' \
  | sort -k3 | tee ~/tomkatom-zone-before.tsv
```

Keep `$CF_TOKEN` out of shell history and out of any transcript.

---

## 5. Flip 1 — `manage_dns = true`

### 5a. The trap: the apex record already exists

`local.dns_a_records` has three entries — `apex`, `wildcard`, `vpn.`. Two of
those names do not exist in the zone, so Tofu creates them cleanly. **The
apex does exist**, pointing at the old server, and Cloudflare happily holds
more than one A record at a name: a plain apply would *add* a second apex
record rather than replace the first, and the zone would round-robin between
the old and new servers. Fix it before applying, not after.

**Preferred — adopt the existing record into state.** Find its ID:

```sh
curl -s -H "Authorization: Bearer $CF_TOKEN" \
  "https://api.cloudflare.com/client/v4/zones/$ZONE/dns_records?type=A&name=tomkatom.com" \
  | jq -r '.result[] | [.id, .content] | @tsv'
```

Add an import block to `infra/tofu/cloudflare.tf`, in the same PR as the
flip:

```hcl
# One-shot: the apex A record predates this repo and still points at the old
# server. Delete this block once the apply below has run.
import {
  to = cloudflare_dns_record.records["apex"]
  id = "096a4bdef4b6f25679ec97e558d04bf4/<record-id>"
}
```

`tofu plan` should then read something like **`1 to import, 2 to add, 1 to
change, 0 to destroy`**, with the imported apex showing an in-place `content`
change `94.75.211.144 → 145.239.3.55`. The counts matter less than the two
facts: **zero destroys**, and the apex is a change rather than an add. A
destroy, or three adds, means the import did not match — stop.

**Fallback** — delete the apex record by hand in the Cloudflare dashboard
immediately before the apply, and let Tofu create it fresh. Simpler, but the
old server is NXDOMAIN for the gap between the two actions. Only do this if
the import path fails.

### 5b. Apply

This apply touches Cloudflare only — no firewall, no VM — so the normal
gated CI apply is fine (`docs/runbooks/tofu-apply.md` §5); the
"do not let CI perform a firewall-affecting apply" rule there does not bite
here. Locally is equally fine:

```sh
cd infra/tofu
./tofu.sh plan     # re-read it: apex changes, nothing is destroyed
./tofu.sh apply
```

### 5c. Verify, then remove the import block

```sh
dig +short tomkatom.com A                        # 145.239.3.55
dig +short randomname-xyz123.tomkatom.com A      # 145.239.3.55 (wildcard now exists)
dig +short vpn.tomkatom.com A                    # 145.239.3.55
dig +short sonarr.tomkatom.com                   # CNAME → apex → 145.239.3.55
curl -sI https://tomkatom.com | grep -iE '^HTTP|^location' | tr -d '\r'
# HTTP/2 200 — Homepage, on the real chain, and no location: line
```

That last check is the flip's user-visible result, and no `-k`: a TLS error
there is precondition 7 having been wrong. It greps for `location` as well
as the status line because the apex Ingress is deliberately un-annotated
(`clusters/lab/apps/homepage.yaml`): a `302` to `auth.tomkatom.com` here
means forward-auth got onto this host, which would send exactly the viewers
the page is written for to a login they have no account on. Load it in a
browser too — the apex is now a page people will be sent to, so "Traefik
answers" is a weaker claim than it used to be.

Then open a follow-up PR deleting the `import` block (it has done its job;
leaving it is harmless but it reads like pending work). At this point every
name on the zone resolves to the new server, and external-dns has still
written nothing.

---

## 6. Flip 2 — remove `--dry-run`

### 6a. Pre-flight: free the six suppressing names, clear ten dead ones

**Do this before removing the flag** (the old server has already stopped
serving, so there is no timing to wait for). Sixteen `CNAME`s on the zone
point at the apex, in two groups for two different reasons — keep them
separate in your head even though the mechanical delete step is identical.

**Group 1 — suppressing, must be gone before flip 2 or external-dns
silently never creates the record:** `sonarr.` `radarr.` `prowlarr.`
`deluge.` `bazarr.` and `www.tomkatom.com` are unowned `CNAME`s to the apex
that share a name with a cluster Ingress host — `www`'s Ingress comes from
a separate PR against `clusters/lab/apps/homepage.yaml` (§0); confirm it
has merged before relying on this step to free the name for real.
External-dns will not create an A record at a name where a record it does
not own already sits (§1), and it says nothing when it declines — so left in
place, these six hosts would simply never appear on the new server's side
of the zone, while every other host would. Nothing downstream would look
broken; they would keep resolving to whatever the apex points at. `bazarr`
and `www` are the two easiest to miss doing this by hand: both have (or
are about to have) a healthy cluster Ingress like every other app here, so
nothing about either *looks* unusual — only the zone itself shows they are
still hand-made CNAMEs.

**Group 2 — dead for good, cleared as zone hygiene, nothing depends on
this:** `authelia.` `request.` (singular — the cluster's host is
`requests.`, plural) `codeowner.` `codeowner-coolify.`
`codeowner-pgadmin.` `b2-codeowner.` `realtime.` `proxmox.` `traefik.` and
`portainer.tomkatom.com`. Five were the old server's own stack and have a
named cluster replacement already serving under a different name —
`authelia` → `auth.`, `request` → `requests.`, `traefik` → the `traefik`
namespace, `portainer` → Argo CD, `proxmox` → `pve.lab.` on the tunnel
(`media-migration.md` §2.1 lists what the old box actually ran). The other
five — `codeowner.` `codeowner-coolify.` `codeowner-pgadmin.`
`b2-codeowner.` and `realtime.` — belonged to an unrelated project on the
same box. None has a cluster Ingress, so external-dns was never blocked by
any of them, and flip 2 does not need them gone — they are deleted anyway
so the zone stops advertising names that resolve to a server that no
longer exists. `proxmox` and `traefik` are worth
deleting promptly: after flip 1 the wildcard would otherwise make them
resolve to the *new* node, publicly advertising management-sounding names
for services that are deliberately WireGuard-only (`pve.lab.` /
`k3s.lab.`).

These sixteen are the only ones this step applies to. Every other cluster
host had no record of its own before flip 1 (§0) and needs no preparation.

Delete both groups by hand in the Cloudflare dashboard, or with the token
from §4:

```sh
# Group 1 — suppressing, gates flip 2
for h in sonarr radarr prowlarr deluge bazarr www; do
  ID=$(curl -s -H "Authorization: Bearer $CF_TOKEN" \
    "https://api.cloudflare.com/client/v4/zones/$ZONE/dns_records?type=CNAME&name=$h.tomkatom.com" \
    | jq -r '.result[0].id // empty')
  [ -n "$ID" ] || { echo "$h: no CNAME, nothing to do"; continue; }
  curl -s -X DELETE -H "Authorization: Bearer $CF_TOKEN" \
    "https://api.cloudflare.com/client/v4/zones/$ZONE/dns_records/$ID" | jq -r '.success'
  echo "$h deleted"
done

# Ask the zone's own nameserver, not your resolver — see the second ⚠ below.
NS=$(dig +short NS tomkatom.com | head -1)
for h in sonarr radarr prowlarr deluge bazarr www; do
  printf '%-24s %s\n' "$h.tomkatom.com" \
    "$(dig +short @"$NS" CNAME "$h.tomkatom.com" | tr '\n' ' ')"
done   # all six empty — no CNAME left at any of them

# Group 2 — dead, zone hygiene only, order doesn't matter
for h in authelia request codeowner codeowner-coolify codeowner-pgadmin \
         b2-codeowner realtime proxmox traefik portainer; do
  ID=$(curl -s -H "Authorization: Bearer $CF_TOKEN" \
    "https://api.cloudflare.com/client/v4/zones/$ZONE/dns_records?type=CNAME&name=$h.tomkatom.com" \
    | jq -r '.result[0].id // empty')
  [ -n "$ID" ] || { echo "$h: no CNAME, nothing to do"; continue; }
  curl -s -X DELETE -H "Authorization: Bearer $CF_TOKEN" \
    "https://api.cloudflare.com/client/v4/zones/$ZONE/dns_records/$ID" | jq -r '.success'
  echo "$h deleted"
done
```

⚠ **Check the `CNAME`, not the address — `dig +short <host>` is useless
here.** Flip 1 created Tofu's `*.tomkatom.com` A record (§5,
`local.dns_a_records`'s `wildcard`), and a wildcard answers every name in
the zone that has no record of its own. So the instant Group 1's `CNAME`s
are deleted the names keep resolving — to `145.239.3.55`, the right answer,
via the wildcard. **There is no NXDOMAIN window**, nothing to schedule
around, and equally nothing an address lookup can tell you: those six
names return the same IP before §6a, between §6a and §6b, and after
external-dns has created real A records for them. Only the record *type*
and the ownership TXT distinguish those states, which is what §7 checks.
This is exactly why missing `bazarr` or `www` here is dangerous rather
than merely wrong — a plain address lookup afterwards shows the right IP
and nothing looks broken (§9 item 5). Group 2 has no such subtlety: those
ten names have no Ingress to collide with, so after their `CNAME` is gone
the wildcard answers them too — that is simply the right answer for a
name with no record and no cluster host, not a state to verify further.

⚠ **Ask the zone's nameserver, not your resolver.** A `CNAME` you have just
deleted stays in a recursive resolver's cache for the rest of its TTL
(Cloudflare "automatic", ~300s), so a plain `dig` can report a record that
no longer exists — and report it unevenly, since only the names you happen
to have looked up recently are cached at all. Five of six still showing a
`CNAME` while the sixth is clean is that, not a partial delete. Hence the
`@"$NS"` above.

The failure direction here is the frustrating one rather than the dangerous
one: a stale cache reads as *still suppressing*, which stalls a cutover that
is already ready. It cannot mislead you the other way. Nor does it delay
flip 2 — external-dns builds its picture of the zone from the Cloudflare
API, never from DNS resolution, so it does not share your resolver's cache
and does not wait for it to expire. Once the loop above is clean against
`@"$NS"`, the gate is clear whatever a cached lookup still says.

Do not "fix" a Group 1 name by re-creating a CNAME at it — that puts the
suppression straight back, silently.

Confirmation that the gate has actually cleared, while still in dry-run:
Group 1's six names now show up as would-creates where before they were
absent entirely. Group 2 never shows up here at all, before or after —
there is no Ingress for external-dns to see, so it has no opinion on any
of the ten.

```sh
kubectl -n external-dns logs deploy/external-dns --tail=200 | grep -i 'sonarr\|radarr\|prowlarr\|deluge\|bazarr\|www'
```

### 6b. Remove the flag

One-line PR against `clusters/lab/platform/external-dns.yaml`: delete the
`extraArgs: ["--dry-run"]` block. Merge, and Argo applies it within a sync
cycle.

With §6a done, expect it to create an A + ownership TXT for **all ten**
cluster hosts it can reach — `auth. sonarr. radarr. bazarr. prowlarr.
deluge. tautulli. maintainerr. requests. www.` — and nothing else. The apex
`tomkatom.com` is Homepage's *other* host and is deliberately not in that
list: it is Tofu's record and external-dns cannot write it (§0, §1). The
log line for a run with nothing left to do is `All records are already up
to date`.

```sh
kubectl -n external-dns logs deploy/external-dns | grep -E 'Changing record|up to date'
```

There should be **no** `Changing record.` line naming `tomkatom.com`,
`vpn.tomkatom.com`, or any other name from the §4 snapshot that is not one
of those ten cluster hosts. If there is, re-add `--dry-run` immediately
(§9) — the ownership contract is not behaving as read, and nothing below
is trustworthy.

---

## 7. Verify the ownership contract

This is the check that matters most, because it is what keeps the *next* few
years of Ingress churn from touching records external-dns did not create.

**Every record external-dns created has a paired ownership TXT.** Mind the
record-type infix: the TXT for an A record at `auth.tomkatom.com` is
`_externaldns.` + `a-` + the host.

The set is every `*.tomkatom.com` host this cluster serves, and no more.
**`plex`** is the one app permanently outside it: it has no Ingress at all,
so external-dns never sees it and remote access is brokered by plex.tv
straight to `145.239.3.55:32400` (§0). The apex `tomkatom.com` is outside
it too, for the opposite reason — it is Homepage's *other* host, but it is
Tofu's record and stays Tofu's — an A record with no ownership TXT, checked
as such in the next block rather than this one.

```sh
NS=$(dig +short NS tomkatom.com | head -1)
for h in auth sonarr radarr bazarr prowlarr deluge tautulli maintainerr requests www; do
  echo "== $h"
  dig +short @"$NS" "$h.tomkatom.com" A                        # 145.239.3.55
  dig +short @"$NS" "_externaldns.a-$h.tomkatom.com" TXT       # heritage=external-dns,external-dns/owner=lab-k3s,...
done
```

Both loops in this section pin `@"$NS"` for the reason §6a gives, with the
sign reversed. These records were just *created*, so a resolver still
holding the negative answer it cached before flip 2 reports an ownership TXT
as missing — which reads here as a create that did not happen, the one
conclusion this whole section exists to draw. The absence check below pins
it for the mirror case: a cached negative would hide an ownership TXT that
should never have appeared at all.

**The TXT column is the whole check; the A column proves nothing.** Tofu's
`*.tomkatom.com` A record answers every name in this zone that has no
record of its own, so `dig +short <host> A` returns `145.239.3.55` whether
external-dns created a record or silently declined to. A host with an
address and **no** `_externaldns.a-` TXT is a create that did not happen —
looking exactly like a working one from the outside. That is why the six
that were CNAMEs until §6a (`sonarr.`, `radarr.`, `prowlarr.`, `deluge.`,
`bazarr.`, `www.`) get read here rather than by resolution: they must now
be plain A records (`dig <host> A` shows `IN A`, not a CNAME chain) with an
ownership TXT beside them, like every other row.

**Nothing else grew one.** Tofu's records must have no ownership TXT at all
— that absence is the only thing keeping `policy: sync` off them, and it
now also has to hold for a name external-dns has an Ingress for. The apex
serving Homepage is exactly the case where an ownership TXT appearing would
mean the gate had failed:

```sh
for h in tomkatom.com vpn.tomkatom.com; do
  for pfx in a- cname-; do
    printf '%-40s %s\n' "_externaldns.$pfx$h" \
      "$(dig +short @"$NS" "_externaldns.$pfx$h" TXT)"
  done
done
```

Every line must show an empty value.

**Diff the whole zone against the snapshot.** Re-run §4's `curl` into
`~/tomkatom-zone-after.tsv` and `diff` them. The only new rows should be
one A + one TXT per cluster host (ten new pairs, matching §6b's ten), the
only removed rows §6a's sixteen `CNAME`s (six of Group 1 replaced by those
new A/TXT pairs, all ten of Group 2 simply gone with nothing replacing
them), and the only changed row the apex's content. The `_dmarc` TXT,
`*._domainkey` TXT and apex SPF TXT rows are mail records untouched by any
of this — expect them to show up unchanged, not as drift. Anything else is
unexplained and worth chasing before you walk away.

> **Never delete an ownership TXT by hand.** external-dns then forgets it
> owns the record and stops managing it, rather than cleaning it up — you
> get a permanent orphan. Remove the Ingress; let external-dns remove both.

---

## 8. After the cutover

- **The old server's six suppressing `CNAME`s are gone** — §6a deleted
  `sonarr.`, `radarr.`, `prowlarr.`, `deluge.`, `bazarr.` and `www.`, and
  external-dns now owns a plain A record at each of those names. `www` is
  the newest of the six: it started suppressing only once
  `clusters/lab/apps/homepage.yaml` gained it as a second Ingress host
  (§0), and now resolves as a genuine cluster host in its own right rather
  than following the apex. Nothing is left on this zone that external-dns
  cannot see; if a future host is ever hand-created as a CNAME again, the
  same suppression comes back with it.
- **The ten dead-for-good `CNAME`s are also gone, but for hygiene, not
  because §6b needed them cleared.** `authelia`, `request`, `codeowner`,
  `codeowner-coolify`, `codeowner-pgadmin`, `b2-codeowner`, `realtime`,
  `proxmox`, `traefik` and `portainer` were either the old server's own
  stack, already replaced under a different name (`auth.`, `requests.`, the
  `traefik` namespace, Argo CD, `pve.lab.`), or part of an unrelated project
  that lived on the same box. None had a cluster Ingress, so external-dns
  never had an
  opinion on any of them — deleting them just stops the zone advertising
  names for a server that no longer exists. `proxmox` and `traefik` were
  the two worth prioritising: past flip 1 the wildcard would otherwise
  answer for them too, publicly exposing management-sounding names for
  services that are deliberately WireGuard-only (`pve.lab.` / `k3s.lab.`).
- **`vpn.lab.tomkatom.com` is retired** in favour of the now-live
  `vpn.tomkatom.com` — `docs/runbooks/wireguard-peer.md`'s peer-config
  template points at the new name, and `infra/tofu/locals.tf`'s
  `dns_mgmt_records` no longer defines the duplicate. Any peer config
  written before this still has the old `Endpoint` line; repoint it by hand
  (§4 of `wireguard-peer.md`) before this Tofu change is applied and the
  record is destroyed.
- **TTLs stay Cloudflare "automatic" (`ttl=1`).** external-dns sets no TTL
  and the chart configures none. If a specific TTL is ever wanted, it is the
  `external-dns.alpha.kubernetes.io/ttl` annotation on the Ingress, per host.
- **A new public IP means grepping for the literal** — `grep -rn
  145.239.3.55` currently finds it in `infra/tofu/terraform.tfvars` (twice:
  `ovh_public_ip` and `proxmox_endpoint`), `ansible/inventory/hosts.yml`,
  `ansible/inventory/group_vars/all.yml`, and now
  `clusters/lab/platform/traefik.yaml`. That last one is a literal rather
  than a reference because Argo renders the manifest straight from git with
  no templating layer that could reach the others; miss it and every record
  external-dns writes from then on is stale.

---

## 9. If it goes wrong (rollback ladder, cheapest first)

1. **external-dns wrote something unexpected** — re-add `extraArgs:
   ["--dry-run"]` to `external-dns.yaml`, merge (Argo applies it in a sync
   cycle; `argocd app sync external-dns` over WG if you want it now). Then
   delete the offending record *and its ownership TXT* by hand. Re-adding
   dry-run does not undo writes — it only stops further ones.
2. **Traffic is on the new server and shouldn't be** — set `manage_dns =
   false` and apply. Note what this does: Tofu *destroys* the apex, wildcard
   and `vpn.` records rather than reverting the apex to `94.75.211.144`,
   because the gate empties the `for_each` map. The apex being gone is worse
   than the apex being wrong. **Prefer editing the apex record back to
   `94.75.211.144` in the Cloudflare dashboard** — it puts traffic back in
   seconds and leaves the plan to reconcile afterwards (Tofu will show drift
   and want to set it back; keep the flip PR reverted until you have decided
   what you want).
3. **The zone is in an unrecognisable state** — the §4 snapshot is a full
   BIND export. Cloudflare's dashboard imports one, and the TSV is enough to
   rebuild by hand. This is why §4 is not optional.
4. **A name the old server needs stopped resolving** — check for a duplicate
   apex A record first (§5a's trap); that is by far the most likely cause.
5. **One of §6a's six suppressing names has no `_externaldns.a-` TXT** long after §6b
   merged — external-dns has not created it, and the wildcard is covering
   for the gap, so the name still resolves to the right address and nothing
   looks broken (§7). Check the logs for that host and confirm the `CNAME`
   really is gone (a second, forgotten record at the same name is enough to
   re-arm the ownership gate). Re-creating the CNAME permanently blocks
   external-dns from owning the name and buys nothing the wildcard is not
   already giving you.
