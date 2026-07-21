# virtiofs share of the host's tank/data ZFS dataset (created by the
# ansible/roles/zfs_tank role) into the k3s VM. One concern — the virtiofs
# share — spanning this directory-mapping resource and the consuming
# `virtiofs` block on the VM in vm-k3s.tf (a nested block can't live in a
# separate file). Requires /tank/data to already exist on the node.
#
# proxmox_hardware_mapping_dir, not the _virtual_environment_-prefixed
# alias: the provider docs mark proxmox_virtual_environment_hardware_mapping_dir
# deprecated (removal in v1.0) in favor of this shorter name, same as
# proxmox_download_file / proxmox_network_linux_bridge elsewhere in this repo.
resource "proxmox_hardware_mapping_dir" "data" {
  name    = "data"
  comment = "tank/data — media library + downloads, shared to k3s-node via virtiofs"

  map = [
    {
      node = var.node_name
      path = "/tank/data"
    },
  ]
}
