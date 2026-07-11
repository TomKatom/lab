# Foundational Cloudflare DNS records: apex + wildcard (+ a dedicated `vpn.`
# host record for the WireGuard endpoint), all pointing at the OVH host's
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

resource "cloudflare_dns_record" "apex" {
  zone_id = var.cloudflare_zone_id
  name    = var.domain
  type    = "A"
  content = var.ovh_public_ip
  ttl     = 1
  proxied = false
  comment = "Managed by OpenTofu"
}

resource "cloudflare_dns_record" "wildcard" {
  zone_id = var.cloudflare_zone_id
  name    = "*.${var.domain}"
  type    = "A"
  content = var.ovh_public_ip
  ttl     = 1
  proxied = false
  comment = "Managed by OpenTofu"
}

resource "cloudflare_dns_record" "vpn" {
  zone_id = var.cloudflare_zone_id
  name    = "vpn.${var.domain}"
  type    = "A"
  content = var.ovh_public_ip
  ttl     = 1
  proxied = false
  comment = "Managed by OpenTofu - WireGuard endpoint"
}
