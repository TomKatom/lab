# Secrets

One age keypair covers everything encrypted in this repo: Kubernetes
Secrets (via [ksops](https://github.com/viaduct-ai/kustomize-sops)),
OpenTofu tfvars, and Ansible group/host vars. Rules live in
[`.sops.yaml`](../.sops.yaml).

## The keypair

- **Public key** (committed, safe to share): see `.sops.yaml`.
- **Private key**: generated locally, held **out-of-band** — never
  committed. It currently lives at `~/.config/sops/age/keys.txt` on the
  machine that generated it (SOPS' and age's default lookup path, so no
  `SOPS_AGE_KEY_FILE` env var is needed locally).

Before this goes further than a laptop, copy the private key into a
password manager entry (e.g. "lab — age SOPS key") and treat that as the
durable copy. Losing it means every `.sops.yaml`-matched file in this repo
becomes permanently unreadable — there is no recovery path except
generating a new key and re-encrypting everything from plaintext sources
you kept elsewhere.

## What gets encrypted

`.sops.yaml` creation rules, by path:

| Path pattern | What | Encrypted fields |
|---|---|---|
| `clusters/**/*.sops.yaml` | k8s Secrets, decrypted in-cluster by ksops | only `data`/`stringData` — metadata stays plaintext so kustomize/Argo can diff |
| `infra/tofu/**/*.sops.tfvars` | Proxmox + Cloudflare API tokens | whole file |
| `ansible/**/*.sops.yml` | group/host vars secrets | whole file |

Anything matching one of these patterns must be encrypted before it's
committed — `gitleaks` in CI is the backstop, not the primary control.

## Local workflow

```sh
# encrypt a new file in place (uses .sops.yaml rules by path)
sops -e -i infra/tofu/secrets.sops.tfvars

# edit an existing encrypted file (decrypts to $EDITOR, re-encrypts on save)
sops ansible/group_vars/all.sops.yml

# decrypt to stdout, e.g. to feed `tofu` or `ansible-playbook`
sops -d infra/tofu/secrets.sops.tfvars
```

`sops` finds the private key automatically at
`~/.config/sops/age/keys.txt`. On a new machine, set `SOPS_AGE_KEY_FILE`
to wherever you've restored it from the password manager instead.

## CI / Argo access

- **CI** (GitHub Actions) never decrypts anything — it only checks that
  nothing *unencrypted* slipped in (`gitleaks`). No private key is stored
  as a repo secret.
- **Argo CD** decrypts in-cluster via the ksops Kustomize plugin. The
  private key is installed once at cluster bootstrap as a k8s Secret
  (`sops-age-key`) — see `docs/bootstrap.md` (Phase 4) for the exact
  procedure.
- **Ansible/Tofu applies** run from a machine (self-hosted runner or
  workstation) that has the private key locally, reachable over
  WireGuard — see [`docs/architecture.md`](architecture.md#management-plane).

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
