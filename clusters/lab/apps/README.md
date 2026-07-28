# apps

The media stack: Deluge, Prowlarr, Sonarr, Radarr, Bazarr, Unpackerr, Plex,
Seerr, Tautulli, Maintainerr, Recyclarr, Homepage, and the shared
`media-common` config, discovered the same way `platform/` is —
`clusters/lab/platform/apps.yaml` is a chart-free Application at sync-wave
`"3"` (after every platform wave 0-2, since every app here assumes Traefik,
Authelia, cert-manager and external-dns already exist) whose `source.path`
is this directory, non-recursive (the default — `directory.recurse` is
deliberately left unset rather than written as `false`; see
[`platform/README.md`](../platform/README.md#component-layout) for why).
Exactly like root-app one layer up, that means only the top-level
`apps/*.yaml` Application manifests are applied directly; each app's own
non-Application content — a kustomize overlay, a ksops-encrypted Secret —
lives in a same-named subdirectory and is pulled in only by that
component's own `<component>-config.yaml` Application. See
[`platform/README.md`](../platform/README.md#component-layout) for the
three-piece convention this mirrors.

Phase 6 built this directory — see [`master-plan.md`](../../../master-plan.md)
("Media apps") for where it sits in the overall build order.

## One `media` namespace, not one per app

Every platform component gets its own namespace. This stack deliberately
does not: `deluge`, `prowlarr`, `sonarr`, `radarr`, `bazarr`, `unpackerr`,
`plex`, `seerr`, `tautulli`, `maintainerr`, `recyclarr` and `homepage`
all land in a single `media` namespace.

The reason is the shared secrets, not laziness. `media-common` (wave 0,
below) holds one copy each of `arr-api-keys` and `telegram`, consumed by
most of the apps above. Kubernetes Secrets don't cross namespaces — giving
each app its own namespace would mean re-encrypting every shared secret
once per consuming namespace, the same way `external-dns` already carries
a second, separately-encrypted copy of the Cloudflare API token because it
sits in its own namespace from cert-manager's (see
[`platform/README.md`](../platform/README.md#dns-records-from-ingresses-inert)).
That one, documented 2-copy case is already a rotation hazard worth
calling out; this stack is ~10+ apps deep, and per-app namespaces would
turn it into ~10+ copies of the same two Secrets to keep in sync by hand
on every rotation. One namespace, one copy of each, is the deliberate
trade: the whole suite is one coupled trust domain anyway (they all talk
to each other's ClusterIP Services by design), so the usual argument for
namespace-per-component — blast-radius isolation between components that
don't trust each other — doesn't buy anything here.

## Identity: everything runs as 1000:1000

`1000:1000` is the `debian` user on the underlying VM, and the owner of
the `/data` hostPath tree (see below). Every app's `securityContext` is
this block verbatim unless documented otherwise:

```yaml
securityContext:
  runAsUser: 1000
  runAsGroup: 1000
  fsGroup: 1000
  runAsNonRoot: true
  fsGroupChangePolicy: OnRootMismatch
  seccompProfile:
    type: RuntimeDefault
  capabilities:
    drop: ["ALL"]
```

`fsGroupChangePolicy: OnRootMismatch` keeps `fsGroup`'s recursive chown
from re-running on every pod restart once ownership already matches — the
`/data` tree and the config PVCs are both large enough that a full chown
on every restart would be its own outage.

**Documented exception: Deluge.** The LinuxServer.io image boots as root
via its own `s6` init and drops privilege internally — it cannot be forced
through Kubernetes' `runAsUser` the way the `home-operations` images used
elsewhere in this stack can. Its manifest carries no
`securityContext.runAsUser`; instead it sets the LSIO-native identity env
directly:

```yaml
env:
  - name: PUID
    value: "1000"
  - name: PGID
    value: "1000"
  - name: UMASK
    value: "002"
```

**The exception costs two halves of the house block, not one.** Alongside
`runAsUser`/`runAsGroup`/`runAsNonRoot`, `deluge.yaml` also carries no
container-level `capabilities.drop: ["ALL"]`: `s6` needs `CAP_CHOWN`,
`CAP_SETUID`, `CAP_SETGID` and `CAP_DAC_OVERRIDE` to chown `/config` and
`/data` and then drop from root to `PUID`/`PGID`, so dropping ALL breaks
its startup rather than hardening it. What Deluge does keep is everything
that doesn't block a root start — `fsGroup`, `fsGroupChangePolicy` and
`seccompProfile: RuntimeDefault`. Any image needing the same treatment
should lose exactly those two pieces and no more.

If any other image later turns out to need root at container start
(verify at authoring time — the `home-operations` images used elsewhere in
this stack are confirmed rootless), give it the same shape of per-app note
explaining why, rather than silently weakening the house default.

## The `/data` mount

`/data` is a hostPath, mounted at the identical container path `/data` in
every app that touches it — never remapped, never split into separate
`/downloads` and `/media` mounts. That sameness is the point: Sonarr,
Radarr and Bazarr import by hardlinking a completed download from
`/data/torrents/...` into `/data/media/...`, and a hardlink only works
within one filesystem. Same path everywhere means zero Remote Path
Mappings to configure in any `*arr`, and the import step is a rename, not
a copy — instant regardless of file size, and the seeding copy under
`/data/torrents` keeps satisfying its tracker ratio after import.

Mount rules:

- **rw**: `deluge` (writes the downloads), `sonarr`/`radarr` (write
  imports into `/data/media`), `unpackerr` (extracts archives in place
  before the `*arr`s import them).
- **rw, and only at `/data/media`**: `bazarr` — it writes subtitle files
  beside the media and never reads or writes `/data/torrents`, so it gets
  the media subtree alone. Same path in the container as on the host, so
  this is a narrowing, not a remap: nothing about hardlinks or Remote Path
  Mappings changes.
- **ro**: `plex`, and only at `/data/media` — Plex only ever reads, never
  writes, the media tree, and has no business seeing `/data/torrents` at
  all.
- **nobody else.** `prowlarr`, `recyclarr`, `seerr`, `tautulli`,
  `maintainerr` and `homepage` never mount `/data` — none of them touch
  files, only APIs.

## The `/data` path contract

The section above says every app sees the same filesystem. This one says
what lives where in it, and it is the single description of that — three
manifests point here rather than each restating a third of it.

```
/data
├── torrents/                     seeding copies, never read by Plex
│   ├── tv/                       ← sonarr tells deluge to download here
│   ├── movies/                   ← radarr tells deluge to download here
│   ├── books/{audiobooks,ebooks,comics}/
│   ├── games/                    added by hand; the deluge label
│   └── programs/                 files these on completion
├── torrents-final/               .torrent copies (copy_torrent_file)
├── media/                        the Plex libraries, read-only to plex
│   ├── tv/                       ← sonarr root folder
│   └── movies/                   ← radarr root folder
├── .recyclebin/{sonarr,radarr}/  deleted media, kept 7 days
└── backups/{sonarr,radarr}/      the *arrs' own scheduled backups
```

A grab makes exactly one trip:

1. Sonarr/Radarr send the `.torrent` to Deluge's JSON-RPC with two extra
   things: a **category** (`tv` / `movies`) and a **download directory**
   (`/data/torrents/tv` / `/data/torrents/movies`).
2. Deluge downloads it there, in place. There is no incomplete directory,
   no blackhole directory, and no move on completion.
3. On completion the `*arr` imports by **hardlinking** into
   `/data/media/...` under its naming scheme. One inode, two names, no
   second copy of the bytes.
4. Deluge keeps seeding the original name forever. Plex reads
   `/data/media` and never sees a torrent.

Three files have to agree for that to hold, and they are edited together:

| End of the contract | Declared in |
|---|---|
| category name, and where a labelled torrent is filed | `deluge.yaml` → `label.conf` |
| category to send, and the directory to download into | `arr-settings/` → `downloadDirectory` |
| where to look for archives to extract | `unpackerr.yaml` → `UN_*_PATHS_0` |

Two consequences that are easy to get wrong:

- **`tv` and `movies` must not carry `apply_move_completed`.** The `*arr`
  already passed the final directory, so a label move would relocate data
  the `*arr` is mid-import on. Deluge reports `is_finished` before
  `storage_moved_alert`, so the import looks for files at a path the move
  has just emptied — that is the "import failed, retrying" loop, and it is
  a configuration bug rather than bad luck. Every other label *does* move
  on completion, because those torrents are added by hand with no client
  to pass a directory and would otherwise pile up at `/data/torrents`.
- **Nothing upstream deletes a torrent.** Deleting a series in Sonarr, or
  a Maintainerr retention rule firing, unlinks under `/data/media` and
  stops there — the `*arr`s only reach `core.remove_torrent` from *queue*
  operations, and Maintainerr's download-client cleanup is qBittorrent-only.
  So deleting media frees no space while the torrent still holds the inode,
  and pruning seeds is a deliberate act in Deluge. That is the correct
  default for private trackers: automatic removal keyed to library churn is
  how hit-and-runs happen.

## Ingress: chart-rendered, not a `-config` dir

Unlike `platform/`, where every Ingress-bearing CR lives in a component's
`-config` kustomize overlay, an app's Ingress here is a value inside its
own chart Application's `helm.valuesObject` (`app-template`'s `ingress:`
key) — one file per app holds host, Service and port together, and the
widened CI render step (see below) renders and validates it exactly like
the rest of the values. A `-config` dir only exists where there's
multi-file plain config with nothing to do with a chart's own resources
(`recyclarr`, `homepage`) or a ksops Secret to decrypt (`media-common`) —
see "Sync waves" and "Kustomize `-config` dirs" below.

House Ingress style is unchanged from `platform/` (see
[`platform/README.md`](../platform/README.md#exposing-a-service)): no
`ingressClassName`, no `tls:` block — Traefik is the cluster default
`IngressClass` and its default `TLSStore` already serves the
`wildcard-tomkatom-tls` Secret for any host that doesn't ask for its own
certificate. Every admin-facing host carries exactly this annotation to
sit behind Authelia:

```yaml
metadata:
  annotations:
    traefik.ingress.kubernetes.io/router.middlewares: authelia-forwardauth@kubernetescrd
```

Authelia's existing ACL already covers every new host here with zero
Authelia-side change: `access_control.default_policy: deny` plus one rule
for `*.tomkatom.com` at `two_factor` (`platform/authelia.yaml`) applies to
any hostname under the zone, new or old.

**Two Ingresses here deliberately carry no annotation at all**, and both
for the same reason — they are the two hosts aimed at people who hold a
Plex account and no Authelia identity, so forward-auth would lock out
exactly the audience they exist for. An un-annotated Ingress means Traefik
never consults the middleware for that host.

- **Seerr, `requests.tomkatom.com`** — end users authenticate through
  Seerr's own Plex OAuth login.
- **Homepage, `tomkatom.com`** — the front door: public hostnames and
  public plex.tv links, no Secret read, no app polled, `disableIndexing`
  set. Losing the *arr widgets is part of the same decision, not a
  separate one: a homepage widget renders what the credential it holds
  returns, so a queue counter on an unauthenticated page is a library
  inventory.

Everything else admin-facing gets the annotation. Note the apex is also
the one host here that Authelia's `*.tomkatom.com` rule would *not* match
even if it were annotated — a wildcard label does not cover the bare
domain, and `default_policy: deny` would then deny it outright. Anything
apex-hosted that ever does need protecting needs an Authelia ACL rule of
its own in the same commit.

## Single `source:`, always

An app's chart Application must never become a multi-source Application.
CI's widened render step (below) reads `.spec.source.chart` to decide
whether a file is a remote-chart Application worth rendering — a
multi-source Application has no `.spec.source` at all (it's
`.spec.sources`, a list), so the step's guard silently evaluates to empty
and skips the file entirely rather than failing loudly. A schema mistake
in a multi-source app manifest would pass CI unnoticed. Every app chart
here has exactly one `source:`,
`repoURL: https://bjw-s-labs.github.io/helm-charts`, `chart: app-template`,
pinned `targetRevision`, inline `helm.valuesObject`.

## Secrets and environment

Shared, ksops-encrypted, created once by `media-common` (wave 0, ns
`media`):

- **Secret `arr-api-keys`** — `SONARR_API_KEY`, `RADARR_API_KEY`,
  `PROWLARR_API_KEY`, `BAZARR_API_KEY`. Consumed by name, per key, via
  `env.valueFrom.secretKeyRef` wherever an app needs one of them (e.g.
  Sonarr's own `SONARR__AUTH__APIKEY`, Unpackerr's
  `UN_SONARR_0_API_KEY`) — never `envFrom` for this one, since apps only
  ever need a subset of the four keys. `BAZARR_API_KEY` is the odd one:
  Bazarr has no env override for its own key and nothing in the cluster
  calls Bazarr, so it is injected nowhere and exists only as the recorded
  copy of a value the migrated `config.yaml` has to match (`bazarr.yaml`).
- **Secret `telegram`** — `TELEGRAM_BOT_TOKEN`, `TELEGRAM_CHAT_ID`, for
  Seerr's and Tautulli's notification agents (configured in-app; the
  Secret only holds the credential).
- **Secret `tautulli-credentials`** — `PLEX_TOKEN`, `TAUTULLI_API_KEY`,
  both consumed by `tautulli.yaml` as environment variables. Tautulli
  reads `TAUTULLI_<SETTING>` ahead of its config.ini and refuses to save
  that setting from the UI while the variable is set, which makes its
  whole Plex connection declarable the way the *arrs' API keys are. Scoped
  to Tautulli rather than shared as a `plex` Secret because it is the only
  environment consumer of a Plex token — Seerr and Maintainerr
  authenticate to Plex from their own databases.
- **ConfigMap `media-env`** — `TZ: Asia/Jerusalem`, one value, and every
  app that cares about time zone consumes the whole map via `envFrom`
  rather than naming the single key.
- **ConfigMap `media-urls`** — the cluster-internal address of every app
  in the stack (`DELUGE_URL`, `SONARR_URL`, …), consumed per key via
  `env.valueFrom.configMapKeyRef`, same as `arr-api-keys` and never via
  `envFrom`. These apps talk to each other constantly, so the same
  `http://<svc>.media.svc.cluster.local:<port>` string is needed by
  several consumers at once; holding it in one place is what keeps a port
  change from being a multi-file edit with no way to confirm every copy
  was found.

  Treat it as a contract rather than a description. The entry here and
  the `service:` block in the app's own manifest are two declarations of
  one fact, and nothing validates them against each other — so a PR that
  changes a Service name or port changes both in the same commit.

### A Service's name depends on how many Services its app declares

app-template names a Service after the release when an app declares
exactly one, and appends the service identifier to **all** of them as
soon as it declares two or more
(`_determineResourceNameFromValues.tpl`). Sonarr declares one Service and
gets `sonarr`; Deluge declares three (the klipper mixed-protocol
workaround) and would get `deluge-app`, `deluge-bt-tcp`, `deluge-bt-udp`.

The trap is that this reacts to a change made for unrelated reasons:
adding a metrics Service to a single-Service app silently renames the one
every other app was already calling. Nothing fails at render time — the
in-chart `ingress.hosts.paths.service.identifier` reference follows the
rename, so the app keeps serving; only the consumers that reach it by DNS
break, and the *arrs' download-client and connection settings live in
their own databases rather than in git, so re-pointing them is manual
per-app work.

Deluge therefore pins its WebUI Service with `forceRename: deluge`. Any
app here that grows a second Service must do the same, or update its
`media-urls` entry in the same commit.

## Renovate: the image-tag comment convention

The `argocd` manager already bumps each app's `chart:`/`targetRevision:`
pin. It has no idea an inline `valuesObject` contains a container image
tag, though — that's a plain string a few levels deep in Helm values, not
a field either the `argocd` or `kubernetes` manager understands. A
`customManagers` regex closes the gap instead: it looks for a comment of
the exact shape `# renovate: datasource=docker depName=<image>` on the
line directly above a `tag:` key, anywhere under `clusters/lab/apps/`.
Every app's `valuesObject` must use this two-line form for its image:

```yaml
image:
  repository: ghcr.io/home-operations/sonarr
  # renovate: datasource=docker depName=ghcr.io/home-operations/sonarr
  tag: "4.0.15.2941@sha256:..."
```

Without the comment, Renovate has no way to find the tag at all — it will
never open a PR for it, silently, and the image pins here would rot
unnoticed.

The `@sha256:` digest is optional but preferred: the tag says which
version, the digest says which exact build, so a re-pushed tag can't
change what runs. Both forms are handled — the regex captures the version
into `currentValue` and the digest into a separate `currentDigest` group,
which is what lets Renovate bump the version *and* re-pin the digest in
the same PR.

That split is load-bearing, and its absence is a silent failure rather
than a loud one. A regex that swallows the whole `1.2.3@sha256:…` string
into `currentValue` hands Renovate something that is not a parseable
version; it finds no update and opens no PR, exactly as if the comment
were missing. If a digest-pinned image here ever stops receiving bumps,
check that group before anything else.

## local-path reclaim is `Delete`

Every config PVC in this stack uses the cluster's default StorageClass,
`local-path-provisioner`, whose reclaim policy is `Delete`: deleting the
PVC (or the Application that owns it, without care) deletes the
underlying data on the node with it — there is no recycle bin. Two
mitigations, neither automatic yet:

- The migration runbook's post-migration hardening step patches every
  config PV to `Retain` by hand once real data lives on it
  (`kubectl patch pv <pv> -p '{"spec":{"persistentVolumeReclaimPolicy":"Retain"}}'`),
  so a PVC delete afterwards orphans the PV instead of destroying the
  data.
- Every `*arr` has a built-in backup feature, pointed at
  `/data/backups/<app>` — on the same ZFS-backed tree as everything else,
  survives a PVC delete outright.

A full backup story (offsite, scheduled) is out of scope here and
deferred to Phase 8.

## Sync waves within `apps/`

- **`media-common` — wave `"0"`.** First into the `media` namespace, so it
  carries `syncOptions: [CreateNamespace=true]` — the same first-syncer
  rule `authelia-config.yaml` follows for the `authelia` namespace. Every
  other app's Secret/ConfigMap consumption assumes it already exists.
- **App charts — wave `"1"`** (`deluge`, `unpackerr`, `prowlarr`,
  `flaresolverr`, `sonarr`, `radarr`, `bazarr`, `plex`, `tautulli`,
  `seerr`, `maintainerr`), together with `recyclarr-config`'s and
  `homepage-config`'s own kustomize-source Applications.
- **`recyclarr` and `homepage` charts — wave `"2"`**, one wave after their
  own `-config` overlays, so the ConfigMap each mounts already exists the
  moment the Pod starts.

A first-sync race — an app Pod starting before `media-common` has
finished and hitting a secret-not-found — is expected and self-heals on
the next sync; it is not a bug to chase.

## Argo strips nulls in `valuesObject`

Same hard-won lesson as `platform/` (see
[`platform/README.md`](../platform/README.md#pre-merge-review)): Argo's
API server strips any `null` out of `helm.valuesObject` before Helm ever
sees it ([argo-cd#16312](https://github.com/argoproj/argo-cd/issues/16312)).
`key: null` renders correctly under CI's `helm template` (which doesn't go
through Argo's API server) and does nothing live. Never use `null` to
remove a chart default here — find the chart's own positive form of "off"
(an empty list, `enabled: false`, whatever the chart's
`values.schema.json` actually models) instead.

## Kustomize `-config` dirs

Most apps here have no `-config` directory at all — their entire manifest
is the one chart Application file, Ingress included. A `-config`
kustomize-source Application (mirroring `authelia-config.yaml`'s shape)
only exists where there's:

- **Multi-file plain config with no ksops Secret to decrypt** —
  `recyclarr-config` (a `recyclarr.yml` ConfigMap), `homepage-config`
  (Homepage's own config-as-code ConfigMaps) and `arr-settings-config`
  (the Sonarr/Radarr setting specs plus the script that applies them).
  CI's kustomize-build step actually builds and validates these, since it
  only skips a directory when it can detect a ksops `SecretGenerator`
  inside it.
- **A ksops Secret to decrypt** — `media-common`, the one directory in
  this stack that CI's kustomize step deliberately skips building (no
  `SOPS_AGE_KEY` in that job), the same way every platform `-config`
  overlay with a `.sops.yaml` file is skipped.

What splitting the config out costs, in both cases: app-template only
stamps its `checksum/configMaps` pod annotation — the thing that rolls a
Deployment when config content changes — over ConfigMaps declared in its
own `configMaps:` values. A ConfigMap owned by a separate Application is
invisible to it, so editing one of these directories syncs green in Argo
while the running Pod keeps the old content, and the restart is manual.
Weigh that drift window against the CI validation above before adding the
next `-config` dir; an app whose config changes often is better off with
the ConfigMap in its chart values.

## Media pipeline smoke test

The phase-level acceptance check, in the same shape as
[`platform/README.md`](../platform/README.md#smoke-testing-forward-auth-end-to-end)'s
whoami procedure: run it after the migration runbook's restores, after any
`app-template` chart bump, and any time the pipeline needs re-proving end
to end.

**Every check here is internal, over WireGuard.** Hostnames are resolved
at the node with `curl --resolve`, never through public DNS. Until
[`docs/runbooks/dns-cutover.md`](../../../docs/runbooks/dns-cutover.md)
runs, **six of the names below already resolve publicly — every one of
them to the old server**: the apex `tomkatom.com` (`A 94.75.211.144`) and
the five hand-made `CNAME`s to it, `sonarr.` `radarr.` `prowlarr.`
`deluge.` `bazarr.`. The rest (`tautulli.` `maintainerr.` `requests.`) are
NXDOMAIN. So `--resolve` is not belt-and-braces on any line here: drop it
on one of those six and the check quietly passes against **production**.
`docs/runbooks/media-migration.md` §4 step 6 has the same table, and the
`/etc/hosts` overrides to use when a browser is needed instead of `curl`.

### 1. Everything is Synced, Healthy and Running

```sh
kubectl -n argocd get applications
# every app Synced/Healthy: apps, media-common, deluge, unpackerr, prowlarr,
# flaresolverr, sonarr, radarr, bazarr, recyclarr(+-config), plex, tautulli,
# seerr, maintainerr, homepage(+-config), arr-settings(+-config)

kubectl -n media get pods
```

Every Deployment pod reads `1/1 Running`. Recyclarr and arr-settings are
CronJobs, so they appear only as `Completed` Job pods (or not at all
between runs) — that is correct, not a missing app.

### 2. Auth boundary: seven protected hosts, two that must not be

```sh
for h in sonarr radarr bazarr prowlarr deluge tautulli maintainerr; do
  printf '%-14s %s\n' "$h" "$(curl -sI --resolve "$h.tomkatom.com:443:10.10.10.10" \
    "https://$h.tomkatom.com" | grep -iE '^HTTP|^location' | tr -d '\r' | paste -sd' ' -)"
done
# each: HTTP/2 302  location: https://auth.tomkatom.com/?rd=...

curl -sI --resolve requests.tomkatom.com:443:10.10.10.10 \
  https://requests.tomkatom.com | head -1
# HTTP/2 200 — Seerr's own Plex-OAuth login, by design (no annotation)

curl -sI --resolve tomkatom.com:443:10.10.10.10 https://tomkatom.com | head -1
# HTTP/2 200 — Homepage, the front door, also by design (no annotation)
```

A `200` from any of the seven means the forward-auth annotation is missing
from that Ingress; a `302` from `requests.` or from the apex means one was
added that should not be there. Note there is no `-k` anywhere above: a TLS
error is itself the certificate check failing — and the apex line is the
only one that exercises the `tomkatom.com` SAN added to
`platform/traefik/wildcard-certificate.yaml`, since every other host is
covered by the wildcard.

`--resolve` is load-bearing on the apex line and on five of the seven
above it — `sonarr.` `radarr.` `prowlarr.` `deluge.` `bazarr.` are `CNAME`s
to the apex, so until the cutover runs all six resolve publicly to the old
server. Drop the flag on any of them and the check quietly passes against
production — and the old server runs its own Traefik and Authelia
(`media-migration.md` §2.1), so the response can look exactly like the one
this check is asking for.

### 3. Hardlink proof (the master-plan acceptance)

An imported file must be **one inode with two names** — once under
`/data/torrents`, once under `/data/media`. If it is two inodes, the import
copied instead of linking and the library is silently double-counting disk.

```sh
ssh debian@k3s.lab.tomkatom.com '
  f=$(find /data/media -type f -links +1 -print -quit)
  stat -c "%h links  inode %i  %n" "$f"
  find /data/torrents -samefile "$f"
'
# link count >= 2, and the same inode surfaces under /data/torrents/...
```

### 4. Deluge is reachable from the outside and seeding

```sh
ssh debian@k3s.lab.tomkatom.com 'ss -lntu | grep 51413'
# two rows: LISTEN on tcp/51413 and UNCONN on udp/51413 (the two klipper
# LoadBalancer Services), matching config/lab.yml's ports.torrent
```

In the Deluge WebUI, an active private-tracker torrent shows a recent
successful announce, and the tracker's own site reports the client address
as **`145.239.3.55`** — the host's public IP, which egress masquerade makes
Deluge announce from. A private address there means the NAT contract broke.

### 5. Plex: migrated identity, direct play, zero transcodes

```sh
curl -s http://10.10.10.10:32400/identity   # over WG — Plex has no Ingress
```

`machineIdentifier` must equal the value
[`media-migration.md`](../../../docs/runbooks/media-migration.md) §8
recorded from the old server's `Preferences.xml` — same identity means no
re-claim
and an intact watch history. Then play something to a remote client and
confirm in Plex's dashboard (or Tautulli) that the session reads **Direct
Play** with **zero** transcode sessions: this node has no GPU, so every
transcode is software libx264 and direct play is the design assumption.

### 6. The full end-user loop

The one check that exercises every app at once. Request a title in
`requests.tomkatom.com` → Seerr hands it to Sonarr/Radarr → Prowlarr's
indexers find it → Deluge downloads it → the `*arr` hardlink-imports it into
`/data/media` → Plex's library updates → Seerr flips it to **Available**
→ **a message lands in the Telegram group**. Tautulli's recently-added
digest follows on its own schedule.

Anything that stalls mid-chain localises immediately: no grab is a Prowlarr
or indexer problem, a grab with no import is a download-client path or
category problem, an import with no Plex update is the library-scan path
(virtiofs has no reliable inotify — the `*arr`→Plex Connect notification is
what refreshes it), and a Plex update with no Telegram message is the
notification agent.

### 7. external-dns is still inert, and still blind to the old server

Until the cutover runbook runs, this must all still be true:

```sh
kubectl -n external-dns logs deploy/external-dns --tail=200 \
  | grep -iE 'changing record|create|up to date'
# would-create lines for the never-existing hosts only — auth., tautulli.,
# maintainerr., requests. Nothing for sonarr./radarr./prowlarr./deluge./
# bazarr. (taken CNAMEs) and nothing for the bare apex either (Homepage's
# host; Tofu's record, equally unowned) — all six blocked by the same
# ownership gate. And no actual writes at all (--dry-run).

dig +short tomkatom.com A                        # 94.75.211.144 — old server
dig +short requests.tomkatom.com                 # empty — NXDOMAIN
dig +short _externaldns.a-auth.tomkatom.com TXT  # empty — nothing written yet
```

A `Changing record.` line naming a taken host, or any `_externaldns.*` TXT
existing, means the ownership contract is not behaving as read — stop and
re-read [`platform/README.md`](../platform/README.md#dns-records-from-ingresses-inert)
before going near the cutover.

## Migrating state from the old server

State migration (media files, `*arr` databases, Plex identity and watch
history, Deluge's session and active seeds) is entirely operator-executed
and out of scope for any Application here — see
[`docs/runbooks/media-migration.md`](../../../docs/runbooks/media-migration.md).
