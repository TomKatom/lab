#!/usr/bin/env bash
# scripts/mint-pve-token.sh — one-time per server: mint the PVE API token
# infra/tofu authenticates with, and write it into
# infra/tofu/secrets.sops.tfvars.json (re-encrypted in place).
#
# Run AFTER the first proxmox-host.yml apply has created the Terraform role
# and terraform@pve user (ansible/roles/pve_permissions), from an operator
# machine with: SSH access to root@<host>, sops, and the age private key
# (~/.config/sops/age/keys.txt — see docs/secrets.md). This is an operator
# script, never CI: the PVE API reveals the token secret exactly once, at
# creation, and a CI job would leak it into the job log; here it exists in
# plaintext only in this process's memory, between the API response and the
# sops re-encrypt.
#
# --privsep 0 on purpose: the token inherits the terraform@pve user's ACL,
# so the role/user/ACL managed by ansible/roles/pve_permissions stays the
# single place the provider's effective permissions come from. A
# privilege-separated token would need its own parallel ACL to keep in sync.
#
# Usage:
#   ./scripts/mint-pve-token.sh root@<host-public-or-wg-ip>
#
# Afterwards: commit the updated secrets.sops.tfvars.json on a branch and
# open a PR — the tofu plan job proves the token works before anything
# applies.

set -euo pipefail

pve_user="terraform@pve"
token_id="tofu"

host="${1:?usage: $0 root@<proxmox-host>}"

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
secrets_file="${repo_root}/infra/tofu/secrets.sops.tfvars.json"

for tool in ssh sops; do
  if ! command -v "$tool" > /dev/null 2>&1; then
    echo "error: ${tool} is required" >&2
    exit 1
  fi
done

# Refuse to mint twice: a second `token add` for the same id errors anyway,
# but catching it here gives an actionable message instead of a pveum trace.
# Rotating = remove the old token first (invalidating the old secret), then
# re-run this script.
if ssh "$host" "pveum user token list ${pve_user} --output-format json" |
  grep -q "\"tokenid\":\"${token_id}\""; then
  echo "error: token ${pve_user}!${token_id} already exists." >&2
  echo "To rotate it: ssh ${host} pveum user token remove ${pve_user} ${token_id}" >&2
  echo "then re-run this script (the old secret stops working immediately)." >&2
  exit 1
fi

echo "Minting ${pve_user}!${token_id} on ${host} ..."
token_json="$(ssh "$host" "pveum user token add ${pve_user} ${token_id} --privsep 0 --comment 'infra/tofu bpg provider' --output-format json")"

# The JSON is {"full-tokenid":"...","info":{...},"value":"<uuid>"} — pull the
# value without jq (not everyone has it; the format is stable enough for a
# targeted match, and an empty result fails the :? guard below).
token_value="$(printf '%s' "$token_json" | sed -n 's/.*"value":"\([^"]*\)".*/\1/p')"
: "${token_value:?could not parse the token value from the pveum response}"
proxmox_api_token="${pve_user}!${token_id}=${token_value}"

# secrets.sops.tfvars.json decrypts to HCL tfvars syntax despite the .json
# suffix (see infra/tofu/tofu.sh's header) — so this rewrites the
# `proxmox_api_token = "..."` line, it does not edit JSON. The plaintext
# stays in shell variables; only ciphertext is ever written to disk, to a
# temp file that atomically replaces the original after a decrypt
# round-trip proves the re-encrypt worked.
plaintext="$(sops -d "$secrets_file")"
if ! printf '%s\n' "$plaintext" | grep -q '^proxmox_api_token'; then
  echo "error: no proxmox_api_token line found in the decrypted ${secrets_file}" >&2
  exit 1
fi
updated="$(printf '%s\n' "$plaintext" |
  sed "s|^proxmox_api_token.*|proxmox_api_token   = \"${proxmox_api_token}\"|")"

tmp_file="${secrets_file}.tmp"
trap 'rm -f "$tmp_file"' EXIT
printf '%s\n' "$updated" |
  sops -e --input-type binary --output-type binary \
    --filename-override "$secrets_file" /dev/stdin > "$tmp_file"

# Round-trip: the new ciphertext must decrypt back to exactly what we
# encrypted, or something about the sops invocation is wrong — fail before
# touching the real file.
if [ "$(sops -d "$tmp_file")" != "$updated" ]; then
  echo "error: re-encrypted file did not round-trip; leaving ${secrets_file} untouched" >&2
  exit 1
fi
mv "$tmp_file" "$secrets_file"
trap - EXIT

echo "Wrote ${pve_user}!${token_id} into ${secrets_file} (encrypted)."
echo "Next: commit it on a branch and open a PR — the tofu plan job is the"
echo "proof the token authenticates."
