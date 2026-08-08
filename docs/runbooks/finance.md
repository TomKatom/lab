# Runbook: bootstrapping and running the finance stack

How to get every shekel that moves through Bank Hapoalim and Isracard into an
envelope budget automatically, and how to tell whether it is still happening —
without a manual export, a spreadsheet, or a single line of data entry.

Two pieces, both in the `finance` namespace. **Actual Budget**
([`clusters/lab/apps/actual.yaml`](../../clusters/lab/apps/actual.yaml)) is the
budget itself, one pod on `budget.tomkatom.com` with a PVC. **moneyman**
([`clusters/lab/apps/moneyman.yaml`](../../clusters/lab/apps/moneyman.yaml)) is
a CronJob that wakes at 04:30 Israel time, drives headless Chromium through
both institutions' web logins, and imports what it scraped into Actual over the
in-cluster Service. Everything either of them needs to know lives in one
SOPS-encrypted Secret,
[`finance-common/moneyman-config.sops.yaml`](../../clusters/lab/apps/finance-common/moneyman-config.sops.yaml).

---

## 0. A Succeeded Job is not a successful scrape

moneyman exits `0` no matter what happens. Its `main` catches every error path
and ends on an unconditional `process.exit(0)`, so a night where Isracard
served a CAPTCHA instead of a login page, or where the Actual API refused the
budget file, still finishes as a green Job in `kubectl get jobs`.

Everything downstream inherits that:

| Signal | What it actually means |
|---|---|
| Job `Succeeded` | the container ran to completion. Nothing more. |
| `KubeJobFailed` silent | no pod crashed. Says nothing about the scrape. |
| `MoneymanStale` silent | the CronJob is still being scheduled and Jobs still complete. |
| New rows in Actual | **the only evidence that the scrape worked.** |

So the health check for this stack is a human one: open
<https://budget.tomkatom.com> every week or two and confirm the most recent
transaction is from yesterday, not from three weeks ago. `MoneymanStale`
([`clusters/lab/platform/monitoring/rules-finance.yaml`](../../clusters/lab/platform/monitoring/rules-finance.yaml),
added by a sibling PR) catches the *other* failure — the CronJob stopping
altogether, because the controller wedged, the image will not pull, or someone
left it suspended — and it is worth having for exactly that. It is not a
scraper monitor and must not be read as one.

Upstream ships one real failure channel, `options.notifications.telegram`,
which sends per-run errors and the full log to a chat. It is deliberately
unused: it would give the Telegram bot token a third SOPS home, and this
repo's alerting is Prometheus to Alertmanager to Telegram, one path. That
trade is worth re-opening if the weekly eyeball proves unreliable in practice.

---

## 1. What this is

Actual is reachable at **<https://budget.tomkatom.com>** and is gated twice:
Authelia two-factor at the Ingress, and Actual's own server password inside.
That is deliberate defence in depth — the Ingress annotation is one line that
a future edit could drop, and a budget is the highest-value thing this cluster
serves.

It is **not linked from the homepage**, on purpose: `tomkatom.com` is a public
page for Plex viewers and lists nothing that sits behind Authelia
([`clusters/lab/apps/homepage/configmap-homepage.yaml`](../../clusters/lab/apps/homepage/configmap-homepage.yaml)).
Bookmark it.

moneyman reaches Actual as `http://actual.finance.svc.cluster.local:5006`,
which is the Service, not the Ingress — so it bypasses Authelia entirely and
authenticates with Actual's server password like any other client. That
address is written inside the encrypted config, where nothing can diff it
against `actual.yaml`. **Changing Actual's Service name or port means a `sops`
edit in the same commit.**

---

## 2. One-time bootstrap

Everything below is operator work, done once, in this order. Nothing scrapes
until the last step, because the CronJob is merged with `suspend: true`.

### 2.1 Set the server password and create the budget

Open <https://budget.tomkatom.com>, clear Authelia, and set the Actual server
password on the welcome screen. There is no environment variable for it and no
default — the first visitor to an empty database sets it, which is why this
step comes before anything else.

Create the budget file, then in **Settings** set the currency and number format
to ILS and the date format to `DD/MM/YYYY`. Doing it now is cheaper than
reformatting after a few hundred imported transactions.

### 2.2 Create the two accounts

Add exactly two **on-budget** accounts:

| Name | Holds |
|---|---|
| Hapoalim checking | rent, salary, the monthly card settlement debit |
| Isracard | the itemized card charges |

On-budget matters: an off-budget account's transactions never reach a category,
which defeats the point.

### 2.3 Collect the ids

- **`budgetId`** — Settings → Advanced settings → **Sync ID**. It is a UUID,
  not the budget's name.
- **Each account's UUID** — open the account and read it out of the URL
  (`/accounts/<uuid>`).

### 2.4 Discover the scraper-side account ids

