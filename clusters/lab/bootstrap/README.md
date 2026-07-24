# bootstrap

- `argocd-values.yaml` — Helm values for the argo-helm `argo-cd` chart: the
  ksops repo-server patch (init container installs the `ksops`/`kustomize`
  binaries, mounts the `sops-age-key` Secret, sets `SOPS_AGE_KEY_FILE`, and
  enables `--enable-alpha-plugins --enable-exec` in `kustomize.buildOptions`)
  plus single-node sizing (one replica per controller, no `redis-ha`
  subchart). Applied both by the one-time bootstrap install and by Argo's
  own self-management of the chart afterward
  (`clusters/lab/platform/argo-cd.yaml`) — one file, no drift.
- `root-app.yaml` — the app-of-apps entrypoint: an Argo `Application` that
  recursively syncs everything under `clusters/lab/platform/`.

These manifests are static — applying them live (`helm upgrade --install` +
`kubectl apply -f root-app.yaml`) is the Ansible `argocd` role's job, run
once via the gated `argocd-bootstrap` dispatch. The two Secrets the values
above depend on (`sops-age-key` and the `repo-lab` Argo repository
credential) are planted in the same run by the `argocd_secrets` role. The
full step-by-step — deploy-key prerequisite, dispatch, verification, and
re-dispatch/upgrade caveats — lives in
[`docs/bootstrap.md`](../../../docs/bootstrap.md).
