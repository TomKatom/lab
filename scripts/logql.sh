#!/usr/bin/env bash
# scripts/logql.sh — run a LogQL query against the lab's Loki and print the
# matching log lines. Read-only.
#
# Loki holds 30 days of every pod log plus the k3s node's systemd journal, so
# this reaches logs from pods that no longer exist — which `kubectl logs`
# cannot. See scripts/lab-query-lib.sh for how it reaches Loki and why.
#
# A LogQL query MUST start with a stream selector; `|= "error"` alone is a
# syntax error, not an empty result. Alloy's relabel rules define the entire
# available label set, and a selector naming a label nothing sets matches zero
# streams forever with no error:
#
#   pod logs   namespace, pod, container, app   — and NO `job` label
#   journal    job="systemd-journal", host="k3s-node"  — no namespace, no pod
#
# Alloy is a DaemonSet inside the cluster, so the journal here is the k3s
# VM's. The Proxmox hypervisor's journal is NOT shipped to Loki — the host is
# covered by metrics only (job="pve-node"). Use --labels / --values to
# discover the rest rather than guessing.
#
# Usage:
#   scripts/logql.sh '{namespace="media", app="sonarr"} |= "error"'
#   scripts/logql.sh --since 7d --limit 500 '{namespace="media"} |~ "(?i)exception"'
#   scripts/logql.sh '{job="systemd-journal"} |= "oom"'
#   scripts/logql.sh --labels                 # every label name Loki knows
#   scripts/logql.sh --values namespace       # every value of one label
#   scripts/logql.sh --rules                  # ruler group health
#   scripts/logql.sh --json '{namespace="media"}'   # unformatted API response
#
# Environment: LAB_SSH_HOST (default k3s), LAB_MON_NS (monitoring),
# LAB_LOKI_SVC (loki:3100).

set -euo pipefail
# shellcheck source=scripts/lab-query-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lab-query-lib.sh"

# The header comment IS the usage text — see promql.sh for why this walks the
# comment block instead of using a fixed line range.
usage() {
  awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"
  exit "${1:-0}"
}

since='1h' limit='200' query='' as_json=0 with_labels=0

while (($#)); do
  case $1 in
    --since)
      since=${2:-}
      [[ -n $since ]] || die "--since needs a value, e.g. --since 7d"
      shift 2
      ;;
    --limit)
      limit=${2:-}
      [[ -n $limit ]] || die "--limit needs a value"
      shift 2
      ;;
    --json)
      as_json=1
      shift
      ;;
    --with-labels)
      with_labels=1
      shift
      ;;
    --labels)
      lab_api_get "$LAB_LOKI_SVC" "/loki/api/v1/labels" | lab_emit
      exit 0
      ;;
    --values)
      [[ -n ${2:-} ]] || die "--values needs a label name, e.g. --values namespace"
      lab_api_get "$LAB_LOKI_SVC" "/loki/api/v1/label/$(urlencode "$2")/values" | lab_emit
      exit 0
      ;;
    --rules)
      # The ruler speaks the Prometheus rules API, not a Loki-shaped one.
      lab_api_get "$LAB_LOKI_SVC" "/prometheus/api/v1/rules" | lab_emit
      exit 0
      ;;
    -h | --help) usage 0 ;;
    --)
      shift
      query=${1:-}
      break
      ;;
    -*) die "unknown option: $1 (see --help)" ;;
    *)
      [[ -z $query ]] || die "only one query may be given (quote it as a single argument)"
      query=$1
      shift
      ;;
  esac
done

[[ -n $query ]] || usage 1

start=$(date -u -d "-${since}" +%Y-%m-%dT%H:%M:%SZ) ||
  die "could not parse --since '${since}' (try 30m, 6h, 7d)"
end=$(date -u +%Y-%m-%dT%H:%M:%SZ)

path="/loki/api/v1/query_range?query=$(urlencode "$query")"
path+="&start=$(urlencode "$start")&end=$(urlencode "$end")"
path+="&limit=$(urlencode "$limit")&direction=backward"

body=$(lab_api_get "$LAB_LOKI_SVC" "$path")

if ((as_json)) || ! command -v jq > /dev/null 2>&1; then
  printf '%s' "$body" | lab_emit
  exit 0
fi

# Loki returns one entry list per stream, each newest-first. Flatten and sort
# ascending so a burst reads in the order it happened, which is the whole
# point of looking.
printf '%s' "$body" | jq -r --argjson lbl "$with_labels" '
  [ .data.result[] as $r
    | $r.values[]
    | { t: (.[0] | tonumber), line: .[1],
        lbl: ($r.stream | to_entries | map("\(.key)=\(.value)") | join(" ")) } ]
  | sort_by(.t)[]
  | if $lbl == 1
    then "\((.t / 1000000000) | todate)  [\(.lbl)]  \(.line)"
    else "\((.t / 1000000000) | todate)  \(.line)"
    end
'
