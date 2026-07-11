# Provider configuration. Endpoints/usernames are non-secret vars (see
# variables.tf, values in terraform.tfvars); API tokens are sensitive vars
# sourced from secrets.sops.tfvars (local) or repo secrets (CI).

provider "proxmox" {
  endpoint  = var.proxmox_endpoint
  api_token = var.proxmox_api_token
  insecure  = var.proxmox_insecure

  # bpg performs the cloud image download and disk `import_from` over SSH
  # to the node — required for storage.tf/vm-k3s.tf to work. Phase 2 still
  # reaches the node over its public IP:22 (no WireGuard yet); Phase 3
  # narrows this once the management plane moves behind WG.
  ssh {
    agent    = true
    username = var.proxmox_ssh_username
  }
}

provider "cloudflare" {
  api_token = var.cloudflare_api_token
}
