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
| [`config/lab.yml`](config/lab.yml) | Shared facts (domain, subnet, ports, admin SSH keys) — single source of truth across all three layers below | — |
| [`infra/tofu/`](infra/tofu/) | Provision (VM, disks, Proxmox firewall, DNS) | OpenTofu |
| [`ansible/`](ansible/) | Configure (WireGuard, NAT, hardening, k3s bootstrap) | Ansible |
| [`clusters/lab/`](clusters/lab/) | Deliver (everything in-cluster) | Argo CD |
| [`docs/`](docs/) | Architecture, bootstrap, secrets, SSH keys, observability, backups, media retention, runbooks | — |

## Status

Phases 1–5 are done and applied live. The VM, its disks and the Proxmox
filter firewall are provisioned (Tofu); WireGuard, single-IP NAT/DNAT,
host + VM hardening, the `tank` ZFS stripe, the virtiofs share and k3s are
configured (Ansible); Argo CD runs the platform layer — cert-manager,
Traefik on `:443`, Authelia forward-auth and external-dns.

**Phase 6 — Media apps** is live in the `media` namespace, reconciled from
[`clusters/lab/apps/`](clusters/lab/apps/): Deluge, Prowlarr, FlareSolverr,
Sonarr, Radarr, Bazarr, Unpackerr, Recyclarr, Plex, Tautulli, Seerr,
Maintainerr and Homepage — the last of those being the front door at the
apex, `tomkatom.com`, and the only page here written for viewers rather
than for the operator. **Migrating the old server's state onto them —
media files, `*arr` databases, Plex identity, Deluge's session — is
operator work still in progress**, per
[`docs/runbooks/media-migration.md`](docs/runbooks/media-migration.md).

How a grab becomes a Plex file — the download directory, the Deluge label
and the `*arr` category that have to agree for hardlinked imports to work —
is declared in git and described once, in
[`clusters/lab/apps/README.md`](clusters/lab/apps/README.md#the-data-path-contract).
Moving an existing library onto it is
[`docs/runbooks/deluge-arr-path-contract.md`](docs/runbooks/deluge-arr-path-contract.md).

**Phase 7 — Observability** and **Phase 8 — Backups** are live. Prometheus,
Loki, Alloy and Grafana run in the `monitoring` namespace and alert to
Telegram ([`docs/observability.md`](docs/observability.md)). Backups are
three tiers — sanoid ZFS snapshots for rollback, a nightly `vzdump` of the
k3s VM into Proxmox Backup Server, and a nightly file-level backup of the
hypervisor itself — all client-side encrypted into a Backblaze B2 bucket for
about $0.25/month ([`docs/backups.md`](docs/backups.md)).

Three things are deliberately still pending:

- **Public DNS has not moved.** `tomkatom.com` and the `sonarr./radarr./
  prowlarr./deluge.` CNAMEs still resolve to the old server, and
  external-dns runs `--dry-run` so it writes nothing. Every new hostname is
  NXDOMAIN publicly and is reached over WireGuard only. Moving the zone is
  a separate, operator-triggered runbook —
  [`docs/runbooks/dns-cutover.md`](docs/runbooks/dns-cutover.md).
- **The first restore drill has not been run.** Everything in Phase 8 is
  live and alerting, but `RestoreDrillOverdue` fires until a real restore
  has been performed and its final step touches the marker — deliberately,
  because a backup that has never been restored is a hypothesis. Procedure:
  [`docs/runbooks/restore.md`](docs/runbooks/restore.md#the-restore-drill).

See the phased plan in
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

## Development

Formatting is enforced locally via [pre-commit](https://pre-commit.com):

```sh
uv tool install pre-commit   # one-time
pre-commit install           # wires the git hook, once per clone
pre-commit run --all-files   # optional: check everything now
```

Hooks: trailing whitespace / EOF / line-ending fixups, YAML syntax +
`yamllint` (same config as CI), `shfmt`, `tofu fmt` for
[`infra/tofu/`](infra/tofu/), and `gitleaks` (same secret-scan CI blocks
on). Renovate keeps hook versions up to date (`.pre-commit-config.yaml`
is a supported manager).

## Domain

`tomkatom.com`, DNS on Cloudflare, wildcard cert `*.tomkatom.com` via
cert-manager (DNS-01).
