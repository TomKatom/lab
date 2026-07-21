# Derived values. `local.lab` is the repo-root single source of truth shared
# with Ansible (Phase 3) and Helm/Argo (Phase 5) — see config/lab.yml. Only
# Tofu-internal derivations (never re-declared as variables) belong here.

locals {
  lab = yamldecode(file("${path.module}/../../config/lab.yml"))

  vm_gateway         = split("/", local.lab.network.vmbr1_host_address)[0]
  vm_ip_cidr         = "${local.lab.network.vm_ip_address}/${split("/", local.lab.network.internal_subnet)[1]}"
  runner_ip_cidr     = "${local.lab.network.runner_address}/${split("/", local.lab.network.internal_subnet)[1]}"
  management_sources = [local.lab.network.internal_subnet, local.lab.network.wireguard_subnet]

  # Firewall rule sets (firewall.tf). public_service_rules is derived from
  # config/lab.yml's nat_ingress_rules — the same list Ansible's network_nat
  # role DNATs from — so the set of forwarded ports only exists in one place.
  public_service_rules = [
    for rule in local.lab.nat_ingress_rules : {
      comment = rule.comment
      proto   = rule.proto
      dport   = local.lab.ports[rule.port]
    }
  ]
  node_mgmt_rules = [
    { comment = "SSH (host)", proto = "tcp", dport = local.lab.ports.ssh },
    { comment = "Proxmox API/UI", proto = "tcp", dport = local.lab.ports.pve_api },
  ]
  # No vm_mgmt_rules / runner_mgmt_rules: guests run without a per-VM firewall
  # (firewall=false, so host egress NAT works) — see firewall.tf "VM (guest)
  # firewall — intentionally absent". Guest ingress is governed by position
  # (no public IP; internet via host DNAT only, mgmt via WireGuard only).

  # Cloudflare A records (cloudflare.tf).
  dns_a_records = {
    apex     = { name = local.lab.domain, comment = "Managed by OpenTofu" }
    wildcard = { name = "*.${local.lab.domain}", comment = "Managed by OpenTofu" }
    vpn      = { name = "vpn.${local.lab.domain}", comment = "Managed by OpenTofu - WireGuard endpoint" }
  }
}
