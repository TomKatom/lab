# lab

GitOps IaC for my personal dedicated server (OVH) — a seedbox + media stack
(Plex, the *arrs, Deluge) running on a hardened single-node k3s cluster.
This repo is the single source of truth: everything is declarative,
versioned, and reconciled from git.

See [`master-plan.md`](master-plan.md) for the full design rationale and
locked decisions, and [`docs/architecture.md`](docs/architecture.md) for the
living reference — kept in sync with what's actually implemented as each
phase lands.

## Layout

| Path | Layer | Tool |
|---|---|---|
| [`infra/tofu/`](infra/tofu/) | Provision (VM, disks, Proxmox firewall, DNS) | OpenTofu |
| [`ansible/`](ansible/) | Configure (WireGuard, NAT, hardening, k3s bootstrap) | Ansible |
| [`clusters/lab/`](clusters/lab/) | Deliver (everything in-cluster) | Argo CD |
| [`docs/`](docs/) | Architecture, bootstrap, secrets, runbooks | — |

## Status

Currently in **Phase 1 — repo scaffold**. No infrastructure has been
provisioned yet. See the phased plan in
[`master-plan.md`](master-plan.md#phased-implementation-each-phase--its-own-pr).

## Secrets

All secrets are encrypted at rest with [SOPS](https://github.com/getsops/sops)
+ [age](https://github.com/FiloSottile/age) — nothing plaintext is ever
committed, enforced in CI by [gitleaks](https://github.com/gitleaks/gitleaks).
See [`docs/secrets.md`](docs/secrets.md) for key custody and how to decrypt
locally.

## CI

Every PR runs `tofu fmt/validate`, `ansible-lint` + `yamllint`,
`helm template | kubeconform` (+ `kustomize build | kubeconform` for the
ksops-encrypted overlays), and `gitleaks`. See
[`.github/workflows/ci.yml`](.github/workflows/ci.yml).

## Domain

`tomkatom.com`, DNS on Cloudflare, wildcard cert `*.tomkatom.com` via
cert-manager (DNS-01).
