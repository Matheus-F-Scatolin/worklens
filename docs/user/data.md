# Where your data lives

Everything is under `DATA_DIR` — `~/Library/Application Support/Worklens/data` for an installed
app, `./data` beside a checkout (git-ignored), wherever you point it if you set the key:

```
data/
  worklens.sqlite            # captures, descriptions, blocks, LLM cost ledger
  screenshots/YYYY-MM-DD/    # JPEGs, only for frames that were described
  timeline/YYYY-MM-DD.md     # only if a build from before 2026-10-05 wrote it; kept
  reports/daily|weekly/      # only if a build from before 2026-10-05 wrote reports; kept
  logs/
```

To wipe everything Worklens knows about you:

```bash
rm -rf data
```

### How big it gets, and how to make it age out

About **12 MB of screenshots and 1.5 MB of database a day** — eleven days on the author's own Mac
(2026-09-08 to 2026-09-18, about 190 screenshots a day at the 60-second default) left 115 MB of
JPEGs and a 16 MB database holding 21 000 rows. A year at that rate is roughly **4 GB of
screenshots and 0.5 GB of database**. Yours scales with the hours you are at the keyboard and
with `CAPTURE_INTERVAL_SECONDS`; Settings → Usage → **Data folder** shows the total for your own
copy, and `du -sh "$DATA_DIR/screenshots"` the screenshot half.

Only the screenshot half has ever had a ceiling: `SCREENSHOT_DISK_BUDGET_GB` (default 20) empties
whole day folders oldest first once it is passed. The database half grows until you say
otherwise, and `RETENTION_DAYS` is how you say it:

```bash
RETENTION_DAYS=90            # keep a quarter, today included; 0, the default, keeps everything
RETENTION_KEEP_REPORTS=true  # the default: the timelines for those days stay
```

A pass runs with the rest of the quarter-hourly housekeeping and deletes the screenshots, their
summaries, the stored window text and the app-by-app sessions older than that many days. **Today
and yesterday are never touched**, whatever the number says, and neither are your timelines,
calendar events or what the models cost. Settings → Privacy → **Keep history for** shows
the number in force and changes it.

The activity blocks stay as the record of a day whose screenshots have gone — a pass never
rebuilds a timeline from frames it just deleted. If you want the summaries gone too, set
`RETENTION_KEEP_REPORTS=false`, which also removes those days' activity blocks, and any timeline
files or friction rows an older version wrote for them. Reports written before 2026-10-05, when
Worklens stopped writing them, stay either way.

### Keep it on this Mac's own disk

Pointing `DATA_DIR` at iCloud Drive, Dropbox, Google Drive, OneDrive or a network share is the
natural thing to try — "then my history follows me" — and it is the one way to lose the history
outright. Worklens keeps a SQLite database there with a write-ahead log, and takes a lock on
`.lock` in the same folder so two Worklenses can never capture into one history. A file provider
breaks both: it can sync a `-wal` out from under an open database, which Worklens reads as
corruption and answers by moving the file aside and starting an empty one; and the lock is a
kernel lock on *this* Mac, which another Mac syncing the same folder never sees.

So Worklens checks. If `DATA_DIR` is inside one of those folders, on a `~/Library/CloudStorage`
mount, or on a volume that is not local, it says so in the menu and does not start capturing —
reading, the MCP tools and `search` all still work, so nothing you already have
becomes unreachable. The writing CLI subcommands (`capture-once`, `describe-pending`,
`describe-one`) refuse with exit code 3, and
`worklens config-dump` says so. Set `ALLOW_NONLOCAL_DATA_DIR=true` if you have
read that and want it anyway.

### Two Macs

**One install per Mac, each with its own `DATA_DIR`, and the histories do not merge.** There is
no sync, no server and no merge tool, and a shared folder is the failure above rather than a
workaround for it. Each Mac writes its own name into `app_state` on first run; if a data directory turns out to
have been written by a different Mac, the menu says which one. The name stays on your disk and
never reaches Gemini.

Moving to a new Mac is a folder copy, not a merge:

1. Quit Worklens on **both** Macs — the old one must not be capturing mid-copy.
2. Copy the whole `DATA_DIR` across, `worklens.sqlite` and its `-wal`/`-shm` sidecars included.
3. Point the new Mac's `DATA_DIR` at the copy (edit its `.env`, then `make install-env`).
4. Start Worklens there. It will say the folder came from the other Mac, once.
