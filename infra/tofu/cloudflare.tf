# Cloudflare DNS. Two independent sets, gated differently:
#   1. Foundational public records — apex + wildcard + `vpn.` — pointing at
#      the OVH host's single public IP. Gated by `manage_dns` (see below).
#   2. Management records under `<management_subdomain>.<domain>`, pointing
#      at internal addresses. Ungated — second resource at the bottom of this
#      file.
#
# The first set: apex + wildcard (+ a dedicated `vpn.` host record for the
# WireGuard endpoint), all pointing at the OVH host's
# single public IP. Grey-cloud (proxied = false) throughout — Plex (32400)
# and the torrent port are non-HTTP protocols that would break behind the
# Cloudflare proxy, and the apex/wildcard need to resolve straight to the
# host for the same reason as everything else on this box.
#
# external-dns (Phase 5) manages per-service records (sonarr., auth., ...)
# dynamically; it must run with an `upsert-only` policy so it can never
# delete or clobber these Tofu-owned apex/wildcard/vpn records.
#
# `cloudflare_zone_id` is a plain var (not a data source) to avoid Cloudflare
# v5 provider schema churn on zone lookups — it's not secret, just an
# operator-verified fact filled into terraform.tfvars.
#
# Gated by `var.manage_dns` (default false): the zone's apex/wildcard/vpn
# records currently point at the old server and are still in production use.
# Until cutover, `for_each` resolves to `{}` so `tofu apply` never touches
# Cloudflare — flip `manage_dns` to true once the new server is ready to take
# over these records.

resource "cloudflare_dns_record" "records" {
  for_each = var.manage_dns ? local.dns_a_records : {}

  zone_id = var.cloudflare_zone_id
  name    = each.value.name
  type    = "A"
  content = var.ovh_public_ip
  ttl     = 1
  proxied = false
  comment = each.value.comment
}

# Management endpoints by name (config/lab.yml `management_hosts`): grey-cloud
# A records under `<management_subdomain>.<domain>` pointing at the RFC1918
# addresses of the host and the guests, plus a `vpn.` name for the tunnel
# endpoint itself. Publishing private targets in a public zone is the
# deliberate trade: no split-horizon resolver to run or keep alive, the names
# work from any device, and they can hold real certificates later — at the
# cost of disclosing the internal layout (RFC1918 addresses that are useless
# without a tunnel) and of tripping DNS-rebinding filters on the occasional
# resolver that strips private answers from public domains.
#
# Ungated by `manage_dns` unlike the records above — see locals.tf's
# `dns_mgmt_records` for why that's safe pre-cutover. These do need the
# Cloudflare token to actually carry Zone:DNS:Edit on this zone, which the
# gated records have so far let us defer proving.
resource "cloudflare_dns_record" "management" {
  for_each = local.dns_mgmt_records

  zone_id = var.cloudflare_zone_id
  name    = each.value.name
  type    = "A"
  content = each.value.content
  ttl     = 1
  proxied = false
  comment = each.value.comment
}

# Renamed from the pre-for_each apex/wildcard/vpn resources — same records,
# just addressed as records["..."] now. No destroy/recreate.
moved {
  from = cloudflare_dns_record.apex
  to   = cloudflare_dns_record.records["apex"]
}

moved {
  from = cloudflare_dns_record.wildcard
  to   = cloudflare_dns_record.records["wildcard"]
}

moved {
  from = cloudflare_dns_record.vpn
  to   = cloudflare_dns_record.records["vpn"]
}
