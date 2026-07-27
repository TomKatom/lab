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
old server's four hand-made `CNAME`s** (§6a). They are not in git, external-dns
cannot touch them, and while they exist it silently declines to create the
records that replace them.

Everything in Phase 5 was built so that neither flip can be a surprise. This
runbook is the forward procedure; §9 is the rollback ladder.

**This runbook has never been executed.** Every command below is written from
the live zone state and the pinned upstream sources, but the first run is the
first proof — treat unexpected output as a reason to stop, not to improvise.

---

## 0. The state you are starting from

Verified by public `dig` (read-only, no server access needed — re-run it
before you begin, the zone is shared and can change under you):

| Name | Today | Serves |
|---|---|---|
| `tomkatom.com` | `A 94.75.211.144` | old server |
| `sonarr` / `radarr` / `prowlarr` / `deluge` | `CNAME → tomkatom.com` | old server |
| `*.tomkatom.com` | **NXDOMAIN** | nothing — there is no wildcard *record* (the old server has a wildcard *certificate*, which is a different thing) |
| `vpn` / `auth` / `bazarr` / `tautulli` / `maintainerr` / `home` / `requests` | **NXDOMAIN** | nothing — these are the cluster's own hosts, reachable over WireGuard only |
| `*.lab.tomkatom.com` | `A` (internal addresses) | new server, WireGuard-only, already Tofu-managed and ungated |
| `_externaldns.*` | **NXDOMAIN** | nothing — external-dns has written zero records since it was deployed |

`plex.tomkatom.com` is absent from that table on purpose: **Plex has no
Ingress and needs no record at all.** Remote clients are brokered by
plex.tv straight to `145.239.3.55:32400`, which the host already DNATs to
the node, so external-dns never sees a Plex host and never creates one —
before or after this cutover.

```sh
dig +short tomkatom.com A
dig +short sonarr.tomkatom.com
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
with **no** record at all. Today that means the six cluster hosts nothing
else claims — `auth.`, `bazarr.`, `tautulli.`, `maintainerr.`, `home.` and
`requests.`. That is what `--dry-run` is standing in for, and it is a
timing guard (do not make new-server services resolve before you mean to),
not a safety guard.

**Corollary that shapes the whole procedure:** the four names the old server
serves are already `CNAME`s, so external-dns will *never* adopt them — and,
less obviously, **it will never *create* them either, for as long as those
CNAMEs exist.** `appendTakenDNSNameChanges` drops the `Create` because a
record it does not own is already sitting at the name; nothing is logged as
refused, the host simply never appears. So the CNAMEs do not just survive
the cutover, they suppress it for those four hosts. Deleting them by hand is
therefore a required step of this runbook, not decommissioning cleanup —
§6a.

---

## 2. Preconditions

Do not proceed until every row is green.

| # | Precondition | How to check |
|---|---|---|
| 1 | **Phase 6 apps are live on this cluster**, with an Ingress each | `kubectl get ingress -A` over WG lists every host the old server serves |
| 2 | Each of those Ingresses answers on the real wildcard cert | `curl -sI --resolve <host>:443:10.10.10.10 https://<host>` → 200/302, LE chain |
| 3 | **Every Ingress publishes the public IP, not `10.10.10.10`** | §3 — this is the hard gate |
| 4 | Media data is on the new server and the old server is ready to stop serving | operator judgement; the flip is near-instant to reverse but the traffic is real |
| 5 | Cloudflare token in `secrets.sops.tfvars.json` really carries `Zone:DNS:Edit` | already proven — the `lab.` management records were created with it |
| 6 | The flip PRs are clean, minimal diffs with CI green | `gh pr diff <PR#>`, `gh pr checks <PR#>` |

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

Equivalent read-only API call, with the token this repo already holds:

```sh
CF_TOKEN=$(sops -d infra/tofu/secrets.sops.tfvars.json | grep cloudflare_api_token | cut -d'"' -f2)
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
curl -sI https://tomkatom.com | head -1          # the new server's Traefik answers
```

Then open a follow-up PR deleting the `import` block (it has done its job;
leaving it is harmless but it reads like pending work). At this point every
name on the zone resolves to the new server, and external-dns has still
written nothing.

---

## 6. Flip 2 — remove `--dry-run`

### 6a. Pre-flight: free the four taken names

**Do this before removing the flag, and only once the old server has
stopped serving.** `sonarr.` `radarr.` `prowlarr.` `deluge.tomkatom.com` are
unowned `CNAME`s to the apex. External-dns will not create an A record at a
name where a record it does not own already sits (§1), and it says nothing
when it declines — so left in place, these four hosts would simply never
appear on the new server's side of the zone, while every other host would.
Nothing downstream would look broken; they would keep resolving to whatever
the apex points at.

They are also the only four this applies to. Every other cluster host is
NXDOMAIN (§0) and needs no preparation.

Delete them by hand in the Cloudflare dashboard (`tomkatom.com` → DNS →
Records → the four `CNAME` rows → Delete), or with the token from §4:

