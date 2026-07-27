# Runbook: media state migration (old server → this cluster)

How to move the *state* the old hand-built docker-compose media stack has
accumulated — media files, `*arr` databases, Plex's identity and watch
history, Deluge's session and active seeds — onto the Phase 6 apps running
in the `media` namespace on this cluster. See
[`docs/architecture.md`](../architecture.md) and
[`master-plan.md`](../../master-plan.md#phased-implementation-each-phase--its-own-pr)
for how Phase 6 fits the rest of the build.

This is an **operator-executed** runbook: every command below runs on your
laptop, on the Proxmox host, or inside the k3s VM — all over WireGuard, per
[`docs/runbooks/wireguard-peer.md`](wireguard-peer.md). Nothing here is run
by CI or by an agent.

> **Golden invariant.** The old server (`94.75.211.144`) stays **fully
> operational** — serving `tomkatom.com` and the `sonarr./radarr./prowlarr./
> deluge.` CNAMEs — for the entire length of this runbook, up to and
> including §11's final pipeline cutover. Nothing here changes public DNS.
> Moving public traffic onto this cluster is a **separate, later** runbook —
> [`dns-cutover.md`](dns-cutover.md) — out of scope here and not to be
> executed until an operator deliberately picks it up.

---

## 1. Scope & sequencing map

Each app's restore section depends on that app's Phase 6 PR having merged
(its Argo `Application` and chart exist in `clusters/lab/apps/`) — see the
PR table in the phase's planning record. §2 and §3 need nothing and should
start immediately; the multi-day rsync in §3 is the long pole of the whole
migration, so start it the same day this runbook is picked up.

| Section | Gated on | When it runs |
|---|---|---|
| §2 Old-server inventory | — | now (read-only) |
| §3 Bulk media rsync | — | now — multi-day, old server stays live |
| §4 Generic restore procedure | `media-common` merged (PR3) | a template §5–§10 each reference, not a step on its own |
| §5 Prowlarr | prowlarr merged (PR5) | once §3 is substantially caught up |
| §6 Sonarr / Radarr | sonarr+radarr merged (PR6) | ″ |
| §7 Bazarr | bazarr merged (PR7) | ″ |
| §8 Plex | plex merged (PR8) | ″ |
| §9 Seerr / Tautulli / Maintainerr | plex + request-layer merged (PR8, PR9) | ″ |
| §10 Deluge | deluge merged (PR4) | **executed last** — only as part of §11's cutover |
| §11 Delta syncs + pipeline cutover | every app above restored once | the final pass; runs §10 |
| §12 Post-migration hardening | after §11 | cluster is now authoritative for pipeline state |
| §13 Verification table | after §11/§12 | acceptance |

Two things this runbook deliberately never does: it never touches Cloudflare
or `external-dns`, and §10 (Deluge) is the one section that is *not*
independent — it is written to run only as the last act of §11, once the old
server's `*arr`s and Deluge have already stopped writing.

---

## 2. Old-server inventory (read-only)

Nothing in this section changes anything. It only records values the later
sections and Phase 6's PR3 (`media-common`) consume verbatim.

### 2.1 Per-app config directories and sizes

The old stack is hand-built docker-compose, not IaC — one directory per app
under `/srv`, each holding that app's `docker-compose.yml` beside its state
directory. The layout is **already known** (operator-supplied, 2026-07-25);
every path in this runbook is written against it:

```
/srv/<app>/config          # every migrating app except the two below
/srv/portainer/data        # not migrating
/srv/traefik/data          # not migrating
/srv/deluge/config-backup  # a sibling of deluge's config — see §10
/srv/unpackerr/            # docker-compose.yml only, no state at all
```

(`old` here is a suggested `~/.ssh/config` alias for `94.75.211.144` — add
one now, the same convention `wireguard-peer.md` §5a uses for
`pve`/`k3s`/`runner`. §3's rsync and every `old:` reference below assume it
exists.)

⚠ **`/srv/overserr` is spelled with one `e`** on the old server — a typo
baked into the directory name years ago. Every `old:` path for Overseerr in
this runbook uses `overserr` deliberately; "correcting" it to `overseerr`
gives you an rsync against a nonexistent source, which succeeds at copying
nothing.

⚠ **The old server runs Overseerr; the cluster runs Seerr.** Overseerr was
archived in July 2026 when it merged with Jellyseerr into Seerr, so
`clusters/lab/apps/seerr.yaml` deploys the successor and Seerr migrates the
restored Overseerr config on its first start (§9). That means this one app
is named differently on each side — source `/srv/overserr/config`,
destination the `seerr` PVC — everywhere below.

Confirm the layout still matches and size each config dir — the sizes are
what the per-app PVC sizes in the Phase 6 reference table were bookkept
against:

```sh
ssh old 'ls -1 /srv && du -sh /srv/*/config /srv/*/data'
```

Cross-check that each container really mounts the directory named after it
(the mapping is conventional here, not enforced by anything):

```sh
ssh old '
  for c in deluge prowlarr sonarr radarr bazarr plex overseerr unpackerr; do
    echo "== $c"
    docker inspect "$c" --format "{{json .Mounts}}" | jq -r ".[] | \"\(.Source) -> \(.Destination)\""
  done
'
```

Expect each app to mount `/srv/<app>/config → /config` (Overseerr's
destination is `/app/config`) and the media apps to additionally mount
`/data → /data`. That second mount is what makes §6's root-folder check a
formality rather than a path rewrite.

| App | Config dir (old server) | Size | Notes |
|---|---|---|---|
| Deluge | `/srv/deluge/config` | | `config-backup` sibling stays behind — §10 |
| Prowlarr | `/srv/prowlarr/config` | | |
| Sonarr | `/srv/sonarr/config` | | |
| Radarr | `/srv/radarr/config` | | |
| Bazarr | `/srv/bazarr/config` | | key lives deeper than the others — §2.2 |
| Plex | `/srv/plex/config` | | app-support subtree only — see §8 |
| Overseerr | `/srv/overserr/config` | | **one `e`** — see the warning above; restores into the cluster's `seerr` app (§9) |
| Unpackerr | — | — | no state; its config becomes env in PR4 |

**Nothing to migrate for four of the twelve `/srv` directories.** The
cluster already replaces each, so they are deliberately left behind and
die with the old server:

| Old `/srv` dir | Replaced by |
|---|---|
| `authelia` | the `authelia` namespace (Phase 5) — new file users + fresh TOTP enrolment, no state carried |
| `traefik` | the `traefik` namespace (Phase 5) — cert-manager issues the wildcard, so `traefik/data`'s acme store is obsolete |
| `portainer` | Argo CD — the cluster's management surface |
| `watchtower` | Renovate — image bumps arrive as reviewable PRs, not unattended pulls. See §11.1: stop it *first* at cutover |

### 2.2 The four `*arr` API keys

Prowlarr/Sonarr/Radarr each keep their API key in a `config.xml` at the root
of their config dir. **Bazarr does not** — it is not a \*arr fork and stores
its settings under a nested `config/` subdirectory instead, as
`config.yaml` (v1.4.3+) or `config.ini` (older). Pull the three, then Bazarr
separately:

```sh
ssh old '
  for c in prowlarr sonarr radarr; do
    printf "%-10s " "$c"
    grep -oP "(?<=<ApiKey>).*(?=</ApiKey>)" "/srv/$c/config/config.xml"
  done
'

ssh old 'ls -1 /srv/bazarr/config/config/ && grep -riA2 "^\[*auth" /srv/bazarr/config/config/config.*'
```

Bazarr's key is the `apikey` value under the `auth` section, in whichever of
the two formats that directory turns out to hold. If the `grep` comes back
empty, read it out of the UI instead (Settings → General → API key) — §7
re-reads it from the *restored* app anyway, and treats that value as
authoritative over whatever this step recorded.

These four values become PR3's `clusters/lab/apps/media-common/
arr-api-keys.sops.yaml` — pinned **as-is**, not rotated, so every existing
cross-reference (Prowlarr's app-sync, Seerr, Unpackerr) keeps working
with zero key surgery after restore:

| SOPS key (`arr-api-keys` Secret) | Value source |
|---|---|
| `SONARR_API_KEY` | Sonarr's `config.xml` `<ApiKey>` |
| `RADARR_API_KEY` | Radarr's `config.xml` `<ApiKey>` |
| `PROWLARR_API_KEY` | Prowlarr's `config.xml` `<ApiKey>` |
| `BAZARR_API_KEY` | Bazarr's `apikey` under `auth` in `/srv/bazarr/config/config/config.{yaml,ini}` — see §7's caveat: Bazarr can drift from this value at runtime |

Edit them in with `sops clusters/lab/apps/media-common/
arr-api-keys.sops.yaml` once PR3 has merged (its placeholder gate says
exactly this).

> **⚠ Type every value as a quoted string** — `"a1b2c3…"`, not `a1b2c3…`.
> See the box in §2.5: an all-digit key entered bare re-encrypts as a
> number and the Secret then fails to apply.

### 2.3 Deluge: listen port and path layout — verify, don't assume

```sh
ssh old 'grep -E "listen_ports|random_port|download_location|move_completed|torrentfiles_location|copy_torrent_file|autoadd_location" \
  /srv/deluge/config/core.conf'
```

Record the listen port (expected `51413` — `config/lab.yml`'s
`ports.torrent`, the port-preserving NAT contract this whole stack depends
on) and, critically, whether `download_location`/`move_completed_path`
already point at `/data/torrents/...`/`/data/media/...` (TRaSH-style
layout). The top-level shape of `/data` (§2.4) says they do, but the shape
of a directory tree is not proof of what a config file says — **read the
values, don't infer them.** §10 branches on the answer: if paths already
match, no rewrite is needed; if not, §10's bencode warning applies.

The extra keys in that `grep` exist because of `/data/torrents-final`
(§2.4): something on the old server writes `.torrent` files there, and
`torrentfiles_location` (with `copy_torrent_file` on) is the likeliest
owner. Record which setting points at it. §3 copies the whole `/data` tree,
so the directory arrives either way and the setting keeps working
unchanged after restore — this is only about knowing which knob it is, so
§10 doesn't accidentally "clean up" a path that is load-bearing.

### 2.4 The `/data` tree: ownership, shape, and size

The old server's `/data` is its own filesystem (it has a `lost+found`), with
three top-level directories:

```
/data/media/{movies,tv}   # the Plex libraries
/data/torrents/…          # completed downloads: category dirs + loose files
/data/torrents-final/     # .torrent files — see §2.3
/data/lost+found          # fsck artifact, NOT migrated — §3 excludes it
```

This matches the TRaSH layout the cluster expects (`docs/architecture.md`'s
"Single `/data` tree"), so the mount path is identical on both sides and no
library or download-client path rewrite is needed. Two details worth
knowing before §3:

- `/data/torrents` mixes category subdirectories (`movies`, `tv`, `music`,
  `books`, `games`, `programs`) with loose per-release directories and
  files sitting directly at its root. That's fine — §3 copies the tree
  wholesale and never enumerates it.
- At least one entry there is a **symlink** (`smash.7z` → a file in the
  same directory). `rsync -a` implies `-l`, which recreates symlinks as
  symlinks rather than following them, and a same-directory relative target
  lands intact. No special handling needed; just don't add `-L`.

Record ownership and size:

```sh
ssh old 'stat -c "%u:%g %a %n" /data /data/media /data/torrents /data/torrents-final'
ssh old 'du -sh /data/*  &&  df -h /data'
```

The new cluster's convention is **1000:1000** (`debian`, the owner of
`/data` on the k3s VM — see `clusters/lab/apps/README.md`'s identity
convention). §3 normalizes to this regardless of what the old server used;
recording it here just tells you whether that chown is a no-op or a real
change.

**Capacity pre-flight — do this before starting §3, not after it has run
for two days.** The destination is the `tank` pool: a **non-redundant
2-disk stripe over the 2×2 TB HDDs** (`ansible/roles/zfs_tank` asserts
exactly that shape), so ~3.6 TiB usable, minus ZFS overhead, plus whatever
`lz4` compression wins back on an already-compressed media library
(≈ nothing). On the Proxmox host:

```sh
ssh root@pve.lab.tomkatom.com 'zpool list tank && zfs list tank/data && df -h /tank/data'
```

If the `du -sh /data/*` total does not fit with room to spare, stop and
decide what is not coming across — §3 is a multi-day transfer and an
`ENOSPC` at 90 % is the worst possible time to have that conversation.
`/data/torrents` is the obvious candidate for pruning, but only for
torrents that are no longer seeding: deleting one that Deluge still tracks
means §10 restores a session whose data is gone, and the torrent
fails its recheck.

### 2.5 Telegram bot (feeds PR3's `telegram` Secret)

1. Message **@BotFather** on Telegram → `/newbot` → follow the prompts →
   record the bot token.
2. Add the new bot to the Telegram group the notifications should land in
   (the phase decision is a **group**, for multiple users — not a DM).
3. Send any message in that group so it appears in the bot's update queue,
   then fetch it:

   ```sh
   curl -s "https://api.telegram.org/bot<TOKEN>/getUpdates" | jq '.result[].message.chat'
   ```

   Expect an object with `"type": "group"` (or `"supergroup"`) and an `id`
   that is **negative** (or `-100`-prefixed for a supergroup) — that's
   correct, not an error; DM chat ids are positive.

| SOPS key (`telegram` Secret) | Value source |
|---|---|
| `TELEGRAM_BOT_TOKEN` | BotFather's token, step 1 |
| `TELEGRAM_CHAT_ID` | The group's `chat.id`, step 3 |

Edit them in with `sops clusters/lab/apps/media-common/telegram.sops.yaml`
once PR3 has merged.

> **⚠ Type every value as a quoted string.** In the `sops` editor write
> `TELEGRAM_CHAT_ID: "-1234567890"`, **with the quotes**. Bare, YAML reads
> it as a number and sops re-encrypts it as `type:int`; a number under
> `stringData` makes the whole Secret unappliable, and Argo drops it with
> `cannot unmarshal number into Go struct field Secret.stringData of type
> string` — the Secret never appears in the namespace while every other
> resource in the overlay applies normally, so `kubectl get ns media`
> looks healthy and only the one Secret is missing. This bit for real on
> the first fill of this file. CI now rejects it at PR time; if the check
> named **sops Secret values are all strings** fails, this is why —
> re-open the file and quote the value.
>
> Verify before committing, without printing the secret:
>
> ```sh
> grep -c 'type:str]' clusters/lab/apps/media-common/telegram.sops.yaml
> # 3 — both values plus the sops mac. Any 'type:int]' is the bug above.
> ```

---

## 3. Bulk media rsync — start immediately, runs days

Run this **on the Proxmox host**, over WireGuard (`ssh
root@pve.lab.tomkatom.com`), not from the k3s VM: `/tank/data` is a host
path (`ansible/roles/zfs_tank`), shared into the VM by virtiofs at `/data`
(`ansible/roles/virtiofs`) — writing directly to the host path avoids an
extra network hop through the virtiofs boundary for a transfer this size.

The new host's SSH is WireGuard-only by design (no public management
surface), so a push *from* the old server would need inbound access this
host will never grant. **Pull, don't push** — the Proxmox host reaches out
to the old server instead, which is fine because the old server still has
its own public SSH.

### 3.1 Pre-flight: the new host needs its own path to `old`

The old server is a **VM (`old`) on its own Proxmox host (`old-pve`)**, and
`/data` is a virtual disk *inside that VM* — not a bind mount visible on
`old-pve`. So there is no shorter route: the transfer runs
new-pve → `old-pve` → `old`, with `old-pve` relaying.

Your laptop's `~/.ssh/config` does not help here. The rsync runs as **root
on the new Proxmox host**, so `old` must resolve in *that* host's SSH
config, with a key that host holds. Agent forwarding is not a substitute —
it dies with your SSH session, and this transfer outlives it by days.

1. **Mint a dedicated key on the new host.** Passphrase-less, because an
   unattended multi-day job cannot answer a prompt. It is removed again in
   §12:

   ```sh
   ssh root@pve.lab.tomkatom.com \
     "ssh-keygen -t ed25519 -N '' -f /root/.ssh/id_migration -C pve-media-migration"
   ```

2. **Authorize it on *both* hops** — `old-pve` to make the jump, `old` as
   the destination. Run from your laptop, which already reaches both. The
   `grep` guard keeps a re-run from appending a duplicate:

   ```sh
   PUB=$(ssh root@pve.lab.tomkatom.com 'cat /root/.ssh/id_migration.pub')
   for h in old-pve old; do
     ssh "$h" "mkdir -p ~/.ssh && chmod 700 ~/.ssh && \
       grep -qxF '$PUB' ~/.ssh/authorized_keys 2>/dev/null || \
       printf '%s\n' '$PUB' >> ~/.ssh/authorized_keys; \
       chmod 600 ~/.ssh/authorized_keys"
   done
   ```

3. **Copy your laptop's working host definitions to the new host**, rather
   than retyping addresses from memory. `ssh -G` prints the *effective*
   resolved config, so this reads back exactly what already works:

   ```sh
   ssh -G old-pve | grep -E '^(hostname|user|port) '
   ssh -G old     | grep -E '^(hostname|user|port|proxyjump) '
   ```

   Write `/root/.ssh/config` on the new host with those values:

   ```
   Host old-pve
       HostName <hostname from old-pve above>
       User <user>
       IdentityFile /root/.ssh/id_migration
       IdentitiesOnly yes

   Host old
       HostName <hostname from old above — as reachable from old-pve>
       User <user>
       ProxyJump old-pve
       IdentityFile /root/.ssh/id_migration
       IdentitiesOnly yes
       ServerAliveInterval 60
       ServerAliveCountMax 3
   ```

   `IdentitiesOnly yes` stops SSH offering every other key on the host and
   tripping `MaxAuthTries` before it reaches this one. The `ServerAlive*`
   pair kills a wedged connection in ~3 minutes instead of letting it hang
   for hours — which matters because §3.2 retries on exit, and a hung
   transfer never exits.

4. **Prove it works non-interactively.** `BatchMode=yes` fails instead of
   prompting, so this cannot pass merely because you were sitting there:

   ```sh
   ssh root@pve.lab.tomkatom.com \
     'ssh -o BatchMode=yes old "hostname && df -h /data && ls /data"'
   ```

   Expect the VM's hostname and the `media`/`torrents`/`torrents-final`
   listing from §2.4. Anything that prompts, hangs, or asks about a host
   key is a problem to fix **now**, not sixteen hours into a transfer.

5. **Dry-run the real command** — this also gives you the total byte count
   to check against §2.4's capacity numbers before committing days to it:

   ```sh
   rsync -aHn --info=stats2 --exclude='/lost+found/' old:/data/ /tank/data/
   ```

### 3.2 The transfer

```sh
tmux new -s media-rsync   # this runs for days; don't let a dropped SSH kill it
until rsync -aH --info=progress2 --partial-dir=.rsync-partial \
        --exclude='/lost+found/' old:/data/ /tank/data/; do
  echo "rsync exited $? — retrying in 60s"; sleep 60
done
```

The retry loop is there because the jump doubles the failure surface:
`old-pve`'s sshd restarting, or the relay dropping, kills the run outright,
and losing a day of transfer to a five-second blip is avoidable. **Retrying
is safe for hardlinks** — each attempt is a fresh whole-tree pass, so `-H`
still sees both halves of every pair (see the constraint below).

`--partial-dir` keeps an interrupted file's bytes so the retry resumes it
instead of starting that file over — worth having when single files run to
tens of gigabytes. It stashes them in a side directory rather than leaving
a truncated file sitting at the real path, and rsync excludes that
directory from its own transfer automatically.

Do watch it rather than trusting the loop: it will happily spin forever on
something real and permanent, like a full pool. If the same error repeats
twice, stop and read it.

The exclusion is anchored (leading `/`) so it drops only the source
filesystem's own `lost+found` at the root of `/data` — an artifact of the
old server's fsck, meaningless on a ZFS destination — without matching a
directory of that name anywhere deeper in the tree. Everything else comes
across: `media/`, `torrents/`, and `torrents-final/` (§2.3).

**This must be one single whole-tree invocation.** `-H` (preserve
hardlinks) only detects and re-links hardlinked files *within the files
rsync sees in that one run* — splitting `torrents/` and `media/` into two
separate `rsync` calls means rsync never sees both halves of a hardlinked
pair at once, and every hardlink-imported file silently becomes two
independent copies on the new server. This is the single most important
constraint in this whole runbook; there is no partial-then-fix-up path once
it's been split.

The old server keeps serving throughout — this is a read-only pull against
it.

### 3.3 Ownership normalization

Once the transfer finishes (expect **days**, not hours, for a multi-TB
library):

```sh
mkdir -p /tank/data/backups
chown -R 1000:1000 /tank/data
chmod 2775 /tank/data /tank/data/torrents /tank/data/media /tank/data/torrents-final /tank/data/backups
```

`2775` (setgid) matches the virtiofs role's `virtiofs_dir_mode` default —
re-asserting it here guards against rsync's `-a` having carried over
different permission bits from the old server. Note what each path in that
list is for:

- `torrents` and `media` are the only two the `virtiofs` role creates
  itself (`virtiofs_subdirs`), so they may already exist with the right
  bits before rsync ever runs.
- `torrents-final` arrives from the old server (§2.4) and the role knows
  nothing about it — it needs the bits asserted here.
- `backups` does not exist on either side. It is created here because §6
  points Sonarr's and Radarr's built-in backups at `/data/backups/<app>`,
  and that is the local-path `Delete`-reclaim mitigation §12 depends on.
- `/tank/data` **itself** is in the list deliberately: the `zfs_tank` role
  creates the dataset but never sets ownership on its mountpoint, so it
  starts `root:root`. Without this chown, a pod running as 1000 cannot
  create anything at the root of `/data`.

Deltas (the transfer catching up on what changed since this pass) are §11's
job, not this one's — this first pass is allowed to be stale by the time it
finishes.

---

## 4. Generic per-app restore procedure

§5–§10 each say "follow this, with the specifics below" rather than
repeating it six times. Every restore is: stop Argo from fighting you, stop
the pod, copy config in, fix ownership, start the pod back up, hand control
back to Argo.

Everything below is driven with `kubectl` over WireGuard, not the Argo CD
CLI:

> ⚠ **`argocd` is not installed on `k3s-node`**, despite the Ansible
> `argocd` role that is supposed to put it there — found while running §5
> and §6 for real, and unexplained. Every `argocd app set` this procedure
> used to call is written below as the `kubectl -n argocd patch
> application` it performs anyway (the CLI only PATCHes the same
> `Application` CR). Nothing here is blocked by the gap, but fix it before
> someone reaches for `argocd app list --core` and finds nothing. Reaching
> the CLI from your own machine over a `kubectl -n argocd port-forward
> svc/argocd-server 8080:443` (`docs/bootstrap.md`) works and is equally
> valid — the patches below are simply the form that needs no CLI at all.

Then, for `<app>` being restored:

1. **Pause auto-sync — on the parent `apps` Application first, then on
   `<app>` — before anything else:**

   ```sh
   kubectl -n argocd patch application apps --type=merge \
     -p '{"spec":{"syncPolicy":{"automated":null}}}'
   kubectl -n argocd patch application <app> --type=merge \
     -p '{"spec":{"syncPolicy":{"automated":null}}}'
   ```

   ⚠ **The trap, and it has two layers.** Scale the Deployment down while
   `selfHeal` is on and Argo reverts the scale-down on its next reconcile —
   you end up fighting your own GitOps controller, and the pod flaps back
   up mid-copy. But **pausing `<app>` on its own does not hold**: this is an
   app-of-apps (`root-app` → `apps` → `<app>`) with `selfHeal` at every
   level, so the parent `apps` Application reconciles
   `clusters/lab/apps/<app>.yaml` — which still says `automated:` in git —
   back over your patch within about a second, and *that* revert is what
   re-arms the child's own self-heal to scale the Deployment straight back
   up. Pausing `apps` as well is what makes the pause stick.

   **Leave `root-app` alone.** It is an unrelated sibling covering
   `platform/` (Traefik, Authelia, cert-manager, external-dns); nothing in
   this runbook needs it paused, and pausing it stops platform drift
   correction for no benefit.

   Confirm the pause actually took, rather than assuming:

   ```sh
   kubectl -n argocd get application apps <app> \
     -o custom-columns=NAME:.metadata.name,AUTOMATED:.spec.syncPolicy.automated
   # both rows read <none>
   ```

2. Scale the Deployment to zero (releases the PVC's writer, and the app's
   sqlite DBs, so the copy in step 4 lands on a clean, unlocked file):

   ```sh
   kubectl -n media scale deploy <app> --replicas=0
   ```

3. Resolve which host directory backs the app's config PVC — never assume
   the naming pattern, read it back from the objects:

   ```sh
   kubectl -n media get pvc <app>              # confirm STATUS: Bound
   PV=$(kubectl -n media get pvc <app> -o jsonpath='{.spec.volumeName}')
   kubectl get pv "$PV" -o jsonpath='{.spec.hostPath.path}{"\n"}'
   # e.g. /var/lib/rancher/k3s/storage/pvc-<uid>_media_<app>
   ```

4. Copy the old app's config into that directory — **relayed through your
   own machine**, not pulled from the VM. The obvious one-liner
   (`rsync -a old:/srv/<app>/config/ …`, run on `k3s-node`) cannot work,
   for two independent reasons found while running §5 and §6 for real:

   - **`rsync` is not installed on `k3s-node`** (Debian trixie base image),
     so there is no binary to run there.
   - **`ssh k3s` has no route to `old`** — no key and no host entry for it.
     §3.1 deliberately provisioned that path on the *Proxmox host*, for the
     bulk transfer, and nowhere else.

   Your own machine already reaches both sides, so relay: `rsync` to pull,
   plain `tar` over `ssh` to push (the far end has no `rsync` to talk to).

   ```sh
   mkdir -p ~/migration-scratch/<app>
   rsync -a old:/srv/<app>/config/ ~/migration-scratch/<app>/

   tar cf - -C ~/migration-scratch/<app> . \
     | ssh debian@k3s.lab.tomkatom.com \
         'sudo tar xf - -C /var/lib/rancher/k3s/storage/pvc-<uid>_media_<app>'
   ```

   The remote `sudo` is not optional:
   `/var/lib/rancher/k3s/storage/` itself is not world-traversable, even
   though the leaf PVC directory under it is.

   ⚠ **On macOS, clear the AppleDouble litter before step 5.** BSD `tar`
   writes a `._*` sidecar into the archive for every file carrying extended
   attributes, and they arrive as junk in the app's config dir — the real
   restores deleted **593** of them for Sonarr and **646** for Radarr:

   ```sh
   ssh debian@k3s.lab.tomkatom.com \
     'sudo find /var/lib/rancher/k3s/storage/pvc-<uid>_media_<app> -name "._*" -delete'
   ```

   `<app>` is the same word on both sides for every app this template
   covers, with **one exception: the request portal, where the source is
   `/srv/overserr/config/` (§2.1's spelling warning) and the destination is
   the `seerr` PVC** — old Overseerr, new Seerr, neither spelled like the
   other. Plex does not use this step at all — §8 copies a subtree, not the
   whole config dir.

   **Installing `rsync` on `k3s-node` (via the Ansible roles that build it,
   not by hand) removes this relay entirely** — worth doing before the
   bigger copies, since Plex's config alone is 2.7 GB and every byte
   currently makes a round trip through your laptop.

   Delete the scratch copy once the push has succeeded — it is a full copy
   of an app's database, API keys included.

5. Fix ownership — the copy above lands as whatever the old server's uid/gid
   was (§2.4):

   ```sh
   ssh debian@k3s.lab.tomkatom.com \
     'sudo chown -R 1000:1000 /var/lib/rancher/k3s/storage/pvc-<uid>_media_<app>/'
   ```

6. Scale back up and verify (app-specific checks are in §5–§10; §13 has the
   final per-app assert):

   ```sh
   kubectl -n media scale deploy <app> --replicas=1
   kubectl -n media logs deploy/<app> -f     # watch it come up clean
   ```

   For any app with an Ingress, verify it over WireGuard the same way every
   other Phase 5/6 check does — resolve the public hostname at the internal
   IP, never over public DNS (nothing here is public yet):

   ```sh
   curl -sI --resolve <app>.tomkatom.com:443:10.10.10.10 https://<app>.tomkatom.com
   ```

   ⚠ **The UI checklists in §5–§9 cannot be done with `curl`, and a browser
   does not have `--resolve`.** Four of these hostnames already resolve —
   **to the old server**, which is still production:

   | Name | Public DNS today | What a browser gets |
   |---|---|---|
   | `sonarr.` `radarr.` `prowlarr.` `deluge.tomkatom.com` | `CNAME → tomkatom.com → 94.75.211.144` | **the old app**, with no error and nothing to tip you off |
   | `bazarr.` `tautulli.` `maintainerr.` `home.` `requests.` `auth.` | NXDOMAIN (there is no `*.tomkatom.com` record — the old server has a wildcard *certificate*, which is a different thing) | nothing resolves |

   So you can complete an entire §5/§6 checklist against **production** and
   change nothing on the cluster. Override the names locally instead, on the
   machine running the browser, while on WireGuard — in `/etc/hosts`:

   ```
   10.10.10.10  auth.tomkatom.com
   10.10.10.10  sonarr.tomkatom.com radarr.tomkatom.com prowlarr.tomkatom.com
   10.10.10.10  deluge.tomkatom.com bazarr.tomkatom.com tautulli.tomkatom.com
   10.10.10.10  maintainerr.tomkatom.com home.tomkatom.com requests.tomkatom.com
   ```

   One address may carry many names on a line, but **`/etc/hosts` has no
   line-continuation syntax** — a trailing `\` is parsed as part of a
   hostname, not as "continued below", and the entries after it silently do
   not resolve.

   **`auth.tomkatom.com` has to be in that list.** Every protected host 302s
   the *browser* to it, and it is NXDOMAIN publicly, so without the override
   the login redirect dead-ends and nothing above it is reachable either.

   The `*.lab.tomkatom.com` management names (`pve.`, `k3s.`) need no
   override — they are real public A records pointing at internal addresses.
   The app names are not in that scheme, and there is no split-horizon
   resolver here by design.

   **Remove these entries at DNS cutover** (`dns-cutover.md`), or they will
   mask a broken public record later: your browser will keep working off the
   override long after everyone else's has stopped.

7. Hand control back to Argo — child first, then the parent:

   ```sh
   kubectl -n argocd patch application <app> --type=merge \
     -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}'
   kubectl -n argocd patch application apps --type=merge \
     -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}'

   kubectl -n argocd get application apps <app> \
     -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status
   # both Synced / Healthy again
   ```

   Order matters only in that resuming `<app>` first means `apps` finds no
   drift to correct when it resumes — by then the child's `syncPolicy`
   already matches what git says.

---

## 5. Prowlarr (after PR5)

Follow §4 for `prowlarr`. Specifics:

- The env-pinned `PROWLARR_API_KEY` (from the `arr-api-keys` Secret, PR3)
  already equals the old key (§2.2) — nothing else needs to move for
  Prowlarr's own identity.
- Re-point every **Apps** entry (Settings → Apps) at the cluster DNS names,
  not the old server's addresses. The UI works, and so does Prowlarr's own
  API — `PUT /api/v1/applications/<id>` with only `baseUrl` changed is what
  the real restore used; send the masked `"********"` `apiKey` field back
  verbatim, which Prowlarr reads as "unchanged", exactly as its own UI does.
  The addresses:
  - Sonarr: `http://sonarr.media.svc.cluster.local:8989`
  - Radarr: `http://radarr.media.svc.cluster.local:7878`
- If any indexer used a FlareSolverr proxy, re-point it too:
  `http://flaresolverr.media.svc.cluster.local:8191`. PR5 marks FlareSolverr
  optional — if it wasn't deployed, remove the proxy reference from the
  indexer instead.
- Verify: Settings → Apps → each app shows a successful sync test, and
  Settings → Indexers → **Test All**. A red indexer here is almost always
  pre-existing credential rot — an expired session cookie, a dead tracker —
  rather than a migration fault: nothing in this restore touches indexer
  credentials. Judge it against how that indexer behaved on the old server
  before spending time on it.

---

## 6. Sonarr / Radarr (after PR6)

Near-identical twins — follow §4 once for `sonarr`, once for `radarr`.
Specifics for both:

- ⚠ **First thing after the pod comes up, before any other UI work: set
  Settings → Indexers → Options → RSS Sync Interval to `0`** (which disables
  it) on both apps. The restored database brings its indexers *and* its
  enabled RSS sync across with it, and the old server's Prowlarr is still
  publicly reachable — so within ~15 minutes the restored app starts
  grabbing releases **in parallel with the old server still doing the same
  job**: duplicate snatches against private trackers (which count them),
  duplicate downloads, and a `/data/media` on the cluster that drifts from
  the copy §11's final delta has to reconcile. **Restore the interval in
  §11**, as part of the cutover — not before, and **write down the value you
  are replacing** so there is something to restore it to. (On the real
  restore, Sonarr's had come across as `0` already and Radarr's as `30`, so
  the two apps do not necessarily match.)

- **Expected while the old server is still live — don't chase either:** the
  queue shows orphaned items belonging to the *old* Deluge, and health
  checks complain about the download client until the re-point below (and
  about an empty Deluge until §10 restores its session). Both clear
  themselves at cutover.

- The restored config dir includes the sqlite DB and `config.xml`. **The
  env override (`SONARR__AUTH__APIKEY` / `RADARR__AUTH__APIKEY`, from PR3's
  `arr-api-keys` Secret) wins over `config.xml` at startup** — this is
  exactly why §2.2 pinned the SOPS value to equal the old key: if they
  diverged, every dependent (Prowlarr's app-sync, Seerr, Unpackerr)
  would start authenticating with the wrong key against the migrated app.
- Re-point the download client (Settings → Download Clients → Deluge):
  Host `deluge.media.svc.cluster.local`, Port `8112`. The app's own REST API
  is an equally good route and is what the real restore used — `PUT
  /api/v3/downloadclient/<id>` with only the `host` field changed and
  `X-Api-Key` set to the value in `arr-api-keys`.

  Either way, **the save's live client test fails until §10 restores
  Deluge's own config**, with Deluge rejecting the `TvCategory` /
  `MovieCategory` field as "Label plugin not activated" — the Label plugin
  is enabled in Deluge's config, which does not exist on the cluster yet.
  That error is itself proof the host and port are right: nothing reached
  Deluge would have produced it. Persist the change anyway (`?forceSave=true`
  on the API call, or the UI's save-regardless prompt) and re-test after §10.
- Verify root folders are unchanged (Settings → Media Management → Root
  Folders): **`/data/media/tv` for Sonarr, `/data/media/movies` for
  Radarr** — the old server's actual layout (§2.4), and identical on the
  cluster because both mount the same `/data` tree at the same path. This
  is a check, not an edit, unless §2.1's `docker inspect` turned up a
  container mount destination other than `/data`.
- **Delete any Remote Path Mappings** (Settings → Download Clients → Remote
  Path Mappings). They existed on the old server to translate between
  Deluge's and the `*arr`'s different container mount paths; on the
  cluster every app mounts the identical `/data` hostPath, so a mapping now
  actively breaks the hardlink import instead of fixing anything.
- Enable the built-in backup (Settings → General → Backups), pointed at
  `/data/backups/sonarr` (respectively `/data/backups/radarr`) — this is
  the local-path Delete-reclaim mitigation carried into §12.
- Verify the Plex Connect notification entry (Settings → Connect) points at
  `http://plex.media.svc.cluster.local:32400`.
- Confirm a hardlink import: pick any file already imported into the
  library and check `stat -c %h` is **≥ 2** for the same file under
  `/data/torrents/...` and `/data/media/...` — the master-plan's same-inode
  acceptance, repeated per-app in §13.

---

## 7. Bazarr (after PR7)

Follow §4 for `bazarr`. Specifics:

- ⚠ **First, disable the scheduled subtitle search** (Settings → Scheduler →
  the "Search for Missing Subtitles" tasks → Never/disabled). This is
  Bazarr's version of §6's RSS-sync race: the old server's Bazarr is still
  running the same searches against the same providers, so leaving both on
  burns limited provider quota re-fetching subtitles the old server is
  fetching too, and writes them into a `/data/media` tree §11's final delta
  then has to reconcile. **Re-enable it in §11**, with the `*arr`s' RSS
  sync.
  A manual search on a single title still works meanwhile — that is how the
  verification at the end of this section is done.

The one honest gap in this whole runbook:

- **Bazarr's API key lives only in its own config — there is no env
  override for it**, unlike Sonarr/Radarr/Prowlarr. That means after
  restore, Bazarr's real key is whatever its restored config says, and the
  pinned `BAZARR_API_KEY` in `arr-api-keys.sops.yaml` (§2.2) may no longer
  match it if it ever drifted on the old server. **Align the SOPS value
  with reality, not the other way round** — read the key back from the
  restored app (Settings → General → API key, or `grep` the config file
  directly) and `sops`-edit `arr-api-keys.sops.yaml` to match it if they
  differ. Nothing consumes `BAZARR_API_KEY` as an env override into Bazarr
  itself — the Secret only exists so *other* apps (e.g. a future Homepage
  widget) can read Bazarr's key without a second copy.
- Re-point Bazarr's own Sonarr/Radarr connections (Settings → Sonarr /
  Settings → Radarr): `sonarr.media.svc.cluster.local:8989` and
  `radarr.media.svc.cluster.local:7878`, with `SONARR_API_KEY`/
  `RADARR_API_KEY` as the API key fields.
- Verify: the Series/Movies lists populate from Sonarr/Radarr again, and a
  subtitle search/download succeeds against a title already in the library.

---

## 8. Plex (after PR8)

⚠ **This is the one restore that is a real, one-way, user-visible cutover.
Schedule it deliberately.** Everything before it is reversible — the old
server keeps serving while a cluster app is restored alongside it. Plex is
not, for three reasons that compound:

- **It needs no DNS at all**, so nothing gates it. plex.tv brokers clients
  straight to `145.239.3.55:32400`, already DNAT'd to the node
  (`config/lab.yml`'s `ports.plex`), and Plex has no Ingress and no DNS
  record — `clusters/lab/apps/plex.yaml` deliberately declares none. There
  is no "restore it now, expose it later" step.
- **The old Plex must be stopped first** — two servers must never share one
  machine identity, and the copy below has to capture a database that is
  not being written to.
- **So the moment this section completes, end users are streaming from the
  cluster**, against a library frozen at the last rsync (§3) until §11's
  deltas catch it up. Anything grabbed on the old server in between is
  missing until then.

Plex's restore is therefore ordered differently from §4, starting with that
stop.

1. `ssh old` and stop Watchtower first, then Plex:

   ```sh
   ssh old '
     docker compose -f /srv/watchtower/docker-compose.yml down
     docker compose -f /srv/plex/docker-compose.yml stop
   '
   ```

   Watchtower goes first because it recreates containers on its own
   schedule when a new image appears. It only ever acts on *running*
   containers, so a stopped Plex will not be resurrected by it — but a
   Watchtower-triggered recreate landing in the middle of the copy below
   would capture the database mid-write, which is precisely what stopping
   Plex was meant to prevent. It stays down from here on: the cluster's
   image updates come from Renovate PRs (§2.1).
2. Then follow §4's steps 1–3 for `plex` (sync-policy off, scale to zero,
   resolve the PVC's host path).
3. Copy Plex's Application Support tree in, **excluding `Cache/`** — this is
   the single biggest disk-growth lever available at migration time:

   ```sh
   rsync -a --exclude='Cache/' \
     'old:/srv/plex/config/Library/Application Support/Plex Media Server/' \
     '/var/lib/rancher/k3s/storage/pvc-<uid>_media_plex/Library/Application Support/Plex Media Server/'
   ```

   Confirm the source path resolves before running the copy — the quoting
   above matters, the path has spaces in it:

   ```sh
   ssh old 'ls -d "/srv/plex/config/Library/Application Support/Plex Media Server"'
   ```

   **Verified against the pinned image** (PR8): the image config of
   `ghcr.io/home-operations/plex:1.43.3.10828` sets
   `PLEX_MEDIA_SERVER_APPLICATION_SUPPORT_DIR=/config/Library/Application Support`,
   and its `/entrypoint.sh` reads `Preferences.xml` from
   `${PLEX_MEDIA_SERVER_APPLICATION_SUPPORT_DIR}/Plex Media Server/` — so
   the destination above is the layout the pinned image actually uses, not
   an assumption carried from other images.
4. `chown -R 1000:1000` the PVC directory, then scale Plex back up.
5. **Identity check — this is what makes the whole migration low-risk for
   Plex specifically.** `Preferences.xml`'s `ProcessedMachineIdentifier`
   came across with the copy, so the new pod claims the *same* server
   identity as the old one — no re-claim through plex.tv, and watch history
   (tied to that identity) survives intact. Confirm it:

   ```sh
   grep -o 'ProcessedMachineIdentifier="[^"]*"' \
     '/var/lib/rancher/k3s/storage/pvc-<uid>_media_plex/Library/Application Support/Plex Media Server/Preferences.xml'
   curl -s http://10.10.10.10:32400/identity   # over WG — Plex has no Ingress
   ```

   Both must report the same machine identifier. (Plex only answers
   `/identity` unauthenticated once claimed — if this returns an auth
   challenge instead, the identity did not carry over; stop and re-check the
   copy before going further.)
6. If §2's inventory shows the old media path differed from `/data/media`,
   fix each library's path (Settings → Manage → Libraries → Edit → path) —
   otherwise this is a no-op, since the mount is identical.
7. **Make sure the old Plex can never come back up** — two servers sharing
   one Plex identity is a supported-nowhere state that corrupts both. A
   `docker compose stop` is not enough on its own: the compose file almost
   certainly carries `restart: unless-stopped` or `always`, and `always`
   brings the container back the next time the Docker daemon or the server
   restarts. Take the container away entirely:

   ```sh
   ssh old '
     docker compose -f /srv/plex/docker-compose.yml down
     docker ps -a --filter name=plex   # expect no rows
   '
   ```

   `down` removes the container while leaving `/srv/plex/config` untouched
   on disk, so the old state is still there as a fallback if step 5's
   identity check fails.
8. Enable scheduled library scans (Settings → Library → "Update my library
   periodically", e.g. every hour). virtiofs has no reliable inotify (see
   `docs/architecture.md`'s risk list), so this — plus the `*arr`→Plex
   Connect notification already verified in §6 — is the actual refresh
   path, not filesystem-event auto-detection.
9. Disable video preview thumbnail generation (Settings → Library →
   "Generate video preview thumbnails" → Never). This is a disk-growth
   control (§12 tracks growth going forward), not a functional requirement.
10. **Re-point the transcoder directory** (Settings → Transcoder →
    "Transcoder temporary directory") to `/transcode`, the emptyDir
    `clusters/lab/apps/plex.yaml` mounts. The image's entrypoint sets this
    preference *only when it is empty*, so the restored `Preferences.xml`
    keeps whatever `TranscoderTempDirectory` the old container used — and
    if that path does not exist in the pod, every transcode fails while
    direct play keeps working, which makes it easy to miss. Confirm:

    ```sh
    grep -o 'TranscoderTempDirectory="[^"]*"' \
      '/var/lib/rancher/k3s/storage/pvc-<uid>_media_plex/Library/Application Support/Plex Media Server/Preferences.xml'
    ```

    An empty result is fine — it means the entrypoint will set `/transcode`
    itself on the next start.

---

## 9. Seerr / Tautulli / Maintainerr (after PR8, PR9)

**Seerr** — follow §4 for `seerr` (config PVC mounted at `/app/config`).
This is the one app whose old and new names differ: the cluster runs Seerr,
the archived Overseerr's successor, and it converts the old config on its
first start. Two departures from the §4 template, both in step 4:

- **The source is `/srv/overserr/config/`** (one `e` — §2.1) and the
  destination is the `seerr` PVC, so §4's relay runs with a different word
  at each end:

  ```sh
  mkdir -p ~/migration-scratch/seerr
  rsync -a old:/srv/overserr/config/ ~/migration-scratch/seerr/

  tar cf - -C ~/migration-scratch/seerr . \
    | ssh debian@k3s.lab.tomkatom.com \
        'sudo tar xf - -C /var/lib/rancher/k3s/storage/pvc-<uid>_media_seerr'
  ```

  Everything else in step 4 still applies — the macOS `._*` sweep included.
  `settings.json` and the sqlite db under `db/` are what carry the state.
  The Plex auth token lives in `settings.json` and survives because Plex's
  identity survived §8 — no re-authentication needed.

- **Take a copy of the restored directory before scaling the pod back up.**
  Seerr's first start runs `server/lib/overseerrMerge.ts`, which recognises
  an Overseerr config by its missing `mediaServerType` and rewrites the
  sqlite schema **in place**. There is no downgrade path afterwards, and an
  interrupted rewrite leaves a half-migrated db. Pull it back off the VM
  rather than leaving it beside the live PVC:

  ```sh
  ssh debian@k3s.lab.tomkatom.com \
    'sudo tar cf - -C /var/lib/rancher/k3s/storage/pvc-<uid>_media_seerr .' \
    > ~/overseerr-config-pre-seerr.tar
  ```

  Keep it until the checks below pass; it goes back the same way the copy
  above went in. `~/migration-scratch/seerr/` is the same bytes and can
  serve instead — but §4 tells you to delete it (it holds the Plex token),
  so do not rely on it surviving. `/srv/overserr` on the old server is a
  second fallback: nothing in this runbook deletes it.

Then, after §4's step 6 scales the Deployment back up:

- Watch the migration run. It logs under the `Seerr Migration` label and
  ends with `Yeah! Overseerr to Seerr migration completed successfully!`:

  ```sh
  kubectl -n media logs deploy/seerr -f
  ```

  It runs exactly once — `mediaServerType` is set by the time it finishes,
  so every later restart skips it. A `Failed to …` line under that label
  means the pod exited mid-migration: restore the tarball above over the
  PVC directory before retrying, not on top of a partially migrated db.
- The migration also renames the application title `Overseerr` → `Seerr`
  and defaults the media server type to Plex. Users, requests, issues and
  their Plex accounts come across with the db; nothing is re-entered.
- Re-point Plex/Sonarr/Radarr hostnames (Settings → Services → each entry):
  `plex.media.svc.cluster.local:32400`, `sonarr.media.svc.cluster.local:8989`,
  `radarr.media.svc.cluster.local:7878`, with `SONARR_API_KEY`/
  `RADARR_API_KEY` where an API key field is asked for.
- Configure the Telegram agent in the UI (Settings → Notifications →
  Telegram): bot token = `TELEGRAM_BOT_TOKEN`, chat id = `TELEGRAM_CHAT_ID`
  (the group, §2.5), notification type **Media Available** enabled.
- Verify Seerr's own login still works unauthenticated by Authelia (its
  Ingress carries no forward-auth annotation by design — Plex OAuth is the
  end-user login, per the phase's decision).

**Tautulli** — follow §4 for `tautulli` (config PVC 5Gi at `/config`):

- Restore the history db (`tautulli.db`) from the old config dir.
- Re-point Plex (Settings → Plex Media Server): host
  `plex.media.svc.cluster.local`, port `32400`. Run "Verify Server" — it
  should reconnect cleanly since the restored db already has the working
  auth token.
- Configure the recently-added digest to the same Telegram group (Settings
  → Notification Agents → Telegram, same bot token/chat id as Seerr;
  enable the "Recently Added" trigger on whatever schedule is wanted).

**Maintainerr** — fresh setup, nothing to restore (its rules are UI-only,
no export/import path exists):

- Add the Plex server: `plex.media.svc.cluster.local:32400`.
- Add Sonarr/Radarr with `SONARR_API_KEY`/`RADARR_API_KEY`.
- Rules that key off *who requested something* need the request portal too:
  Settings → **Seerr** (this pinned version speaks Seerr natively, not just
  the old Overseerr API), `http://seerr.media.svc.cluster.local:5055` with
  an API key read out of Seerr's own Settings → General. Skip it if no rule
  uses requester data.
- Re-create whatever collection/cleanup rules mattered on the old server —
  there is no config to migrate here, only a checklist to redo by hand.

---

## 10. Deluge (after PR4) — executed LAST

Do not run this section until §11 has already stopped the old server's
`*arr`s and Deluge and taken the final delta. This is the one app whose
restore is not independent of the cutover sequence.

1. Final stop of the old Deluge — this is the point of no return for the
   old server's torrent session:

   ```sh
   ssh old 'docker compose -f /srv/deluge/docker-compose.yml stop'
   ```

2. Copy `core.conf`, the `state/` directory (torrents + fastresume files),
   and the `auth` file (WebUI password) into the new Deluge's config PVC,
   per §4's dir-resolution steps. Copying the whole
   `/srv/deluge/config/` dir is simpler and equally correct — the files
   above are the ones that carry the session, the rest is UI preferences:

   ```sh
   rsync -a old:/srv/deluge/config/ /var/lib/rancher/k3s/storage/pvc-<uid>_media_deluge/
   ```

   **`/srv/deluge/config-backup` is a sibling of `config`, not a
   subdirectory of it** (§2.1), so the copy above does not pull it in —
   which is what you want. Leave it on the old server: it is a pre-existing
   snapshot of this exact state, and the single best rollback if step 4's
   path handling goes wrong. Do not restore *from* it without first
   checking how old it is (`ssh old 'ls -la /srv/deluge/config-backup'`) —
   a stale `state/` re-adds torrents that have since been removed.
3. **Before scaling Deluge back up**, edit the copied `core.conf` in place
   on the VM:

   ```json
   "listen_ports": [51413, 51413],
   "random_port": false,
   ```

   This is the port-preserving NAT contract the whole single-IP model
   depends on — `config/lab.yml`'s `ports.torrent: 51413` is the single
   source for both the Tofu firewall rule and the Ansible DNAT rule that
   forward the public port here. Deluge picking a random port instead
   silently breaks inbound connectability for every existing torrent.
4. **Paths:** if §2.3 already confirmed `/data/torrents/...`-style paths in
   the old `core.conf`, no further edit is needed — the mount is identical.
   **If it did not**, do **not** `sed` the `state/*.fastresume` files to fix
   the paths: they are bencoded, and a plain text substitution changes
   string lengths without updating the length-prefixes bencode requires,
   silently corrupting every entry it touches. Use a bencode-aware tool
   (a small Python script against a bencode library, or the
   `deluge-console` CLI) to rewrite paths correctly, or — the simpler,
   safer option — import with the old paths as-is and let Deluge's own
   **Move Storage** action (WebUI or console, per-torrent or in bulk) do the
   relocation, since Deluge already knows how to update its own fastresume
   state consistently.
5. `chown -R 1000:1000` the Deluge config PVC directory.
6. Scale Deluge up, verify the WebUI is reachable and the old password
   still authenticates.
7. **Verify before declaring done:** open the Torrents view and confirm
   seeds have completed their startup recheck and are announcing
   successfully (tracker status column shows a recent OK, not an error) —
   don't walk away from a batch of torrents silently failing to announce.

---

## 11. Delta syncs + pipeline cutover

1. **Delta #2**, while the old server is still fully live (expect hours,
   not days — most of the tree is already there): re-run §3.2's exact
   command, unchanged, from the same place and as the same user:

   ```sh
   rsync -aH --info=progress2 --partial-dir=.rsync-partial \
     --exclude='/lost+found/' old:/data/ /tank/data/
   ```

2. When ready to cut the pipeline over, stop everything on the old server
   that can still write to `/data` — the `*arr`s, Unpackerr, and Deluge.
   **Watchtower first**, so it cannot recreate any of them behind you (it
   is already down if §8 has run; this is idempotent):

   ```sh
   ssh old '
     docker compose -f /srv/watchtower/docker-compose.yml down
     for a in prowlarr sonarr radarr bazarr unpackerr deluge; do
       docker compose -f "/srv/$a/docker-compose.yml" stop
     done
     docker ps --format "{{.Names}}"   # expect none of the above to remain
   '
   ```

   Unpackerr is in that list even though it has no state of its own (§2.1):
   it extracts archives into `/data`, so leaving it running would keep the
   source tree moving underneath the final delta.

3. **Final delta** (expect minutes): the same single whole-tree command one
   more time — this is the pass that must be complete and gapless, since
   nothing is racing it now:

   ```sh
   rsync -aH --info=progress2 --partial-dir=.rsync-partial \
     --exclude='/lost+found/' old:/data/ /tank/data/
   ```

   When it reports zero bytes transferred on a second consecutive run, the
   trees are identical and the source is provably frozen.

   Re-assert ownership afterwards, since this pass brings in files created
   by the old server's uid/gid since §3 ran:

   ```sh
   chown -R 1000:1000 /tank/data
   ```

4. Now run §10 (Deluge) — the old server's session is stopped and its
   source data is frozen, exactly what §10 assumes.

5. **Re-enable what §6 and §7 deliberately switched off.** Both mitigations
   existed only to stop the cluster racing a still-running old server; that
   server is now stopped, and leaving them off means the pipeline quietly
   does nothing.

   - Sonarr and Radarr: Settings → Indexers → Options → **RSS Sync
     Interval** back to the value recorded in §6.
   - Bazarr: re-enable the scheduled subtitle searches disabled in §7.
   - Re-test each `*arr`'s Deluge download client (Settings → Download
     Clients → Test). With §10 done, the "Label plugin not activated" error
     from §6 is gone and the test passes.

6. **The media pipeline is now served by the cluster** — every request that
   used to flow through the old docker-compose stack flows through `media`
   namespace pods instead.
7. **Public DNS cutover remains entirely separate** — see
   [`dns-cutover.md`](dns-cutover.md). Nothing above changes what
   `tomkatom.com` resolves to; that stays the old server's IP until an
   operator deliberately runs that runbook.

---

## 12. Post-migration hardening

1. **Patch every config PV to `Retain`** — local-path-provisioner's default
   reclaim policy is `Delete`, so deleting a PVC by mistake (or an Argo
   `--auto-prune` acting on a removed Application) destroys the app's
   config with it. Enumerate and patch:

   ```sh
   kubectl get pv -o json \
     | jq -r '.items[] | select(.spec.claimRef.namespace=="media") | .metadata.name' \
     | while read -r pv; do
         kubectl patch pv "$pv" -p '{"spec":{"persistentVolumeReclaimPolicy":"Retain"}}'
       done
   kubectl get pv -o custom-columns=NAME:.metadata.name,RECLAIM:.spec.persistentVolumeReclaimPolicy,NS:.spec.claimRef.namespace \
     | grep media   # every row should now read Retain
   ```

2. **Retire the migration SSH key.** §3.1 put a passphrase-less key on the
   new Proxmox host that authenticates to both `old-pve` and `old`. Once
   §11's final delta is done, nothing needs it again, and leaving it in
   place means the new host's compromise hands over the old one too:

   ```sh
   ssh root@pve.lab.tomkatom.com 'shred -u /root/.ssh/id_migration*'
   PUB=$(ssh root@pve.lab.tomkatom.com 'cat /root/.ssh/id_migration.pub' 2>/dev/null)
   # then drop the pve-media-migration line from authorized_keys on both hops:
   for h in old-pve old; do ssh "$h" 'grep -n pve-media-migration ~/.ssh/authorized_keys'; done
   ```

   Read the `grep` output and remove those lines by hand — this is a
   one-time, two-host edit, and a scripted in-place rewrite of
   `authorized_keys` is a well-known way to lock yourself out of a machine
   you still need. Also drop the two `Host` blocks from
   `/root/.ssh/config` on the new host so nothing later resolves `old` and
   fails confusingly.

3. Confirm the `*arr` backups configured in §6 are actually landing:

   ```sh
   ssh debian@k3s.lab.tomkatom.com 'ls -la /data/backups/sonarr /data/backups/radarr'
   ```

4. The full backup story (`vzdump` → NFS) is deferred to Phase 8 — nothing
   to do here beyond what §6/§12.1 already cover as interim mitigations.
5. Until Phase 7's observability lands, watch disk growth by hand
   periodically (Plex's Cache exclusion and disabled thumbnails from §8 are
   the main controls, but verify them):

   ```sh
   ssh debian@k3s.lab.tomkatom.com 'du -sh /var/lib/rancher/k3s/storage/*'
   ```

---

## 13. Per-app verification table

One concrete, checkable assertion per app that actually carried state
across:

| App | Assert |
|---|---|
| Deluge | Tracker on an active private-tracker torrent reports the client's announced address as **`145.239.3.55`** (the new server's public IP, via egress masquerade); `ss -lntu \| grep 51413` on the k3s VM shows both `tcp` and `udp` bound |
| Sonarr / Radarr | `stat -c %h` on a file already imported into the library is **≥ 2** for the same file under `/data/torrents/...` and `/data/media/...` — the hardlink survived the migration |
| Prowlarr | Settings → Indexers → **Test All** green; Apps → Sonarr/Radarr sync succeeds |
| Bazarr | A subtitle search/download succeeds for a title already in the library; Sonarr/Radarr connections show green |
| Plex | `curl http://10.10.10.10:32400/identity` (over WG) returns the **same** `machineIdentifier` as the old server's `Preferences.xml` — no re-claim; a remote client shows **Direct Play**, zero transcode sessions |
| Seerr | End-to-end: request → Prowlarr/Sonarr grab → Deluge download → hardlink import → Plex library updates → Seerr flips **Available** → a **Telegram group** message arrives |
| Tautulli | The recently-added digest posts to the same Telegram group on its configured schedule; play history shows continuity from before the migration |
| Maintainerr | At least one re-created rule executes against a test item without error |
| Unpackerr | A multi-part archive downloaded by Deluge is auto-extracted and picked up by Sonarr/Radarr with no manual intervention |
