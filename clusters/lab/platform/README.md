# platform

Cluster platform services, synced before any media app depends on them:

- `argo-cd.yaml` — Argo CD self-management. A multi-source `Application` that
  adopts the bootstrap-installed `argo-cd` helm release and reconciles it
  from the same `../bootstrap/argocd-values.yaml`. Discovered by `root-app`
  recursing this directory. **Implemented (Phase 4).**
- `cert-manager` — Let's Encrypt DNS-01 via Cloudflare, wildcard
  `*.tomkatom.com`.
- `external-dns` — Cloudflare records follow Ingress objects.
- `traefik` — ingress controller on `:443` (klipper servicelb, no MetalLB).
- `authelia` — forward-auth (file users + TOTP, SQLite) in front of the
  *arr/Deluge UIs.
- `secrets/` — ksops-encrypted Kustomize overlays consumed by the apps above
  via `existingSecret`.
- `monitoring/` — placeholder namespace; kube-prometheus-stack + Loki land
  here later (Phase 7).

Everything except `argo-cd.yaml` is not yet implemented — built in Phase 5.
