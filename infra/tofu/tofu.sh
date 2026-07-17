#!/usr/bin/env bash
# infra/tofu/tofu.sh — local apply wrapper.
#
# OpenTofu's native state encryption needs a `TF_ENCRYPTION` env var built
# from a passphrase that must never appear in .tf code (see versions.tf for
# why). This script decrypts that passphrase from state.sops.env (SOPS +
# age), builds TF_ENCRYPTION in-memory, and runs `tofu` with the decrypted
# secrets.sops.tfvars.json fed in as a -var-file via process substitution —
# the passphrase and the Proxmox/Cloudflare tokens never touch disk.
#
# secrets.sops.tfvars.json is real HCL tfvars syntax once decrypted, despite
# the `.json` suffix — it's encrypted as opaque binary (`sops
# --input-type/--output-type binary`) and named `.tfvars.json` on purpose,
# so `tofu fmt -recursive` (which errors trying to parse ciphertext as HCL
# in any plain `*.tfvars` file, but explicitly skips `*.tfvars.json`) leaves
# it alone. See the comment on its .sops.yaml rule.
#
# Usage:
#   ./tofu.sh init
#   ./tofu.sh plan
#   ./tofu.sh apply
#   ./tofu.sh <any other tofu subcommand>

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

if ! command -v sops > /dev/null 2>&1; then
  echo "error: sops is required (state.sops.env / secrets.sops.tfvars.json are SOPS-encrypted)" >&2
  exit 1
fi

if ! command -v tofu > /dev/null 2>&1; then
  echo "error: tofu (OpenTofu) is required" >&2
  exit 1
fi

# Decrypts to a single `STATE_PASSPHRASE=...` line.
STATE_PASSPHRASE=$(sops -d state.sops.env | sed -n 's/^STATE_PASSPHRASE=//p')
: "${STATE_PASSPHRASE:?state.sops.env did not decrypt a STATE_PASSPHRASE value}"

export TF_ENCRYPTION
TF_ENCRYPTION=$(STATE_PASSPHRASE="$STATE_PASSPHRASE" ./build-tf-encryption.sh)
unset STATE_PASSPHRASE

# Only the subcommands that actually accept -var-file get the decrypted
# secrets.sops.tfvars.json fed in; `init`/`fmt`/`validate`/etc. don't take
# that flag and would error if we always appended it.
case "${1:-}" in
  plan | apply | destroy | refresh | import | console)
    exec tofu "$@" -var-file=<(sops --input-type binary --output-type binary -d secrets.sops.tfvars.json)
    ;;
  *)
    exec tofu "$@"
    ;;
esac
