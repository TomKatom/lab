# clusters/lab

**Layer 3 — Deliver.** The Argo CD app-of-apps root for the `lab` cluster —
everything here is reconciled from git; nothing is applied by hand.

- `bootstrap/` — Argo CD Helm values, the ksops repo-server patch, and
  `root-app.yaml` (Phase 4, live — see [`docs/bootstrap.md`](../../docs/bootstrap.md)).
- `platform/` — cert-manager, external-dns, Traefik, Authelia, ksops-encrypted
  secrets, and a placeholder `monitoring/` namespace (Phase 5, live — see
  [`platform/README.md`](platform/README.md)). Everything is synced and
  healthy except external-dns, which runs `--dry-run` on purpose until the
  zone moves off the old server
  ([`docs/runbooks/dns-cutover.md`](../../docs/runbooks/dns-cutover.md)).
- `apps/` — the media stack: Deluge, Prowlarr, FlareSolverr, Sonarr,
  Radarr, Bazarr, Unpackerr, Recyclarr, Plex, Tautulli, Seerr, Maintainerr
  and Homepage, each an `Application` against the shared `bjw-s/app-template`
  chart with inline values, all in one `media` namespace (Phase 6, live —
  see [`apps/README.md`](apps/README.md)). Homepage holds the apex,
  `tomkatom.com`; everything else lives on a subdomain of it.

`root-app` does not watch `apps/` itself. `platform/apps.yaml` — an
ordinary top-level `platform/*.yaml` manifest, so `root-app` picks it up
like any other — is the `Application` that discovers `clusters/lab/apps/`,
repeating root-app's own `directory.recurse: false` contract one layer
down. Two levels, one shape: `root-app` → `apps` → each app.

See [`docs/architecture.md`](../../docs/architecture.md) for the full design.
