# Secrets

One age keypair covers everything encrypted in this repo: Kubernetes
Secrets (via [ksops](https://github.com/viaduct-ai/kustomize-sops)),
OpenTofu tfvars, and Ansible group/host vars. Rules live in
[`.sops.yaml`](../.sops.yaml).

## The keypair

- **Public key** (committed, safe to share): see `.sops.yaml`.
- **Private key**: generated locally and never committed. It exists in a
  fixed set of places, and adding one is a policy decision, not a chore:

| Copy | Why it exists |
|---|---|
| `~/.config/sops/age/keys.txt` on the operator's machine | Local `sops` edits and `./tofu.sh` runs. SOPS' and age's default lookup path, so no `SOPS_AGE_KEY_FILE` is needed locally. |
| Password-manager entry ("lab — age SOPS key") | The durable backup, and the only recovery path. |
| `SOPS_AGE_KEY` GitHub Actions **repository** secret | Lets the gated workflows decrypt the committed SOPS files directly — see [CI / Argo access](#ci--argo-access) and the trade it accepts. |
| `sops-age-key` k8s Secret in the `argocd` namespace | Lets Argo CD decrypt `clusters/**/*.sops.yaml` in-cluster via ksops. Planted at bootstrap — Phase 4, see `docs/bootstrap.md`. |

Losing every copy means every `.sops.yaml`-matched file in this repo becomes
permanently unreadable — there is no recovery path except generating a new
key and re-encrypting everything from plaintext sources you kept elsewhere.

## What gets encrypted

`.sops.yaml` creation rules, by path:

| Path pattern | What | Encrypted fields |
|---|---|---|
| `clusters/**/*.sops.yaml` | k8s Secrets, decrypted in-cluster by ksops | only `data`/`stringData` — metadata stays plaintext so kustomize/Argo can diff |
| `infra/tofu/**/*.sops.tfvars.json` | Proxmox + Cloudflare API tokens | whole file (opaque binary — see `infra/tofu/README.md` for why the `.json` suffix) |
| `infra/tofu/state.sops.env` | OpenTofu native state-encryption passphrase | whole file |
| `ansible/**/*.sops.yml` | group/host vars secrets | whole file |

Anything matching one of these patterns must be encrypted before it's
committed — `gitleaks` in CI is the backstop, not the primary control.

## Local workflow

```sh
# edit an existing encrypted file (decrypts to $EDITOR, re-encrypts on save)
sops infra/tofu/state.sops.env
sops --input-type binary --output-type binary infra/tofu/secrets.sops.tfvars.json

# decrypt to stdout, e.g. to feed a consumer directly
sops -d infra/tofu/state.sops.env
```

`ansible/inventory/group_vars/k3s_node.sops.yml` (see
[`ansible/README.md`](../ansible/README.md)) holds `argocd_repo_deploy_key`
— the Argo CD read-only GitHub deploy key's private half. Same workflow as
any other SOPS file: `sops ansible/inventory/group_vars/k3s_node.sops.yml`
to edit, `sops -d ...` to decrypt to stdout. The `community.sops` vars
plugin (enabled in `ansible/ansible.cfg`) decrypts it in-memory whenever the
`k3s_node` group is in scope — never written to disk.

`infra/tofu/secrets.sops.tfvars.json` and `state.sops.env` are normally
decrypted for you by [`infra/tofu/tofu.sh`](../infra/tofu/tofu.sh) — locally
and in CI alike — so you shouldn't need to run `sops -d` on them by hand
outside of the edit workflow above.

`sops` finds the private key automatically at
`~/.config/sops/age/keys.txt`. On a new machine, set `SOPS_AGE_KEY_FILE`
to wherever you've restored it from the password manager instead.

## Backup credentials

Phase 8 added six values to
`ansible/inventory/group_vars/proxmox_host.sops.yml`. Five behave like every
other secret in this repo. **One does not, and it is the most important
thing on this page after the age key itself.**

| Value | What it is | Rotatable |
|---|---|---|
| `pbs_encryption_key` | the PBS client-side encryption key, in PBS's own JSON key format | **no — see below** |
| `pbs_s3_access_key` / `pbs_s3_secret_key` | the **bucket-scoped** Backblaze B2 application key, never the master key | yes |
| `pbs_pve_storage_password` | the password PVE authenticates to PBS with, as `pve-backup@pbs` | yes |
| `pbs_notify_telegram_bot_token` / `pbs_notify_telegram_chat_id` | the PBS-native Telegram webhook, which survives the k3s VM being down | yes |

**`pbs_encryption_key` cannot be rotated.** Backups in B2 are encrypted
client-side, so that key *is* the backups — regenerate it and every existing
snapshot becomes permanently unreadable. PBS has no re-key operation;
"rotating" it in practice means starting a new datastore and keeping the old
one until its retention runs out. It was generated once
(`proxmox-backup-client key create --kdf none`) and must never be generated
again.

It therefore lives in **two** places on purpose:

| Copy | Why it exists |
|---|---|
| Password-manager entry ("lab — PBS encryption key") | The durable copy, and the only one not protected by the age key. |
| `pbs_encryption_key` in `proxmox_host.sops.yml` | So a rebuilt host gets it from git before `/etc/pve` exists — the disaster-recovery chain in [`backups.md`](backups.md#the-disaster-recovery-chain). |

**A copy that exists only inside the SOPS file is not a second copy.** The
age key that decrypts it is in the same password manager, so losing that
manager loses both. Two separate entries, one root of trust — which is the
same trade [the keypair table](#the-keypair) already documents, restated
here because the consequence is different: a lost age key means re-encrypting
from plaintext sources, while a lost encryption key means the backups are
gone.

The four rotatable values need a **two-converge dance**, because a secret
PBS never reveals again cannot be diffed: update the value in SOPS, converge
once with `-e pbs_rotate_secrets=true`, then converge again without it. The
reasoning is in `ansible/roles/pbs/tasks/main.yml`'s header, and the
operational detail in
[`backups.md`](backups.md#secret-rotation).

**What an attacker holding the B2 key can do:** delete the backups. PBS
supports neither S3 Object Lock nor bucket versioning — enabling either can
corrupt the datastore, because garbage collection must be free to delete
chunks — so there is no vendor-side immutability standing behind this. That
is an accepted, recorded risk; what stands in for it is bucket scoping, the
local ZFS snapshot tier under different credentials, and alerting that
notices a datastore which has stopped changing within 36 hours.

## CI / Argo access

- **The PR gate** (`ci.yml`) holds no secrets and decrypts nothing. It only
  lints, renders manifests, and checks that nothing *unencrypted* slipped in
  (`gitleaks`). Keep it that way.
- **The gated Tofu apply pipeline** (`tofu-apply.yml`) runs
  [`infra/tofu/tofu.sh`](../infra/tofu/tofu.sh) — the same wrapper a local
  apply uses — with the age key supplied as the `SOPS_AGE_KEY` repository
  secret. It decrypts `state.sops.env` and `secrets.sops.tfvars.json` in
  memory, never to the runner's disk. The committed ciphertext is the single
  source of truth: there is no parallel set of per-token Actions secrets to
  keep in sync by hand any more, and no way for the two to drift.
  `PROXMOX_SSH_PRIVATE_KEY` deliberately stays its own secret — it's
  bootstrap connectivity, loaded into an `ssh-agent` *before* any decryption
  can happen. Setup: [`docs/runbooks/tofu-apply.md`](runbooks/tofu-apply.md).
- `SOPS_AGE_KEY` is **repository**-scoped, not scoped to the `production`
  Environment: the `plan` job runs unattended on every pull request with no
  `environment:` key, so an Environment-scoped secret would be invisible to
  it. The required-reviewer rule on `production` is what gates the pipeline,
  not secret visibility.
- **The Ansible gated apply workflow** (`ansible-apply.yml`) reads
  `PROXMOX_SSH_PRIVATE_KEY` (the same repo secret `tofu-apply.yml` uses, its
  trust extended to the VM as well as the host — see
  [`docs/ssh-keys.md`](ssh-keys.md)), `GH_RUNNER_PAT`, and — now that
  `ansible/inventory/group_vars/k3s_node.sops.yml` exists —
  `SOPS_AGE_KEY` the same way `tofu-apply.yml` supplies it. The
  `community.sops` vars plugin enabled in `ansible/ansible.cfg` decrypts it
  in memory at load time, whenever the `k3s_node` group is in scope.
- **Argo CD** decrypts in-cluster via the ksops Kustomize plugin, from its
  own `sops-age-key` k8s Secret — planted at bootstrap by a gated CI
  dispatch rather than from a laptop. See `docs/bootstrap.md` (Phase 4).
- **Local Ansible/Tofu applies** run from a machine (self-hosted runner or
  workstation) that has the private key locally, reachable over
  WireGuard — see [`docs/architecture.md`](architecture.md#management-plane).

### Accepted trade: CI holds the age key

This reverses the rule this repo held through Phases 1–3 ("CI holds no age
key"). Read this before touching secrets policy again.

**Before:** CI held four narrow, hand-synced secrets — `PROXMOX_API_TOKEN`,
`CLOUDFLARE_API_TOKEN`, `STATE_PASSPHRASE` (each a manually-kept-in-sync
copy of something already SOPS-encrypted in the repo) plus
`PROXMOX_SSH_PRIVATE_KEY`. A CI-secrets compromise yielded four separately
scoped things — bad, but each capped to its own scope.

**Now:** CI additionally holds one key that decrypts **every**
SOPS-encrypted file in this repo, forever, **including files that don't
exist yet**. Today that is roughly equivalent to the three retired secrets
combined (same underlying tokens, one master key instead of three scoped
ones) — but going forward, **every future SOPS secret this repo ever
encrypts becomes CI-decryptable automatically**, with no separate opt-in per
secret. That includes the Argo deploy key added in Phase 4, and later any
k8s Secret for the media stack (external-dns' Cloudflare token, Authelia
user/TOTP secrets, Sonarr/Radarr API keys) — all of which were originally
meant to be decryptable **only in-cluster via Argo/ksops**, never by CI.

So the real shift is: *"CI holds N narrowly-scoped secrets"* → *"CI holds
one universal key that silently covers every secret this repo will ever
encrypt."*

Judged acceptable because this is a single-operator **private** repo (fork
PRs get no secrets), every apply is gated behind the `production`
required-reviewer rule and runs on our own `LAB_RUNNER` inside the WireGuard
boundary rather than shared GitHub-hosted infrastructure, and the
alternative — seeding the age key
onto the runner's own disk instead of as a GitHub secret — was considered
and consciously not chosen: it keeps "GitHub holds no age key" true but
makes the runner stateful and adds moving parts for a one-person setup.
**If this repo ever gets a second operator, external contributors, or
anything genuinely sensitive beyond home-lab media credentials, revisit
this** — the more-isolated split (deploy key in CI, age key runner-local
only) is the fallback.

## Recovery

If the private key is lost but the password-manager copy survives: restore
it to `~/.config/sops/age/keys.txt` (or point `SOPS_AGE_KEY_FILE` at it)
and everything decrypts as before — no repo changes needed.

If the key is lost with no backup: rotate. Generate a new keypair, update
the recipient in `.sops.yaml`, and re-encrypt every affected file from
whatever plaintext source still exists (a password manager entry, a
teammate's checkout, etc.) — the old ciphertext in git history is
unrecoverable and should be treated as dead. There is currently only one
recipient key (single-operator repo); if that changes, add recipients as
additional `age:` entries under the relevant `key_groups` rather than
replacing the shared key.

Either way, a rotation is only finished once **every** copy in [the keypair
table](#the-keypair) carries the new key — including the `SOPS_AGE_KEY` repo
secret and the in-cluster `sops-age-key` Secret. A stale copy in CI shows up
as a decryption failure on the next `tofu plan`; a stale copy in-cluster
shows up as Argo failing to sync, which is quieter.
