# Debian 13 (Trixie) cloud image, downloaded straight into the Proxmox
# `import` datastore so vm-k3s.tf can `import_from` it as the OS disk.
#
# The `tank` HDD stripe itself is created, striped, and mounted by Ansible
# (Phase 3) — infra/tofu never touches the pool. The only infra/tofu
# reference to it is storage-virtiofs.tf's directory mapping, which just
# shares the already-mounted /tank/data path into the k3s VM via virtiofs.
#
# depends_on vmbr1: the download's URL-metadata fetch runs on the node
# itself (host resolver, host network stack), and proxmox_network_linux_bridge
# ends its own create with a network reload (ifreload -a), which briefly
# disrupts the node's networking/DNS. With no explicit ordering, OpenTofu
# fires both in parallel — on the first apply against this host that raced
# and the download failed DNS resolution mid-reload. Running the download
# after the bridge (and its reload) has settled removes that race.
resource "proxmox_download_file" "debian13" {
  depends_on = [proxmox_network_linux_bridge.vmbr1]

  content_type       = "import"
  datastore_id       = var.image_datastore
  node_name          = var.node_name
  url                = var.debian_image_url
  checksum           = var.debian_image_checksum
  checksum_algorithm = "sha512"

  # The "latest" Trixie URL doesn't expose file metadata (size/mtime) over
  # HTTP HEAD, which OpenTofu needs to decide whether to re-download an
  # already-present file. `overwrite = false` skips that remote metadata
  # check entirely; checksum verification above still guards content
  # correctness on the initial download.
  overwrite = false
}
