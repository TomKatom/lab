# OpenTofu + provider version pins.
#
# No `encryption` block here. The native state-encryption key_provider
# passphrase must be a literal — OpenTofu evaluates the encryption config
# before variables are resolved, so it can't come from a `var`, and writing
# it as a literal here would mean committing a plaintext secret. Instead the
# whole encryption config is built and injected at runtime via the
# TF_ENCRYPTION env var (OpenTofu merges env config over code) — see
# infra/tofu/tofu.sh and docs/runbooks/tofu-apply.md.
#
# This also keeps CI `validate` green with zero secrets: no encryption block
# to evaluate, and the CI fmt/validate job deletes its checkout's committed
# terraform.tfstate before `init -backend=false` (see ci.yml) so the default
# local backend has no encrypted state file to read. Nothing at that stage
# needs TF_ENCRYPTION.

terraform {
  required_version = ">= 1.8.0"

  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.111.0"
    }
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.0"
    }
  }

  # No backend block: default local backend. State lives at
  # infra/tofu/terraform.tfstate, natively encrypted (via tofu.sh), and is
  # committed to git.
}
