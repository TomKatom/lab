# Backups

What survives losing this server, where each copy lives, and what is
deliberately not protected at all. The roles and manifests named here carry
their own "why" headers; this document is the map between them, plus the
reasoning that lives in no single file.

Scope: the k3s VM, the Proxmox host's own configuration, and the local
rollback tier. Restoring any of it is
[`runbooks/restore.md`](runbooks/restore.md); rebuilding the whole machine
from nothing is
[`runbooks/disaster-recovery.md`](runbooks/disaster-recovery.md).

**Snapshots are not backups.** The ZFS tier below lives on the pool it
protects and does not survive losing it. It is the rollback tier and
nothing else — the actual backup is the copy in Backblaze B2.

## The three tiers

| Tier | What it protects against | Where it lives | Built by |
|---|---|---|---|
| **ZFS snapshots** | a bad `apt upgrade`, a wrong `/etc` edit, an hour of regret | `rpool`, the same NVMe mirror as the thing it copies | [`ansible/roles/zfs_snapshots`](../ansible/roles/zfs_snapshots) (sanoid) |
| **VM image backup** | losing the k3s VM, the host, or the pool | Backblaze B2, via PBS | [`infra/tofu/backup.tf`](../infra/tofu/backup.tf) (the `vzdump` job) |
| **Host file backup** | losing the machine PVE itself runs on | Backblaze B2, via PBS | [`ansible/roles/pbs`](../ansible/roles/pbs) (`tasks/host_backup.yml`) |

The destination for the two offsite tiers is one Proxmox Backup Server
**running on the hypervisor itself**, with an S3-backed datastore called
`lab` in a Backblaze B2 bucket. Proxmox advises against co-locating PBS with
PVE, and the reason they give is a shared failure domain — which does not
apply here, because the copy that matters is in B2 and the local cache holds
no authoritative data. There is exactly one machine, so the alternative is a
VM on that same machine: same failure domain, plus a guest OS to patch.

### Why PBS and B2

Locked with the operator during Phase 8 planning; recorded here because the
question will be asked again.

- **PBS**, not restic/borg/plain `vzdump`, because it is the only option
  that gives dirty-bitmap incrementals, chunk-level dedup, client-side
  encryption, *verify* jobs that prove restorability, prune/GC, **and**
  single-file restore out of a block-level VM image — all native to the
  platform this repo already runs.
- **Backblaze B2**, EU region, because the protected set is ~35 GB and any
  provider with a 1 TB floor charges 20× for nothing. B2 has no minimums,
  no minimum retention charge (Wasabi's 90-day one actively fights PBS
  garbage collection), free API calls, and free egress up to 3× stored per
  month — which is what makes the weekly verify job affordable.
- **Not OVH object storage**, though it is cheap and already in the
  account: same vendor as the server. One account lockout would lose
  production *and* the backups.
- **Not Cloudflare R2**, though it adds no new vendor and has free egress:
  it would put DNS, TLS issuance and backups behind one Cloudflare account.
  For backups, blast-radius separation beat vendor consolidation — a backup
  that a compromised Cloudflare token can delete is not much of a backup.

## What is backed up

| Source | Group in PBS | Contains | Measured size |
|---|---|---|---|
| k3s VM `9000`, disks `scsi0` + `scsi1` | `vm/9000` | the guest OS, and every PVC on the default `local-path` class — Plex metadata, the \*arr SQLite DBs, Deluge's session state, Authelia's TOTP/WebAuthn registrations | 214 GiB provisioned, ~35 GiB of actual chunks |
| the Proxmox host's own files | `host/server` | `/etc` (crossing into `/etc/pve` on purpose), `/var/lib/pve-cluster`, `/root`, and a regenerated rebuild-facts dump | ~7 MiB |

The `vm/9000` figure is the one number here that is routinely misread. **214
GiB is the *logical* size** — `scsi0` (64 GiB) plus `scsi1` (150 GiB) as
provisioned, before dedup and compression, and it is what the Grafana
*Newest snapshot size, per target* panel shows. What is actually in the
bucket is the deduplicated chunk total, reported by garbage collection as
`disk-bytes` and measured at **35.2 GiB** after the first GC. Nothing else
exposes the bucket's size: `proxmox-backup-client status` on an S3 datastore
reports the *local chunk cache*, not B2.

