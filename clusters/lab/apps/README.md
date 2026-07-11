# apps

The media stack, each app a thin `values.yaml` against the shared
`bjw-s/app-template` Helm chart to stay DRY across ~7 near-identical
deployments: `plex`, `prowlarr`, `sonarr`, `radarr`, `bazarr`, `deluge`,
`overseerr`.

All share the single `/data` tree (`/data/torrents` + `/data/media`, TRaSH
layout) via virtiofs, so Sonarr/Radarr import with atomic hardlink moves —
no copies. App configs/DBs live on VM NVMe via `local-path-provisioner`.
Plex direct-plays only, on its own port, outside Traefik/Authelia.

Not yet implemented — built in Phase 6.
