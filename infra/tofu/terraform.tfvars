# Non-secret, environment-specific values for infra/tofu. Committed to git.
#
# Facts shared across IaC layers (domain, subnet, ports, admin SSH keys)
# live in ../../config/lab.yml instead of here — see locals.tf.
#
# Secrets (Proxmox/Cloudflare API tokens) live in secrets.sops.tfvars.json
# (encrypted) — never here. See docs/runbooks/tofu-apply.md for the full
# bootstrap procedure.
#
# Every CHANGE_ME below is a genuine unknown the operator must fill in
# before `./tofu.sh plan` will produce a usable plan. `tofu validate` in CI
# does not need these values (no plan/apply happens there).

# --- Cloudflare / domain ---------------------------------------------------

cloudflare_zone_id = "096a4bdef4b6f25679ec97e558d04bf4" # Cloudflare dashboard -> tomkatom.com -> Overview -> API section -> Zone ID
ovh_public_ip      = "145.239.3.55"                     # the dedicated server's single public IPv4

# --- Proxmox connection -----------------------------------------------------

proxmox_endpoint     = "https://145.239.3.55:8006/" # OVH public IP or hostname
proxmox_insecure     = true                         # self-signed PVE cert
proxmox_ssh_username = "root"
node_name            = "server" # `pvesh get /nodes` on the host, or hostname -s

# --- VM identity + sizing -----------------------------------------------------

vm_name              = "k3s-node"
vm_id                = 9000
vm_cores             = 8
vm_cpu_type          = "host"
vm_memory_mb         = 32768
vm_disk_size_gb      = 64
vm_data_disk_size_gb = 150

# --- Storage / image ----------------------------------------------------------

system_storage_pool = "local-zfs" # e.g. "local-zfs" — verify with `pvesm status` on the host
data_storage_pool   = "local-zfs" # e.g. "local-zfs" — verify with `pvesm status` on the host
image_datastore     = "local"

debian_image_url = "https://cloud.debian.org/images/cloud/trixie/latest/debian-13-generic-amd64.qcow2"
# CHANGE_ME: sha512 of the file at debian_image_url. Get the current value with:
#   curl -s https://cloud.debian.org/images/cloud/trixie/latest/SHA512SUMS | grep generic-amd64.qcow2
debian_image_checksum = "78f658893d7aecb56288b86afebb72dcdb1a636e8e9db8bda64851a308697794678ceb5cd3b7c86afd5fb892afbc6baf9d2dbaceb7855347fde8660e8d68e667"

# --- VM guest OS / cloud-init --------------------------------------------------

vm_username = "debian"
# Authorized SSH public keys live in ../../config/lab.yml
# (admin_ssh_public_keys) — shared with Ansible's future host hardening
# role instead of duplicated here. See docs/ssh-keys.md.
vm_dns_servers = ["1.1.1.1", "8.8.8.8"]

# --- Firewall toggles ------------------------------------------------------------

enable_firewall = true
# Must stay false until WireGuard (Phase 3) is verified end-to-end. See
# docs/architecture.md#management-plane and the anti-lockout note in
# firewall.tf.
restrict_management = false