### The rebuild-facts archive

`host/server` carries nine regenerated text files that no configuration file
records and that a bare-metal rebuild needs in front of it: `pveversion -v`,
`zpool status -v`, `zpool list -v`, `zfs list`, `zfs get all`,
`ls -l /dev/disk/by-id/`, `lsblk` with serials and WWNs, `pvesm status`, and
the dpkg package list. They are regenerated on every run, so each night's
snapshot describes that night's machine. This is the difference between a
rebuild being mechanical and it being archaeological.

`/etc/pve` is inside `etc.pxar` and `/var/lib/pve-cluster` is a separate
archive on purpose: pmxcfs serves file contents from memory, so `/etc/pve`
reads coherently on a live host, while the raw `config.db` underneath it can
be caught mid-write. **`/etc/pve` is the copy to restore from; the `.db` is
the fallback for a pmxcfs that will not start at all.**

## Deliberately not backed up

Shorter than intuition suggests: **nothing on `tank` is backed up**, and
that is a decision rather than a compromise.

| Excluded | Why it is safe to exclude |
|---|---|
| `/tank/data/media`, `/tank/data/torrents` | Re-downloadable. 3.6 TB. The operator's explicit call — protecting it would cost more per month than the media is worth. |
| `/tank/data/backups` (the \*arr weekly zips) | **Redundant.** A zip is the app's SQLite DB plus `config.xml` — a strict subset of the config PVC, which lives on `scsi1`, which is inside the VM backup. If `tank` dies, every database still survives. |
| `/tank/data/torrents-final` (`.torrent` files) | **Redundant.** Deluge's own `state/` directory in its config PVC already holds a copy of each `.torrent` plus its resume data. |
| `/tank/data/.recyclebin` | Transient by design, 7-day cleanup — see [`media-retention.md`](media-retention.md). |
| Prometheus / Loki / Alertmanager PVCs | Reproducible telemetry with daily churn. Excluded **by disk, not by path** — see below. |
| `ci-runner` VM (`9001`) | Deliberately stateless; it re-registers itself from `GH_RUNNER_PAT`. |
| `rpool/pbs-cache` | PBS's own S3 chunk cache. Reconstructible from B2 by definition, and the one dataset here designed to churn. |
| `rpool/var-lib-vz` | ISO and container-template store. Re-downloadable, and not configuration. |

