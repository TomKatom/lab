# vmbr1 — internal bridge for the k3s-node VM (Tofu-owned).
#
# A brand new, isolated bridge: this resource never touches vmbr0 or the
# host's existing public networking, so applying it carries very low blast
# radius (it cannot by itself strand management access). Ansible (Phase 3)
# layers nftables NAT/DNAT + masquerade on top of this bridge for the
# single-public-IP model — a different nftables hook than the Tofu-owned
# filter firewall in firewall.tf, so the two coexist without conflict.
resource "proxmox_network_linux_bridge" "vmbr1" {
  node_name = var.node_name
  name      = "vmbr1"
  address   = local.lab.network.vmbr1_host_address
  autostart = true
  comment   = "Managed by OpenTofu - internal bridge for k3s-node"
}
