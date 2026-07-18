#!/usr/bin/env bash
# ansible/run.sh — local playbook wrapper, mirrors infra/tofu/tofu.sh.
#
# Unlike tofu.sh, this doesn't build a secret in-memory to feed via a flag —
# SOPS decryption here happens per-value, in-memory, at var-load time via the
# community.sops vars plugin (enabled in ansible.cfg), transparently for
# every *.sops.yml under group_vars/host_vars. This script's job is just to
# fail fast on missing tooling and make sure ansible-playbook always runs
# from ansible/ regardless of the caller's cwd, the same guarantee tofu.sh
# gives infra/tofu/.
#
# Usage:
#   ./run.sh playbooks/ping.yml
#   ./run.sh playbooks/proxmox-host.yml --check
#   ./run.sh <any other ansible-playbook args>

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

if ! command -v ansible-playbook > /dev/null 2>&1; then
  echo "error: ansible-playbook is required (pipx/uv tool install ansible-core, or 'pip install ansible')" >&2
  exit 1
fi

if ! command -v sops > /dev/null 2>&1; then
  echo "error: sops is required (group_vars/*.sops.yml are SOPS-encrypted, decrypted via the community.sops vars plugin)" >&2
  exit 1
fi

exec ansible-playbook "$@"
