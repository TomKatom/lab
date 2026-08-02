# Runbook: restoring from backup

The granular cases — one file, one PVC, one host config file, an hour of
regret, or the whole VM. Losing the entire machine is a different document:
[`disaster-recovery.md`](disaster-recovery.md).

What each tier holds and why is [`docs/backups.md`](../backups.md). This
file is the commands, and **every command below was executed read-only
against this host while it was written** — the identifiers in the examples
are real ones from 2026-08-02, not invented.

> **Restores are operator work, run over SSH on the host.** That is the one
> place this repo's "never touch the server by hand" rule does not apply,
> because a restore is by definition not reconcilable from git. Everything
> you *change* on the way back — a manifest, a variable — still goes through
> a PR.

---

## Before anything: the environment

Every `proxmox-backup-client` and `proxmox-file-restore` call needs three
things. Set them once per shell, on the host, as root:

```sh
export PBS_REPOSITORY='pve-backup@pbs@127.0.0.1:8007:lab'
export PBS_FINGERPRINT=$(proxmox-backup-manager cert info \
  | grep -oE '([0-9A-Fa-f]{2}:){31}[0-9A-Fa-f]{2}' | head -n 1)
export PBS_PASSWORD_FILE=/etc/proxmox-backup/lab-host-backup.pw
```

- **The repository legitimately carries two `@`.** The form is
  `[[username@]server[:port]:]datastore`, and the auth-id
  `pve-backup@pbs` brings its own.
- **The fingerprint is read live, never pasted.** PBS's certificate is
  self-signed, so the client either pins a fingerprint or asks — and a
  question inside a script is a hang. Matching by *shape* (32
  colon-separated hex octets) rather than by the label in front of it is
  what `roles/pbs` does everywhere, for the same reason.
- **The key file is `/etc/proxmox-backup/lab-encryption-key.json`** and is
  passed as `--keyfile` on every command that reads data. Without it you
  get chunks you cannot decrypt, not an error you can act on.

**`proxmox-file-restore` is the exception, and it is not documented
anywhere obvious:** the QEMU-backed path refuses `PBS_PASSWORD_FILE` and
fails with

```
Error: environment variable PBS_PASSWORD has to be set for QEMU VM restore
```

because it has to hand the credential to the temporary restore VM. For
those commands only, use:

```sh
export PBS_PASSWORD=$(cat /etc/proxmox-backup/lab-host-backup.pw)
```

### What is in the datastore

```sh
proxmox-backup-client snapshot list
```

```
host/server/2026-08-02T00:48:28Z   7.096 MiB   catalog.pcat1 etc.pxar index.json pve-cluster.pxar rebuild-facts.pxar root.pxar
host/server/2026-08-02T02:30:03Z   7.172 MiB   catalog.pcat1 etc.pxar index.json pve-cluster.pxar rebuild-facts.pxar root.pxar
vm/9000/2026-08-02T03:00:02Z         214 GiB   client.log drive-scsi0.img drive-scsi1.img fw.conf index.json qemu-server.conf
```

**`proxmox-backup-manager snapshot list` does not exist** — that binary has
no `snapshot` subcommand at all. Use the client, as above. (Two earlier
handoff documents in this project told people to use the manager; this is
the correction.)

The listing has no `crypt-mode` column. To confirm a snapshot is actually
encrypted — the check that catches an encryption key that never reached
PVE — ask for its files instead:

```sh
proxmox-backup-client snapshot files host/server/2026-08-02T02:30:03Z
```

```
etc.pxar.didx             encrypt     3068058
pve-cluster.pxar.didx     encrypt     4202575
index.json.blob           sign-only       757
```

`sign-only` on `index.json` is normal: the manifest is signed, not
encrypted, so PBS can list a snapshot without holding the key.

Add `--output-format json` if you are scripting — the fields are
`backup-id`, `backup-time`, `backup-type`, `files`, `fingerprint`, `owner`,
`protected`, `size` and `verification`, and **`backup-time` is a Unix epoch
number**, not the ISO-8601 string that appears in a snapshot path.

