---
name: lab-diagnose
description: Query the lab's Prometheus metrics and Loki logs to diagnose a problem or do routine maintenance. Use whenever a question is about what the server is doing right now or recently did — a firing alert, a service that looks down, a slow or stalled download, a full disk, a pod that restarted, "is everything OK", "why did X fail", or any request to check the health of Proxmox, ZFS, k3s, Plex, Deluge or the *arrs. Also use before proposing a fix that assumes a cause, to confirm the cause from telemetry first.
---

# Diagnosing this lab from telemetry

Two read-only scripts reach the stack. Neither needs a credential; both go
through the k3s API server's service proxy over `ssh k3s`.

```bash
scripts/promql.sh 'up == 0'                       # instant query
scripts/promql.sh --since 6h --step 5m '<promql>' # range query
scripts/promql.sh --alerts                        # firing right now
scripts/promql.sh --targets                       # scrape target health
scripts/promql.sh --rules                         # rule group health

scripts/logql.sh '{namespace="media", app="sonarr"} |= "error"'
scripts/logql.sh --since 7d --limit 500 '<logql>'
scripts/logql.sh --labels                         # discover label names
scripts/logql.sh --values namespace               # discover label values
```

Loki holds **30 days** of pod logs and the k3s node's systemd journal, so it
reaches logs from pods that no longer exist. Prometheus holds **15 days** /
15 GiB.

Alloy's relabel rules define the entire LogQL label set, and a selector naming
a label nothing sets matches zero streams forever with no error:

| Source | Labels |
|---|---|
| pod logs | `namespace`, `pod`, `container`, `app` — **no `job` label** |
| journal | `job="systemd-journal"`, `host="k3s-node"` — no namespace, no pod |

**The Proxmox hypervisor's journal is not in Loki.** Alloy is a DaemonSet
inside the cluster, so `{job="systemd-journal"}` is the k3s VM. The host is
covered by metrics only (`job="pve-node"`); there are no host logs to query.

## Start here, always

`scripts/promql.sh --alerts` before anything else. If it is quiet the lab is
fine — 139 rules are watching (120 from kube-prometheus-stack, 19
hand-written in `clusters/lab/platform/monitoring/rules-*.yaml` and
`loki-rules.yaml`).

**`Watchdog` fires permanently by design.** It is the heartbeat proving the
alert path works. Never report it as a problem; report its *absence* as one.

## Vocabulary — do not guess these

Wrong-but-plausible metric names have shipped silently-broken alerts in this
repo three times. Everything below is verified. Anything not below should be
confirmed with `--targets` or a bare selector before being trusted.

**The two hypervisor jobs are a contract and are not interchangeable.** The
in-cluster node-exporter DaemonSet emits series with *identical names* to the
hypervisor's, so a missing job matcher silently mixes VM and host data.

| Job | What it is |
|---|---|
| `job="pve-node"` | the Proxmox **host's** node_exporter, `10.10.10.1:9100` |
| `job="pve-exporter"` | the PVE **API** (guests, storages, quorum), in-cluster |
| `job="exportarr-sonarr"` / `-radarr` / `-prowlarr` | the three \*arrs |
| `job="plex-exporter"`, `job="deluge"` | Plex, Deluge |

Verified series:

- Host — `node_zfs_zpool_state{job="pve-node", state="online"}`,
  `zfs_pool_capacity_ratio{job="pve-node"}`,
  `smartmon_device_smart_healthy{job="pve-node"}`,
  `node_filesystem_avail_bytes{job="pve-node"}`,
  `media_backup_newest_mtime_seconds{job="pve-node", app="sonarr"|"radarr"}`
- Guests — `pve_up{job="pve-exporter", id=~"(qemu|lxc)/.+"}`,
  `pve_guest_info{job="pve-exporter", template="0"}`
- Certs — `certmanager_certificate_expiration_timestamp_seconds`,
  `certmanager_certificate_ready_status{condition="False"}`
- Plex — `plex_up`, `plex_sessions_count`,
  `plex_video_transcode_sessions_count`,
  `plex_audio_transcode_sessions_count`, `plex_media_count`
- Deluge — `deluge_info`, `deluge_torrents{state="..."}`,
  `deluge_libtorrent_net_{recv,sent}_payload_bytes_total`
- \*arrs — `{sonarr,radarr,prowlarr}_system_health_issues{type="error"}`,
  `prowlarr_indexer_unavailable`, `<app>_queue_total`

Traps that will otherwise waste a session:

- **`deluge_up` does not exist**, and `up` cannot stand in for it — the
  exporter returns HTTP 200 with no series when its RPC connection fails.
  Liveness is `absent(deluge_info)`.
- **`media_backup_newest_mtime_seconds` is absent, not zero, when an app has
  no backups.** A `0` would make `time() - metric` span the Unix epoch. Pair
  any freshness expression with `absent()`.
- **The Plex exporter has no transcode-decision label.** Decisions are
  encoded as separate metric *names*, and direct-play vs direct-stream is
  indistinguishable to it.
- **exportarr v2.3.0 collapses the whole queue into one `<app>_queue_total`
  series** carrying the total count and the last record's labels. Do not
  build a `download_state` matcher on it; the reasoning is in
  `rules-media.yaml`'s header.
- The \*arr queue label is `download_state`, not `tracked_download_state`.
- A LogQL query must start with a stream selector. `|= "error"` alone is a
  syntax error, not an empty result.

## Recipes

**Triage a firing alert** — `--alerts` for the labels, then read that alert's
`expr` in `clusters/lab/platform/monitoring/rules-*.yaml` (the rule files
carry the reasoning for every threshold), then run the `expr` yourself to see
the current value, then pull the matching logs.

**A service looks down** — `scripts/promql.sh --targets` distinguishes "the
app is broken" from "the exporter is broken", which look identical from
outside. Then `scripts/logql.sh --since 2h '{namespace="media", app="<app>"}'`.

**A pod restarted and you missed it** — Loki has the logs from before the
restart; `kubectl logs` does not. `{namespace="<ns>", pod="<pod>"}` over
`--since 24h`.

**Downloads stalled** — `deluge_torrents{state="error"}`, then
`rate(deluge_libtorrent_net_recv_payload_bytes_total[5m])`, then the \*arr
queue panel logic: a `<app>_queue_total` that never falls is the symptom of a
stuck import. `/data` pressure shows up as
`node_filesystem_avail_bytes{job="pve-node"}`.

**Routine health sweep** — `--alerts`, then `up == 0`, then
`zfs_pool_capacity_ratio{job="pve-node"}`, then
`time() - media_backup_newest_mtime_seconds{job="pve-node"}`, then
`certmanager_certificate_expiration_timestamp_seconds - time()`.

## Blind spots — do not claim coverage here

- **No external probing.** Everything watches the lab from inside the lab,
  and alerts leave over the same wire. A dead uplink, broken host NAT or
  Cloudflare problem is invisible, and so is the failure of the alert path
  itself. This detects *internal* failures only.
- **No `importBlocked` alert** — a real gap, deliberately not faked; see the
  exporter trap above.
- **Not scraped at all:** Tautulli, Argo CD, per-torrent Deluge stats, ZFS
  scrub staleness. Their absence is a decision, recorded in
  `docs/observability.md`.

## Rules of engagement

These scripts are read-only and that is the whole point. Do not propose
`kubectl edit`, `kubectl delete`, restarts or any other live mutation as a
remedy: this repo is GitOps, changes go through a PR and Argo, and
`CLAUDE.md` binds you to that. Diagnose here, then fix in git.

Full reference: `docs/observability.md`.
