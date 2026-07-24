# clusters/lab

**Layer 3 — Deliver.** The Argo CD app-of-apps root for the `lab` cluster —
everything here is reconciled from git; nothing is applied by hand.

- `bootstrap/` — Argo CD Helm values, the ksops repo-server patch, and
  `root-app.yaml` (Phase 4, live — see [`docs/bootstrap.md`](../../docs/bootstrap.md)).
- `platform/` — cert-manager, external-dns, Traefik, Authelia, ksops-encrypted
  secrets, and a placeholder `monitoring/` namespace (Phase 5).
- `apps/` — the media stack: Plex, Prowlarr, Sonarr, Radarr, Bazarr, Deluge,
  Overseerr, each a small `values.yaml` against the shared
  `bjw-s/app-template` Helm chart (Phase 6).

See [`docs/architecture.md`](../../docs/architecture.md) for the full design.