moneyman keys its account map by the account number *the bank reports*, which
is not something you can guess reliably — Isracard in particular reports a card
identifier rather than the number printed on the card.

Fill only the credentials into the config for now:

```
sops clusters/lab/apps/finance-common/moneyman-config.sops.yaml
```

Leave `storage.actual.accounts` as a single placeholder entry, commit, and let
Argo re-render the Secret. Then run one diagnostic Pod — not the CronJob, which
by design logs almost nothing (see [§3](#3-running-it-by-hand) for why):

```
kubectl -n finance run moneyman-discover --rm -it --restart=Never \
  --image=ghcr.io/daniel-hauser/moneyman:v2026.07.18.1 \
  --overrides='{"spec":{"containers":[{"name":"moneyman-discover",
    "image":"ghcr.io/daniel-hauser/moneyman:v2026.07.18.1",
    "env":[{"name":"MONEYMAN_UNSAFE_STDOUT","value":"true"},
           {"name":"DEBUG","value":"moneyman:*"},
           {"name":"MONEYMAN_CONFIG","valueFrom":{"secretKeyRef":
             {"name":"moneyman-config","key":"MONEYMAN_CONFIG"}}}]}]}}'
```

It scrapes for real, prints one line per account it found —

```
	✔️ [hapoalim] 12-345-678901: 37
	✔️ [isracard] 1234: 112
```

— and *then* fails the import with `Failed to initialize Actual Budget: No
valid account mappings found`. That failure is expected and is not a problem:
the summary is emitted before the storage step runs. The strings on the left of
each colon are the keys for `storage.actual.accounts`.

Three things about that Pod. Use the same digest-pinned image reference the
CronJob uses — copy it out of `moneyman.yaml` rather than the tag written
above, which is only there to keep the command readable. `--overrides`
replaces the container wholesale, so the image has to appear inside it as well
and any `--env` flags on the command line are ignored. And it prints real
transaction descriptions and amounts to stdout,
which this cluster ships to Loki like any other pod — a fair trade for one run,
not something to leave switched on.

### 2.5 Fill the config

```
sops clusters/lab/apps/finance-common/moneyman-config.sops.yaml
```

Fill `budgetId`, the Actual server password, and the `accounts` map — scraped
account id on the left, Actual account UUID on the right.

**Keep the value a block scalar.** The whole JSON blob lives under
`stringData.MONEYMAN_CONFIG` as a `|` block; if the editor turns it into a
flow scalar the Secret still encrypts, still applies, and moneyman then reads
a config it cannot parse. Leave `options.scraping.transactionHashType` set to
`"moneyman"` exactly as the template has it — see [§4](#4-routine-ops).

Commit, merge, and confirm Argo has re-rendered the Secret before continuing.

### 2.6 Unsuspend

One-line PR flipping `suspend: true` to `false` in
[`moneyman.yaml`](../../clusters/lab/apps/moneyman.yaml). Do it only after a
manual run ([§3](#3-running-it-by-hand)) has put real transactions in Actual —
an unsuspended CronJob against a broken config fails silently every night,
which by [§0](#0-a-succeeded-job-is-not-a-successful-scrape) looks exactly like
success.

### 2.7 Patch the PV to Retain

Once real data is in the budget, take the `actual` PV out of the default
delete-on-PVC-delete behaviour of `local-path`
([`clusters/lab/apps/README.md`](../../clusters/lab/apps/README.md#local-path-reclaim-is-delete)):

```
kubectl patch pv <pv> -p '{"spec":{"persistentVolumeReclaimPolicy":"Retain"}}'
```

### 2.8 Stop the card spending being counted twice

**This is the one that quietly ruins the numbers.** Every card purchase arrives
twice: itemized in the Isracard account on the day it happened, and again a few
weeks later as one lump-sum debit in the Hapoalim account when the card
settles. Left alone, the month's spending is roughly double the truth and the
Isracard account balance grows forever.

After the first settlement debit has been imported, create one Actual rule:

- **Condition** — account is Hapoalim, payee matches the settlement line. It is
  usually some form of `ישראכרט`; copy the exact string out of the first
  imported month rather than typing it, because the match has to be exact.
- **Action** — make it a **Transfer** to the Isracard account.

Transfers are movements between two accounts you own, so they never count as
spending, and this one zeroes the Isracard balance every month. Set it once and
every future settlement is handled on import.

---

## 3. Running it by hand

The CronJob is a template; a Job created from it runs immediately and **works
while the CronJob is suspended**, which is the whole reason the suspended merge
is safe:

```
kubectl -n finance create job --from=cronjob/moneyman moneyman-manual-$(date +%s)
kubectl -n finance get jobs -w
```

Then check Actual. Do not check the logs to decide whether it worked: the image
sets `MONEYMAN_UNSAFE_STDOUT=false`, so the entrypoint redirects the whole run
into `/tmp/moneyman.log` inside the container and deletes it before exit,
leaving `kubectl logs` with `Scraping ended` and little else. That default is
kept deliberately, because the un-redirected stream carries account numbers and
every transaction description.

For a run you can actually read, use the diagnostic Pod from
[§2.4](#24-discover-the-scraper-side-account-ids) — it is the same recipe for
any debugging session, not just for discovering ids.

To check a config edit without touching a bank, the image also ships a
validator that parses `MONEYMAN_CONFIG` against the real schema and exits
non-zero if it does not fit. Same override, with a command:

```
"command":["node","dst/scripts/verify-config.js"]
```

Worth running immediately after any `sops` edit, and before unsuspending.

---

## 4. Routine ops

**Rotating a bank password.** `sops` the config file, change the one value,
commit. Each run is a fresh Pod reading the Secret at start, so there is
nothing to restart and the next scheduled run picks it up. The same is true of
the Actual server password if you change it — but change it in both places in
the same commit, or moneyman silently stops being able to import.

**Never change `transactionHashType` after the first import.** It decides which
hash becomes each transaction's `imported_id`, and Actual dedupes on
`(imported_id, account)`. Changing it in either direction re-mints every id at
once, and the next run re-imports the entire `daysBack` window as new
transactions on top of the ones already there. The template pins it to
`"moneyman"` because upstream's default hashes the description, the memo and a
minute-rounded date — all of which drift on Isracard — and because upstream
intends to flip that default in a future release.

**When `MoneymanStale` fires**, work in this order; it is ordered by how often
each cause is the real one:

1. **Is it suspended, or did it just miss?** `kubectl -n finance get cronjob
   moneyman`. The chart sets `startingDeadlineSeconds: 30`, so a
   controller-manager that is busy at 04:30 skips the night entirely, and
   `concurrencyPolicy: Forbid` does the same if the previous run is somehow
   still going.
2. **Did the pod fail to start?** `kubectl -n finance describe job/<name>` —
   image pull failures after a Renovate bump and OOM kills both land here, and
   both are the only failures `backoffLimit` ever retries.
3. **Did the bank change its site?** Check
   [israeli-bank-scrapers](https://github.com/eshaham/israeli-bank-scrapers/issues)
   issues and moneyman releases, and look for a pending Renovate PR bumping the
   image — this failure mode is usually already fixed upstream and waiting in a
   PR. `daysBack: 14` means merging the fix backfills the missed days
   invisibly.
4. **Did only one of the two images bump?** moneyman bundles a pinned
   `@actual-app/api` (26.7.0 at the current pin) and Actual refuses a budget
   file carrying more migrations than the client knows about. The symptom is
   misleading: the visible error is `Failed to initialize Actual Budget: No
   budget file is open`, and the real cause, `Error updating Error:
   out-of-sync-migrations`, appears earlier in the run. The fix is to hold
   `actual` at the last tag whose `packages/loot-core/migrations/` list matches
   moneyman's bundled API version until a moneyman release catches up — the two
   pins are a pair even though Renovate moves them independently.

**If Isracard starts blocking the scrape.** Its anti-bot layer serves CAPTCHAs
and 429s to datacenter IPs, and this server is one, in Germany. Upstream's
primary documented deployment is GitHub Actions, so non-Israeli datacenter
egress is a supported case rather than a novelty, and intermittent blocks hit
Israeli home IPs too — so a bad week is not evidence of anything. **If it
becomes chronic**, the contingency is to route this pod's egress over
WireGuard to an Israeli endpoint. That is a design note, not a built feature:
it means a second WireGuard client inside the cluster and a residential
endpoint to terminate on, which is a real amount of machinery to add on
suspicion. Establish the pattern first — several weeks of failures, not one.

---

## 5. Recovery

Actual's `/data` PVC holds the entire budget: accounts, categories, rules,
history. It is on the default `local-path` StorageClass, so it lands on the
disk that the nightly `vzdump` of guest 9000 already captures and reaches PBS
and B2 with everything else — nothing to configure
([`docs/backups.md`](../backups.md)). Getting it back is a VM-image file-level
restore, not a per-PVC one ([`restore.md`](restore.md)). Combined with the
`Retain` patch from [§2.7](#27-patch-the-pv-to-retain), the realistic ways to
lose this budget are down to "the whole VM is gone" and "someone deleted the
PV by hand".

moneyman needs no recovery at all. It is stateless — no PVC, nothing cached
between runs — and re-scraping is idempotent, so after any restore the next
nightly run refills whatever the backup was missing, up to `daysBack`.

The one thing worth doing by hand occasionally: **Settings → Export** in Actual
downloads the whole budget as a single file. Do it a couple of times a year and
keep it somewhere that is not this server. It costs a minute and it is the only
copy that does not depend on the backup chain being correct.
