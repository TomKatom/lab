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
# Orange-clouding the HTTP-only names (`requests.`, the apex) has been looked
# at and rejected twice; the reasons are recorded here so it does not get
# re-proposed as free hardening:
#
#   1. It hides nothing. The origin IP is published by design elsewhere —
#      `PLEX_ADVERTISE_URL` in clusters/lab/apps/plex.yaml hands it to
#      plex.tv, which hands it to every client; Traefik's `ingressEndpoint.ip`
#      carries it; and the grey `*` record below answers with it for any name
#      external-dns has not explicitly created. Proxying two names out of a
#      zone that resolves to the origin everywhere else is not concealment.
#   2. It fails closed on the wrong SSL/TLS mode, loudly. Traefik deliberately
#      keeps :80 off the Service and off the node (clusters/lab/platform/
#      traefik.yaml), and only :443 is DNAT'd — so under Cloudflare's
#      "Flexible" mode, which dials the origin on port 80, every proxied name
#      returns 521 with nothing to debug at the origin. Only Full (strict)
#      works, and that is a zone-level dashboard setting this repo does not
#      manage, so the config would depend on a toggle git cannot see.
#
# If edge filtering is ever actually wanted, the coherent version is all HTTP
# names proxied, `*` narrowed or dropped, :443 restricted to Cloudflare's
# published ranges, the SSL mode pinned here as a `cloudflare_zone_setting`,
# and Traefik configured to trust `CF-Connecting-IP` — which would also be
# what finally gives this cluster a real client IP (see traefik.yaml). That is
# a project, not a checkbox, and it still leaves Plex on the naked IP.
#
# external-dns (Phase 5) manages per-service records (sonarr., auth., ...)
# dynamically. It runs `policy: sync`, which does delete — what keeps it off
# these Tofu-owned records is ownership, not policy: external-dns only
# touches a record carrying its own `_externaldns.` TXT with
# `external-dns/owner=lab-k3s`, and nothing here has one. See
# clusters/lab/platform/external-dns.yaml.
#
# `cloudflare_zone_id` is a plain var (not a data source) to avoid Cloudflare
# v5 provider schema churn on zone lookups — it's not secret, just an
# operator-verified fact filled into terraform.tfvars.
#
# Gated by `var.manage_dns` (default false): the zone's apex/wildcard/vpn
# records currently point at the old server and are still in production use.
# Until cutover, `for_each` resolves to `{}` so `tofu apply` never touches
# Cloudflare — flip `manage_dns` to true once the new server is ready to take
# over these records. The apex already exists and Cloudflare allows several A
# records at one name, so that flip needs an `import` block or the zone ends
# up round-robining between two servers: the procedure is
# docs/runbooks/dns-cutover.md, not a bare `tofu apply`.

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
# addresses of the host and the guests. Publishing private targets in a
# public zone is the deliberate trade: no split-horizon resolver to run or
# keep alive, the names work from any device, and they can hold real
# certificates later — at the cost of disclosing the internal layout
# (RFC1918 addresses that are useless without a tunnel) and of tripping
# DNS-rebinding filters on the occasional resolver that strips private
# answers from public domains.
#
# Ungated by `manage_dns` unlike the records above — see locals.tf's
# `dns_mgmt_records` for why that's safe pre-cutover. These do need the
# Cloudflare token to actually carry Zone:DNS:Edit on this zone, which the
# gated records have so far let us defer proving.
#
# The duplicate `vpn.<management_subdomain>.<domain>` tunnel-endpoint record
# that used to live here has been retired now that the gated `vpn.<domain>`
# record above is live — see docs/runbooks/dns-cutover.md.
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
