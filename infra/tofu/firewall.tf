# Proxmox filter firewall — default-drop, with an explicit anti-lockout
# escape hatch. This is the highest-risk file in Phase 2: a mistake here can
# strand management access on a server with no IPMI/console.
#
# THE ORDERING INVARIANT (learned the hard way — this file locked the host out
# once already): a default-DROP policy and the accept rules that punch holes in
# it are separate API objects, and OpenTofu will happily create the policy
# first unless the graph forbids it. The original version had the rules
# `depends_on` the node firewall; the rules resource then never ran because an
# upstream dependency failed, while the cluster DROP policy — which depended on
# nothing — applied cleanly. Result: DROP-by-default with zero accept rules.
#
# So the dependency runs the other way round now: POLICY DEPENDS ON RULES.
#
#   ipset ─┐
#          ├─> node accept rules ─> cluster policy (enable + input DROP)
#   node firewall (enable) ─┘
#
#   VM accept rules ─> VM firewall options (enable + input DROP)
#
# That single inversion gives three properties for free:
#   1. Create: the holes exist before the wall goes up.
#   2. Failure: if any rule resource errors, the DROP policy is never reached,
#      so a broken apply leaves the box *open*, not bricked.
#   3. Destroy: reverse order tears the policy down first, so the rules are
#      never removed while DROP is still in force.
#
# Do not add a `depends_on` from a rules resource to a policy resource — that
# reintroduces the lockout and (now) cycles the graph. The `precondition`
# blocks below are the tripwire for anyone who tries.
#
# Provider note (bpg/proxmox 0.111.1): node-scoped policy is NOT set via
# `proxmox_virtual_environment_firewall_options` — that resource requires
# exactly one of `vm_id`/`container_id` and only ever manages VM/container
# scope. Node-level enable/logging is a separate resource,
# `proxmox_node_firewall`, which has no `input_policy` of its own; the node
# inherits the cluster-wide default policy. One DROP posture, not two to keep
# in sync.
#
# Why default-drop is still safe to apply: with `restrict_management = false`
# the SSH/API accept rules below have no `source` restriction (source = null ⇒
# any), so public SSH survives. Phase 3 flips `restrict_management` to true
# only after WireGuard is verified end-to-end; at that point only the `source`
# on those rules narrows to the "mgmt" ipset. 443/32400/torrent/51820-udp stay
# public throughout. `enable_firewall` (default true) is a master kill-switch
# escape hatch independent of that toggle.

# --- Management source ipset (used by both node and VM rules) ------------

resource "proxmox_virtual_environment_firewall_ipset" "mgmt" {
  # No node_name/vm_id: this is a cluster-level ipset, referenceable from
  # any node/VM rule as "+mgmt".
  name    = "mgmt"
  comment = "Managed by OpenTofu - management source CIDRs"

  dynamic "cidr" {
    for_each = local.management_sources
    content {
      name = cidr.value
    }
  }
}

# --- Node (host) firewall ---------------------------------------------------
#
# Enabling the node firewall is inert on its own: Proxmox only filters once the
# *cluster* firewall is enabled, which happens at the very end of this file.

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
    dport   = local.lab.ports.wireguard
    proto   = "udp"
  }

  # Always-public: HTTPS/Plex/torrent, DNAT'd to the VM in Phase 3+.
  # BitTorrent needs both transports on the same port.
  dynamic "rule" {
    for_each = local.public_service_rules
    content {
      type    = "in"
      action  = "ACCEPT"
      comment = rule.value.comment
      dport   = rule.value.dport
      proto   = rule.value.proto
    }
  }

  # Management: SSH + Proxmox API/UI. Anti-lockout — source is unrestricted
  # until restrict_management=true (Phase 3, post-WireGuard-verification).
  dynamic "rule" {
    for_each = local.node_mgmt_rules
    content {
      type    = "in"
      action  = "ACCEPT"
      comment = rule.value.comment
      dport   = rule.value.dport
      proto   = rule.value.proto
      source  = var.restrict_management ? "+mgmt" : null
    }
  }
}

# --- Cluster-wide default policy — MUST BE LAST -----------------------------
#
# This is the wall. Everything above punches the holes. The depends_on is the
# whole anti-lockout mechanism: without it OpenTofu is free to (and did) create
# this first.

