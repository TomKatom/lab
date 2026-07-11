# Debian 13 (Trixie) cloud image, downloaded straight into the Proxmox
# `import` datastore so vm-k3s.tf can `import_from` it as the OS disk.
#
# The `tank` HDD mirror is deliberately not referenced anywhere in
# infra/tofu — it's created, mirrored, and mounted by Ansible (Phase 3).
resource "proxmox_download_file" "debian13" {
  content_type       = "import"
  datastore_id       = var.image_datastore
  node_name          = var.node_name
  url                = var.debian_image_url
  checksum           = var.debian_image_checksum
  checksum_algorithm = "sha512"
}
