# Glossary

The words Worklens uses about your own day, in the places it uses them: the menu's counts line,
the timeline file and the CLI.

**Frame** — one captured moment. A timestamp, the frontmost app, the window title, optionally the
browser tab URL, the focused window's text, and a JPEG *only* when that text did not already
cover what was on screen. Frames are taken every `CAPTURE_INTERVAL_SECONDS` (60), and one that
looks the same as the last one is dropped rather than described. The menu counts them:
`Today: 128 frames`.

**Described** — a frame the vision model has already turned into a sentence or two, stored beside
it. `121 described` in the counts line. The description, not the picture, is what the timeline is
written from.

**Pending** — captured but not described yet, usually because the queue is a few seconds behind.
`3 pending`. `worklens describe-pending` drains it from a terminal.

**Over budget** — captured, and deliberately *not* described because today's spend has reached
`DAILY_BUDGET_USD`. `7 over budget`, and the counts line turns red. Nothing is lost: click
**Allow $X more today…** in the menu and those frames go back in the queue ([cost.md](cost.md)).

**Paused** — nothing is captured at all. `⌥⇧P` from any app, or the menu item. The pause survives
a quit, a crash and an auto-update, and Worklens reminds you every `PAUSE_REMINDER_HOURS` that it
is still on.

**Blocked** — a moment that matched one of the three blocklists (`BLOCKED_BUNDLE_IDS`,
`BLOCKED_TITLE_PATTERNS`, `BLOCKED_URL_HOSTS`). The app name and the reason are recorded so the
day's time still adds up; the title, the URL and the image are not.

**Block** — a run of consecutive frames that were the same kind of work, one row in
`activity_blocks` and one paragraph in the timeline: an app, a task label, a start, an end and a
summary. Blocks are what the day is made of; frames are only their raw material.

**Timeline** — the day as plain text, built from its blocks when asked for: the `timeline`
tool over `worklens mcp` returns it, and `worklens timeline --date YYYY-MM-DD --rebuild`
rebuilds a past day's blocks. It is the most direct answer to "what does Worklens actually have about me":
everything the numbers are built from is in there, in order. Since 2026-10-05 nothing writes it
to `data/timeline/`; files an older version left there stay until the day is erased or aged out.

**Task label** — the `task_key` on a block (`coding`, `reading_code`, `forms_admin`, …), chosen
by the describer from a fixed list.

**Taxonomy** — that fixed list, `taxonomy.json`: the apps Worklens knows and the task labels each
one may be doing. It is **hand-edited and frozen** — #86 removed the learning loop, so nothing
Worklens sees adds to it or changes it behind your back. An update may add apps Worklens now
ships, once, and moves your past frames of those apps to their new labels (Codex and Worklens
got their own labels; cmux joined Terminal); it never removes or renames anything you have,
and an app you delete afterwards stays deleted.

**Context event** — something from outside the screen that you connected: a meeting from Calendar
or Granola. Only your own activity, only from the sources you turned on, and a body is cut at 400 characters before it can reach a prompt; a Granola meeting also lists the next steps and decisions from its full summary — full
meeting transcripts never do. See [integrations.md](integrations.md).

**Unexplained time** — minutes of your day that nothing on record accounts for: no block, no
frame or lock that still held, no foreground session, no meeting, and no pause, quit or missing
permission. The `accounting` that the `stats` and `span` tools return puts every minute of the day
in one bucket, and this is the bucket for the rest. It is a fact about the record, not about you:
a closed lid before Worklens recorded sleep, or the hours before you first opened the laptop, land
here. See [claude-desktop.md](claude-desktop.md).
