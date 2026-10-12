# What leaves your Mac, what Worklens records, and how to remove it

Worklens takes screenshots of your own screen, describes them with a vision model, and lays
your day out as a timeline. That is a lot of trust to ask for, so this document says exactly what leaves the
machine, what is stored, where, and how to delete any of it. Every claim below names the file
that implements it, so you can check rather than believe.

There is no server, no account, and no telemetry. Nothing about you reaches the author of this
software, ever — there is no code in the repository that could send it.

## Privacy in 30 seconds

- **Everything lives in one folder on your Mac**, `DATA_DIR`. `rm -rf` it and Worklens knows
  nothing about you.
- **One destination sees your activity**, a paid API you configure yourself: Google (Gemini)
  describes each frame. Nothing goes to Anthropic from the app any more: the daily and weekly
  reports it used to write with Claude were removed on 2026-10-05.
- **Everything else that leaves is optional**: GitHub, asked once every 15 minutes
  what `main` points at and nothing else, and the context sources you connect yourself. Each one
  has a row in the table below.
- **Nothing goes to the author of this software.** No analytics, no crash reporting, no identifier.
- **`⌥⇧P` pauses everything instantly**, three blocklists keep an app or a site out entirely,
  editable in Settings → Privacy or from the menu while the thing is in front of you — and the
  menu deletes the last 10 minutes or the last hour.

<!-- #131: the welcome window's first page duplicates the wording of this section and of the two
below it ("What it records", "What it never records") as Swift string constants in
`Sources/WorklensCore/UI/SetupCopy.swift`. There is no resource bundle in this package, so the
app cannot read this file at runtime. Change both, or neither: `SetupCopyTests` fails the build
when a sentence there stops appearing here. -->

## What leaves your machine

This table is the whole list — every host any code in this repository can reach. Two rows are on
by default, and a third, GitHub through `gh`, runs only once you have installed `gh` and logged it
in; the rest exist only because you connected something. None of them belongs to the author of
this software.

| Destination | What is sent | When | How to turn it off |
|---|---|---|---|
| **Google (Gemini)** — `generativelanguage.googleapis.com` | the redacted text of the focused window, plus a JPEG only when that text was incomplete, plus the app name, window title, URL and timestamp around it, plus one-line summaries of the previous few frames | once per frame worth describing | pause capture, or leave `GEMINI_API_KEY` unset — nothing is described without it (`LLM/GeminiClient.swift`) |
| **GitHub** — `github.com` | one `git ls-remote origin refs/heads/main` — the question "what does `main` point at?". No screen content, no account, no identifier: it is the same request `git` would make from your shell, over whatever credentials your checkout already uses | when you press Check now, or, with `AUTO_UPDATE_ENABLED=true` (off by default), every `AUTO_UPDATE_POLL_MINUTES` (15 by default), starting a minute after launch; either way **only when the app is running from the checkout it was built from** — a bundle copied anywhere else never polls at all (`AppModel.repoRoot`) | leave `AUTO_UPDATE_ENABLED=false`, the default (`App/AutoUpdater.swift`, `App/AppModel.swift`) |
| **Granola** — `public-api.granola.ai` | your Granola API key and a request for your own recent notes and their transcripts | once per context sync, only while `GRANOLA_API_KEY` is set — plus one request for a single note each time you press Test in Granola's setup sheet under Settings → Connections, which stores nothing | leave `GRANOLA_API_KEY` unset (`Context/Sources/GranolaSource.swift`) |
| **GitHub, through the `gh` command** — `api.github.com` | under the login `gh` already holds (Worklens never reads its token): three searches for your own PRs, your own issues and the PRs you reviewed, updated since a date; one request for your username; and one request for the reviews on each PR of someone else's you reviewed; and, with `MEMO_REPOS` set, one file list (paths and change types, never contents) per merged PR of yours in those repos, read once. The answers keep each item's title, link, repo, number, state and times — never a body, a diff or a review's text | once per context sync while `GITHUB_SHIPPED=true` (the default) and `gh` is installed and logged in, and when you run `worklens shipped sync`, and, for a memo repo's merged PR, once when it first lands or when `MEMO_REPOS` changes | `GITHUB_SHIPPED=false`, which also deletes what was stored; an empty `MEMO_REPOS` (the default) reads no file list and deletes the memo rows (`Outputs/GHRunner.swift`, `Outputs/OutputSync.swift`, `Outputs/MemoOutputs.swift`) |
| **Google Calendar** — `www.googleapis.com` | your Google access token and a request for your primary calendar's events in a date window | once per context sync, only after you connect Google in Settings → Connections | *Disconnect* in that source's ••• menu (`Context/Google/CalendarSource.swift`) |
| **Google sign-in** — `accounts.google.com`, `oauth2.googleapis.com` | the OAuth exchange itself: your client id and secret, the authorisation code, a refresh token on renewal or revocation, and one `userinfo` call for the address of the account you connected. The browser's redirect comes back to a loopback server on `127.0.0.1` that is open only for those few seconds and never leaves the Mac (`Context/Google/LoopbackReceiver.swift`) | when you connect or disconnect Google, and when an access token expires | do not connect Google (`Context/Google/GoogleAuth.swift`) |
| **Pages you open from a menu or a button** — `console.cloud.google.com`, `myaccount.google.com`, `app.granola.ai`, `claude.ai`, `openai.com`, `github.com`, `aistudio.google.com` | nothing from Worklens. These are the pages Settings → Connections' setup steps, the "Revoke at …" item in each source's ••• menu, "Get Claude Desktop" and "Get Codex" (shown only when that app is not installed), the welcome window's "Get a Gemini key" link, and the Help menu's documents link to; clicking one opens it in your own browser, which then connects exactly as it would for any link you clicked. Worklens sends them no request and no credential. | only when you click a setup or revoke link, the key link on the welcome window, a Help menu item or a **Learn more** link | do not click them; the same steps are written out in `docs/user/integrations.md`, and the Help menu's documents normally open the copies inside the app rather than the web at all (`Context/IntegrationSetup.swift`, `Context/IntegrationRemoval.swift`, `Settings/ConnectionsSection.swift`, `UI/HelpDoc.swift`, `Setup/SetupPages.swift`) |
| **An MCP client, if you configure one** | over stdin/stdout, not the network — but the client will normally send it on to its own model. See below | only while a client keeps `worklens mcp` running | remove the `worklens` entry from the client's configuration (`MCP/WorklensMCPTools.swift`) |