```sh
for h in sonarr radarr prowlarr deluge; do
  ID=$(curl -s -H "Authorization: Bearer $CF_TOKEN" \
    "https://api.cloudflare.com/client/v4/zones/$ZONE/dns_records?type=CNAME&name=$h.tomkatom.com" \
    | jq -r '.result[0].id // empty')
  [ -n "$ID" ] || { echo "$h: no CNAME, nothing to do"; continue; }
  curl -s -X DELETE -H "Authorization: Bearer $CF_TOKEN" \
    "https://api.cloudflare.com/client/v4/zones/$ZONE/dns_records/$ID" | jq -r '.success'
  echo "$h deleted"
done

for h in sonarr radarr prowlarr deluge; do
  printf '%-24s %s\n' "$h.tomkatom.com" "$(dig +short "$h.tomkatom.com" | tr '\n' ' ')"
done   # all four empty — NXDOMAIN
```

**A NXDOMAIN window is expected and normal here**, from this delete until
external-dns's first live sync after §6b lands. Those four are admin UIs,
reachable over WireGuard against `10.10.10.10` throughout (the `curl
--resolve` form used everywhere in this repo), so the window costs nothing
but do not be surprised by it — and do not "fix" it by re-creating a CNAME,
which puts the suppression straight back.

Confirmation that the gate has actually cleared, while still in dry-run:
those four names now show up as would-creates where before they were absent
entirely.

```sh
kubectl -n external-dns logs deploy/external-dns --tail=200 | grep -i 'sonarr\|radarr\|prowlarr\|deluge'
```

### 6b. Remove the flag

One-line PR against `clusters/lab/platform/external-dns.yaml`: delete the
`extraArgs: ["--dry-run"]` block. Merge, and Argo applies it within a sync
cycle.

With §6a done, expect it to create an A + ownership TXT for **all ten**
cluster hosts — `auth. sonarr. radarr. bazarr. prowlarr. deluge. tautulli.
maintainerr. home. requests.` — and nothing else. The log line for a run
with nothing left to do is `All records are already up to date`.

```sh
kubectl -n external-dns logs deploy/external-dns | grep -E 'Changing record|up to date'
```

There should be **no** `Changing record.` line naming `tomkatom.com`,
`vpn.tomkatom.com`, or any other name from the §4 snapshot that is not one
of those ten. If there is, re-add `--dry-run` immediately (§9) — the
ownership contract is not behaving as read, and nothing below is
trustworthy.

---

## 7. Verify the ownership contract

This is the check that matters most, because it is what keeps the *next* few
years of Ingress churn from touching records external-dns did not create.

**Every record external-dns created has a paired ownership TXT.** Mind the
record-type infix: the TXT for an A record at `auth.tomkatom.com` is
`_externaldns.` + `a-` + the host.

The set is exactly the hosts with an Ingress — every `*.tomkatom.com` host
this cluster serves, and no more. **`plex` is not among them**: Plex has no
Ingress, so external-dns never creates a record for it, and remote access
is brokered by plex.tv straight to `145.239.3.55:32400` (§0).

```sh
for h in auth sonarr radarr bazarr prowlarr deluge tautulli maintainerr home requests; do
  echo "== $h"
  dig +short "$h.tomkatom.com" A                        # 145.239.3.55
  dig +short "_externaldns.a-$h.tomkatom.com" TXT       # heritage=external-dns,external-dns/owner=lab-k3s,...
done
```

The four that were CNAMEs until §6a must now read as plain A records with an
ownership TXT beside them, like every other row. An empty A **and** an empty
TXT for one of them means external-dns still sees something at that name —
re-check that §6a's delete actually took.

**Nothing else grew one.** Tofu's records must have no ownership TXT at all
— that absence is the only thing keeping `policy: sync` off them:

```sh
for h in tomkatom.com vpn.tomkatom.com; do
  for pfx in a- cname-; do
    printf '%-40s %s\n' "_externaldns.$pfx$h" \
      "$(dig +short "_externaldns.$pfx$h" TXT)"
  done
done
```

Every line must show an empty value.

**Diff the whole zone against the snapshot.** Re-run §4's `curl` into
`~/tomkatom-zone-after.tsv` and `diff` them. The only new rows should be one
A + one TXT per cluster host, the only removed rows §6a's four `CNAME`s, and
the only changed row the apex's content. Anything else is unexplained and
worth chasing before you walk away.

> **Never delete an ownership TXT by hand.** external-dns then forgets it
> owns the record and stops managing it, rather than cleaning it up — you
> get a permanent orphan. Remove the Ingress; let external-dns remove both.

---

## 8. After the cutover

- **The old server's four `CNAME`s are gone** — §6a deleted them, and
  external-dns now owns a plain A record at each of those names. Nothing is
  left on this zone that external-dns cannot see; if a future host is ever
  hand-created as a CNAME again, the same suppression comes back with it.
- **Retire `vpn.lab.tomkatom.com`** in favour of the now-live
  `vpn.tomkatom.com` (`infra/tofu/locals.tf` says so at the record's
  definition). WireGuard peer configs naming the old endpoint need updating
  first — see `docs/runbooks/wireguard-peer.md`.
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
5. **One of §6a's four names is still NXDOMAIN** long after §6b merged —
   external-dns has not created it. Check the logs for that host and confirm
   the `CNAME` really is gone (a second, forgotten record at the same name is
   enough to re-arm the ownership gate). Re-creating the CNAME restores
   resolution immediately but permanently blocks external-dns from owning the
   name; only do that if the name must resolve *now*.
