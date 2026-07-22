# infra/tofu

**Layer 1 — Provision.** OpenTofu (`bpg/proxmox` + `cloudflare` providers): the
`k3s-node` VM on `vmbr1`, disk layout, the Proxmox filtering firewall, and
foundational Cloudflare DNS records for `*.tomkatom.com`.

State is local and natively encrypted (OpenTofu ≥1.7 state encryption) —
`terraform.tfstate` is committed to git in encrypted form. Secrets (Proxmox
and Cloudflare API tokens) live in `secrets.sops.tfvars.json`, encrypted with
SOPS + age; see [`docs/secrets.md`](../../docs/secrets.md).

Facts shared with the other IaC layers (domain, subnet, ports) live in
[`../../config/lab.yml`](../../config/lab.yml), not here — see `locals.tf`.

## Files

| File | Purpose |
|---|---|
| `versions.tf` | OpenTofu + provider pins. No `encryption` block — see below. |
| `providers.tf` | `proxmox` (API token + SSH) and `cloudflare` provider config. |
| `locals.tf` | Reads `config/lab.yml`; derives Tofu-internal values (rule lists, DNS record map). |
| `network.tf` | `vmbr1`, the internal bridge the VM lives on (Tofu-owned). |
| `storage.tf` | Downloads the Debian 13 cloud image into the `import` datastore. |
| `vm-k3s.tf` | The `k3s-node` VM: sizing, OS + data disks, cloud-init. |
| `firewall.tf` | Cluster/node/VM Proxmox filter firewall, anti-lockout toggle. |
| `cloudflare.tf` | Apex/wildcard/vpn `A` records, grey-cloud. |
| `variables.tf` / `outputs.tf` | Full variable surface; non-sensitive outputs for Phase 3 Ansible. |
| `terraform.tfvars` | Committed, non-secret environment values (`CHANGE_ME` placeholders). |
| `secrets.sops.tfvars.json` | Encrypted: Proxmox + Cloudflare API tokens. |
| `state.sops.env` | Encrypted: the state-encryption passphrase. |
| `tofu.sh` | Apply wrapper (local *and* CI) — injects `TF_ENCRYPTION`, decrypts secrets. |

## Usage

State encryption needs a passphrase that can never be a literal in code
(OpenTofu evaluates the `encryption` block before variables), so there is no
`encryption {}` block in this directory — it's injected at runtime via the
`TF_ENCRYPTION` env var instead. Don't run `tofu` directly for `plan`/
`apply`/`destroy`; use the wrapper, which builds `TF_ENCRYPTION` from
`state.sops.env` and feeds `secrets.sops.tfvars.json` in as a `-var-file`,
both via SOPS decryption that never touches disk:

```sh
./tofu.sh init
./tofu.sh plan
./tofu.sh apply
```

`tofu fmt`, `tofu validate`, and CI's `tofu init -backend=false` don't need
any of that — they never read state or evaluate an encryption config, so
they run as plain `tofu <command>` with no secrets required.

First-time bootstrap (populating the tfvars/secrets files, the dead-man
switch for the first apply, and enabling the gated CI pipeline) is
documented in
[`docs/runbooks/tofu-apply.md`](../../docs/runbooks/tofu-apply.md). Every
apply after the first one runs through
[`.github/workflows/tofu-apply.yml`](../../.github/workflows/tofu-apply.yml):
a `plan` job on every pull request targeting `master`, gated by a
`production` GitHub Environment approval before `apply` ever runs. That workflow runs this same
`tofu.sh`, decrypting the same committed SOPS files with the age key from
the `SOPS_AGE_KEY` repo secret — so CI and a laptop take one code path and
there is no parallel copy of any credential to keep in sync.

See [`docs/architecture.md`](../../docs/architecture.md) for the design.
