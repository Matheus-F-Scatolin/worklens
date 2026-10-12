# Worklens — Architecture and shared building blocks

Moved from `docs/PLAN.md` §3 on 2026-09-08. Read this when adding a type, a table, a config key or a
CLI subcommand; the "Shared building blocks" table says where each kind of thing lives.

Every string a *person* reads — a menu row, a button, a Settings sentence, an alert, a notification,
what a CLI command prints — follows [`docs/copy.md`](copy.md) (#157): one noun per concept, one verb
per action, second person, and never a number formatted by hand. It governs display strings only;
column values, enum raw values, config keys and `--json` keys are named for the machine.

```
┌──────────────────────────── Worklens.app (single process) ────────────────────────────┐
│                                                                                       │
│  MenuBarExtra UI ──▶ CaptureScheduler (timer, idle/lock/meeting/pause/blocklist)      │
│                          │                                                            │
│                          ▼                                                            │
│   ForegroundContextCollector ──▶ ScreenCaptureService ──▶ ImagePipeline               │
│   (app, window title, URL)        (ScreenCaptureKit)       (downscale, JPEG, dHash)   │
│                          │                                                            │
│                          ▼  captures row (+ JPEG only when it will be described)      │
│                     SQLite (GRDB) ◀──────────────────────────────────────────┐        │
│                          │                                                   │        │
│                          ▼ pending                                           │        │
│                   DescribeWorker ──▶ GeminiClient ──▶ descriptions row ───────┘        │
│                          │            (JSON: app_key, task_key, summary, flags)       │
│                          ▼                                                            │
│                   TimelineWriter ──▶ activity_blocks                                  │
│                          │                                                            │
│   ContextSyncScheduler ──┼──▶ context_events (granola / calendar)                      │
│                          ▼                                                            │
│   StatsAggregator ──▶ the Today and Weeks pages, and the MCP `stats` tool             │
│                                                                                       │
│   LLMCallLedger (every call: tokens, USD) ──▶ CostTracker ──▶ daily budget gate       │
└───────────────────────────────────────────────────────────────────────────────────────┘
```

Two SwiftPM targets: `WorklensCore` (everything above except UI; fully testable) and
`Worklens` (SwiftUI app + CLI entry point). Every stage is runnable from the CLI
(`worklens capture-once`, `describe-pending`, `timeline --rebuild`, …) so it can
be tested without the menu bar. `describe-pending --fake` (#121) runs the describe stage with no
API keys.

### Data directory (`DATA_DIR`, `./data` in dev, Application Support in the app)

With no layer setting `DATA_DIR`, `Config.defaults(cwd:isBundledApp:)` answers `./data` beside
the working directory for a checkout and `~/Library/Application Support/Worklens/data` for the
bundled app (#116), which LaunchServices launches with `/` as its working directory and which
therefore used to fail to create `/data` and come up on a two-item "Configuration error" menu.
`isBundledApp` defaults to `Bundle.main.bundleIdentifier == Config.bundleIdentifier` — the app's
own identifier, not merely "has one", so `swift run`, the CLI and the test runner all stay on
`./data` — and is a parameter so tests can ask for either answer.

```
data/
  worklens.sqlite                 # + -wal/-shm
  taxonomy.json                   # user-editable app/task taxonomy + project list (seeded on first run)
  screenshots/YYYY-MM-DD/HHmmss_<id8>.jpg
  timeline/YYYY-MM-DD.md          # only from before 2026-10-05 (#299); kept, never written
  reports/daily/YYYY-MM-DD.md      # only from before 2026-10-05 (#298); kept, never written
  reports/weekly/YYYY-Www.md
  context/granola/<note_id>.md    # full transcripts (large), referenced from DB
  logs/worklens-YYYY-MM-DD.log
```

### Config layering and provenance (#34, #108)

Per key, first hit wins: process environment → `$WORKLENS_ENV_FILE` → `~/Library/Application
Support/Worklens/settings.json` → `~/Library/Application Support/Worklens/.env` → `<cwd>/.env` →
the built-in default. `ConfigLayer` names those six (`env`, `WORKLENS_ENV_FILE`, `settings`,
`app-support`, `cwd`, `default`) and its raw values are the labels `worklens config-dump` prints
beside each value, secrets still masked.

`settings.json` is the one layer Worklens writes itself — Settings in the reader, and `worklens
config set|unset`. `SettingsStore` owns it: a flat `{"KEY": "value"}` map at mode 0600, written
atomically, with `Config.validate(key:value:)` run before every write so the file can only hold
values that parse. It sits *below* `WORKLENS_ENV_FILE` deliberately: that variable is how
worktrees, tests, `make run` and `scripts/` pin `DATA_DIR`, and a file the GUI can rewrite must
not be able to take it away — the #34 trap one rung higher. `DATA_DIR` is excluded from the layer
outright (`ConfigKey.editableInApp` is false for it, and `SettingsStore.layerValues()` drops it
even if someone hand-edits it in). Nothing watches the file, so a `worklens config set` while the
app is running says so: the app re-reads on launch, on its own edits, and on Reload configuration.

Since #124 the Gemini API key, the only one Worklens uses, is typed there too, through Settings → Connections (Accounts until #286)
(`Worklens/Settings/AccountsSection.swift` over `WorklensCore/Config/Accounts.swift`). The
precedence above is the whole answer to "I typed a key and nothing changed": a value in the
process environment or in `WORKLENS_ENV_FILE` still wins and the row says so instead of offering
an edit, and when an `.env` layer supplies the key the row names the file rather than shadowing
it in silence. A key set here also ends the `appSupportOverrides` warning for that key, because
the App Support file is no longer the layer taking it away from the checkout.

### The blocklist overlay (#128)

The three blocklists are the one thing a layer cannot express. `BLOCKED_BUNDLE_IDS`,
`BLOCKED_TITLE_PATTERNS` and `BLOCKED_URL_HOSTS` resolve like every other key — first layer with
a value wins the whole list — and then `BlocklistOverlay` adds to and subtracts from the winner:
the effective list is `(built-in defaults ∪ .env ∪ what you added) − what you removed`. Removals
are why it is two sets and not one: `com.1password.1password` is a Swift constant
(`Config.defaultBlockedBundleIDs`), and Settings → Privacy puts a "×" on every row.

`BlocklistStore` owns the file — `~/Library/Application Support/Worklens/blocklists.json`, mode
0600, atomic, beside `settings.json` and resolved *relative to it*, so a test or a worktree that
points `settingsFile` at a scratch directory never reads the real one. `Config.loadWithProvenance`
applies it, which is the single seam for both processes: the menu-bar app and `PrivacyPolicy`
cannot disagree about what is blocked, and `PrivacyPolicy` needs no changes
because it still reads three plain lists off `Config`. `.env` is never written by any of this —
#108's objection to editing a file you also edit by hand stands; this is the #90 answer instead
(what the app writes, the app owns).

One writer, one store: Settings → Privacy (`BlocklistSection`).
Each entry is validated where it is typed: a bundle id is an identifier, a site is a bare host
(`PrivacyPolicy.normalizeHost` accepts a pasted URL), and a window title is a case-insensitive
**regex**, refused if it does not compile. A row's source (`built in` / `.env` / `yours`) comes
from the `ConfigProvenance` the load already recorded, not from a hand-kept footnote. A write from
a terminal reaches a running app on *Reload configuration*, the same rule `worklens config set`
prints.

### One registry of configuration keys (#108)

`Config.keys` (`WorklensCore/Config/ConfigKey.swift`, `ConfigKeys.swift`) is the single list of
every key: name, section, kind, default literal, one sentence of help in the second person, the
`.env.example` prose, whether the app may write it, whether it is retired (#87), and an `apply`
closure that parses one raw string into the right `Config` property. Everything else derives from
it — the parse dispatch in `Config.load(layers:)`, `dumpLines` (and so `knownKeys`),
`Config.retiredKeys`, `Config.validate`, what `SettingsStore` will accept, and `.env.example`
itself, which `EnvExample.render()` generates and `worklens config-example` prints. A test asserts
the checked-in `.env.example` is that output byte for byte, which is why an orphan section header
(what #87 left behind) cannot come back. Adding a key is one entry plus its `Config` property, then
`swift run Worklens config-example > .env.example`.

### Validation, provenance and the lenient load (#126)

The registry also carries the **rules**, so a value is checked where it is defined rather than in
whatever code happens to read it later. A key's `kind` may be `.model` (checked against
`ModelPricing.default`), `.list` (either `,` or `;`) or `.regexList` (that separator only: a comma
is legal inside a quantifier such as `{2,3}`); and a numeric key may carry a `minimum`.

Severity is split, and the split is the point:

- **Fatal** (`ConfigError`): anything that does not parse, an interval or `AUTO_UPDATE_POLL_MINUTES` below 5, a negative `DAILY_BUDGET_USD`.
- **Advisory** (`ConfigWarning`, never fatal): a model id that is in no price-table row — the
  table is pinned and date-verified, so a new id is a missing row and refusing to launch over it
  would be the worst possible answer; it just means those calls are costed at $0, which is now
  said out loud. Also a regex list written with commas, and an unknown key.

`Config.load(sources:cwd:isBundledApp:lenient:)` takes **named** layers (`ConfigSource`: layer,
file URL, values) and collects **every** error before throwing — `ConfigError.multiple`, each leaf
wrapped in `.located` with the layer and path, so a message names the file to open instead of
leaving the user to guess which of five layers it came from. The old `load(layers:)` overload
stays for tests and throws the same bare error it always did. `lenient: true` is "use defaults for
these keys and start": only the keys that failed are dropped, every other value is kept, the
built-in default stands for that session, each drop is a `.usingDefault` warning, and **nothing is
written anywhere** — `.env` remains the source of truth.

`ConfigProvenance.unknownKeys` names what no layer of Worklens reads, with the nearest known key
within an edit distance of three (`CAPTURE_INTERVAL_SECS` → `CAPTURE_INTERVAL_SECONDS`). It is
shaped exactly like the retired-key warning (#87) and inherits its two rules: **file layers only**
— a shell holds hundreds of variables that are none of Worklens's business — and **key names
only**, since a value could be an API key. Unknown keys stay non-fatal; `docs/decisions.md` has
always said a stale `.env` is not an error, and this only stops the ignoring being silent.

`ConfigReload` holds the ordering rule as a tested type rather than a comment: `reloadConfig()`
parses first and tears the stack down only on `.rebuild`. A `.keepRunning` outcome leaves capture,
the describe worker and the scheduler exactly as they were and raises one notice. `MenuState`
splits `configError` (fix the value, in this file) from `storageError` (the data directory), which
have different remedies — re-reading `.env` cannot fix a folder — and `SettingsPage` puts one
`ConfigBanner` above whichever section is showing, because while an error stands every control is
drawing `Config.defaults()` and only the banner says so.

Two rules keep a relative `DATA_DIR` meaning what it looks like it means:

- **In a file it resolves next to that file** (`Config.fileLayer`), not against the process
  working directory — a bundled app is launched with `/` as its cwd, so the documented default
  `./data` would otherwise be `/data`. In the process environment it still resolves against the
  cwd, which is what a shell one-liner means.
- **`make install-env` pins it.** `worklens install-env` (`CLI/InstallEnvCommand.swift` over
  `WorklensCore/Config/EnvInstall.swift`; `scripts/install-env.sh` is a wrapper that finds a
  binary in the checkout) rewrites a relative `DATA_DIR` to the absolute path of the checkout it
  ran from, appends one when the file sets none, leaves an absolute or `~` path alone, and prints
  the result — plus the path it replaced, so a relocation is never silent. The copy is read from
  a different directory than it was written in, so a verbatim relative path used to mean
  "wherever install-env last ran". `--data-dir <path>` pins elsewhere and `--no-pin` hands the
  directory back to the binary default.

**It merges, it does not copy (#129).** The old `scripts/install_env_rewrite.py` opened the
destination with `"w"`, so every run threw away whatever the installed file had that the checkout
did not — including anything typed into Settings before #108 gave that its own file.
`EnvInstall.plan` is the rule, and it is pure: the destination's bytes are carried through,
source-only keys are appended under one comment, and a key both files set to different values is
a *conflict* — reported as a three-column diff (key · this checkout · installed), left at the
destination's value, and taken from the checkout only under `--force`. An *empty* source value is
not a value: `Config` layers by "first non-empty layer wins", so `plan` skips a source key whose
value is blank rather than counting it as a disagreement. Without that rule the `GEMINI_API_KEY=`
`.env.example` ships — which is what a checkout looks like once the real keys live only in
Application Support (#116) — would conflict with the installed key, and `--force`, the very thing
the conflict message tells you to reach for, would write the blank over it. `--data-dir` wins its
own key without `--force`, because it is an instruction rather than a disagreement. Secrets are masked
in the diff (`ConfigKey.Kind.secret`), the file is written 0600, and nothing ever prompts: an
unattended `make setup` or `scripts/update.sh` must not be able to hang on a question.

### Which file the app read, and telling the launch paths about it (#129)

`Config.provenance(...)` answers "which files did I read?" without validating a value, so a
degraded start — `loadWithProvenance` threw on a bad value — still knows. That matters twice:
the menu shows the override line exactly when the configuration is confusing, and
`recordLaunchEnvironment` would otherwise delete a correct `.launch-env` as though there were no
override at all.

`ConfigProvenance` grew three derived facts — `devOverrideFile`, `devOverrideActive` and
`devOverrideLine` — so the one place that knows `WORKLENS_ENV_FILE` won is the one place that
words it. `MenuState.devOverrideLine` carries the sentence into `MenuModel`, which is why the
menu, Settings → General and the tests all say the same thing. `<cwd>/.env` is deliberately not
part of it: a bundled app's working directory is `/`, so that layer only ever applies to a CLI
run.

`AppModel.start()` then writes the path to `~/Library/Application Support/Worklens/.launch-env`
(`WorklensCore/Config/LaunchEnv.swift`) — a **fixed** location, never inside `DATA_DIR`, because
`DATA_DIR` is the value in dispute and a script that had to find the handshake underneath it
would already need the answer it came for. Only a real override is recorded: naming the App
Support `.env` there would promote it above `settings.json` rather than reproduce anything, so
with no override the file is removed. `scripts/launch.sh --restore` — which `scripts/update.sh`
calls, and `make run` deliberately does not — relaunches with exactly that file, and falls back
to today's rule when the record is missing or names a file that is gone.

Settings → General → Advanced renders `Config.dumpLines(provenance:)` as a key/value/source grid
over the `ConfigProvenance.files` list, each file badged *winning* / *read* / *missing* with its
own Open button, plus the `appSupportOverrides` line in amber. Everything there comes from
`WorklensCore`, so the window cannot drift from `worklens config-dump`, and the values arrive
already masked. The Storage section above it is read-only on purpose: `DATA_DIR` cannot live in
the app's own writable layer, since `settings.json`'s sibling database lives inside the folder
`DATA_DIR` names.

### First run (#116)

Nothing about a plain install needs a terminal. `Config.loadWithProvenance` records every file
it consulted, `ConfigProvenance.noFilesFound` is true when not one of them exists, and on that
`AppModel.start()` writes `~/Library/Application Support/Worklens/.env` from `EnvTemplate` —
mode 0600, in a directory created 0700 — through `FirstRunEnv.createIfMissing`, which never
touches a file that is already there. `EnvTemplate` renders from `Config.keys` like
`EnvExample` does, with two differences: only `.secret` keys are live lines (blank, waiting),
and every other key including `DATA_DIR` is commented out at its default, so a written file
changes no value and the binary stays the single source of where data lives. The menu answers
the same condition with `MenuModel.firstRunLine` — "Add your Gemini API key to get started" over
"Open .env…" — while `state.firstRun` (no Gemini key) suppresses the two missing-key
problems that would otherwise say the same thing twice. `worklens config-dump` prints "no
configuration file found; defaults in use" under its layer list, and
`worklens config-example --first-run` prints the template itself.

### `DATA_DIR` has to be local (#122)

`DataDirLocation.check` runs at every `AppModel.start()` — so at launch and after every
Reload configuration — and in `CLIEntryPoint` before a writing subcommand. When it finds
something, the app raises `SetupIssue.dataDirNotLocal` with a message naming the folder and does
not start capturing (`AppModel.dataDirBlocked` also blocks "Start capturing" and "Capture now",
so the menu cannot walk around the refusal), and the CLI exits `DataDirLocation.refusedExitCode`
(3, not the 2 a busy `run --headless` once exited, so a script that retried a busy run does not retry this one).
Read-only subcommands and everything the app does with data it already has are untouched.
`worklens config-dump` prints the warning.

The signals, in the order they are tried: the path itself under `~/Library/Mobile Documents`,
`~/Library/CloudStorage/<provider>`, `~/Dropbox`, `~/Google Drive*` or `~/OneDrive*` (symlinks
resolved first, since `~/Dropbox` usually is one); then `URLResourceKey.isUbiquitousItemKey`;
then `volumeIsLocalKey`, which catches **only** SMB and NFS mounts — iCloud Drive, Dropbox and
Google Drive all sit on the local boot volume and answer true, which is why it cannot be the
primary test; then `.icloud` placeholders, which exist only for evicted files and so are never
more than a last resort. `ALLOW_NONLOCAL_DATA_DIR=true` skips the whole check: it is a safety
catch rather than one of the tuning knobs #87 deleted, because the failure it prevents (a healthy
database renamed `worklens.sqlite.corrupt-<ts>` and replaced by an empty one) is not one to
discover afterwards.

`MachineName` is the other half: the name goes into `app_state.machine_name` at first run, and
a mismatch raises `SetupIssue.dataDirAnotherMac` — which does not block capture, since the folder
may simply have been copied here. The name stays on the disk.

The App Support file outranking `<cwd>/.env` is deliberate — it is the only file a Finder-launched
app can find — but it is how two agents' captures landed in another worktree's database. So
`Config.loadWithProvenance` logs at info (category `config`) when that file wins a key the
checkout's `.env` also sets **and the two values differ**; `ConfigProvenance.appSupportOverrides`
carries the same list, and `config-dump` prints it as a warning. Key names only ever appear in
that message — a value could be an API key. Agreement is not reported: after `install-env` the
two files agree on nearly everything, and warning about that would bury the one real conflict.

### Core tables (full DDL in issue #5)

`captures`, `descriptions`, `activity_blocks`, `reports`,
`llm_calls`, `context_events`, `app_state`, `foreground_sessions`, `ax_snapshots`,
`friction_items`, `search_fts`, `search_docs`, `coverage_events`, `outputs`, `agent_sessions`,
`agent_prompts`, `agent_turns`, `agent_session_prs`, `agent_source_files`, `project_assignments`.

**What you shipped (#314, migration `ledger-314-outputs`).** `outputs` holds one row per thing you
shipped: `source` (`github`), `kind` (`pr_merged`, `pr_closed`, `issue_opened`, `issue_closed`,
`review_submitted`; an `OutputKind` this build does not know still decodes and prints its raw
value), `at`, `repo`, `number`, `url`, `title`, `path`, `resource_key`, `external_id`,
`project_key`/`project_rule` (left null for now), `provenance` (the `gh` query that found it) and
`synced_at`. `UNIQUE(source, external_id)` makes `OutputStore.upsert` idempotent: a re-sync whose
row is unchanged writes nothing, not even `synced_at`. `Outputs/` holds `GitHubOutputs` (the pure
`gh` argument builders and JSON → `Output` mappers), `GHRunner` (`GHRunning`, the `gh` subprocess
with a 30 s watchdog, and `GHError`), `OutputSync` (the actor the context sync round calls through
`ContextSyncScheduler(outputs:)`, with its status and backoff in `app_state` under
`outputs.github.status`), `ShippedSection` (the timeline's `## Shipped`, right before
`## Context`, and the shared count line, which never sums kinds) and `ShippedMCPTool` (the ninth
MCP tool, `shipped`). `GITHUB_SHIPPED` (default `true`) gates the sync; `false` deletes the rows.
`DataEraser` and `Retention` leave the table alone. The CLI is `worklens shipped`
(`CLI/ShippedCommand.swift`).

**Company memos (#317).** `MEMO_REPOS` (comma-separated `owner/name`, empty = off) names the repos
whose merged PRs of yours are read with `gh pr view <n> --repo <r> --json files`. `MemoPathRule`
(pure, in `Outputs/MemoPathRule.swift`) keeps only `corpus/companies/<slug>/<file>.md` with
`<file>` not starting with `_`: ADDED is `memo_published`, MODIFIED/RENAMED/CHANGED is
`memo_updated`, one event per (PR, slug), publish wins. `MemoCompanyMatcher` (same file) links the
slug to a non-house catalog entry: as written, then with `-`/`_` as spaces, then without separators
against spellings minus a domain suffix; two answers are ambiguous and link nothing. No answer
creates a `company` entry named from the slug with the slug as an alias, through
`ProjectCatalog.addCompany` (`Taxonomy/ProjectCatalog+Company.swift`). `MemoOutputs.apply` is
called once per round by `OutputSync`, before its write, with the round's rows: it reads only the
merged PRs the ledger does not hold yet, plus a one-time backfill of the stored ones gated by
`app_state.memo_rule_backfilled` (rule version and repo list), then re-resolves every memo row's
project and name (a merged entry is followed to its target, and a `memo_created` row whose entry
is gone gets it back). It never fails the round (`OutputSync` logs a thrown pass at `warn` and
still writes): a PR `gh` says does not exist ("Could not resolve to a PullRequest") is skipped, and
any other `gh` failure, or a catalog that will not open, ends the pass and clears the gate, so the
next pass backfills what was not read. A `MEMO_REPOS` URL is read as its `owner/name`; an entry
with no `/` raises a config warning. Rows are `source = memo`,
`external_id = memo:<repo>#<n>:<slug>`, `title` = the company's name, `path` = the memo file,
`repo`/`number`/`url` = the PR's, `provenance = memo-path-rule v1`. They print as `You published
the memo for <name> in <repo>#<n>` and are counted per kind, never into the PR count. `info` logs
carry counts only. An empty `MEMO_REPOS` or `GITHUB_SHIPPED=false` deletes them.

**Agent sessions (#321, migration `ledger-agent-sessions-v1`).** Metadata read from the logs
Claude Code (`~/.claude/projects/`), the Claude app's Code tab
(`~/Library/Application Support/Claude/claude-code-sessions/`) and Codex (`~/.codex/sessions`,
`~/.codex/archived_sessions`) keep. Five tables: `agent_sessions` (`id`, `tool` `claude_code` or
`codex`, `host` such as `claude-desktop`, `cli`, `sdk-cli`, `codex-desktop` or `codex-exec`,
`parent_id`, `start_at`/`end_at`, `cwd`, `vcs_repo` (Codex's recorded remote), `repo`/`repo_rule`,
`branch`, `edited`, `parser`); `agent_prompts` (`record_id` PK, which is how a fork's repeated
records dedupe, `session_id`, `at`); `agent_turns` (`session_id`, `start_at`, `end_at`);
`agent_session_prs` (`session_id`, `pr_key` in `OutputStore`'s `resource_key` shape, `state`); and
`agent_source_files` (`path`, `store`, `session_id`, `size`, `mtime`, `offset`, `open_turn_at`,
`parser`, `edited`), which is how a round reads only what a log gained; a session's `edited` is
the sum of its files' counts, one per file name, so a re-read or an archived Codex rollout never
adds twice. `Agents/` holds
`AgentStoreParsers` (whitelist decoders; `version` re-reads every file when it rises; the prompt
rule is `origin.kind == "human"`, else an external main-thread user record that is not a tool
result and does not open with a wrapper tag, a compaction summary or `[Request interrupted`;
Codex prompts only from `Codex Desktop`, as `item_completed` `UserMessage` items or the older
`user_message`; a turn opens on a trigger and stretches only on the agent's replies and its
tools' results, never on an attachment, a queued message or a system note),
`RepoMap` (own PR → git remote → the one repo a root learned → folder name; a worktree folds to
its checkout, an ambiguous root stays nil, and a Codex run in a Claude worktree gets the
overlapping Claude session as `parent_id`), `PromptWindows` (each prompt claims [p−3, p+10 min],
cut at the next prompt, intersected with the host app in `foreground_sessions` and the active
blocks, split at midnight), `AgentSessionSync` (the actor `ContextSyncScheduler(agents:)` awaits
after `publishMeetings`; 30 days back the first time, 256 MB a round, status under
`agents.sessions.status`; records before the retention cutoff or inside any erased range,
`agents.sessions.erased`, are skipped, and a turn ends at the first skipped record)
and `AgentLedger` (the per-repo and per-session report, and the `sessions` lines `shipped` prints
under each PR). `Storage/AgentSessionStore.swift` writes and reads the tables; `DataEraser` and
`Retention` delete prompts and turns through `deleteActivity`. `AGENT_SESSIONS` (default `true`)
gates the sync; `false` deletes the rows. The MCP tool is `agent_sessions`
(`MCP/WorklensMCPTools+Agents.swift`); the CLI is `worklens agents` (`CLI/AgentsCommand.swift`).

**Was Worklens watching? (#146, migration `coverage-events`).** `captures` says what was on
screen and cannot say anything about time when no tick ran, so a paused afternoon, a quit and a
revoked Screen Recording grant all look like an afternoon away from the desk. `coverage_events`
(`id, at, kind, reason`) holds one content-free row per transition — `started`, `paused` (with
`reason` `user` or `permission_missing`), `resumed`, `stopped` — written by `CaptureScheduler`;
`start()` also closes a run that ended without a `stopped` at its last frame, which is what a
crash or an update looks like from the next launch. `CoverageSpans` (pure) turns those rows, plus
the `budget` skip rows `captures` already carries, into the day's uncovered spans and into the one
sentence the timeline footer and the menu's counts line say about them.
Adding rows here moves no existing number: every `DailyStats` field but `accounting` (#320) is
unchanged for a day that gained coverage rows.

#313: `stop()` writes `stopped` only when the scheduler ran (`loopTask` was set; the loop runs
while paused). A second copy of the app builds its stack and is told to quit before it ever
starts, and its `stopped` used to end the running copy's coverage for a week. The read side does
not trust a lone row either: `CoverageSpans.gaps(events:proofs:start:end:)` replays the
transitions together with *proofs* — `captures.captured_at` and `foreground_sessions.start_at`
(not `end_at`, written at quit), plus the latest of each before the range — and a proof more
than `proofGrace` (60 s) after a `notRunning` span began ends it there. Proofs never open a span,
never end `paused` or `permission_missing`, and change nothing on a day with no coverage rows.
The grace is what keeps a straggler tick after a real quit, or the frame `closeUnfinishedRun`
dated its `stopped` to, from erasing a real gap. Because a stray row outranks the `stopped`
`closeUnfinishedRun` would have written, a `started` after a span a proof ended reads as a
relaunch: the stretch from the last proof to it is `notRunning` again. Any capture row counts,
which holds because only the app writes them: the core cut removed `worklens run --once`, and
`capture-once` writes a file, not a row. `CoverageEventStore` gathers the
events, the rows and the proofs in one read, so its signatures, and `MenuCounts` and
`TimelineWriter`, are unchanged.

**Where every minute went (#320).** `Stats/DayAccounting.swift` (pure) puts every second of a
local day, cut at now for today, in exactly one of eleven buckets, highest rule first: `meeting`
(the union of `StatsAggregator.isMeeting` blocks), `away` (`isAway`), `screen` and
`batterySparse` (active blocks; sparse from a frame whose `interval_seconds` is at least
`PowerPolicy.batteryIntervalMultiplier` times its base, the meeting or the capture interval;
nil is `screen`), `asleep`/`locked`/`idle` (a skip row holds until the next capture row, the next
coverage event or the end; the last row before midnight carries in; an idle block outside every
hold is `idle`), `screen` again for a foreground session no block covers (an open one only today,
up to now), `paused`/`permissionMissing`/`notRunning` from `CoverageEventStore.gaps` (`budget`
gaps are ignored: those frames exist), and `unexplained` for the rest. `day` sums to the day
(1,440, or 1,380/1,500 when the clocks change), `window` to the stretch from the first block,
frame or session to the last, each rounded by largest remainder. `StatsService+Accounting` reads
the gaps, the transitions and the carry-in (`Database.lastCaptureRow(before:)` in
`Storage/CaptureStore+Accounting.swift`); `daily` sets `DailyStats.accounting` with its `spans`,
`weekly` and `SpanDay` drop them, and `SpanStats.accounting` sums `day` and `window` over the
range. `StatsService(baseIntervals:)` defaults to the shipped 60 s and 300 s; MCP `stats` and
`span` pass the configured ones. No migration, no Gemini call, no UI change.

**Which project each minute went to (#322).** `Stats/ProjectSpans.swift` (pure, no clock) turns a
day's evidence into `ProjectSpan`s: disjoint stretches of the accounting's `meeting`, `screen` and
`batterySparse` time, each with its project or why it has none (`no_evidence`, `undescribed`,
`redacted`, `meeting_without_company`, `conflict`), the rule that decided it, `secondsByRule`,
`absorbed` and `overridden`. Precedence is your rules (#324: URL prefix, repo, domain), meeting company (#318), agent repo (#321),
resource key (#319), `project_key` (#315), then the folded hint; same-tier disagreement is a
`conflict`, weaker keys go to `overridden`, and in a meeting only a domain rule and the meeting company decide,
so screen under a meeting counts once. A frame stands for its tick cut at the next frame; one frame
decided by a key, a hint or nothing between two stretches of one project takes it (`detour`), and a
frameless stretch of up to `TimelineWriter.minimumGapTolerance` between two such stretches is filled
(`gap_fill`); nothing joins across another bucket or a redacted or idle frame.
`Stats/ProjectSpanService.swift` is the only DB side: frames from `TimelineQueries.frames`, resource
keys through `outputs.project_key` or a GitHub repo a catalog entry names, `MeetingAttribution`, and
`PromptWindows`. Spans are computed on read, never stored. `StatsService.daily` passes them to
`StatsAggregator.daily`, where `spanSlices` builds `byProject` (share over covered seconds, meeting
rows keep #318's rules) and `spanProjects` gives each block the span covering most of it;
`TimelineRenderer.projectSuffix` reads the same `ProjectSpans.project(from:to:in:)`.
`DailyStats.projectSpans` is nil inside `weekly`. `worklens projects coverage` prints
`ProjectSpanService.CoverageReport`: minutes by kind, reason and rule, next to each frame alone.

**Project rules and assignments (#324, migration `ledger-324-project-assignments`).**
`Taxonomy/ProjectRules.swift` holds the repo and URL-prefix rules a catalog entry carries
(`ProjectEntry.rules`; a domain rule is a row in `domains`) and `ProjectRuleMatcher`, which
normalizes each kind the way it matches it (a URL prefix matches only at a host or path-segment
boundary). The rules are evidence tiers above every other one, in the order URL prefix
(`rule_url_prefix`), repo (`rule_repo`), domain (`rule_domain`), and they run before smoothing.
`project_assignments` (`ProjectAssignmentStore`) holds the stretches you claimed for a project;
they apply after smoothing, the newest winning an overlap, with the rule `assignment`.
`Taxonomy/ProjectCorrections.swift` is the dry run: it compares a day's spans before and after a
proposed rule or assignment and reports the minutes that would move. `Util/LocalInstant.swift`
reads the instants `worklens projects assign` takes (local time unless an offset is given).

**Where a range went, by project (#323).** `Stats/Timesheet.swift` (pure) builds `span`'s
`by: "project"` answer from each day's `ProjectSpan`s, `DayAccounting` and agent turns: every
project uncut, each row's totals rounded once from summed seconds and each day's cells apportioned
across the rows by largest remainder, `minutes` = screen + meeting (disjoint, so a frame in a call
counts once), agent minutes a per-day union kept out of `minutes`, `byRule` keyed by whatever rule
names the spans carry, an `unattributed` row with `breakdown` and reasons, and `notRecorded` = the
window's non-recorded buckets by name. An agent turn's repo goes to a project through a repo rule
first, then a catalog name or alias. `StatsService.timesheet(from:to:project:)` reads spans and
accounting per day, never `daily`, so `spanProjectMaxDays` (92) stays cheap. No table, no cache.

**How long a frame stands for (migration `capture-interval`).** `captures.interval_seconds` is the
scheduler's `baseInterval` when it wrote the row: the configured interval after the battery (#145)
and meeting (#66) stretches, before jitter. `BlockBuilder` joins two frames within three of those
ticks (the longer of the pair, or the shorter when only one is a meeting frame; never less than the
configured `gapTolerance`) and lets a block's last frame stand for one of its own ticks. Nil on
idle and lock rows and on every row written before the column, which build exactly as before.
Forward-only and additive.

**The day's sentence (#249, migration `day-headline`).** `reports.headline` is one nullable
column: a report's own opening line, lifted out by `DayHeadline.fromReport` when the report was
written, so that listing days costs one more column rather than one `content_md` per row. No
report has been written since the reports were cut (#298, 2026-10-05), so the column only holds
the sentences of older days. `DayIndex.entries` reads it back beside `period_start`; a day with no
report falls back to `DayHeadline.fromStats` — the apps its active blocks spent the most time in
(named the way the timeline names them) and how long the day was. From there the sentence
reaches `ReaderIndex.subtitle` and the MCP `days` table's `headline` column (empty string when
there is none). Never a window title, never a URL, never a score: this is what the day *held*.
Forward-only and additive, so a downgraded build still opens the database.

**`friction_items`, a table nothing writes (#92, #245, #299).** The daily report (#92, until
#298) and a model-free detector over the day's blocks (#245) wrote one row per friction they
found (`id, day, report_id, slug, kind, title, minutes, evidence_json, project, created_at`, plus
`source` from migration `friction-source`). #299 removed the ledger — the detector, its store, the
panel, `worklens friction`, the MCP tool and prompt — and kept the table: there is no migration
that drops it, so an older build still opens the database and the rows a user already has stay
theirs. Nothing in Swift models a row any more. `DataEraser` deletes the rows of every day an
erase covers, and `Retention` those of the days it ages out under `RETENTION_KEEP_REPORTS=false`,
both by plain SQL on `day`.

**Full-text search (#88).** `search_fts` is an FTS5 virtual table —
`fts5(text, capture_id UNINDEXED, day UNINDEXED, kind UNINDEXED, tokenize='unicode61
remove_diacritics 2')`, created and backfilled by the `search-fts` migration. One row per
(capture, kind) with `kind` in `ax` / `description` / `title` / `url`, so a frame contributes at
most four: its stored window outline, its description, its window title and its browser URL. No
model call is involved — every word searched is text that was already on disk. `search_docs`
(`capture_id`, `kind`, `doc_id`) maps a row to its FTS rowid: FTS5 cannot index its own
`UNINDEXED` columns, so deleting by `capture_id` would read every document in the table on a path
that runs once per described frame.

*Maintenance rules*, in the stores rather than in triggers, so the write path stays readable:

| Who | What |
|---|---|
| `CaptureStore.insert` / `.update` | writes the `title` and `url` rows |
| `DescriptionStore.insert` | writes the `description` row |
| `AXSnapshotStore.insert` | writes the `ax` row — the text was already put through `TextRedactor` before storage, so nothing new reaches the index |
| `AXSnapshotStore.clearText` | **removes** the `ax` row. The index must never outlive the text: under `DELETE_SCREENSHOTS_AFTER_DESCRIBE`, or on a frame flagged sensitive, a searchable copy of the outline is exactly the evidence that call exists to drop |
| `CaptureStore.deleteRange` | removes every row of every erased capture, in the same transaction as the delete. This is what `DataEraser` reaches; a virtual table takes no foreign-key cascade, so nothing else would clean it up |

Blank text writes no row, and each write replaces the row it would duplicate, so
`SearchIndex.backfill` is safe to run again.

**The taxonomy learning loop is gone (#86).** `task_proposals` and `descriptions.proposed_task`
were dropped by the `drop-task-proposals` migration, along with the weekly Opus review, its
scheduler, its Settings tab and the `taxonomy review` / `proposals` / `apply` subcommands. The
task list is frozen (the `taxonomy` CLI command went in #300), and `TaxonomyStore`
keeps the bundle-id/URL resolver plus `isKnownTask` / `canonicalTask`, which coerce a key outside
the enum to `other`. The one exception is apps a release adds to the seed (#312): `TaxonomySeed`
keeps `appsRevision` and the bundle ids each revision added, `TaxonomyMerge` (pure) folds them into
an existing file without removing, renaming or editing anything, and `AppLabelRepair` runs it once
per revision at launch (`app_state.taxonomy_apps_revision`). Its `relabelIfDue`, on the
housekeeping pass, moves past `descriptions.app_key` for those bundles to their new key in one
write and rebuilds the days touched, so stats, timelines and search agree without any reader
re-resolving (`app_state.app_labels_revision`; days still to rebuild sit in
`app_labels_pending_days`).

**Taxonomy schema v2 (#25):** a `TaskEntry` may carry `aliases: [String]`, hand-edited in
`taxonomy.json`. An alias means `isKnownTask` accepts a synonym without adding a key, while the
describe prompt and the response schema keep listing keys only.

**Taxonomy schema v3 — `projects` (#90).** `taxonomy.json` may carry
`"projects": [{"key", "name", "aliases": [...]}]`, the canonical list of what the days were
*about*. The field is optional in `Codable` (a file written before #90 decodes with `projects`
nil, and `Taxonomy.projectList` reads both as empty) and ships empty in the seed: the list is
learned, not shipped. `key` is the folded name and is what `DailyStats.byProject` groups on
across days; `ProjectEntry.matches` compares name and aliases case-, diacritic- and
whitespace-insensitively, and `validationProblems` refuses a list where two entries answer to one
spelling. `TaxonomyStore.resolveProject(hint:)` is the single-hint lookup.

Three things read the list: `ProjectNames.resolve(_:projects:)` (a hint the list claims takes
that project's key and name, and a cluster containing a claimed spelling follows it — everything
else keeps #70's clustering), `TimelineRenderer` (block headings) and `DescribePrompt` (the
`Known projects, by key` block and the `project_key` enum, which is why the prompt is `d5`; an
empty list sends neither).

**Meeting domains (#318).** `ProjectEntry.domains` (optional) lists the email domains whose
meetings count toward the entry (on the house entry: your own, which never count), and
`Taxonomy.ignoredDomains` (`ignored_domains`, optional) the ones that never count;
`projectProblems` refuses a domain claimed by two entries. `ProjectCatalog.preview` (so `learn`
and the daily `learnIfDue`) adds a `company:<domain>` entry, kind `company`, named after the
domain's first label, for every domain that alone settled a meeting in the window; `merge` carries
the source's domains (and a `company:` key's own) to the target, and `forget` of a `company:` key
adds its domain to `ignored_domains`. Both fields are absent from an older file and decode as nil.

**Kinds and keys (#315).** `ProjectEntry.kind` is optional: `house` (the firm you work at — at
most one, `projectProblems` refuses a second), `company` or `side`; an entry without one decodes
as before, and every `ProjectCatalog` edit keeps it (`setKind`, `worklens projects kind`). d5
lists the entries by key, house first with its rule, then grouped by kind, capped at
`DescribePrompt.projectKeyLimit` (40): past the cap `promptProjects` keeps house plus the entries
with the most frames in 14 days (`DescribeWorker` caches the counts for an hour). The schema
gains a nullable `project_key` enum of exactly the listed keys and drops `people` and
`confidence` (the `confidence` column is written NULL). `DescribeWorker.store` keeps a key only
when `Taxonomy.project(forKey:)` still knows it (key first, then name and aliases, so a merged
key lands on its target) and writes it to `details_json.project_key`. Readers carry it beside the
hint — `TimelineFrame.Details`, `DescriptionStore.projectKeys`/`projectObservations`,
`StatsAggregator`, `TimelineRenderer`, `SearchService`'s project filter and MCP `now` and
`vocabulary` (which also shows `kind`) — and `ProjectNames.resolve` maps a known key ahead of the
echo filter and the clustering, so a d4 row reads exactly as before.
`worklens projects check` re-asks recent house frames that have window text through
`DescribeWorker.probe(captureId:)` — a text-only d5 request through the cost gate that writes one
`llm_calls` row and no description — and `ProjectKeyCheck` (pure) picks the sample and tallies
where the answers went.

`ProjectLearning.learned(projects:byDay:)` grows the list with no model call and no review UI: a
spelling that clusters with a project the list already claims becomes an alias, and an unclaimed
cluster seen on two or more separate days becomes a project named after its most frequent
spelling. `ProjectCatalog` is the wiring — it reads the window out of
`DescriptionStore.projectObservations`, saves through `TaxonomyStore.save` (validated, version
bumped, atomic) and owns the hand edits `rename` / `merge` / `addAlias` / `removeAlias` /
`forget`. It runs once per local day from the app's housekeeping loop
(`ProjectCatalog.learnIfDue`, which records the day in `app_state.projects_learned_day`), and on
demand from `worklens projects learn` or the Log settings tab. Nothing is ever renamed or removed
automatically; `worklens projects list | rename | merge | alias | forget` and the tab are how a
wrong guess is fixed.

**`app_state` keys** are plain strings, each declared as a `static let …Key` on whichever type
owns it — grep `Key = "` for the live set. Today: `last_fingerprint` (`CaptureStore`),
`describe_backoff_until` (`DescribeWorker`), `cost_last_rollover_day` /
`budget_override_<yyyy-MM-dd>` (`CostTracker`, #137 — one row per local day holding that day's
raised budget; the rollover deletes every row but today's, so a raise never outlives its day),
`last_erase` (`DataEraser`), `last_ax_text_hash` (`CaptureStore`, #53 — the
previous frame's *redacted* accessibility text hash, cleared whenever the frontmost bundle
changes or continuity breaks), `projects_learned_day` (`ProjectCatalog`, #298),
`retired_sources_removed` (#285 — set by the one-time Slack and Gmail cleanup, which #299
removed; an older database may still hold it, and nothing reads or writes it now), `context_sync_status_<source>` (`SourceStatus.statusKey`, #141 — the last
round's time, inserted count, error, actionable flag and consecutive-failure count as one JSON
blob, so a relaunch does not show "never synced" for a source holding thousands of events;
`retryAfter` is re-derived from `lastFailureAt` + `ContextSyncScheduler.backoff(after:)` rather
than stored, since a stored deadline the Mac slept through would be meaningless), `last_vacuum_at` / `start_capturing_on_launch` / `budget_banner_day` (`AppModel`, the last being the local day the "daily budget reached" banner was posted for — `CaptureScheduler` sets and clears `.budgetExceeded` per frame, so the latch is the day and not the transition, #149),
`screen_recording_granted_at` / `permission_incident_started_at` /
`skip_accessibility_advisory` / `skip_browser_advisory` (`AppModel`, #117 — respectively: the
first time Screen Recording was ever seen granted, which is the only thing that tells "not on
yet" from "lost"; when the current outage began, so a relaunch re-raises the menu line without
re-posting the notification; and the two "don't remind me" flags behind Settings →
Permissions), `onboarded_at` (`AppModel`, #131 — when the welcome window was finished, or
written silently under an install that predates it; it decides whether the window appears at
all; an older build's `setup_started_at` row is no longer read), `show_dock_icon`
(`AppModel`, #147 — Settings → General → "Keep Worklens in the Dock"; absent means off, a Dock
icon only while a window is open, and it is handed to `DockPresence.pinned` in `start()`), `appearance`
(`AppModel` — Settings → General → "Appearance"; `system`, `light` or `dark` as `AppearanceChoice`, absent
meaning `system`, handed to `NSApp.appearance` in `start()` and on every change), `advisories_dismissed_at`
(`AppModel`, #136 — when the menu's one collapsed optional-permissions row was dismissed; deleted
again the moment Settings → Capture → Access is opened, which is where the row leads, so it silences
the row without silencing the permission), `notices`
(`NoticeStore`, #110 — the last `NoticeStore.limit` notices as a JSON array), `update_pending`
(`UpdatePending`, #150 — the commit that was running when "Update and restart…" quit the app,
compared with the `Info.plist` stamp on the next launch so Worklens can say it came back, and
cleared whatever that comparison decides), `pause_hotkey`
(`HotkeySpec`), `capture_paused_until` (`CaptureScheduler`, #113 — the deadline of the pause in
force, empty for "until you resume"; written by `pause(until:)`, deleted by `resume()`, by
`start()` and by the expiry inside `performTick`, and deliberately *not* by `stop()`, which runs
on the way out of every quit), `run_state` / `run_started_at` / `expected_restart_at` (`RunMarkers`, #156 — the clean-exit marker the app writes at launch and at the end of `shutdown()`, when that run started, and the claim `worklens expect-restart` records before `scripts/update.sh` SIGTERMs the app so a planned restart is not reported as a crash; the claim expires after `RunMarkers.expectedRestartWindow`, and **only the menu-bar app** writes the first two — the same binary is every CLI subcommand, and a `worklens search` that cleared the marker would manufacture a crash), `app_permissions` (#156's permission snapshot; nothing has written or read it since #301 removed the diagnostics bundle, and a row an older build left stays where it is), — since #36 — `google_account_email` (`AppStateGoogleAccountRecord`): the
address of the connected Google account, recorded when you connect in Settings → Connections, because an address is not a
secret. Keychain access is bound to the reading binary's *exact* code hash — every rebuild,
certificate or not, is a new keychain partition (`docs/decisions.md`, "The Keychain dialog after a
rebuild cannot be fixed in code"), so decrypting `dev.worklens.google` from a build this Mac has
not authorised raises the macOS access dialog; keeping the address here lets Settings → Connections name the
account without that read.

One `Database` (`Sources/WorklensCore/Storage/Database.swift`) owns the connection and exposes
`writer: any DatabaseWriter` — a `DatabasePool` on disk, a `DatabaseQueue` for
`Database.inMemory()` in tests. One repository struct per table (`CaptureStore`,
`DescriptionStore`, `ActivityBlockStore`, `LLMCallStore`,
`ContextEventStore`, `AppStateStore`, `ForegroundSessionStore`, `AXSnapshotStore`), each
constructed with that `Database`. Record structs live in `Sources/WorklensCore/Models/` and are
named after the table (`Capture`, `Description`, `ActivityBlock`, `Report`,
`LLMCall`, `ContextEvent`, `ForegroundSession`, `AXSnapshotRecord`; `friction_items` has none, #299); ids are lowercase UUID
strings from `Identifiers.new()` — except `ax_snapshots`, whose primary key *is* its
`capture_id`, because a frame has at most one outline.

### Shared building blocks

| Where | What |
|---|---|
| `WorklensCore/LLM/Common.swift` | `JSONValue`, `LLMError`, `LLMUsage`, `ModelPricing` (the only place prices live), `URLSession.worklens` (60 s) and `.worklensLong` (600 s / 900 s) |
| `WorklensCore/Cost/` | `CostGate` + `CostPolicy` (what the budget stops) + `AlwaysAllowCostGate` (the test default), and `CostTracker` — the real gate over `llm_calls`, and the only place today's spend is cached |
| `WorklensCore/Privacy/` | `PrivacyPolicy` (bundle / title / host, in that precedence, returning the `skip_reason` a blocked frame carries), `TextRedactor` (the one place a credential or a payment instrument is taken out of a string, before it is stored or sent) , `DataEraser` (delete a stretch and leave the day consistent) |
| `WorklensCore/Storage/DiskBudget.swift` | the screenshot disk budget: `daysToSweep` is pure over `[ScreenshotDay]`, `sweep()` is the filesystem half |
| `WorklensCore/Privacy/Retention.swift` | #144's age policy, the other half of `DiskBudget`: `oldestKeptDay(days:today:timeZone:)` is pure over a clock — counting includes today, and the answer is clamped so today and yesterday survive any `RETENTION_DAYS` — and `sweep()` deletes `captures` (descriptions and `ax_snapshots` cascade), their JPEGs and `foreground_sessions` older than it. It deliberately does **not** rebuild the affected timelines, delete `friction_items` or write `app_state.last_erase`, which is what separates it from `DataEraser`: the blocks are the surviving record of an aged-out day, and the user did not erase anything. `RETENTION_KEEP_REPORTS=false` is the one path that also drops those days' blocks, `friction_items` rows (plain SQL, #299) and timeline files an older build wrote; reports are never deleted, whatever the setting. Both deletion paths share `CaptureStore.deleteRange`, `ForegroundSessionStore.deleteRange` and `ScreenshotPaths.unlink`, so the per-table rules cannot diverge |
| `WorklensCore/Util/FileLog.swift` | the file half of `Log`: one file per day under `DATA_DIR/logs`, buffered, pruned at 14 days, plus `Log.redactForLog` |
| `WorklensCore/Util/InstanceLock.swift` | `flock` on `DATA_DIR/.lock`, so two Worklens processes can never both capture into one history |
| `WorklensCore/Config/DataDirLocation.swift` | whether `DATA_DIR` is somewhere SQLite can be trusted (#122): `check(_:home:probe:)` returns the provider ("iCloud Drive", "Dropbox", "a network volume"), the `Signal` that gave it away and the abbreviated path, plus the wording all three callers share (`menuMessage`, `explanation`, `fixAdvice`). Pure — the filesystem questions live in an injected `Probe`, so the tests cover every provider without a cloud folder |
| `WorklensCore/Util/MachineName.swift` | which Mac this is (`Host.current().localizedName`), recorded in `app_state.machine_name` on first run and compared on every launch: `Match` is `.firstRun` / `.same` / `.different`, and a difference restamps the row so a renamed Mac says it once while two Macs taking turns say it every launch |
| `WorklensCore/Util/RelaunchPlan.swift` | the shell one-liner that quits and comes back (#117): wait out this process's own pid with `kill -0`, then `open` the bundle. `scripts/update.sh`'s order, and the only one that survives `SingleInstance`; the wait is on a pid because `update.sh`'s `pgrep -a -f "$APP_BIN"` would match the helper's own command line |
| `WorklensCore/Util/CheckoutLocator.swift` | which checkout a bundle came from — `WLRepoPath` first, the bundle's grandparent second (#119); `AppModel.repoRoot` is one call to it |
| `WorklensCore/Util/BundleLayout.swift` | whether the running binary is the one inside `Worklens.app` or the loose development build, and that bundle's `Info.plist` — both asked of the resolved executable path rather than of `Bundle.main`, which is the symlink's directory when the CLI is reached through `worklens` (#119) |
| `WorklensCore/Capture/ImagePipeline.swift` | `FrameFingerprint`, downscale, JPEG, `changeScore`, `hamming`; `ScreenshotPaths` for on-disk layout |
| `WorklensCore/Capture/SystemStateMonitor.swift` | `SystemStateProviding` (locked / asleep / idle seconds) and `SystemStateHandlers` — `onWake`, `onLock`, `onSleep`. Several observers may register; `start(owner:handlers:)` installs the OS observers once and `stop(owner:)` removes only that owner's |
| `WorklensCore/Capture/ForegroundSessionRecorder.swift` | `AppActivationObserving` + `ActivatedApp` (the `NSWorkspace.didActivateApplicationNotification` seam) and the recorder that turns switches into `foreground_sessions` rows |
| `WorklensCore/Capture/AccessibilityPermission.swift` | the Accessibility grant — `isTrusted`, `request()`, `openSettings()`, `settingsHint`; same shape as the Screen Recording flow |
| `WorklensCore/Capture/AutomationPermission.swift` | whether this app may drive a browser over Apple events — `Status` (`allowed` / `denied` / `notRunning` / `notAsked`), `status(forBundleID:)`, `displayName(forBundleID:)`, `browsers()`, `openSettings()`, `settingsHint`; same shape as `AccessibilityPermission`. Reading passes `askUserIfNeeded: false`, so no tick can prompt (#64). `request(forBundleID:)` is the one call that asks — it blocks until the user answers, so it hops off the main thread and is reached only from the per-row button in Settings → Capture → Access, which `Status.canRequest` shows for `notAsked` alone; `applying(_:toBundleID:in:)` moves that one row's badge (#79) |
| `WorklensCore/Capture/AXWalk.swift` | the pure half of the accessibility read: `AXNode`, `AXElementSource` (the seam the fixture tree implements), `AXRoles`, `AXWalkLimits`, `AXWalker` (the focused-first walk) and `AXOutline` (render, truncate, SHA-256) |
| `WorklensCore/Capture/AccessibilitySnapshotter.swift` | `AXSnapshot` + `Coverage.classify`, `AXHeader` + `AXHeaderProviding` (the cheap pre-blocklist read of #55), `AccessibilitySnapshotting` (`snapshot(pid:)`, `snapshot(pid:header:)` and `header(pid:)`, plus `resetEnhancedUserInterface(pid:)` — all but the first default to a no-op or to the plain walk), and the live `AXUIElement` implementation |
| `WorklensCore/Search/` | `SearchKind` and `SearchIndex` (the index-maintenance calls the stores above make, each taking the GRDB connection so the index change joins the transaction of the row it describes), `SearchQuery` (the pure escaping half: every bare term is re-emitted as a quoted FTS5 phrase, so `-`, `*`, `:`, `(` and `NOT` typed at a shell are searched rather than parsed, while a double-quoted run stays one phrase and a trailing `*` stays a prefix search) and `SearchService` — `search(query:days:limit:)`, ranked by bm25 with `description` weighted above `title`, `url` and `ax`, and hits that fall inside one `activity_blocks` row collapsed so a 40-frame reading session is one result with its best snippet, plus `page(query:days:offset:limit:)` → `SearchPage` (#244: the same read with an offset, the total behind it, and `isTotalExact`, which is false when the capped scan may have cut rows off — the reader pages with it and says both numbers). `search` is that page at offset zero, so `worklens search` and #89's MCP `search` tool answer byte for byte what they answered before |
| `WorklensCore/Storage/AXSnapshotStore.swift` | `ax_snapshots` reads and writes, and `clearText` (retention's only lever on the table) |
| `WorklensCore/Artifacts/` | #319, all pure: `ArtifactKey` (the document a frame was of — a Google Docs, Sheets or Slides id, a GitHub PR or issue, or a local path — resolved on read from `browser_url`, else `ax_snapshots.document_url`, from scheme, host and path only), `DocumentTime` (seconds per key over the screen-active frame weights `byProject` reads, and the `byDocument` slices) and `OutputViewTime` (the `shipped` join: a GitHub row's repo and number against the frames' keys over the 30 local days up to its day, only the latest row per key credited) |
| `WorklensCore/Storage/CaptureStore.swift` | `captures` reads and writes, the `app_state` keys the next tick compares against (`last_fingerprint`, `last_ax_text_hash`), `browserBundlesWithoutURL(day:)`, the browsers that got no URL out of today from either reader, which is what Settings → Permissions' #64 line is computed from, and `fetchLastFrame(day:timeZone:)` (#151 — the newest row of **one local day**, joined to two columns of its description; the MCP `now` tool reads it, and the menu's "Last frame" rows went with #299) |
| `WorklensCore/Config/Config.swift` | every `.env` key, typed; `Config.load()` / `loadWithProvenance()`, the registry-driven parse dispatch and `Config.validate(key:value:)`, plus `ConfigLayer`, `ConfigSource` and `ConfigProvenance` — which layer supplied each value, `retiredKeys` (the keys #87 turned into constants), `unknownKeys` and the advisory `warnings` (#126). `ConfigError` gains `.located` (layer + file) and `.multiple`; `ConfigWarning` is the never-fatal half |
| `WorklensCore/Config/ConfigKey.swift`, `ConfigKeys.swift` | `ConfigSection` and `ConfigKey` — the one registry every key list derives from (#108), including each key's validation rule: `Kind` (`.model`, `.list`, `.regexList`, …) and `minimum` (#126) |
| `WorklensCore/Config/ConfigReload.swift` | `ConfigReloadOutcome` — parse before teardown — and the sentences the reload, the failure and "use defaults for these keys" say (#126) |
| `WorklensCore/Config/SettingsStore.swift` | the app-owned layer: `settings.json` at mode 0600, validated and atomic, what Settings and `worklens config set` write |
| `WorklensCore/Config/Blocklists.swift` | `Blocklist` (which key, what an entry must look like, what is already blocked), `BlocklistOverlay` + `BlocklistStore` (the app-owned additions and removals in `blocklists.json`) and `BlocklistRow`/`BlocklistSource` — what Settings and the menu both read (#128) |
| `WorklensCore/Config/Accounts.swift` | #124's Accounts section as pure values: `AccountRow` (masked value, which `ConfigLayer` won the key, whether the row is editable here and what to say when a `.env` supplies it), `Accounts.normalize`/`entryError`/`shapeWarning` (trim, refuse the impossible, warn about a prefix — no network call), and `AccountVerifier`, the `Verify` button: one `KeyProbing.probeKey` call and one $0 `llm_calls` row at purpose `verify` |
| `WorklensCore/Config/KeyProbe.swift` | `KeyProvider`, `KeyVerdict`, `KeyProbe` and the `KeyProbing` seam `AccountVerifier` calls; `LiveKeyProbe` is the free `GET /v1/models` and `GET /v1beta/models`, which cost no tokens — moved out of #118's doctor when #301 removed it |
| `WorklensCore/Config/EnvExample.swift` | renders `.env.example` from the registry; `worklens config-example` prints it and a test holds the checked-in file to it |
| `WorklensCore/Config/EnvTemplate.swift` | the same file rendered for a first run: secrets live and blank, every other key commented at its default (#116) |
| `WorklensCore/Config/FirstRunEnv.swift` | writes that template at 0600 when no `.env` exists anywhere, and never over one that does |
| `WorklensCore/Util/DayBoundaries.swift` | the only place local `YYYY-MM-DD` days convert to instant ranges |
| `WorklensCore/Util/Format.swift` | #157: every number, clock and date a *person* reads — `money`, `clock`, `shortDate`, `day`, `cadence`, `decimal`. Each takes a locale that defaults to `Format.fixed` (`en_US_POSIX`), which reproduces the exact strings this repository already ships, and the app passes `.autoupdatingCurrent` at the sites a real person is looking at (`MenuState.locale`, `TodaySnapshot`, Settings, the About window's build stamp). What deliberately stays fixed: `SpendCSV`, whose strings land in a file, and the CLI's own output, which is piped and grepped |
| `WorklensCore/LLM/VisionDescriber.swift` | the model seam: one frame in / one JSON document out. The client supplies its own `provider`, which is the label written to `llm_calls` and `descriptions` (#87 retired the keys that only ever named it) |
| `WorklensCore/LLM/FakeProvider.swift` | #121's offline describer, `FakeDescriber`: deterministic, obviously-synthetic output, provider `fake`, 0 tokens and $0.00 in the ledger. Selected only by `--fake` on `describe-pending`; no config key reaches it |
| `WorklensCore/Describe/DescribeHealth.swift` | #125: whether the describe queue is moving — `.ok` / `.holding(until:reason:)` / `.failing(message:httpStatus:)` — plus `classify(_:provider:)`, which turns one describe error into an error *class* ("Gemini rejected the key") and a `isRefusal` flag. The one place a provider's response body is looked at and thrown away: nothing downstream, log or menu, ever carries it. `DescribeWorker` raises it through `healthHandler`; `MenuState.describeHealth` renders it. A refusal (400 `API_KEY_INVALID` / 401 / 403, and 429 after the client's own retries) holds the whole queue instead of spending the frame's three attempts, and `DescribeQueries.requeueRejectedFailures` puts back the frames an earlier build had already marked `failed`. `keyWasRejected(httpStatus:error:)` (#189) is the same line drawn over a stored `llm_calls` row instead of a live error — 401, 403, or a 400 whose `error` text satisfies `saysKeyInvalid` — and is the only thing that repair re-queues on, so a plain 400 about the frame itself (an oversized image, a malformed request) is left `failed` instead of being re-described at every reload |
| `WorklensCore/Stats/` | `DailyStats`/`WeeklyStats` and `StatsAggregator` (pure), `StatsService` (the DB side), `ISOWeek`, `DayIndex` (#134 — one grouped query per day: frames, described, whether there are `activity_blocks` to draw a timeline from, and their minutes; `MCPDay`/`days(limit:)` are the frozen answer the MCP `days` tool gives, `entries(limit:)` the reader's fuller one), `DayAccounting` (#320 — pure, every minute of a day in one of eleven buckets; `StatsService+Accounting` reads what it needs), `ProjectSpans` (#322 — pure, every covered minute on one project span with the rule that decided it; `ProjectSpanService` reads the evidence), Timesheet (#323 — pure, span's by-project table) and `ProjectNames` — the pure clean-up that turns the describer's free-text `project_hint` into the handful of names `DailyStats.byProject` is keyed on (#70), folded onto `taxonomy.json`'s canonical `projects` where the list claims them (#90). Since #91 the same names also key `DailyStats.threads` (`ThreadStat`: visits, re-entries, longest run, median gap) and `WeeklyStats.projectLedger` (`ProjectLedgerRow`, project × day minutes) |
| `WorklensCore/Taxonomy/` | `Taxonomy` (apps, tasks, and #90's `ProjectEntry`), `TaxonomySeed` (plus #312's `appsRevision` / `additions`), `TaxonomyStore` (the file side: seed, 30 s reload, `resolve`, `resolveProject`, validated `save`), `TaxonomyMerge` and `AppLabelRepair` (#312: seed apps merged into an existing file once, past frames relabelled), `ProjectLearning` (pure: which spellings are aliases and which cluster has earned being a project) and `ProjectCatalog` (the DB + file wiring, and every hand edit the CLI and the Projects settings tab make) |
| `WorklensCore/Timeline/` | `TimelineFrame`, `BlockBuilder` (pure: frames → `activity_blocks`), `TimelineRenderer` (also the home of the `isShort` / `nest` / heading-label / totals rules, which moved back from #160's `TimelineLayout` when #297 cut the Timeline page), `TimelineWriter` (the DB side: it rebuilds `activity_blocks` and renders `markdown(day:)`, and since #299 writes no file). Since #51 `build` also takes the day's `foreground_sessions` and snaps a run's bounds to the switch instants they record, so a block begins when the user actually switched instead of at the frame after it — a run only moves for a session on its own first frame's bundle, and a day with no sessions renders byte for byte as before. Since #69 `TimelineFrame` also carries `document`, `projectHint` (parsed out of `descriptions.details_json` in `TimelineQueries`, so nothing downstream touches JSON) and the OS-reported `appName`; the renderer prints the block's dominant `document` as `Topic: …` in place of `Window: …` whenever the window title is only the app's own name ("Claude", "Granola"), for nested entries too, as prose. #94 collapses runs of sub-minute blocks in `TimelineRenderer.collapsedRun` — presentation only, `activity_blocks` and every number in `DailyStats` keep all of them. Since #90 `render` also takes the canonical `projects` and each screen block's heading ends with the project its frames named (`## 09:07–09:18 · Claude Desktop · Chatting with ai · worklens (11m)`), by the same most-frequent rule as the `Topic:` line; a day whose frames named nothing renders exactly as before. |
| `WorklensCore/Context/` | `ContextSyncSource` + `SyncResult`/`SourceStatus`, `ContextSyncScheduler`, `ContextSources` (the registry), `ContextBody` (the ≤ 2k inline rule and the body files), `ContextBlocks` (meetings, and #94's away time, → `activity_blocks`), one file per source under `Context/Sources/` and `Context/Google/` (where `GoogleAuth` pairs the grant — `KeychainTokenStore` or `FileTokenStore`, per `GOOGLE_TOKEN_STORE` — with `GoogleAccountRecord`, the non-secret address in `app_state`, and `GoogleGrantStatus`, what a status surface may say without decrypting anything) |
| `WorklensCore/MCP/` | the MCP server (#89), all of it pure or read-only: `JSONRPC.swift` (newline-delimited JSON-RPC 2.0 — `JSONRPCRequest.decode`, the five error codes, the one-line encoder), `MCPServer` (`handle(line:)` — one line in, zero or one line out, which is the whole protocol — plus `serve(_:)` over the `MCPTransport` seam), `MCPTool`/`MCPToolRegistry`/`MCPToolResult` (a declared tool and its `tools/call` answer; a thrown `MCPToolError` becomes `isError: true` content, an unknown tool name becomes `-32602`), `MCPStdioTransport` (the fd pair) and `WorklensMCPTools.registry(config:db:taxonomy:)` — the ten tools themselves (the ninth, `shipped`, lives in `Outputs/ShippedMCPTool.swift`, #314; the tenth, `agent_sessions`, in `MCP/WorklensMCPTools+Agents.swift`, #321) |
| `WorklensCore/Context/` | `ContextSyncSource` + `SyncResult`/`SourceStatus` (whose `lastErrorWasCredential` is the line between "paste a new token" and "try again later", #135), `ContextSyncScheduler`, `ContextSources` (the registry), `IntegrationSetup` + `IntegrationCard`/`IntegrationCards` (#135 — what Settings → Connections draws: the value sentence, the "What is stored" rows, the numbered setup steps and their links, the per-field paste rules `entryError`/`shapeWarning`, and `ConfigLayer.isWritableInApp`/`lockedNote`), `IntegrationTester` (the Test button: `GranolaSource.check` = one note, writing nothing), `IntegrationRemoval` (#141 — taking a source back out: `plan`/`deleteSyncedData` count then remove the rows, the body files and the blocks and name the days to redraw, `clearState` forgets the stored status, `credentialKeys` names what Worklens itself may remove, and `revokeURL`/`revokeTitle` are the provider page it cannot), `ContextBody` (the ≤ 2k inline rule and the body files), `ContextBlocks` (meetings, and #94's away time, → `activity_blocks`), one file per source under `Context/Sources/` and `Context/Google/` (where `GoogleAuth` pairs the grant — `KeychainTokenStore` or `FileTokenStore`, per `GOOGLE_TOKEN_STORE` — with `GoogleAccountRecord`, the non-secret address in `app_state`, and `GoogleGrantStatus`, what a status surface may say without decrypting anything) |
| `WorklensCore/MCP/` | the MCP server (#89), all of it pure or read-only: `JSONRPC.swift` (newline-delimited JSON-RPC 2.0 — `JSONRPCRequest.decode`, the five error codes, the one-line encoder), `MCPServer` (`handle(line:)` — one line in, zero or one line out, which is the whole protocol — plus `serve(_:)` over the `MCPTransport` seam), `MCPTool`/`MCPToolRegistry`/`MCPToolResult` (a declared tool and its `tools/call` answer; a thrown `MCPToolError` becomes `isError: true` content, an unknown tool name becomes `-32602`), `MCPStdioTransport` (the fd pair), `MCPDayIndex` (the one query behind `days()`), `MCPSmokeTest` (#140 — `clientConfig`, configuration resolved the way the client will resolve it, and `run`, an in-process `initialize` + `tools/list` over a **read-only** `Database.readOnly(dataDir:)`, reporting the tool count and the `DATA_DIR` the launched server would read) and `WorklensMCPTools.registry(config:db:taxonomy:)` — the ten tools themselves (the ninth, `shipped`, lives in `Outputs/ShippedMCPTool.swift`, #314; the tenth, `agent_sessions`, in `MCP/WorklensMCPTools+Agents.swift`, #321) |
| `WorklensCore/Diagnostics/` | what is left of #118's folder once #301 removed the doctor and the bundle: `RunMarkers` (#156) and `MCPClientConfig`, the whole Claude Desktop entry (#140): `parse`/`read`/`health` over `claude_desktop_config.json`, and `plan`/`install`, which copies the old file aside with a timestamp, merges **only** the Worklens entry — under the name the user gave it, when they renamed one — and refuses a file it cannot parse rather than replacing it. `installedKey`/`remove` are its mirror: the same backup, the same one-key edit, `mcpServers` left in place even when it ends up empty. Keys are masked through `Config.mask` in the text output and in `--json` alike |
| `WorklensCore/Util/SigningIdentity.swift` | two signing questions: `hasIdentity(named:)` asks the **keychain** whether a build could be signed properly (`security find-identity -v`, what `sign.sh` tests), and `runningTeamIdentifier` reads the Team ID from **this process's** signature through `SecCodeCopySelf` + `SecCodeCopySigningInformation`, with no subprocess. Moved out of `AutoUpdater` for #118; the updater calls `hasIdentity`, and Settings → Connections reads `runningTeamIdentifier` to pick where the Google token is stored (#139) |
| `WorklensCore/UI/` | `MenuState` → `MenuModel` (the pure state-to-labels mapping the menu bar renders), `MenuRow` / `StatusGlyph` (#132 — one informational menu row as `{kind, glyph, text}`, the glyph's raw value being the SF Symbol name so Core names a symbol without importing SwiftUI), `MenuCounts` (today's frames/described/pending/failed/blocked/sensitive/redactions/spend, in four queries), `LastFrame` (#151 — what became of the newest frame, as `{at, appName, outcome, summary}` plus the pure `outcome(describeStatus:skipReason:isRedacted:isSensitive:)` mapping, which the MCP `now` tool reads), `NotificationCopy` and `BannerLatch` (#149 — every banner's words in one voice, and the two pure decisions behind the scheduler's own two: whether a timed pause that stopped being in force actually ran out, and which local day the "budget reached" banner has already been posted for), `Activity` / `UpdatePending` (#150 — one thing being done right now, which turns the status glyph `.busy`, plus the "Worklens is back" line after an update), `StatusLevel` (#109), `Notice` / `NoticeKind` / `NoticeAction` / `SetupIssue` (#110), `ScreenRecordingCopy` (#117 — every sentence about a Screen Recording grant that is not in force, in the two wordings "not on yet" and "lost") `WorklensMark` (#114 — the app icon and every menu-bar glyph as CoreGraphics paths), and #134's reader half: `ReaderModel` (`ReaderSelection`/`ReaderDay`/`ReaderWeek`/`ReaderIndex`/`ReaderDocument`/`ReaderCopy`, the paging, and `ReaderTick` — which open page the minute refresh rebuilds). Here rather than in the app target so it is unit-testable, and — for the mark — so `scripts/render-icon.swift` can compile against the same file the menu bar draws from. |

**The toolchain checks are `scripts/doctor.sh`** (`make doctor-toolchain`, run at the top of `make build` and never able to fail it), because a Swift subcommand cannot diagnose the toolchain that failed to build it.

**PRIVACY.md's destinations table is the network allow-list, and a test enforces it (#120).**
`Tests/WorklensCoreTests/NetworkDestinationsDocTests.swift` walks every `.swift` file under
`Sources/`, pulls the host out of each quoted `"http…"` literal (a URL in a comment is not a call,
which is what the leading quote separates), and asserts each one appears in the
"What leaves your machine" table — plus a second pass for network-capable `git` subcommands run
through `Process`, because the auto-updater's `git ls-remote origin refs/heads/main` reaches GitHub
with no URL literal anywhere in the file. **Adding a host means adding a row**, naming what is
sent, when, and how to turn it off. PRIVACY.md is the single source of truth; the README's shorter
table under the hero is a copy for findability and is not parsed, so it cannot be what drifts.
Loopback (`127.0.0.1`, from `Context/Google/LoopbackReceiver.swift`) is exempt: it never leaves the
Mac. The scan follows the `#filePath` precedent in `MCPToolsTests.argumentsAreNotLogged` and stays
offline.

**The MCP server is read-only and lock-free (#89).** `worklens mcp` speaks newline-delimited
JSON-RPC 2.0 on stdin/stdout — `initialize` (protocol version `2025-11-25` or `2025-06-18`, `capabilities.tools`, the app icon in `serverInfo.icons` from `MCPServerIcon`),
`notifications/initialized`, `ping`, `tools/list`, `tools/call` — and exposes, among others:
`search` (#88's `SearchService`), `timeline` (`TimelineWriter.markdown(day:)`, the live rendering,
no rebuild and no file written), `stats` (`StatsService.daily`/`weekly` through
`StatsAggregator.prettyJSON`), `context_events` (`ContextEventStore.fetch(from:to:sources:)` with
bodies cut to 400 characters by `ContextBody.oneLine`; since #318 each meeting's
`MeetingAttribution` company and rule, and an optional `company` filter) and `days` (`MCPDayIndex`, which since #134 is a typealias for `Stats/DayIndex.swift` — `captures` grouped by
`date(captured_at, 'localtime')`, with each day's headline). The `report` tool went with the
reports (#298), and `friction` with the ledger (#299). Every result is one
`text` content block. Two invariants hold the design up: **stdout is the protocol**, so
`MCPCommand.run` duplicates fd 1 and points fd 1 at stderr before loading anything (`Log` writes to
os_log and `FileLog`, never stdout, and `WorklensCore` contains no `print`); and the command is
**takes no instance lock** on purpose, because the MCP client launches it
while the menu-bar app is running. Opening the database still runs `Migrations.migrator`, exactly
as `search` does — the client launches the binary inside `Worklens.app`, so its schema is
the app's own. No new table, no new config key: the server reads what is already stored.
`serve(_:trace:)` hands every request's `MCPServer.traceLine` — method, tool name, outcome,
milliseconds, never arguments or results — to a closure `MCPCommand` points at stderr, which is
the client's own log of the server. Because the server shares the menu bar's binary,
`scripts/update.sh` and `scripts/install.sh` quit the app through
`scripts/app-process-pattern.sh`, which matches the binary with no subcommand, `app` or `run`
and leaves `Worklens mcp` running.

**Two shared conventions** the timeline writer and the aggregator both depend on are named in
`StatsAggregator`: `inactiveKeys` (what counts as idle), `meetingTaskKey` and `awayAppKey`.

**`REPORT_LANGUAGE` (default `en`, #157).** Which language the model writes each summary in, as
a BCP-47 code; the name is from when it also set the reports' language, kept so an existing `.env`
keeps working. `ReportLanguage` (`WorklensCore/Config/ReportLanguage.swift`) turns it into the
single sentence appended to `DescribePrompt.systemInstruction` — and returns nil for English, which
is what keeps the prompt byte-identical for everyone who never sets the key
(`ReportLanguageTests`). The default is a constant rather than `Locale.current`: a default that
changed with System Settings would change what the prompt says from one machine to the next, and
with it every snapshot test. Only the prose changes — keys, slugs and app names stay English.
Settings → Capture edits it.

**Config keys added in M5:** `CONTEXT_SYNC_MINUTES` (default 15) — how often the context sources
are pulled. (`GRANOLA_MODE` was removed in #87 along with the local-cache source it selected.)
Since #135 it is a control rather than a line of text (Settings → Advanced → "Sync sources every" since #286), and the two
credential key `GRANOLA_API_KEY` (and the two `GOOGLE_CLIENT_*` ones) are pasted there: all four
are `editableInApp`, so they are written to `settings.json` through
`SettingsStore` like every other setting the app owns (#108). A reload whose changes are confined
to `ConfigReload.contextKeyNames` — the `ConfigSection.context` keys — rebuilds only
`AppModel.contextSync` (`ConfigReload.onlyContextChanged`), so editing an integration never stops
capture; `AppModel.configGeneration` is bumped by both reload paths and is what tells a Settings
pane holding derived state to re-read it.

**Redaction is one pure function with a fixed list of kinds (#49).** `TextRedactor` is a
stateless `Sendable` struct whose built-in regexes are compiled once into a static rule table, so
the capture tick can call it on every frame off the main actor. It replaces exactly six things —
`CARD` (13–19 digits bounded by non-digits *and* Luhn), `IBAN` (mod-97), `OTP` (6–8 digits within
30 characters of a word meaning "code"), `SECRET` (`sk-`, `AIza`, `xox?-`, `ghp_`/`github_pat_`,
`AKIA`, JWTs, PEM private-key blocks, `Bearer …`), `PASSWORD` (`password=`/`senha=`/`pwd=`/`passwd=`
values) and `CUSTOM` (`REDACT_EXTRA_PATTERNS`) — and deliberately keeps names, phone numbers,
emails, CPFs, CNPJs, IP and postal addresses, NF-e keys, boleto lines, dates, prices and version
numbers, which are the user's own working context rather than anyone's credentials. A URL keeps its
host and path and loses its query string and fragment through `TextRedactor.stripURLQueries`
(#332), with or without a scheme: after `http(s)://` everything from the first `?` or `#` to
whitespace goes; a scheme-less host (two or more labels, the last 2–24 letters, not preceded by a
letter, digit, `@`, `.`, `/`, `:` or `-`) loses a `?` run that holds an `=`, and a `#fragment`
after a path. `node.js?`, `Is it example.com?`, `v1.2.3?x=1` and an email address stay. The URL
span wins every overlap and is deleted whole; a secret matched inside it still counts in the
per-kind counts. Placeholders are numbered per
call and stable per value (`[CARD_1]` twice for the same card); `[OTP]` and `[PASSWORD]` carry no
number. Adding a shape is a `Kind` case and a `Rule` row.

Two call sites, one function: `DescribeWorker.input(for:repairNote:)` runs the window title and the
URL through it before they reach `DescribePrompt.Input`, and the per-kind counts land in
`descriptions.details_json` under `redactions`; the capture tick will redact the accessibility text
before the row is written (#53). `captures.window_title` and `browser_url` are stored as they always
were — the user's own data on the user's disk — and the blocklist remains the tool for a title that
should not exist at all.

**The accessibility read is focused-first, and its pure half is a separate file (#52).** A
breadth-first walk from the window root spends its whole node budget on tab strips and toolbars
and never reaches a message body, so `AXWalker` runs four stages under **one** shared node budget
(`AXWalkLimits.maxNodes`), **one** depth limit per stage (`maxDepth`) and **one** deadline
(`timeoutMs`): the focused element's titled ancestry (breadcrumbs) → the focused
element's subtree → the main content container (`AXWebArea`, else the largest
`AXScrollArea`/`AXGroup` by frame) → the rest of the window. Emission and expansion are tracked
separately, so an ancestor emitted as a breadcrumb can still be descended through later and no
node is emitted twice.

Everything the walk needs about one element arrives in a single
`AXUIElementCopyMultipleAttributeValues` — role, subrole, title, description, value, `AXURL`,
frame, children, parent — and `AXLiveElement` memoises it, so a node costs one IPC round-trip
however many stages reach it. `AXElementRead.value` is a **closure, not a stored property**: that
is what makes "the value of an `AXSecureTextField` is never read" a fact the tests can assert
rather than a promise, since the walk simply never makes the call for a secure role or subrole.

**The window title and the browser URL come from the tree first, and the old probes stay as
fallbacks (#55).** `AXHeader` is a deliberately cheap read of the focused window — one
`AXUIElementCopyMultipleAttributeValues` plus `AXDocument`, no walk — and
`ForegroundContextCollector.collect()` consults it **before** `PrivacyPolicy` runs, because the
title and the host the blocklist matches on are exactly what it produces. The title is
`AXTitle`; the URL is `AXURL` on the window, else the focused element's when that element *is*
the `AXWebArea` (the `AXURL` of anything inside one is a link's href, which is a page the user is
not on), else `AXDocument` when it is an http(s) URL — which is how a Chromium window names its
tab. Both go through the same `BrowserRegistry.strippedTitle` and `BrowserRegistry.normalize`, so
the stored string and the host the timeline groups by do not depend on which reader answered.
`normalize` always drops the fragment and the query string (#87 made that unconditional), for
`captures.browser_url` and, through `BrowserRegistry.storableDocumentURL` (#311), for
`ax_snapshots.document_url` too.
`strippedTitle` now **cuts** at the browser's name instead of trimming a suffix:
`kCGWindowName` reports a Chromium window's page title alone, while `AXTitle` reports the whole
window title — `<page> - Google Chrome - <profile>` on a machine with more than one profile — and
only cutting makes the two readers agree and keeps the profile name (a person's name) off every
row. The last occurrence wins, so a page that names the browser in its own title survives. `kCGWindowName` (Screen Recording) and the per-browser AppleScript
(Apple Events, and nothing at all for Firefox) are untouched underneath: a header is missing
whenever the grant is, and a single attribute can be absent on a window that has the rest.
`ForegroundContext.titleSource` / `urlSource` (`ax | windowList | applescript | none`) record
which one answered, for the menu's browser-URL line (#64) and `.debug` logs only — no report,
timeline or prompt reads them. `collectWithHeader()` hands the header's window and focused element back to
`CaptureScheduler.performTick`, which passes them to `snapshot(pid:header:)`: element reads are
memoised, so one tick creates one application element and looks the focused window up once, and
the header costs the walk nothing.

`AXOutline.render` is the deterministic text form (`[role] title — value`, indented by depth,
focused subtree first, duplicate lines dropped, head + tail to `AXWalkLimits.maxTextChars`) and
`AXOutline.hash` is its SHA-256 — the hash #53 compares between ticks. Nothing here is stored,
nothing is redacted (that is #49, applied by the caller) and nothing about window text is logged
at all. Since #53 the capture tick is its caller; the `ax-snapshot` command that printed it went
in #300.

**The tick stores the window's text and decides describes from its hash (#53).** Tick order:
paused → locked/asleep → idle → context → *bundle-change bookkeeping* → blocklist → meeting
throttle → **accessibility snapshot** → permission/screenshot → downscale/fingerprint → decision
→ write. The snapshot is started with `async let` and awaited after `capture.capture()` returns,
so the walk's deadline and the screenshot's latency overlap instead of adding up. The snapshotter
is the one place the Accessibility grant is checked — it answers nil when the process is not
trusted — so a missing grant costs one `AXIsProcessTrusted()` a tick and nothing else. The
blocklist still runs *first*: a blocked app's tree is never read.

`TextRedactor` runs on the same task that produced the outline and `text_hash` is the SHA-256 of
the **redacted** text, so a stored row and its hash can never disagree, and the raw string never
outlives the tick. `DescribeDecision.needsDescribe` gained `textChanged: Bool?` and `coverage`:
`.full` is `textChanged || signatureChanged || heartbeat` — dropping the pixel term is what stops
a playing video buying a vision call — `.partial` is `textChanged || today's pixel rule`, and
`.none` or no snapshot is today's rule untouched. "No previous frame at all" still wins over all
of it.

`DescribeDecision.trustedCoverage` is the one addition the issue did not ask for.
`Coverage.classify`'s node floor is "more than one node", and #52 measured Slack grading `.full`
off two nodes and a window title — an outline that holds no message text, so its hash does not
move when a message arrives. Trusting that as `.full` would remove the pixel term that is
currently the only thing noticing, so a `.full` grade with fewer than
`trustedFullMinNodes` (5) nodes is consumed as `.partial` and keeps the pixel rule underneath it.
Deliberately not in `classify`: that grade is what #54's measurements bucketed
frames by, and redefining it would silently move the measurements in `docs/decisions.md`.

Retention: `DELETE_SCREENSHOTS_AFTER_DESCRIBE` and `DELETE_SENSITIVE_SCREENSHOTS` now null
`ax_snapshots.text` alongside the JPEG — a stored outline is the same kind of evidence as the
pixels, often a more literal one. The hash, the counts and the coverage stay, so the next tick's
decision still works. `DiskBudget` is unaffected: the text is in
SQLite, not on the filesystem.

`MenuState`
gained `accessibilityMissing`, which `MenuModel` renders as one advisory line
(`MenuModel.accessibilityMissingLine`) and nothing else: the icon and every action stay put,
because capture keeps running on pixels. `AppModel.requestAccessibility()` is the only thing that
ever prompts, and it is wired to a button in Settings → Capture → Access — never to launch.

**The browser URL line (#64).** `MenuState.browsersMissingURLs` gets the same treatment one level
down: `AppModel.refreshBrowserURLs(db:)` pairs `CaptureStore.browserBundlesWithoutURL(day:)` with
`AutomationPermission.status(forBundleID:)` on the existing 30 s refresh, and `MenuModel` renders
`browserURLLine(_:)` — advisory, never the icon. The store side asks for browsers with *no* URL
all day rather than any frame without one: on 2026-09-09 four Chrome frames missed their URL
before Accessibility was granted and every frame after it had one, and "any" would have left the
line up until midnight while URLs were arriving. A browser that is not running is left out:
`procNotFound` says nothing about the grant, and a line about a browser closed hours ago would
sit there for the rest of the day. Nothing on this path prompts, and the failing probe itself now
writes one `info` line per ten-minute backoff window, bundle id only.

**Asking for Automation (#79).** System Settings lists an app under Privacy & Security →
Automation only once it has an answer on file, so "Open System Settings" is a dead end for a
browser at `notAsked`, and the URL probe cannot supply the answer either: its first Apple
event raises the dialog, but the 1.5 s deadline fires long before a human does.
`AutomationPermission.request(forBundleID:)` raises the dialog on purpose from a per-row
**Ask macOS for access…** button in Settings → Capture → Access, and the row's badge
takes the answer in place. `denied` keeps
**Open System Settings** — macOS never prompts twice — and `notRunning` gets no button,
because a closed browser returns `procNotFound` and shows nothing. `AppleScriptBrowserURL`'s
backoff ends early when a window that opened *without* the grant sees it arrive; a window
opened by a deadline on an already-allowed browser is left alone, since that one is what
keeps a beachballing browser from costing 1.5 s a tick. Since #117 the probe only runs for an
allowed browser at all, so a window is normally opened by an allowed browser and that early end
covers only the narrow case of a grant revoked between the gate and the failure.

**Asking for Screen Recording, and the two wordings (#117).** `AppModel.requestScreenRecording()`
calls `ScreenCaptureService.requestPermission()` — `CGRequestScreenCaptureAccess()`, at most once
per launch — and only falls back to the pane when the answer is still no; asking is what puts
Worklens in that pane's list at all. `screen_recording_granted_at` is stamped the first time
`permissionState()` answers `.granted`, and its presence is the whole of `everGranted`:
`ScreenRecordingCopy` turns it into the notification title and body, the `SetupIssue` message
(`Notice.init(_:message:)` overrides the issue's own sentence) and `MenuModel.permissionFixLine`.
`permission_incident_started_at` makes the outage outlive the process, so relaunching — which is
exactly what a fresh grant asks of the user — re-raises the menu line without re-posting the
banner. `.permissionMissing` now also disables Pause (`canCaptureNow` already was false), leaving
one row: `Screen Recording is off — Fix…` → Settings → Capture → Access, where Ask, Re-check and
Relaunch sit together. `RelaunchPlan` is the relaunch itself; `NSWorkspace.openApplication(
createsNewApplicationInstance:)` cannot be used, because `SingleInstance` makes the second copy
activate the first and exit.

**Offering the optional permissions instead of warning about them (#117).**
`AppleScriptBrowserURL.frontTabURL` returns nil unless `automationStatus(bundleID) == .allowed`,
so no capture tick can raise the consent dialog, and `refreshBrowserURLs(db:)` splits what it
finds: `.denied` browsers into `browsersMissingURLs` ("turn them on in Settings → Capture → Access…")
and `.notAsked` ones into `browsersNotAsked`. #136 folded both into the one advisory row, so the
menu no longer asks for anything itself: Settings → Capture → Access raises the dialog per browser
through `AutomationPermission.request`. Both lines and the Accessibility one dropped the ⚠️: they are offers, and
`skip_accessibility_advisory` / `skip_browser_advisory` silence them from Settings → Capture → Access.

**Describing from the window's text (#54).** `DescribePrompt.version = "d2"`. `Input` gained
`windowText`, `coverage` and a `mode`, and `Mode.forFrame(hasText:coverage:hasImage:)` is the one
place the three renderings are chosen: text-only for `.full`, text plus the picture for
`.partial`, image-only for `.none` or no snapshot — and text-only for any frame that has text but
no picture, because there is nothing else to send. The mode is stored on the `Input` rather than
derived at the last moment, so the prompt's wording and the request's parts cannot disagree:
`DescribePrompt.request` attaches the JPEG only when `mode.sendsImage`, and `Prepared` keeps the
input so the one repair attempt rebuilds the *same* mode instead of quietly finding the picture.
The system instruction drops d1's "Prefer the metadata … when the image is ambiguous" — the text
*is* the exact metadata that hedge stood in for — and keeps every sensitivity rule word for word.
The JSON schema and `FrameDescription` are untouched, so the timeline, blocks and reports keep
working.

`DescribeRequest.imageJPEG` is now optional and `GeminiClient.requestBody` emits the
`inline_data` part only when there is one: a text-only describe is a single `text` part, not an
empty image beside it.
`DescribeWorker.prepare` reads `ax_snapshots.text` (already redacted on the way in, so what is
stored is what may be sent) and only refuses a frame that has *neither* artifact —
`WorkerError.imageMissing` is now the empty case rather than the no-file case.

`CAPTURE_SOURCE` (`CaptureSourceMode`, distinct from the `CaptureSource` a row carries) decides
what a tick collects. Under `screenshot` and `both` the walk runs alongside the capture, as in
#53; under `auto` and `accessibility` the tick awaits the walk first, because the coverage is
what decides whether to photograph — that is up to `AXWalkLimits.timeoutMs` added to a tick, and the
price of not taking a picture. A text-only frame writes a row with a NULL `image_path`, no
`dhash` and no `change_score`, so `DescribeDecision.needsDescribeFromText` decides it from the
text hash, the window signature and the heartbeat — the same three terms as the `.full` branch,
minus the pixel term there is no longer any pixel for. `lastFingerprint` is left alone on those
ticks, so the pixel rule keeps meaning "changed since the last photograph". Under
`accessibility` a window that exposes nothing is written `skipped` / `no_text` (a new
`SkipReason`, one row per stretch and a new one when the app changes, exactly as a blocked app
is) rather than photographed; it carries no label, so the timeline continues the block around it
the way it does for an unchanged frame. `DiskBudget` needs no change: it simply finds fewer files.

**Run-aware describe context (#65).** `DescribePrompt.version = "d3"`. `DescribeQueries.recentContext`
is gone; `runContext(for:)` replaces it and returns a `DescribePrompt.RunContext` — the last
quotable description from a *different* `app_bundle_id`, plus the current run: the consecutive
captures carrying this frame's bundle, walking back until the bundle changes, an idle or locked
row breaks the stretch, or `runContextWindow` (90 min) runs out. One query, one pass.
Inherited descriptions are never quoted (they are the previous frame's words), but they do not
end a run either — the screen simply did not change.

`RunContext.compressed` is the only way to build a non-empty one, so the budget cannot be
side-stepped: identical summaries collapse onto the first time they were said, the run keeps its
first frame and its last `runContextTail` (4) distinct ones, each quoted summary is cut at
`runContextSummaryLimit` (180 chars), and quoted frames are then dropped — oldest first, the
run's first frame next, the "before this app" line last — until the block fits
`runContextBudget` (700 chars). What is dropped is counted rather than lost: the header says how
many frames the run has and `… N more frames` accounts for the gap. `Input.recent` became
`Input.context`, and `DescribePrompt.contextBlock` renders it in **all three** modes — the run is
a fact about the frame, not about which artifacts were sent:

```
Before this app: 09:41 slack/reading_messages — Reads #deal-flow.
In this app since 09:45 (20 frames):
- 09:45 chat_llm/prompting: Drafts a migration plan.
… 15 more frames
- 10:31 chat_llm/prompting: Reviews the generated SQL.
```

The system instruction asks for the delta when the activity continues, and for a verb-first
summary with no subject; the schema's `summary` description says the same, and the closing lines
say "Describe what is happening" rather than "what the person is doing" — that phrase was the
last thing seeding the three words 176 of 176 summaries began with on 2026-09-08. The proposed
`continues_previous` boolean was **not** added: it would have to live on `FrameDescription` and in
`details_json`, which is more than "cheap", and nothing consumes it yet.

**Config keys added in #54:** `CAPTURE_SOURCE` (`auto|accessibility|screenshot|both`), shipped as
`both` — #53's behaviour; `docs/decisions.md` records the rule and what would flip it to `auto`.

**The battery policy is one pure function (#145).** `PowerPolicy.decide(power:mode:baseIntervalSeconds:)`
(`WorklensCore/Capture/PowerPolicy.swift`) maps a `PowerState` — `onBattery` from IOKit's
`IOPSGetProvidingPowerSourceType`, `lowPowerMode` from `ProcessInfo` — and `CAPTURE_ON_BATTERY`
onto an effective interval and a `describeAllowed` flag. Nothing else knows the rule.
`SystemStateMonitor` is where the live facts come from: it already owns every OS observer, so it
gained `power`, an `onPowerChange` handler, the `NSProcessInfoPowerStateDidChange` observer and an
`IOPSNotificationCreateRunLoopSource` for the charger — there is no `NSWorkspace` notification for
the latter, and polling a laptop's power source is exactly the thing this issue exists to stop.
`CaptureScheduler` republishes it as `@Published power` and applies the decision in `baseInterval`;
`AppModel.syncSchedulerState()` mirrors it onto `MenuState` and pushes it into `DescribeWorker`
with `setPower`, which is how an actor learns a main-actor fact. The describe half is a
**precondition at the top of `runCycle`**, deliberately *not* the `describe_backoff_until` outage
hold: that one is a 300 s-capped doubling hold for a provider that is down, and "until the charger
is back" has no deadline to count. Frames are left `pending` — the same end state the outage path
produces — so nothing downstream knows a battery was involved. The menu says it in
`MenuModel.batteryLine`, which replaces the "Capturing · every 60 s" row rather than adding one.

**Config keys added in #145:** `CAPTURE_ON_BATTERY` (`normal|slow|describe-later`), shipped as
`slow`: on battery, or in Low Power Mode on the charger, the interval is multiplied by
`PowerPolicy.batteryIntervalMultiplier` (5) and describing continues. `describe-later` also holds
the queue until mains. What Worklens weighs on the Mac is in `docs/footprint.md`.

**Config keys added in #52 and retired in #87:** the five `AX_*` knobs are now `AXWalkLimits`'s
defaults — 400 nodes, depth 24, 250 ms, 3000 characters, a 80-character floor. Only tests pass
anything else.

**Config key for where the Google grant lives:** `GOOGLE_TOKEN_STORE` — `keychain` (default) or
`file`. `GoogleAuth.store(for:)` maps it to `KeychainTokenStore` or `FileTokenStore`
(`DATA_DIR/google-token.json`, written 0600 under a temporary name and `rename`d into place). `file` exists
because the Keychain access dialog cannot be silenced in code — see `docs/decisions.md`, "The
Keychain dialog after a rebuild cannot be fixed in code". Switching the key does not migrate a
grant: the new store has none, so you connect again, and PRIVACY.md carries the consequence
(with `file`, a backup of `DATA_DIR` does hold a credential). #139 made the key the record of a
*choice*: the Google Calendar setup sheet offers the two stores by name as you connect (and Settings → Advanced after, since #286), pre-selected with
`GoogleTokenStorage.recommended(teamID:)` from `SigningIdentity.runningTeamIdentifier`
(`SecCodeCopySelf` → `SecCodeCopySigningInformation` → `kSecCodeInfoTeamIdentifier`, no
entitlement and no subprocess), and switching stores runs the disconnect-then-connect order for
you. Nothing resolves the key behind the user's back — a layer that already set it still wins.

**Config keys added in #49:** `REDACT_EXTRA_PATTERNS` (default empty) — extra regexes for
`TextRedactor`, semicolon-separated like `BLOCKED_TITLE_PATTERNS`, each hit replaced by
`[CUSTOM_n]`; one that does not compile is dropped and counted in `TextRedactor.invalidPatterns`,
the way `PrivacyPolicy.invalidPatterns` works.

**Config keys added in M4 (#16):** `BLOCKED_URL_HOSTS` (default empty) — hosts whose pages are
never looked at, semicolon-separated, matched at a dot boundary so `nubank.com.br` covers
`app.nubank.com.br`.

**What the daily budget stops, and what it only warns about (#17).** `CostPolicy` is the single
place this is decided. `.describe` is an absolute stop: it is the one path whose volume is
unbounded (a frame a minute, forever), frames past the budget are still captured but written
`skipped/budget`, and the only way to resume is to raise `DAILY_BUDGET_USD` and reload. Every
other purpose is *advisory*: refused when something automatic asks, allowed when a person
asks — the menu quotes `CostTracker.estimate(purpose:)` in a confirmation first. Since the reports
were cut (#298) describing is the only purpose that spends. The rule in one
line: **nothing spends without either a budget under it or a person behind it.**

Every such confirmation goes through one helper — `AppModel.confirm`, which answers a `Bool`
(#154): the action button keeps its macOS place (added first, so rightmost)
and answers ⌘↩, Escape cancels, and Return performs nothing — no call site compares
`alertFirstButtonReturn` itself, so an alert cannot be wired so that dismissing it spends money or
deletes a day. The budget, erase and update alerts all use it.

`CostGate` gained `allows(_:userInitiated:)` and `ledgerChanged()`; a conformer only has to
answer `isOverBudget`, and the protocol extension applies `CostPolicy` to it. Every spender is
gated: `CaptureScheduler` and `DescribeWorker` each hold the app's one `CostTracker`.
`LLMPurpose.taxonomy`, `.chat` and `.rangeResolve` kept their cases after #86 and #95 removed
their only callers, and the report cases kept theirs after #298 — they are values stored in `llm_calls`, and dropping one would
make an old row undecodable. `.verify` (#124) is the one new case: Settings → Accounts writes a
row per `Verify` press — the free models-list `GET`, zero tokens, `costUsd: 0` — so a call that
carried your API key off this Mac is as auditable as every other. `purpose` is an unconstrained
`TEXT` column, so it needed no migration; `CostTracker.firstGuess(.verify)` is 0 and
`CostPolicy` never stops it. `DailySpend.otherUSD` sums all four, so the Settings table's three
columns still add up to the day's total on a day that predates the removals.

**`skip_reason` refinements (#16, #54).** `SkipReason` gained `blocked:bundle`, `blocked:title`
and `blocked:host` beside the bare `blocked` that rows written before #16 carry. Ask
`skipReason.isBlocked` rather than comparing to a case. #54 added `no_text`, which is not a
blocked reason: the app was allowed to look, `CAPTURE_SOURCE=accessibility` forbade the
screenshot, and the window exposed nothing to read. #313 added `asleep`: sleep used to be written
as `locked`. It is not blocked, the row is `is_idle = 1` like `locked`, so describe inheritance
and the timeline treat both alike, and `LastFrame` maps it to `.locked`, so the menu says what it
said before. `TickDecision` stays `.locked`. Rows written before #313 are not rewritten. A
build from before #313 cannot decode an `asleep` row (its `restoreState()` reads the latest
capture at launch), so a downgrade past #313 is unsupported.

**`DailySpend` is per-purpose and on local days (#17).** `LLMCallStore.summary(days:)` groups in
Swift rather than in SQL: `created_at` is stored UTC, a local day is not a fixed offset from it,
and the menu's "Today" line is a local day — so `substr(created_at, 1, 10)` would disagree with
it every evening. `DayBoundaries` stays the only place the conversion happens.

**Migration `v2`** adds `llm_calls.pricing_version`, stamped by `LLMCallStore.insert` from
`ModelPricing.pricingVersion` so a price change shows up as a change rather than as a mystery in
last month's totals.

**Migration `v4`** adds `captures.capture_source` and `ax_snapshots` (#53). `capture_source` is
`screenshot | both | accessibility`, nullable because every row written before it was pixels only,
and a plain string on the row for the reason `foreground_sessions.source` is one: #54 started
writing `accessibility` without another migration, which is what that shape was for. #53 wrote
only `screenshot` (no grant, or no snapshotter) and `both` (the window was walked, whatever the
walk found); since #54 `CAPTURE_SOURCE` decides, and `accessibility` means the frame has no
JPEG at all.
`ax_snapshots` is keyed by `capture_id` with `ON DELETE CASCADE`, so an erased frame takes its
outline with it — `DataEraserTests` asserts that rather than trusting it — and holds `coverage`,
`node_count`, `text_chars`, `elapsed_ms`, `text_hash`, `document_url`, `text` and
`redactions_json`. `text` is the **redacted** outline and the only column retention removes.
`document_url` is the window's `AXDocument`, which on a Chromium window is the tab's address, so
`CaptureScheduler.writeCapture` stores it through `BrowserRegistry.storableDocumentURL`:
`normalize`d like `browser_url` (no query, no fragment, lowercased scheme and host), and NULL
for a page (a known browser's window, or any http(s) address) while `COLLECT_BROWSER_URL` is
off. An editor's `file:` address is kept. The snapshotter still sees the raw value, because
`AXHeader.make` derives the tab URL from it. No search index row holds this column. Since #319
`AXSnapshotStore.documentURLs(day:timeZone:)` reads it back, per frame, for the document key
`ArtifactKey` computes on read (see "Time per document"); nothing derived from it is stored. The
**outline** (`text`) loses its URL queries in `TextRedactor` (#332), scheme-less ones included,
so a Chromium omnibox's `mail.example.com/inbox?token=…` is stored, indexed and described as
`mail.example.com/inbox`.

**Migration `ledger-document-url-strip-ax-snapshots`** (#311) repairs the rows written before
that rule: `AXSnapshotStore.normalizeDocumentURLs` rewrites each non-null `document_url` through
`storableDocumentURL(…, collectBrowserURL: true)` and updates only the rows whose value changes.
No DDL. The `COLLECT_BROWSER_URL` gate is forward-only, because a migration cannot know the
setting a past row was written under; a second run changes nothing.

**Migration `ledger-outline-url-strip-ax-text`** (#332) repairs the outlines written before the
scheme-less rule: `AXOutlineRepair.stripURLQueries` puts each non-null `text` through
`TextRedactor.stripURLQueries` and, for a row it changes, updates `text`, `text_chars` and
`text_hash` together and rebuilds that capture's `ax` row with `SearchIndex.set`.
`redactions_json` stays: dropping a query is not a redaction of a kind. No DDL; a second run
changes nothing. The first tick after it may see a new hash for the frontmost window and describe
it once more.

**Migration `v5`** adds `captures.title_source` and `captures.url_source` (#55): which reader
supplied the row's window title and browser URL. Nullable, because rows written before it cannot
say and because a skip or a blocked row carries neither field — which is also why
`CaptureStore.browserBundlesWithoutURL(day:)` reads only rows that have a `title_source`. Plain
strings for the reason `capture_source` is one: the point of storing them is a week of numbers
deciding whether the AppleScript probe still carries any frames, and the issue that removes a reader must not need a migration to stop writing it.

**Migration `v3`** adds `foreground_sessions` (#46): `start_at`, a nullable `end_at` while the
interval is open, `app_bundle_id` / `app_name` (both null for a blocked app), `is_blocked`, and
`source TEXT NOT NULL DEFAULT 'nsworkspace'`. `source` is a plain string rather than an enum so
#47 can add imported rows without another migration and without an unknown value failing to
decode; this issue only ever writes `nsworkspace`.

**The name `ContextSource` is the enum on `context_events`** (`granola | calendar`), so issue
#19's protocol is spelled `ContextSyncSource` and its `id` is that enum. A source stores only the
user's own activity: the meetings they attended. (`slack` and `gmail` were cases until #285 removed
both sources; `SLACK_USER_TOKEN` is a retired key now, so an old `.env` still loads.)
Bodies over 2 000 characters (Granola transcripts) go to `DATA_DIR/context/<source>/<id>.md` and
are referenced by `body_path`; **only `body_md` ever reaches an LLM prompt**, and only its first
300 characters.

A meeting block sits *on top of* the screen blocks it covers rather than replacing them, so
`StatsAggregator` and `TimelineRenderer` total time as the **union** of block intervals, never the
sum. The same call known to both Granola and the calendar is collapsed by
`ContextBlocks.deduplicate`: since #318 only a Granola note and the calendar event it names
(`linkedCalendarEventId`, `raw_json.calendar_event.calendar_event_id` = the event's `external_id`)
whose times overlap, and (#340) a note that names no event with each calendar event it overlaps
for more than half of the shorter one, unless some note names that event; when the note that
names it also overlaps it, the unlinked note is that call's second copy and is dropped. Granola
wins, and every other pair, a calendar double booking or two unlinked notes included, stays two.

**Which company a meeting counts toward (#318).** `Context/MeetingAttribution.swift` is pure and
runs on read; nothing is stored. A meeting's company domains are its `participantEmails`' domains
minus yours (the calendar's `self` attendee or organizer, Granola's `owner.email`), the house
entry's `domains`, `ignoredDomains`, a static personal-mail list and `*.calendar.google.com`.
`resolve(_:catalog:ignoredDomains:)` tries `yours` (one entry claims them), `domain` (exactly one:
`company:<domain>`), `title` (the title holds exactly one non-house entry's 3+ character spelling
as whole words), then `calendar_event` (an unsettled note takes its linked event's answer, or,
with no link, the one company of the meetings #340's dedupe merges it with, or
`several_companies` when they disagree); else the key is nil with `several_companies` or
`no_company_domain`. `StatsAggregator.meetingShares`
gives each joined meeting the part of the day's meeting union no earlier meeting covered, and
`projectSlices` adds it to the company's `byProject` row as `Slice.meetingMinutes` and
`meetingRules` (or to `unattributed` by reason); `minutes` stays screen-only, and with #322's
spans `share` is of the covered screen and meeting seconds on a day, a week and a range (the
per-frame `projectSlices`, used only when a day's spans could not be read, keep that day's share
screen-only); rows rank by both, and both merges (`StatsAggregator.merge`, `StatsService.merge`) sum the new fields.

**A Granola meeting keeps its next steps (#316).** `Context/MeetingOutcomes.swift` is a pure parser
over the *full* `summary_markdown` (never `body_md`, which cuts it, and never the transcript or the
private notes): ATX headings whose folded label starts with `next step`, `action item`,
`follow-up`, `proximos passos`, `pendencias` or `encaminhamentos` (or `decision`, `decisoes`) open
a section that runs to a same-or-higher heading, a flush non-bullet line (Granola's footer link)
or the end. Each top-level bullet is an item, its indented lines are its `detail`, a bare `Name:`
bullet or a deeper heading prefixes the items under it, and `namesYou` is a whole-word match on
`owner.name`, "you" or "você"; at most 12 items per kind, 300 and 600 characters. No model call.
`GranolaSource.makeEvent` stores the result in `context_events.outcomes_json` (migration
`ledger-granola-next-steps-outcomes`) as `{v, nextSteps, decisions}`, empty arrays when the summary
has neither heading. Because an unchanged note is never refetched, `sync` first calls
`ContextEventStore.refreshMeetingOutcomes()` (`MeetingOutcomes+Store.swift`), which re-parses the
stored `raw_json` of every Granola row whose `outcomes_json` is NULL or older than
`MeetingOutcomes.parserVersion` and writes that one column, so `synced_at` does not move. MCP
`context_events` prints them under each meeting (`next steps (3, 1 names you):`, and
`outcomes_only` for just those meetings), and `TimelineRenderer.contextSection` nests up to five
`Next step:` / `Decision:` lines under it; a meeting without outcomes renders as before.

**The calendar also says when you were away (#94).** `CalendarSource` marks only conferences as
meetings, so a lunch with two colleagues was an unexplained hole the report had to ask about.
`ContextBlocks.awayBlocks(day:events:frames:)` turns a calendar event that is timed (never
all-day), not declined, has somebody else on it, is not already a meeting, and whose span
non-idle frames touch for less than `awayFrameCoverage` (20 %) of its minutes into a block with
`appKey: "away"`, `taskKey: "calendar"` and `source: .calendar` — id `away-ctx-calendar-<event>`,
so it can never collide with the meeting block for the same event. `TimelineWriter` owns and
rebuilds them exactly as it does meeting blocks (the same `deleteBlocks(day:sources:)` pass), and
the renderer prints `## 12:00–13:00 · Away · "Lunch at bem" (60m) — source: calendar` and never
nests screen blocks under one: it is not a call. `"away"` was already in
`StatsAggregator.inactiveKeys`, so away time is *tracked*, part of `idleMinutes`, and never
active; `StatsAggregator.isMeeting` now excludes it, so it is never meeting time either. New
`DailyStats.awayMinutes` names the total, and the MCP `stats` tool returns it on the days that
had one.

**Sessions are time, frames are meaning (#46).** `foreground_sessions` records every foreground
switch to the second, from `NSWorkspace.didActivateApplicationNotification` — no new permission,
no LLM call, no config key. An activation event names a *process* and nothing else, so a Chrome
row cannot tell `gmail` from `gsheets`; a described frame can, but only once a tick. So each half
supplies what it knows. `StatsAggregator.exactAppSeconds` takes the **total per bundle** from the
sessions (their union, intersected with the union of the day's active blocks, so idle, lock and
meeting handling are unchanged) and the **split inside a bundle** from the blocks: each screen
block is attributed to the bundle most of its captures carried, and the bundle's exact total is
handed to its app keys in proportion to their block seconds. Xcode, one key, simply gets its exact
total; Chrome's is divided between the keys its frames resolved to. `byApp` and `byCategory` are
the only breakdowns that move, and their denominator becomes the sum of the adjusted per-key
seconds rather than `screenActiveSeconds`, so the shares still add to one. `byTask`, `hourly`,
focus and the switch metrics stay block-based, and a bundle with no sessions — a day before the
migration, a stretch with the recorder stopped — keeps its block seconds untouched. **Sessions are
exact where they exist and silent where they do not (#61):** only the part of a block that falls
inside the session union is redistributed, so block seconds outside session coverage are never
rescaled — a day whose recorder started at 22:25 keeps the twelve hours of blocks before it rather
than collapsing them into nine minutes. `DailyStats.sessionMinutes` says how much of the active
span is exact and `sessionCoverage` what fraction of it that is; the markdown prints both. #51 uses the same rows one
step earlier: `BlockBuilder.build` snaps a run's start to the session start that precedes its first
frame by less than a tick, so the day's blocks stop overlapping or leaving a gap at every switch.

**Time per project (#70, #90)** is the one breakdown that comes from what the frames were *about*
rather than what they were in. `StatsService.daily` reads `project_hint` out of the day's
`descriptions.details_json` (`DescriptionStore.projectHints`, two columns, and inherited rows carry
a copy of the hint) and hands `StatsAggregator.daily` a `[captureID: String]`. `ProjectNames`
then does the deterministic clean-up — case-fold, drop a hint that only repeats the frame's own app
name or window title, merge a label into another whose words contain it, and show the group's most
frequent spelling — and `byProject` gives each project the minutes of its frames the way `byHost`
does, plus an explicit `unattributed` row so the shares still account for the whole day. Rows are
keyed on the folded display name, so a week merges `worklens` and `Worklens`. A day whose frames
carried no hints has no rows and no table, and its markdown is byte for byte what it was.

#90 puts the canonical list in front of that clustering (`StatsService` is handed a `projects`
closure, so an edit shows up in the next run) and gives each row its own second level:
`Slice.parts` carries the project's top three apps, which is the `top apps` column of the
markdown table and lets the report say "worklens: Claude Desktop 1h 10m, Web browser 25m". The
week's rows are merged by key as before and carry no `parts`. #90 also taught `ProjectNames`
that a rare label naming two projects — two frames of `Riverbend Capital Group - Meridian` against 59
and 41 — must not merge them: it joins the heavier one instead. A label that names two unrelated
things and is *commoner* than both (`KPL trivia night`) is still the project's name.

**Threads and the weekly ledger (#91).** "42 context switches, 6 per active hour" says a day was
busy; it cannot say whether an hour on one project was an hour or six returns to it. A **thread**
is a maximal run of consecutive screen-active blocks sharing one identity: the canonical project
its frames named, or — for blocks no project was named on — the block's app plus the `document`
the describer saw (`DescriptionStore.frameDocuments`, the other half of the `details_json` two
columns `projectHints` already reads). One identity per block, the heaviest of its frames', so a
run is either on the thread or it is not; that also makes `ThreadStat.totalMinutes` block minutes,
which can differ by a minute from the frame-weighted `byProject` row of the same project.
`StatsAggregator.threads` walks the day's screen blocks **idle ones included** — the opposite
convention to `switchPairs`, which drops idle first so that stepping away is not counted as
churn. Here stepping away and coming back is exactly the thing being counted, so an idle stretch
ends a visit, as does a block on another thread or one nothing could be said about. Meeting
blocks are left out: they sit on top of the screen blocks they contain and would break every
thread that ran through a call. A two-minute idle blip does split a run, which is what
`medianGapMinutes` is for — six visits three minutes apart is a thread never put down, not six
pieces of work, and the prompt rule says so in as many words. `ProjectNames.resolve` now runs once per day
(`StatsAggregator.namedProjects`) and feeds both tables, so they can never disagree about which
project a frame belonged to. The MCP `stats` tool returns the threads beside `byProject`.

`WeeklyStats.projectLedger` is the week's other half: every day's `byProject` rows merged into
project × day minutes, `other` and `unattributed` kept, so a day's column adds up to exactly what
that day's own table said. The Weeks page reads the same blocks.
`contextSwitches`, `switchesPerActiveHour` and `topSwitchPairs` are untouched and
stay in the JSON.

**Time per document (#319)** keys each frame to the document it showed, computed on read so
nothing new is stored and erasing a frame erases its key. `ArtifactKey.resolve(url:documentURL:)`
reads `browser_url` first and `ax_snapshots.document_url` second, and only their scheme, host and
path: `docs.google.com/{document|spreadsheets|presentation}/(u/<n>/)?d/<id>`,
`github.com/<o>/<r>/{pull|issues}/<n>` (owner and repo lowercased, any subpath), or a
percent-decoded `file:` path; anything else, Forms and PR lists included, is no key.
`DocumentTime` adds up the screen-active frame weights per key, a blocked frame giving none.
`DailyStats.byDocument` keeps the top ten plus `other`, keyed by `canonical` with your home
folder as `~`, and named by the describer's most frequent `document`, then the most frequent
window title, then a short form (`owner/repo#12`, `Google Slides`, the file name); a redacted
frame adds minutes but never a name. The week merges it like `byHost`, `SpanStats` like
`byProject`. `StatsService.documentSeconds(day:)` is the uncapped map the `shipped` tool joins
through `OutputViewTime`: a GitHub row's repo and number against the frames' keys over the 30
local days up to and including its day, the latest row of a shared key taking all the minutes,
printed as ` · on your screen 25m`. Keys are never logged and never reach a prompt.

`ForegroundSessionRecorder` is `@MainActor` and runs exactly when capture runs: `AppModel`
mirrors the scheduler's published state onto it, so **paused records nothing**, as `PRIVACY.md`
promises. One interval is open at a time; it closes on the next activation, on lock, on sleep, on
pause, on stop, and on idle — and idle is a *poll* (`ForegroundSessionRecorder.idlePollInterval`,
30 s) rather than an event, so the interval is closed at `now − idleSeconds()`, the last input,
not at the moment the poll noticed. Wake and unlock reopen it immediately rather than waiting out
`CaptureScheduler.wakeTickDelay`. On launch a row left open by a crash is closed at the newest
`captures.captured_at`, or at launch if that is earlier — never past the last evidence. The bundle
blocklist is the only one of the three that can apply (an activation carries no title and no URL):
a blocked app **keeps its interval** with `is_blocked = 1` and no name, so the day still adds up.
**Config keys added in #144:** `RETENTION_DAYS` (int, default `0` = keep everything, minimum 0)
and `RETENTION_KEEP_REPORTS` (bool, default `true`), both in the `privacy` section of the
registry. `AppModel.ageOutHistory()` runs the pass from the quarter-hourly housekeeping loop,
between the screenshot sweep and the `VACUUM` question, so a pass that frees real space is
followed by the vacuum that reclaims it. Settings → Privacy shows the number as a read-only
row beside the two existing retention toggles.
#217's Recent screenshots window, and `DataEraser.erase(screenshotID:)` that only it called,
went in #299.

`DataEraser` deletes sessions inside an erased stretch, trims one that overlaps an edge, and
splits one that spans the whole stretch. Nothing about sessions is logged above debug.

**The app owns the wiring.** `Sources/Worklens/App/AppModel.swift` is the only place the services
meet: it builds `Config`, `Database`, `TaxonomyStore`, `ScreenCaptureService`, `CostTracker`,
`CaptureScheduler`, `DescribeWorker`, `TimelineWriter`,
`ContextSyncScheduler`, `DataEraser` and `DiskBudget`, forwards each
capture tick to `DescribeWorker.nudge()`, refreshes `MenuCounts` every 30 s and after every tick,
and brings an open reader up to date once a minute (`readerTickInterval`, through
`ReaderTick.decide`). A fourth loop every 15 minutes (#18) does the
housekeeping: `CostTracker.tick()` for the local-midnight rollover, `DiskBudget.sweep()`,
`ProjectCatalog.learnIfDue` once per local day, and a weekly `VACUUM` once the scheduler has been
idle for ten minutes.

**The global hotkey is Carbon, not `KeyboardShortcuts` (#16).** That dependency's 3.x line uses
SwiftUI's `@Entry` macro and the CLT toolchain ships no `SwiftUIMacros` plugin, so it could never
be linked here; it is gone from `Package.swift`. `App/GlobalHotkey.swift` calls
`RegisterEventHotKey` directly (40 lines, no Accessibility permission), and
`Settings/HotkeyRecorder.swift` carries an `NSControl`-backed recorder in place of
`KeyboardShortcuts.Recorder` — a button to VoiceOver, startable with Space or Return, cancelled
with Escape (#154). What it *says* is not the US-ANSI letter of the key code: `UI/KeyDisplayName`
in `WorklensCore` asks the active keyboard layout (`TISCopyCurrentKeyboardLayoutInputSource` →
`UCKeyTranslate`) what is printed on that physical key, falls back to a table for non-printing
keys and for input methods with no `uchr` data, and is re-asked when the input source changes.
The stored `HotkeySpec.keyCode` never moves, so the combination keeps firing on the same key.
The sync scheduler is handed the *same* `MeetingDetector` the capture scheduler holds, so a
synced meeting is what slows capture down — see `docs/wiring/context.md`. Settings tabs live in
`Sources/Worklens/Settings/`.

**Nothing the user needs to know disappears on a timer (#110).** `MenuState.notices` is the
whole of it: a `Notice` is a kind (`problem`, `done`, `info`), a message, an instant, an optional
`NoticeAction` (the one button it carries) and an optional `SetupIssue`. `.done` lives 60 s and
`.info` 600 s — `MenuBarExtra(.menu)` offers no "the menu opened" hook, so "until the next open"
had nothing to hang on — while a `.problem` stays until the user dismisses it, and one raised by
a `SetupIssue` until that condition is re-derived as false. `SetupIssue` covers the conditions
that are re-derived rather than remembered — `screenRecordingDenied`, `keyRejected`,
`noGeminiKey` — raised in `AppModel.buildServices` and cleared there on reload
(`noAnthropicKey` still decodes from an old `app_state` row, and is never raised). #139 added `googleReconnect`, re-derived on
every `refreshCounters` from `ContextSyncScheduler.sourcesNeedingReconnect` (itself the typed
`SourceStatus.needsReconnect` flag, set from `GoogleAuth.needsReconnect(_:)` rather than from the
error sentence) and carrying `NoticeAction.reconnectGoogle`; one notification per expiry, on the
edge into the condition. It deliberately leaves the three existing
condition-backed signals alone: `configError` still owns the unreadable data directory and still
degrades the whole menu, and `accessibilityMissing` and `browsersMissingURLs` stay advisory lines.
The menu shows **one** problem — worst first, `SetupIssue` before an ad-hoc failure, newest among
equals — plus `2 more problems in Settings → General`; Settings → General's "See all" is the full list, open
ones first, each with the same button the menu offers. `NoticeStore` keeps the last 30 in
`app_state`, open problems first so a chatty day cannot push an unresolved one out. Only a
`SetupIssue` whose `blocksWork` is true (a missing or rejected key) moves the menu-bar icon;
permission advisories still never do.

**Colour and spacing come from one place (#109).** `StatusLevel` (`WorklensCore/UI/StatusLevel.swift`)
is what a status *means* — `ok`, `attention`, `problem`, `neutral`, `muted` — and
`Sources/Worklens/Design/Theme.swift` is the only place that turns one into a colour
(`Theme.Colors.status(_:)`) and the only place that turns one into a symbol
(`Theme.Symbols.status(_:)`, which forwards to `StatusLevel.symbolName` — #133 gave every level
its own SF Symbol, because a green dot and a red dot are the same dot in greyscale and to
VoiceOver). Alongside them: `Theme.Space` (`row`, `section`, `pane`), `Theme.Layout`
(`field`, `labelColumnNarrow`, `cornerRadius`), `Theme.SettingsWindow`
(the sidebar widths and the window's minimum, #133) and `Theme.Typography.controlPointSize`,
which is `NSFont.systemFontSize` since #154 so the hotkey recorder that reads it sizes itself
from the text rather than from a hard-coded box.
`Theme.Layout.labelColumn` and `statusDot` are gone: #133 replaced the hand-set label gutters with
`LabeledContent` in a grouped `Form`, and the dots with symbols. A width that genuinely has to
stay — a key field, a timestamp column — is wrapped in `@ScaledMetric(relativeTo:)` at its call
site so it grows with the reader's text size. `SpendLevel.level`,
`StatusBadge.Level.level` and `IntegrationState.level` are the three adapters onto it;
`neutral` is a full-strength label and `muted` a greyed one, which is why `SpendLevel.nominal`
maps to `neutral`. `StatusBadge` takes either a `StatusLevel` or its own three-case `Level`
(#135): a view whose state already carries a level decided and tested in WorklensCore passes it
straight through, and only a row that has to decide the level in the view uses the three cases —
re-deriving one that already existed is how an Integrations card came to draw a grey icon and an
orange badge for the same fact. `Layout` and `Typography` are plain `CGFloat` so the `NSView`-backed hotkey
recorder can use the same numbers as the SwiftUI views. New UI reads a token instead of writing
`.orange` or `frame(width: 220)`; a token belongs here only once something calls it.

**Type, surfaces, motion and a row that answers the pointer (#237).** #109's layer stopped at
colour and spacing, so everything drawn after it invented its own scale. `Theme` now also carries:

- **`Theme.Text`** — four roles, each a `Font` built from a system text style plus a weight and
  never a point size, so every surface follows the user's text size: `statusTitle` (the sentence a
  window or a banner opens with), `rowBody`, `sectionHeader` and `metadata`. `sectionHeader` and
  `metadata` are drawn `.foregroundStyle(.secondary)` at the call site — colour is not part of a
  `Font`.
- **`Theme.Surface`** — `.card()` (the raised block a tile or an empty state sits on) and
  `.panel()` (the recessed container a list sits in), plus `Theme.Surface.shape`.
  The radius comes from `Theme.Layout`, both strokes and materials from system semantic colours,
  so light and dark still follow macOS with no asset catalogue. They exist to retire the
  `.background(.quaternary.opacity(0.4), in: RoundedRectangle(...))` still written out by hand in
  three reader views, which #233 owns.
- **`Theme.Motion`** — `quick` (a hover or a press settling), `reveal` (a disclosure), one curve,
  and `animation(reduceMotion:_:)`, which returns `nil` under Reduce Motion so the change lands
  with no animation at all.

**`make lint-design` is a baseline, not a gate (#237).** `scripts/design-lint.sh` greps
`Sources/Worklens` for `.font(.system(size:` and numeric `RoundedRectangle(cornerRadius:`, prints
each `file:line` and the total, and compares it with a `BASELINE` committed in the script. It
exits non-zero only when the count goes **up**, and it is deliberately not part of `make check`:
the literals left behind sit in files other issues are rewriting, so a zero gate would fail for
reasons no one pull request can fix. #251 wires it into `make check` once the rewrites have landed.

**Settings is a page of the reader (#286).** There is no Settings window any more: the gear at
the foot of `ReaderRail` sets `AppModel.settingsSection`, and while it is non-nil `ReaderView`
draws `SettingsPage` (`Settings/SettingsPage.swift`) where the reading page was — a 208 pt section
list on the `ReaderTheme.list` tone beside a 640 pt column — and the rail stays. Settings is not a
`ReaderPlace`: the rail's two places stay the reading places and `readerPlace` keeps the one you
came from, so Esc (a local key monitor in `SettingsPage`, which stands down while a text field or
the shortcut recorder has the key) is `closeSettings()` and nothing else. `SettingsSection`
(`WorklensCore/UI/SettingsSection.swift`) is the list — general, capture, privacy, log,
connections, usage, then Advanced below a hairline, always shown — and `SettingsSection.target(named:)`
folds every name the old eleven panes had into a `SettingsTarget` (a section and optionally a
`SettingsAnchor` row to scroll to and flash): `cost` → Usage, `permissions` → Capture's Access
card, `reports` / `projects` → Log (#298), `integrations` / `assistant` → Connections, `activity` → General. That
is how an old `settings_tab` in `app_state`, `worklens settings --tab permissions` and a
`SettingsReveal` from an older build all still land; `SettingsSectionTests` proves no old value is
left unmapped. `AppModel.openSettings(_:)` is the one route in — the gear, ⌘, (a `CommandGroup`
replacing `.appSettings` on the reader scene, plus a key inside the window for when no menu bar is
up), the menu's "Settings…", the CLI, `SettingsReveal` and every remedy button that used to name a
pane — and it ends in `frontHomeWindow()`, which opens the reader if it was closed. Every row
writes through `AppModel.saveSetting` (`AppModel+Settings.swift`), the old `applySetting` path
plus a "Saved" toast; a key the process environment or `WORKLENS_ENV_FILE` supplies stays locked
with `SettingsCopy.lockNote`, which names neither. The logic the page only lays out is in
`WorklensCore` with tests: the status line's priority (`SettingsStatus`: a missing grant or an
open notice, then everything is working — the same condition lights the dot on
the gear), Privacy's mixed "Never look at" list and its type guess (`NeverLookAt`), the delete
confirm's count, and Usage's 30 days (`UsageSummary`). Key names appear in exactly one place,
Advanced's "Every value and where it comes from".
**The menu is grouped, and the maintenance is not in it (#136).** `MenuContent` was six
`Section`s — a read-only header, then Capture, Reports, Files, Erase and an unlabelled trailing
group — instead of eighteen items separated by `Divider()`s. Whether `MenuBarExtra(.menu)` draws a
`Section` *header* is macOS's call; where it does not, a section still separates, which is the
divider the file used before, so the grouping is safe either way. Four things moved or folded.
The three sibling "Pause …" buttons became one `Menu("Pause")` over `PauseChoice`
(`15 minutes` / `1 hour` / `Until tomorrow` / `Until I resume`), reachable *while paused*, which is what lets a pause be extended
— `MenuModel.canPause` is true for `.paused` now. (#299 removed `activePauseChoice` and the
optional-permission `advisoryLine`, which #231's menu stopped drawing; the optional grants live in
Settings → Permissions only.) The build stamp and
"Update and restart…" moved into Settings → General → Updates (`updateAvailableLine` stays in the
menu: a pending update is a fact about the install, not a maintenance control), and
"Sync integrations now" was deleted in favour of Integrations → "Sync all now". The daily actions
carry key equivalents (⌘P pause/resume, ⌘N capture now, ⌘O reader, ⌘⌫ delete the
last 10 minutes); these fire only while the menu is open — an
`LSUIElement` app has no main menu — so they exist to be drawn at the right edge and read by
VoiceOver. The one key that works with the menu shut is the global hotkey. Pressing the hotkey now answers on three channels — `note(notice:)`, the notification, and
an `NSAccessibility.announcementRequested` that is best-effort, since an announcement from a
background app is not reliably spoken while another app is frontmost — and "Capture now" leaves a
line where it left none: "Captured this screen." only when the forced tick collected something,
and otherwise `MenuModel.captureNowSkippedLine(_:)` on the decision it came back with — a
blocklisted app in front, a locked screen, a window with no text.

**The menu bar is a menu again, and a compact one (#231).** `MenuContent` replaced #159's
`MenuPopover`, and `WorklensApp` carries `.menuBarExtraStyle(.menu)`: a real `NSMenu`, so the
menu is keyboard-navigable, VoiceOver-native and dismissed by the same click every other menu on
macOS is. It is still a `MenuBarExtra` and not a hand-made `NSStatusItem`, for the reason #159
settled: `openSettings` and `openWindow` are SwiftUI *view* environment actions, and the reader
(#134), the welcome window (#131), About (#153) and Settings are reachable only through the
copies a view in that scene graph hands to `AppModel.installSceneActions` — a view under an
`NSHostingController` is outside it. Under `.menu` the menu content is handed to AppKit, so the
*label* view is the only installer, and it is evaluated at launch, which is what makes the
welcome window openable before anyone has opened a menu. Dismissal is no longer a problem to
solve, so `StatusItemTooltip.closeMenu()` left with the popover, and the rest of
`StatusItemTooltip` — the hover text and the label it set through a `responds(to:)`-guarded
`statusItem` accessor — went in #299; the label view's own accessibility label remains.

At most twelve top-level rows, separators not counted: one status line, one tally line from
`TodaySnapshot`, at most one attention row, then Pause ▸ / Capture now, Open Worklens ⌘O, Delete ▸, and Settings… ⌘, / Help ▸ / Quit Worklens ⌘Q. A configuration or a
storage fault takes the attention slot as a *submenu* — one line naming the fault, with the same
three remedies `ConfigBanner` offers in Settings hanging off it — because neither fault has a
single answer. What the popover drew and the menu does not is in the reader or in Settings: the
"Today" card in the reader, the notice banners in Settings → General, the
files rows in Settings' provenance section, blocklist rows in Settings → Privacy. Submenu rows do
not count against the twelve, which is why Help ▸ keeps Troubleshooting… — `openTroubleshooting(_:)`,
the route that lands on one symptom of `docs/user/troubleshooting.md`, is called from there and
nowhere else.

**`TodaySnapshot` is deliberately not `DailyStats` (#159).** `StatsService.daily` is six full-day
table scans plus a ledger query, and the card needs four numbers, so `WorklensCore/UI/TodaySnapshot.swift`
computes active minutes, meeting minutes and the day's first activity from `activity_blocks`
alone — the same union-not-sum rule `StatsAggregator.daily` uses, so a calendar meeting laid over
screen time is counted once — and takes today's spend and the budget in force straight off
`MenuState`. `AppModel.refreshTodaySnapshot()` is called from `AppModel.menuWillOpen()`, which
`MenuContent.body` runs when the menu is opened; it no-ops while the cached snapshot is younger than
`TodaySnapshot.cacheSeconds` (60 s) and the read runs `nonisolated async`, off the main actor.
The 30 s refresh loop never computes one, which is the whole reason the type exists (PLAN §1.6).
Yesterday's blocks are read only when today has fewer than three, so the `recent` rows are not
empty at 00:30; each row carries its own `day`. #231 draws none of them in the menu — the one
thing the menu takes from the snapshot is `tallyLine`, `2h 05m active · 45m in meetings · $0.42
of $2.00`, omitted entirely before anything is tracked.

**The menu says it in symbols and words, never in emoji (#132).** `MenuModel` used to build
state into strings with an emoji prefix — a filled circle before `Capturing`, a sleep glyph before
`Idle`, a banknote on the over-budget spend line — which mixed colour emoji with the monochrome
glyphs everywhere else and made VoiceOver open each row with "money with wings". Every
informational line is now a `MenuRow` (`{kind, glyph, text}`), and `statusLine` /
`countsLine` / `problemLine` and friends stay as passthroughs onto the row's `text` for the
accessibility label and the tests. Two rules hold it together, and #231 put the
first one back: under `.menuBarExtraStyle(.menu)` an informational row is a disabled `NSMenuItem`
whose title AppKit draws in the system colour, so `Theme.Colors.status` cannot reach it, which is
why the budget warning *says* `$1.20 of $1.50 (80 % of today's budget)` and `$1.60 of $1.50 —
over budget` in words rather than in a tint. And every `text` stands without its glyph, because whether a non-`Button`
`Label` draws its image in an AppKit menu is macOS's decision. One user-facing sentence moved
targets for the same reason: `MenuModel.budgetSkipNotice(kind:budget:)` was inline in `AppModel`,
where `WorklensCoreTests` — the only test target — could not reach it.

**Settings deep links (#112).** Since #286 this is `AppModel.openSettings(_:)` and a
`SettingsTarget` — see "Settings is a page of the reader" above. The section last shown is no
longer remembered: a door that names no section opens General. `SettingsSection.restoring` still
maps an old pane's name (`--tab permissions`, a stale `settings_tab` row) to the section that holds
it now.

**Three doors back in (#147).** The menu-bar item is not always reachable — a full menu bar, a
notch, an item hider — so there are two routes back in that do not need it and one that
does not need the app at all. `AppDelegate.applicationShouldHandleReopen(_:hasVisibleWindows:)`
covers re-opening the *same* bundle, which never starts a second process: LaunchServices
activates the running one and sends it that message, and the handler answers with
`AppModel.frontHomeWindow()` — the reader, since #252; the ⌥⇧W shortcut takes the same door,
and Settings is reached through the menu or `worklens settings`. A second *copy* (`make run` against an installed app) still exits on
`SingleInstance`, but posts `SettingsReveal` (`WorklensCore/UI/SettingsReveal.swift`) on the way
out — a `DistributedNotificationCenter` name keyed to the bundle identifier, carrying at most a
`SettingsPane` raw value — which the running copy observes from `applicationDidFinishLaunching`,
after the single-instance check so it cannot hear itself. `worklens settings [--tab <pane>]`
posts the same notification and exits. Not Apple events: `make sign` passes `--options runtime`,
so that route would need the automation entitlement and a TCC dialog for no gain. The permanent
version is Settings → General → **Keep Worklens in the Dock** — persisted under
`AppModel.dockIconKey`, off by default and needing no relaunch either way; the Dock tile is
useful only because the reopen handler above turns a click on it into this window.

**Dock app while a window is open.** The bundle stays `LSUIElement=true`, so every launch starts
as `.accessory`. `DockPresence` (`App/DockPresence.swift`) switches `NSApp.setActivationPolicy`
to `.regular` — Dock tile, ⌘-Tab, the menu bar across the top — while any titled, non-panel
window is visible or minimized, and back to `.accessory` when the last one closes, unless the
setting above pins it. `AppModel.openWindow(id:)` and `openSettings(tab:)` call
`windowWillOpen()` *before* `NSApp.activate`, because a policy that turns `.regular` after the
activation can leave the previous app's menus on screen; `NSWindow` key, occlusion, miniaturize
and close notifications are the backstop. The top menu bar's content is `WorklensCommands` in
`WorklensApp.swift`: Help carries the menu-bar icon's Help rows, and "About Worklens" is
SwiftUI's standard panel.

**The shape of a Settings page (#286, was #133's pane).** Every section is a column of
`SettingsGroup`s — a small muted label, an optional one-sentence note, and hairline
`SettingsRow`s (a title and a one-line description on the left, the control on the right) — from
`Settings/SettingsKit.swift`, on `ReaderTheme` tokens taken from the prototype's `:root` block.
Only Capture's Access card is boxed (`SettingsCard`). Terracotta is the only accent: the switch,
the selected segment, small primary buttons. A read-only fact — a model id, the pricing version —
lives on Advanced, never beside a control on the other pages. Usage's 30 days are
a bar chart now (`UsageSummary.days` fills the calendar); "Copy as CSV" still renders `SpendCSV`.

**The next auxiliary window is a `Window(id:)` scene, not a window host.** #95 deleted
`ChatWindowScene`, a plain `Window("Ask Worklens", id: "chat")` (recoverable at
`git show bf8bece:Sources/Worklens/Chat/ChatWindow.swift`), and the recorded reason
(`docs/decisions.md`, #95) is that nobody used it — not that windows are wrong. macOS 14's
`Window(id:)` already creates-or-fronts one instance, restores frame and screen by scene id, and
closes without quitting an `LSUIElement` app, so an `NSWindowController` of our own would be a
second mechanism competing with the idiom this repo already used. A new surface is therefore one
scene in `WorklensApp.body` with `.defaultSize`/`.windowResizability`, fronted from the model
through `AppModel.openWindow(id:)` (which activates first, for the same reason as above).

**The help surface is three files and no new mechanism (#153).** `HelpDoc`
(`WorklensCore/UI/HelpDoc.swift`) names each document the app links to by its repo-relative path
and resolves it **bundle → checkout → GitHub**: `scripts/bundle.sh` copies `PRIVACY.md`,
`README.md` and `docs/user/` into `Contents/Resources` under those same paths, so an installed app
with no checkout opens a real page rather than a URL on a private repository — the bug
`openPrivacyDoc` had, where it looked in the process working directory, which is `/` for a Finder
launch. `HelpLink` gained the same bundle-first step as an overload, `SettingsPane.helpDoc` is the
page behind every section's **Learn more…** (one button in `SettingsPage`, not seven).

**The reader is that scene (#134), and since #233 it is the home window.**
`Window(ReaderCopy.windowTitle, id: AppModel.readerWindowID)` in `WorklensApp.body`, with
`Sources/Worklens/Reader/` behind it. **Since the core cut (#297) it is two pages**:
`ReaderView` is an icon rail (`ReaderRail`, one `ReaderPlace` per item — Today and Weeks — held in
`AppModel.readerPlace`, with the Settings gear at its foot) beside one page. **Today**
(`TodayPage`) is the date, three facts and the waterfall, drawn from `ReaderDocument.waterfall` —
`WorklensCore/UI/Waterfall.swift`, built from the day's `DailyStats`, with a Meetings bar for
active time no app on screen accounts for. **Weeks** (`WeekPage`) is the 08:00–20:00 grid from
`ReaderDocument.calendar` — `WorklensCore/UI/WeekCalendar.swift`, which owns the 30-minute slot
grouping and is tested in `ReaderShellTests`. Since #298 it is the calendar and nothing else.
The Days list, the Timeline, Stats and Search pages, the toolbar's recording control and
the compiled-in example day went with the cut; pause and resume are the menu's. App colours are `AppPalette`, keyed by app key so
a taxonomy rename cannot move them; the tokens are `Design/ReaderTheme.swift`. It is not the window #95 deleted: that was
a chat client onto data the MCP server already exposes, and this makes no model call of its own —
it is where the app's own output is read, and it replaces `NSWorkspace.open` on a `.md` file rather
than Claude Desktop. The menu opens it with **Open Worklens** (⌘O); the two folder items moved
to Settings → General under "Your data".

**How the reader *works* is `Sources/Worklens/App/AppModel+Reader.swift` (#233).** Opening and
selecting, stepping with ⌘← / ⌘→, the day-index read and the document build all live there.
**#244 gave it the whole history.** The day index is paged rather than capped at 120 days:
`ReaderPaging` (60 calendar days a page) is the window `DayIndex.entries(limit:after:before:)`
reads — a date window is served by `idx_captures_captured_at`, while a bare `LIMIT` is applied
*after* the group and bounds nothing — `loadEarlierDays()` appends the next page, and ⌘← loads
across the page boundary and stops at `ReaderPaging.oldestRecordedDay`. The minute refresh does
not rebuild whatever is open: `ReaderTick.decide` is a pure function over the open selection
and today — it rebuilds the open page only when
that page holds today — asserted in `ReaderTests` without a window; `AppModel.swift` keeps only the stored state they publish, because
an extension holds no stored properties — which is also why none of it is `private` any more.

**The sample week (#349, #350) is a second database the reader alone opens.**
`WorklensCore/Sample/` builds it: `SampleWeek` (all of last ISO week and this week up to today,
`dayCount(now:)` days keyed by weekday, so the same date always draws the same day; every id starts
`sample-`) writes captures, screen blocks and
calendar meetings into `<dataDir>/sample-week/worklens.sqlite` through the same stores, and
`SampleWeekHandoff` is the pure rule for when it shows (`atLaunch`), when it hands over
(`onSummary`: the first summary from a real provider, never `FakeProvider`) and what the ribbon's
status line says (`statusLine`, in the menu's own wording). The once-ever facts
(`sample_week_handed_off_at`, `sample_week_left_at`) are `app_state` rows on the **real** ledger.
`Sources/Worklens/App/AppModel+SampleWeek.swift` holds the seam (`isShowingSampleWeek`,
`showSampleWeek()`, `leaveSampleWeek()`), and `AppModel+Reader.swift` reads `readerDB`, which is
the sample's database while it is shown. Nothing else is ever handed that database: the MCP
server and the CLI open `Database(dataDir:)`, which is `worklens.sqlite` at the top of the data
directory, and `SampleWeekTests` runs every MCP tool over a ledger beside a built sample and fails
on any sample row. The describe worker's `onDescribed` hook calls `sampleWeekSummaryArrived`,
which records the handoff, fades the reader back, posts `Notifier.sampleWeekHandoff` through
`postBanner` with `mirrorAsNotice: false`, and removes the sample folder.

Since #357 the tour reads the sample too. `SampleWeek.tourWeek(now:)` is the week the Weeks stop
opens on (this week once it has `tourWeekWholeDays` whole days, last week before that), and
`AppModel.tourWeekMonday` hands it to `show(.weeks)` while the tour runs over the sample.
`SampleWeek.miniature` is the welcome window's static drawing of the week. The tour's
`.openWeeks` stop has `waitsFor: .weeks`: it cuts out the rail button, `TourState.canGoNext`
hides Next while the anchor is measured, and `show(_:)` calls `tourSawPlace`, which advances it.
`TourRun.welcome` has no Skip and ignores Esc; `TourRun.again` (Settings) keeps both.
`Waterfall.summaries(of:)` gives each app bar the summary of its longest block, which the pinned
tooltip on the `.moment` stop and every hover show. `WeekCalendar.placement` keeps a short
meeting chip's title and the block label beside it apart on the Weeks grid.

**Search is the MCP `search` tool and `worklens search` only:** the reader's search field went with the core cut (#297). The query and the
snippets are never logged at any level.

**The timeline is Markdown on demand, not a page (#297) and not a file (#299).** `TimelineRenderer` owns the rules #160 had moved
into `TimelineLayout`: `isShort` (#94), `nest` (#19), the heading labels and the header's totals
line — `Tests/Fixtures/timeline-golden.md` is the guard. `TimelineWriter.markdown(day:)`
(`nonisolated`) renders a day without writing it, for the MCP `timeline` tool;
`worklens timeline --rebuild` only rebuilds the blocks. The drawn Timeline tab, `TimelineLayout` and
`Theme.Colors.timelineBlock` went with the core cut.

**The welcome window is the second such scene (#131, four pages since #232, five since #352 added the tour's).**
`Window(SetupCopy.windowTitle, id: AppModel.setupWindowID)` in `WorklensApp.body`, fixed at
`Theme.SetupWindow`'s width and height (`.windowResizability(.contentSize)`), with
`Sources/Worklens/Setup/` behind it: `SetupWindowView` (the header, the five-page switch, the
step dots and the Back / skip / primary footer) and `SetupPages` (one view per `SetupPage` —
what Worklens does, Screen Recording, your keys, ready). `AppModel+Setup.swift` is everything
those pages ask the model, so `AppModel.swift` keeps one line of this.
`AppModel.startSetupIfNeeded()` is the launch gate and `SetupGate.decide` (WorklensCore) is the
whole rule, unchanged by #232: `onboarded_at` present means nothing happens; absent with either a
non-empty `captures` table or an existing `start_capturing_on_launch` row means the install
predates the window, so the key is written silently and capture is never deferred; absent on a
Mac with neither means the window is shown and `setupPending` holds the scheduler until the last
page's **Done** writes the key and calls `startOrResume()`. A configuration error leaves `db` nil, so the window is shown anyway and
`persistDeferredSetupKeys` writes the two dates when a reload finally opens a database — the same
`start()` the reload re-enters, which is why the gate is idempotent.

Two things about the scene are not obvious. `openWindow(id:)` called from
`applicationDidFinishLaunching` is *dropped* — the scene graph is not taking requests that early
— so `AppModel.openSetupWhenTheSceneIsReady()` repeats the request every
`setupOpenRetryDelay` until `SetupWindowView` reports that it appeared, at most eight times. And
the environment action itself has to exist before any menu has been opened, so `MenuBarLabel` —
the menu-bar item's own label, which SwiftUI evaluates at launch — calls `installSceneActions`
too, and `openWindow(id:)` parks a request in `pendingWindowID` if it is somehow still early.
Both replace the `NSWindowController` the review note asked for; #134 had already proved the
scene idiom.

**Page 1's words are `PRIVACY.md`'s words.** There is no resource bundle and `PRIVACY.md` is not
in the `.app`, so the three sections it shows — what it records, what it never records, what
leaves your Mac — are Swift constants in `SetupCopy.Privacy`, with a comment in each file naming
the other and `SetupCopyTests` failing the build when a constant stops appearing in the document.
Since #232 the page opens with `SetupCopy.Welcome`'s three lines and those four lists sit behind
a disclosure, which is why the constants are still the page's and still checked.
`SetupProgress` (WorklensCore) is the rest of the model: the three required steps behind
`MenuState.setup`, the `Finish setting up Worklens (2 of 3)` row that replaces `firstRunLine`
while it stands, and the 24-hour grace that keeps the two optional-permission advisories off the
menu until the welcome is finished.

**The mark (#114).** `WorklensCore/UI/WorklensMark.swift` is the only definition of what
Worklens looks like: a lens ring, seven things that can sit inside it (`Badge`), and three app-icon
directions (`Concept`, of which `chosen` is `lensTimeline` — switching it is a one-line edit plus
`make icon`). Two consumers draw from it and there is no third. `scripts/render-icon.sh` compiles
`WorklensMark.swift` together with `scripts/render-icon.swift` — two files through `swiftc`, no
package build — and writes `Resources/AppIcon.iconset` (each tile drawn at its own size, not
downsampled), the three concept renders and the contact sheet (the icon plus every badge at 1×
and 2×, light and dark, magnified with interpolation off) and the two container candidates
(`candidates/{A,B}/`) in the gitignored `build/icon-preview/`, then packs the `.icns` with
`iconutil`; `Resources/AppIcon.icns` is checked in, `scripts/bundle.sh`
copies it into `Contents/Resources` and `Info.plist`'s `CFBundleIconFile` names it, which is what
puts a real icon on the TCC dialog, Login Items, notification banners and every `NSAlert`. In the
app, `App/MenuBarGlyph.swift` turns each `MenuIcon` into an 18 pt *template* `NSImage` — cached,
because `render()` runs every counter refresh — so macOS tints it for a light or dark menu bar and
for Increase contrast; `MenuBarLabel` falls back to `MenuIcon.rawValue`'s SF Symbol if drawing ever
fails, and since #132 carries `MenuModel.iconLabel` as its accessibility label with the counts line as its value — `Worklens, capturing every 60 seconds`, a sentence written for speech. It has had an accessibility label since #114, but that label was `statusLine`, the menu row's own text: abbreviated for a 22-point menu bar and prefixed with an emoji, so VoiceOver read `black circle, Capturing · every 60 s`. `StatusItemTooltip`, which also set that label and the build stamp on the `NSStatusBarButton` underneath, went in #299. `MenuIcon` has seven cases
for eight scheduler states: `.idle`, `.locked` and `.asleep` share `.resting` because they mean
the same thing to the user, `.budgetExceeded` and `.stopped` no longer borrow the glyphs of
`.running` and `.paused`, and `.busy` is an init-level override on `MenuState.running` that
`.attention` outranks. `DevAppIcon` gives an unbundled `swift run Worklens` the checkout's `.icns`
so dev alerts are not generic. No SPM resources are involved anywhere in this.

**The recording mark on ivory.** After the reader redesign the dusk-blue lens icon was the one
thing still in the old palette, so `WorklensMark.chosen` is now `.recording`: a terracotta ring and
dot on an ivory squircle (`tileGradient()` runs `Palette.ivory` to `Palette.stone`, the page and
the rail). It is the rail's `lensMark` and the menu bar's `.dot` glyph at icon scale, drawn with the
rail's proportions (15 pt ring, 2.2 pt stroke, 5.2 pt dot) and sized so the ring spans about 60 % of
the old 824 pt tile. It draws the same at every size, since its 63 pt stroke is still a whole pixel
on the 16 px tile. `Palette` repeats the reader's `Theme` colours as `CGColor`s, because
`WorklensCore` cannot import SwiftUI. The lens concepts still render to `build/icon-preview/` on
their old dusk gradient.

**One container, and glyphs sized for 18 pt (#238).** The icon used to draw a rounded tile
inset to 824 pt inside the 1024 pt canvas and stroke a white hairline around it — a rounded
rect inside a rounded rect, with the second outline the eye was reading. It is now a single
container: `WorklensMark.Container`, a superellipse (|x|⁵ + |y|⁵ = 1, which is macOS 26's
continuous corner — a `CGPath` rounded rect hands a straight edge to a circular arc, and that
join is what makes a tile look like a sticker), filled with `tileGradient()` and lit along the
top edge by a short gradient *inside* the clip rather than a stroke around the path.
`tileInset` and `tileCorner` are gone. How much of the canvas the container fills is the one
thing no test can settle — this app ships a legacy `.icns` through `CFBundleIconFile`, and an
Icon Composer `.icon` asset cannot be built here (`actool` needs a full `Xcode.app`; this
machine has the Command Line Tools) — so both are rendered for a real Dock:
`A` full bleed and `B` a 46 pt margin, at 1024/512/128/32/16, under
`build/icon-preview/candidates/`. `shippedContainer` is `B`, and moving it is one line plus
`make icon`. In the menu bar the ring is `ringRadius` 6.4 at `ringWidth` 1.7 — a 14.5 pt mark
on the 18 pt square instead of 15.2 pt, with `.slash` reaching 5.35 pt per axis instead of a
5.9 that ran 18.5 pt across an 18 pt canvas — and `.hollow` is a 6.9 pt lens around a clear
4.8 pt opening rather than a thin ring the same size as `.dot`'s disc.
`Tests/WorklensCoreTests/WorklensMarkTests.swift` renders every badge at 18 pt and 2× and the
icon at 1024 into alpha bitmaps and holds them to recorded numbers: coverage inside a band,
ink inside the ring, never blank (the failure `MenuBarGlyph`'s guard catches at runtime and
nothing caught before it), no two badges within 2.5 % of the same silhouette, and `.dot` and
`.hollow` separated by their *centre* coverage — 1.00 against 0.00 — because their total
coverage is 0.265 against 0.273 and could never have told them apart.

**Localization: the English sentence is the key (#161).** `WorklensCore/Util/L10n.swift` is the
whole mechanism — `L10n.string(_:value:comment:)`, `L10n.format(_:_:)` and
`L10n.plural(count:one:other:)`, each a `Bundle.main.localizedString(forKey:value:table:)` on the
one `Localizable` table with the English literal passed as the fallback value. The `Worklens`
target uses `String(localized:, comment:)` for its SwiftUI, alert and notification strings, which
resolves through the same bundle. Nothing else exists: no string catalog (`xcstringstool` and
`genstrings` are both absent from the Command Line Tools), no `defaultLocalization`, and no SPM
resource bundle.

The constraint that decided the design is that `swift test` and `swift run` load **no** `.lproj`
at all, so every lookup outside the built `.app` misses and must still produce correct English —
hence the key being the English sentence, and hence `L10n.plural` carrying explicit `one:`/`other:`
English formats and falling back to `String(format:)` rather than trusting the stringsdict. A
`.stringsdict`-only plural would print `Today: %lld screenshots` for one screenshot.

| Where | What |
|---|---|
| `Resources/en.lproj/Localizable.strings` | every singular key, English on both sides; regenerated by `scripts/strings-extract.sh --strings` |
| `Resources/en.lproj/Localizable.stringsdict` | the six counted nouns, keyed by their English `other` string |
| `Resources/pt-BR.lproj/` | a deliberately **partial** translation — the popover, the status and counts lines, the spoken menu-bar label, the notifications, the welcome window and the reader's empty states. Most of Settings is what it omits, and that falls back to English one key at a time, which is what makes the fallback observable. A *surface* is translated whole or not at all: half a pane in each language is the one outcome worse than all of it in English |
| `Resources/Info.plist` | `CFBundleDevelopmentRegion` = `en` |
| `scripts/bundle.sh` | copies `Resources/*.lproj` into `Contents/Resources` **before** `scripts/sign.sh` runs — a resource added after signing invalidates the signature |
| `scripts/strings-extract.sh` | the keys, read out of `Sources/` with a regex over the four allowed call shapes, plus `TableColumn(`, `DatePicker(` and `.alert(` — SwiftUI shapes whose bare literal is a live `LocalizedStringKey` lookup the extractor could not see, so the lint now fails on one and pushes it to `String(localized:)` (`--plurals`, `--strings`, `--missing`) |
| `scripts/strings-lint.sh` | `make lint-strings`: `plutil -lint` on every catalog, a failure for a code key missing from `en.lproj`, a failure for a translated value whose format specifiers do not match English's, a warning for a translated key the code dropped |

**What stays English:** timeline text, model prompts, log messages, CLI output and every
value written to the database — and nothing else. Every window is localizable, the welcome pages
and the reader's empty states included. A localized timeline would change its
meaning to the golden fixtures; a localized `--json` key or
column value would break the schema. All but the CLI are English by construction — no localized string is ever in reach. The
CLI is not: `scripts/install.sh` symlinks `worklens` into `Worklens.app/Contents/MacOS/Worklens`,
so `Bundle.main` for the installed CLI is the app bundle and its `.lproj` catalogs answer. A
command that names a pane, a setting or a tab prints its stable `rawValue`, never a localized
`title` — `worklens settings --tab` does exactly that. `REPORT_LANGUAGE` (#157) is the unrelated knob that tells the *describe model*
which language to write each summary in. `CONTRIBUTING.md` → "Add a language" is the procedure.

**The version, and where it comes from (#130).** There is no hand-edited version number.
`scripts/bundle.sh` derives `CFBundleShortVersionString` from
`git describe --tags --match 'v*' --abbrev=0` with the `v` stripped, and `CFBundleVersion` from
`git rev-list --count HEAD`; `WorklensVersion` (`WorklensCore/Util/Version.swift`) reads both back
out of the bundle through `BundleLayout.infoDictionary`, with `WorklensVersion.fallback` — the same
pair checked into `Resources/Info.plist` — as the answer for an unbundled `swift run Worklens` and
for a tree with no tag. So the tag is the single source of truth and a "keep in sync" comment
cannot rot; before this, two constants and that comment meant every build made in 168 commits
reported `0.1.0`.

`--abbrev=0` and not the default `git describe`, because `CFBundleShortVersionString` has to be
one to three dot-separated integers; `v0.1.0-12-g9772c6a` is not, and Finder and every installer
misread it. `bundle.sh` enforces the rule and `VersionTests` asserts
it. `WorklensVersion.numbers(from:)` takes the dictionary rather than reaching for `Bundle.main`
for the reason `BuildStamp(info:)` does — and one more: under `make test` `Bundle.main` is Swift
Testing's own bundle, so the suite would be asserting against the test runner's version.

There is no release tooling and no published download: with no Apple Developer ID a downloaded
build would be self-signed, quarantined, and read by TCC as a new app on every update, losing
Screen Recording, Accessibility and Automation each time. The release script that existed until
the 2026-10 core cut lives in git history. Sparkle was considered and rejected: it needs a
framework in the bundle and a hosted appcast, and "no server" is `docs/PLAN.md`'s first
principle.

**Which build is running, and staying on the latest one.** `scripts/bundle.sh` stamps the
bundle's own `Info.plist` with `WLCommit`, `WLCommitShort`, `WLPullRequest`, `WLCommitSubject`,
`WLBuildDate`, `WLDirty` and `WLRepoPath` (#119), before `scripts/sign.sh` runs `codesign`,
because the signature seals `Info.plist` and a later edit would break it; `BuildStamp` (in
`WorklensCore/Util`) reads those keys back. The *bundle*
carries the answer because a checkout's HEAD moves the moment you pull, and the question is which
commit is running — `AppModel.versionLine` puts it in the menu (`0.1.0 · #105 · 0ae882e · updated
3 hours ago`, version first since #130 because that is what a bug report needs first, with
`buildLine` the same facts minus the version for `worklens version`'s second line). The
menu-bar icon's hover text that carried the longer form (`StatusItemTooltip`, #114/#132) went in
#299.

**The signature, and why the grants keep resetting (#115).** `scripts/make-dev-cert.sh` behind
`make dev-cert` is the whole Keychain Access ritual the README used to ask for: `openssl` writes a
self-signed `codeSigning` certificate, `security import` puts it in the login keychain,
`set-key-partition-list` stops `codesign` raising a dialog on every build (which would also wedge
an unattended auto-update), and `add-trusted-cert -p codeSign` in the *user* trust domain is the
step Certificate Assistant leaves out — without it `find-identity -v` reports zero valid
identities. It is idempotent and needs no admin rights. The app never runs it: `make dev-cert`
needs a trust prompt and a typed password in an interactive terminal, which an `LSUIElement` has
nothing to offer. Unrelated to the partition-list decision above about the Google token (`GOOGLE_TOKEN_STORE`),
which is about a keychain *item*, not the app's signature.

**Installing it, and finding the way home (#119).** `make install` (`scripts/install.sh`)
`ditto`s the freshly signed bundle to `/Applications` — `~/Applications` when that is not
writable — and symlinks that copy's binary to `/usr/local/bin/worklens` when the directory
already exists and is writable, `~/.local/bin` otherwise; it never creates `/usr/local/bin`,
which is absent on a clean Apple-silicon Mac and needs `sudo`. `APPS_DIR` and `BIN_DIR` override
both and `--dry-run` prints without writing. It deliberately does not touch
`~/Library/Application Support/Worklens/.env`, which outranks every checkout (#34) and which the
app writes for itself on a first run (#116) — that file is `make install-env`'s to decide, and
only if the user asks for it.

`scripts/setup.sh` behind `make setup` is those targets in order, each printed and consented to
before it runs, with `--dry-run` turning every write into an echo. It stops for nothing: since
#116 a Worklens with no keys captures, writes its own `.env` and says "Add your Gemini API key to get
started" in the menu, so setup reports what is missing and carries on rather than inventing a
requirement the app does not have. The Claude Desktop merge is printed, never performed — that
is #140.

Moving the bundle away from `build/` is what `WLRepoPath` exists for: `CheckoutLocator.resolve`
(in `WorklensCore/Util`, so the decision is unit-tested rather than only observable by launching
the app) prefers the stamped checkout and falls back to the bundle's grandparent, and
`AppModel.repoRoot` is one call to it. Without the stamp an installed copy had no repository
beside it, so the menu's "Update and restart…" and every auto-update silently disappeared.
`BundleLayout` (also `WorklensCore/Util`) answers the other half — is the running binary the one
inside `Worklens.app` or the loose development build — and the CLI prints one stderr line when it
is the latter, because the two carry different signatures and therefore different TCC grants.
Neither `Bundle.main.bundleIdentifier` nor a `.app` suffix on `bundlePath` can tell: through the
`worklens` symlink `Bundle.main` is `/usr/local/bin` and the identifier is nil, so the test is
`_NSGetExecutablePath` with its symlinks resolved, landing inside `<name>.app/Contents/MacOS`
beside a real `Info.plist`. The same lookup feeds `BuildStamp.current`, which for the same reason
no longer reads `Bundle.main.infoDictionary`: through the symlink there is none, and
`worklens version` would print a bare version number for a bundle that carries the whole stamp.

`scripts/installed-app.sh` answers the matching question from the shell — is there an installed
Worklens stamped with *this* checkout — and is what makes `scripts/update.sh` quit the installed
copy as well as the one in `build/` (a `pkill` for the checkout path never matched it, so the
rebuild landed and `open` merely re-activated the old process), re-install after signing, and
relaunch the right one. `scripts/launch.sh` holds that last rule for `make run` and
`update.sh` alike, and the one about configuration: it points `WORKLENS_ENV_FILE` at the
checkout's `.env` only for `build/Worklens.app` on a Mac with no installed `.env`. An installed
copy is always opened plainly, so a fresh one-line install writes its own Application Support
`.env` instead of reading the clone's.

`App/AutoUpdater.swift` polls `git ls-remote origin refs/heads/main` every
`AUTO_UPDATE_POLL_MINUTES` and runs `scripts/update.sh --log` — the menu item's own round trip,
minus the log window nobody asked for — when it has moved. This is not CI and cannot be: a GitHub
runner cannot reach this Mac, and the release build, the `Worklens Dev` signature and the relaunch
only mean anything here. `AutoUpdatePolicy.decide` is the pure half and holds every refusal: it
blocks a checkout that is dirty, on a branch other than `main`, without an upstream, or on a Mac
with no signing certificate (an ad-hoc signature reads to macOS as a different app, and Screen
Recording goes with it — silently, which is the whole problem), and it defers while the app is
busy (a sync, a reload, a deletion) or while capture is paused (#113 — the restart would come back capturing, which is
the one thing the kill switch promises never happens; an indefinite pause defers indefinitely, and
the menu says why through `updateAvailableLine`). Each remote commit is attempted at most once per launch, which is what stops the
loop `update.sh` would otherwise create: it skips the pull on a dirty tree and rebuilds anyway, so
HEAD never reaches the remote and every poll would restart the app again.

**Config keys for auto-update:** `AUTO_UPDATE_ENABLED` (default false), `AUTO_UPDATE_POLL_MINUTES`
(default 15, floored at `AutoUpdatePolicy.minimumPollMinutes`).

**The pause outlives the process (#113).** `CaptureScheduler.pause(until:)` writes
`capture_paused_until` to `app_state`; `AppModel.start()` calls
`startRestoringPause()`, which reads the record *before* `start()` clears it and puts the loop
straight back into the same pause — started, because a timed pause can only expire from inside
`performTick`. A deadline that passed while the app was down is deleted and the launch captures
normally. `PauseReminder` (pure, in `WorklensCore/Capture`) decides when to say "still paused";
`AppModel` posts it off the 30 s refresh timer, every `PAUSE_REMINDER_HOURS` (default 4, 0 off).

**What was just captured, and how often the safety nets fired (#151).** A `LastFrame` is read by
`CaptureStore.fetchLastFrame(day:timeZone:)` — the newest `captures` row plus two columns of its
description, never `raw_json`. **Bounded to one local day**: unbounded it drew Friday evening's
frame under Monday's `0 screenshots`. `LastFrame.outcome(...)` is
the one place `describe_status`, `skip_reason`, `captures.is_redacted` and
`descriptions.is_sensitive` become a single ending, with blocked outranking everything (such a
frame never reached the model) and sensitive outranking described. The menu's two last-frame rows
and `MenuState.lastFrame` went in #299; the MCP `now` tool is the reader that remains. `MenuCounts` gained `blocked` (one more column on the grouped `captures`
query, the same `is_redacted` flag `BlockBuilder.redactedTaskKey` blocks are built from),
`sensitive` and `redactions` (`DescriptionStore.privacyCounts` — sensitive counts every row,
inherited included, so it matches the timeline footer; redactions sum `details_json` on described
rows only, because an inherited row copies that JSON wholesale). `MenuModel.countsRow` prints each
only when it is non-zero. `DescribePrompt.sensitiveCategories` is the category list lifted out of
the prompt literal: `systemInstruction` interpolates it and Settings → Privacy quotes it, so the
pane cannot describe a rule the model is no longer being given.

**CLI convention:** the root command lives in `Sources/Worklens/CLI/WorklensCLI.swift`; each
subcommand is its own file `Sources/Worklens/CLI/<Name>Command.swift`. Since #158 the root holds
three `CommandGroup`s — Everyday, Setup and integrations, Diagnostics (#300 removed Development) — instead of one
flat array, so a new issue adds one file and one line **to the group it belongs in**; the flat
`subcommands:` array is empty and stays that way, because an ungrouped command is invisible in the
grouped help.

Four shared pieces live beside them, and a new subcommand should reach for them rather than repeat
their work:

- `CLIFailure` (`WorklensCore/Util/CLIFailure.swift`) — throw this, not `ValidationError`, when
  the *run* failed rather than the command line. `ValidationError` prints the usage block and
  exits 64; `CLIFailure` prints one `error:` line and exits 1 (runtime), 3 (permission,
  `DataDirLocation.refusedExitCode`) or 4 (config). 2 is unused since `run --headless` went.
  The catch is in `CLIEntryPoint.run`, which parses and runs itself instead of calling
  `WorklensCLI.main(_:)`: ArgumentParser honours a custom exit code only for a thrown `ExitCode`
  and turns everything else into 1.
- `LocalDay` (`WorklensCore/Util/`), conformed to `ExpressibleByArgument` in
  `CLI/CLIArguments.swift` — declare `var date: LocalDay` and the parser does the validating,
  `today`/`yesterday`/`-N` included.
- `JSONOutputOptions` and `CLIOutput` (`CLI/CLIOutput.swift`) — `@OptionGroup var output:
  JSONOutputOptions` for the flag, `CLIOutput.printOrJSON` for the two renderings. The JSON
  payload should come from the same function the text does (`ConfigDumpText.rows` beside
  `.render`) so the two cannot disagree about a number.
- `CLIEntryPoint.writingCommands` — a subcommand that opens a write connection for more than an
  instant belongs in it.

`worklens app` is what is left of #158's split of the old `run` (its headless half went in #300). Both GUI spellings —
`app` and the still-working `run` — are answered in `main.swift` before ArgumentParser sees them,
because `NSApplication` has to come up from the top level of the process; `AppCommand` exists for
the help screen and for `AppCommand.refusal`, the one place that says why a checkout build must
not put a menu bar on the screen.
