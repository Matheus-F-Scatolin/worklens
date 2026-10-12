# Worklens — Decisions, cost model, milestones

Moved from `docs/PLAN.md` §4–§7 on 2026-09-08. History and rationale; rarely needed while coding.

A working log kept while the project was private, published as it was written: "the owner" is
the maintainer, and anything it calls current describes the day of its entry, not today.

## Cost model (verified prices, 2026-09-07)

Assumes an 8-hour day, 60 s capture interval (480 frames), ~40 % of frames pass the
change/metadata filter (≈ 200 vision calls).

| Item | Tokens | Unit price | Per day |
|---|---|---|---|
| Describe, Gemini 3.5 Flash-Lite, `MEDIUM` image (560) + ~600 text in, ~150 out | 200 × (1.2k in, 0.15k out) | $0.30 / $2.50 per M | ≈ $0.15 |
| **Total** | | | **≈ $0.15 / day ≈ $3 / month** |

Until 2026-10-05 the table had two more rows, the Opus 5 daily report (≈ $0.20) and the weekly
(≈ $0.06), for a total of ≈ $0.40 a day; they went with the reports (#298).

Levers if it needs to be cheaper: `MEDIA_RESOLUTION_LOW` (halves image tokens), a longer
interval, or Gemini 2.5 Flash-Lite ($0.10 / $0.40 → describe cost ≈ $0.03/day). The eval
export (issue #24) exists precisely to test those swaps against real frames.

---

## Milestones and issues

Issue numbers assume creation in order into an empty repo.

**M0 — Scaffold**
1. Scaffold SwiftPM menu-bar app, bundle/sign scripts, config loader, CLI skeleton

**M1 — Capture**
2. Screen Recording permission flow + ScreenCaptureKit screenshot service
3. Foreground context collector (app, window title, browser URL)
4. Image pipeline: downscale, JPEG, perceptual hash, change score
5. SQLite storage layer (GRDB): schema, migrations, repositories
6. Capture scheduler: timer, idle/lock/sleep, pause, blocklist, meeting cadence

**M2 — Describe**
7. App & task taxonomy: seed file, resolver, proposals
8. Gemini vision client (REST, structured JSON, cost accounting, retries)
9. Describe worker: queue, prompt assembly, inheritance for unchanged frames
10. Timeline writer: activity blocks + daily markdown

**M3 — Reports**
11. Anthropic client (REST Messages API, Opus 5, refusal handling, cost)
12. Daily stats aggregator
13. Daily report generator (prompt, schedule, catch-up, storage)
14. Weekly report generator

**M4 — UI, privacy & robustness**
15. Menu bar UI + Settings window
16. Privacy controls: blocklists, redaction, pause hotkey, delete-last-N-minutes, PRIVACY.md
17. Cost guardrails: ledger, daily budget, spend display
18. Robustness: launch at login, logging, disk budget, permission loss, single instance

**M5 — Context sources**
19. Context events framework + meeting detection
20. Granola source
21. Slack source (own messages only)
22. Google Calendar + Gmail source (OAuth loopback, Keychain)
23. ~~"Ask your week" chat window~~ — built, then removed by #95; asking happens in
    Claude Desktop over the MCP server (#89).

**M6 — Evals & learning**
24. Eval export + Python eval harness
25. ~~Taxonomy auto-update from proposals (Opus 5 review, user approval)~~ — built, then
    removed by #86; the task list is frozen and hand-edited.

Build order is the numbering. A useful product exists after #10 (timeline) and a
complete v1 after #18.

---

## Decisions log

- **Swift over Electron/Tauri/Python:** lowest RAM/CPU, first-class ScreenCaptureKit and
  TCC handling, one language. Tauri would add Rust; Electron violates the overhead goal.
- **Keep screenshots (default `DELETE_SCREENSHOTS_AFTER_DESCRIBE=false`):** needed for
  evals. Mitigations: only frames that get described are saved, sensitive frames are
  deleted, disk budget pruning, everything under one folder the user can wipe.
- **Gemini `generateContent` rather than the newer Interactions API:** still fully
  supported, stateless by default, well known to implementing models, and the exact
  field names were verified live. Interactions can be adopted later behind the same
  `VisionDescriber` protocol.
- **Opus 5 for reports, not Haiku:** user preference; quality matters more than the
  ~$0.20/day it costs.
- **Metadata first, vision second:** a frame is described only if the perceptual change
  score crosses a threshold, the app/window changed, or a 5-minute heartbeat elapsed.
- **Redact credentials, keep identity (#49, 2026-09-08):** before any window text reaches a
  model, `TextRedactor` replaces what someone else could *use* — card numbers (bounded by
  non-digits and Luhn-checked), IBANs, one-time codes, API keys and password pairs — and keeps
  what makes a report readable: names, phone numbers, emails, CPFs, CNPJs, IPs and addresses.
  Regex-only, so the cost is a fraction of a millisecond per frame (0.41 ms for 3 000 characters
  on an M-series Mac) and there is no model in the privacy path; `NSDataDetector` was dropped with
  the decision to keep IPs and addresses.
- **The Keychain dialog after a rebuild cannot be fixed in code (measured 2026-09-10):** the
  "Worklens wants to access key `dev.worklens.google`" prompt is gated by the item's *partition
  list*, not by the application list an "Always Allow" click or a `kSecAttrAccess` ACL writes.
  `securityd` stamps that list when the item is created, and for a signature with no Apple
  Developer Team ID it stamps `cdhash:<exact binary>` — verified by creating items from an
  unsigned binary, from one signed with the `Worklens Dev` certificate, and with
  `security add-generic-password -A`: all three came back `cdhash:<that binary>`, and all three
  blocked a *different* binary's decrypt even with the application list widened to the "any
  application" wildcard (a nil list, which an Apple-signed tool matching `apple-tool:` proved is
  genuinely permissive). Pre-creating a `ACLAuthorizationPartitionID` ACL with
  `SecACLCreateWithSimpleContents` does not pre-empt the stamp — the item ends up with both ACLs
  and still prompts — and changing a stored item's partition list needs the login keychain
  password (`security set-generic-password-partition-list -k`). The data-protection keychain,
  which has no ACLs at all, refuses the write with `errSecMissingEntitlement` (-34018) without a
  team, and claiming `keychain-access-groups`/`application-identifier` on a self-signed binary
  gets it SIGKILLed by AMFI. So the options are a Developer ID (partition becomes
  `teamid:<TEAM>`, stable across rebuilds), keeping the token somewhere other than the login
  keychain, or one password per rebuild. Signing `.build/release/Worklens` with the certificate
  was tried for this and dropped: it stabilises the CLI's designated requirement, which the
  keychain does not consult. **Resolved with `GOOGLE_TOKEN_STORE=file`** (opt-in,
  `FileTokenStore`, `DATA_DIR/google-token.json` at 0600): the keychain was the only place
  Worklens kept a credential outside `.env`, which already holds `GOOGLE_CLIENT_SECRET` and every
  API key in plain text, so the file store costs no protection this project was actually relying
  on and removes the dialog for every build and worktree. The default stays `keychain`, because
  the trade — a grant inside a backup of `DATA_DIR` — should be chosen, not inherited. **#139
  made it an actual choice** rather than a default nobody was ever shown: the connect sheet in
  Settings → Integrations offers the two stores in their own words, pre-selected to the file
  store when the running binary carries no Apple Developer Team ID
  (`SigningIdentity.runningTeamIdentifier`, `SecCodeCopySelf` →
  `kSecCodeInfoTeamIdentifier`) — which is every build of Worklens today. Pre-selected, not
  resolved: `GOOGLE_TOKEN_STORE` still records the answer, a value the user or a file already
  set still wins, and switching stores from the radio group performs the disconnect-then-connect
  dance in one click instead of printing it as two terminal commands.
- **Own data only for integrations:** Granola stores meetings the user attended, and Calendar the
  events on the user's own calendar. (Slack stored only messages the user sent, and Gmail only
  sent-mail metadata, until both were removed on 2026-09-23 — see below.)
- **Exact per-app time from `NSWorkspace`, not from Screen Time's stores (#46):**
  `NSWorkspace.didActivateApplicationNotification` is the same OS signal Apple's own tracking
  is built on, it fires on every foreground switch, and it costs no new permission, no private
  API and no reverse-engineered database. Screen Time's stores (`knowledgeC.db` and friends)
  would need Full Disk Access, are undocumented, and change shape between macOS releases — they
  stay an experiment in #47, behind the `foreground_sessions.source` column this issue added for
  exactly that. Sampling screenshots was never going to be right: a 40-second Slack check between
  two ticks does not exist, and a two-minute switch counts as one minute or three depending on
  tick phase.
- **Per-bundle total from sessions, per-key split from frames (#46):** an activation event names
  a *process*, and the app taxonomy is finer than that — `TaxonomyStore.resolve` turns a Chrome
  frame on `mail.google.com` into `gmail` and a Sheets tab into `gsheets`, which sessions alone
  would collapse into `chrome`. So the exact total per bundle comes from the sessions (union,
  intersected with the day's active blocks) and the split within a bundle comes from the blocks,
  in proportion to their seconds. Neither source is asked for something it does not know. A
  bundle with no sessions keeps its block seconds, so days recorded before the migration do not
  regress; `byTask`, `hourly` and the focus metrics stay block-based, because a task is a
  property of a frame, not of a process.

## Accessibility first, pixels as fallback (#50)

Started with #52 (the snapshotter and the CLI, no pipeline change); #53 stores the text each tick
and decides describes from its hash; #54 describes from that text, makes the screenshot optional
and adds `CAPTURE_SOURCE`.

**`CAPTURE_SOURCE` stays `both`: the eval ran on 2026-09-09 and the rule for `auto` was not
met.** The rule was written before the work started (#54, 2026-09-08): `auto` ships as the default
only if text-only `app_key`/`task_key` agreement with image-only is at least as high as the
image-vs-image consistency on the same frames, and the judge does not score text-only summaries
lower. The corpus came from a day of normal work under the shipped default (`CAPTURE_SOURCE=both`,
`DELETE_SCREENSHOTS_AFTER_DESCRIBE=false`): 94 `.full` frames carrying both artifacts, exported
with `export-evals --sample 100 --coverage full` (export `20260910T023751Z`, prompt `d3`,
stratified over eight app buckets — Claude Desktop 37, Google Calendar 26, other browser tabs
23, VS Code 3, Meet 2, GitHub, LinkedIn and Terminal one each), then three
`gemini-3.5-flash-lite` runs (`--mode text`, `--mode image`, and `--mode image` again as the
ceiling) and Opus 5 judging the first 20 frames of each. Spend: $0.16 for the three describe
runs, $0.99 for the three judge runs.

| run against run, 94 frames | `app_key` | `task_key` | `is_sensitive` |
|---|---|---|---|
| image vs image-again (the ceiling) | 100% | 100% | 100% |
| text vs image | 100% | 96% | 100% |
| text vs image-again | 100% | 96% | 100% |

| judge (Opus 5, 20 frames, 1–5) | activity | classification | faithfulness | sensitivity | mean |
|---|---|---|---|---|---|
| image | 4.60 | 4.90 | 4.35 | 5.00 | 4.71 |
| image-again | 4.25 | 4.90 | 4.25 | 4.95 | 4.59 |
| text | 3.85 | 4.65 | 3.45 | 4.90 | 4.21 |

Cost per frame: text $0.00068 (1 210 prompt tokens), image $0.00053 (752 tokens — the harness
sends `MEDIA_RESOLUTION_LOW`; production sends `MEDIUM`). Text was faster: p50 976 ms against
1 194–1 414 ms.

Both halves of the rule failed. `task_key` agreement is 96% against a 100% ceiling: four frames
of 94, three browser frames the outline read as `forms_admin` and the picture as `reading`, and
one VS Code frame, `coding` against `reading_code`. The judge scored text-only lower on every
dimension, and the faithfulness gap (3.45 against 4.35 and 4.25) is far outside the ~0.3 noise
band: on the 20 paired frames, text scored below image on 12 and above it on 3, while the two
image runs differed on 10 frames in either direction. One judge-side caveat is real and does not
rescue the result: the judge grades against the pixels, and a `.full` outline legitimately
contains text the viewport does not show, so some "invented" details exist in the window but not
on the screen.

**What the failures look like** (from the judge's rationales; names withheld). The outline of a
calendar week lists every event in the week, and the text-only describe narrated a meeting other
than the one under the cursor. The outline of an Electron chat app carries the sidebar's session
list, and the describe summarised that list instead of the open thread, attributing the work to
the wrong project. A static filter chip in a pipeline list became "configuring filters"
(`forms_admin`). The common shape is not hallucination from nothing: a `.full` outline is *more*
than what the person is looking at, and once it is flattened a text-only model cannot tell the
focused part from the rest. The image runs never made that mistake, because pixels show exactly
the viewport.

**What this means for the default, and what it does not.** `both` stays, so every tick keeps a
JPEG and a description can be checked against what was on the screen. It does *not* mean the
describes are unaffected: `DescribePrompt.Mode.forFrame` sends a `.full` frame text-only whatever
`CAPTURE_SOURCE` says (all 94 exported frames were described from text in production), so the
faithfulness gap above is the shipped behaviour, and the JPEG that `both` keeps is evidence on
disk, not an input to the describe. Three follow-ups fall out of this, each its own issue rather
than a change slipped into a docs PR: send a `.full` frame as text *plus* image when a JPEG
exists (the harness cannot measure that yet — `--mode both` means "as production would", which is
text-only for `.full`); make the outline carry the focus, a shorter listing that stops at the
focused subtree and the main content container so that a sidebar or the other six days of a week
are not on equal footing with what is being read; and hand the judge the outline alongside the
pixels when it grades a text-only run, so a detail that is in the window but off-screen is scored
as off-screen rather than invented. Until the first of those is measured, `auto` is the wrong
default: it would remove the one artifact that shows what the text-only describe got wrong.

Re-running the eval after any of those changes is the same recipe:

```bash
swift run Worklens export-evals --sample 100 --coverage full
cd evals
uv run run_describe.py --export … --model gemini-3.5-flash-lite --mode text
uv run run_describe.py --export … --model gemini-3.5-flash-lite --mode image
uv run run_describe.py --export … --model gemini-3.5-flash-lite --mode image --name image-again
uv run judge.py --export … --run …/runs/<each>.jsonl --limit 20
uv run report.py --export …
```

The third run is the point of the exercise: it is the same settings twice, so the
run-against-run table prints the image-vs-image ceiling next to the text-vs-image number, and the
rule is read against that ceiling rather than against 100%. A flip to `auto` is then a one-line
change to `Config.defaults()` and `.env.example`, and the new numbers in this section.

**What was verified live on 2026-09-08, before the corpus existed** (developer
machine, `DATA_DIR` pointed at a scratch directory so nothing touched the real data):

- Under `CAPTURE_SOURCE=auto`, a `.full` frame took **no** screenshot: `saved=no`,
  `capture_source = accessibility`, `image_path` NULL, no `.jpg` on disk, and the frame was still
  queued for describing. A `.none` frame in the same session fell back to the picture, wrote
  `both`, and `stats` printed `3 accessibility · 1 both · 1 with a JPEG` beside the coverage line.
  The second and third `auto` ticks on an unchanged window were `unchanged`, from the text hash
  alone, with no pixels involved.
- A **text-only describe reaches Gemini and works**: 537 prompt tokens, $0.000431, a correct
  one-sentence description, with no `inline_data` part in the body. Worth stating because
  `docs/api-shapes.md` was verified with an image part present; a body with only a `text` part is
  accepted by `generateContent` with `mediaResolution` still in `generationConfig`.
- The harness runs end to end. One frame carrying both artifacts, three runs
  (`--mode text|image|both`), then `report.py`: 507 prompt tokens for the text rendering against
  970 for `MEDIA_RESOLUTION_MEDIUM`, $0.00042 against $0.00050 per frame, and the
  run-against-run table rendered. One frame is a wiring check, not a measurement, and no number
  from it belongs in a decision. Total spend for all of the above: **under one cent**.

**Text-first is not a token saving per call.** The one honest number the smoke test gives: 507
tokens of outline against 970 with a medium JPEG on the same frame — cheaper here, but that is one
notification banner; 3 000 characters of outline is ≈750 tokens against 560 for the image. The
savings come from the describes that no longer happen (a playing video no longer buys a vision
call), and the win is exactness and the pixels never leaving the machine.

**Why #53 still takes a screenshot on every tick.** It would have been one line to skip the
capture for a `.full` frame, and it would have been the wrong line. `DescribeWorker` cannot read
`ax_snapshots.text` until #54, so a frame with no JPEG would simply have no description — the
timeline would go blank for exactly the windows the accessibility tree covers best. Keeping the
pixels means #53 changes *nothing* downstream and can be judged on its own: the video-frame waste
stops (a `.full` frame whose text hash did not move is no longer described, however much the
pixels moved), the coverage numbers start accumulating on real work, and the database fills with
frames that carry **both** artifacts — which is precisely the corpus #54's eval needs to compare
a text-only describe against today's image one on the same moments. Two shippable halves, each
reversible, instead of one flag day where a regression in the walk is indistinguishable from a
regression in the prompt.

**#55 reads the title and the URL from the tree, and keeps both probes.** The same read that
covers the window's text also names it, so `AXHeader` (title, `AXDocument`, `AXURL`, and no walk)
runs *before* the privacy blocklist — the blocklist matches on exactly those two fields, and this
is the only reader that has them without Screen Recording and without an Apple Events prompt per
browser. Firefox gains a URL it never had. Nothing is removed and nothing is preferred blindly:
`kCGWindowName` and the AppleScript probe still answer whenever an attribute or the whole grant is
missing, both readers share `BrowserRegistry.normalize`, and `titleSource` / `urlSource` on the
row turn "can the probes go?" into a week of `stats --date` rather than an argument.

**The `.full` grade is re-checked where it is consumed, not where it is computed.** #52's table
below records Slack grading `.full` off two nodes; #53's rule for `.full` drops the pixel term, so
trusting that grade would have removed the only signal that notices a new Slack message.
`DescribeDecision.trustedCoverage` demotes a `.full` snapshot with fewer than five nodes to
`.partial`, which keeps the pixel rule underneath it. `Coverage.classify` is left alone on
purpose: it is what `ax-snapshot` prints and what #54 buckets eval frames by, and moving it would
have silently invalidated the measurements in this document. The floor costs a few extra vision
calls on genuinely small windows (Terminal reads `.full` at four nodes) and that is the safe
direction to err in — an unnecessary describe costs a fraction of a cent, a missed one loses an
hour from the timeline.

**The walk is focused-first, not breadth-first from the root.** A BFS from the window root under a
node budget spends it on tab strips and toolbars; the message body a user is actually reading sits
a dozen levels deeper. Four stages under one budget, one per-stage depth limit and one deadline:
focused ancestry → focused subtree → main content container (`AXWebArea`, else the largest
`AXScrollArea`/`AXGroup`) → the rest of the window.

**Measured on the developer machine, 2026-09-08** (`swift run Worklens ax-snapshot --app <name>`,
release build, M-series, defaults `AX_MAX_NODES=400` / `AX_WALK_TIMEOUT_MS=250`). Recorded as
found; the defaults were not tuned to make any row look better.

| App | Coverage | Nodes | Elapsed | What stopped it, and what it got |
|---|---|---|---|---|
| Mail | `full` | 8–11 | 34–45 ms | Finished. Only the **first-run onboarding window** — no mail account is configured on this machine, so there is no mailbox window to read. |
| Safari (Wikipedia article) | `partial` | 334 | 280 ms | Deadline. Article text reached; `webURL` correct from the `AXWebArea`. |
| Safari (Start Page) | `full` | 58 | 55 ms | Finished. |
| Chrome (Gmail inbox) | `partial` | 400 | 101 ms | Node budget. Conversation list reached — senders, dates, subjects — not just the tab strip; `webURL` and `documentURL` both correct. |
| Chrome (a heavy web app) | `partial` | 400 | 176–193 ms | Node budget. |
| Slack | `full` ⚠️ | 2 | 32–46 ms | Finished, and that is the problem — see below. `AXManualAccessibility` accepted; the tree underneath is still untitled `AXGroup`s with no text. |
| VS Code | `partial` | 2 | 61 ms | Finished but under `AX_MIN_TEXT_CHARS`. `AXManualAccessibility` accepted; `documentURL` is the open file. |
| Xcode | — | — | — | Not installed: this is a Command Line Tools machine (see the toolchain note in `CLAUDE.md`). |
| Finder | `full` | 63 | 97 ms | Finished. |
| Notes | `full` | 179 | 199–265 ms | Finished, but within a hair of the deadline. |
| Terminal | `full` | 4 | 42–47 ms | Finished. `documentURL` is the shell's working directory. |
| Preview, no window | `none` | 0 | 14 ms | No focused or main window. |
| TextEdit | `full` | 47 | 129 ms | Finished. |
| TextEdit under `kill -STOP` | `none` | 0 | 398 ms | Deadline plus the messaging timeout, twice (the empty tree triggers the second walk). The call never blocks. |

Three things the table says that the design did not predict:

- **`Coverage.classify`'s "more than one node" floor is too low for Electron.** Slack grades
  `full` on two nodes and 130 characters — a window title and one untitled group — because both
  the node floor and `AX_MIN_TEXT_CHARS` are cleared. Left as specified rather than tuned, but
  #53 must not trust `.full` on the node count alone; a text-per-node floor or a minimum node
  count is the likely fix, and it belongs with the decision rule that consumes it.
- **Chrome needs no `AXEnhancedUserInterface` from us, and would not take one.** Setting it
  returns `kAXErrorAttributeUnsupported` (-25208) on Chrome 1xx here; the tree becomes available
  on its own once an assistive client queries the app a few times. The first snapshot after that
  starts can still be thin *and* grade `full` (27 nodes of browser chrome), which is the same
  weakness as the Slack row. `AXManualAccessibility` is accepted by both Electron apps and is
  reported in the snapshot.
- **A frozen app costs about 400 ms, not 250.** The deadline bounds the walk, and the messaging
  timeout (`AX_WALK_TIMEOUT_MS / 2`) bounds each blocked call, but an empty result triggers the
  `AXEnhancedUserInterface` retry and so pays both twice. It is bounded and it never blocks, but
  #53 should not treat the deadline as the worst case.

**Privacy invariants (all four issues).** The value of an `AXSecureTextField` is never read — the
walk asks for a node's value through a closure and never makes the call for a secure role or
subrole, which is asserted by a test rather than promised. Nothing about window text is logged at
any level. The text is redacted (#49) before any row is written (#53) and before it leaves the
machine (#54); `ax-snapshot` prints through the redactor by default and `--raw` warns on stderr.

## The daily report is written the morning after (#68, #62)

Decided 2026-09-08, from that day's own log. The 18:30 run failed offline
(`network error … The Internet connection appears to be offline`), nothing retried it, and the
report only exists because the app was relaunched at 22:25 and its launch catch-up wrote it at
22:27. That accident is what makes the evidence: the 22:26 prompt is 34 208 characters against the
18:30 prompt's 29 023, and everything in the difference — the Youka lyric sync, which the report
itself calls the day's biggest hands-on task, the OBS / iMovie / QuickTime work, and the PR merges
at 21:12 and 22:13 — is work an on-time 18:30 report would have missed for good. There is no
second pass over a day, so a report written while the day is still running is permanently
incomplete, and "three things to try tomorrow" is read the next morning anyway.

So the report time changed meaning rather than value: it is when *yesterday's* report is written,
and its default moved from 18:30 to 07:00. The weekly report day moved from `friday` to `monday` for
the same reason — under the old rule a Friday-evening weekly could never contain Friday's daily.
The scheduled and catch-up paths were doing the same job for the same period once the target
became "the period that just ended", so they are one path now, due at the report time or 30 s after
launch, whichever is later. The prompt is `r2`: it says the day is over, the section is "Three
things to try today", and `yesterdaySuggestions` still reads the `r1` heading so continuity
survives the rename. The menu action and `worklens report --date` are unchanged — writing today's
report on demand is the preview, and the user asked for it.

#148 finished the sentence that decision started. The preview stayed, and so did `report --date`;
what changed is that the prompt is now told which of the two it is. The daily prompt's framing
is `.sameDay` exactly when the day being written is the day it is now, and `.sameDay` drops the
morning-after rule for one that says the day is still in progress and addresses the suggestions to
the rest of it — the prompt is `r7`. Under `r2`–`r6` every preview of today was told it was
"writing on the morning after" and called the day "yesterday", which is the one way a report could
be factually wrong about its own subject. The menu item names the period it writes for the same
reason, and the scheduler's own runs are still `.morningAfter` and still the free ones.

Failures now retry instead of waiting for a relaunch (#62): 30 min, 1 h, then 2 h, six attempts,
with the next time in the message the menu shows ("retrying at 07:30"). Skips stay terminal —
already written, a quiet day and over budget are all answers, not errors — and a new local day
re-arms a period whose attempts ran out, so the 2026-09-08 case ends with a report even if every
attempt on 09-09 had failed too.

## Run-aware describe context, verb-first summaries (#65, 2026-09-09)

`DescribePrompt.version = "d3"`. The describer now sees the app the frame was switched from and
the run it belongs to, and is asked for what is *new* when the activity continues; every
instruction that seeded a subject ("Describe what the person is doing") is gone.

**Measured on 2026-09-08's frames.** One 60-frame stratified export per prompt, the *same* 60
frames (the sampler is seeded, so exporting the same window twice gives the same set), both
re-described with `gemini-3.5-flash-lite`, `MEDIA_RESOLUTION_MEDIUM`, `thinking-level minimal`,
`--mode image` — that day was captured before #53, so image is the only mode its frames can be
sent as. Judged by Opus 5 over all 60 frames of each run.

| | d1 (shipped that day) | d2 (before this change) | d3 (this change) |
|---|---|---|---|
| near-duplicate consecutive pairs¹ | 5/18 = **27.8 %** | 4/16 = **25.0 %** | 0/14 = **0.0 %** |
| summaries starting with a subject² | 60/60 = **100 %** | 59/60 = **98.3 %** | 0/60 = **0 %** |
| mean summary length | 15.2 words | 15.2 words | 12.2 words |
| judge: activity accuracy | — | 4.72 | 4.68 |
| judge: classification correct | — | 4.40 | 4.45 |
| judge: faithfulness | — | 4.80 | 4.75 |
| judge: sensitivity handling | — | 4.92 | 4.95 |
| judge: mean of the four | — | **4.71** | **4.71** |
| prompt tokens / frame | — | 1 002 | 1 023 |
| cost / 1 000 frames | — | $0.60 | $0.60 |

¹ The issue's rule: consecutive non-inherited frames sharing `app_key` **and** `task_key`, whose
summary word sets overlap at Jaccard ≥ 0.6. Over the **whole day** as it was actually described
(d1, 185 non-inherited rows) the share is **48/89 = 53.9 %** — the issue's 56 % on a slightly
different window. The table's smaller pair counts are the price of measuring three prompts on one
sampled corpus: only 14–18 of the 59 consecutive pairs in a 60-frame stratified sample share an
app and a task. Stripping the subject phrase and English stopwords before comparing — so d3's win
cannot be an artifact of "the person" no longer being two shared words — gives 22.2 % / 6.2 % /
**0 %** for the same three sets.

² `^(the person|the user|you)`.

**What this bought and what it cost.** No summary in the d3 run repeats its predecessor under
either rule, none begins with a subject, and the judge is flat: every dimension moves by ≤ 0.05,
far inside the ±0.3 the README calls noise, so the delta ask did not cost accuracy or
faithfulness. The context is cheaper than the issue estimated (+150–250 tokens): **+21 prompt
tokens per frame**, about +0.6 % — 42 of the 60 frames got only the one-line "before this app",
because the day is mostly short app visits, and the run block is capped at ~700 characters.

**`continues_previous` was not added.** It was optional in the issue and only "if it stays cheap":
it would need a field on `FrameDescription`, a key in `details_json` and a decoder change, in
files this change otherwise does not touch, and nothing consumes it yet. The run context is in
the export (`context` per frame), so a later issue can score block boundaries without it.

## Apple Screen Time stores: investigated, no-go for now (#47, 2026-09-09)

Checked on macOS 26.6.2 with Full Disk Access granted to the process running the probe script,
now only in history (`git show 2147a4b:scripts/screentime-probe.py`; it reads copies of the
stores, prints stream names, counts, date ranges, device ids and bundle ids; never titles, URLs
or domain names). Re-run it after a macOS update before trusting anything below.

**What the stores hold on macOS 26**

- `~/Library/Application Support/Knowledge/knowledgeC.db` (62 MB). `/app/usage` is alive:
  5 141 rows over 27 days (2026-08-13 → today), 118.6 h, Cocoa seconds in UTC with a
  `ZSECONDSFROMGMT` per row; 165 of the 421 rows on 09-09 are zero-length switches. **No usage
  row carries a device id** (`ZSOURCE.ZDEVICEID` is NULL on every `/app/usage`, `/app/webUsage`
  and `/app/mediaUsage` row); the only streams that arrive from other devices are `/app/intents`
  and `/bluetooth/isConnected`. So knowledgeC has no iPhone time. `/app/inFocus` is gone, as
  expected. `/app/webUsage` still exists but is Safari-only and tiny: 26 rows since 09-07, all
  `com.apple.Safari`, keyed on `Z_DKDIGITALHEALTHMETADATAKEY__WEBDOMAIN` (5 distinct domains).
  Chrome never appears in it.
- `~/Library/Biome/streams/restricted/App.InFocus` is where the iPhone lives. SEGB v2 segments
  (magic `SEGB` at offset 0, 32-byte header, 16-byte footer index entries of offset / state /
  Cocoa timestamp growing back from the end of the 512 KB file, protobuf records with a
  scene-or-bundle string, in/out flags, a fixed64 timestamp, the bundle id and the app version).
  `local/` is this Mac (segments 08-03 → 09-04). `remote/<device-uuid>/` holds synced devices:
  seven ids, two of them iPhones by their bundle ids (`com.apple.mobilesafari`, WhatsApp,
  `com.apple.SpringBoard.transitionReason.*`), with segments 08-08 → 08-30 and 07-01 → 09-07.
  The newest iPhone data is two days old and arrives one 512 KB segment at a time, days apart.
  The uuid → device-name mapping is only in `~/Library/Biome/sync/sync.db`, which also holds
  harvested Mail and Messages content, so it was not opened. `ScreenTime.AppUsage` (Mac only)
  and `App.WebUsage` (Safari) sit next to it; `streams/public` does not exist.
- The ScreenTimeAgent `RMAdminStore-Local/-Cloud.sqlite` that every write-up up to macOS 15
  describes **no longer exists** anywhere under `~/Library`. What is there instead is
  `com.apple.UsageTrackingAgent`'s `UsageTracking.sqlite` (DeviceActivity budget tables, all
  empty) and `com.apple.RemoteManagementAgent`'s `RemoteManagement.sqlite` (declarative device
  management). There is no SQLite shortcut to the hourly aggregate the panel renders, and none
  to iPhone usage.

**Diff against Worklens for 2026-09-09 (UTC).** Where Worklens ran with full capture coverage
the two agree to within a few minutes per hour: 15h 13.0 vs 13.0 min, 22h 60.0 vs 53.3,
23h 11.4 vs 11.4. The rest of the gap (8.91 h vs 3.50 h for the day) is coverage, not
semantics: `foreground_sessions` is empty before 05:25 because #46 shipped then (captures were
running at one a minute and match knowledgeC hour by hour), and 16–20h the app was being rebuilt
and relaunched for #81–#83 (captures drop to 14–23 an hour). One real semantic difference:
06:16–07:46 knowledgeC books 90 min of TextEdit with `/display/isBacklit = 1` while Worklens
has a single capture. Screen Time counts whatever is frontmost while the display is on, idle
or not; Worklens closes the session after `CAPTURE_IDLE_SECONDS`. A backfill would therefore
overstate time on whatever app was left in front.

**Go/no-go, per extra**

- **Safari domains: no-go.** Safari only, five domains in two days; you browse in Chrome (5 h
  that day) and #67 already reads the Chrome URL from the accessibility tree.
- **Backfill: no-go as a feature.** It would add 27 days of per-app totals from before install
  (Worklens started capturing 2026-09-08) with no frames behind them: no descriptions, no
  blocks, no report, just a time-per-app line with the idle semantics above. The window closes
  around 2026-10-05 anyway, and it costs a permanent Full Disk Access grant for Worklens.app.
  If ever wanted it is one SQLite query (`/app/usage` → `foreground_sessions` with
  `source = 'screentime_mac'`) plus the copy-then-read dance, about a day.
- **iPhone usage: present, deferred.** The only one of the three Worklens cannot see itself,
  and the most expensive: a SEGB v2 + protobuf reader (~200 lines; aw-import-screentime has the
  Python version), pairing in/out events per bundle, two device ids to tell apart without
  opening `sync.db`, a lag of days (so an addendum to an already-written report, never a
  same-day paragraph), and Full Disk Access for the app for good. Open a follow-up issue only if
  "off the Mac" paragraphs are wanted; the sketch in #47 (rows tagged `screentime_iphone`,
  never mixed into Mac totals, `SCREENTIME_IMPORT=0` by default, daily run) still stands.

#47 closes with this entry. No fixture was added (nothing goes ahead). Full Disk Access was
granted to Claude.app for the probe on 2026-09-09 and should be revoked.

- **The taxonomy learning loop is removed (#86).** Two days of live use produced 28 proposals,
  every one still pending and nearly all synonyms of keys that already existed (`video_meeting`
  ×6, plus `video_call`, `video_meeting_notes`, `watching_video`, `video_editing`). The weekly
  Opus review that was supposed to absorb them never ran once. The dimension it refined is 42 %
  `chatting_with_ai` and 15 % `other`, and no finding in any daily report was built on a task
  key. That bought ~1,570 source lines and ~490 test lines, a Settings tab, three CLI
  subcommands, a scheduler tick and a notification category — so it goes: the `drop-task-proposals`
  migration drops `task_proposals` (28 rows) and `descriptions.proposed_task`, and the describe
  schema no longer invites a proposal. Kept, because the stats need them: the bundle-id/URL
  resolver, a frozen `taxonomy.json`, and `isKnownTask` / `canonicalTask` coercing anything
  outside the enum to `other`. If task keys ever earn their keep, the way back is a better
  vocabulary written by hand, not a loop that proposes synonyms.

## Twelve tuning keys became constants (#87, 2026-09-09)

Forty-two keys in `config-dump`, six of them reachable from the UI. Twelve were knobs nobody had
turned and nobody would: `DESCRIBE_PROVIDER` and `REPORT_PROVIDER` selected nothing (there is one client
each, and the value only labelled the `llm_calls.provider` column — the client now names itself),
the five `AX_*` limits were read once each into `AXWalkLimits`, and `DESCRIBE_MEDIA_RESOLUTION`,
`DESCRIBE_THINKING_LEVEL`, `CAPTURE_JPEG_QUALITY`, `URL_STORE_QUERY` and `GRANOLA_MODE` each had
exactly one reader. Every value ships unchanged; it now lives next to its use — `AXWalkLimits`,
`GeminiClient`, `ImagePipeline.jpegQuality`, and `BrowserRegistry.normalize`, which strips the
query string unconditionally now (a stored search term or session token was never worth a knob).
`config-dump` prints 33 keys — the four `GOOGLE_*` keys landed after this was written, and since #108 the count is whatever `Config.keys` holds rather than a number kept by hand.

`GRANOLA_MODE=local` went with `GranolaLocalSource`: current Granola builds ship
`cache-v6.json.enc` and an encrypted `granola.db`, so the reader had nothing left to parse
(verified 2026-09-07). The official API is the only Granola path.

A stale `.env` is not an error — `Config` has always ignored unknown keys. It now warns once at
load naming any retired key a file still sets (`Config.retiredKeys`), so the two `.env` files can
be cleaned without guessing which lines are dead.

## The MCP server is hand-rolled and read-only (#89, 2026-09-10)

Worklens's data was only reachable from Worklens: the menu bar, the Ask window, the CLI. The Ask
window got one question in two days while Claude Desktop got 99 minutes on 2026-09-09, so the data
moved to where the asking already happens — `worklens mcp`, a stdio MCP server inside the same
binary, exposing `search`, `timeline`, `stats`, `report`, `context_events`, `friction` and `days`.
Screenpipe's MCP server is that product's main 2026 draw; Dayflow, AutoJournal and Granola all ship
one.

Three decisions worth keeping:

- **No SDK.** The CLT toolchain has already refused one package over macros (#16), and stdio MCP is
  five real methods (`initialize`, `notifications/initialized`, `ping`, `tools/list`,
  `tools/call`). `WorklensCore/MCP/` is about 300 lines, and `MCPServer.handle(line:)` is a pure
  function of a string, so `MCPServerTests` drives a whole transcript with no process and no pipe
  to a real client.
- **stdout is the protocol, so the command takes it away from everything else.** `MCPCommand.run`
  duplicates fd 1 and then points fd 1 at stderr. After that a stray `print`, an ArgumentParser
  diagnostic or a library's `fprintf` lands where the client logs it instead of corrupting the
  stream, and the only way to reach the client is the duplicate. `Log` was never the risk — it
  writes to os_log and `FileLog` — and the log file is how you debug a server whose stdout you
  cannot read.
- **Read-only, and deliberately not under the instance lock.** The client launches the binary
  *because* the app is running, so `mcp` stays out of `CLIEntryPoint.exclusiveCommands` and every
  tool in `WorklensMCPTools.registry` is a query onto a service that already exists. Write tools
  (pause, erase), HTTP transport, MCP resources and prompts are out of scope: a server that can
  erase a day is a different privacy conversation.

Nothing new is collected. The tools return the same redacted text the app already stores, and the
new destination is whichever MCP client the user configured — which is why `PRIVACY.md` names it
next to Gemini and Anthropic rather than leaving it implied.

## The Ask window is gone; Claude Desktop is the chat surface (#95, 2026-09-10)

#95 made the removal conditional on a one-week trial of the MCP server. The user waived the wait and
decided on 2026-09-10, the day #89 landed: the numbers that motivated the issue were already
one-sided — the Ask window was opened once in two days and cost $0.055, against about 99 minutes a
day in Claude Desktop — and once #89 put `search`, `timeline`, `stats`, `report`, `context_events`,
`friction` and `days` in front of Claude Desktop, the window was a second-best chat client onto the
same data, and one we had to maintain. Nothing is lost by deciding early: the data is unchanged and
the MCP server reads it, so a week of trial could only have confirmed it.

What went: `WorklensCore/Chat/` (`ChatSession`, `ChatRange`, `RangeResolver`, `ContextPacker`),
`Worklens/Chat/ChatWindow.swift`, the `ask` and `ask-time` subcommands, `ChatTests`,
`ContextPackerTests`, `docs/wiring/chat.md`, the `ChatWindowScene` in `WorklensApp`, and the menu's
"Ask about your time…" (⌘K). About 2 100 lines, including the 371-line `RangeResolver` and its own
model call — a question with no *when* in it paid for a second Opus 5 round-trip just to decide
which days to pack.

Three things stayed on purpose:

- **`LLMPurpose.chat` and `.rangeResolve`.** They are values already written into `llm_calls`;
  dropping a case would make an old row undecodable. Same reasoning as `.taxonomy` after #86.
- **The Chat column did not just disappear from `Settings → Models & cost`.** `DailySpend.otherUSD`
  now sums `taxonomy + chat + rangeResolve`, so the three remaining columns still add up to the
  day's total on a day whose ledger predates the removal, instead of silently losing spend.
- **`ContextBody.oneLine`.** It never belonged to the chat — it already lives in `Context/` and the
  timeline, the report prompt and #89's `context_events` tool all call it.

`ContextPacker`'s reports → timelines → events → transcripts ordering has no successor: the MCP
client does the packing now, choosing which tool to call, which is the part a 150k-character budget
was standing in for.

## A synced DATA_DIR is refused, and two Macs are two installs (#122, 2026-09-12)

Pointing `DATA_DIR` at iCloud Drive or Dropbox is the most natural thing a new user will try and
the one way to lose the history outright. Both of the storage layer's assumptions break over a
file provider: `Database` opens a WAL `DatabasePool`, and `Database.init` catches *every* error
from open, migrate or `PRAGMA quick_check` and sets the file aside — so a transient lock or a
half-materialised `-wal` renames a healthy `worklens.sqlite` to `worklens.sqlite.corrupt-<ts>`
and starts an empty one. `InstanceLock`'s `flock` is worse: it is a kernel lock on one machine,
so two Macs signed into the same account interleave writes and neither ever sees the other.

So `DataDirLocation` refuses rather than warns: capture does not start, the writing CLI
subcommands exit 3, and the menu carries a persistent row naming the folder. Everything that
*reads* is untouched, which is the same line `InstanceLock` already draws — someone who has
already pointed `DATA_DIR` at iCloud Drive must still be able to look at what they have.

`volumeIsLocalKey` is in the check but demoted: iCloud Drive, Dropbox and Google Drive all sit on
the local boot volume and answer true, so it catches only SMB and NFS mounts. The path prefixes
are the real test, and `.icloud` placeholders (which exist only for evicted files) are the last
resort.

`ALLOW_NONLOCAL_DATA_DIR` is a new key three months after #87 deleted twelve of them, and the
distinction is deliberate: #87 removed *tuning constants* nobody would set, and this is a safety
catch. The failure it prevents is silent and destroys data, so refusing without an escape hatch
would be the app overruling someone who understands the trade-off — and refusing with one is the
only way the refusal can be strict. It is not reachable from Settings; it has to be typed into an
`.env`, which is the point.

**Two Macs is two installs, each with its own `DATA_DIR`, and the histories do not merge.** There
is no sync story and there will not be one: nothing here leaves the disk except the two API calls.
What was missing was any way to tell two folders apart, so `MachineName` writes this Mac's name
into `app_state` at first run and into every report's front matter, and a mismatch raises its own
row — that mismatch, not the path check, is what catches a folder that arrived from another Mac by
some route nobody anticipated. It does not stop capture: a restored backup and a renamed Mac look
exactly the same from here. The name is restamped on a difference, so a rename says it once while
two Macs taking turns say it at every launch. It never reached Gemini or Anthropic — the
report prompt stripped the front-matter block from every report that went back into a prompt,
which also saved the weekly prompt a few hundred tokens it was spending on `model:` and
`cost_usd:` lines. Since the reports were cut (2026-10-05) the name is written to `app_state`
alone.

## The blocklists are app-writable, and `.env` still is not (#128, 2026-09-14)

The privacy promise rests on three lists, and until now exercising it meant finding a bundle
identifier, guessing which separator a key uses (`,` for `BLOCKED_BUNDLE_IDS`, `;` for the other
two) and opening a text file. The menu could delete the last ten minutes but could not stop the
next frame. So the three lists are editable: in Settings → Privacy, from the menu while the app
or the site is in front of you, and (until #300) from a `block` CLI command.

**The app writes its own file, never `.env`.** That objection (#108, and the comment that used to
sit at the top of `SettingsView.swift`) was never about blocklists being sacred — it was about
merge conflicts with the editor you keep the file open in. #90 had already drawn the line for the
projects list: what the app writes, the app owns. `blocklists.json` is the same answer.

**It is an overlay, not a layer.** `settings.json` wins a key outright, which would freeze a
snapshot of whatever `.env` said at the moment you clicked something and quietly ignore every
later edit to that file. The blocklists instead store *additions and removals*, and the effective
list is `(defaults ∪ .env ∪ added) − removed`. Without the removal set a "−" button would be a
lie on two thirds of the rows: `com.1password.1password` and `com.apple.keychainaccess` are Swift
constants, and `BLOCKED_BUNDLE_IDS` in an `.env` replaces the defaults rather than extending them.
Un-blocking your own password manager is a legitimate thing to want; it is your Mac.

**One seam, both processes.** `Config.loadWithProvenance` applies the overlay, so the app, the CLI
and `PrivacyPolicy` see the same three lists and `PrivacyPolicy` did not change at all. The file
lives beside `settings.json` and is resolved relative to it, which is what keeps the suite (and a
worktree) from ever reading the real one.

**The menu item reads a row, not a browser.** *Never capture <app>…* and *Never capture <host>…*
are computed in `MenuModel` from the most recent stored capture. A fresh Apple event at menu-open
would be the #64 trap: the first one blocks past the 1.5 s capture deadline and arms a ten-minute
backoff, so the menu would hang the first time it mattered. The consequence is honest and worth
saying out loud — the menu offers what was last *recorded*, which on a quiet minute is a frame or
two old.

**Window titles are regexes, so they are validated as regexes.** The list is not a list of
literals (PRIVACY.md has said so since #16), and "host validation" would have been the wrong
check. A pattern that does not compile is refused where it is typed, rather than dropped with a
warning at the next load the way `REDACT_EXTRA_PATTERNS` is.

## Integrations are set up in the app, through `settings.json` (#135, 2026-09-15)

Every integration used to cost the same three steps: leave the app, find the right `.env`, guess
what the key was called, come back and reopen a pane that then lied about the result. The pane's
whole instruction was `Set GRANOLA_API_KEY` — the name of a variable, in a file it never named.

**The keys are written the way every other setting is.** The issue's review notes asked for a new
`WorklensCore/Config/EnvFile.swift` that rewrites one `KEY=VALUE` line in place, because at the
time the recorded decision was that `.env` is the single source of configuration and a UI that
edited it would fight the user's own editor. #108 landed the better answer first: `SettingsStore`
writes `~/Library/Application Support/Worklens/settings.json`, a validated flat map at mode 0600
that outranks both `.env` files and loses to the process environment and `WORKLENS_ENV_FILE`. So
there is no `.env` writer and no second store — the integration keys are ordinary
`editableInApp` keys, saved through `AppModel.applySetting` like the API keys #124 added, and a
field whose key a layer above the store supplies shows itself disabled instead of pretending the
edit would take.

**A refused credential is not an error.** Granola answers 401 both for a wrong key and for a plan
without API access, and its own hint has always said so. Rendering that as a red `Error: …` line
tells the reader the app is broken when the answer is either "re-paste" or "your plan does not
include this". It is now a state of its own at attention level, and the Business-plan requirement
is stated above the field rather than discovered after the paste.

**Test before the background finds out.** Each sheet's Test button makes one free call — Slack's
`auth.test`, which the sync already makes once per workspace, and one Granola note — and neither
writes to the database. Without it the first sign of a bot token or a rotating token was a failed
sync a quarter of an hour later, in a pane the user had already closed.

**Editing an integration must not stop capture.** `reloadConfig` rebuilt the entire stack for any
change at all, so pasting a Slack token dropped the frame in flight and re-armed every timer.
`ConfigReload.onlyContextChanged` is the narrow test — the new config with its context values put
back must equal the old one, so a key added outside `ConfigSection.context` falls to the safe
side — and it rebuilds `contextSync` alone.

## Worklens writes Claude Desktop's configuration, once you say so (#140, 2026-09-15)

The most attractive thing this app can do for a Claude Desktop user was gated behind a JSON edit
in a hidden folder whose failure mode is silence: a wrong path and the server simply never
appears. So the app does the edit. Three rules make that acceptable. It asks first, every time,
naming the file — editing another application's configuration is not something to do on a click.
It copies the old file aside with a timestamp and merges **only** `mcpServers.worklens`, so every
other server, and every other key, survives; a file that does not parse is refused rather than
replaced, because a hand-edited file is precisely the one worth not losing. And it never touches
a running Claude Desktop: the card says to quit and reopen it, which is one more click than
killing it and one less betrayal.

The half that is easy to miss is the environment. Claude Desktop launches the binary with a
minimal environment and working directory `/`, so `Config.loadWithProvenance` sees only the App
Support layers, while the app itself usually runs with `WORKLENS_ENV_FILE` set by
`scripts/update.sh` — the same divergence `make install-env` exists to paper over. The entry
therefore pins that file when there is one, and the smoke test afterwards resolves configuration
the client's way rather than the app's, so "7 tools ready, reading …" is a claim about the
process Claude Desktop will start rather than about this one. `initialize` now also carries that
directory in its `instructions`, which makes a mismatch answerable from inside the client. All of
it lives in `MCPClientConfig` and `MCPSmokeTest` in `WorklensCore`, with the executable path
passed in from the app, so the button and `worklens mcp install` cannot drift apart.

## 2026-09-23: Slack and Gmail sources removed (#285)

The owner decided this on 2026-09-23, during the Settings redesign (#286); the September feature
audit had deferred it rather than rejected it. Neither source earned its setup cost. Slack needed a
user token from a hand-made Slack app — the manifest, the two user scopes and the rotation trap
were the whole of #135's Slack work — and Gmail added a Google scope that only ever yielded
sent-mail instants: a subject and a time, no body, and nothing a report used that the screen had
not already shown. Removing them also shrinks the new Connections page to four rows: Claude,
Gemini, Granola and Google Calendar.

What was removed is the *integration*: the API sync, the token, the `gmail.metadata` scope, the
stored context events and every CLI, MCP, docs and Settings surface for them. Slack and Gmail as
*apps you use* are untouched — captured, described, in the taxonomy, and a Slack huddle is still a
meeting. How it lands on an existing install:

- **`SLACK_USER_TOKEN` is a retired key**, not a deleted one. An old `.env` that still sets it
  would otherwise be an `unknownKey` and stop the app launching; retired, it is ignored and
  `config-dump` names it as a line to delete.
- **The Google grant is not reset.** `gmail.metadata` left `GoogleAuth.scopes`, so a new sign-in
  asks for `calendar.readonly` alone, but an existing refresh token keeps working for Calendar and
  nothing forces a reconnect. The Google card says once where the old mail access can be removed.
- **One cleanup, once.** `RetiredSources.run` deletes the stored `slack` and `gmail` events and
  blocks by raw source string — their enum cases are gone, so the rows no longer decode, which is
  why it runs synchronously at launch before anything reads one — plus Slack's cached identity and
  names and both sync statuses, behind the `retired_sources_removed` flag in `app_state`. The Slack
  token Worklens saved in `settings.json` is revoked with a best-effort `auth.revoke` and then
  removed. `worklens context forget slack` runs the same cleanup for someone who only uses the CLI,
  explains, and exits 0.
- **The timeline loses two lines and the stats two counts.** "Emails sent" and "Slack: N messages
  sent" went from the Context section, and `emailsSent` / `slackMessagesSent` from `DailyStats`,
  because nothing feeds them any more. The days that carried them are redrawn by the cleanup.

## 2026-09-23: Settings is a page of the reader, not a window (#286)

The owner decided this on 2026-09-23. The Settings window was a SwiftUI `Settings` scene with
eleven panes and more than a hundred controls: "This build", diagnostics, the data and reports
folders and the disk budget each appeared two or three times, raw key names sat in tooltips and in
the Privacy footer, and it was a second window that fought the reader for the front (#279).

Settings is now a page of the reader: a gear at the foot of the icon rail, a Claude-desktop-style
list of six sections — General, Capture, Privacy, Reports, Connections, Usage — and Advanced below
a hairline, always shown. The choices the owner made and that are not to be reopened: an in-app
page rather than a sheet or one long scroll; Projects inside Reports; Activity's notices on
General's status line and as a dot on the gear; open hairline rows on ivory, with only Capture's
Access card boxed; a soft square behind the lit gear, never a solid terracotta tile; terracotta as
the one accent; no Save buttons. Every old pane name still lands somewhere, so a stored
`settings_tab`, a `--tab` and an older build's `SettingsReveal` keep working. The clickable
prototype is https://claude.ai/artifact/YNWBoNUScEawYE5PJiZAPA.

## 2026-10-05: The daily and weekly reports are cut (#298)

The owner cut the Opus reports on 2026-10-05. The timeline, the Today chart and the Weeks
calendar answer "where did the day go" without a second model, and the reports were most of the
bill (≈ $0.26 of ≈ $0.40 a day) and the only reason a second API key existed. Worklens now makes
one kind of model call, Gemini describing a frame.

What went: the report generator, its prompts, the Anthropic client, the scheduler's report half,
`worklens report`, the MCP `report` tool and the `days` report column, the report notifications
and menu row, the report reader on the Weeks page (now calendar-only), the Claude key in setup,
Settings and doctor, and the five report keys. Settings → Reports became Settings → Log, holding
Projects and "Learn from recent days"; the language picker moved to Capture. How it lands on an
existing install:

- **The five keys are retired, not deleted.** The Claude key and the report model, effort,
  time and weekly-day keys in an old `.env` are ignored, and `config-dump` names them as lines
  to delete; `ConfigKeys.swift` lists them as retired entries. `REPORT_LANGUAGE` keeps its name and now only sets
  the summaries' language.
- **Nothing is dropped.** The `reports` table and `DATA_DIR/reports` stay as they are, with no
  migration: they are the user's own writing. `DayTitle`, `DayHeadline.fromReport` and the
  `Report` model stay with them. `RETENTION_KEEP_REPORTS` keeps its name and now covers timelines.
- **Old ledger rows still decode.** The `LLMPurpose` report cases, the usage chart's Reports
  series and the Opus 5 price stay, so a day before the cut keeps its spend.
- **Two jobs lost their trigger.** The reader refreshed on a report landing; it now refreshes
  every 60 s. `ProjectCatalog.learn` ran after a daily report; it now runs in housekeeping, once
  per local day.

## 2026-10-05: The friction ledger and the cuts' dead code go (#299)

With the reports gone, the friction ledger had one writer left, a detector over the day's blocks,
and no page to show it on. #299 removed it — the detector, its store, the panel, `worklens
friction`, the MCP `friction` tool and the `what_am_i_repeating` prompt — together with the
`DATA_DIR/timeline/*.md` files, the Recent screenshots window, the menu-bar icon's hover text, the
#285 Slack and Gmail cleanup and the menu members nothing drew any more. The MCP server now lists
eight tools and four prompts. How it lands on an existing install:

- **Nothing is dropped.** The `friction_items` table stays, with no migration that drops it: an
  older build still reads it. `DataEraser` and `Retention` delete its rows by plain SQL, so
  erasing or ageing out a day still removes them.
- **Old timeline files stay until their day goes.** Nothing writes `DATA_DIR/timeline/` any more;
  the MCP `timeline` tool renders a day on demand. A file an older build wrote is removed when
  its day is erased or aged out, never before.
- **The Slack and Gmail cleanup has run.** Every install that launched a build since #285 has the
  `retired_sources_removed` flag set, so the code that ran once is gone. A `SLACK_USER_TOKEN` still
  in `settings.json` is read as a retired key and never sent anywhere.
## 2026-10-05: The eval harness, demo tooling and duplicate CLI commands are gone (#300)

Part of the core cut. The Python eval harness in `evals/` and its Swift exporter, the `demo` command
and `make demo`, `seed-fixtures`, `dev`, and the CLI commands that repeated a Settings page or a menu
item (`stats`, `costs`, `block`, `taxonomy`, `google`, `context`, `schedule`, the hidden `run`
subcommand, `describe-image`, `ax-snapshot`, `context-once`, `foreground-sessions`, `redact-check`)
were removed. The CLI keeps the stages a contributor or a script drives: `describe-pending` (with
`--fake` and `--dry-run`), `describe-one`, `capture-once`, `timeline --rebuild`, `search`,
`projects` and the setup and diagnostics commands. No table was dropped and no data file deleted:
an old `DATA_DIR/evals` folder stays until you remove it by hand.

## 2026-10-05: The distribution-era support kit is gone (#301)

Worklens has one user, who builds it from this checkout. The `doctor`, `diagnostics`,
`db-stats`, `export`, `data move` and `uninstall` commands, the About window, Help → "Report a problem…",
Settings → Advanced → Diagnostics, Usage's "Take it with you" and "Move…" rows and the footprint
row existed for strangers installing a release and filing bugs, and were removed. The key check
behind Settings → Connections → **Verify** stayed and moved to `Config/KeyProbe.swift`;
`make doctor-toolchain` and `scripts/doctor.sh` stayed. No table was dropped and no data file
deleted: the `app_permissions` row in `app_state` is simply no longer written.

## Things only the user can do

Settings → Connections checks the keys and the `claude_desktop_config.json` entry, and
Settings → Capture → Access shows the grants. Neither can *do* any of the steps below: every
grant, keychain entry and hand-edited file is the user's.

The six setup steps a user needs — `make dev-cert`, re-granting after the first signed build,
the monthly Screen Recording dialog, the billing-enabled Gemini project, the Google consent
screen and test-user list, the Granola Business plan — moved to
[docs/user/setup.md](user/setup.md#things-only-you-can-do) (#142). Edit them there; what is left
below is the owner's own to-do list and the reasons behind it.

- Upload `docs/media/social-preview.png` under the repository's **Settings → Social preview**
  (#152). The file is rendered by `make icon` from the same `WorklensMark` the app icon comes
  from, so it never drifts, but GitHub takes it only through that settings page and it does
  nothing at all while the repository is private — which it is today. Re-upload after any change
  to the mark; this is the one asset a `git push` does not publish.
- Remove the Worklens Slack app at [api.slack.com/apps](https://api.slack.com/apps), and, if you
  want it gone, the Gmail grant at
  [myaccount.google.com/permissions](https://myaccount.google.com/permissions) (#285). The first
  launch of a build without those sources deletes what they stored on this Mac and revokes the
  Slack token it saved; neither provider lets an app remove its own install or grant.
- The Granola key needs a Business plan, and there is no fallback: the local-cache reader was
  removed in #87 because current Granola versions ship `cache-v6.json.enc` and an encrypted
  `granola.db`, with no plaintext `cache-v3.json` left to read. Verified on the developer
  machine 2026-09-07.
- Delete the twelve keys #87 retired from `~/Library/Application Support/Worklens/.env` and from
  the checkout's `.env`. Nothing breaks if they stay — they are ignored — but the app warns at
  launch naming every one it still finds, which is the list to delete.
- The text-versus-image eval ran on 2026-09-09 (numbers in the "Accessibility first" entry).
  Re-run it after any change to the outline or to the describe modes: the app must have run under
  `CAPTURE_SOURCE=both` with `DELETE_SCREENSHOTS_AFTER_DESCRIBE=false` so the frames carry both
  artifacts, and the full recipe (three describe runs at ~100 frames, three judge runs at
  `--limit 20`) costs about $1.15.
- Grant **Full Disk Access** to Terminal (or to Claude.app, if the probe runs from a Claude Code
  session) for the duration of the #47 Screen Time investigation, run the probe
  (`git show 2147a4b:scripts/screentime-probe.py > /tmp/probe.py`, then
  `python3 /tmp/probe.py --date <yesterday>`), and revoke it afterwards. The
  stores (`knowledgeC.db`, `~/Library/Biome/streams`, the ScreenTimeAgent `RMAdminStore-*.sqlite`)
  are TCC-protected: without the grant every read fails with "Operation not permitted", so no
  agent can do this step. Done once on 2026-09-09 (findings above); the grant to Claude.app is
  still to be revoked.
- Grant **Accessibility** (System Settings → Privacy & Security → Accessibility) to whatever
  launches the binary: Terminal or iTerm for `worklens ax-snapshot` and for
  `swift run Worklens ax-snapshot`, Worklens.app for the app. TCC attributes the request to the
  launching app, and the grant is bound to the code signature, so an ad-hoc rebuild loses it —
  the same "Worklens Dev" certificate that keeps Screen Recording is what keeps this. The
  `worklens` symlink `make install` creates (#119) does not change this: it runs the installed
  app's own binary, but a process started from a shell is still attributed to the shell's app,
  so the installed bundle and a terminal need their grants separately.
- After `make install` (#119), re-grant **Screen Recording** and **Accessibility** to the copy in
  `/Applications` and relaunch once — the first grant of either only takes effect on the next
  launch. A grant made to a bundle at `<repo>/build/Worklens.app` does carry over, because both
  copies share one signature, but only while the certificate does; an ad-hoc build does not.
- **Confirm the write to `claude_desktop_config.json`, then quit and reopen Claude Desktop**
  (#140). The app no longer asks anyone to hand-edit that file: Settings → Integrations →
  Claude Desktop → **Install into Claude Desktop**, or `worklens mcp install`, copies the file
  aside with a timestamp, merges only `mcpServers.worklens` and writes it back atomically — with
  the path it resolved for itself, so there is no path to get wrong. What is still the user's:
  saying yes to that dialog, and quitting and reopening Claude Desktop, which reads the file only
  at launch. Worklens never quits it for them. Afterwards the card runs `initialize` +
  `tools/list` in process and reports "N tools ready, reading `DATA_DIR`", resolved the way
  the client will resolve it — no inherited environment, working directory `/` — so a server
  wired up against an empty database says so instead of answering cheerfully. When the app itself
  was launched with `WORKLENS_ENV_FILE` (which is what `scripts/update.sh` does), that path is
  pinned into the entry's `env`; otherwise `~/Library/Application Support/Worklens/.env` is the
  only layer the launched process will find, and `make install-env` is what puts it there. This
  supersedes the earlier claim here that only the user can edit that file — the user confirms it,
  the app performs it. `make setup` still prints the JSON for a client Worklens does not write
  (Cowork, Codex), as does `worklens mcp install --print`, and the user-facing page is
  `docs/user/claude-desktop.md`.
