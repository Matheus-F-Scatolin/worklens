# Configuring Worklens

Settings you change in the app are saved by Worklens; everything else comes from `.env`. See
`.env.example` for the full list with defaults and an explanation each — it is generated from the
key registry, so it cannot fall behind the code.

## The layers

Keys resolve in this order, first hit wins per key:

1. the process environment
2. `$WORKLENS_ENV_FILE`, if set
3. `~/Library/Application Support/Worklens/settings.json` — what Settings and `worklens config
   set` write; mode 0600, validated before anything lands in it
4. `~/Library/Application Support/Worklens/.env`
5. `./.env`
6. the built-in default

The one API key Worklens uses, Gemini's, can be typed in the app: Settings → Connections → **AI
providers** has its row — press **Connect…** or **Change**, paste the key, and Worklens saves it and
asks Google straight away (one free models-list request; no tokens, $0). It is stored
masked in the settings file above, so a layer that outranks it still wins — the row says so rather than accepting an edit that would
change nothing.

`worklens config-dump` prints every key with the layer that supplied it, secrets masked;
`worklens config get|set|unset|path` reads and writes the settings file from a terminal. A running
app keeps the old value until Settings → Advanced → Settings file → **Reload**.

`DATA_DIR` is the one key Worklens never writes for itself: `WORKLENS_ENV_FILE` is how a worktree,
a test or a script pins the data directory, and a file the app can rewrite must not outrank it.

`.env` is git-ignored and must never be committed.

## Capture

Settings → Capture is controls, not readings: a change is saved to the settings file above and
takes effect on the next screenshot, with no relaunch.

- **Source** — *Text and a picture* (the default), *A picture only*, or *Text
  only*, which never takes a picture. Anything that reads text needs the Accessibility grant;
  without it *Text and a picture* falls back to pictures only, and *Text only* collects nothing
  at all. The section says which of the two you are in.
- **Look at your screen every** and **In a meeting, every** — how often Worklens looks while you
  work, and while you are in a meeting. How long you have to be away before it stops is under
  Settings → Advanced → Capture tuning.
- **On battery** — *Keep going*, *Slow down* (the default: five times less often, still
  summarizing), or *Wait for the charger*, which keeps taking screenshots and holds the
  summarizing until you plug in. Low Power Mode counts as battery, even on the charger.
- **Screenshot size** — *Smaller files*, *Balanced* or *Sharper*, one choice standing in for the
  screenshot size and the how-much-changed cut-off. A pair you set by hand in a `.env` file shows
  as *Custom* and is left alone until you pick a preset.

The keys behind those controls, for a `.env` file or `worklens config set`. A number outside its
range is refused the same way in the app and in the terminal, with the same sentence. The
steppers walk a narrower span than the range allows — 15 s and up, 30 s and up in a meeting, one
minute and up for away — so a smaller number you set by hand keeps working but is not offered.

| Control | Key | Allowed |
|---|---|---|
| Source | `CAPTURE_SOURCE` | `both`, `screenshot`, `accessibility` |
| Look at your screen every | `CAPTURE_INTERVAL_SECONDS` | 5 to 600 |
| In a meeting, every | `MEETING_CAPTURE_INTERVAL_SECONDS` | 5 to 900 |
| Stop after you have been away for (Advanced) | `CAPTURE_IDLE_SECONDS` | 5 to 1800 |
| On battery | `CAPTURE_ON_BATTERY` | `normal`, `slow`, `describe-later` |
| Screenshot size | `CAPTURE_MAX_EDGE_PX` and `CHANGE_THRESHOLD` | 64 to 4096; 0 to 1 |
