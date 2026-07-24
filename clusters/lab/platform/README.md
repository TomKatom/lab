# platform

Cluster platform services, synced before any media app depends on them:

- `argo-cd.yaml` — Argo CD self-management. A multi-source `Application` that
  adopts the bootstrap-installed `argo-cd` helm release and reconciles it
  from the same `../bootstrap/argocd-values.yaml`. Applied by `root-app` as a
  top-level `platform/*.yaml` manifest — see "Component layout" below for how
  `root-app` discovers things from Phase 5 onward. **Implemented (Phase 4).**
- `cert-manager` — Let's Encrypt DNS-01 via Cloudflare, wildcard
  `*.tomkatom.com`.
- `external-dns` — Cloudflare records follow Ingress objects.
- `traefik` — ingress controller on `:443` (klipper servicelb, no MetalLB).
- `authelia` — forward-auth (file users + TOTP, SQLite) in front of the
  *arr/Deluge UIs.
- `monitoring/` — placeholder namespace; kube-prometheus-stack + Loki land
  here later (Phase 7).

Everything except `argo-cd.yaml` is not yet implemented — built in Phase 5.

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

## Pre-merge review

CI's `render-manifests` job renders every top-level platform `Application`
(`helm template` for chart Applications, `kustomize build` for overlays,
skipping ksops overlays it has no key to decrypt) as a syntax/schema
preview. For an exact, ksops-decrypted preview of a change to an
*already-created* Application, run `argocd app diff <app> --revision
<branch>` over WireGuard before merging.
