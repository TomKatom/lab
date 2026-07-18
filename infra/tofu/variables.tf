# Full variable surface for infra/tofu. Facts shared across IaC layers
# (domain, subnet, ports — see config/lab.yml) live in locals.tf instead of
# here. Non-secret concrete values below live in the committed
# terraform.tfvars; secrets live in secrets.sops.tfvars.json (encrypted).
#
# Variables with no `default` below are operator-verified environment facts
# (Proxmox endpoint/node, storage pool names, the OVH IP, the Cloudflare
# zone id, the image checksum, SSH public keys) — `tofu validate` doesn't
# need a value for them, but `plan`/`apply` do, so they're filled with
# CHANGE_ME placeholders in terraform.tfvars for the operator to replace.

# --- Cloudflare / domain ---------------------------------------------------

variable "manage_dns" {
  description = "Whether Tofu manages the apex/wildcard/vpn DNS records. Kept false while the old server is still live on this zone; flip to true at cutover to the new server."
  type        = bool
  default     = false
}

variable "cloudflare_zone_id" {
  description = "Cloudflare zone ID for `domain`. Not secret, but environment-specific."
  type        = string
}

variable "ovh_public_ip" {
  description = "The OVH dedicated server's single public IPv4 address."
  type        = string
}

# --- Proxmox connection -----------------------------------------------------

variable "proxmox_endpoint" {
  description = "Proxmox API endpoint, e.g. https://<ip>:8006/."
  type        = string
}

variable "proxmox_insecure" {
  description = "Skip TLS verification against the Proxmox API (self-signed cert)."
  type        = bool
  default     = true
}

variable "proxmox_ssh_username" {
  description = "SSH username bpg uses for image download / disk import operations on the node."
  type        = string
  default     = "root"
}

variable "node_name" {
  description = "Proxmox node name (single-node cluster)."
  type        = string
}

# --- Networking --------------------------------------------------------------
# internal_subnet, vmbr1_host_address, wireguard_subnet, management_sources:
# see local.lab.network / local.management_sources in locals.tf.

# --- VM identity + sizing -----------------------------------------------------

variable "vm_name" {
  description = "Name of the k3s-node VM."
  type        = string
  default     = "k3s-node"
}

variable "vm_id" {
  description = "Proxmox VM ID for k3s-node."
  type        = number
  default     = 9000
}

variable "vm_cores" {
  description = "vCPU cores for k3s-node."
  type        = number
  default     = 8
}

variable "vm_cpu_type" {
  description = "Emulated CPU type for k3s-node."
  type        = string
  default     = "host"
}

variable "vm_memory_mb" {
  description = "Dedicated memory (MB) for k3s-node."
  type        = number
  default     = 32768
}

variable "vm_disk_size_gb" {
  description = "OS disk (scsi0) size in GB."
  type        = number
  default     = 64
}

variable "vm_data_disk_size_gb" {
  description = "Data disk (scsi1) size in GB, for local-path PVs."
  type        = number
  default     = 150
}

# --- Storage / image ----------------------------------------------------------

variable "system_storage_pool" {
  description = "Datastore for the OS disk (rpool-backed, e.g. local-zfs)."
  type        = string
}

variable "data_storage_pool" {
  description = "Datastore for the data disk (rpool-backed, e.g. local-zfs)."
  type        = string
}

variable "image_datastore" {
  description = "Datastore the Debian cloud image is downloaded into."
  type        = string
  default     = "local"
}

variable "debian_image_url" {
  description = "URL of the Debian 13 (Trixie) generic cloud qcow2 image."
  type        = string
  default     = "https://cloud.debian.org/images/cloud/trixie/latest/debian-13-generic-amd64.qcow2"
}

variable "debian_image_checksum" {
  description = "sha512 checksum of debian_image_url, from the matching SHA512SUMS file."
  type        = string
}

# --- VM guest OS / cloud-init --------------------------------------------------

variable "vm_username" {
  description = "Cloud-init user account created on k3s-node."
  type        = string
  default     = "debian"
}

variable "vm_dns_servers" {
  description = "DNS servers configured on k3s-node via cloud-init."
  type        = list(string)
  default     = ["1.1.1.1", "8.8.8.8"]
}

# --- Firewall toggles ------------------------------------------------------------

variable "enable_firewall" {
  description = "Master kill-switch for the Proxmox filter firewall (cluster/node/VM). Defaults on."
  type        = bool
  default     = true
}

variable "restrict_management" {
  description = "When true, restricts SSH/Proxmox API/k8s API to management_sources instead of any source. Must stay false until WireGuard (Phase 3) is verified end-to-end — flipping this before then risks a lockout."
  type        = bool
  default     = false
}

# --- Secrets (sensitive; values in secrets.sops.tfvars.json) --------------------------

variable "proxmox_api_token" {
  description = "Proxmox API token, format `user@realm!tokenid=uuid`."
  type        = string
  sensitive   = true
}

variable "cloudflare_api_token" {
  description = "Cloudflare API token (Zone:DNS:Edit + Zone:Read on `domain`'s zone)."
  type        = string
  sensitive   = true
}