**`--fake` reaches none of these hosts.** The offline provider (#121) makes its sentences up
locally, so no key is needed and nothing is sent. Everything it writes says
`sample — not a real summary`. (`LLM/FakeProvider.swift`)

Two consequences worth knowing:

- **Use a billing-enabled Gemini project.** On Google's free tier your prompts and images may be
  used to improve their models. On a paid project they are not. `.env.example` says so at the key.
- **Meeting transcripts never reach a prompt.** A body over 2 000 characters — which is what a
  Granola transcript is — is written to `data/context/<source>/<id>.md` and referenced from the
  database by path. The describe prompt carries at most the title of the meeting a frame falls
  inside, never its body. (`Context/ContextBody.swift`, `Describe/DescribeWorker.swift`)

**Credentials and payment data are taken out before anything is sent.** The window title and the
URL go through one local regex pass (`Privacy/TextRedactor.swift`) on their way into the describe
prompt, and what it finds is replaced with a placeholder — `[CARD_1]`, `[IBAN_1]`, `[OTP]`,
`[SECRET_1]`, `[PASSWORD]` — before the request is built. It covers card numbers (13–19 digits that
also pass the Luhn check), IBANs, one-time codes, API keys and tokens (`sk-…`, `AIza…`, `xoxb-…`,
`ghp_…`, `AKIA…`, JWTs, `-----BEGIN … PRIVATE KEY-----`, `Bearer …`) and `password=`/`senha=` pairs,
and it drops the query string and fragment from any web address in the text, with or without
`https://` in front (an address bar often shows none), while keeping the host and path. The
focused window's text goes through the same pass before it is stored, so an address bar's query
is not kept there either, nor in search. What it deliberately
*keeps* is your own working context: personal names, phone numbers, email addresses, CPFs, CNPJs,
IP addresses, postal addresses, dates, prices and version numbers. None of those is a credential,
and a timeline that cannot name the person you were emailing is not worth reading; the blocklists
below are the tool for a window that should not be looked at at all. `REDACT_EXTRA_PATTERNS` adds
your own shapes (`[CUSTOM_1]`). The screenshot itself cannot be redacted — a picture of a card number
is still a card number, which is why `DELETE_SENSITIVE_SCREENSHOTS` defaults to on.

**Checking a key in the app asks Google one extra question.** It sends the API key and nothing
else, to `GET /v1beta/models` at Google — "do you recognise this key?". The key travels in a
request header, never in the URL. No prompt, no image, no tokens billed, and no new host: it is
already in the table. It never runs on its own — only when you save a key in Settings →
Connections → AI providers or press **Verify** there. Each check writes one `llm_calls` row so the
call is auditable like every other: purpose `verify`, zero tokens, `$0.00`, and on a failure the
HTTP status and nothing else — never the key, never the provider's own wording.
(`Config/KeyProbe.swift`, `Config/Accounts.swift`)

**The update check asks a question; it does not answer one.** `git ls-remote` sends no data about
you, and it only happens at all when the running app sits in `<repo>/build/Worklens.app` with an
executable `scripts/update.sh` and a `Package.swift` two directories above it — which is what
`AppModel.repoRoot` tests for. A bundle you dragged to `/Applications` fails that test, gets no
updater and no "Update and restart…" button in Settings → General → Updates, and never talks to
GitHub. In a checkout the poll is off by default too (`AUTO_UPDATE_ENABLED=false`); set it to `true` to
turn it on. The button works either way.

**The MCP client is a destination you create (#89).** `worklens mcp` serves your history over
stdin/stdout to whichever client you put in its configuration — Claude Desktop, Cowork, Codex. It
collects nothing new: every tool reads the same already-redacted text the app stores, and there are
no write tools, so a client cannot capture, generate or delete anything. What changes is where the
data can go. A timeline, a day's statistics, a search hit or a meeting summary that a
client asks for is sent to that client, and that client will normally send it on to its own model
under its own privacy terms — for Claude Desktop, Anthropic's. Nothing is sent until a client asks,
the server runs only while a client keeps it running, and removing the `worklens` entry from
`~/Library/Application Support/Claude/claude_desktop_config.json` ends it. Full meeting transcripts
stay out of this too: `context_events` cuts a body at 400 characters. Since #319 `stats` and `span` also name the documents you had open (a Google file's id, a GitHub PR or issue, a local path with your home folder written as `~`) with their minutes, and `shipped` adds how long each PR's or issue's page was on your screen; both are computed on read from addresses already stored, so erasing a screenshot erases them, and none of it is logged or sent to Gemini. Each Granola meeting also lists the next steps and decisions from its full summary; transcripts are never included. (`MCP/WorklensMCPTools.swift`, `CLI/MCPCommand.swift`)

Beyond that table there is nothing: no analytics, no crash reporting, no identifier of any kind.
Every call other than Gemini is one you turned on, and a test in the suite fails the
build if a new host appears in `Sources/` without a row here
(`Tests/WorklensCoreTests/NetworkDestinationsDocTests.swift`).

## What it records

- **A screenshot**, only when the focused window's own text did not already cover it — with
  `CAPTURE_SOURCE=auto` and Accessibility granted, a fully covered window is described from its
  text and never photographed at all — and then only when the screen actually changed since the
  last one, or when `CAPTURE_HEARTBEAT_SECONDS` has passed without a change. Downscaled to
  `CAPTURE_MAX_EDGE_PX` on its longest edge and JPEG-encoded at `CAPTURE_JPEG_QUALITY`
  before it is written — the full-resolution frame never touches the disk. `CAPTURE_SOURCE`
  decides the rest: `accessibility` never takes one, `screenshot` always does, `both` takes
  both. (`Capture/CaptureScheduler.swift`, `Capture/ImagePipeline.swift`)
- **Metadata about the moment**: the timestamp, which display, the frontmost app's bundle id and
  name, the window title, and — only while `COLLECT_BROWSER_URL=true` — the frontmost browser
  tab's URL, without its query string or fragment. The address of the document the focused
  window shows follows the same rule: a web address is stored stripped, whichever app shows it,
  and not at all while `COLLECT_BROWSER_URL=false`; a file open in an editor keeps its path,
  without any `#fragment`. The title
  and the tab's URL are read from the focused window itself when you have granted Accessibility — its
  title and the address of the page it is showing, nothing else from the window — and otherwise
  from the two older probes: the window list, which needs Screen Recording, and one AppleScript
  per browser, which runs only for a browser whose Apple Events permission you have already
  granted — it never asks for one mid-capture — and cannot answer for Firefox. Each frame
  records *which* of those answered, so you can see how much of a day needed either permission at
  all. (`Capture/ForegroundContextCollector.swift`)
- **The focused window's text**, but only if you grant Accessibility (Settings → Capture → Access;
  Worklens never asks for it on launch, and never asks at all unless you press that button).
  With it, Worklens reads what the window already exposes to assistive technology — the roles,
  titles and values a screen reader would read — as a plain indented outline of the *focused*
  window only, capped at `AX_MAX_TEXT_CHARS`. It is redacted before it is written, and the
  redacted text — never the raw walk — is what goes to the describer in place of a picture. It
  is also what lets the app stop paying for a fresh look at a screen that has not really changed.
  Without the grant nothing about this happens.
  (`Capture/AccessibilitySnapshotter.swift`, `Describe/DescribeWorker.swift`)
- **A short text description** of each frame: one or two sentences, an app label and a task
  label from your own taxonomy. (`Describe/DescribeWorker.swift`)
- **A timeline and a spend ledger** built from those descriptions.
- **Context you already have elsewhere**, if you connect it: the meetings you attended, from
  Granola and your Google calendar. Only ever your own activity, never anyone else's.
  (`Context/`)
- **Your coding agents' session metadata**, while `AGENT_SESSIONS=true` (the default): Worklens
  reads the logs Claude Code (`~/.claude/projects/`), the Claude app's Code tab
  (`~/Library/Application Support/Claude/claude-code-sessions/`) and Codex (`~/.codex/sessions/`,
  `~/.codex/archived_sessions/`) already keep on this Mac, and keeps each session's tool, folder,
  repo, branch, first and last instant and edit count, the instant of each prompt you typed, the
  span of each agent turn and the PR links. It decodes a fixed list of fields and never stores a
  prompt's text, a command, a tool's output, a file's contents or a session's title. Reading them
  sends nothing anywhere, runs no git command and asks for no permission.
  `AGENT_SESSIONS=false` stops it and deletes what was kept; `worklens agents forget` deletes it
  once. (`Agents/`, #321)

**Nothing is captured before you have been told all of this (#131).** On a first launch Worklens
opens a welcome window that shows the three lists on this page — what it records, what it never
records, what leaves your Mac — and only then asks for Screen Recording, your Gemini API key and
the optional permissions, each of which can be skipped. Capture starts when you press **Start
capturing** on its last page, and not before; the notifications dialog is on that window's
optional page rather than being the first thing a new install does. An install that was already
running is never shown the window and never stops capturing. The menu and Settings → Advanced →
**Show welcome again** re-open it.

## What it never records

- **Audio.** Nothing in Worklens opens a microphone.
- **Keystrokes.** The only thing it asks the input system is *how long ago* you last touched the
  keyboard or mouse, so it can tell whether you are there. Not what you pressed.
  (`Capture/SystemStateMonitor.swift`)
- **Other people's screens or accounts.** Only the frontmost window of your own session.
- **Anything at all while paused, locked, asleep, idle, or in front of a blocked app.** Each of
  those writes a row that says only *that* — so the timeline has no unexplained hole — and no
  image, no title and no URL. (`Capture/CaptureScheduler.swift`, `Privacy/PrivacyPolicy.swift`)
- **The value of a password field.** With Accessibility granted, Worklens does read the text the
  focused window exposes — that is the point of the grant — but the value of a secure field is
  never asked for: the walk skips the call entirely for a secure role or subrole, which is a test
  in the suite rather than a promise here (`Capture/AXWalk.swift`). Whatever it *does* read goes
  through the same redactor as everything else **before** any of it is written, so a card number,
  an IBAN, a one-time code, an API key or a `senha=` value is replaced by a placeholder and the
  original is never stored (`Privacy/TextRedactor.swift`, `Capture/CaptureScheduler.swift`).
  Screen Recording still governs the pixels, separately and as before. And the blocklists remain
  the tool for a window that should not be looked at at all, which is why `1Password` and
  `Password` are blocked by default — a blocked app's accessibility tree is never read either.

## Where the data lives

One folder, `DATA_DIR`: `~/Library/Application Support/Worklens/data` for the installed app,
`./data` beside a checkout, wherever you point it if you set the key. Nothing is written outside
it except five things. `~/Library/Application Support/Worklens/.env` — your configuration, which
the app creates empty at mode 600 on its first launch if you have none and never writes to again.
`~/Library/Application Support/Worklens/settings.json` — the file Settings and `worklens config
set` write, mode 600, which since #124 is also where an API key typed into Settings → Connections →
AI providers is kept: plain JSON, unreadable by other accounts on this Mac, readable by
anything running as you, and included in any backup of that folder. (The macOS Keychain would be
a better home for it; its access dialog returns after every rebuild of a self-signed build, so it
is not usable until this build has a Developer ID — see `docs/decisions.md`. Worklens never shows
a stored key again: every surface prints the same seven-character prefix `config-dump` does.)
`~/Library/Application Support/Worklens/.launch-env`, a one-line note of *which* configuration
file this launch was told to read so an update can put the app back on it (a path, never a
value; deleting it is safe). And the macOS keychain entry for a Google refresh token if you
connect Calendar (`Context/Google/Keychain.swift`) — unless you choose the data folder
when you connect, which puts it *into* `DATA_DIR` as `google-token.json`, mode 0600, to
escape a macOS access dialog that a rebuild raises again no matter how the item was stored
(docs/contributing/signing.md, "The Keychain dialog after every rebuild"). Then it is as exposed
as your `.env`: unreadable by other accounts on this Mac, readable by anything running as you,
and included in any backup of the folder (`Context/Google/FileTokenStore.swift`). The Google
Calendar setup sheet asks which of the two you want as you connect, Settings → Advanced → **Keep
the Google sign-in in** changes it later, and both write the answer to `GOOGLE_TOKEN_STORE`; the sheet pre-selects the
data folder on a build with no Apple Developer Team ID, because on those the keychain asks for your
login password again after every rebuild. And, only if you ask for it,
`~/Library/Application Support/Claude/claude_desktop_config.json`: Settings → Connections → Claude
Desktop → **Connect**, and `worklens mcp install`, merge one `mcpServers` entry into that file so Claude Desktop can launch `worklens mcp` (#140). Your old file is copied beside it first as
`claude_desktop_config.json.worklens-<timestamp>.bak` — nothing deletes those copies, so they stay
until you do. Nothing else in the file is changed, and a file Worklens cannot parse is refused
rather than replaced (`Diagnostics/MCPClientConfig.swift`).

```
data/
  worklens.sqlite                 # every row: captures, descriptions, blocks, ledger
  taxonomy.json                   # your app/task vocabulary, projects, and the email domains
                                  #   meetings count toward or ignore (domains only, never addresses)
  screenshots/YYYY-MM-DD/*.jpg    # the frames themselves
  timeline/YYYY-MM-DD.md          # only if a build from before 2026-10-05 wrote it
  reports/                        # only if a build from before 2026-10-05 wrote reports
  context/granola/<note_id>.md    # meeting transcripts, if Granola is connected
  taxonomy_proposals/*.json
  evals/exports/…                 # only if you ran `export-evals` before #300 removed it
  logs/worklens-YYYY-MM-DD.log
  google-token.json               # only with GOOGLE_TOKEN_STORE=file: the Google grant, 0600
  .lock                           # so two Worklenses never run against one folder
```

`data/` is git-ignored. `rm -rf data` deletes everything Worklens knows about you.

**It has to be a folder on this Mac's own disk.** If `DATA_DIR` is inside iCloud Drive, Dropbox,
Google Drive, OneDrive, `~/Library/CloudStorage`, or on a volume that is not local, Worklens does
not capture into it: a file provider can sync the SQLite write-ahead log out from under an open
database, and the `.lock` that keeps two Worklenses off one history is a kernel lock this Mac
cannot enforce on another one. Reading what is already there still works. `ALLOW_NONLOCAL_DATA_DIR=true`
overrides it, at the cost of the database it protects.

**Two Macs means two Worklenses, each with its own `DATA_DIR`, and the histories do not merge.**
Nothing syncs between them, because nothing here leaves your disk except the calls named under
"What leaves your machine". Each Mac writes its own name — what "About This Mac" calls it — into `app_state`
on first run; if a data directory turns out to have been written by a different Mac, the menu
says which one. That name is on your disk only, and never reaches Gemini.
Moving to a new Mac is a folder copy with both apps quit — docs/user/data.md, "Two Macs".

## How long things are kept

| Thing | Retention |
|---|---|
| Screenshots | until `DATA_DIR/screenshots` passes `SCREENSHOT_DISK_BUDGET_GB`, at which point whole day folders are deleted oldest-first — never today or yesterday. The rows and descriptions stay; the day just loses its pixels. (`Storage/DiskBudget.swift`) |
| Screenshots, if you prefer | deleted the moment a frame has been described, with `DELETE_SCREENSHOTS_AFTER_DESCRIBE=true` — which now takes the window text with them. Settings → Privacy switches it on and off; it is not retroactive, and a frame whose pixels are gone can never be described again |
| The focused window's text | stored in SQLite (`ax_snapshots.text`), and dropped by the same two settings below that drop screenshots. Its hash, the redaction counts and how much of the window was read stay behind, so the app can still tell a changed screen from an unchanged one. (`Describe/DescribeWorker.swift`) |
| Frames the describer flagged sensitive | the image is deleted immediately and `image_path` set to NULL, by default (`DELETE_SENSITIVE_SCREENSHOTS=true`, a switch in Settings → Privacy). The description stays; it is written to describe the *activity* without quoting what was on screen. (`Describe/DescribeWorker.swift`) |
| Screenshots, descriptions, window text and sessions, if you set a number | deleted once they are older than `RETENTION_DAYS` days, today included — a quarter-hourly pass, never touching today or yesterday. It ships as `0`, which keeps everything and is what Worklens did before this setting existed. Settings → Privacy shows what it is set to. (`Privacy/Retention.swift`) |
| Activity blocks, and any timeline files and friction rows an older build wrote | forever, until you delete them: a retention pass leaves the blocks as the surviving record of a day whose screenshots it removed, and never rebuilds them from frames that are gone. Nothing writes timeline files or friction rows since 2026-10-05 (#299). `RETENTION_KEEP_REPORTS=false` removes those days' blocks, timeline files and friction rows too |
| Reports written before 2026-10-05 | forever, until you delete them. Worklens no longer writes reports, and nothing removes the ones it wrote: the `reports` table and `DATA_DIR/reports` stay as they are |
| The spend ledger and your calendar and Granola events | forever, until you delete them. Neither a retention pass nor the date-range delete touches them: money was really spent, and a meeting you attended is not something Worklens watched you do |
| What you shipped on GitHub (`outputs`) | forever, until you delete it. Neither a retention pass nor the date-range delete touches it, for the same reason as a meeting: a PR you merged is not something Worklens watched you do. `worklens shipped forget` deletes it; `GITHUB_SHIPPED=false` deletes it and stops the sync (#314). Memo rows (#317) keep the company's name and the memo file's path (`corpus/companies/<company>/<file>.md`); an empty `MEMO_REPOS` deletes them |
| Your agent sessions' prompt instants and turns (`agent_prompts`, `agent_turns`) | like captures: a retention pass removes those before the cutoff and the date-range delete removes those inside the range, and a later read of the agents' logs skips both, so neither comes back. The per-session rows and PR links stay until `worklens agents forget` or `AGENT_SESSIONS=false` (#321) |
| Your project rules and assignments (the `rules` and `domains` on a project in `taxonomy.json`, and `project_assignments`) | forever, until you remove them with `worklens projects rule remove`. Neither a retention pass nor the date-range delete touches them: they are corrections you wrote, not something Worklens watched you do. An assignment holds a start, an end, a project key and when you made it; a URL prefix rule never keeps a query or a fragment (#324) |
| Log files | 14 days, pruned at launch (`Util/FileLog.swift`) |

Log files never contain a window title, a URL, a summary or an API key above `debug` level.
`LOG_LEVEL=debug` is the only setting that lets user content into them, and `Log.redactForLog`
is what the other levels use to keep the shape without the content.

The configuration warnings the log, the menu, the Settings banner and `worklens config-dump`
print follow the same rule: they name **keys**, never values, because a mistyped key name could
be sitting next to an API key — or be one. The two exceptions are deliberate and are not yours:
a model id (`DESCRIBE_MODEL=gemini-9-flash`, so you can see why its calls are costed at $0) and the
path of the `.env` file the error is in, which is the thing you have to open to fix it.

## How to stop it, and how to delete things

**Pause everything, right now:** press the global hotkey — `⌥⇧P` unless you changed it in
Settings → General → Shortcuts, and the menu names it on a row of its own. It pauses until you
resume. Capture stops before the next tick, and Worklens says so on the menu's notice line, in a banner
where notifications are allowed, and to VoiceOver. The same key resumes.
(`App/GlobalHotkey.swift`)

**Pause for a while:** the menu's "Pause" submenu offers 15 minutes, an hour, until tomorrow, or
until you resume, with a checkmark beside the one in force. Picking another while paused moves
the deadline — a pause can be extended without resuming first.

**The pause outlives the app.** It is written down (`capture_paused_until` in `app_state`), so
quitting Worklens, restarting the Mac, a crash, `make update` or the automatic update that runs
itself in the background all come back *paused*, with the menu saying "Paused until 15:30" or
"Paused until you resume". The automatic updater will not even restart the app while you are
paused. Nothing resumes capture except you. Because a pause can now last across a day, Worklens
posts one reminder every `PAUSE_REMINDER_HOURS` (default 4; `0` turns it off) saying that it is
still paused and recording nothing.

**On battery it records less by itself.** `CAPTURE_ON_BATTERY` ships as `slow`: while the Mac is
on battery — or in Low Power Mode on the charger — the interval between screenshots is multiplied
by five, so an unplugged hour produces a fifth of the frames a plugged-in one does, and the menu
says which it is doing. `describe-later` also holds the vision calls until mains, which means an
unplugged afternoon sends nothing to Google until you plug in; the frames wait on disk and are
described then, not dropped. `normal` turns the whole thing off. (`Capture/PowerPolicy.swift`)

**Never look at this app or site again:** three lists, editable in three places and live from the
next capture on:

- `BLOCKED_BUNDLE_IDS` — exact bundle identifiers, comma-separated in `.env`.
- `BLOCKED_TITLE_PATTERNS` — case-insensitive regexes, tested against the window title *and* the
  URL, semicolon-separated in `.env`.
- `BLOCKED_URL_HOSTS` — hosts, semicolon-separated in `.env`, matched at a dot boundary so
  `nubank.com.br` also covers `app.nubank.com.br`.

Settings → Privacy edits all three in place, as one **Never look at** list with a type on each
row, and **Choose an app…** reads an app's bundle identifier out of the app so you never have to
know one. **Worklens never writes your `.env`.** What you
change is recorded in `~/Library/Application Support/Worklens/blocklists.json` (mode 0600) as the
entries you added and the entries you removed, and the effective list is your `.env` and the
built-in defaults with those changes folded in — which is why you can take
`com.1password.1password` off the list if you want to, and why each row in Settings says whether
it came from Worklens, from your `.env`, or from you. An edit from the app or the menu takes
effect immediately; one from a terminal takes effect when the running app next reloads
(*Reload configuration*, or a restart). (`Config/Blocklists.swift`)

A blocked moment still writes a row — the app name, and the reason (`blocked:bundle`,
`blocked:title`, `blocked:host`) — so your timeline says "1Password, 4 minutes" rather than
going quietly blank. Nothing else about it is stored. (`Privacy/PrivacyPolicy.swift`)

**Delete what just happened:** the menu's *Delete last 10 minutes…* and *Delete last hour…*.
Both count what they are about to remove and ask first.

**Delete a range of days:** Settings → Privacy → *Delete a date range*.

Either way, what goes is: the `captures` rows, their descriptions and their stored window text
(both by cascade), their JPEGs, the timeline blocks over that stretch, the day's regenerated
timeline file, and the agent prompts and turns inside it (#321). What stays is
`llm_calls` — because money really was spent, and a budget that forgets is a broken budget —
`context_events`, because a meeting you attended is not something Worklens watched you do,
`outputs`, the GitHub items you shipped, for the same reason, and
`coverage_events`, which is a timestamp, a transition (started, paused, resumed, stopped) and, for
a pause, whether it was you or a missing Screen Recording grant. Nothing about what was on screen
is in it, and deleting a stretch of time does not make Worklens claim it was watching then.
(`Privacy/DataEraser.swift`)

**Delete what one integration synced:** Settings → Connections → Sources, the ••• menu on the
source's row, *Delete synced data…*. It counts first and asks, then removes that source's `context_events` rows, its files under `data/context/<source>/`
and the timeline blocks built from them, and redraws every day it touched. This is not a
contradiction of the rule above: erasing a *stretch of time* leaves meetings alone because
Worklens did not watch you attend them, and this removes one *source* entirely because you asked
for that source by name. (`Context/IntegrationRemoval.swift`)

**Disconnect an integration without deleting anything:** the same menu's *Disconnect*. It removes
the credential from `settings.json` and forgets the sync status; Google's also revokes the grant at
Google and deletes the stored token. A credential set in a `.env` or in the environment is not
Worklens's to rewrite — it says so and opens the file instead. Your synced history stays until you
delete it. (`Context/IntegrationRemoval.swift`)

**Slack and Gmail are no longer sources (#285).** The builds between #285 and #299 deleted
what they had stored on their first launch, and revoked the Slack token Worklens saved. That
one-time cleanup went with #299 on 2026-10-05, so Worklens no longer contacts Slack at all; an
install that skipped those builds keeps any old Slack or Gmail rows until you erase their days, and
any `SLACK_USER_TOKEN` in `settings.json` is read as a retired key and never used. Worklens cannot
take back the grants at the other end: remove the Worklens app at `api.slack.com/apps`, and, if you
like, the Gmail access at `myaccount.google.com/permissions` (a Google sign-in made before the
removal keeps working for Calendar either way).

**Delete all of it:** quit Worklens and `rm -rf` your `DATA_DIR`. There is no other copy.
If you also connected Google, disconnect it in Settings → Connections first (which deletes the
keychain item under the service `dev.worklens.google`, or `google-token.json` when
`GOOGLE_TOKEN_STORE=file`) and revoke the app at
[myaccount.google.com/permissions](https://myaccount.google.com/permissions).

## The permission prompt that keeps coming back

macOS asks you to re-confirm Screen Recording roughly once a month, and if you miss it, capture
stops **silently** — the API simply returns nothing. Worklens notices within one tick, raises one
line in the menu, retries every five minutes, and tells you when it is capturing again. If you
allowed notifications it also posts one banner per outage, which you can click to open the right
settings pane; without that grant the menu is the whole of it, and nothing is lost but the
banner. The first time, before the grant has ever existed, it says Screen Recording is *not on
yet* rather than accusing you of revoking it. That is why the permission keeps being asked for;
it is macOS protecting you from exactly the thing this app does, and it is working as intended.

Accessibility, if you grant it, has the same catch and no monthly re-confirmation: it is tied to
the code signature too, and it is optional — without it the app captures exactly what it captured
before, on pixels. The menu offers it in one line, and Settings → Capture → Access has
"Don't remind me about Accessibility" for that line, so a decision against it stays decided.

The browser Automation grant is asked for the same way, and only when you ask for it: a capture
tick reads the frontmost tab's URL of a browser you have already allowed and skips every other
one, so no consent dialog ever appears in the middle of your work. A browser nobody has answered
for yet gets an **Ask macOS for <browser>…** button in Settings → Capture → Access instead.

Screen Recording permission is tied to the app's code signature, so a rebuild with an ad-hoc
signature looks like a brand-new app and has to be granted again. docs/contributing/signing.md,
"Keeping Screen Recording permission across rebuilds", explains how to make a self-signed
certificate so that stops happening.

## Reading the data yourself

It is a SQLite file and a folder of screenshots. Nothing is encrypted, obfuscated or
proprietary:

```bash
sqlite3 data/worklens.sqlite 'SELECT captured_at, app_name, describe_status, skip_reason FROM captures ORDER BY captured_at DESC LIMIT 20;'
```

If something here does not match what the code does, the code is the bug. Please open an
issue — or, if showing it would mean sharing screen contents, report it privately instead
(see [SECURITY.md](SECURITY.md)).
