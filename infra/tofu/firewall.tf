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
# (There is no per-VM firewall chain: guests run firewall=false so host egress
# NAT works — see the "VM (guest) firewall — intentionally absent" note below.)
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

  lifecycle {
    # The tripwire on the wg1 guest exit VPN. Unlike the preconditions on the
    # cluster policy at the bottom of this file, this one guards against
    # *exposure* rather than lockout, and it takes no part in the ordering
    # invariant the header describes.
    #
    # It lives on THIS resource, not on the cluster policy, because this
    # resource is the write it guards. The block below is what materialises
    # local.management_sources into the '+mgmt' ipset, and nothing downstream
    # re-checks it: the node rules already reference '+mgmt' by name and the
    # cluster firewall is already enabled from an earlier apply, so the
    # instant those CIDRs land in the ipset the exposure is live. A
    # precondition on the cluster policy would evaluate strictly after this
    # apply had succeeded, abort the run without rolling the ipset back, and
    # leave every holder of an exit-tunnel config with host SSH, the Proxmox
    # API and PBS until somebody noticed the failed apply. A precondition is
    # only prevention if it sits on the resource that does the damage.
    #
    # What it does not do. It is exact string equality over the list, not
    # CIDR containment (OpenTofu has no containment function and
    # cidrsubnet/cidrhost cannot express one), so it catches the realistic
    # mistake — someone appending network.wireguard_exit_subnet itself — and
    # not a supernet like 10.0.0.0/8. And it reads local.lab directly, so a
    # missing config/lab.yml key hard-errors here rather than silently
    # passing on a typo; that is deliberate, it pins the key's existence.
    precondition {
      condition     = !contains(local.management_sources, local.lab.network.wireguard_exit_subnet)
      error_message = "network.wireguard_exit_subnet is in local.management_sources: the wg1 guest exit VPN would be stamped into the '+mgmt' ipset, and every guest holding an exit-tunnel config would reach host SSH, the Proxmox API and Proxmox Backup Server. Remove it from local.management_sources in locals.tf — the exit subnet must never be a management source."
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
  # The ansible/roles/pve_firewall role pins the node to the nftables backend
  # live via `pvesh set .../firewall/options --nftables 1` (fixes the VM
  # egress-NAT breakage the legacy iptables backend caused — see
  # phase3-plan.md's PR-NAT-FIX). Declaring it here too keeps Tofu's state in
  # sync with that Ansible-enforced reality; leaving it unset previously made
  # every plan want to flip it back to the provider default (false), which
  # would silently undo the Ansible fix on the next apply.
  nftables = true
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

  # Always-public: the guest exit-VPN endpoint (wg1). A second listener
  # rather than a second peer subnet inside the rule above, so the host-side
  # isolation can match on `iifname "wg1"` (ansible/roles/network_nat) and
  # a leaked guest config reveals nothing about the admin tunnel. This port
  # grants no lab access by itself — network.wireguard_exit_subnet is
  # deliberately absent from local.management_sources, which the precondition
  # on the "+mgmt" ipset above asserts.
  #
  # Not folded together with the "WireGuard" rule via a dynamic block: a
  # two-element list would hide two very different exposure stories behind a
  # for_each. (local.public_service_rules earns its dynamic block by being
  # *derived* from nat_ingress_rules; this is not derived from anything.)
  rule {
    type    = "in"
    action  = "ACCEPT"
    comment = "WireGuard (guest exit)"
    dport   = local.lab.ports.wireguard_exit
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

  # Management plane: SSH, Proxmox API/UI, host metrics — whatever
  # local.node_mgmt_rules carries. Anti-lockout — source is unrestricted
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

# --- VM (guest) firewall — intentionally absent -----------------------------
#
# There is deliberately NO per-VM (k3s-node / ci-runner) firewall here. A
# per-VM firewall requires `firewall = true` on the vNIC (vm-k3s.tf /
# vm-runner.tf), which makes Proxmox insert a per-VM firewall bridge (fwbr).
# Under the nftables firewall backend that bridge does stateful L2 conntrack
# (nf_conntrack_bridge) and CONFIRMS the guest's outbound connection before it
# is routed — after which the host's L3 masquerade (Ansible network_nat) can
# no longer attach a SNAT binding, so the guest has NO working egress. (The
# legacy iptables backend breaks the same path differently, via
# bridge-nf-call-iptables=1 committing a null SNAT binding at the bridge
# stage.) Egress NAT and a per-VM firewall bridge are mutually exclusive here.
#
# Guests run with `firewall = false` and are protected by position, not a
# per-VM wall: they hold no public IP (RFC1918 on vmbr1), so the internet
# reaches them only through explicit host DNAT, and management reaches them
# only over WireGuard. The gap this leaves — a WG peer has unrestricted L3 to
# the guests, and there is no east-west segmentation between guests — is a
# tracked follow-up: see master-plan.md, "Internal segmentation / DMZ (TODO)".
