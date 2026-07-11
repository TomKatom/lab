# Non-secret, environment-specific values for infra/tofu. Committed to git.
#
# Secrets (Proxmox/Cloudflare API tokens) live in secrets.sops.tfvars.json
# (encrypted) — never here. See docs/runbooks/tofu-apply.md for the full
# bootstrap procedure.
#
# Every CHANGE_ME below is a genuine unknown the operator must fill in
# before `./tofu.sh plan` will produce a usable plan. `tofu validate` in CI
# does not need these values (no plan/apply happens there).

# --- Cloudflare / domain ---------------------------------------------------

domain             = "tomkatom.com"
cloudflare_zone_id = "CHANGE_ME" # Cloudflare dashboard -> tomkatom.com -> Overview -> API section -> Zone ID
ovh_public_ip      = "CHANGE_ME" # the dedicated server's single public IPv4

# --- Proxmox connection -----------------------------------------------------

proxmox_endpoint     = "https://CHANGE_ME:8006/" # OVH public IP or hostname
proxmox_insecure     = true                      # self-signed PVE cert
proxmox_ssh_username = "root"
node_name            = "CHANGE_ME" # `pvesh get /nodes` on the host, or hostname -s

# --- Networking --------------------------------------------------------------

internal_subnet    = "10.10.10.0/24"
vmbr1_host_address = "10.10.10.1/24"
wireguard_subnet   = "10.10.20.0/24"
management_sources = ["10.10.10.0/24", "10.10.20.0/24"]

# --- VM identity + sizing -----------------------------------------------------

vm_name              = "k3s-node"
vm_id                = 9000
vm_cores             = 8
vm_cpu_type          = "host"
vm_memory_mb         = 32768
vm_disk_size_gb      = 64
vm_data_disk_size_gb = 150

# --- Storage / image ----------------------------------------------------------

system_storage_pool = "CHANGE_ME" # e.g. "local-zfs" — verify with `pvesm status` on the host
data_storage_pool   = "CHANGE_ME" # e.g. "local-zfs" — verify with `pvesm status` on the host
image_datastore     = "local"

debian_image_url = "https://cloud.debian.org/images/cloud/trixie/latest/debian-13-generic-amd64.qcow2"
# CHANGE_ME: sha512 of the file at debian_image_url. Get the current value with:
#   curl -s https://cloud.debian.org/images/cloud/trixie/latest/SHA512SUMS | grep generic-amd64.qcow2
debian_image_checksum = "CHANGE_ME"

# --- VM guest OS / cloud-init --------------------------------------------------

vm_username = "debian"
ssh_public_keys = [
  "CHANGE_ME", # e.g. contents of ~/.ssh/id_ed25519.pub
]
vm_ip_address  = "10.10.10.10"
vm_ip_cidr     = "10.10.10.10/24"
vm_gateway     = "10.10.10.1"
vm_dns_servers = ["1.1.1.1", "8.8.8.8"]

# --- Ports ---------------------------------------------------------------------

wireguard_port = 51820
https_port     = 443
plex_port      = 32400
torrent_port   = 51413
ssh_port       = 22
pve_api_port   = 8006
k8s_api_port   = 6443

# --- Firewall toggles ------------------------------------------------------------

enable_firewall = true
# Must stay false until WireGuard (Phase 3) is verified end-to-end. See
# docs/architecture.md#management-plane and the anti-lockout note in
# firewall.tf.
restrict_management = false
