# infra/tofu

**Layer 1 — Provision.** OpenTofu (`bpg/proxmox` + `cloudflare` providers): the
`k3s-node` VM on `vmbr1`, disk layout, the Proxmox filtering firewall, and
foundational Cloudflare DNS records for `*.tomkatom.com`.

State is local and natively encrypted (OpenTofu ≥1.7 state encryption) —
`terraform.tfstate` is committed to git in encrypted form. Secrets (Proxmox
and Cloudflare API tokens) live in `secrets.sops.tfvars`, encrypted with SOPS
+ age; see [`docs/secrets.md`](../../docs/secrets.md).

Not yet implemented — built in Phase 2. See
[`docs/architecture.md`](../../docs/architecture.md) for the design.
