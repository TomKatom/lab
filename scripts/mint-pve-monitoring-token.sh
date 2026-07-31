#!/usr/bin/env bash
# scripts/mint-pve-monitoring-token.sh — one-time per server: mint the
# read-only PVE API token prometheus-pve-exporter authenticates with, print
# it once, and print the exact steps to seal it into
# clusters/lab/platform/monitoring/pve-token.sops.yaml.
#
# Run AFTER the first proxmox-host.yml apply has created the monitoring@pve
# user and its PVEAuditor binding (ansible/roles/pve_permissions), from an
# operator machine with SSH access to root@<host>. This is an operator
# script, never CI: the PVE API reveals the token secret exactly once, at
# creation, and a CI job would leak it into the job log.
#
# Unlike its sibling scripts/mint-pve-token.sh, this one does NOT write the
# secret anywhere. That script's destination is an existing SOPS file with a
# `proxmox_api_token = "..."` line to rewrite; this one's destination is a
# Kubernetes Secret that does not exist yet, and creating it means choosing
# a filename that ../.sops.yaml's `clusters/.*\.sops\.ya?ml$` rule matches
# and that the ksops generator already lists. Both are one `cp` and one
# `sops -e -i` away, printed below, and doing them by hand is what keeps the
# rule "encrypted files are created by the operator, never by a tool" intact.
#
# --privsep 0 on purpose, same as the tofu token: the token inherits the
# monitoring@pve user's ACL, so the user/ACL managed by
# ansible/roles/pve_permissions stays the single place the exporter's
# effective permissions come from. A privilege-separated token starts with
# *no* permissions at all and would need its own parallel ACL — and the
# failure mode is silent, because the exporter authenticates fine and every
# collector then returns an empty result set.
#
# Usage:
#   ./scripts/mint-pve-monitoring-token.sh root@<host-public-or-wg-ip>

set -euo pipefail

pve_user="monitoring@pve"
token_id="prometheus"
secret_file="clusters/lab/platform/monitoring/pve-token.sops.yaml"

host="${1:?usage: $0 root@<proxmox-host>}"

if ! command -v ssh > /dev/null 2>&1; then
  echo "error: ssh is required" >&2
  exit 1
fi

# Refuse to mint twice: a second `token add` for the same id errors anyway,
# but catching it here gives an actionable message instead of a pveum trace.
# Rotating = remove the old token first (invalidating the old secret), then
# re-run this script and re-seal the new value.
if ssh "$host" "pveum user token list ${pve_user} --output-format json" |
  grep -q "\"tokenid\":\"${token_id}\""; then
  echo "error: token ${pve_user}!${token_id} already exists." >&2
  echo "To rotate it: ssh ${host} pveum user token remove ${pve_user} ${token_id}" >&2
  echo "then re-run this script (the old secret stops working immediately)." >&2
  exit 1
fi

echo "Minting ${pve_user}!${token_id} on ${host} ..."
token_json="$(ssh "$host" "pveum user token add ${pve_user} ${token_id} --privsep 0 --comment 'prometheus-pve-exporter (read-only)' --output-format json")"

# The JSON is {"full-tokenid":"...","info":{...},"value":"<uuid>"} — pull the
# value without jq (not everyone has it; the format is stable enough for a
# targeted match, and an empty result fails the :? guard below).
token_value="$(printf '%s' "$token_json" | sed -n 's/.*"value":"\([^"]*\)".*/\1/p')"
: "${token_value:?could not parse the token value from the pveum response}"

cat << EOF

The token secret is shown ONCE, here and nowhere else. PVE will never
show it again; losing it means removing the token and re-running this
script.

  PVE_TOKEN_VALUE: ${token_value}

Seal it into the repo now, from the repo root:

  cp ${secret_file}.example ${secret_file}
  \${EDITOR:-vi} ${secret_file}      # replace <paste-uuid-here>, keep the quotes
  sops -e -i ${secret_file}
  git add ${secret_file} && git commit -m 'feat(monitoring): pve-exporter API token'

Then verify before pushing — these are the two ways this goes wrong quietly:

  sops -d ${secret_file}                     # must print the uuid back
  grep -c 'type:str]' ${secret_file}         # must be 1, not 0

A value entered without quotes re-encrypts as type:int, which is well-formed
YAML that kustomize builds and kubeconform validates, and only fails at Argo
sync time. CI greps for exactly that.

Note the exporter also needs PVE_USER=${pve_user} and
PVE_TOKEN_NAME=${token_id}; both are already set, in plaintext, in
clusters/lab/platform/monitoring/pve-exporter-deployment.yaml. Only the
value above is a secret.
EOF
