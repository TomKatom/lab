#!/usr/bin/env bash
# scripts/promql.sh — run a PromQL query against the lab's Prometheus and
# print the JSON result. Read-only.
#
# Instant query by default; add --since to get a range query instead. See
# scripts/lab-query-lib.sh for how it reaches Prometheus and why.
#
# The metric and label vocabulary is NOT guessable — job="pve-node" and
# job="pve-exporter" are different targets with identically-named series, and
# several plausible metric names in this stack do not exist. Start from
# docs/observability.md and the expressions already proven in
# clusters/lab/platform/monitoring/rules-*.yaml rather than from memory.
#
# Usage:
#   scripts/promql.sh 'up == 0'
#   scripts/promql.sh 'zfs_pool_capacity_ratio{job="pve-node"}'
#   scripts/promql.sh --since 6h --step 5m 'rate(node_cpu_seconds_total[5m])'
#   scripts/promql.sh --targets            # every scrape target and its health
#   scripts/promql.sh --alerts             # what is firing right now
#   scripts/promql.sh --rules              # rule groups and their health
#
# Environment: LAB_SSH_HOST (default k3s), LAB_MON_NS (monitoring),
# LAB_PROM_SVC (kube-prometheus-stack-prometheus:9090).

set -euo pipefail
# shellcheck source=scripts/lab-query-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lab-query-lib.sh"

# The header comment IS the usage text. Printed by walking from line 2 to the
# first non-comment line rather than by a fixed range, so editing the header
# cannot silently make --help print shell code.
usage() {
  awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"
  exit "${1:-0}"
}

since='' step='1m' query=''

while (($#)); do
  case $1 in
    --since)
      since=${2:-}
      [[ -n $since ]] || die "--since needs a value, e.g. --since 6h"
      shift 2
      ;;
    --step)
      step=${2:-}
      [[ -n $step ]] || die "--step needs a value, e.g. --step 5m"
      shift 2
      ;;
    --targets)
      lab_api_get "$LAB_PROM_SVC" "/api/v1/targets" | lab_emit
      exit 0
      ;;
    --alerts)
      lab_api_get "$LAB_PROM_SVC" "/api/v1/alerts" | lab_emit
      exit 0
      ;;
    --rules)
      lab_api_get "$LAB_PROM_SVC" "/api/v1/rules" | lab_emit
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

if [[ -n $since ]]; then
  # `date -d "-6h"` needs GNU date; this repo's operator machines are Linux.
  start=$(date -u -d "-${since}" +%Y-%m-%dT%H:%M:%SZ) ||
    die "could not parse --since '${since}' (try 30m, 6h, 2d)"
  end=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  path="/api/v1/query_range?query=$(urlencode "$query")"
  path+="&start=$(urlencode "$start")&end=$(urlencode "$end")"
  path+="&step=$(urlencode "$step")"
else
  path="/api/v1/query?query=$(urlencode "$query")"
fi

lab_api_get "$LAB_PROM_SVC" "$path" | lab_emit
