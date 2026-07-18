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

No `ansible/**/*.sops.yml` file exists today — no Phase 3 role has needed a
real secret yet (see [`ansible/README.md`](../ansible/README.md)) — but the
pattern above applies identically once one does: `sops
ansible/group_vars/all.sops.yml` to edit, `sops -d ...` to decrypt to
stdout. The `community.sops` vars plugin (enabled in `ansible/ansible.cfg`)
picks up any matching file automatically the moment it exists.

`infra/tofu/secrets.sops.tfvars.json` and `state.sops.env` are normally
decrypted for you by [`infra/tofu/tofu.sh`](../infra/tofu/tofu.sh) — you
shouldn't need to run `sops -d` on them by hand outside of the edit
workflow above.

`sops` finds the private key automatically at
`~/.config/sops/age/keys.txt`. On a new machine, set `SOPS_AGE_KEY_FILE`
to wherever you've restored it from the password manager instead.

## CI / Argo access

- **The PR-gate workflow** (`ci.yml`) never decrypts anything — it only
  checks that nothing *unencrypted* slipped in (`gitleaks`). No private key
  is stored as a repo secret; SOPS/age never enter CI.
- **The gated apply workflow** (`tofu-apply.yml`) *also* never touches SOPS
  or the age key — it's a separate mechanism entirely. It reads
  `PROXMOX_API_TOKEN` / `CLOUDFLARE_API_TOKEN` / `STATE_PASSPHRASE` /
  `PROXMOX_SSH_PRIVATE_KEY` from **repository**-level GitHub Actions
  secrets (set once, by hand, in repo settings — see
  [`docs/runbooks/tofu-apply.md`](runbooks/tofu-apply.md)). They're
  repo-scoped rather than scoped to the `production` Environment because
  the `plan` job — which runs unattended on every pull request — needs
  them too;
  the Environment's required-reviewer rule is what gates the pipeline, not
  secret visibility. Keeping these in
  sync with the SOPS-encrypted local copies (`secrets.sops.tfvars.json`,
  `state.sops.env`) is a manual step when either changes; they're
  intentionally two independent secret stores, not one synced from the
  other, so a compromised GitHub Actions secret can't also unlock the age
  keypair.
- **The Ansible gated apply workflow** (`ansible-apply.yml`) follows the
  same principle: it reads only `PROXMOX_SSH_PRIVATE_KEY` (the same repo
  secret `tofu-apply.yml` uses, its trust extended to the VM as well as the
  host — see [`docs/ssh-keys.md`](ssh-keys.md)) and touches no SOPS/age
  material at all. That's easy to hold today because no Ansible role
  currently needs a secret — `ansible/group_vars/` holds only plain vars,
  and the `community.sops` vars plugin (enabled in `ansible/ansible.cfg`)
  has nothing to decrypt because no `*.sops.yml` file exists there yet. If
  a future role needs one, CI would need a way to decrypt it without ever
  holding the age key outright — same unsolved shape as "CI holds no age
  key" above — a problem worth solving when it's real, not preemptively.
- **Argo CD** decrypts in-cluster via the ksops Kustomize plugin. The
  private key is installed once at cluster bootstrap as a k8s Secret
  (`sops-age-key`) — see `docs/bootstrap.md` (Phase 4) for the exact
  procedure.
- **Local Ansible/Tofu applies** run from a machine (self-hosted runner or
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