`proxmox-backup-client catalog dump` writes its output to **stderr**, not
stdout, so it needs `2>&1 |` to pipe anywhere.

---

## Restore one file from the k3s VM

The common case: something inside the guest was deleted or corrupted and you
want last night's copy, without touching the running VM.

`proxmox-file-restore` boots a small, short-lived QEMU VM that mounts the
backed-up disk image read-only and hands files back. It self-terminates
after about ten minutes; you can also stop it explicitly (below).

**1. Pick a snapshot and see which disks it holds:**

```sh
export PBS_PASSWORD=$(cat /etc/proxmox-backup/lab-host-backup.pw)
proxmox-file-restore list vm/9000/2026-08-02T03:00:02Z / \
  --repository "$PBS_REPOSITORY" \
  --keyfile /etc/proxmox-backup/lab-encryption-key.json
```

```
v   drive-scsi0.img.fidx    68719476736
v   drive-scsi1.img.fidx   161061273600
```

`scsi0` is the guest OS; `scsi1` is every PVC on the default `local-path`
class. **There is no `drive-scsi2.img.fidx`, and there should never be** —
that disk carries `backup = false` and holds the monitoring PVCs. Seeing one
here means the exclusion has been undone.

**2. Descend into the disk.** The next level is the partition layout, and
these disks have none — `roles/k3s` formats the whole device — so it is a
single entry called `raw`:

```sh
proxmox-file-restore list vm/9000/2026-08-02T03:00:02Z /drive-scsi1.img.fidx \
  --repository "$PBS_REPOSITORY" \
  --keyfile /etc/proxmox-backup/lab-encryption-key.json
```

```
v   raw
```

This is the step that actually boots the restore VM, so it takes ~30 s. The
first level (step 1) is served from the index and is instant.

**3. Below `raw` is the filesystem root**, which for `scsi1` is
`/var/lib/rancher/k3s/storage` — i.e. the PV directories:

```sh
proxmox-file-restore list vm/9000/2026-08-02T03:00:02Z /drive-scsi1.img.fidx/raw \
  --repository "$PBS_REPOSITORY" \
  --keyfile /etc/proxmox-backup/lab-encryption-key.json
```

```
d   lost+found
d   pvc-17be46d0-c8a8-4ea5-ae87-5fe1ef9c962f_media_plex
d   pvc-6043a4bd-76c9-48b5-9684-6fa54fea7c21_media_sonarr
...
```

The naming is `pvc-<uid>_<namespace>_<claim-name>`, so the directory you
want is identifiable without consulting the cluster — which matters,
because in a real restore the cluster may not be up.

**4. Extract.** Keep going down the path until you reach the file, then:

```sh
proxmox-file-restore extract vm/9000/2026-08-02T03:00:02Z \
  /drive-scsi1.img.fidx/raw/pvc-6043a4bd-..._media_sonarr/sonarr.db \
  /root/restore \
  --repository "$PBS_REPOSITORY" \
  --keyfile /etc/proxmox-backup/lab-encryption-key.json
```

Extracting a **directory** works too and produces an archive; add
`--format tar` or `--format zip` to choose which, or `-` as the target to
write to stdout.

**5. Leave nothing running:**

```sh
proxmox-file-restore status
proxmox-file-restore stop 'qemu_pve-backup@pbs@127.0.0.1:8007:lab/vm/9000/2026-08-02T03:00:02Z'
```

`status` prints `Qemu: no mappings` once it is clean. The restore VM times
out on its own, so forgetting this is untidy rather than dangerous — but it
holds RAM until it does.

---

## Restore one PVC

