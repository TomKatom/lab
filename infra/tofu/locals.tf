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
  # node_mgmt_rules is the management-plane list: firewall.tf stamps
  # `source = "+mgmt"` onto every entry once restrict_management is true, so
  # anything added here is reachable from the internal and WireGuard subnets
  # only — which is exactly the exposure a metrics endpoint should have.
  # Prometheus scrapes from the k3s VM at network.vm_ip_address, inside
  # internal_subnet, so it is already covered by the ipset; no firewall.tf
  # change accompanies a new entry.
  node_mgmt_rules = [
    { comment = "SSH (host)", proto = "tcp", dport = local.lab.ports.ssh },
    { comment = "Proxmox API/UI", proto = "tcp", dport = local.lab.ports.pve_api },
    { comment = "node_exporter (host metrics)", proto = "tcp", dport = local.lab.ports.node_exporter },
    { comment = "Proxmox Backup Server UI/API", proto = "tcp", dport = local.lab.ports.pbs_api },
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

  # Management A records — internal endpoints, addressable by name (see
  # config/lab.yml's management_hosts). Deliberately a separate set from
  # dns_a_records above, and NOT gated on var.manage_dns: that gate exists
  # because apex/wildcard/vpn are still serving the old server, whereas
  # every name here is new, lives under the `lab.` label, and has never
  # resolved to anything — so creating them can't disturb the cutover.
  mgmt_dns_domain = "${local.lab.management_subdomain}.${local.lab.domain}"
  dns_mgmt_records = {
    for host in local.lab.management_hosts : host.name => {
      name = "${host.name}.${local.mgmt_dns_domain}"
      # `address` is a key into config/lab.yml's `network` map; the /CIDR
      # some of those carry (vmbr1_host_address) is a host-interface fact,
      # not part of the record.
      content = split("/", local.lab.network[host.address])[0]
      comment = "Managed by OpenTofu - internal management endpoint (WireGuard-only)"
    }
  }
  # `vpn.${mgmt_dns_domain}` (the duplicate tunnel-endpoint record) retired
  # here: the DNS cutover flip landed `vpn.${domain}` for real (see
  # docs/runbooks/dns-cutover.md), so peer configs point there now instead.
}
