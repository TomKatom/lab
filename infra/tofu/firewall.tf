# Proxmox filter firewall — default-drop, with an explicit anti-lockout
# escape hatch. This is the highest-risk file in Phase 2: a mistake here can
# strand management access on a server with no IPMI/console.
#
# Deviation from the original plan sketch, confirmed against the bpg/proxmox
# 0.111.1 docs: node-scoped firewall policy is NOT set via
# `proxmox_virtual_environment_firewall_options` — that resource requires
# exactly one of `vm_id`/`container_id` and only ever manages VM/container
# scope. Node-level enable/logging is a *separate* resource,
# `proxmox_node_firewall` (the non-deprecated short name; its old long name
# `proxmox_virtual_environment_node_firewall` is deprecated in 0.111.1). That
# resource has no `input_policy`/`output_policy` of its own — the node
# inherits the cluster-wide default policy set below, which is exactly what
# we want (one DROP-by-default posture, not two to keep in sync).
#
# Why this is safe on first apply: with `restrict_management = false` the
# firewall is enabled (default-drop hardening) but the SSH/API accept rules
# below have no `source` restriction (source = null ⇒ any), so public SSH
# survives. Phase 3 flips `restrict_management` to true only after
# WireGuard is verified end-to-end — at that point only the `source` on
# those specific rules narrows to the "mgmt" ipset; 443/32400/torrent/
# 51820-udp stay public throughout. `enable_firewall` (default true) is a
# master kill-switch escape hatch independent of that toggle.

# --- Cluster-wide default policy ------------------------------------------

resource "proxmox_virtual_environment_cluster_firewall" "this" {
  enabled = var.enable_firewall

  input_policy  = "DROP"
  output_policy = "ACCEPT"
  # Must stay ACCEPT: DNAT'd public traffic to the VM (Phase 3, Ansible
  # nftables) is forwarded/routed through the host, not destined for it.
  forward_policy = "ACCEPT"
}

# --- Management source ipset (used by both node and VM rules) ------------

resource "proxmox_virtual_environment_firewall_ipset" "mgmt" {
  # No node_name/vm_id: this is a cluster-level ipset, referenceable from
  # any node/VM rule as "+mgmt".
  name    = "mgmt"
  comment = "Managed by OpenTofu - management source CIDRs"

  dynamic "cidr" {
    for_each = var.management_sources
    content {
      name = cidr.value
    }
  }
}

# --- Node (host) firewall --------------------------------------------------

resource "proxmox_node_firewall" "this" {
  node_name = var.node_name
  enabled   = var.enable_firewall
}

resource "proxmox_virtual_environment_firewall_rules" "node" {
  depends_on = [
    proxmox_node_firewall.this,
    proxmox_virtual_environment_firewall_ipset.mgmt,
  ]

  node_name = var.node_name
  # vm_id left empty: node-scoped rules.

  # Always-public: WireGuard tunnel endpoint (Phase 3 stands up the
  # interface; the accept rule can exist ahead of that).
  rule {
    type    = "in"
    action  = "ACCEPT"
    comment = "WireGuard"
    dport   = var.wireguard_port
    proto   = "udp"
  }

  # Always-public: HTTPS ingress (DNAT'd to the VM's Traefik in Phase 3+).
  rule {
    type    = "in"
    action  = "ACCEPT"
    comment = "HTTPS (DNAT to VM)"
    dport   = var.https_port
    proto   = "tcp"
  }

  # Always-public: Plex direct-play (DNAT'd to the VM).
  rule {
    type    = "in"
    action  = "ACCEPT"
    comment = "Plex (DNAT to VM)"
    dport   = var.plex_port
    proto   = "tcp"
  }

  # Always-public: torrent (DNAT'd to the VM). BitTorrent needs both
  # transports on the same port.
  rule {
    type    = "in"
    action  = "ACCEPT"
    comment = "Torrent TCP (DNAT to VM)"
    dport   = var.torrent_port
    proto   = "tcp"
  }

  rule {
    type    = "in"
    action  = "ACCEPT"
    comment = "Torrent UDP (DNAT to VM)"
    dport   = var.torrent_port
    proto   = "udp"
  }

  # Management: SSH to the host. Anti-lockout — source is unrestricted
  # until restrict_management=true (Phase 3, post-WireGuard-verification).
  rule {
    type    = "in"
    action  = "ACCEPT"
    comment = "SSH (host)"
    dport   = var.ssh_port
    proto   = "tcp"
    source  = var.restrict_management ? "+mgmt" : null
  }

  # Management: Proxmox API/UI. Same anti-lockout toggle as SSH above.
  rule {
    type    = "in"
    action  = "ACCEPT"
    comment = "Proxmox API/UI"
    dport   = var.pve_api_port
    proto   = "tcp"
    source  = var.restrict_management ? "+mgmt" : null
  }
}

# --- VM (k3s-node) firewall -------------------------------------------------

resource "proxmox_virtual_environment_firewall_options" "vm" {
  depends_on = [proxmox_virtual_environment_vm.k3s]

  node_name = var.node_name
  vm_id     = proxmox_virtual_environment_vm.k3s.vm_id

  enabled       = var.enable_firewall
  input_policy  = "DROP"
  output_policy = "ACCEPT"
}

resource "proxmox_virtual_environment_firewall_rules" "vm" {
  depends_on = [
    proxmox_virtual_environment_firewall_options.vm,
    proxmox_virtual_environment_firewall_ipset.mgmt,
  ]

  node_name = var.node_name
  vm_id     = proxmox_virtual_environment_vm.k3s.vm_id

  rule {
    type    = "in"
    action  = "ACCEPT"
    comment = "HTTPS"
    dport   = var.https_port
    proto   = "tcp"
  }

  rule {
    type    = "in"
    action  = "ACCEPT"
    comment = "Plex direct-play"
    dport   = var.plex_port
    proto   = "tcp"
  }

  rule {
    type    = "in"
    action  = "ACCEPT"
    comment = "Torrent TCP"
    dport   = var.torrent_port
    proto   = "tcp"
  }

  rule {
    type    = "in"
    action  = "ACCEPT"
    comment = "Torrent UDP"
    dport   = var.torrent_port
    proto   = "udp"
  }

  # Management: k8s API + SSH into the VM. Same anti-lockout toggle.
  rule {
    type    = "in"
    action  = "ACCEPT"
    comment = "k8s API"
    dport   = var.k8s_api_port
    proto   = "tcp"
    source  = var.restrict_management ? "+mgmt" : null
  }

  rule {
    type    = "in"
    action  = "ACCEPT"
    comment = "SSH (VM)"
    dport   = var.ssh_port
    proto   = "tcp"
    source  = var.restrict_management ? "+mgmt" : null
  }
}
