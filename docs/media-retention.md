# Media retention

How the library is kept from filling `tank`, and what Maintainerr can and
cannot do about it. Maintainerr's connection settings and rules live in its
own SQLite database rather than in git, so this document is the source of
truth for *what the rules are meant to say*. Once the rules exist, the YAML
exported out of Maintainerr becomes the source of truth for what they
actually say — it lives beside this file under `maintainerr-rules/`, which
the first export creates (nothing is committed there yet; the rules have
not been built, see "Rules as code" below).

## The constraint

`tank` is a two-disk stripe, ~3.6 TB, no redundancy. It holds both halves of
the media pipeline: `/data/torrents` (what Deluge seeds) and `/data/media`
(what Plex serves). Those are not two copies. The *arrs import by hardlink,
so a release that has been imported is **one file with two names**, and it
occupies its bytes exactly once.

## What deleting actually frees

This is the part that decides whether a retention rule is worth writing.

Maintainerr deletes through the Sonarr and Radarr APIs. It has no way to
touch Deluge — its download-client cleanup is qBittorrent-only at the pinned
version (`download-client.factory.ts` returns a `QbittorrentApi`
unconditionally), and there is no Deluge backend to select. So a Maintainerr
deletion removes the `/data/media` name and nothing else.

If the release is still seeding, `/data/torrents` still holds the other name,
the inode survives, and **the deletion frees zero bytes.** With roughly 600
permanently-seeding torrents on private trackers, that is the common case
rather than the exception.

So Maintainerr buys three things here, and only the third is bytes:

1. A **"leaving soon" collection** in Plex that warns users before anything
   happens.
2. A **list** of what the library considers stale — which is the input to
   deciding what to stop seeding.
3. Actual reclaimed space, but **only** for releases no longer being seeded.

Reclaiming space on a seeded release is a two-step operation and the second
step is not Maintainerr's: remove the torrent from Deluge (with its data), and
the last name goes with it. The post-import label the *arrs set on their
grabs — Sonarr's `TvImportedCategory` and the Radarr equivalent — is what
makes those filterable in the Deluge UI. Treat ratio obligations on private
trackers as the thing that decides whether a given release *may* be stopped;
Maintainerr only tells you which ones nobody is watching.

## The policy

One time window for everything, with a manual exemption.

Both rule groups carry the same escape hatch as their **first** condition:

```
Plex → [list] Labels   not contains   keep
```

Anything labelled `keep` in Plex is immune, permanently, with no time
component. That is the "stays forever" switch: open the item in Plex →
Edit → Tags → Labels → add `keep`. It works from any Plex client, needs no
Maintainerr access, and survives rule edits because it is a property of the
media rather than of the rule.

Use it for anything worth its bytes indefinitely — the 4K remuxes, anything
hard to re-acquire, anything a household member is partway through and slow
about.

### Movies

| | |
|---|---|
| Library | Movies |
| Condition 1 | `[list] Labels` **not contains** `keep` |
| Condition 2 | `Date added` **not in last** `90 days` |
| Condition 3 | `Last view date` **not in last** `60 days` |
| Action | Add to collection **Leaving Soon**, delete after **14 days** |

Condition 3 also catches never-watched items: an item with no view date does
not satisfy "viewed in the last 60 days".

### Shows

Shows need the season/episode-aware properties, not the movie ones — a show
is "watched" in a way a movie is not.

| | |
|---|---|
| Library | Shows |
| Condition 1 | `[list] Labels` **not contains** `keep` |
| Condition 2 | `Last episode added at` **not in last** `90 days` |
| Condition 3 | `Newest episode view date` **not in last** `90 days` |
| Action | Add to collection **Leaving Soon**, delete after **14 days** |

A longer view window than movies on purpose: people leave a series parked
mid-season for months and come back to it, and re-acquiring a full season
costs far more than re-acquiring one film.

## Rules as code, within the limits

Maintainerr 3.19.0 has first-class YAML import/export for rule groups — the
`YamlImporterModal` in the UI, `POST /api/rules/yaml/encode` and
`/api/rules/yaml/decode` behind it. Its **connection settings** (Plex,
Sonarr, Radarr, Tautulli, Seerr) have no such path and no environment
overrides; those are database-only and are a one-time UI checklist in
[`runbooks/media-migration.md`](runbooks/media-migration.md) §9.

The workflow is therefore export-then-commit, not commit-then-apply:

1. Build or edit the rule group in the UI.
2. Export its YAML from the rule editor.
3. Commit it under `docs/maintainerr-rules/<group>.yml`.

That keeps the rules reviewable, diffable and restorable — Maintainerr's PVC
is on local-path storage, whose reclaim policy is `Delete` — without
pretending git drives them. If a rule is changed in the UI and not
re-exported, git is stale, and nothing detects that but a human. Re-export in
the same sitting as the edit.

## Before turning deletion on

Run each group with the delete action off for a cycle or two and read what
lands in the **Leaving Soon** collection. The rules above are a starting
point tuned for a library that is mostly seeded and mostly unwatched-tail;
the windows are the part most likely to want changing once there is real
data. Deletion through the *arrs is not undoable from Maintainerr.
