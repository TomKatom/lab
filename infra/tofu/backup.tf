# The nightly vzdump job — the first thing in this repo that actually
# produces a backup. ansible/roles/pbs built the destination (PBS itself, the
# B2-backed `lab` datastore, the PVE storage entry named below); until this
# resource exists that destination stays empty.
#
# WHY THIS IS TOFU WHEN THE STORAGE ENTRY IS ANSIBLE: the storage entry needs
# the PBS API certificate fingerprint, which does not exist until PBS has been
# installed and generated it — see roles/pbs's header for the ordering knot
# that creates. A backup job needs nothing a later layer produces, so it
# belongs here with the rest of the PVE configuration.
resource "proxmox_backup_job" "guests_nightly" {
  # Changing this id replaces the job (destroy + create). Harmless — a job
  # holds no data and the snapshots in PBS are keyed by guest, not by job —
  # but it is not a label to tidy up later either.
  id   = "lab-guests-nightly"
  node = var.node_name

  # roles/pbs prunes at 06:00 and verifies Sunday 07:00, both deliberately
  # after this window: prune has nothing to unreference until the night's
  # snapshot exists, and verify should read back what was just written.
  schedule = "04:00"

  # Named once in config/lab.yml because roles/pbs creates this storage and
  # this job consumes it, and PVE checks neither: it accepts a job pointing
  # at a storage that does not exist and fails at 04:00 instead.
  storage = local.lab.pbs.storage_id

  # An explicit list, never `all = true` (the provider treats the two as
  # mutually exclusive). ci-runner (9001) is deliberately disposable — it
  # re-registers from GH_RUNNER_PAT — so leaving it out is a decision, and an
  # explicit list makes adding a future guest to the backup set a visible
  # diff rather than a side effect of creating a VM.
  vmid = [tostring(var.vm_id)]

  # snapshot mode plus the qemu-guest-agent (installed by roles/hardening) is
  # what makes the live databases inside the guest safe to capture without
  # stopping anything: PVE fsfreeze's the guest filesystems for the instant
  # the snapshot is taken, so the *arr SQLite DBs, Plex's metadata and
  # Deluge's session state come out as a consistent point-in-time image
  # rather than a torn copy. The alternatives stop or suspend the guest.
  mode = "snapshot"

  # Stated rather than inherited, so a job switched off by hand in the PVE UI
  # comes back on at the next apply.
  enabled = true

  # A host that is down or rebooting at 04:00 otherwise skips the night
  # outright, and the gap only surfaces 36 h later as PR 6's BackupStale
  # alert. This turns a reboot into a late backup instead of a missing one.
  repeat_missed = true

  # Becomes the snapshot's comment in PBS, which is what a restore picks
  # from. Only {{cluster}}, {{guestname}}, {{node}} and {{vmid}} are
  # substituted; PVE rejects anything else when the job is created.
  notes_template = "{{guestname}}"

  # Deliberately unset, each for a reason that is not visible from here:
  #
  #   prune_backups — retention is defined exactly once, in roles/pbs's PBS
  #     prune job. Setting it here would make PVE prune over the API as
  #     pve-backup@pbs, whose DatastoreBackup role cannot prune by design, so
  #     every run would end in an error (roles/pbs's defaults say the same
  #     thing from the other side).
  #
  #   compress / zstd / pigz — a PBS target ignores them; the backup client
  #     compresses its own chunks. Setting one would only imply otherwise.
  #
  #   mailto / mailnotification — there is no MTA on this host, and a failed
  #     vzdump is a PVE-side event that roles/pbs's Telegram webhook never
  #     sees (it is a PBS notifier: verify, GC, prune). Until PR 6 scrapes
  #     backup age into Prometheus, a failing job is silent — that is the gap
  #     PR 6 closes, not something configurable here.
  #
  #   fleecing — revisit only if the first runs stall guest I/O. In snapshot
  #     mode a guest write to a not-yet-backed-up block waits for that block
  #     to reach the target, and the target here is object storage over the
  #     internet; fleecing parks those blocks on a local image instead. It
  #     needs a storage of its own, so it stays off until there is evidence.
  #
  #   tmpdir / script / dumpdir — only root@pam may set these and Tofu
  #     authenticates as terraform@pve!tofu, so adding one turns every apply
  #     into a permission error.
}
