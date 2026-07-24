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
- `external-dns` — Cloudflare records follow Ingress objects.
- `traefik` — ingress controller on `:443` (klipper servicelb, no MetalLB).
  Owns the real `*.tomkatom.com` wildcard `Certificate`, because Traefik's
  default `TLSStore` can only read a Secret from its own namespace.
- `authelia` — forward-auth (file users + TOTP, SQLite) in front of the
  *arr/Deluge UIs.
- `monitoring/` — placeholder namespace; kube-prometheus-stack + Loki land
  here later (Phase 7).

Everything not marked implemented above is still being built in Phase 5.

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

## Pre-merge review

CI's `render-manifests` job renders every top-level platform `Application`
(`helm template` for chart Applications, `kustomize build` for overlays,
skipping ksops overlays it has no key to decrypt) as a syntax/schema
preview. For an exact, ksops-decrypted preview of a change to an
*already-created* Application, run `argocd app diff <app> --revision
<branch>` over WireGuard before merging.
