#!/usr/bin/env bash
# infra/tofu/build-tf-encryption.sh — emits the TF_ENCRYPTION HCL config to stdout.
#
# Single source of truth for the state-encryption method definition, shared by
# infra/tofu/tofu.sh (local applies, passphrase from state.sops.env) and
# .github/workflows/tofu-apply.yml (CI plan/apply, passphrase from the
# STATE_PASSPHRASE repo secret) — see docs/secrets.md and
# docs/runbooks/tofu-apply.md. Previously this HCL block was hand-duplicated
# in three places; a change to one (e.g. bumping iterations) without updating
# the others would make state written by one writer undecryptable by another.
#
# Reads the passphrase from $STATE_PASSPHRASE (never a literal, never
# written to disk). Usage: STATE_PASSPHRASE=... ./build-tf-encryption.sh

set -euo pipefail
: "${STATE_PASSPHRASE:?STATE_PASSPHRASE must be set}"

cat << EOF
key_provider "pbkdf2" "state_passphrase" {
  passphrase    = "${STATE_PASSPHRASE}"
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
