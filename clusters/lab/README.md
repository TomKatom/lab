# clusters/lab

**Layer 3 — Deliver.** The Argo CD app-of-apps root for the `lab` cluster —
everything here is reconciled from git; nothing is applied by hand.

- `bootstrap/` — Argo CD Helm values, the ksops repo-server patch, and
  `root-app.yaml` (Phase 4, live — see [`docs/bootstrap.md`](../../docs/bootstrap.md)).
- `platform/` — cert-manager, external-dns, Traefik, Authelia, ksops-encrypted
  secrets, and a placeholder `monitoring/` namespace (Phase 5, live — see
  [`platform/README.md`](platform/README.md)). Everything is synced and
  healthy, external-dns included — it published the zone for real once
  [`docs/runbooks/dns-cutover.md`](../../docs/runbooks/dns-cutover.md) ran
  and no longer carries `--dry-run`.
- `apps/` — the media stack: Deluge, Prowlarr, FlareSolverr, Sonarr,
  Radarr, Bazarr, Unpackerr, Recyclarr, Plex, Tautulli, Seerr, Maintainerr
  and Homepage, each an `Application` against the shared `bjw-s/app-template`
  chart with inline values, all in one `media` namespace (Phase 6, live —
  see [`apps/README.md`](apps/README.md)). Homepage holds the apex,
  `tomkatom.com`; everything else lives on a subdomain of it. Two
  namespaces here are not `media`: `filebrowser` (Phase 9) sits in `share`
  and the personal-finance stack (Phase 11) in `finance`, each for the
  reason recorded in [`apps/README.md`](apps/README.md#the-share-namespace)
  and [`apps/README.md`](apps/README.md#the-finance-namespace).

`root-app` does not watch `apps/` itself. `platform/apps.yaml` — an
ordinary top-level `platform/*.yaml` manifest, so `root-app` picks it up
like any other — is the `Application` that discovers `clusters/lab/apps/`,
repeating root-app's own non-recursive discovery contract one layer down
(unset rather than explicit `directory.recurse: false`, to dodge an Argo
CD diff bug — see [`platform/README.md`](platform/README.md#component-layout)).
Two levels, one shape: `root-app` → `apps` → each app.

See [`docs/architecture.md`](../../docs/architecture.md) for the full design.
