# platform

Cluster platform services, synced before any media app depends on them:

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

Not yet implemented — built in Phase 5.
