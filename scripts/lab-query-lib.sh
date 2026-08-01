#!/usr/bin/env bash
# scripts/lab-query-lib.sh — shared plumbing for promql.sh and logql.sh.
# Sourced, never executed.
#
# These are read-only operator/agent tools. They exist so that diagnosing a
# problem does not mean opening Grafana, and so an agent working in this repo
# can read the same telemetry the alerts are built on without being handed a
# credential. Nothing here writes: every call is a GET against a query API.
#
# ── Why the API-server service proxy, and not curl to a ClusterIP ──────────
#
# Prometheus and Loki have no authentication of their own (docs/observability.md,
# "Grafana has no authentication of its own" — the auth boundary in this lab is
# Authelia in front of *Grafana*, not in front of the stores). So the only
# question is how to reach them from an operator machine. Three options, and
# only one of them is stateless and free of assumptions:
#
#   curl to the ClusterIP from the node — needs the node to route ClusterIPs
#     itself, and needs cluster DNS from a host shell, which does not exist.
#   kubectl port-forward — stateful, needs a background process and a free
#     local port, and leaves a socket open if anything dies mid-command.
#   kubectl get --raw <service proxy path> — the API server proxies the
#     request to the Service's endpoints. One shot, no local port, no DNS
#     assumption, no ClusterIP-routing assumption. Used here.
#
# The cost is that the proxy path hard-codes a Service name, which is why both
# are overridable below and why a failed lookup prints the namespace's Services
# rather than just the API server's 404.
#
# ── Service names ─────────────────────────────────────────────────────────
#
# Derived from the Helm release names in the Argo Applications, not observed
# live. `clusters/lab/platform/kube-prometheus-stack.yaml` releases as
# `kube-prometheus-stack`, so the operator-created Prometheus Service is
# `kube-prometheus-stack-prometheus:9090`. `loki.yaml` releases as `loki`, and
# that one is independently corroborated: kube-prometheus-stack.yaml's Grafana
# datasource points at `http://loki.monitoring.svc:3100`, which is the same
# Service. Override either with LAB_PROM_SVC / LAB_LOKI_SVC if a chart bump
# ever renames them.

set -euo pipefail

LAB_SSH_HOST="${LAB_SSH_HOST:-k3s}"
LAB_MON_NS="${LAB_MON_NS:-monitoring}"
LAB_PROM_SVC="${LAB_PROM_SVC:-kube-prometheus-stack-prometheus:9090}"
LAB_LOKI_SVC="${LAB_LOKI_SVC:-loki:3100}"

die() {
  printf '%s: %s\n' "${0##*/}" "$*" >&2
  exit 1
}

# Percent-encode $1 for use in a query string. LC_ALL=C so ${#s} and the
# substring below count BYTES, not characters — a multi-byte character encoded
# per-character rather than per-byte produces a string the API server rejects.
urlencode() {
  local LC_ALL=C
  local s=$1 i c out=''
  for ((i = 0; i < ${#s}; i++)); do
    c=${s:i:1}
    case $c in
      [a-zA-Z0-9.~_-]) out+=$c ;;
      *)
        printf -v c '%%%02X' "'$c"
        out+=$c
        ;;
    esac
  done
  printf '%s' "$out"
}

# GET an API-server service-proxy path and print the response body.
#
# The path is built locally and passed over stdin rather than interpolated
# into the remote command line: a PromQL selector is full of quotes, braces
# and backslashes, and every one of them would otherwise be re-parsed by the
# remote shell. `"$(cat)"` on the far side means the remote shell sees exactly
# one argument no matter what the query contains.
lab_api_get() {
  local svc=$1 path=$2 raw out
  raw="/api/v1/namespaces/${LAB_MON_NS}/services/${svc}/proxy${path}"

  if ! out=$(printf '%s' "$raw" |
    ssh -o BatchMode=yes "$LAB_SSH_HOST" 'sudo kubectl get --raw "$(cat)"' 2>&1); then
    printf '%s\n' "$out" >&2
    printf '\n%s: the query above failed. Services currently in %s:\n' \
      "${0##*/}" "$LAB_MON_NS" >&2
    ssh -o BatchMode=yes "$LAB_SSH_HOST" \
      "sudo kubectl -n ${LAB_MON_NS} get svc" >&2 || true
    printf '\nIf the Service name differs, re-run with LAB_PROM_SVC=<name>:<port> or LAB_LOKI_SVC=<name>:<port>.\n' >&2
    exit 1
  fi

  printf '%s' "$out"
}

# Pretty-print JSON when jq is available, pass it through unchanged when it is
# not. Never a hard dependency: the raw body is still the answer.
lab_emit() {
  if command -v jq > /dev/null 2>&1; then
    jq .
  else
    cat
  fi
}
