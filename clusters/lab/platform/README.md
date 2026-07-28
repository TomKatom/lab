# platform

Cluster platform services, synced before any media app depends on them:

- `argo-cd.yaml` — Argo CD self-management. A multi-source `Application` that
  adopts the bootstrap-installed `argo-cd` helm release and reconciles it
  from the same `../bootstrap/argocd-values.yaml`. Applied by `root-app` as a
  top-level `platform/*.yaml` manifest — see "Component layout" below for how
  `root-app` discovers things from Phase 5 onward. **Implemented (Phase 4).**
- `cert-manager.yaml` + `cert-manager-config.yaml` + `cert-manager/` — ACME
  via the Cloudflare DNS-01 solver. Two `ClusterIssuer`s
  (`letsencrypt-staging`, `letsencrypt-prod`) share one API-token Secret.
  **Implemented (Phase 5).** See "Issuing a certificate" below.
- `external-dns.yaml` + `external-dns-config.yaml` + `external-dns/` —
  Cloudflare records follow Ingress objects. **Implemented (Phase 5), and
  deliberately inert** — it runs with `--dry-run` until the DNS cutover. See
  "DNS records from Ingresses (inert)" below.
- `traefik.yaml` + `traefik-config.yaml` + `traefik/` — ingress controller on
  `:443` (klipper servicelb, no MetalLB). Owns the real `*.tomkatom.com`
  wildcard `Certificate`, because Traefik's default `TLSStore` can only read
  a Secret from its own namespace. **Implemented (Phase 5).** See "Exposing a
  service" below.
- `authelia.yaml` + `authelia-config.yaml` + `authelia/` — forward-auth
  (file users + TOTP, SQLite) in front of the *arr/Deluge UIs.
  **Implemented (Phase 5).** See "Protecting a service with forward-auth"
  below.
- `apps.yaml` — **not a platform component**, but the media stack's
  entrypoint: a chart-free `Application` at sync-wave `"3"` (after every
  platform wave) whose `source.path` is `clusters/lab/apps`, non-recursive
  (the default — see "Component layout" below for why the field is left
  unset rather than set to `false`). `root-app` applies it as an ordinary
  top-level `platform/*.yaml` manifest, and it in turn discovers every
  `clusters/lab/apps/*.yaml` Application — see
  [`../apps/README.md`](../apps/README.md). **Implemented (Phase 6).**
- `monitoring/` — placeholder namespace; kube-prometheus-stack + Loki land
  here later (Phase 7).

Every platform component Phase 5 set out to build is now in place;
`monitoring/` is the only entry above still a placeholder, and it belongs to
Phase 7.

## Component layout

`root-app` (`../bootstrap/root-app.yaml`) sets `directory.recurse: false` —
it applies only the top-level `platform/*.yaml` Application manifests and
does not scan subdirectories. Each platform component instead follows a
three-piece convention:

- `<component>.yaml` — chart `Application` (top-level, applied by
  `root-app`). Single-source, referencing a remote Helm chart with inline
  `helm.valuesObject`.
- `<component>-config.yaml` — kustomize-source `Application` (top-level,
  applied by `root-app`), pointing at `./<component>/`.
- `<component>/` — the kustomize overlay itself: CRs plus a ksops-encrypted
  Secret. **Not** scanned by `root-app` directly — pulled in only via the
  sibling `<component>-config.yaml` Application.

`apps.yaml` is the one file here that is none of those three: it is a
top-level Application like the first kind, but its source is a *directory
of Applications* (`clusters/lab/apps`) rather than a Helm chart, so it
repeats this same non-recursive discovery contract one layer down for
the media stack. Adding an app is dropping a file into
`clusters/lab/apps/`; nothing here changes.

