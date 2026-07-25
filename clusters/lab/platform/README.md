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
certificate. Two consequences worth knowing:

- **There is no `:80`.** Only the `websecure` entrypoint is published on the
  Service, so klipper binds `:443` on the node and nothing else — matching
  the DNAT rules, which forward `443` and not `80`. Nothing redirects
  plaintext HTTP because nothing can reach it.
- **Cross-namespace `Middleware` references work** (`allowCrossNamespace`),
  which is how an app opts into Authelia forward-auth:
  `traefik.ingress.kubernetes.io/router.middlewares:
  authelia-forwardauth@kubernetescrd`.

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
  `prowlarr` and `deluge` are each a `CNAME` to the apex, verified by `dig`;
  a random name under the zone returns `NXDOMAIN`, so **there is no
  wildcard DNS record** (the old server has a wildcard *certificate*, which
  is a different thing). A name that already has a record external-dns does
  not own is unreachable to it — see `policy: sync` below.
- **What it does guard is the one unconditional write: creating a name the
  zone does not have yet.** `auth.tomkatom.com` and `plex.tomkatom.com`
  resolve to nothing today, so those are real creates.
- **And today every such create would point at `10.10.10.10`** — RFC1918
  space in a public zone. See the `sources` bullet below for why.

So the flag comes off exactly once, as a deliberate step in the cutover —
`docs/runbooks/dns-cutover.md` (Phase 5, PR6) — alongside flipping
`manage_dns=true` in Tofu **and fixing the published target**. Never as a
drive-by edit.

Three settings worth knowing before that day:

- **`txtOwnerId: lab-k3s`** is stamped into an ownership TXT record beside
  everything external-dns creates. Two servers share this zone; the owner ID
  is how external-dns tells its own records from the ones it must not touch.
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
  to keep external-dns off Services it has no business publishing. ⚠ **It
  does not avoid the `10.10.10.10` problem, despite how it was originally
  justified.** The Traefik chart renders
  `--providers.kubernetesingress.ingressendpoint.publishedservice=traefik/traefik`,
  so Traefik copies its LoadBalancer status onto every Ingress, and
  external-dns reads the target from there — the same internal address
  `sources: [service]` would have given, since klipper binds the node IP.
  Before dry-run comes off, the target has to be overridden: external-dns
  `--default-targets`, a per-Ingress
  `external-dns.alpha.kubernetes.io/target` annotation, or Traefik's
  `ingressEndpoint.ip`. Tracked as a cutover-runbook prerequisite.

The Cloudflare token is the same one cert-manager uses, encrypted a second
time into the `external-dns` namespace (`external-dns/cloudflare-api-token.sops.yaml`),
because Secrets don't cross namespaces. **Rotating it means editing both
files in one commit.**

## Pre-merge review

CI's `render-manifests` job renders every top-level platform `Application`
(`helm template` for chart Applications, `kustomize build` for overlays,
skipping ksops overlays it has no key to decrypt) as a syntax/schema
preview. For an exact, ksops-decrypted preview of a change to an
*already-created* Application, run `argocd app diff <app> --revision
<branch>` over WireGuard before merging.
