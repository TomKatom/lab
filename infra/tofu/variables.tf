# Full variable surface for infra/tofu. DRY: every shared value (domain,
# subnet, ports, VM sizing) is declared once here and referenced everywhere
# else. Non-secret concrete values live in the committed terraform.tfvars;
# secrets live in secrets.sops.tfvars.json (encrypted).
#
# Variables with no `default` below are operator-verified environment facts
# (Proxmox endpoint/node, storage pool names, the OVH IP, the Cloudflare
# zone id, the image checksum, SSH public keys) — `tofu validate` doesn't
# need a value for them, but `plan`/`apply` do, so they're filled with
# CHANGE_ME placeholders in terraform.tfvars for the operator to replace.

# --- Cloudflare / domain ---------------------------------------------------

variable "domain" {
  description = "Root domain managed in Cloudflare."
  type        = string
  default     = "tomkatom.com"
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

variable "internal_subnet" {
  description = "Internal subnet behind vmbr1."
  type        = string
  default     = "10.10.10.0/24"
}

variable "vmbr1_host_address" {
  description = "vmbr1 address on the Proxmox host (CIDR) — also the VM's gateway."
  type        = string
  default     = "10.10.10.1/24"
}

variable "wireguard_subnet" {
  description = "WireGuard peer subnet (Phase 3), included in management_sources ahead of time."
  type        = string
  default     = "10.10.20.0/24"
}

variable "management_sources" {
  description = "CIDRs allowed to reach management ports when restrict_management=true."
  type        = list(string)
  default     = ["10.10.10.0/24", "10.10.20.0/24"]
}

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

variable "ssh_public_keys" {
  description = "SSH public keys authorized for vm_username via cloud-init."
  type        = list(string)
  default     = []
}

variable "vm_ip_address" {
  description = "Static internal IP address of k3s-node (no CIDR suffix)."
  type        = string
  default     = "10.10.10.10"
}

variable "vm_ip_cidr" {
  description = "Static internal IP address of k3s-node, in CIDR notation."
  type        = string
  default     = "10.10.10.10/24"
}

variable "vm_gateway" {
  description = "Gateway address for k3s-node (vmbr1's host address)."
  type        = string
  default     = "10.10.10.1"
}

variable "vm_dns_servers" {
  description = "DNS servers configured on k3s-node via cloud-init."
  type        = list(string)
  default     = ["1.1.1.1", "8.8.8.8"]
}

# --- Ports ---------------------------------------------------------------------

variable "wireguard_port" {
  description = "WireGuard UDP port (host, public)."
  type        = number
  default     = 51820
}

variable "https_port" {
  description = "HTTPS port (Traefik ingress, DNAT'd to the VM)."
  type        = number
  default     = 443
}

variable "plex_port" {
  description = "Plex direct-play port (DNAT'd to the VM)."
  type        = number
  default     = 32400
}

variable "torrent_port" {
  description = "Torrent (Deluge) port, TCP+UDP (DNAT'd to the VM)."
  type        = number
  default     = 51413
}

variable "ssh_port" {
  description = "SSH port, host and VM."
  type        = number
  default     = 22
}

variable "pve_api_port" {
  description = "Proxmox API/UI port."
  type        = number
  default     = 8006
}

variable "k8s_api_port" {
  description = "k3s API server port."
  type        = number
  default     = 6443
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
