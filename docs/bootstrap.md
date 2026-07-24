# Runbook: Argo CD bootstrap (Phase 4)

How to stand up Argo CD on the k3s cluster and hand the repo the keys to
itself — the one-time step that turns `clusters/**` into a pull-based,
GitOps-reconciled source of truth. After this, merging to `master` *is* the
deploy for everything under `clusters/`; you never dispatch a delivery
playbook again.

See [`docs/architecture.md`](architecture.md) for the Layer 3 design and
[`master-plan.md`](../master-plan.md) for the frozen decision record. This
runbook is Stage E of [`provision-new-server.md`](runbooks/provision-new-server.md#7-stage-e--argo-cd-bootstrap);
that runbook stays the authoritative *pointer*, this file owns the
step-by-step.

There is no IPMI/console on this server, but this stage touches **no
firewall/NAT/SSH rule** — the k8s API stays WireGuard/internal-only
throughout, so unlike the Tofu applies there is no lockout risk here. The
Argo UI is reached over WireGuard via `kubectl port-forward`, not a public
ingress (none exists until Phase 5's Traefik).

## What this does, in one picture

A single gated CI dispatch (`ansible-apply.yml` → `argocd-bootstrap`) runs
the `argocd-bootstrap.yml` playbook on `k3s-node`, which runs two roles in
order:

```
argocd_secrets   → ensure argocd namespace
                 → create sops-age-key Secret        (age key from SOPS_AGE_KEY)
                 → create repo-lab repository Secret  (deploy key from SOPS)
argocd           → assert both Secrets exist (fails loudly if not)
                 → install pinned helm binary
                 → helm upgrade --install argo-cd (ksops repo-server patch) --wait
                 → kubectl apply root-app.yaml
                 → read-back: repo-server rolled out, root-app present
```

Then, pull-based and hands-off:

```
root-app  reconciles clusters/lab/platform/ (recurse)
          └─ argo-cd.yaml (self-manage Application) → Argo ADOPTS the release
             it was just helm-installed from, from the same argocd-values.yaml
```

The two in-cluster Secrets are the **trust root**: `sops-age-key` lets the
ksops-patched repo-server decrypt `clusters/**/*.sops.yaml` in-cluster; the
`repo-lab` repository Secret lets it git-clone this private repo over SSH.
Both are planted by the gated CI run — **no operator laptop step at
bootstrap, ever** (the deliberate posture documented in
[`docs/secrets.md`](secrets.md)).

## Prerequisites

Everything Stage A–D of [`provision-new-server.md`](runbooks/provision-new-server.md)
established must already hold — in particular:

- **k3s is up** (`k3s-vm.yml` ran): the node has `/etc/rancher/k3s/k3s.yaml`
  and `k3s kubectl` works locally. The playbook runs *on* `k3s-node` and uses
  that kubeconfig implicitly — no WireGuard hop, no kubeconfig rewrite.
- **The automation SSH key is enrolled on `k3s-node`** (`hardening-vms.yml`)
  so the gated runner can reach it.
- **`SOPS_AGE_KEY` is set** as a repository secret (the full contents of
  `~/.config/sops/age/keys.txt`, comment lines and all). Already required by
  every other CI job since Phase 2 — see
  [`provision-new-server.md` §1.2](runbooks/provision-new-server.md#12-github-repo-state-order-matters).

### The one manual GitHub step: the Argo deploy key

`github.com/TomKatom/lab` is private, so Argo's repo-server needs a
credential to pull it. We use a **read-only GitHub deploy key**, not a PAT.
The private half is already SOPS-encrypted in the repo
(`ansible/inventory/group_vars/k3s_node.sops.yml`, var
`argocd_repo_deploy_key`); the `argocd_secrets` role decrypts it in CI and
injects it as the `repo-lab` repository Secret. GitHub only needs the
**public** half, added once:

1. Repo → **Settings → Deploy keys → Add deploy key**.
2. Title: `argocd-readonly` (or similar). Key: the public half — its exact
   string is in PR [#38](https://github.com/TomKatom/lab/pull/38)'s
   description (`ssh-ed25519 … argocd-readonly@lab`).
3. **Leave "Allow write access" unchecked.** Argo only reads.

> Rotating the key later means: generate a fresh `ed25519` pair off-server,
> `sops -e -i` the private half into `k3s_node.sops.yml`, replace the public
> half here, and re-dispatch the bootstrap (the `repo-lab` Secret is
> existence-checked, so delete it in-cluster first if you want it recreated —
> see [Re-dispatch](#re-dispatching-a-failed-or-partial-bootstrap)).

## Run it — the one-time dispatch

**Run this exactly once, at the end of provisioning.**

1. **Actions → Ansible Apply → Run workflow.** Set **playbook =
   `argocd-bootstrap`**. Run.
2. **Approve the gated run.** The `production` environment's required-reviewer
   rule pauses the `apply` job until you approve it — the same gate every
   other apply uses. It runs only on the self-hosted `LAB_RUNNER`.
3. Watch the job summary. On success you'll see, in order: the two Secrets
   created (or already-present on a re-run), `helm upgrade --install argo-cd
   … --wait` returning after the release comes up healthy (~40s on this box),
   `root-app.yaml` applied, and both read-back asserts passing
   (`argo-cd-argocd-repo-server rolled out successfully`, `root-app
   Application is present and reconciling`).

That's the whole live step. Delivery is pull-based from here.

> **Why `argocd-bootstrap` is a `workflow_dispatch` and not in `site.yml`.**
> The push-to-`master` auto-converge runs `site.yml`. Once the self-manage
> `Application` (`argo-cd.yaml`) is reconciling, replaying the bootstrap's
> `helm upgrade --install` + `kubectl apply root-app.yaml` on every merge
> would **fight Argo for ownership of the same release** — the exact
> dual-installer conflict the self-management design exists to avoid. So the
> bootstrap deliberately stays out of `site.yml` (its header documents this)
> and lives only as an operator-picked dispatch. You do **not** re-run it as
> maintenance.

## Verify

Over WireGuard, from an operator peer (or read the run's own read-back
asserts, which cover the first two):

```sh
# Everything Running, repo-server included
kubectl -n argocd get pods

# Both Applications Synced + Healthy
kubectl -n argocd get applications
#   root-app   Synced   Healthy
#   argo-cd    Synced   Healthy   <- self-management adopted the release

# ksops toolchain actually landed in the repo-server via the init container
kubectl -n argocd exec deploy/argo-cd-argocd-repo-server -- \
  sh -c 'ls -l /usr/local/bin/ksops /usr/local/bin/kustomize && echo "$SOPS_AGE_KEY_FILE"'
```

The repo-server Deployment is **`argo-cd-argocd-repo-server`**, not
`argo-cd-repo-server`: the release is named `argo-cd`, and the chart's
`fullname` helper only collapses `<release>-<nameOverride>` to the bare
release name when the release name *contains* the `nameOverride` (`argocd`).
`argo-cd` does not contain `argocd` (the hyphen differs), so the name
doubles. (Cosmetic naming debt, consciously kept — renaming the live release
would mean a `helm uninstall`/reinstall dance for zero functional gain.)

**Self-adoption drift is expected, once.** On the first self-manage sync
Argo takes ownership of the helm-installed objects; a transient
label/annotation diff is normal and resolves itself via `selfHeal` +
`ServerSideApply=true`. If instead the repo-server Deployment ends up
*perpetually* `OutOfSync` (Argo ping-ponging one field), add an
`ignoreDifferences` for that field to `argo-cd.yaml` — do **not** just
disable `selfHeal` to hide the symptom.

### ksops smoke test (optional, proves the repo-server patch end-to-end)

The asserts above prove Argo is up and self-managing; they do **not** prove
ksops can actually decrypt. To confirm the repo-server patch works
end-to-end, apply a *throwaway* `clusters/**/*.sops.yaml` Secret via a
scratch Application (or `argocd app create` against a branch) and confirm it
materializes decrypted in-cluster — **do not merge it to `platform/`.** Full
"an app consumes an `existingSecret`" verification is Phase 5's job, not this
phase's.

> **Forward-flagged for Phase 5:** once real ksops-encrypted overlays live
> under `clusters/`, `ci.yml`'s `render-manifests` `kustomize build` will
> need `--enable-alpha-plugins --enable-exec` and still can't decrypt in CI
> (ksops-as-kustomize-plugin must be installed in the runner image; CI
> holding the age key doesn't help). Not a Phase 4 blocker — no such overlays
> exist yet.

## Re-dispatching a failed or partial bootstrap

**Re-dispatch is safe — but only for a failed or interrupted first run.**
Every stateful task uses the existence-check idiom (read state → act only if
needed → read-back assert), so a second `argocd-bootstrap` dispatch finishes
what an interrupted run left undone without duplicating anything:
already-present Secrets/namespace are no-ops, `helm upgrade --install` is
create-or-update, `kubectl apply` is idempotent. A clean re-run reports
`failed=0` with only the genuinely-missing pieces `changed`.

That is the *only* reason to run it twice. **Not** to reconcile drift (Argo
does that continuously) and **not** to bump the chart version (see below).

If a run failed *before* a Secret was created and you need it regenerated
(e.g. after rotating the deploy key), delete the stale Secret in-cluster
first so the existence-check re-creates it:

```sh
kubectl -n argocd delete secret repo-lab        # or sops-age-key
```

## Upgrading Argo CD after bootstrap (chart version)

The argo-cd chart version is pinned in **two** places that must stay in
lockstep:

- `ansible/roles/argocd/defaults/main.yml` → `argocd_chart_version` (what the
  bootstrap `helm install` uses), and
- `clusters/lab/platform/argo-cd.yaml` → `sources[0].targetRevision` (what
  self-management reconciles to).

Both carry Renovate annotations resolving to
`depName=argo-cd`/`datasource=helm`, and `renovate.json`'s `"helm charts"`
`packageRule` groups them, so a version bump lands as **one** PR touching
both literals — no hand-sync drift. When that PR merges, Argo's self-managed
sync rolls the upgrade out on its own. **You never re-dispatch
`argocd-bootstrap` to upgrade** — that path is bootstrap-only.

> This is a "two pins, Renovate-grouped" arrangement, not the original
> single-pin/derive-from-manifest design — that didn't survive the actual PR
> order (the role was authored before the self-manage manifest existed, so
> there was nothing to grep). If a future change ever reintroduces a third
> copy of the version, it **must** join the same Renovate group.

## What this stage does *not* touch (confirm it stays true)

Phase 4 changes no host firewall, NAT, or SSH rule — no diff to
`infra/tofu/firewall.tf` or `ansible/roles/network_nat/` anywhere in it. The
k8s API is never exposed publicly. Any future change to this bootstrap that
starts touching network-adjacent config invalidates the "no lockout risk /
no dead-man switch needed" assumption above — re-evaluate it if that
happens.
