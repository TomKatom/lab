# Runbook: sending someone a file

How to hand a person outside the lab a link to something already on the
server, without an SSH session, a third-party upload, or an account for them.

The service is FileBrowser Quantum
([`clusters/lab/apps/filebrowser.yaml`](../../clusters/lab/apps/filebrowser.yaml)),
one pod in the `share` namespace. It browses `/data/torrents` **in place** —
nothing is ever copied or staged, which matters because `tank` has under a
terabyte of runway and a "share" that duplicated the file would spend it.

---

## 0. The two hostnames are not interchangeable

| | `files.tomkatom.com` | `share.tomkatom.com` |
|---|---|---|
| Who it is for | you | the recipient |
| Auth | Authelia, two-factor | none — the link *is* the credential |
| What is published | everything: browse UI, `/api`, the share manager | `/public` and nothing else |
| Bare `/` | the file browser | **404 from Traefik** |

Both names point at the same Service. The separation is a routing fact, not
an application setting: the public Ingress declares `path: /public`, so
Traefik has no route for anything else on that hostname and rejects it before
the pod is involved. That is deliberate — it means an authentication bug
inside FileBrowser cannot re-expose the browse API on the public name.

The corollary is the thing to remember day to day: **never send anyone a
`files.` URL.** It will ask them for a login they do not have. Every link the
share dialog produces is already on `share.` (the app is configured with
`server.externalUrl`), so the only way to get this wrong is to copy one out of
your address bar by hand.

---

## 1. Create a share

1. Open <https://files.tomkatom.com> and authenticate through Authelia. The
   first visit creates your FileBrowser account from the `Remote-User` header
   Authelia returns — there is no separate password to set, and no signup.
2. Navigate to the file or folder under `torrents`.
3. Right-click → **Share**, and set:

   | Field | Policy | Why |
   |---|---|---|
   | **Expiry** | always. 7 days unless there is a reason | An unexpiring link is a permanent public URL you will forget about |
   | **Download limit** | always. 5 unless there is a reason | Caps the damage if the link is reposted; the recipient normally needs one |
   | **Password** | for anything sensitive, sent out-of-band | Defence in depth — see the note below |
   | **Bandwidth limit** | worth setting on anything large | One recipient should not saturate the uplink |

4. Copy the generated link. It will be
   `https://share.tomkatom.com/public/share/<hash>`.

Expired shares are removed at startup. The hash is the real access control:
it is high-entropy and unguessable, and the design treats it that way
deliberately, because FileBrowser has twice shipped an incomplete fix for
share-**password** bypass (CVE-2026-27611 and GHSA-525j-95gf-766f, both
leaking the tokenised download URL through `/public/api/share/info` without
the password). Nothing here depends on the password holding, so that bug class
costs nothing — but it is also why a password is not a substitute for an
expiry and a cap.

## 2. Folders download as one archive

Sharing a directory gives the recipient a single `.zip`/`.tar.gz`. Two things
about that are worth knowing before you share a large one:

- An ordinary browser download **streams** — the archive is built on the fly
  and never lands on disk, so folder size is not a constraint.
- A `HEAD` or a `Range` request — a download manager, a resumed transfer —
  makes the server **spool the whole archive to disk first**, and that path is
  capped by `server.maxArchiveSize` (10 GB). Above it the recipient gets a
  `413`; a plain browser download of the same folder still works.

If someone reports a 413 on a big folder, that is this, and the fix is either
"download it in a browser" or a deliberate bump of `maxArchiveSize` together
with the `cache` volume's `sizeLimit` in the same commit — they are sized
against each other.

## 3. Revoke

Shares are listed in the FileBrowser UI on `files.tomkatom.com`. Delete the
share; the link is dead immediately.

Revoke without being asked when `PublicShareRequestSpike` fires
([`docs/observability.md`](../observability.md#log-alerts)) — over 500
`/public` requests in fifteen minutes means a link has been reposted somewhere
public, or the hostname is being scanned. The download cap will already have
stopped the actual transfers; the alert is telling you the link itself has
escaped.

## 4. What this cannot do

**Sharing is send-only.** There is no anonymous write path, and that is
enforced three times over rather than once, because each layer can be
misconfigured independently:

1. The `/data/torrents` mount is `readOnly: true` — the kernel refuses.
2. The source is declared `readOnly: true` — FileBrowser refuses, and the
   write actions are absent from the UI.
3. `userDefaults` grants neither `modify`, `create` nor `delete`.

**Only `/data/torrents` is visible.** Not `/data/media`, not the rest of the
tree. Sharing something from the Plex library means sharing the seeding copy
it was hardlinked from, which is the same bytes
([`clusters/lab/apps/README.md`](../../clusters/lab/apps/README.md#the-data-path-contract)).

**The pod cannot reach the rest of the cluster.** Its NetworkPolicy
([`filebrowser/networkpolicy.yaml`](../../clusters/lab/apps/filebrowser/networkpolicy.yaml))
allows ingress from the `traefik` namespace only and egress to DNS only. Both
halves are load-bearing: the first is what stops any pod in the cluster
curling the Service with a `Remote-User` header of its choosing and bypassing
Authelia entirely, and the second means a compromised `/public` handler has
nowhere to send anything.

## 5. Restoring after a loss

The `/config` PVC holds the share records and your account. It is on the
default `local-path` StorageClass, so it is inside the nightly `vzdump` of
guest 9000 and reaches PBS and B2 with everything else — nothing to configure
([`docs/backups.md`](../backups.md)).

Getting it back is a **VM-image file-level restore**, not a per-PVC one
(VolSync is roadmap, not built — [`docs/runbooks/restore.md`](restore.md)).
That is proportionate: the database holds nothing but share records, which are
expiring by design. The realistic recovery is to create the shares again.
