# Runbook: cutting over to the declared Deluge/\*arr path contract

One-time migration to the path contract described in
[`clusters/lab/apps/README.md`](../../clusters/lab/apps/README.md#the-data-path-contract).
Run it **after** the PR that introduces `arr-settings` and the declarative
`label.conf` has merged and Argo has synced.

What actually changes on disk is small. The label → directory mapping this
stack already used is the one being declared, so nothing bulk moves: 379 of
the 384 seeding torrents are already in the right place and stay exactly
where they are. The work is five strays, three latent recheck triggers, and
a library rename.

**Nothing here is reversible by re-running it.** §4's rename rewrites every
file and folder name under `/data/media`; §3 relocates torrent data. Read
§0 before starting anything.

---

## 0. What the cutover consists of, and what it risks

| Step | Touches | Reversible |
|---|---|---|
| §1 pre-flight | nothing (reads only) | n/a |
| §2 settings apply | the two \*arr databases | yes — revert the PR, run again |
| §3 stray torrents | 5 torrents' data location | yes — move them back |
| §4 library rename | every name under `/data/media` | **no** (see below) |
| §5 cleanup | un-imported leftovers you approve | no |

**§4 is the one to schedule deliberately.** Sonarr and Radarr rename in
place, so nothing is lost and no torrent is touched — a media file is a
hardlink, and renaming a hardlink does not move the bytes or disturb the
seeding copy that shares the inode. But there is no "undo rename" button:
going back means declaring the old naming scheme and renaming again. Plex
will also show the library as churning while it rescans.

**What §4 cannot break, and is worth knowing so you do not panic:**
seeding. `stat -c %h` on a renamed media file still reports ≥ 2, and
Deluge's copy under `/data/torrents` never had its path changed.

---

## 1. Pre-flight (read-only)

First confirm the directories the declared settings name already exist —
Sonarr's and Radarr's `recycleBin` is validated for existence *and*
writability at save time, and a missing one 400s the whole
`mediaManagement` call rather than just that key:

```sh
ls -ld /data/.recyclebin/sonarr /data/.recyclebin/radarr /data/torrents-final
# if any is missing, they are declared in ansible/roles/virtiofs — re-run
# ansible/playbooks/virtiofs.yml rather than creating them by hand
```

Then run the applier in dry-run to see exactly what it will change. Nothing
is written and no \*arr is modified:

```sh
kubectl -n media create job --from=cronjob/arr-settings arr-settings-preflight \
  --dry-run=client -o json \
  | python3 -c 'import json,sys
job = json.load(sys.stdin)
job["spec"]["template"]["spec"]["containers"][0].setdefault("env", []).append(
    {"name": "DRY_RUN", "value": "1"})
json.dump(job, sys.stdout)' \
  | kubectl create -f -
kubectl -n media wait --for=condition=complete job/arr-settings-preflight --timeout=120s
kubectl -n media logs job/arr-settings-preflight
```

Expect a list of `->` lines for the naming formats, `extraFileExtensions`,
`recycleBin`, and `downloadDirectory` on each Deluge client, then
`N resource(s) would change`. **Anything naming a setting you did not
expect is a reason to stop**, particularly under `/downloadclient` — that
is the one section where a wrong value stops downloads being imported
rather than merely being named oddly.

Delete the pre-flight Job when you are done reading it:

```sh
kubectl -n media delete job arr-settings-preflight
```

Record the starting state so §6 has something to compare against:

```sh
kubectl -n media exec deploy/deluge -- \
  deluge-console -c /config "info -v" 2>/dev/null \
  | grep -cE '^State: Seeding'          # expect 384
ls /data/media/tv | head; ls /data/media/movies | head
```

## 2. Apply the declared settings

Argo syncs the CronJob but does not run it. Trigger the first run by hand:

```sh
kubectl -n media create job --from=cronjob/arr-settings arr-settings-manual
kubectl -n media logs job/arr-settings-manual -f
```

Expect the same lines the dry run showed, without the `DRY_RUN` banner,
ending in `N resource(s) changed`. Run it a second time — it must report
`in sync` for every resource and `0 resource(s) changed`. That second run
is the real check: it proves the applier converged rather than merely
succeeded.

```sh
kubectl -n media delete job arr-settings-manual
```

**Do not skip the second run.** A setting that does not stick (because the
\*arr rejected it, or because a field name changed between versions) shows
up as permanent drift here and nowhere else — the CronJob would otherwise
rewrite it hourly forever and look green doing it.

At this point the Deluge pod should also have rolled once, on its own,
because the `label.conf` content changed the `checksum/configMaps`
annotation. Confirm the labels landed:

```sh
kubectl -n media logs deploy/deluge -c init-config
# label.conf: 7 labels, 383 torrent assignments preserved
```

The `music` label is gone — it had no torrents. If that line reports fewer
than 383 assignments, **stop**: the merge dropped per-torrent labels, which
is the one thing the renderer is built not to do.

## 3. The five strays and the three latent rechecks

Two small fixes that the declared config cannot make on its own, because
both are per-torrent state rather than configuration.

**3a. Torrents sitting outside their label's directory.** List them by
comparing each torrent's save path against the directory its label
declares — re-run this rather than trusting the table below, the session
moves under you:

```sh
kubectl -n media exec deploy/deluge -- python3 -c '
import json, pickle, sys
sys.path.insert(0, "/lsiopy/lib/python3.12/site-packages")
from deluge.config import find_json_objects
from deluge.core.torrentmanager import TorrentState, TorrentManagerState
state = pickle.load(open("/config/state/torrents.state", "rb"))
raw = open("/config/label.conf").read()
start, end = find_json_objects(raw)[-1]
config = json.loads(raw[start:end])
labels = config["torrent_labels"]
want = {name: opts["move_completed_path"]
        for name, opts in config["labels"].items()}
for t in state.torrents:
    label = labels.get(t.torrent_id)
    if want.get(label) != t.save_path:
        print(t.torrent_id, "label=%s" % label, t.save_path, t.filename[:60])'
```

At the time of writing, five:

| Torrent | Label | Sits in | Belongs in |
|---|---|---|---|
| `36ede42e…` VMware Workstation | `programs` | `/data/torrents/programs/VMware.…-AMPED` | `/data/torrents/programs` |
| `ca270cca…` Hunger Games Trilogy | `ebooks` | `/data/torrents/books/audiobooks` | `/data/torrents/books/ebooks` |
| `93667a8a…`, `36cd6372…` | `games` | `/data/torrents` | `/data/torrents/games` |
| `7f77e92e…` | *(none)* | `/data/torrents` | your call |

Move each with Deluge's own `move`, never with `mv` — Deluge has to update
the torrent's save path and fastresume, and a filesystem move behind its
back makes the torrent error out and re-check against files it can no
longer find:

```sh
kubectl -n media exec deploy/deluge -- \
  deluge-console -c /config "move 93667a8aa1a9557e6bb56876f694f170111b5ce4 /data/torrents/games"
```

The last one carries no label at all. Give it one in the WebUI (which
files it on the next completion) or leave it at the root — it is a
deliberate choice, not a defect. The VMware one is only nested a level
deeper than its label says; harmless, and worth fixing only for tidiness.

Each move is a rename within one filesystem, so it is instant, and the
media hardlinks are unaffected — none of these five are `tv`/`movies`
torrents anyway, so no `*arr` has ever hardlinked them.

**3b. Three torrents carry a latent full-recheck trigger.** These are in
`tv`/`movies` with `move_completed` still set, pointing at the directory
they are already in:

```
23cfafb14b560b3db5b0855d5ad16c65b9a73648  movies
82bf424365e45be6c146234cf710125d6425151e  tv
e9ab690a063cebdb5c5399a973c7577147151bda  movies
```

They are harmless today and are not a data-loss risk — libtorrent's
`move_storage` under `dont_replace` skips a file that already exists at the
destination rather than deleting the source (`storage_utils.cpp`). But that
same branch sets `status_t::need_full_check`, so if any of the three ever
emits `torrent_finished` again (a force-recheck of a complete torrent does
exactly that) it schedules a **full hash check** of the torrent.

That is also precisely why the contract never sets a download directory and
a label move to the same path: doing both would arm this on every single
grab.

Clear them over the daemon's RPC. **Do not use
`deluge-console "manage <id> --set move_completed false"` for this** — the
console coerces every value with the type in `TORRENT_OPTIONS`, which for
this key is `bool`, and `bool("false")` is `True`. That command sets the
option it looks like it clears. The RPC below passes a real boolean:

```sh
kubectl -n media exec deploy/deluge -- python3 -c '
import sys
sys.path.insert(0, "/lsiopy/lib/python3.12/site-packages")
import deluge.configmanager as cm
cm.set_config_dir("/config")
from deluge.ui.client import client
from twisted.internet import reactor

IDS = ["23cfafb14b560b3db5b0855d5ad16c65b9a73648",
       "82bf424365e45be6c146234cf710125d6425151e",
       "e9ab690a063cebdb5c5399a973c7577147151bda"]

def done(_):
    print("cleared", len(IDS)); client.disconnect(); reactor.stop()

def fail(reason):
    print("FAILED", reason); client.disconnect(); reactor.stop()

def go(_):
    client.core.set_torrent_options(
        IDS, {"move_completed": False}).addCallback(done).addErrback(fail)

client.connect().addCallback(go).addErrback(fail)
reactor.run()'
```

`client.connect()` with no arguments uses the `localclient` credentials in
`/config/auth`, the same ones `deluge-console -c /config` uses — no WebUI
password is involved.

Verify none are left:

```sh
kubectl -n media exec deploy/deluge -- python3 -c '
import json, pickle, sys
sys.path.insert(0, "/lsiopy/lib/python3.12/site-packages")
from deluge.config import find_json_objects
from deluge.core.torrentmanager import TorrentState, TorrentManagerState
state = pickle.load(open("/config/state/torrents.state", "rb"))
raw = open("/config/label.conf").read()
start, end = find_json_objects(raw)[-1]
labels = json.loads(raw[start:end])["torrent_labels"]
bad = [t.torrent_id for t in state.torrents
       if labels.get(t.torrent_id) in ("tv", "movies") and t.move_completed]
print("armed:", len(bad), bad)'
# armed: 0 []
```

## 4. Rename the library to the declared scheme

The declared naming scheme applies to everything imported from now on. To
bring the existing library across, both apps need a nudge — and they need
different ones, because Radarr can reconcile a movie folder on refresh and
Sonarr cannot.

Do this when nobody is mid-stream. Plex tolerates it, but a file that is
renamed while being read will stop that playback.

**4a. Radarr.** `autoRenameFolders` is now on, so a refresh moves each
movie folder to `{Movie CleanTitle} ({Release Year}) {imdb-{ImdbId}}`;
`RenameMovie` then renames the files inside:

```sh
RK=$(kubectl -n media get secret arr-api-keys -o jsonpath='{.data.RADARR_API_KEY}' | base64 -d)
R=http://radarr.media.svc.cluster.local:7878/api/v3
IDS=$(curl -s -H "X-Api-Key: $RK" "$R/movie" | jq -c '[.[].id]')

curl -s -H "X-Api-Key: $RK" -H 'Content-Type: application/json' \
  -d '{"name":"RefreshMovie"}' "$R/command"
curl -s -H "X-Api-Key: $RK" -H 'Content-Type: application/json' \
  -d "{\"name\":\"RenameMovie\",\"movieIds\":$IDS}" "$R/command"
```

**4b. Sonarr.** Renaming files is the same shape, but the *series folder*
is only recomputed when the series is moved, so the folder migration is a
no-op move to the root folder it is already in — with `moveFiles: true`,
which is what makes Sonarr recalculate the path from `seriesFolderFormat`:

```sh
SK=$(kubectl -n media get secret arr-api-keys -o jsonpath='{.data.SONARR_API_KEY}' | base64 -d)
S=http://sonarr.media.svc.cluster.local:8989/api/v3
IDS=$(curl -s -H "X-Api-Key: $SK" "$S/series" | jq -c '[.[].id]')

curl -s -H "X-Api-Key: $SK" -H 'Content-Type: application/json' -X PUT \
  -d "{\"seriesIds\":$IDS,\"rootFolderPath\":\"/data/media/tv\",\"moveFiles\":true}" \
  "$S/series/editor"
curl -s -H "X-Api-Key: $SK" -H 'Content-Type: application/json' \
  -d "{\"name\":\"RenameSeries\",\"seriesIds\":$IDS}" "$S/command"
```

Watch both in Activity → Queue / History rather than by tailing logs; the
folder move is a batch command and reports per-item there.

**4c. Plex.** The rename changes every path Plex has recorded, so it needs
a full scan, not the partial one `*arr` Connect triggers:

```sh
curl -s "http://plex.media.svc.cluster.local:32400/library/sections?X-Plex-Token=$PLEX_TOKEN"
# then, per section id:
curl -s "http://plex.media.svc.cluster.local:32400/library/sections/<id>/refresh?force=1&X-Plex-Token=$PLEX_TOKEN"
```

Watch history is keyed to the Plex item, not the file path, so it survives
the rename. Items Plex cannot re-match will surface as new — check the
library's "Recently Added" for duplicates once the scan settles.

## 5. Leftovers to review, not to delete blindly

Fourteen release-named folders sit directly in the library roots and were
never imported. They are what the \*arrs report as *unmapped folders*:

```sh
curl -s -H "X-Api-Key: $SK" "$S/rootfolder" | jq -r '.[].unmappedFolders[].path'
curl -s -H "X-Api-Key: $RK" "$R/rootfolder" | jq -r '.[].unmappedFolders[].path'
```

At the time of writing that is 9 under `/data/media/tv` (Andor releases)
and 5 under `/data/media/movies`. **Check each against Deluge before
removing anything** — if a torrent still references the same inode, the
folder is a seeding copy in the wrong tree and deleting it costs you the
seed:

```sh
find /data/media/tv/<folder> -type f -printf '%n %i %p\n'
```

Link count 1 means nothing else points at it and it is safe to remove; ≥ 2
means it is shared, and the right fix is to import it in the \*arr rather
than delete it.

## 6. Verification

| Check | Command | Expect |
|---|---|---|
| Nothing stopped seeding | `deluge-console -c /config "info -v" \| grep -c '^State: Seeding'` | 384 |
| Labels are declared, assignments intact | `kubectl -n media logs deploy/deluge -c init-config` | `7 labels, 383 torrent assignments preserved` |
| Settings converged | second `arr-settings` run | `0 resource(s) changed` |
| Hardlinks survived the rename | `find /data/media/tv -type f -printf '%n\n' \| sort \| uniq -c` | the ≥2 bucket is no smaller than before |
| New grabs land in place | grab one episode, then `deluge-console -c /config "info -v"` | `Download Folder: /data/torrents/tv`, no `Moving` state |
| The import is a hardlink | `stat -c %h` on the imported file | ≥ 2 |

The fifth row is the one that proves the contract end to end: a torrent
that shows `/data/torrents/tv` as its download folder from the moment it is
added, and never passes through `Moving`, is the whole point of the change.

## 7. If it goes wrong

- **Imports start failing right after §2.** Almost certainly the download
  directory and the label disagree. Check that `deluge.yaml`'s `tv`/`movies`
  labels have `apply_move_completed: false` and that the \*arr's
  `downloadDirectory` matches the label's `move_completed_path`. Reverting
  the `arr-settings` ConfigMap and re-running the CronJob restores the
  previous behaviour within the hour.
- **A torrent goes to `Error` after §3.** It was moved behind Deluge's
  back. Point it back at the directory its files are actually in with
  `deluge-console "move <id> <path>"`, then force a recheck.
- **Plex shows duplicates after §4.** The rename outran the scan. Run
  §4c's `refresh?force=1` again and let it finish before judging; genuine
  orphans can then be removed from the library without touching files.
- **Mass recheck starts.** Stop Deluge before it thrashes the HDD stripe,
  and check §3b — an armed `move_completed` is the likely cause.