The one thing given up: after a `tank` loss you cannot do a one-click in-app
\*arr restore from a zip. You restore the config PVC out of the VM backup
instead, which holds the same data and is covered by
[`runbooks/restore.md`](runbooks/restore.md#restore-one-pvc). Not worth a
special case.

### The monitoring exclusion is a disk, because it has to be

`vzdump` of VM 9000 is **block-level and cannot exclude a path**. The only
way to keep ~25 GB of daily-churning TSDB out of the datastore — and out of
B2 for the six months `keep-monthly` would hold those chunks — is to put it
on a disk the backup job never reads. That disk is `scsi2`, carrying
`backup = false` in [`infra/tofu/vm-k3s.tf`](../infra/tofu/vm-k3s.tf), and
the Prometheus, Alertmanager and Loki PVCs reach it through the non-default
`local-path-ephemeral` StorageClass. The full chain is in
[`observability.md`](observability.md#where-a-pvc-actually-lives).

Two consequences that are easy to undo by accident:

- **`local-path` remains the cluster default**, so anything that omits
  `storageClassName` lands on the backed-up disk. Opting *out* of backup is
  always an explicit line in a manifest — never the other way round.
- **The ZFS snapshot tier derives its disk set from PVE's own `backup=`
  flags**, so `vm-9000-disk-2` is excluded from snapshots by construction
  rather than by name. The zvol suffix is allocation order, not the scsi
  index: detaching and re-adding a disk renumbers the rest, and an exclusion
  list keyed on `vm-9000-disk-2` would then protect the wrong disk while
  still looking correct.

## The nightly timeline

Everything is UTC as the host runs it, and the order is load-bearing.

| When | What | Defined in |
|---|---|---|
| every 15 min | sanoid takes and prunes ZFS snapshots | `sanoid.timer` (packaged), config from `roles/zfs_snapshots` |
| every 15 min | the backup metrics collector rewrites `lab-backup.prom` | `roles/pbs` (`pbs_metrics_interval`) |
| `sat 02:00` | PBS garbage collection — deletes chunks nothing references any more | `roles/pbs` (`pbs_gc_schedule`) |
| **`03:30`** | the host's own file-level backup → `host/server` | `roles/pbs` (`pbs_host_backup_schedule`) |
| **`04:00`** | `vzdump` of guest 9000 → `vm/9000` | `infra/tofu/backup.tf` |
| `06:00` | PBS prune — applies retention, unreferencing old snapshots | `roles/pbs` (`pbs_prune_schedule`) |
| `sun 07:00` | PBS verify — re-reads chunks from B2 and checks them against their digests | `roles/pbs` (`pbs_verify_schedule`) |

The host backup runs before the VM backup so a night's host configuration
exists before that night's guest image. Prune runs after both, because it
has nothing to unreference until the night's snapshots exist. Verify runs
after prune, so it reads back what was actually kept. GC runs weekly rather
than nightly because on an S3 datastore it is a full bucket listing plus
deletes — billable API calls — and it has no work to do until a prune has
unreferenced something.

**A reboot at 04:00 does not skip the night.** The `vzdump` job carries
`repeat_missed = true` and the host-backup timer carries `Persistent=true`,
so a missed window becomes a late backup rather than a missing one.

## Retention

Defined **exactly once each**, and that is deliberate in both cases.

| Tier | Policy | Defined in |
|---|---|---|
| ZFS snapshots | 24 hourly, 7 daily, 4 weekly, `autoprune` | `zfs_snapshots_retention` |
| PBS | `keep-last 3`, `keep-daily 7`, `keep-weekly 4`, `keep-monthly 6` | `pbs_prune_keep` |

**The `vzdump` job deliberately has no `prune_backups`.** PVE would apply it
over the API as `pve-backup@pbs`, whose `DatastoreBackup` role cannot prune
by design, so every run would end in an error. Retention lives in the PBS
prune job and nowhere else; widening the ACL to `DatastorePowerUser` just to
host a second copy of the same numbers would be strictly worse.

**Every ZFS retention type is stated, including the zeros, and that is
load-bearing.** sanoid ships a `[template_default]` carrying `hourly = 48`,
`daily = 90` and **`monthly = 6`**, and seeds every section from it before
merging anything from the rendered config. A config that sets only the three
types it wants silently inherits six monthly snapshots per dataset, held for
half a year — while looking, in the file, exactly like a config that does
not.

## Encryption and the key

**Everything is encrypted client-side, before it leaves the host.** B2 holds
ciphertext and nothing else — not the file names, not the directory
structure. That is what makes an external vendor acceptable for this at all.

The key is a single `proxmox-backup-client key create --kdf none` JSON file,
generated once and **never regenerated**. It exists in exactly three places,
and adding a fourth is a policy decision:

| Copy | Why it exists |
|---|---|
| Password-manager entry | The durable copy. **That file *is* the backups** — without it the bucket is noise. |
| `ansible/inventory/group_vars/proxmox_host.sops.yml` (`pbs_encryption_key`) | So a rebuilt host gets the key from git, decrypted with the age key, before `/etc/pve` exists. |
| `/etc/proxmox-backup/lab-encryption-key.json` on the host | What `proxmox-backup-client` reads for the host backups. `roles/pbs` also hands it to `pvesm add --encryption-key`, which copies it to `/etc/pve/priv/storage/pbs.enc` for `vzdump` and `qmrestore`. |

A copy that exists **only** inside the SOPS file is not a second copy: the
age key that decrypts it lives in the same password manager. The two are
separate entries so that losing one does not lose both, but they share a
single root of trust — see [`secrets.md`](secrets.md#the-keypair).

**An unencrypted snapshot means the key never reached PVE, and it will keep
"working".** The check is `proxmox-backup-client snapshot files <snapshot>`
— **not** `snapshot list`, which has no `crypt-mode` column — and every
archive should read `encrypt`:

```
etc.pxar.didx             encrypt     3068058
pve-cluster.pxar.didx     encrypt     4202575
index.json.blob           sign-only       757
```

`index.json` reading `sign-only` is normal and not a finding: the manifest
is signed rather than encrypted, so PBS can list a snapshot's contents
without the key.

### What replaces immutability

**PBS supports neither S3 Object Lock nor bucket versioning, and enabling
either can corrupt the datastore** — garbage collection has to be free to
delete chunks. So an attacker holding the B2 application key can delete the
backups, and there is no vendor-side control that prevents it. This is an
**accepted risk**, recorded rather than overlooked. What stands in for
immutability:

- the B2 key is **bucket-scoped**, never the master key;
- it lives only in SOPS and the password manager, never in a shell history
  or an environment file;
- the local ZFS tier is on different infrastructure from the bucket and
  under different credentials, so one stolen key does not reach both;
- `PbsGcStale` and `BackupStale` make a datastore that has stopped changing
  visible within 36 hours rather than at audit time.

## The cost model

Measured on this datastore rather than estimated.

| Figure | Value | Where it comes from |
|---|---|---|
| Logical size of everything backed up | 214 GiB | `lab_backup_last_size_bytes`, i.e. provisioned disk size |
| Actual chunks in B2 | **35.2 GiB** | `proxmox-backup-manager garbage-collection list` → `disk-bytes` |
| Storage cost | **~$0.23/month** | 37.8 GB × $6/TB |
| Egress | $0 | verify re-reads ~1× stored per month; B2 allows 3× free |
| API calls | $0 | B2 does not charge for them, and the metrics collector was measured to cost none at all — manifests are served from the local cache |

Steady state will be higher than today: `keep-monthly 6` means six monthly
snapshots accumulate over the first half-year, and only the chunks that
actually differ between them are stored. Budget **under $1/month** and treat
anything above that as a signal that something large moved onto a backed-up
disk.

`disk-bytes` is only refreshed when GC runs, i.e. weekly. It is the one
number that answers "how much are we storing in B2", and **no Prometheus
metric carries it** — the `lab_backup_cache_*` series describe the local
chunk cache, whose `total` is exactly the 64 GiB ZFS quota on
`rpool/pbs-cache`.

## The local chunk cache

An S3-backed datastore requires a local persistent cache on a path of its
own — PBS refuses a directory that is already a datastore, and a cache
sharing a filesystem with something else can starve it. Hence a dedicated
dataset:

- `rpool/pbs-cache`, mounted `/mnt/pbs-cache`, **64 GiB quota**.
- `roles/pbs` reads the pool's real free space at converge time and refuses
  to create the dataset unless the quota fits twice over, then **asserts the
  quota actually applied**. An inherited default of 0 (unlimited) is the
  failure that matters: everything looks healthy and the cache grows until
  rpool — the root filesystem *and* both VM disks — is full, months later.
- **PBS bounds it with an LRU of its own**, roughly 4095 chunks (~16 GiB),
  which is why `PbsCacheDiskHigh` at 85 % is meaningful rather than
  permanently firing. The cache is designed to fill; had PBS sized its LRU
  from the quota, that alert would fire forever once the datastore grew.
- It is excluded from ZFS snapshots by construction, and restated in
  `zfs_snapshots_forbidden` so that a later edit widening the selection
  fails the converge instead of quietly filling the pool with snapshots of
  a cache.

## Verification

A backup nobody has read is a directory of files, and a backup nobody has
restored is a hypothesis. Three different things check three different
claims:

| Mechanism | Proves | Does not prove |
|---|---|---|
| **Verify job** (`sun 07:00`) | the chunks in B2 are still readable and match their digests | that they reassemble into something that boots |
| **Metrics + alerts** (`rules-backups.yaml`) | backups are still being *taken*, on schedule | anything about giving them back |
| **The restore drill** (every 180 d) | a real file comes back out, decrypted, intact | — this is the only one that closes the loop |

`--ignore-verified` plus `--outdated-after 30` is what keeps verification
affordable: the weekly schedule is the *opportunity* to verify, and the
30-day window is what actually bounds it, so in steady state the datastore
is re-read roughly once a month. A weekly schedule with no `outdated-after`
would read it four times a month and start costing real egress.

**`RestoreDrillOverdue` fires on a host where no drill has ever run, and
Ansible deliberately does not seed the marker.** The marker is
`/var/lib/lab-backup-metrics/last-restore-drill`; the role creates its
directory and never the file, because a seeded file would clear the alert by
asserting a restore had been proven when none had. It is the one alert in
this repo that no machine can satisfy — the drill's last step touches it.
Procedure: [`runbooks/restore.md`](runbooks/restore.md#the-restore-drill).

## Monitoring

PBS has no Prometheus endpoint at any version — it pushes to InfluxDB or
Graphite and to nothing else — so `roles/pbs` ships a textfile collector
(`templates/lab-backup-metrics.sh.j2`) that node_exporter serves on the
host, alongside the ZFS and SMART one from `roles/node_exporter`. It is a
**separate `.prom` file** on purpose: node_exporter treats a file it cannot
parse as an error for the whole textfile directory, so folding the two
together would let a PBS outage take ZFS capacity and SMART freshness down
with it.

The nine series, the seven alerts and the "Backups" Grafana dashboard are
catalogued in
[`observability.md`](observability.md#metric-alerts--backups). Two rules
that matter when adding to them:

- **No `0` sentinels.** A backup, verify, GC or drill that has never
  happened emits no series at all — a `0` would make `time() - metric` span
  the Unix epoch and pin the alert firing forever. Every staleness rule
  therefore carries a paired `absent()` clause naming each expected target.
- **`host/server` and `vm/9000` are hard-coded** into those `absent()`
  clauses, from `pbs_host_backup_id` and `infra/tofu/backup.tf`'s `vmid`
  respectively. Adding a backup target means adding a clause.

There is also a **PBS-native Telegram webhook**, which deliberately
duplicates what Alertmanager already does. Prometheus runs inside the k3s
VM: if that VM is down, every alert path in `clusters/lab/platform` is down
with it, *including any alert about the VM being down*. This notifier runs
on the hypervisor and is the only backup-failure signal that survives that.
Do not consolidate it into Alertmanager.

It has one known limitation, recorded in `roles/pbs`' `vars/main.yml`:
Telegram rejects a `text` over 4096 characters, so a very long verify report
can be dropped outright. Acceptable for a channel whose job is to say "go
and look", and it is why this supplements Alertmanager rather than replacing
it.

**It is a PBS notifier**, so it sees PBS's own verify/GC/prune events and
**never** a `vzdump` that failed on the PVE side, nor a host backup that
failed. There is no MTA on this host either. Those two failures are covered
by `BackupStale` and by nothing else.

## The disaster-recovery chain

Stated explicitly because it looks circular and that is when people panic.
It is not circular — every link is recoverable from two things held
**outside** the server:

```
password manager (age key)
  └─> GitHub (this repo, cloned anywhere)
        └─> SOPS decrypts proxmox_host.sops.yml
              ├─> B2 application key      ─┐
              └─> PBS encryption key       ├─> reattach the `lab` datastore
                                           ┘     on a rebuilt PBS
                    └─> restore the host's files, then the VM
                          └─> Argo CD reconciles everything else from git
```

The age key remains the single root of trust, exactly as
[`secrets.md`](secrets.md) says. What you must be able to reach on a day
when the server is gone is: **the password manager, and GitHub.** Nothing
else in that chain lives on the machine being restored.

Two things that would break the chain if changed casually:

- **The datastore name `lab` is part of the contract, not a label.**
  Reattaching the bucket to a rebuilt PBS requires creating a datastore with
  the same name, or the S3 object prefix will not line up with what is
  already there. Changing it means migrating, not renaming.
- **The B2 bucket must never have Object Lock or versioning enabled**, at
  any point, including "just to be safe" during a recovery.

Full procedure: [`runbooks/disaster-recovery.md`](runbooks/disaster-recovery.md).

## Adding a backup target

In rough order of how often it comes up.

**A new PVC that should be backed up** — do nothing. `local-path` is the
cluster default, so any PVC that omits `storageClassName` lands on `scsi1`
and is inside `vm/9000` from its first write.

**A new PVC that should *not* be backed up** — set
`storageClassName: local-path-ephemeral` explicitly, and say why in the
manifest. Then confirm it landed there: `kubectl -n <ns> get pvc` should
show the class, and the PV directory should appear under
`/var/lib/rancher/k3s/ephemeral/`, not `/var/lib/rancher/k3s/storage/`. A
green Argo status is not this check — during the Phase 8 cutover both
StatefulSets read `Synced/Healthy` while their pods were still bound to the
old PVCs on the backed-up disk.

**A new guest VM** — add its id to `vmid` in
[`infra/tofu/backup.tf`](../infra/tofu/backup.tf) (an explicit list, never
`all = true`, so adding a guest to the backup set is a visible diff rather
than a side effect of creating a VM), and to `zfs_snapshots_guests` if it
should also get the local rollback tier. Then add an `absent()` clause for
its group to `BackupStale` in
[`monitoring/rules-backups.yaml`](../clusters/lab/platform/monitoring/rules-backups.yaml)
— nothing derives those, and a target with no clause simply goes quiet
instead of alerting.

**A new host path** — add it to `pbs_host_backup_sources` in
`roles/pbs`' `defaults/main.yml`. If it is on a different filesystem, it
also needs an entry in `pbs_host_backup_include_devs`: the client does
**not** cross mount points, which is what keeps 3.6 TB of `/tank` out of
this with no exclude rules at all, and is also why `/etc/pve` has to be
named explicitly — it is a FUSE mount and would otherwise be skipped
silently, in the middle of `/etc`.

**A new host filesystem to snapshot** — add it to
`zfs_snapshots_filesystems`. The role asserts every dataset exists before
writing it into the config, because sanoid will not: a dataset that does not
exist is a `warn`, not a `die`, the unit still exits 0, and the only trace
is one line in that night's journal.

## Secret rotation

Six values live in `ansible/inventory/group_vars/proxmox_host.sops.yml`.
Four of them can be rotated; two cannot.

| Value | Rotatable | How |
|---|---|---|
| `pbs_s3_access_key` / `pbs_s3_secret_key` | yes | Issue a new **bucket-scoped** B2 application key, update both halves in SOPS, converge once with `-e pbs_rotate_secrets=true`, then converge again without it. B2 issues both halves together, so a rotated key always changes both. |
| `pbs_pve_storage_password` | yes | Same two-converge dance. |
| `pbs_notify_telegram_bot_token` / `pbs_notify_telegram_chat_id` | yes | Same. |
| `pbs_encryption_key` | **no** | Regenerating it makes every existing snapshot in B2 unreadable. There is no re-key operation. Rotating it in practice means starting a new datastore and keeping the old one until its retention runs out. |

The two-converge dance exists because **secrets PBS never reveals again
cannot be diffed**. The role writes them on create, and thereafter only when
`pbs_rotate_secrets` is true for one converge — otherwise every run would
either rewrite them blindly or report *changed* forever.

Custody of all six, plus the age key that decrypts them, is
[`secrets.md`](secrets.md#backup-credentials).

## Restoring

| You want | Runbook |
|---|---|
| one file back out of the VM | [`restore.md`](runbooks/restore.md#restore-one-file-from-the-k3s-vm) |
| one PVC back (the \*arr-database case) | [`restore.md`](runbooks/restore.md#restore-one-pvc) |
| a file off the hypervisor itself | [`restore.md`](runbooks/restore.md#restore-a-file-from-the-hypervisor) |
| to undo the last hour on the host | [`restore.md`](runbooks/restore.md#roll-back-a-zfs-snapshot) |
| the whole k3s VM back | [`restore.md`](runbooks/restore.md#restore-the-whole-k3s-vm) |
| the entire server, from nothing | [`disaster-recovery.md`](runbooks/disaster-recovery.md) |
| to prove any of the above still works | [`restore.md`](runbooks/restore.md#the-restore-drill) |