This is the case the \*arr weekly zips used to cover, and the reason
[`docs/backups.md`](../backups.md#deliberately-not-backed-up) can leave
`/tank/data/backups` out of the backup set: the same SQLite database is
inside `vm/9000` already.

**Scale the app down first.** SQLite plus a live writer plus a file being
swapped underneath it is how you turn one corrupt database into two.

```sh
# on k3s-node (or with a kubeconfig pointed at it)
kubectl -n media scale deployment sonarr --replicas=0
kubectl -n media get pod -l app.kubernetes.io/name=sonarr   # wait for none
```

Then extract the PVC's directory from the backup as above, targeting a
scratch path on the **host**, and move it into place inside the VM. The PV
directory lives at
`/var/lib/rancher/k3s/storage/pvc-<uid>_<ns>_<name>/` on `k3s-node`.

```sh
# on the host: pull the directory out as a tar
proxmox-file-restore extract vm/9000/2026-08-02T03:00:02Z \
  /drive-scsi1.img.fidx/raw/pvc-6043a4bd-..._media_sonarr \
  - --format tar \
  --repository "$PBS_REPOSITORY" \
  --keyfile /etc/proxmox-backup/lab-encryption-key.json \
  > /root/sonarr-pvc.tar

# copy to the VM and unpack beside the live directory, never over it
scp /root/sonarr-pvc.tar debian@10.10.10.10:/tmp/
ssh debian@10.10.10.10 'sudo mkdir -p /var/lib/rancher/k3s/storage/restore \
  && sudo tar -xf /tmp/sonarr-pvc.tar -C /var/lib/rancher/k3s/storage/restore'
```

**Unpack beside, then swap** — `mv` the live directory aside, `mv` the
restored one in, and keep the old one until the app has come back up
healthy. Restoring straight over a live PV directory leaves you with no way
back if the backup turns out to be older than you thought.

Scale back up (`--replicas=1`) and check the app's own logs, not just the
pod status: a corrupt SQLite file produces a running container that logs
errors.

**Ownership matters.** The \*arr containers run as a fixed uid/gid; `tar -x`
as root preserves what was in the archive, which is correct. If you rebuilt
the file by hand instead, `chown` it to match the neighbouring PV
directories before scaling up.

---

## Restore a file from the hypervisor

`host/server` is file-level, so this needs no temporary VM and no
`PBS_PASSWORD` — `PBS_PASSWORD_FILE` is enough.

**See what is in the snapshot:**

```sh
proxmox-backup-client snapshot list
```

Four archives: `etc.pxar` (which includes `/etc/pve`, crossed into on
purpose), `pve-cluster.pxar` (`/var/lib/pve-cluster`), `root.pxar`, and
`rebuild-facts.pxar`.

**Restore one archive to a scratch directory:**

```sh
proxmox-backup-client restore host/server/2026-08-02T02:30:03Z etc.pxar /root/restore-etc \
  --repository "$PBS_REPOSITORY" \
  --keyfile /etc/proxmox-backup/lab-encryption-key.json
```

Then copy out the one file you need. **Never restore an archive directly
over `/etc`** — `--target /etc` would overwrite live configuration
wholesale, including files that have legitimately changed since the backup.

Useful flags when you are extracting onto a machine that is not the one the
archive came from: `--ignore-ownership` (no `chown`), `--ignore-acls`,
`--ignore-xattrs`, `--allow-existing-dirs`.

To list an archive's contents without extracting it:

```sh
proxmox-backup-client catalog dump host/server/2026-08-02T02:30:03Z \
  --repository "$PBS_REPOSITORY" \
  --keyfile /etc/proxmox-backup/lab-encryption-key.json 2>&1 | less
```

**That command writes to stderr**, hence the `2>&1`. Without it you get an
empty pipe and no error.

### The WireGuard host key

Worth calling out because it is the one file in `etc.pxar` that cannot be
regenerated without consequences: `/etc/wireguard/wg0.key` never leaves this
box, and generating a new one invalidates **every peer configuration**,
including the one you would be using to reach the host. It is in the backup
(45 bytes, beside `wg0.conf`); restore it rather than re-keying, unless you
are deliberately rotating and have console access.

---

## Roll back a ZFS snapshot

The rollback tier: 24 hourly, 7 daily, 4 weekly, taken every 15 minutes by
sanoid on `rpool/ROOT/pve-1` (the hypervisor's root filesystem) and on guest
9000's two backed-up disks. **These live on the pool they protect and do not
survive losing it** — they are for undoing a bad `apt upgrade` or a wrong
`/etc` edit, not for disaster recovery.

```sh
zfs list -t snapshot -o name,used,creation rpool/ROOT/pve-1
```

```
rpool/ROOT/pve-1@autosnap_2026-08-02_05:00:02_hourly   4.55M   Sun Aug  2  6:00 2026
```

Only `autosnap_*` snapshots belong to sanoid. A `@vzdump` snapshot is PVE's
own temporary one, taken and removed by the nightly backup job — sanoid
filters on the `autosnap` prefix precisely so it can never prune or race
one.

**Prefer a clone over a rollback.** `zfs rollback` **destroys every snapshot
newer than the target**, irreversibly, and on `rpool/ROOT/pve-1` it rolls
back the running root filesystem:

```sh
# safe: mount a read-only copy and take what you need out of it
zfs clone rpool/ROOT/pve-1@autosnap_2026-08-02_05:00:02_hourly rpool/rollback-tmp
ls /rpool/rollback-tmp/etc/...
# ... copy the file out ...
zfs destroy rpool/rollback-tmp
```

Use a real rollback only when you want the whole filesystem back:

```sh
zfs rollback -r rpool/ROOT/pve-1@autosnap_2026-08-02_05:00:02_hourly
```

`-r` is what destroys the newer snapshots; without it the command refuses
when any exist. **Rolling back the root filesystem wants a reboot**, and
this server has no IPMI and no console — if the rolled-back state cannot
boot, recovery is an OVH rescue-mode ticket
([`lockout-recovery.md`](lockout-recovery.md)). Roll back a *guest* zvol
instead where you can: stop the VM, roll back
`rpool/data/vm-9000-disk-0`/`-1`, start it.

Deleting files that a snapshot still pins frees **nothing** — this is the
first thing to check when `ZfsPoolCapacityHigh` fires.

---

## Restore the whole k3s VM

The nightly `vzdump` snapshots appear as ordinary PVE volumes on the `pbs`
storage:

```sh
pvesm list pbs
```

```
Volid                                     Format  Type            Size  VMID
pbs:backup/vm/9000/2026-08-02T03:00:02Z   pbs-vm  backup  229780752548  9000
```

```sh
qmrestore pbs:backup/vm/9000/2026-08-02T03:00:02Z 9000 --storage local-zfs
```

- **`--force`** is required to overwrite an existing VM 9000. Without it the
  command refuses, which is the right default — think before adding it.
- **`--storage local-zfs`** is stated explicitly. Omitted, volumes are
  allocated on whatever storage they came from, which is the same thing
  today and will not be if the layout ever changes.
- **`--live-restore`** starts the VM immediately and restores in the
  background (PBS only). Tempting during an outage, and the trade is real:
  the guest runs against data still streaming in from B2 over the internet,
  so it is slow and a failed restore leaves a half-populated VM. Prefer the
  ordinary path unless downtime genuinely costs more than the risk.
- **`--start`** boots it afterwards; leave it off if you want to check
  `qm config 9000` first.

**Check `qm config 9000` before starting it.** The restored config comes
from `qemu-server.conf.blob` inside the snapshot, so it reflects the VM as
it was that night — including disk sizes and the `backup=` flags. `scsi2` is
**not** in the backup and will not come back: recreate it via `tofu apply`
(the disk is declared in `infra/tofu/vm-k3s.tf`), let `roles/k3s` format and
mount it, and let Argo recreate the monitoring PVCs on it. Those PVCs hold
telemetry, which is reproducible — that is why they are on that disk.

After the VM is up: `kubectl get nodes`, then Argo. Anything that drifted
while it was down reconciles from git on its own.

---

## The restore drill

**Every 180 days, and the only thing in this repo that proves the backups
are real.** `RestoreDrillOverdue` fires until it has been done, and it is
deliberately impossible to satisfy any other way — Ansible creates the
marker's directory and never the marker itself, because a seeded file would
assert that a restore had been proven when none had.

Do not silence the alert. Do the drill.

**1. Restore a file from the host backup**, into a scratch directory:

```sh
export PBS_REPOSITORY='pve-backup@pbs@127.0.0.1:8007:lab'
export PBS_FINGERPRINT=$(proxmox-backup-manager cert info \
  | grep -oE '([0-9A-Fa-f]{2}:){31}[0-9A-Fa-f]{2}' | head -n 1)
export PBS_PASSWORD_FILE=/etc/proxmox-backup/lab-host-backup.pw

rm -rf /root/drill && mkdir -p /root/drill

newest=$(proxmox-backup-client snapshot list --output-format json \
  | jq -r '[.[] | select(.["backup-type"] == "host" and .["backup-id"] == "server")]
           | max_by(.["backup-time"]) | "host/server/" + (.["backup-time"] | todate)')
echo "$newest"   # e.g. host/server/2026-08-02T02:30:03Z

proxmox-backup-client restore "$newest" rebuild-facts.pxar /root/drill/facts \
  --repository "$PBS_REPOSITORY" \
  --keyfile /etc/proxmox-backup/lab-encryption-key.json
```

**`backup-time` in the JSON is a Unix epoch number, not the ISO-8601 string
the snapshot path wants** — hence `| todate`. Concatenating it directly
fails with `string and number cannot be added`, which is at least a loud
failure; `last` instead of `max_by` would be the quiet one, since nothing
documents that the list comes back sorted.

Check it: nine `.txt` files, all non-empty, and `pveversion.txt` naming a
version you recognise. `rebuild-facts.pxar` is the right archive to drill
on — it is small, it is regenerated nightly so a stale copy is obvious, and
it is the archive a real rebuild reads first.

**2. Restore a file from the VM backup**, which exercises the entirely
different QEMU-backed path:

```sh
export PBS_PASSWORD=$(cat /etc/proxmox-backup/lab-host-backup.pw)
proxmox-file-restore list vm/9000/<latest> /drive-scsi1.img.fidx/raw \
  --repository "$PBS_REPOSITORY" \
  --keyfile /etc/proxmox-backup/lab-encryption-key.json
```

Then `extract` one real file — a `*.db` out of an \*arr PVC is a good
choice — and confirm it is the size you expect and that `file` identifies it
as a SQLite database rather than as data. **Stop the restore VM afterwards.**

**3. Check what the drill just proved by accident:** that the encryption key
on this host still decrypts what is in B2. If step 1 or 2 produced garbage
rather than an error, stop and treat it as an incident — that is the failure
mode no alert can see.

**4. Touch the marker. This is the last step and the whole point:**

```sh
touch /var/lib/lab-backup-metrics/last-restore-drill
```

Within 15 minutes the collector picks it up,
`lab_backup_restore_drill_timestamp_seconds` appears, the *Last restore
drill* panel on the Backups dashboard fills in, and `RestoreDrillOverdue`
clears. Confirm from the other end rather than assuming:

```sh
./scripts/promql.sh 'lab_backup_restore_drill_timestamp_seconds'
```

**5. Clean up:** `rm -rf /root/drill`, and check
`proxmox-file-restore status` reads `Qemu: no mappings`.

### What the drill deliberately does not do

It does not restore the whole VM, because doing that for real means either
overwriting the running one or finding 214 GiB somewhere to put a copy.
The drill covers the two paths that would actually be used in anger — a file
out of the host archive and a file out of a VM image — and the parts it
skips (`qmrestore` itself, and the bare-metal rebuild) are proven by
[`disaster-recovery.md`](disaster-recovery.md) being followed at least once,
not by the marker.

---

## When a restore is not the answer

- **A pod that will not start** is almost never a backup problem. Check Argo
  and the pod's events first; `local-path` PVs are on `scsi1` and are still
  there.
- **A missing media file** is not backed up at all, by design, and should be
  re-acquired through the \*arrs rather than restored.
- **Configuration drift** — a manifest, a variable, a firewall rule —
  reconciles from git. Revert the commit; do not restore a file over the
  top of a GitOps-managed path, because the next sync will simply put it
  back.
