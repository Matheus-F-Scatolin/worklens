# Changelog

All notable changes to Worklens are recorded here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
aims to follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html). The version a build
reports is derived from the newest `v*` tag (#130), so a section heading here and a tag are the
same fact written twice; `worklens version` and Settings → General → Updates (#136, #286) say which build
you are on, with the pull request and commit behind the version. Entries below the first release
are grouped by the milestone that produced them rather than by a release date.

The first step of any release is renaming `## [Unreleased]` below to `## [x.y.z] - YYYY-MM-DD`
and opening a fresh empty one above it.

## [Unreleased]

### Changed
- Settings → General → Updates says whether a new version is available in plain words, with no
  branch or commit, and shows **Update and restart…** only when there is one. The confirmation is
  one line. The reader window opens at 1140 by 750 on a first launch instead of its minimum.

### Security
- A capture is dropped when the focused app, window, tab or page changed at any point while it was
  taken, not only when the two ends differ, so a quick switch through a blocked site is not kept.
- Redaction now catches YAML multi-line values, camelCase credential names (`awsSecretAccessKey`,
  `clientSecret`), quoted values with escaped quotes, and short values after a credential name.
  Plain prose such as "Password: troubleshooting guide" is left alone.
- `worklens capture-once --out` writes its screenshot readable only by you.

## [0.1.0] - 2026-10-12

### Added

- **Open source onboarding: a sample week, a tour of it, and an install you can hand to Claude
  Code (#349–#353).** Until your first screenshot is summarized, the Worklens window opens on
  all of last week and this week up to today, invented, drawn by the real Today and Weeks pages
  under a ribbon that
  says they are invented, says what happens next, and has a **Leave sample week** button. It lives
  in its own database under `sample-week/`, which Claude, the CLI, search, spend, retention,
  deletes and exports never read. Your first real summary fades the window over to your own Today
  and posts "Your day has started." once ever, even when it was written while Worklens was closed.
  The welcome window now opens on **Light**, **Dark** and **System** as three cards with Light
  ringed in terracotta: a new install starts in light, a click switches at once and goes on, and
  an install that never chose keeps following your Mac. Its third page has a small drawing of
  the sample week and one
  button, **Take the tour**, with no Skip: it walks you through Today, its first bar opened up
  with what you were doing in that app, a click on **Weeks** (a terracotta ring pulses round the
  button until you click it, and the tour never changes page for you), a week with at least four
  whole days in the same app colours your own weeks get (Claude Desktop in terracotta, the
  browser, Codex, Slack and the rest), pausing and deleting, asking Claude
  and the menu-bar ring, one card at a time, then brings the window back on Screen Recording.
  Every bar on Today now says what you were doing in that app when you point at it, and on Weeks
  a short meeting keeps its title beside the app block next to it, and a call's minutes no longer
  tint the half hour after it in the call app's colour. Settings → Advanced
  has **Show sample week** and **Take the tour again**, which can be skipped. Setup shows the build as one progress
  line, keeps the whole log in the data folder's `logs/build.log`, and on a failure says what went
  wrong and which troubleshooting section to read; it ends on the welcome window and says what is
  left for you. You can also install Worklens by pasting its link into Claude Code: `CLAUDE.md`
  says what an agent runs, what it never does, and which steps are yours.
- **Ask Claude what you shipped and where your time went, by project (#323).** `span` takes
  `by: "project"` and answers with a timesheet over up to 92 days: every project's screen, meeting
  and agent minutes per day and by the rule that decided them, a row for the time no project
  claimed with its reasons, and the minutes nothing was recorded. `project` narrows it to one row,
  and agent minutes sit beside your own, never added in. The new "What did I ship, and where did
  my time go?" prompt in Claude Desktop's "+" menu pairs it with `shipped`.
- **Tell Worklens which project a repo, a link or a stretch belongs to (#324).**
  `worklens projects rule add` puts a domain, a repo or a URL prefix on a project, and
  `worklens projects assign` claims a stretch of time for one. Your rules outrank every other kind
  of evidence, and an assignment outranks everything, the newest winning. `--dry-run` shows the
  minutes and days that would move before anything is written, `rule list` and `rule remove`
  undo it, and `vocabulary` shows each project's rules to Claude.
- **Ask Claude which project each minute went to (#322).** Every minute of your screen and meeting
  time now lands on one project, or says why it has none (no evidence, not described yet,
  redacted, a meeting with no company, or a conflict). The strongest evidence decides: the company
  you met, then the repo your agent worked in, the document, the screenshot's project key, and
  last the describer's hint. One stray frame between two stretches of a
  project, or a short gap, stays with that project. A one-day `stats` call returns these spans,
  `byProject` counts your meeting minutes in each project's share on a day, a week and a range,
  and the timeline names the same project for each block. `worklens projects coverage` shows how
  much of a day found a project, and by which rule.
- **Ask Claude what your agents did (#321).** Worklens now reads the session logs Claude Code
  (in the terminal and in the Claude app's Code tab) and Codex keep on this Mac: when each session
  ran, its folder, branch and the PRs it linked, and the moments you typed a prompt. Never a
  prompt's text, a command, a tool's output or a session title, and nothing is sent anywhere. Ask
  Claude "what did my agents work on this week?" and the new `agent_sessions(from, to, repo?)` tool
  answers per repo and per session with your prompts, your minutes and the agents' minutes, side by
  side and never added together. `shipped` lists the sessions under each PR they linked, and
  `worklens agents` (with `agents sync` and `agents forget`) reads the same rows in a terminal.
  `AGENT_SESSIONS=false` turns it off and deletes what was read.
- **Company memos count as shipped (#317).** Set `MEMO_REPOS` to the repos where you keep company
  memos (`owner/name`, comma-separated) and a merged PR of yours that adds or changes
  `corpus/companies/<company>/<memo>.md` becomes a row in the shipped ledger, under that company:
  "You published the memo for …" or "You updated the memo for …". A company the catalog does not
  know yet is added to it. Only each PR's file list is read, never the memo's text; an empty
  `MEMO_REPOS` (the default) reads nothing and deletes the memo rows.
- **Meetings count toward the company you met (#318).** A meeting now names the company it counts
  toward, from its attendees' email domains or a project its title names, and `context_events`
  says which company and which rule, with a `company` filter (a key, a name, a domain, or `none`).
  In `stats`
  and `span`, a project row's `meetingMinutes` are kept apart from its screen minutes. `worklens
  projects learn` suggests the companies your meetings name, `projects merge company:<domain>
  <key>` folds a domain into a project you already have, and `projects forget company:<domain>`
  stops a domain counting toward anything. A Granola note and a calendar event are now treated as
  one meeting only when the note is linked to that event.
- **Ask Claude which documents took your time (#319).** `stats` and `span` add `byDocument`: the
  minutes per Google file, GitHub PR or issue, or local file you had open, with your home folder
  shown as `~`. `shipped` adds, for each PR or issue, the minutes its page was on your screen over
  the 30 days up to that day.
- **Ask Claude where every minute of a day went (#320).** `stats` and `span` add `accounting`: each
  minute of the day in one bucket (meeting, away, screen, battery-sparse screen, asleep, locked,
  idle, paused, permission missing, not running, or unexplained), once over the whole day and once
  over the window from your first to your last recorded moment. A one-day `stats` call also lists
  the day's spans, so "why is this afternoon empty?" has an answer.
- **Ask Claude what you shipped (#314).** Worklens now keeps a ledger of what came out of the day
  on GitHub: the PRs you merged or closed, the issues you opened or closed and the reviews you
  left on other people's PRs, PRs an agent wrote under your account included. It asks the GitHub
  CLI (`gh`) on every context sync, so `gh` must be installed and logged in; `GITHUB_SHIPPED=false`
  turns it off. Ask Claude "what did I ship this week?" and the new `shipped(from, to, project?)`
  tool answers with a count per kind and each item's time, repo#number, title and link, over up to
  31 days. The timeline gains a `## Shipped` section before `## Context`, and `worklens shipped`
  (with `shipped sync` and `shipped forget`) reads the same ledger in a terminal.
- **Ask Claude what came out of a meeting (#316).** Granola meetings now keep their next steps and
  decisions, read from the full summary when the meeting syncs, so Claude sees them even when the
  body is cut. `context_events` lists them under each meeting and says how many name you; pass
  `outcomes_only` for just the meetings that have some ("what did I promise to do this week?").
  The timeline's Context section nests up to five of them under each meeting. Transcripts are
  still never read.
- **Projects have a kind, and screenshots name them by key (#315).** `worklens projects kind <key>
  house|company|side|none` marks the one house project, the companies and your side projects.
  The describer now picks a project from that list by its key instead of guessing a name, so a
  company's time stops landing under the house. `vocabulary` tells Claude each project's kind, a
  project filter in `search` matches its aliases and merged keys too, and `worklens projects check
  [--dry-run]` re-asks a sample of recent house screenshots, as text only, and says where the
  answers went and what it cost.
- **Choose light or dark.** Settings → General → Appearance has a Theme control: System follows
  your Mac, Light and Dark keep Worklens that way whatever the Mac does. It applies at once, to
  every window, and is remembered across launches.

### Changed

- **Auto-update is off by default.** `AUTO_UPDATE_ENABLED` now defaults to `false`, so a new
  commit on `main` rebuilds your app only when you ask: **Check now** and **Update and restart…**
  in Settings → General → Updates work as before, and setting it to `true` brings the poll back.
  The README's first-run steps now follow the welcome window, and SECURITY.md no longer mentions
  Anthropic or reports.

- **A Granola note with no calendar link no longer counts its meeting twice (#340).** A note
  that names no calendar event is now one meeting with an event it covers for more than half of
  the shorter one, unless another note names that event; if that other note also covers it, the
  unlinked note is the second copy and is dropped. A note with no company of its own takes the
  company of the event it was merged with.
- **A URL's query is cut from the window outline too (#332).** The outline text, which feeds the
  describer and search, now drops a web address's `?query` the way the stored address already did,
  including the addresses a browser's address bar shows without `https://`. Outlines already
  stored, and their search rows, are rewritten on the first launch of this build.
- **The timeline no longer says Worklens was not running while it was capturing (#313).** A second
  copy of the app quitting at launch could write a "stopped" row that ended the running copy's
  coverage until its next restart; from 28 September to 5 October that hid a week of captures.
  A copy that never started now writes nothing, and a screenshot taken inside a "not running"
  span ends it, so past days read right as soon as you update. Sleep is recorded as asleep, not locked.
- **Codex, cmux and Worklens get their own app labels on existing installs (#312).** Codex desktop
  time was filed under ChatGPT, and cmux and Worklens under borrowed labels, because new seed apps
  only reached fresh installs. An update now adds the apps Worklens ships to your `taxonomy.json`
  without touching your edits, and relabels the past screenshots of those apps once.
- **A page's address in the window outline is stored without its query or fragment (#311).** The
  tab address the outline kept now follows the rule the browser URL always had: no `?query` or
  `#fragment`, and no web address at all while `COLLECT_BROWSER_URL=false`. Addresses already
  stored are stripped on the first launch of this build.

- **The Today waterfall runs biggest bar first.** Apps, Others and Meetings are sorted by minutes,
  so a day of calls can open on its Meetings bar; Total still closes the chart.
- **No em dashes anywhere in the app.** Every label, notice, CLI line, prompt and translation uses
  a colon, a comma or parentheses instead, and an empty value says `none`, `n/a`, `0m` or `not
  yet`. The report and describe prompts forbid the em dash (daily `r9`, weekly `w6`), and what a
  model still writes is swapped on its way to disk and again in the reader, so older reports read
  the same.
- **The Weeks tab title is just the dates**: `21–27 September`, not `Week 39 · 21–27 September`.
- **Settings moved into the app.** The separate Settings window is gone: the gear at the foot of
  the reader's rail (or ⌘, from anywhere, the menu's "Settings…", `worklens settings --tab
  <section>`) opens six sections — General, Capture, Privacy, Reports, Connections, Usage — and
  Advanced, beside the rail. Esc goes back to where you were. Every change saves as you make it,
  with a "Saved" note at the foot. General's status line says what needs you and lights a dot on
  the gear; Capture carries the Access card that was Permissions; Privacy has one "Never look at"
  list for apps, sites and window titles; "Keep history for", the log level and "Screenshot even
  when nothing changes" can be changed in the app now; Usage draws the last 30 days as a chart.
  Configuration key names appear only in Advanced's "Every value and where it comes from".
- **A new app icon.** The Dock, the Finder and notifications now show the recording mark, a
  terracotta ring and dot on an ivory tile, so the icon matches the redesigned window and the
  mark at the top of its rail. The GitHub social card uses the same colours.
- **The reader, redesigned in the Claude-desktop style.** An icon rail replaces the text sidebar:
  Today, Days, Weeks, Timeline, Stats, Friction and Search, each named on hover, with a small dot
  on Friction when the day has notes. **Today** is the date, one line of facts — active time,
  longest focus block, context switches — and a waterfall of where the time went: your top three
  apps, Others, then the total, with the apps inside Others and each app's share of the day on
  hover. **Weeks** is a 08:00–20:00 calendar of the week, each half hour coloured by the app that
  filled most of it and your meetings drawn on top; click a day to open it, or switch to the
  weekly report. The daily report and the day list are on **Days**, the budget line is at the top
  of **Stats**, and the toolbar says whether Worklens is recording, with Stop and Resume beside it.
  Ivory and warm dark themes follow your Mac's appearance.
- **A welcome in four pages, and Claude is genuinely optional (#232).** A new install now meets
  what Worklens does, Screen Recording, your keys and a last page that hands you over — four
  pages in a fixed window, one primary button each, no settings forms. The Gemini key is the one
  Worklens asks for: paste it, verify it, continue. Claude is a toggle you can leave off, and the
  sentence under it says what that costs — "Without it, Worklens writes no reports and finds no
  frictions. You can still read and search your days here and in Claude Desktop." Leave it off
  and setup is *complete*: the menu counts three steps, never four, and stops asking about a
  decision you have made. The last page offers the one-click Claude Desktop connection — the way
  to read your days without a Claude key — and **Open Worklens**, and says in one line that
  Accessibility and browser access are optional and live in Settings → Permissions. Notifications
  are no longer asked for before you have seen a single day. **Done** is what starts capture.

- **The reader is the home window (#233).** "Open Worklens ⌘O" opens the one place your work is
  shown, and it now opens on **Today**: a card above your days with the time you have been on
  screen, the screenshots taken, what the day has cost against your budget and the last report
  written. Click it to open today's timeline, or click the last report to read it. The days under
  it answer the pointer, the tabs (Report · Timeline · Stats · Friction) moved into the toolbar
  beside "write today's report" and the search field, and a report is drawn at a document's
  measure instead of the full width of the pane. A day Worklens recorded but has nothing written
  about says why in one sentence — "Reports are off — add a Claude key in Settings." — instead of
  offering a button that could do nothing. The window still makes no model call of its own unless
  you ask it to write a report. Recent screenshots stay their own window (#217).
- **The menu bar is a menu again, and a short one (#231).** The popover is gone; clicking the
  icon opens a native macOS menu — keyboard-navigable, VoiceOver-native, and dismissed like every
  other menu. It says what Worklens is doing, one line of today (time on screen, time in
  meetings, today's spend), and at most one row asking to be fixed, then Pause ▸, Capture now,
  Open Worklens ⌘O, today's report, Delete ▸, Settings… ⌘,, Help ▸ and Quit ⌘Q. A configuration
  or data-folder fault becomes a submenu carrying the same remedies Settings offers. Everything
  the popover also drew is where it belongs: the day's card and the recent days in the reader,
  the screenshot counts and the notices in Settings → Activity, the Recent screenshots window
  behind Settings → Privacy, blocklists in Settings → Privacy too.
- **A new app icon, and menu-bar glyphs drawn for 18 pt (#238).** The icon is one container
  now — a macOS 26 squircle with the dusk gradient and light along its top edge — instead of a
  rounded tile drawn inside the rounded canvas and ringed with a white hairline. In the menu
  bar the mark is padded in from the 18 pt square, so it sits with the system's own items
  rather than filling the bar's height, and `.slash` no longer runs wider than the canvas it is
  drawn on. "Over budget — capturing, not describing" is now a visibly open lens instead of a
  slightly thinner dot: at a glance it was reading as healthy capture, which is the one state
  you need to notice.

### Removed

The core cut (#303). The owner decided on 2026-10-05 that Worklens is a ledger of where the day went, read on
  Today and Weeks and by Claude over MCP; it does not coach. Everything below
follows from that, and nothing is deleted on upgrade: no table is dropped (`reports` and
`friction_items` stay) and no data file is removed.

- **The reader is Today and Weeks (#297).** The Days list, the Timeline and Stats tabs, the
  Friction place, the in-app Search page and ⌘F, Go to date, Export / Share / Print, the sample
  day and the toolbar Recording control are gone. Search and the day's timeline are the MCP
  `search` and `timeline` tools; pause and resume stay in the menu.
- **The daily and weekly reports (#298).** Worklens makes one kind of model call now, Gemini
  describing a frame, so it needs no Anthropic key, and most of the daily bill went with them.
  `worklens report`, the MCP `report` tool, the report notifications, menu row and Weeks segment
  went with them. An old `.env` that sets `ANTHROPIC_API_KEY`, `REPORT_MODEL`, `REPORT_EFFORT`,
  `REPORT_TIME` or `REPORT_WEEKLY_DAY` loads with a warning naming them; `REPORT_LANGUAGE` now
  only sets the summaries' language. Settings → Reports is Settings → Log.
- **The friction ledger, the timeline files and the Recent screenshots window (#299).** Worklens
  no longer looks for friction in your timeline, and `worklens friction`, the MCP `friction` tool
  and the "What am I repeating" prompt are gone, so `worklens mcp` offers eight tools and four
  prompts. The day's timeline is no longer written to `data/timeline/<day>.md`; the MCP
  `timeline` tool renders it from the blocks, and `worklens timeline --date <day> --rebuild`
  rebuilds a past day's blocks (`--path` is gone). The Recent screenshots window, the menu-bar tooltip and the menu rows
  that nothing drew any more went too. Nothing is deleted on upgrade: the `friction_items` rows and
  any timeline files an older build wrote stay until you erase that day or a retention pass with
  `RETENTION_KEEP_REPORTS=false` ages it out.
- **The eval harness, the demo and the duplicate CLI commands (#300).** A command that repeated a
  Settings page or a menu item went (`stats`, `costs`, `block`, `taxonomy`, `google`, `context`,
  `schedule`, `run --headless`, `demo`, `seed-fixtures` and the one-stage probes), so
  `worklens --help` lists what a script still drives. Exit code 2 is no longer used. An old
  `DATA_DIR/evals` folder stays until you remove it.
- **The distribution-era support kit (#301).** `doctor`, `diagnostics`, `db-stats`, `export`,
  `data move` and `uninstall`, the About window, Help → Report a problem and Settings → Advanced →
  Diagnostics existed for strangers installing a release. **Verify** on Settings → Connections
  and `make doctor-toolchain` stay.
- **History docs, review notes, icon drafts and one-off scripts (#302).** `docs/history/`,
  `docs/reviews/`, the icon drafts and scripts nothing ran any more are gone from the tree; they
  are still in the repository's history.
- **The Slack and Gmail sources (#285).** Granola and Google Calendar stay; Slack and Gmail as
  apps you use are recorded exactly as before. The first launch of this build deletes the Slack
  messages and sent-mail headers they had stored, the timeline lines built from them and Slack's
  cached identity, and revokes and removes the Slack token Worklens saved. Existing Google
  sign-ins keep working for Calendar with no reconnect; new ones ask for `calendar.readonly`
  alone. A `.env` that still sets `SLACK_USER_TOKEN` loads with a warning instead of an error (and,
  until #300 removed it, `worklens context forget slack` said what happened). Two things are yours to do: remove the
  Worklens app at api.slack.com/apps, and, if you like, the Gmail access at
  myaccount.google.com/permissions.

### Fixed

- **Your data folder and API keys are readable by your account only.** The data folder and every
  folder in it (screenshots, transcripts, logs) are now 0700, and the database with its `-wal`
  and `-shm`, each screenshot, each transcript and the log files are 0600, so another account on
  the Mac cannot read them even when `DATA_DIR` or a checkout sits somewhere it can reach, such
  as `/Users/Shared`. Files an earlier build left readable are made private when the app starts.
  `setup.sh` creates a checkout's `.env` as 0600 and makes an existing one 0600, and
  `install-env.sh` does the same to the `.env` it reads from.
- **A huge number no longer stops the MCP server.** A tool call such as `days` with
  `{"limit":1e100}` used to end `worklens mcp`; it now answers "limit must be a whole number"
  like any other bad argument, and the server keeps running.
- **A screenshot is of the approved window and nothing else.** Worklens photographed the whole
  display once the window in front had passed the blocklists, so a blocked app open beside it (a
  password manager, a bank) was in the picture and went to Gemini. It now photographs only the
  focused window of the app it just approved, on whichever display that window is; with no such
  window it takes no picture and keeps the window text if there is any. After the picture comes
  back it checks that the same window of the same app is still in front and still allowed, and
  drops the picture and its text when you switched away or the tab moved to a blocked site.
- **The site blocklist no longer lets a page through when it cannot see the address.** With
  `BLOCKED_URL_HOSTS` set, a browser whose address could not be read (URL collection off, no
  Automation permission, Firefox) was simply allowed. The address is now read for the check even
  while `COLLECT_BROWSER_URL=false`, without being stored, and a browser whose address still cannot
  be read is treated as blocked (`blocked:host_unknown`); *Capture now* says why.

- **A credential in a window title is no longer stored, searchable or returned to an assistant.**
  The title, the address and the context signature are now redacted before the row is written and
  indexed, not only on the way into the describe prompt, so `search` over MCP returns
  `password=[PASSWORD]` rather than the password. The database is repaired once when it is next
  opened: stored titles, addresses, block headings and window outlines, and their search entries,
  go through the redactor, and `search` redacts what it returns as well.
- **More credential shapes are redacted.** JSON and YAML pairs (`"password":"…"`,
  `password: …`), prefixed keys (`DB_PASSWORD=`), the value of a key that names a credential
  (`api_key`, `client_secret`, `aws_secret_access_key`, `GITHUB_TOKEN`, `"private_key":` and the
  like, eight characters or more) and the `user:password@` part of an address, in text and in the
  stored browser URL. Prose such as `Token: expired` is left as it was.
- **Meeting titles, bodies and outcomes are redacted before they leave the app.** A calendar or
  Granola title goes through the redactor before it enters the describe prompt, and
  `context_events`, the timeline and meeting blocks redact the title, the body and the next steps
  and decisions before cutting or returning them.
- **A fresh one-line install keeps its data in Application Support, not in the git checkout.**
  `setup.sh --yes` no longer copies `.env.example` into the clone, and `scripts/launch.sh` never
  points an installed app at a checkout's `.env`, so the first launch writes the app's own
  configuration, no "Dev override" line appears, and Settings changes are not hidden behind the
  clone's defaults. Setup now ends by saying how to put `~/.local/bin` on your `PATH` when the
  `worklens` command landed there.

- **An update no longer cuts Claude off from Worklens.** The update and `make install` quit the
  app by matching its binary's path, which also matched `Worklens mcp`, the server Claude
  Desktop, Claude Code and Codex start from the same binary. Claude Desktop kept the tool list and
  answered every Worklens call with a bare "Tool execution failed" until it was restarted. Only
  the menu bar is quit now; a running server carries on, and picks up the new build the next time
  its client starts it.
- **"An assistant on this Mac can no longer reach Worklens" no longer comes back after
  Reconnect.** Claude Desktop writes its settings file back while it is open, so a Reconnect made
  then was undone within minutes. Connect and Reconnect now ask you to quit Claude Desktop first
  and write nothing while it is open, in Settings and in `worklens mcp install` alike. The notice
  is also kept for a link that is actually gone: an entry that still launches another copy of
  Worklens, such as the checkout's `build/Worklens.app` beside the installed one, shows on its
  Settings row and raises nothing.
- **The server says what it did with each request.** `worklens mcp` writes one line per request
  to stderr, which Claude Desktop keeps as `~/Library/Logs/Claude/mcp-server-worklens.log`: the
  method, the tool's name, how it ended and how long it took. Never the arguments or the answer.

### Added

- **Rows answer the pointer, and there is one type scale instead of four (#237).** Move the
  pointer over a blocklist entry, a project or one of its spellings and the row fills; press it and
  the fill deepens; reach it with the keyboard and it draws a focus ring — a row that is both
  hovered and focused shows both. Nothing in the app reacted to the pointer before this. Settings
  also draws its headings, row text and captions from five named type roles that follow your text
  size rather than from hand-set point sizes, and it honours Reduce Motion (every transition is
  instant) and Reduce Transparency (the fills become opaque).

- **Recent screenshots, with a Delete button on every row (#217).** The menu and Settings →
  Privacy open a window listing every screenshot Worklens wrote, newest first: the minute, the
  app, what became of it — summarized, blocked, waiting, flagged sensitive — and the sentence the
  model wrote. Deleting a row removes that screenshot, its image file and its summary, and
  rewrites the day's timeline without it. Under the list, a legend for any `[CARD_1]`-style
  placeholder the rows contain, and where today's time went, app by app.

- **The history can age out (#144).** `RETENTION_DAYS` deletes the screenshots, their summaries,
  the stored window text and the app-by-app sessions older than that many days, today included.
  It ships as `0` — keep everything, which is what Worklens did before — and any number you set
  is enforced by the quarter-hourly housekeeping pass, which never touches today or yesterday.
  Your timelines and reports survive it: they are what the screenshots were taken for, and a pass
  never rebuilds a day's markdown from frames it just deleted. `RETENTION_KEEP_REPORTS=false`
  removes those days' timelines, daily reports, blocks and friction items too. Settings → Privacy
  shows the number in force. README and [`docs/user/data.md`](docs/user/data.md) now also answer
  "how big does this get": about 12 MB of screenshots and 1.5 MB of database a day, measured over
  eleven days on one Mac.

- **Reports in your own language (#157).** `REPORT_LANGUAGE` — a code such as `pt-BR` or `de` —
  asks the model to write the daily report, the weekly report and every screenshot summary in
  that language, while keys, slugs and app names stay in English so the timeline and the stats
  still line up. It defaults to `en`, and at that default nothing is added to any prompt: your
  reports read exactly as they did. Settings → Reports → Which model sets it.

- **One voice, written down (#157).** [`docs/copy.md`](docs/copy.md) is the style guide the app
  now follows: a *screenshot* is never a "frame", a summary is never a "description", waiting is
  never "pending", and *Delete* is the only word for deleting — the popover's own section used to
  be called "Erase". Settings paragraphs are one sentence with a `Learn more…` link into
  `docs/user/`, rather than four sentences about code signatures and TCC. Nothing machine-readable
  changed: no column value, enum, configuration key or `--json` key was renamed.

- **Numbers, money and clocks read the way your Mac writes them (#157).** One helper, `Format`,
  now owns every number a person reads, and the menu, the Today card, Settings and the About
  window pass it your own locale: a Mac set to Portuguese (Brazil) shows `US$ 0,27 de US$ 1,50`
  and a Mac set to 12-hour time shows `2:05 PM` where the app used to print a hard-coded
  `HH:mm` everywhere. Reports, the stats markdown, the cost CSV, the ledger log and the CLI's
  own output deliberately keep their fixed format — those are files and pipes, not sentences.

- **One command removes Worklens (#155).** `worklens uninstall` — and `make uninstall` — undoes
  what installing it did: the login item, the Google grant, the `worklens` entry in Claude
  Desktop's configuration, your `DATA_DIR`, the `~/Library/Application Support/Worklens` `.env`
  holding both API keys, the app bundles, the `worklens` symlink and the self-signed "Worklens
  Dev" certificate. It prints the whole list first — with the file count and size of your data —
  and asks; `--dry-run` prints and stops, and so does a run with no terminal to ask in. What
  macOS and Google reserve for you (the Privacy & Security panes, the account permissions page,
  Keychain Access) it prints rather than pretending to do.
  `docs/user/uninstall.md` was the page, until #301.

- **A Help menu, an About window, and the privacy document inside the app (#153).** The menu's
  trailing group now carries **Help**: Getting started, Privacy, Troubleshooting, **Report a
  problem…**, **Open log folder** and **About Worklens**. `scripts/bundle.sh` copies `PRIVACY.md`,
  `README.md` and `docs/user/` into the bundle, so every one of those documents opens from inside
  the app itself — with no checkout and no network — instead of a GitHub URL on a repository that
  is private. "Report a problem…" opens the bug form with the build, the macOS version and how
  this copy is signed already filled in, and nothing else: no log lines, no window titles, no
  paths. About Worklens says which build is running and how it is signed. Every Settings pane
  gained a **Learn more** link into the page that explains it, and Settings → General → Updates
  gained **Check now**, which asks what `main` points at and says so without installing anything.

- **Worklens tells you when a run ended badly, and hands you a bundle to attach (#156).** The app
  writes a clean-exit marker when it shuts down and clears it at launch, so a crash, a `kill -9`
  or a machine that lost power is no longer indistinguishable from a clean quit: the next launch
  says so once, in one sentence, with an **Open the log…** button. A planned restart is not a
  crash — `scripts/update.sh` records one with the new `worklens expect-restart` before it stops
  the app, so the unattended auto-update path stays quiet. `worklens diagnostics --out <path>`,
  and Settings → General → **Save diagnostics…**, write one zip you can attach to a bug report:
  the version, the machine checks, the masked configuration, the database row counts, the app's
  own permission grants and the last week of redacted logs, with a MANIFEST listing everything in
  it and everything left out. No screenshot, description, window title, browser URL, context event
  body or accessibility snapshot is reachable from it, `DEBUG` log lines are dropped unless you
  pass `--include-debug`, and every file is scanned for secrets again before the zip closes.

- **The report notification opens the report (#149).** Clicking the one banner Worklens posts a
  day used to do nothing at all, and its body told you to go and find the menu yourself. The
  report category is registered with an **Open report** action, the banner carries the kind and
  the period it was posted for, and either the click or the button opens the reader on that
  report — the one it was about, not whatever is newest. Three banners that were missing are
  here too: a scheduled report that failed, with the reason and the next attempt; the daily
  budget being reached, once a day; and a timed pause running out. The database-recovery banner
  gains **Show in Finder**. Every title and body now comes from one `NotificationCopy` helper in
  `WorklensCore`, so the ISO date and the raw price are gone from the report banner, the commit
  SHA is gone from the updater's, the hotkey answers with two sentences instead of three, and a
  date reads as *Wednesday, September 9*. With notifications denied or unavailable, the same
  sentence is raised on the menu instead of being lost.

- **The menu says what was just captured, and how often the safety nets fired (#151).** Two lines
  above the status row now name the newest frame — *"Last frame: Safari · 2 min ago · described"* —
  with the summary the model wrote under it. The ending is spelled out rather than implied: a
  window a blocklist matched reads *"blocked — only the minute was kept"*, a frame the model
  flagged reads *"flagged sensitive"*, and a queued, failed or over-budget one says so too. The
  counts line gained the three privacy numbers it was missing, each printed only on a day it
  happened: frames blocked, frames flagged sensitive, and credentials replaced in a window title
  or a URL before anything was sent. Until now all three lived in a timeline footnote and a debug
  log. Settings → Privacy says who decides what "sensitive" means, quoting the same category list
  the describe prompt is built from, so the pane and the instruction cannot drift apart.

- **Worklens says what it is doing while it does it, and says when it is done (#150).** A report,
  an integration sync, a configuration reload and an erase each put a row on the menu while they
  run — *"Writing today's report · 42 s · usually about 40 s"*, with the expected time drawn from
  the last three calls of that kind and left off entirely when there have been fewer than three.
  The menu-bar glyph goes busy beside them, including for the 07:00 report nobody pressed a button
  for, which until now was completely invisible. A report can be cancelled from its row; cancelling
  stops the waiting and says so honestly, since what the model already generated is still on the
  bill. Two more things now confirm themselves: a reload reports the cadence it came back with, and
  a sync that half worked shows the warnings it used to drop. *"Update and restart…"* makes the
  icon vanish for a minute or two, so Worklens now remembers which build quit and says
  *"Worklens is back — now on 9f3c1aa"* on the next launch — and says nothing when the update
  failed and the same build came back. An unattended auto-update also stands down while any of
  this is running, rather than only while a report is.

- **The menu says which day a report covers, when the next one arrives, and why one was skipped
  (#148).** The two report items name their period instead of always saying *"today"*: *Write
  yesterday's report (≈ $0.06)* when that is the one you are missing, *Write today's report so
  far* for the preview, *Rewrite today's report…* when today already has one — so a second click
  rewrites the report instead of handing back the first one with its old price. The weekly item
  targets the week that ended rather than the unfinished one, and says what it is short of
  (*"Write last week's report (2 of 3 daily reports)"*) instead of failing with a raw error.
  *Open latest report* now reads *Open yesterday's report · written 07:02*, one new line says
  *Next: tomorrow 07:00 · today's report*, and the disabled daily item counts the screenshots it
  is waiting for. A scheduled report skipped for want of data now reaches you as a notice, and
  one notification, once ever, explains when your first report arrives. The daily prompt is `r7`:
  a report written while the day is still running is told so, instead of being told it is
  "writing on the morning after" and calling today "yesterday".
- **Worklens says when it was not watching (#146).** A pause, a quit and a revoked Screen
  Recording grant used to look exactly like an afternoon away from the machine: no rows either
  way. Every transition is now a row in a new content-free `coverage_events` table, and the day
  reads it back. The menu's counts line gains *"1 h 20 m not watched"* when the gap is worth a
  word; the day's timeline ends with *"Worklens was not running until 09:12, paused 14:00–15:20"*;
  and both reports are told where the day's gaps are, so a stretch with no record is never
  written up as a quiet afternoon (daily prompt `r6`, weekly `w4`).
- **The reader answers "how did that go" and "when did I last see that" (#138).** The Stats tab is
  no longer a wall of pipe tables: five tiles (active, meetings, idle, longest focus, switches per
  active hour), horizontal bars by app, project and category, a threads table, a 24-cell hour
  strip, and — on a week — a day-by-project grid plus the change against *your own* previous week.
  A new **Friction** tab shows the fortnight's ledger the daily reports have been writing all
  along, marks anything seen on three days or more, and turns each cited clock time into a jump
  into that day's timeline. And the reader's toolbar gained a search field (⌘F in the window,
  **Search your days…** in the menu): it queries the text Worklens already recorded, groups hits by
  day with the typed phrase in bold and a thumbnail where the screenshot survived retention, and
  clicking one opens that moment in the timeline. Nothing here calls a model, costs anything or
  leaves the machine, and the query is never logged.

- **Worklens eases off on battery, and says what it costs the Mac (#145).** `CAPTURE_ON_BATTERY`
  (`normal|slow|describe-later`, shipped as `slow`) stretches the capture interval five-fold while
  the Mac is on battery — or in Low Power Mode on the charger, because that is you asking for less
  of everything — and `describe-later` also holds the vision calls until mains, leaving frames
  `pending` rather than dropping any. The menu says so in the row that used to read "Capturing ·
  every 60 s": *"On battery · capturing every 5 min"*, so a slower cadence is never mistaken for a
  fault. Settings → Models & cost gained a **Footprint today** row — database size, the screenshot
  budget line, and a MB-a-day figure averaged over the last seven whole days rather than a
  constant. And the overhead claim in `docs/PLAN.md`, which had never been checked, is now a
  measurement with a method: [docs/footprint.md](docs/footprint.md).
- **Three ways back into the window when the menu-bar icon cannot be found (#147).** A full menu
  bar, a notch or Bartender can leave a menu-bar-only app with no door left, so there are three
  now. Re-opening Worklens — from Spotlight, the Dock or `open -a Worklens` — opens Settings on
  the pane you were last on instead of doing nothing. **Settings → General → Show Worklens in
  the Dock** adds a Dock icon that opens that window and puts Worklens in ⌘-Tab; it is off by
  default and remembered across launches. And `worklens settings` (with `--tab general`,
  `permissions`, and the rest) asks the copy that is already running to show Settings — it never
  starts a second one. `docs/user/troubleshooting.md` lists all three under "I cannot find the
  menu-bar icon".

- **A Google connect flow you can finish without a terminal (#139).** The browser window is five
  minutes rather than one — long enough for a first consent, which includes Google's "unverified
  app" screen — and while the listener is alive there is a **Cancel** and an **Open the consent
  page again** beside it. The Calendar and Gmail setup sheet now carries the whole thing: five
  numbered steps, each linking straight to the console page it names, a shape check on the client
  id (`.apps.googleusercontent.com`) and the secret (`GOCSPX-`), a plain statement that the
  sign-in expires every 7 days while the consent screen stays in Testing, and **Connect** in the
  same sheet. When Google does expire the grant, Calendar and Gmail read **Paused until you
  reconnect**, the menu keeps one line about it until it is fixed, one notification goes out per
  expiry, and **Reconnect** is one click. Where the grant is kept is now a question you are asked
  as you connect — *Data folder* (`DATA_DIR/google-token.json`, 0600, no password dialogs) or
  *Login Keychain* — pre-selected to the store an existing sign-in is already in, and otherwise to
  the data folder when the running binary carries no Apple Developer Team ID, which is every build
  of Worklens today; changing your mind later disconnects and reconnects in one click. The page the browser lands on is themed, named and dark-mode
  aware instead of one unstyled line, and a finished connect brings Worklens back to the front on
  Settings → Integrations. No surface a menu-bar user reads says `worklens google connect` any
  more.

- **A troubleshooting page you can be sent to, and `HelpLink` to send you there (#142).**
  `docs/user/troubleshooting.md` now opens with a symptom → cause → fix table and answers six
  more symptoms whose fixes were only ever prose somewhere else: the red menu icon, today's
  counts "resetting" after a `make run` (a second `DATA_DIR` won), a timeline that names the
  browser but never the page, a permission macOS asks for again after a rebuild, a missing
  **Update and restart…** item, and an update that failed. `HelpLink` in `WorklensCore` names
  each of those anchors once, resolving to the Markdown file in the checkout when the build came
  from one and to GitHub otherwise; the menu's **Troubleshooting…** item opens the page and
  `worklens capture-once`'s exit-3 message prints one of its anchors. `docs/user/` also gains an index, a configuration page, one page per integration with
  what each stores and sends, and the six setup steps that only you can do.

- **A welcome window, and nothing is captured before it is finished (#131).** A first launch used
  to raise an unexplained notifications dialog and start recording, with the explanation of what
  is recorded living in `PRIVACY.md` where only a curious person found it. Now a new install
  opens a five-page window instead: what is recorded, what never is and what leaves your Mac —
  the same sentences as `PRIVACY.md` — then Screen Recording, then your two API keys with the
  same fields and **Verify** button Settings has, then the optional permissions (Notifications,
  Accessibility and one row per browser), each of which can be skipped. Capture starts when you
  press **Start capturing** on the last page, and not before. The notifications dialog is on the
  optional page rather than being the app's first act.
- **The menu says how far setup got (#131).** While the welcome is unfinished the menu carries
  `Finish setting up Worklens (2 of 4)`, which re-opens the window from its first page, and the
  offers about Accessibility and browser tab URLs are held back until setup is done or a day has
  passed — a first launch is not the moment for three optional-permission lines. Settings →
  General → **Show welcome again** re-opens the window at any time.
- **An install that was already running is left alone (#131).** Anything that has captured a
  frame, or that has ever been told whether to start capturing on launch, is recorded as set up
  without being shown anything and keeps capturing exactly as before.
- **A reader window (#134).** `Reports & days…` (⌘R) in the menu opens a window with your days
  down the left, grouped under the week they belong to, and what Worklens wrote about them on the
  right: Report, Timeline and Stats, all rendered in place. Reports used to be handed to whatever
  owns `.md`, so the first one you ever got opened in TextEdit complete with its `---` block and
  its pipe tables; that block is now a header card (when it was written, by which model, what it
  cost) and the tables are tables. A report the model had to cut short says so. ⌘← and ⌘→ step
  through the days, and the weekly report is the week header's own row.
- **A day with no report says why, and offers one thing (#134).** Every day carries a state —
  written, not yet, writing, not enough recorded, left for the budget, failed, or declined — as a
  card with a single button. A failure the 07:00 run hit stays on the day it belongs to until it
  is fixed, rather than on a menu line nobody was awake for. Writing a report happens in the
  reader: the card becomes a writing card with the model and an elapsed time, and is replaced by
  the report itself. Nothing opens another app and nothing steals focus.
- **An example day before your first report (#134).** With nothing recorded yet, the reader says
  when your first report is written and offers to show you what one looks like. It is an invented
  day compiled into the app, marked "Sample data — not yours" on every tab, and it is never
  written to your database.
- **Settings → Integrations sets an integration up** (#135). One card per source — Granola,
  Slack, Calendar, Gmail — each carrying a state, the sentence saying what it puts on your
  timeline, and a **What is stored** disclosure naming what is sent and what is kept. **Set up…**
  opens a sheet with numbered steps and the pages they link to, a masked field that checks the
  shape as you type, a **Test** button that asks the provider now (Slack's `auth.test`, one
  Granola note — neither writes anything), and a **Save** that writes the key to Worklens's own
  settings file. Slack's sheet carries a copyable app manifest declaring `search:read` and
  `users:read` with token rotation off, and refuses a bot (`xoxb-`) or rotating (`xoxe.`) token
  on paste instead of letting a sync discover it a quarter of an hour later; Granola's states the
  Business-plan requirement before the field and reads a refusal as its own state rather than a
  red error. The sync interval is a stepper rather than a sentence, and a control whose key comes
  from the environment or `WORKLENS_ENV_FILE` shows itself disabled instead of pretending an edit
  would take.

- `make release VERSION=0.2.0` (#130) — one command from a clean checkout to a published GitHub
  release: tag, `make build`, bundle, sign, a `ditto` zip, a `hdiutil` dmg with an
  `/Applications` drop target, `shasum -a 256` into `SHA256SUMS`, and `gh release create` with
  this version's changelog section as the body. It refuses to tag when `CHANGELOG.md` has no
  section for the version, refuses to publish a bundle whose stamped version is not the one you
  asked for, and prints a loud warning when the signature is self-signed or ad-hoc — because such
  a build is quarantined on any other Mac and reads to macOS as a brand-new app, so Screen
  Recording, Accessibility and Automation have to be granted again after every update.
  `ARGS=--dry-run` builds everything and publishes nothing. `docs/release-checklist.md` is the
  half a script cannot do.
- `LSApplicationCategoryType` (productivity) and `CFBundleDevelopmentRegion` in the bundle's
  `Info.plist`, so Finder and System Settings file the app properly.
- **The blocklists are editable, where and when you need them** (#128). Settings → Privacy now
  edits all three lists in place: a picker that reads an app's bundle identifier out of the app
  itself (with its icon and its real name on every row), a field for sites, and a field for
  window-title patterns that refuses a regex it cannot compile. Every row says where it came
  from — built in, your `.env`, or you — and every row can be removed, including the two apps
  Worklens has always blocked by default. The menu adds **Never capture <app>…** and
  **Never capture <site>…** for whatever was captured last, next to the two Delete items, so the
  reflex that deletes the last ten minutes can also stop the next frame. `worklens block
  --app/--host/--title` (and `--unblock`) does the same from a terminal. Your `.env` is never
  written: what you change lives in `~/Library/Application Support/Worklens/blocklists.json` as
  additions and removals over whatever the files said.
- A wrong API key is no longer a quiet day (#125). The describe queue now reports its own health:
  a provider that refuses the key, spends the quota or cannot be reached puts a line on the menu —
  `Not summarizing — Gemini rejected the key (HTTP 403)` — with a Fix… button, turns the menu-bar
  icon to attention instead of leaving it on healthy green, and posts one notification per stall.
  Today's line counts failed frames when there are any, and Settings → Models & cost mirrors the
  health line next to the time of the last summary. A scheduled report that fails now also posts a
  notification, carrying the reason and the retry time it already composed.
- **Your API keys have a home in Settings** (#124). Settings → Models & cost opens on an
  **Accounts** section with a row for each of the two keys Worklens cannot run without: what it
  is for, whether it is set, and the same masked prefix `config-dump` prints — there is no reveal
  toggle, because this app takes screenshots for a living. **Set…** takes a paste into a secure
  field, trims it, warns (without refusing) when the prefix is not the provider's usual one, and
  saves it to Worklens's own settings file at mode 0600; **Remove** gives the layer below it back;
  **Verify** asks the provider's free models-list endpoint whether it recognises the key and
  answers "OK" or the HTTP status. A verify costs nothing, bills no tokens, and writes one $0 row
  in the cost ledger so a call that carried your key off this Mac is auditable like every other.
  When a key comes from a `.env` file the row says which one, and when it comes from the process
  environment or `WORKLENS_ENV_FILE` — which still outrank Settings — the row says so instead of
  offering an edit that would change nothing. The menu's "Add your API keys to get started" line
  and both missing-key warnings now lead here rather than into a text editor.
- Settings → General now says where your data lives and which configuration file won (#129). A
  **Storage** section shows the full `DATA_DIR` path with a **Show in Finder** button, what the
  screenshots weigh against their budget, and the size of the database. Under **Advanced**, the
  same per-key provenance `worklens config-dump` prints is now a grid — key, value (secrets still
  masked), and the layer that supplied it — over a list of every file that was consulted, each
  marked *winning*, *read* or *missing*, each with its own **Open** button, and an amber line
  naming the keys the App Support `.env` is quietly taking from a checkout's.
- A "Dev override: reading <path>" line in the menu and in Settings whenever `WORKLENS_ENV_FILE`
  pointed this app at a checkout (#129) — two installs that look identical can be reading
  different files, and this is where you find out. It names the path and nothing in it.
- `worklens install-env` (#129) — the Swift command `scripts/install-env.sh` and
  `make install-env` now run. It **merges** rather than copying: keys only the installed file
  sets are kept, keys only this checkout sets are added, and a key the two disagree about is
  printed as a three-column diff (key · this checkout · installed) and left at the installed
  value unless you pass `--force`. A key this checkout leaves blank — `GEMINI_API_KEY=`, which is
  what `.env.example` ships and what a checkout looks like once the real keys live only in
  Application Support — is not a value, so not even `--force` can blank an installed API key.
  `DATA_DIR` is still pinned to an absolute path, `--data-dir`
  and `--no-pin` still work, the file is still written 0600, and it never prompts — an
  unattended `make setup` cannot hang on it.
- `make demo` — the whole pipeline with no API keys (#121). `worklens demo` seeds an invented day
  of undescribed frames, describes them with an offline fake provider, rebuilds the timeline and
  writes the daily report, into a scratch directory it refuses to let be your `DATA_DIR`. Nothing
  is captured, nothing is sent, and it costs $0.00. `describe-pending --fake` and `report --fake`
  run one stage at a time. Every sentence the fake writes says `sample — not a real summary`, the
  writing provider is recorded on the report row and in its front matter, and a fake run will not
  overwrite a report a real model wrote.
- `worklens doctor` (#118) — one command that answers "is this set up?". It checks the `.env`
  layers and which one is quietly winning, retired keys, the data directory and its database,
  both API keys (masked, and with `--online` confirmed against each provider's free models-list
  endpoint — no tokens, no ledger row), whether the models are priced, whether `REPORT_TIME`
  parses at all, the three macOS permissions, this Mac's signing certificate and the bundle's
  own signature, and the `claude_desktop_config.json` MCP entry. One fix line per problem,
  `--json`, and a non-zero exit when anything failed. `make doctor` builds and runs it;
  **Run diagnostics** and **Copy diagnostics** in Settings → General render the same checks, and
  are the only place the permission rows can answer for `Worklens.app` rather than for whatever
  terminal asked.
- `scripts/doctor.sh` (`make doctor-toolchain`), run at the top of `make build`: the Swift
  version against the floor in `Package.swift`, `xcode-select -p`, the SDK-versus-Swift mismatch,
  and the trap that bare `swift test` on a Command Line Tools machine runs nothing and still
  exits 0. It warns; it never fails a build.
- A first launch that works without a terminal (#116): installed from the bundle rather than the
  checkout, Worklens now keeps its data in `~/Library/Application Support/Worklens/data`, writes
  itself a commented `.env` beside it at mode 600 when it finds no configuration anywhere, and
  answers with **Add your API keys to get started** over **Open .env…** instead of the
  "Configuration error" menu a Finder, Spotlight or login-item launch used to get. A checkout is
  unchanged: `./data`, and `make install-env` still pins the data directory here — now with
  `--data-dir <path>` and `--no-pin`, and printing the path it replaces. `worklens config-dump`
  says "no configuration file found; defaults in use" when that is the case.
- An install path (#119): `make setup` takes a clean clone to an installed, running app one
  consented step at a time — toolchain check, `.env`, the signing certificate, build, sign,
  install, and what is left for you to click — and `SETUP_ARGS=--dry-run` prints the whole thing
  without changing anything. `make install` copies the app to `/Applications` and puts a `worklens` command on
  your `PATH`, so Spotlight can find Worklens and MCP clients have a path that exists. Typing
  `worklens` with no arguments at a prompt now prints help instead of starting a second menu-bar
  app, and the development binary says once, on stderr, that its permissions are not the app's.
- Continuous integration (#123): `.github/workflows/ci.yml` builds, tests, bundles, ad-hoc signs
  and verifies the app on every pull request, uploads `build/Worklens.app` so a reviewer can run
  it, and scans the full git history for secrets. New contributor targets to match —
  `make test FILTER=…`, `make evals-test`, `make format`, `make format-check`, `make check` — with
  a committed `.swift-format`, and Dependabot for SwiftPM, Actions and `evals/`.
- `LICENSE` (MIT), `SECURITY.md`, `CONTRIBUTING.md`, `CODE_OF_CONDUCT.md`, issue and pull request
  templates, and this changelog — everything the repository needed before it could be public.
- `WLRepositoryURL` is stamped into the bundle by `scripts/bundle.sh`, so the app's privacy link
  points at the repository it was actually built from.
- A refusal to capture into a cloud-synced or remote `DATA_DIR` (#122). iCloud Drive, Dropbox,
  Google Drive, OneDrive, `~/Library/CloudStorage` and network volumes are all detected: the menu
  names the folder and the risk, the writing CLI subcommands exit 3, and `config-dump` and
  `worklens doctor` both say so. Reading what is already there still works.
  `ALLOW_NONLOCAL_DATA_DIR=true` overrides it, and the doctor still warns that you did.
- The machine's name in `app_state` and in every report's front matter (#122), so two Macs' data
  directories can never be silently mistaken for one history — the menu says so when a folder was
  last written by a different Mac. The name never reaches Gemini or Anthropic: front matter is
  stripped from every report that goes back into a prompt. README and `PRIVACY.md` now answer the
  second-Mac question — one install per Mac, histories do not merge, moving is a folder copy with
  both apps quit.
- A way to *ask* for Screen Recording (#117), in the menu and in Settings → Permissions. Asking
  is what puts Worklens in the System Settings list at all, so the old "open the pane" button
  sent you to a list you were not in yet. Opening the pane is now the fallback for an answer that
  is still no.
- **Relaunch Worklens**, in the menu and in Settings → Permissions (#117): the first Screen
  Recording grant only reaches a copy of Worklens that starts after it.
- An "Ask…" line for a browser whose tab URLs have never been asked about (#117), and an
  **Open System Settings** button on the Notifications row.
- A pause that outlives the process (#113): pausing is written to `app_state`, so quitting, a
  crash, `make update` and the automatic update all come back paused instead of capturing. The
  automatic updater waits while you are paused, and `PAUSE_REMINDER_HOURS` (default 4, `0` off)
  reminds you that nothing is being recorded.

### Changed

- **A Timeline block keeps its colour from one day to the next (#160).** The hue of a block now
  comes from its taxonomy category's name alone, so `dev` is the same colour tomorrow as it is
  today and a colour you have learnt goes on meaning something. It used to be decided per day —
  the categories present were numbered in name order, which guaranteed no two of them ever drew
  alike but meant a single Finder detour repainted the rest of the day. The sixteen categories
  Worklens ships with are spread evenly over the eight-colour palette, two apiece, so two kinds
  of work sharing a colour on one day is rare rather than routine.
- **`worklens run --headless` says it is now `worklens schedule` at most once a day (#158).** The
  note is on stderr and was printed on every start, which meant a launch agent wrote it to its
  log on every login, forever. You still see it the first time you run the old spelling on any
  given day.
- **The menu is grouped, and it has real shortcuts (#136).** The rows sit in sections — a
  read-only header, then **Capture**, **Reports**, **Files**, **Erase** and the app items — rather
  than in one list of eighteen separated by dividers. The three "Pause …" buttons are one
  **Pause** submenu (15 minutes, 1 hour, until tomorrow, until you resume) with a checkmark
  beside the one in force; it stays available *while paused*, so a pause can be extended without
  resuming first, and a pause until midnight now reads "Paused until tomorrow" rather than
  "Paused until 00:00". The daily actions carry key equivalents — ⌘P pause or resume, ⌘N capture
  now, ⌘R the reader, ⌘L the latest report, ⌘T today's timeline, ⌘⌫ delete the last 10 minutes —
  which fire while the menu is open, and a new hint row names the global hotkey, `⌥⇧P`, which
  works with the menu shut.
- **The optional-permission rows are one row you can dismiss (#136).** Accessibility, browser tab
  URLs, the "Ask…" line and the "Grant Accessibility…" button folded into
  `Optional: window text and browser URLs are off — Review…`, whose submenu offers Settings →
  Permissions or "Don't show this again". Dismissing it is remembered until you open Settings →
  Permissions. The Screen Recording line is untouched: that grant stops capture, and it is not an
  optional extra.
- **The build stamp and "Update and restart…" moved to Settings → General → Updates (#136).**
  They are maintenance; which build is running is still the status icon's hover text. The
  "an update is ready" line stays in the menu, and "Sync integrations now" is gone — Settings →
  Integrations has "Sync all now". "Open latest report" no longer says "(none yet)": it still
  works with no report, opening the reports folder and saying so, and the counts row carries the
  fact instead.
- **Pressing `⌥⇧P` says so even with notifications denied (#136).** The menu's notice line and a
  VoiceOver announcement now go with the banner, and "Capture now" leaves a line either way —
  "Captured this screen.", or why it did not, when the app in front is on your never-capture
  list or the screen is locked.
- **The menu's four `Open…` items are one (#134).** `Reports & days…` (⌘R) opens the reader;
  `Open latest report` and `Open today's timeline` open it on that report and on today. "Reveal
  reports folder" and "Reveal data folder" moved to Settings → General, under **Your data**,
  beside the `DATA_DIR` they are about.
- **A greyed-out `Generate today's report` says why (#134):** `Generate today's report (12 of 20
  frames)`. Two reports can also be written back to back now — a run is tracked per day rather
  than one at a time.
- **The stats tables name apps and tasks instead of printing their keys (#134):** `Code editor /
  Writing code`, not `code_editor/writing_code`, in the daily "longest focus" row and in the
  weekly per-day table.

- **Settings is a window you can navigate, resize and read** (#133). It was a pinned 580×520
  `TabView` whose tab strip the accessibility APIs could not see, so a keyboard or VoiceOver user
  could not leave General. It is now a sidebar of nine panes — General, Capture, Privacy,
  Reports, Models & budget, Permissions, Projects, Integrations, Activity — with ⌘1–⌘9 to jump
  between them, arrow-key and VoiceOver navigation, and a window you can drag as large as you
  like. Each pane is a grouped `Form`, which is what makes it look and behave like System
  Settings. Settings were refiled by the question they answer rather than by where the code grew:
  capture tuning moved out of General into its own pane, report time moved out of Models & cost
  into Reports, and the pause hotkey stayed in Privacy, beside the blocklists and the purge.
  `CAPTURE_SOURCE`, `LOG_LEVEL`, `REDACT_EXTRA_PATTERNS`, `PAUSE_REMINDER_HOURS` and the two
  `AUTO_UPDATE_*` keys now have a row; they had appeared nowhere in the app. Constants that are
  not settings — JPEG quality, image resolution, thinking level, the pricing version — moved out
  of the value column into section footers, next to the name of the `.env` key that does change a
  row. Every status carries its own SF Symbol rather than only a colour, so granted, denied and
  optional stay apart in greyscale and read as one line to VoiceOver; the optional Accessibility
  grant says "Not granted (optional)" instead of the same words the required one used. And the
  30-day spend table is a real table with a header that stays put and a "Copy as CSV" button,
  whose columns are the ones `worklens costs` prints.

- **The menu uses typed symbols instead of emoji, and the menu-bar icon says what it is doing**
  (#132). Status rows used to be strings with a colour emoji glued on the front, so the menu mixed
  emoji with the monochrome glyphs everywhere else and VoiceOver announced each row as "warning
  sign" or "money with wings" before reading it. Each row now carries its own SF Symbol, and every
  sentence reads without it: `Capturing · every 60 s`, `Paused until 15:30`, `Idle · nothing to
  record`, `Screen Recording permission needed`, `Budget reached · capturing, not describing`,
  `Stopped`. The spend line says the warning in words rather than with a marker —
  `$1.20 of $1.50 (80 % of today's budget)`, then `$1.60 of $1.50 — over budget`.
- **The menu-bar icon is named for speech, and has a fuller tooltip** (#132). It has carried an
  accessibility label since #114, but the label was the menu row's own abbreviated text, which
  opened with an emoji VoiceOver announces as a picture — "black circle, Capturing · every 60 s".
  It now says "Worklens, capturing every 60 seconds" (or "paused until 15:30", or "Screen
  Recording permission needed") with today's counts as its value, and the hover text is the
  status line, today's counts and whatever is currently wrong before the build stamp instead of
  the build stamp alone.
- **The version is derived from the git tag** (#130). It was a hand-edited `0.1.0` in two places
  with a "keep these in sync" comment between them, so after 168 commits every build ever made
  reported `0.1.0`. `scripts/bundle.sh` now stamps `CFBundleShortVersionString` from
  `git describe --tags --match 'v*' --abbrev=0` and `CFBundleVersion` from
  `git rev-list --count HEAD`, and `WorklensVersion` reads both back out of the bundle instead of
  holding a constant; the constant is now only what an unbundled `swift run` reports.
- The version comes first wherever the build is named (#130): the menu's version row and the
  menu-bar icon's hover text now read `0.1.0 · #105 · 0ae882e · updated 3 hours ago`, and
  `worklens version` still prints a bare version number on its first line with the build detail
  underneath. The pull request and commit stay — saying which build is running is the whole point
  of that line — but the version is what a bug report needs first.
- `make install-env` never flattens an installed API key (#124). The merge that arrived with
  #129 is what enforces it: a key only `~/Library/Application Support/Worklens/.env` sets is
  kept, a key the two files disagree about is printed as a diff by name and left at the
  installed value, and `ARGS=--force` is still what it takes to prefer this checkout's.
- A bad `.env` no longer stops the recording (#126). "Reload configuration" reads and parses the
  new file **before** it takes anything down, so a typo leaves capture, the describe worker and
  the scheduler exactly where they were and raises a notice naming the key and the file instead
  of dropping the app into degraded mode until the next relaunch. The degraded menu also tells a
  bad value from a data folder it cannot open, and offers each its own way out — including "Use
  defaults for these keys and start", which drops only the settings that did not parse, keeps
  every other value, lasts for that session alone and writes nothing to any file.
- Configuration is validated at load, and every error is reported at once with the file it is in
  (#126). `REPORT_TIME` must be `HH:mm` — the exact rule the report scheduler uses, now one
  shared parser, so a `7am` is refused at load rather than quietly meaning no daily report ever;
  the four capture intervals and `AUTO_UPDATE_POLL_MINUTES` must be 5 or more and
  `DAILY_BUDGET_USD` 0 or more, instead of being silently clamped. A model id that is in no price
  table stays a **warning**, never a refusal — a new Gemini or Claude id must still launch — and
  now says out loud that its calls are being costed at $0.
- Settings shows a banner on every tab while the configuration is broken (#126): the sentences,
  the file path, Open file, Reload, and the fact that the tabs below are showing Worklens's
  built-in defaults rather than your values.
- `.env` parsing got two fixes (#126). A trailing `# comment` is stripped from an unquoted value
  when the `#` has a space in front of it, so `CAPTURE_INTERVAL_SECONDS=60  # a minute` works;
  a `#` with no space before it (a URL fragment, a regex) and anything quoted are kept verbatim.
  `BLOCKED_BUNDLE_IDS` and `BLOCKED_URL_HOSTS` now accept `,` or `;`, while the two regex keys
  stay semicolon-only — a comma is legal inside a quantifier such as `{2,3}` — and warn when a
  value looks comma-separated.
- A key nothing reads is named rather than silently ignored (#126). `worklens config-dump` and
  the menu list unknown keys from your `.env` files with the nearest real key
  (`CAPTURE_INTERVAL_SECS` → `CAPTURE_INTERVAL_SECONDS`). Unknown keys stay non-fatal, exactly as
  retired keys do; key names only are ever printed, never values.
- "Update and restart…" relaunches into the configuration the app was actually reading (#129).
  Worklens records the file `WORKLENS_ENV_FILE` named at `~/Library/Application
  Support/Worklens/.launch-env`, and `scripts/launch.sh --restore` — which `scripts/update.sh`
  calls — passes exactly that file back. A missing record, or one naming a file that is gone,
  falls back to the installed configuration as before. `make run` is unchanged on purpose: it is
  a launch from a checkout, not a restart, and it now prints one line saying that a Finder or
  login-item launch will not read this checkout's `.env`.
- The README is written for someone who wants to *use* Worklens (#127): about 1 600 words with
  what you get, what leaves your Mac, install, the first run, **what it costs** (≈ $0.40 a day,
  ≈ $9 a month, with `DAILY_BUDGET_USD` as a hard stop), the privacy controls, how it works and
  where the two API keys come from — including the billing-enabled-Gemini-project warning, which
  until now was only in `.env.example` and `PRIVACY.md`. Every developer-machine section moved,
  unchanged, into `docs/user/` and `docs/contributing/`, and new pages cover the first day
  (minute 0 → 07:00 tomorrow → Monday), the cost model, the vocabulary and uninstalling. The
  missing-`GEMINI_API_KEY` line in the menu and the matching CLI errors now name
  `docs/user/setup.md#keys`.
- The two optional permissions are offered rather than warned about (#117): the Accessibility and
  browser-URL lines lost their ⚠️, and Settings → Permissions has a "Don't remind me" for each.
- One registry of configuration keys (#108): `Config.keys` is the single list every `.env` key
  list derives from, and `.env.example` is generated from it rather than hand-maintained.
- One home for status colour and Settings layout (#109): `StatusLevel` says what a status means
  and `Design/Theme.swift` is the only place that turns one into a colour.
- The fixtures, tests and doc comments no longer name a real employer, Slack workspace or
  workspace member; the sample projects are fictional.
- `.gitignore` covers Swift and macOS only, plus key material and `.claude/`.
- The original milestone specs moved to `docs/history/issues/`; work is specified on GitHub
  issues.

### Fixed

- **Notifications show the new app icon after an update.** Notification Center keeps the icon
  it first saw for as long as it runs, so after the recording-mark icon landed, every banner
  kept the old one while the Finder and the Dock showed the new one. `scripts/update.sh` now
  notices when an update changes `AppIcon.icns`, re-registers the bundle with Launch Services
  and restarts Notification Center, so the next banner has the new icon. On a Mac that already
  shows the old one, `killall NotificationCenter usernoted` clears it.
- **A day on battery no longer falls apart into one-minute blocks.** On battery Worklens takes a
  screenshot every five minutes instead of every minute, but the timeline still joined frames as
  if they were a minute apart, so a morning of work became a row of one-minute blocks and the
  Weeks calendar had nothing long enough to draw. Each screenshot now records the interval it was
  taken at, and the timeline joins and sizes frames by that. Frames taken before this change keep
  the old rule.

- **The wave 6 review findings.** The menu's **Last frame** line is now bounded to today, so it
  cannot describe Friday evening beside a count of `0 screenshots` — before the first capture of
  a morning there is simply no line. A greyed-out report item names the report that is actually
  holding it rather than whatever else happens to be running, so "Syncing integrations — this
  comes back when that finishes" no longer appears on an item waiting for a daily report. Two
  configuration reloads queued back to back keep their row and the busy glyph up until the second
  one has finished, so the updater can no longer restart the app mid-rebuild. A banner posted
  while notifications have **never been asked for** — not only when they were denied — is
  mirrored onto the menu, and the "your first report is on its way" notice is mirrored with the
  rest. Four banners that wrote their own copy now say it in the same voice as the others, and
  About Worklens reads how this copy is signed without spawning `codesign`. `worklens uninstall`
  clears the certificate's Code Signing trust setting for real — it exports the certificate first,
  because the command it runs takes a file rather than a name — and points at Keychain Access
  whether the step succeeded or not.

- **The pause hotkey can be set from the keyboard, and reads right on any layout (#154).** The
  recorder in Settings → Privacy was a bare view that only a mouse click could start: VoiceOver
  skipped it and Full Keyboard Access could not reach it, on the one control that stops Worklens
  looking. It is now a button with a role, a label and a value — Tab reaches it, Space or Return
  starts it, Escape cancels, and the new combination is announced. The letter it shows comes from
  the *active keyboard layout* rather than the US-ANSI table, so an AZERTY or German keyboard is
  no longer told it bound a key it did not press, and the label follows a layout change while
  Settings is open. **Reset** is always there, disabled when you are already on the default.
- **Return no longer performs the risky half of a confirmation (#154).** "Generate anyway",
  "Update" and "Delete" were each their alert's Return button, so the key you press to dismiss a
  dialog spent money or restarted the app — while the delete alert, the one place it had been
  noticed, had no Return button at all. All three now go through one helper: Escape and Return
  close the alert without acting, ⌘↩ performs it, and a destructive action is marked as one.
- **Settings → Integrations no longer shows yesterday's answer** (#135). It held the `Config` and
  the sync scheduler it was handed when the window opened, so after any configuration reload it
  drew the old state and its **Sync now** called a scheduler that had been torn down — silently
  doing nothing until the window was closed and reopened. It now reads both from the app at the
  moment it asks, and refreshes whenever a reload lands.
- **Editing an integration no longer interrupts capture** (#135). A reload whose changes are
  confined to the context keys rebuilds only the context sync scheduler; screen capture, the
  describe worker and every timer around them keep running. Pasting a Slack token used to tear
  the whole stack down and start it again.
- **Two configuration reloads at once no longer leave a stray sync scheduler running** (#135).
  Applying a configuration stops the old services and starts the new ones, and a second reload
  arriving in between could take over halfway through, dropping the scheduler the first one had
  just started without stopping it — it then kept syncing every source on its own timer, for the
  rest of the session. Reloads now run one after another. Saving a Google client id and secret
  together is two writes, so this was one button press away.
- **"Sync integrations now" is gone from the menu when nothing is connected** (#135), replaced by
  **Set up integrations…**, which opens the pane that can fix that. The old item was always
  offered — the check behind it could never be false — so it invited a sync round that had
  nothing to sync.
- The menu's **Fix…** button next to "Not summarizing…" is no longer offered when it cannot help
  (#191). It opens the field where your API keys are typed, which is the answer to a rejected key
  and to nothing else — but it appeared beside every describe stall, including Gemini having
  trouble (HTTP 503) and an answer that did not fit the schema, where there is no key to correct.
  Those now show the sentence alone. A rejected key still offers the button, and every line reads
  exactly as it did.
- Frames are no longer lost to a rejected key (#125). A provider refusal — a bad key, a spent quota
  — is about the account and not about the frame, so it now holds the queue the way an outage does
  instead of burning each frame's three attempts and marking it permanently `failed`, which nothing
  ever undid. Frames an earlier build failed that way are put back to `pending` on the next config
  reload, so correcting the key recovers the day.
- A frame the provider refused for its own sake is no longer described over and over (#189). That
  recovery read every HTTP 400 in the day's ledger as "the key was rejected", but Gemini answers an
  oversized image or a malformed request with a 400 too. Such a frame spent its three paid attempts,
  was put back to `pending` at the next launch or configuration reload by the very row it had just
  written, and spent three more — for good, at real cost, on a frame that could never succeed. Only
  a 401, a 403, or a 400 whose response named the key now counts, so those frames stay `failed`
  where they belong; frames a genuinely rejected key failed still come back when you fix the key.
- Notification banners drew a blank white tile where the app icon belongs. The icon was never
  the problem — the Finder and System Settings → Notifications both rendered it correctly, and
  so did Launch Services when asked directly — but Notification Center caches an app's icon per
  bundle identifier for the life of that daemon, so a single launch of an early build whose
  bundle had no `AppIcon.icns` poisons every later build until `killall NotificationCenter`.
  `scripts/bundle.sh` now refuses to assemble a bundle with no icon instead of warning about it
  and carrying on, a test keeps `Resources/AppIcon.icns` present and complete at every size, and
  the README says how to clear the cache on a Mac that is already in that state.
- PRIVACY.md no longer claims there is "no update check" (#120). The "What leaves your machine"
  table now lists every host the app can reach — Gemini, Anthropic, GitHub's `git ls-remote` for
  the automatic update, and the Slack, Granola, Google Calendar, Gmail and Google sign-in
  endpoints the context sources use — with what is sent, when, how to turn each one off and the
  file that implements it. The table moved to the top of the document under a "Privacy in 30
  seconds" summary, a short copy of it sits in the README under the hero, the Privacy tab and
  `.env.example` say where the update check goes, and a test fails the build if a new host
  appears in `Sources/` without a row.
- A first run no longer claims Worklens "lost Screen Recording permission" it was never given
  (#117). The notification, the menu line and the problem row now say *not on yet* until the
  grant has existed once, and the outage is remembered in `app_state`, so relaunching to make a
  fresh grant take effect does not post the same banner again.
- The menu no longer offers Pause while a missing grant means nothing is being captured (#117):
  Screen Recording missing now leaves one row, "Screen Recording is off — Fix…".
- A capture tick can no longer raise the macOS Automation dialog (#117). The browser URL probe
  runs for an allowed browser and skips every other one, so the consent dialog appears only when
  you ask for it — and it no longer times out unanswered.
- An installed Worklens keeps its update item (#119). `scripts/bundle.sh` stamps the checkout's
  path into the bundle, so a copy in `/Applications` still knows where it came from — before
  this, installing the app silently turned off "Update and restart…" and every automatic update
  with it. `make update` now also quits, re-installs and relaunches the installed copy; it used
  to rebuild under the running app and leave you on the old one without saying so.
- `make test` again expands `@Test` and `@Suite` on Command Line Tools installations that keep
  `libTestingMacros.dylib` in a `plugins/testing/` subdirectory.

## M6 — Evals and learning

### Added

- Eval export and a Python eval harness (`evals/`), so a prompt change can be measured instead of
  guessed at.

### Removed

- Taxonomy auto-update from model proposals. The task list is frozen and hand-edited.

## M5 — Context sources

### Added

- A context events framework with meeting detection.
- Granola as a source of meeting notes.
- Slack as a source of your own messages only.
- Google Calendar and Gmail through an OAuth loopback flow, with the grant in the Keychain.
- A read-only MCP server, which is how "ask your week" is answered.

### Removed

- The in-app "Ask your week" chat window; Claude Desktop is the chat surface over the MCP server.

## M4 — UI, privacy and robustness

### Added

- The menu-bar UI and the Settings window.
- Privacy controls: blocklists, redaction, a global pause hotkey, delete-the-last-N-minutes, and
  `PRIVACY.md`.
- Cost guardrails: an LLM call ledger, a daily budget, and the spend display.
- Robustness: launch at login, logging, a disk budget, permission-loss handling, and single-
  instance enforcement.

## M3 — Reports

### Added

- The Anthropic client (REST Messages API, Opus 5, refusal handling, cost accounting).
- The daily stats aggregator.
- The daily report generator, with its schedule, catch-up and storage.
- The weekly report generator.

## M2 — Describe

### Added

- The app and task taxonomy: seed data, resolver and proposals.
- The Gemini vision client (REST, structured JSON, cost accounting, retries).
- The describe worker: queue, prompt assembly, and inheritance for unchanged frames.
- The timeline writer: activity blocks and the daily markdown timeline.

## M1 — Capture

### Added

- The Screen Recording permission flow and the ScreenCaptureKit screenshot service.
- The foreground context collector (app, window title, browser URL).
- The image pipeline: downscale, JPEG, perceptual hash and change score.
- The SQLite storage layer (GRDB): schema, migrations and repositories.
- The capture scheduler: timer, idle/lock/sleep handling, pause, blocklist and meeting cadence.

## M0 — Scaffold

### Added

- The SwiftPM menu-bar app skeleton, the bundle and sign scripts, the config loader and the CLI.
