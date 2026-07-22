#!/usr/bin/env bash
# infra/tofu/tofu.sh — apply wrapper, used identically by an operator locally
# and by .github/workflows/tofu-apply.yml.
#
# OpenTofu's native state encryption needs a `TF_ENCRYPTION` env var built
# from a passphrase that must never appear in .tf code (see versions.tf for
# why). This script decrypts that passphrase from state.sops.env (SOPS +
# age), builds TF_ENCRYPTION in-memory, and runs `tofu` with the decrypted
# secrets.sops.tfvars.json fed in as a -var-file via process substitution —
# the passphrase and the Proxmox/Cloudflare tokens never touch disk.
#
# CI runs this same script rather than re-deriving the same values from a
# parallel set of GitHub Actions secrets: the runner holds the age key as the
# SOPS_AGE_KEY repo secret, so the committed SOPS files are the single source
# of truth for local and CI runs alike, and there is one code path to keep
# correct. sops picks the key up from ~/.config/sops/age/keys.txt locally and
# from $SOPS_AGE_KEY in CI, so nothing here branches on where it runs. See
# docs/secrets.md.
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
state_passphrase=$(sops -d state.sops.env | sed -n 's/^STATE_PASSPHRASE=//p')
: "${state_passphrase:?state.sops.env did not decrypt a STATE_PASSPHRASE value}"

# The sole definition of the state-encryption method. Every writer of
# terraform.tfstate has to derive the same key from the same passphrase,
# iteration count and hash function, or state written by one run is
# undecryptable by the next — so this block is built here, once, and never
# restated by a caller.
export TF_ENCRYPTION
TF_ENCRYPTION=$(
  cat << EOF
key_provider "pbkdf2" "state_passphrase" {
  passphrase    = "${state_passphrase}"
  iterations    = 600000
  hash_function = "sha512"
}

method "aes_gcm" "state_method" {
  keys = key_provider.pbkdf2.state_passphrase
}

state {
  method   = method.aes_gcm.state_method
  enforced = true
}

plan {
  method   = method.aes_gcm.state_method
  enforced = true
}
EOF
)

# Only the subcommands that actually accept -var-file get the decrypted
# secrets.sops.tfvars.json fed in; `init`/`fmt`/`validate`/etc. don't take
# that flag and would error if we always appended it.
subcommand=${1:-}
needs_var_file=false

case "$subcommand" in
  plan | destroy | refresh | import | console)
    needs_var_file=true
    ;;
  apply)
    # `tofu apply [options] [PLAN]` — applying a saved PLAN replays the
    # variable values baked into it at plan time, so a var-file there is
    # never useful and is actively hazardous: OpenTofu ≤1.10 (and Terraform
    # still) rejects the combination outright, and 1.11+ accepts it only
    # while every value matches, failing the apply the moment one differs.
    # Drop it whenever a positional plan file is present. CI's gated apply
    # job always takes that form (it applies the exact plan file a human
    # approved); a bare `./tofu.sh apply` still needs the variables.
    needs_var_file=true
    for arg in "${@:2}"; do
      case "$arg" in
        -*) ;;
        *) needs_var_file=false ;;
      esac
    done
    ;;
esac

if [ "$needs_var_file" = true ]; then
  # -var-file must precede any positional args of its own (e.g. import's
  # ADDR ID) — OpenTofu's flag parser stops reading flags after the first
  # positional argument, so appending it after "$@" silently turns it into
  # an extra positional arg instead.
  shift
  exec tofu "$subcommand" -var-file=<(sops --input-type binary --output-type binary -d secrets.sops.tfvars.json) "$@"
fi

exec tofu "$@"
