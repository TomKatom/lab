# SSH keys

Two independent key classes touch this repo's infrastructure. Conflating
them — one key used both by a human and by CI — is the mistake this
document exists to avoid: it couples access to a single machine, makes
revocation ambiguous (rotating it locks out both the pipeline and you), and
blurs "the pipeline did this" from "I did this" in any audit trail.

| | Automation key (`ci-tofu-apply`) | Personal admin key(s) |
|---|---|---|
| Purpose | `bpg`'s SSH-based image download/import (`ssh { agent = true }` in `providers.tf`), and Ansible's SSH transport for CI-driven applies (`ansible-apply.yml`) — no other use | Interactive login for you, to troubleshoot/administer |
| Used by | GitHub Actions (`tofu-apply.yml`, `ansible-apply.yml`) and, for host-sensitive local applies, you | You, from whichever machine you're on |
| Lives in git? | No — never in `~/.ssh` used for anything else, never committed | Public half only, via `admin_ssh_public_keys` in [`config/lab.yml`](../config/lab.yml) |
| Durable custody | GitHub Actions secret `PROXMOX_SSH_PRIVATE_KEY` + a password-manager backup entry | Password-manager or hardware-token-backed SSH agent — not a bare file on one laptop |
| Host (`root@proxmox`) trust | `authorized_keys`, bootstrapped by hand (see [Current gap](#current-gap-the-host)) | Same, same gap |
| VM (`debian@k3s-node`) trust | Yes — CI-driven Ansible applies (`ansible-apply.yml`) need to reach the VM, not just the host. Declared the same way personal keys are, via `admin_ssh_public_keys`; seeded into a fresh build by cloud-init (`infra/tofu/vm-k3s.tf`) and reconciled onto the running VM by the `hardening` role (`ansible/roles/hardening`) | `admin_ssh_public_keys` → cloud-init (`infra/tofu/vm-k3s.tf`) + `hardening` role — fully GitOps'd |

## Why the split

A CI/automation credential and a personal login credential are different
trust domains even when, today, the same person controls both. Keeping
them separate means:

- Rotating or revoking one never locks you out via the other.
- The automation key can be scoped down further later (e.g. a
  restricted user, `command=` forcing) without touching how you log in.
- "The pipeline ran this" and "I ran this" stay distinguishable.

## Personal admin key: recommended custody

Don't keep the only copy of your interactive key as a plaintext file on one
laptop — that's the "couples me to this machine" problem. Back it with a
password manager's SSH agent (1Password, Bitwarden) or a hardware token
(YubiKey/FIDO2, `ed25519-sk`). Either way the private key material never
exists as a copyable file, and the same identity works from any machine
where the agent/token is available — no new key needed per device.

```sh
# One-time: generate, then immediately import into your password manager's
# vault and delete the plaintext copy. Example with 1Password:
ssh-keygen -t ed25519 -C "tom-admin" -f /tmp/tom_admin
# 1Password: New Item > SSH Key > paste the private key in, save.
shred -u /tmp/tom_admin /tmp/tom_admin.pub  # or securely delete via your OS

# Enable 1Password's SSH agent (Settings > Developer > "Use the SSH agent"),
# then point ssh at its socket in ~/.ssh/config:
#   Host *
#     IdentityAgent "~/.1password/agent.sock"   # Linux
# From then on `ssh root@<host>` just works, on any machine signed into
# that 1Password account — nothing to copy anywhere.
```

Add the resulting public key to `admin_ssh_public_keys` in
[`config/lab.yml`](../config/lab.yml) once (already done for the current
`katom@TOM-PC` key — replace it with your agent-backed key when you migrate,
rather than adding a second entry per device).

## Automation key: scoped local use

The automation key is for CI, and for you *only* when a runbook explicitly
calls for a local apply (host-sensitive applies — see
[`docs/runbooks/tofu-apply.md`](runbooks/tofu-apply.md) — are deliberately
manual, never CI). Don't load it into your default, always-on `ssh-agent`;
spin up a throwaway one for the run:

```sh
# Pull the private key from wherever its durable copy lives (password
# manager) straight into an ephemeral agent — it never touches disk.
# Example with the 1Password CLI:
eval "$(ssh-agent -s)"
op read "op://Private/ci-tofu-apply/private key" | ssh-add -
./tofu.sh apply
ssh-agent -k   # tear the scoped agent down when you're done
```

This is also why Claude Code (or any assistant session) can't run
`tofu plan`/`apply` here: it has no access to your password manager or
agent, and by design shouldn't — those commands are meant to be run by you,
deliberately, per the runbook.

## Adding access from a new machine

**VM (`k3s-node`)** — already fully GitOps'd: add the public key to
`admin_ssh_public_keys` in `config/lab.yml`, PR, merge, then apply the
`hardening` role (`playbooks/hardening-vms.yml`) — it reconciles the running
VM's `authorized_keys` to match (cloud-init only seeds keys into a fresh
build). No server ever touched by hand.

**Proxmox host** — today, still manual (see [Current gap](#current-gap-the-host)
below): SSH in with an already-trusted key and append the new public key to
`/root/.ssh/authorized_keys` yourself. If you've migrated to an
agent-or-token-backed personal key as described above, you typically won't
need to do this per-machine at all — the same identity is already available
everywhere the agent is.

## Current gap: the host

Proxmox host bootstrap happened outside IaC (see `CLAUDE.md`'s "Prior
Setup"), so `root@proxmox`'s `authorized_keys` is still hand-maintained —
the one place key trust isn't declarative yet. This closes when the
`hardening` role lands in `ansible/` (Phase 3, see `master-plan.md` and
[`docs/architecture.md`](architecture.md#management-plane)): it should
manage `authorized_keys` from the same `admin_ssh_public_keys` list in
`config/lab.yml`, the same way `vm-k3s.tf` already does. That phase is also
where the host moves to SSH-key-only, non-root, WireGuard-gated access —
see [Management plane](architecture.md#management-plane) — at which point
public SSH to the host goes away entirely and this file's "adding a new
machine" story for the host becomes: add the key to `config/lab.yml`, get
on WireGuard, `ssh`.

## VM key trust: cloud-init seeds, the hardening role reconciles

The VM's key trust is fully declarative from `admin_ssh_public_keys`, but by
two complementary mechanisms — because declarative doesn't mean retroactive.
Cloud-init (`infra/tofu/vm-k3s.tf`) only reads `user_account.keys` on a VM's
**first boot**, so it seeds keys into a *fresh* build but never touches an
already-running VM. The `hardening` role (`ansible/roles/hardening`, applied
via `playbooks/hardening-vms.yml`) closes that window: it reconciles the
running VM's `authorized_keys` to exactly `admin_ssh_public_keys`
(`exclusive: true`), every run, idempotently — the same way it manages the
host.

This is what authorizes the automation key on `k3s-node`: that VM was built
in Phase 2, before the automation key was added to `admin_ssh_public_keys`,
so cloud-init never seeded it. Enrolling `k3s_node` in the `vm_guests`
inventory group hands its `authorized_keys` to the hardening role, which
installs the key on the next apply.

> First enrollment is the one place this needs an operator, not CI. CI
> authenticates with the automation key — the very key not yet on the VM —
> so it can't perform the run that installs it (chicken-and-egg). Break it
> once: an operator runs `playbooks/hardening-vms.yml --limit k3s-node` over
> WireGuard with their **personal** key loaded (which the VM already trusts
> from its Phase 2 build). The role's `authorized_keys` task runs first and
> keeps the personal key (it's in the list), while adding the automation
> key. Every apply after that — including CI — is ordinary and idempotent.

## Rotation / compromise

- **Automation key compromised or rotating:** generate a new keypair,
  update `PROXMOX_SSH_PRIVATE_KEY` in GitHub Actions secrets and the
  password-manager backup, swap the public half in `admin_ssh_public_keys`,
  then apply the `hardening` role — its exclusive `authorized_keys`
  management adds the new key and prunes the old one across the host and
  every enrolled guest in one pass. Doesn't touch your personal access.
- **Personal key compromised or rotating:** remove it from
  `admin_ssh_public_keys` in `config/lab.yml`, add the replacement, PR +
  apply (VM); remove/append the host's `authorized_keys` by hand until the
  Phase 3 role exists. Doesn't touch CI.