Unlike `root-app.yaml`, `apps.yaml` does **not** set `directory.recurse:
false` explicitly — it relies on the default. `apps.yaml` is itself a
resource `root-app` continuously diffs against git (root-app.yaml is not:
it's applied once by the Ansible bootstrap role), and Argo CD's `recurse`
field is `omitempty` — an explicit `false` gets dropped on persist, so the
live object permanently disagrees with git and the `apps` Application
never leaves OutOfSync (upstream: argoproj/argo-cd#4501). Omitting the
field sidesteps it entirely.

## Issuing a certificate

Ask for one by name — reference a `ClusterIssuer` from a `Certificate`
anywhere in the cluster:

```yaml
issuerRef:
  name: letsencrypt-staging  # or letsencrypt-prod
  kind: ClusterIssuer
```

Two things about this that are easy to get wrong:

- **Iterate on `letsencrypt-staging`.** Its certs are browser-untrusted but
  it has its own rate-limit bucket. The production bucket is keyed on the
  registered domain `tomkatom.com`, which the still-live old server also
  draws from — so prod issuance stays deliberately rare.
- **The issued Secret lands in the `Certificate`'s namespace**, not
  cert-manager's, and Kubernetes Secrets don't cross namespaces. Put the
  `Certificate` where the consumer is.

The Cloudflare API token both issuers authenticate with lives in
`cert-manager/cloudflare-api-token.sops.yaml` (Zone:DNS:Edit + Zone:Read on
`tomkatom.com`). It sits in the `cert-manager` namespace because that is
cert-manager's *cluster resource namespace* — where a `ClusterIssuer`'s
`apiTokenSecretRef` is resolved from, wherever the `Certificate` lives.
Rotating it is the usual SOPS loop: `sops <that file>` → edit → commit →
merge.

## Exposing a service

A plain `Ingress` with a `*.tomkatom.com` host is enough — no
`ingressClassName`, no `tls:` block:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: sonarr
spec:
  rules:
    - host: sonarr.tomkatom.com
      http:
        paths: [...]
```

Traefik's `IngressClass` is the cluster default, and its `default` `TLSStore`
serves `wildcard-tomkatom-tls` (issued by `traefik/wildcard-certificate.yaml`
into the `traefik` namespace) for any host that doesn't ask for its own
certificate.

That Certificate carries **two** names, not one: `*.tomkatom.com` matches
exactly one label, so the bare apex needs its own SAN, and it has one
because Homepage's Ingress is `tomkatom.com` itself
(`../apps/homepage.yaml`). Any *other* apex-hosted Ingress added later is
covered by the same Secret with no cert-manager change; a `<x>.<y>.tomkatom
.com` two-label host would not be, and would need its own `Certificate`.

Three consequences worth knowing:

- **There is no `:80`.** Only the `websecure` entrypoint is published on the
  Service, so klipper binds `:443` on the node and nothing else — matching
  the DNAT rules, which forward `443` and not `80`. Nothing redirects
  plaintext HTTP because nothing can reach it.
- **Cross-namespace `Middleware` references work** (`allowCrossNamespace`),
  which is how an app opts into Authelia forward-auth:
  `traefik.ingress.kubernetes.io/router.middlewares:
  authelia-forwardauth@kubernetescrd`.
- **`kubectl get ingress` reports the public IP**, not the node's
  `10.10.10.10`. Traefik writes `ingressEndpoint.ip` from `traefik.yaml`
  into every Ingress status instead of copying its own LoadBalancer
  address, because that status field is exactly where external-dns reads
  the target it publishes. Both halves of that setting are load-bearing —
  see "DNS records from Ingresses (inert)" below.

## Protecting a service with forward-auth

Add the cross-namespace Middleware annotation to the Ingress:

```yaml
metadata:
  annotations:
    traefik.ingress.kubernetes.io/router.middlewares: authelia-forwardauth@kubernetescrd
```

That's it — `access_control.default_policy: deny` plus a `*.tomkatom.com`
rule in `authelia.yaml` already covers every host, so a new Ingress is
protected the moment the annotation lands. Two things worth knowing:

- **Don't add this annotation to Authelia's own Ingress**
  (`authelia/ingress-auth.yaml`). The portal must stay reachable
  unauthenticated — putting it behind its own forward-auth is a lockout
  loop.
- **Authelia's two Applications sync in the opposite order from every
  other component here.** `authelia-config.yaml` (the PVC, the four ksops
  secrets, this Middleware) is wave 1; `authelia.yaml` (the chart) is wave
  2 — the reverse of cert-manager/Traefik's chart-then-CRs ordering. There's
  no CRD/webhook here to wait for; instead the Pod needs its PVC and secret
  files to already exist the instant it starts, so the config half must
  land first and therefore also carries `CreateNamespace=true`.

### Adding or changing a user

Users live in `authelia/users-database.sops.yaml`, encrypted whole. There is
no redeploy:

```sh
authelia crypto hash generate argon2 --password '...'   # or run it interactively
sops clusters/lab/platform/authelia/users-database.sops.yaml
# add the user + argon2id hash, save, commit, PR, merge
```

Argo updates the Secret on merge. **Authelia picks it up on its next
container restart, not instantly** — the file is mounted with `subPath`
(it has to be: it nests inside the SQLite PVC's own `/config` mount), and a
`subPath` mount re-resolves on container restart rather than tracking the
Secret live. Restart the Pod if you need the change now.

### Smoke-testing forward-auth end to end

Worth doing after any change to Traefik, Authelia, or the wildcard cert.
Apply a throwaway protected Ingress, check it, delete it — do **not** commit
it into `platform/`, which is steady state only:

```sh
kubectl create ns whoami-test
kubectl -n whoami-test create deployment whoami --image=traefik/whoami:v1.11.0
kubectl -n whoami-test expose deployment whoami --port=80
kubectl -n whoami-test create ingress whoami \
  --rule='whoami-test.tomkatom.com/*=whoami:80' \
  --annotation traefik.ingress.kubernetes.io/router.middlewares=authelia-forwardauth@kubernetescrd

# all three checks run over WireGuard, against the node — never public DNS
curl -sI --resolve whoami-test.tomkatom.com:443:10.10.10.10 \
  https://whoami-test.tomkatom.com          # 302 → auth.tomkatom.com, real LE chain
kubectl -n whoami-test get ingress whoami \
  -o jsonpath='{.status.loadBalancer.ingress[*].ip}'   # 145.239.3.55, not 10.10.10.10

kubectl delete ns whoami-test
```

A `302` to `auth.tomkatom.com?rd=...` is the pass: it proves the wildcard
cert served, Traefik routed, and the Middleware resolved cross-namespace. A
`200` means forward-auth did **not** engage — check the annotation. Note
external-dns logs a would-create for the new host while the Ingress exists;
that is dry-run doing its job, and it disappears with the namespace.

## DNS records from Ingresses (inert)

external-dns watches `Ingress` objects and would publish an A record per
host into the `tomkatom.com` Cloudflare zone. **It currently publishes
nothing.** `extraArgs: ["--dry-run"]` in `external-dns.yaml` makes it
authenticate, read the zone, and log every record it *would* write, then
return before touching anything.

That is not a soft default, but it guards a narrower thing than it looks
like. Worth being precise about, because the cutover depends on it:

- **It cannot take a hostname away from the old server.** Every name that
  server actually serves has an *explicit* record — `sonarr`, `radarr`,
  `prowlarr`, `deluge`, `bazarr` and `www` are each a `CNAME` to the apex,
  verified by `dig` (`bazarr` is easy to miss: it has a cluster Ingress
  like the others below, but is still one of the old server's hand-made
  CNAMEs; `www` gains a cluster Ingress via a separate PR against
  `clusters/lab/apps/homepage.yaml`, at which point it joins this list for
  real — see `docs/runbooks/dns-cutover.md` §0); a random name under the
  zone returns `NXDOMAIN`, so **there is no wildcard DNS record** (the old
  server has a wildcard *certificate*, which is a different thing). A name
  that already has a record external-dns does not own is unreachable to it
  — see `policy: sync` below.
- **What it does guard is the one unconditional write: creating a name the
  zone does not have yet.** `auth.tomkatom.com` and the media hosts that
  were never CNAME'd (`tautulli.`, `maintainerr.`, `requests.`)
  resolve to nothing today, so those are real creates — and a create makes
  a new-server service resolve publicly while the old server is still the
  one in production. That timing, not safety, is what the flag buys now.
  (`plex.tomkatom.com` is not on that list and never will be: Plex has no
  Ingress, so external-dns never sees it — plex.tv brokers clients straight
  to the DNAT'd `145.239.3.55:32400`.)
- **The apex is on neither list.** Homepage's Ingress is `tomkatom.com`
  itself (`../apps/homepage.yaml`), so external-dns does see the bare name
  — and can do nothing with it either way: a record it does not own already
  sits there, which blocks a create exactly as it blocks a take-over. The
  apex A record is Tofu's (`infra/tofu/cloudflare.tf`) before and after the
  cutover. Homepage is therefore the one host here whose record does not
  arrive with the `--dry-run` removal; it arrives with `manage_dns=true`,
  one flip earlier.

So the flag comes off exactly once, as a deliberate step in
[`docs/runbooks/dns-cutover.md`](../../../docs/runbooks/dns-cutover.md),
alongside flipping `manage_dns=true` in Tofu. Never as a drive-by edit.

Three settings worth knowing before that day:

- **`txtOwnerId: lab-k3s`** is stamped into an ownership TXT record beside
  everything external-dns creates. Two servers share this zone; the owner ID
  is how external-dns tells its own records from the ones it must not touch.
  The TXT's name carries a record-type infix: an A record at
  `auth.tomkatom.com` is tracked by `_externaldns.a-auth.tomkatom.com`, a
  CNAME by `cname-`. Easy to look up the wrong name otherwise.
- **`policy: sync`**, not the chart default `upsert-only`. `upsert-only`
  never issues a delete at all, so every retired Ingress would strand a
  permanent A + TXT pair on a shared zone that nothing in git accounts for.
  `sync` is safe here because reach is scoped by *ownership*, not by policy,
  at two independent layers in v0.21.0:

  1. `plan.calculateChanges` filters `Delete`/`UpdateOld`/`UpdateNew` through
     `FilterEndpointsByOwnerID`, and `appendTakenDNSNameChanges` drops a
     `Create` outright unless *every* record already at that name is owned by
     us ([`plan/plan.go`](https://github.com/kubernetes-sigs/external-dns/blob/v0.21.0/plan/plan.go#L230)).
  2. `TXTRegistry.ApplyChanges` re-filters the same three
     ([`registry/txt/registry.go`](https://github.com/kubernetes-sigs/external-dns/blob/v0.21.0/registry/txt/registry.go#L335)).

  An endpoint with no owner label fails both, and the old server's records
  and Tofu's `manage_dns` apex/`vpn.` records have no ownership TXT. Delete
  an owner TXT by hand and external-dns forgets the record instead of
  cleaning it up — so remove the Ingress, not the TXT.
- **`sources: [ingress]`**, narrowed from the chart's `[service, ingress]`,
  to keep external-dns off Services it has no business publishing — the
  rendered ClusterRole then grants `ingresses` get/watch/list and nothing
  more. It buys nothing on the *target*, though: external-dns takes that
  from `status.loadBalancer.ingress[].ip` on the Ingress, which Traefik
  fills in either way.

**The target is fixed in `traefik.yaml`, not here.** Left at chart defaults,
Traefik copies its own LoadBalancer address into every Ingress status —
`10.10.10.10`, since klipper binds the node — and external-dns would publish
RFC1918 space into a public zone. So `traefik.yaml` sets
`providers.kubernetesIngress.publishedService.enabled: false` **and**
`ingressEndpoint.ip: 145.239.3.55`. Both, in that combination: Traefik's
`updateIngressStatus` returns early on `publishedService` and never looks at
`ip`, so the second setting alone is silently a no-op, and the chart defaults
the first to `true`. **Re-check `kubectl get ingress -A` shows the public IP
after any Traefik chart bump** — that is the realistic way this regresses,
and external-dns's logs will not tell you (the Cloudflare provider never logs
a target).

The Cloudflare token is the same one cert-manager uses, encrypted a second
time into the `external-dns` namespace (`external-dns/cloudflare-api-token.sops.yaml`),
because Secrets don't cross namespaces. **Rotating it means editing both
files in one commit.**

## Pre-merge review

CI's `render-manifests` job renders every top-level platform `Application`
(`helm template` for chart Applications, `kustomize build` for overlays,
skipping ksops overlays it has no key to decrypt) as a syntax/schema
preview, then validates every CR and `Application` file directly against
real CRD schemas from a pinned `datreeio/CRDs-catalog` commit. That last
step is why a misspelled field in a `ClusterIssuer` or `Middleware` now
fails CI instead of failing live: kubeconform's built-in schemas cover no
CRD, and a resource with no schema is *skipped*, not validated. It runs
without `-ignore-missing-schemas`, so adding a resource from a CRD the
catalog doesn't carry is a deliberate step (add a `-schema-location`), not a
silent pass.

Two things it still cannot see, both by design:

- **Chart values.** `helm template` proves a values file renders; it cannot
  prove the value takes effect. Read the rendered container args when a
  setting is load-bearing — Traefik's `ingressEndpoint` and external-dns's
  `--dry-run` are both settings whose absence renders perfectly.
- **Anything null in a `helm.valuesObject`.** Argo's API server strips nulls
  before Helm sees them ([argo-cd#16312](https://github.com/argoproj/argo-cd/issues/16312)),
  so `key: null` renders correctly in CI and does nothing live. Always find
  the positive form of the setting.

For an exact, ksops-decrypted preview of a change to an *already-created*
Application, run `argocd app diff <app> --revision <branch>` over WireGuard
before merging.