resource "proxmox_virtual_environment_cluster_firewall" "this" {
  depends_on = [proxmox_virtual_environment_firewall_rules.node]

  enabled = var.enable_firewall

  input_policy  = "DROP"
  output_policy = "ACCEPT"
  # Must stay ACCEPT: DNAT'd public traffic to the VM (Phase 3, Ansible
  # nftables) is forwarded/routed through the host, not destined for it.
  forward_policy = "ACCEPT"

  lifecycle {
    precondition {
      condition     = length(local.node_mgmt_rules) > 0
      error_message = "Refusing to apply input_policy=DROP with no node management accept rules: that is a guaranteed lockout on a server with no IPMI/console. Add SSH + Proxmox API back to local.node_mgmt_rules."
    }

    precondition {
      condition     = !var.restrict_management || length(local.management_sources) > 0
      error_message = "restrict_management=true narrows SSH/Proxmox API to the '+mgmt' ipset, but local.management_sources is empty — the ipset would match nothing and lock the host out. Populate network.internal_subnet / network.wireguard_subnet in config/lab.yml."
    }
  }
}

# --- VM (k3s-node) firewall -------------------------------------------------
#
# Same invariant, same order: rules first, DROP policy last.

resource "proxmox_virtual_environment_firewall_rules" "vm" {
  depends_on = [proxmox_virtual_environment_firewall_ipset.mgmt]

  node_name = var.node_name
  vm_id     = proxmox_virtual_environment_vm.k3s.vm_id

  # Always-public: HTTPS/Plex/torrent — same service rules as the node scope.
  dynamic "rule" {
    for_each = local.public_service_rules
    content {
      type    = "in"
      action  = "ACCEPT"
      comment = rule.value.comment
      dport   = rule.value.dport
      proto   = rule.value.proto
    }
  }

  # Management: k8s API + SSH into the VM. Same anti-lockout toggle.
  dynamic "rule" {
    for_each = local.vm_mgmt_rules
    content {
      type    = "in"
      action  = "ACCEPT"
      comment = rule.value.comment
      dport   = rule.value.dport
      proto   = rule.value.proto
      source  = var.restrict_management ? "+mgmt" : null
    }
  }
}

resource "proxmox_virtual_environment_firewall_options" "vm" {
  depends_on = [proxmox_virtual_environment_firewall_rules.vm]

  node_name = var.node_name
  vm_id     = proxmox_virtual_environment_vm.k3s.vm_id

  enabled       = var.enable_firewall
  input_policy  = "DROP"
  output_policy = "ACCEPT"

  lifecycle {
    precondition {
      condition     = length(local.vm_mgmt_rules) > 0
      error_message = "Refusing to apply input_policy=DROP on the VM with no management accept rules in local.vm_mgmt_rules."
    }
  }
}

# --- VM (ci-runner) firewall -------------------------------------------------
#
# Same invariant, same order: rules first, DROP policy last. A third,
# independent chain (ipset -> runner rules -> runner options), same shape as
# the k3s-node chain above.

resource "proxmox_virtual_environment_firewall_rules" "runner" {
  depends_on = [proxmox_virtual_environment_firewall_ipset.mgmt]

  node_name = var.node_name
  vm_id     = proxmox_virtual_environment_vm.runner.vm_id

  dynamic "rule" {
    for_each = local.runner_mgmt_rules
    content {
      type    = "in"
      action  = "ACCEPT"
      comment = rule.value.comment
      dport   = rule.value.dport
      proto   = rule.value.proto
      source  = var.restrict_management ? "+mgmt" : null
    }
  }
}

resource "proxmox_virtual_environment_firewall_options" "runner" {
  depends_on = [proxmox_virtual_environment_firewall_rules.runner]

  node_name = var.node_name
  vm_id     = proxmox_virtual_environment_vm.runner.vm_id

  enabled       = var.enable_firewall
  input_policy  = "DROP"
  output_policy = "ACCEPT"

  lifecycle {
    precondition {
      condition     = length(local.runner_mgmt_rules) > 0
      error_message = "Refusing to apply input_policy=DROP on the runner with no management accept rules in local.runner_mgmt_rules."
    }
  }
}
