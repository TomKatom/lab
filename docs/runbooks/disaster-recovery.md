# Runbook: disaster recovery

Bare metal to running, when the server is gone: a dead machine, a reseller
reinstall, a pool that will not import. For anything smaller — one file, one
PVC, one bad `apt upgrade` — use [`restore.md`](restore.md) instead; this
document assumes there is nothing left to log into.

It leans on [`provision-new-server.md`](provision-new-server.md) for the
build itself and only adds what that runbook cannot know: how to get the
backups back. Read both before starting. What is in the backups and why is
[`docs/backups.md`](../backups.md).

**There is no IPMI and no console on this server.** Every step below is
written around that, and [`lockout-recovery.md`](lockout-recovery.md) is the
escape hatch if the network configuration goes wrong on the way.

---

## 0. What you must be able to reach

Two things, both deliberately off the server:

| What | Holds | Without it |
|---|---|---|
| **The password manager** | the age SOPS private key, the PBS encryption key, the B2 application key, the OVH/GitHub/Cloudflare logins | nothing below is possible |
| **GitHub** | this repo — every manifest, every encrypted secret, the Tofu state | you have backups you cannot address |

Everything else is derived. The chain looks circular the first time you read
it and is not:

```
password manager (age key)
  └─> GitHub (this repo, cloned anywhere)
        └─> SOPS decrypts ansible/inventory/group_vars/proxmox_host.sops.yml
              ├─> B2 application key      ──┐
              └─> PBS encryption key      ──┴─> reattach the `lab` datastore
                                                  └─> restore host files, then the VM
                                                        └─> Argo reconciles the rest
```

The age key is the single root of trust, exactly as
[`secrets.md`](../secrets.md) says. **The PBS encryption key is stored twice
on purpose** — in the password manager and, encrypted, in the repo — because
a copy that exists only inside the SOPS file is protected by the same age
key as everything else. Two entries, one root.

### Before you touch anything

- **Confirm the B2 bucket is intact and still has Object Lock and versioning
  off.** Turning either on — including "just to be safe" during a recovery —
  can corrupt the datastore, because PBS's garbage collection has to be free
  to delete chunks.
- **Do not create a new bucket or a new encryption key.** Both are
  one-way: a new key makes every existing snapshot unreadable, and there is
  no re-key operation in PBS.
- **Note the datastore name: `lab`.** It is part of the contract, not a
  label. Reattaching requires creating a datastore with the same name or the
  S3 object prefix will not line up with what is already in the bucket.

---

## 1. Get a machine and a Proxmox install

