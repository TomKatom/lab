# Derived values. `local.lab` is the repo-root single source of truth shared
# with Ansible (Phase 3) and Helm/Argo (Phase 5) — see config/lab.yml. Only
# Tofu-internal derivations (never re-declared as variables) belong here.

locals {
  lab = yamldecode(file("${path.module}/../../config/lab.yml"))

  vm_gateway         = split("/", local.lab.network.vmbr1_host_address)[0]
  vm_ip_cidr         = "${local.lab.network.vm_ip_address}/${split("/", local.lab.network.internal_subnet)[1]}"
  management_sources = [local.lab.network.internal_subnet, local.lab.network.wireguard_subnet]

  # Firewall rule sets (firewall.tf) — the always-public rules are identical
  # on the node (DNAT target) and VM scopes; only the comments used to differ.
  public_service_rules = [
    { comment = "HTTPS", proto = "tcp", dport = local.lab.ports.https },
    { comment = "Plex", proto = "tcp", dport = local.lab.ports.plex },
    { comment = "Torrent TCP", proto = "tcp", dport = local.lab.ports.torrent },
    { comment = "Torrent UDP", proto = "udp", dport = local.lab.ports.torrent },
  ]
  node_mgmt_rules = [
    { comment = "SSH (host)", proto = "tcp", dport = local.lab.ports.ssh },
    { comment = "Proxmox API/UI", proto = "tcp", dport = local.lab.ports.pve_api },
  ]
  vm_mgmt_rules = [
    { comment = "k8s API", proto = "tcp", dport = local.lab.ports.k8s_api },
    { comment = "SSH (VM)", proto = "tcp", dport = local.lab.ports.ssh },
  ]

  # Cloudflare A records (cloudflare.tf).
  dns_a_records = {
    apex     = { name = local.lab.domain, comment = "Managed by OpenTofu" }
    wildcard = { name = "*.${local.lab.domain}", comment = "Managed by OpenTofu" }
    vpn      = { name = "vpn.${local.lab.domain}", comment = "Managed by OpenTofu - WireGuard endpoint" }
  }
}