Per [`provision-new-server.md`](provision-new-server.md) §1–§2 and its
[rebuild appendix](provision-new-server.md#appendix-rebuilding-a-replacement-server):
OVH reinstall to a clean Proxmox, root SSH key authorized out of band, then
the per-server values (public IP, disk identities) into the repo via a PR.

**`rebuild-facts.pxar` in the host backup is what makes this mechanical
rather than archaeological** — it holds `ls -l /dev/disk/by-id/`, `lsblk`
with serials and WWNs, `zpool status -v`, `zfs get all` and the dpkg package
list from the last night the old machine ran. You cannot read it yet, which
is the chicken-and-egg this section resolves: you need *a* machine with the
PBS client on it before you can read the notes describing the machine.

If the disks survived (a reinstall rather than a hardware loss), `rpool` may
still import and this whole runbook collapses into "boot it and converge".
Check `zpool import` before assuming the worst.

---

## 2. Restore the PBS client, early

You do not need the full converge to read the backups. On the fresh host:

```sh
apt update && apt install -y proxmox-backup-client
```

Then, from your laptop, decrypt the two values you need and get them onto
the host **without writing them into a shell history**:

```sh
sops -d ansible/inventory/group_vars/proxmox_host.sops.yml | grep -A1 pbs_encryption_key
```

Write the encryption key JSON to `/etc/proxmox-backup/lab-encryption-key.json`
on the host (mode `0600`), and set the B2 credentials in the environment for
the direct-to-S3 read below.

At this point you can read `rebuild-facts.pxar` — the disk identities, the
pool layout and the package list from the old machine — and lay out `rpool`
to match. See [`restore.md`](restore.md#restore-a-file-from-the-hypervisor)
for the client syntax. **This is the step most likely to be skipped and most
likely to be regretted**: rebuilding the pool from memory and finding out
later that a dataset name or a property differed is how a recovery turns
into a second recovery.

---

## 3. Bring the host up through the normal pipeline

Stages A–D of [`provision-new-server.md`](provision-new-server.md), unchanged:
host converge, PVE role/user/token, first `tofu apply` (bridge, VMs,
firewall), guests and the runner, WireGuard verify, then the
`restrict_management` flip.

Two things specific to a recovery:

- **Restore `/etc/wireguard/wg0.key` from `etc.pxar` *before* the WireGuard
  role runs**, if you want the existing peers to keep working.
  `roles/wireguard` generates a host key in place when there is none, and a
  new key invalidates **every** peer configuration — including the one on
  the laptop you are recovering from. Recoverable (public SSH is still open
  at this stage, since `restrict_management` starts `false`), but it turns
  one step into three.
- **Do not restore `/etc` wholesale onto the new install.** Almost
  everything in it is reconciled from this repo, and a bulk overwrite would
  bury the fresh install's own identity — network interface names, disk
  UUIDs, the certificate the new PVE generated — under the old machine's.
  Restore individual files, deliberately.

---

## 4. Reattach the datastore — the one step with no automation

`ansible/roles/pbs` builds a datastore. It does not **reattach** one, and
the difference matters: `proxmox-backup-manager datastore create` without
`--reuse-datastore` against a bucket that already holds a datastore is not
the operation you want.

So the converge does most of the work and you do one command in the middle
of it:

**4.1 Let `site.yml` run.** `roles/pbs` installs the packages, creates the
`rpool/pbs-cache` dataset with its quota, and configures the S3 endpoint —
all of which come *before* the datastore in `tasks/datastore.yml`. Expect it
to stop at **"Create the S3-backed datastore"**.

**4.2 Create the datastore by hand, with the reuse flags:**

```sh
proxmox-backup-manager datastore create lab /mnt/pbs-cache \
  --backend type=s3,client=backblaze-b2,bucket=<the bucket> \
  --reuse-datastore true \
  --overwrite-in-use true \
  --gc-schedule 'sat 02:00' \
  --notification-mode notification-system
```

- **`--reuse-datastore`** tells PBS the bucket already contains a datastore
  layout and to adopt it rather than initialise over it.
- **`--overwrite-in-use`** claims the `.inuse` marker the old server left
  behind. It is safe here **only because the old server is gone**; two live
  PBS instances writing the same S3 datastore will corrupt it.
- The name (`lab`), the cache path and the endpoint id (`backblaze-b2`) must
  match `roles/pbs`' defaults exactly, or the next converge will try to
  create a second one.

**4.3 Re-run the converge.** From here the role's reconcile path takes over:
it finds the datastore, reconciles the GC schedule, creates the prune and
verify jobs, creates the `pve-backup@pbs` user and its ACL, registers the
PVE storage entry with the encryption key, and enables the host-backup and
metrics timers. `pvesm status` reporting the storage **active** is the
assert that exercises TLS, fingerprint, credential, ACL and the S3 backend
together — if it passes, the datastore is genuinely back.

> **Known gap, not a mystery.** This manual step exists because the role has
> no "reuse" knob. Adding `pbs_datastore_reuse` / `pbs_datastore_overwrite_in_use`
> as defaults-driven flags would remove it, and is the obvious follow-up —
> it was left out of the docs PR that wrote this runbook rather than shipped
> untested. **The failure in 4.1 has never actually been exercised**; if the
> converge instead sails through and creates the datastore cleanly, stop and
> check `proxmox-backup-client snapshot list` before trusting it, because a
> datastore that initialised over the old prefix is an empty one.

---

## 5. Restore the k3s VM

With the datastore attached, the nightly snapshots are ordinary PVE volumes
again:

```sh
pvesm list pbs
qmrestore pbs:backup/vm/9000/<timestamp> 9000 --storage local-zfs
```

Full detail, including why `--live-restore` is usually the wrong call:
[`restore.md`](restore.md#restore-the-whole-k3s-vm).

Three things about the restored VM:

- **`scsi2` does not come back**, because it was never backed up. Recreate
  it with `tofu apply` (it is declared in `infra/tofu/vm-k3s.tf`), let
  `roles/k3s` format and mount it, and let Argo recreate the monitoring PVCs
  on it. Those hold telemetry, which is reproducible — that is the entire
  reason they live there.
- **This is ~35 GiB of chunks coming back over the internet from B2.** Not
  fast, and this is the one moment in the year the free-egress allowance
  matters. Budget on the order of an hour, not minutes.
- **Check `qm config 9000` before starting it.** The config comes from
  inside the snapshot and describes the VM as it was that night.

---

## 6. Let Argo take over

Once `k3s-node` is up and the cluster answers:

```sh
kubectl get nodes
kubectl -n argocd get applications
```

Everything in `clusters/` reconciles from git on its own — the platform
layer, the media stack, the monitoring stack. The restored PVCs carry the
state that git cannot: Plex's metadata and identity, the \*arr databases,
Deluge's session and its ~600 torrents, Authelia's TOTP/WebAuthn
registrations.

If a bootstrap-only object is missing (the `sops-age-key` Secret in the
`argocd` namespace, for instance), that is [`bootstrap.md`](../bootstrap.md)
Phase 4, not a restore.

---

## 7. Prove it, then close the loop

In this order, because each one makes the next meaningful:

1. `proxmox-backup-client snapshot list` — both groups present, sizes
   plausible, `crypt-mode` reading `encrypt`.
2. `pvesm status` — `pbs` **active**.
3. `systemctl list-timers lab-host-backup.timer lab-backup-metrics.timer
   sanoid.timer` — all three scheduled.
4. `./scripts/promql.sh --alerts` — the backup alert group is quiet, or
   firing only for reasons you can name.
5. **A real backup runs that night**, and `BackupStale` does not fire 36
   hours later.
6. **Touch the drill marker** — you have just performed the most complete
   restore this repo has a procedure for:
   `touch /var/lib/lab-backup-metrics/last-restore-drill`.

Then update `docs/backups.md` and this runbook with anything that turned out
to be wrong. A DR runbook that has been executed once and not corrected
afterwards is worth less than it looks.

---

## What is not recovered

Say these out loud before declaring the recovery finished:

| Not recovered | Consequence |
|---|---|
| Everything on `tank` — ~3.6 TB of media and torrents | Re-acquire through the \*arrs. The libraries' *metadata* survives in the VM backup, so Plex and the \*arrs come back knowing what they had; the files themselves do not. |
| Seeding history and tracker ratio | Deluge's session state restores, but the data it points at does not exist until the media is back. Expect a large batch of errored torrents; recheck rather than re-add, once `tank` is repopulated. |
| Prometheus, Loki and Alertmanager history | Deliberate. Reproducible telemetry, excluded by disk. Dashboards and alert rules come from git and are fine; the graphs start empty. |
| The `ci-runner` VM (9001) | Deliberately stateless. Recreated by Tofu, re-registers from `GH_RUNNER_PAT`. |
| Anything written to the host between the last 03:30 backup and the loss | Up to 24 h of host configuration. In practice this is near-zero, because host configuration comes from this repo. |
| Anything written inside the VM after the last 04:00 backup | Up to 24 h of \*arr/Plex/Deluge state. This is the real data loss window. |
