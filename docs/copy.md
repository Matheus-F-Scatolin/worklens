# How Worklens talks

Every word a person reads (a menu row, a button, a Settings sentence, a notification, an alert,
the text a CLI command prints) follows this page. It is the written form of a rule
`CONTRIBUTING.md` already states in one line: *prompts and everything written about your day
address the user as "you"*.

It governs **display strings only**. Database column values (`describe_status`, `skip_reason`),
enum raw values, configuration keys, JSON keys in `--json` output, file names and log lines are
machine-readable and are named for the machine. Renaming one of those breaks the schema, a script,
or a fixture; renaming a sentence breaks nothing.

## The voice

- **No em dashes and no en dashes, anywhere.** Not in a label, a notice, a CLI line, a prompt or a
  translation. Use a colon, a comma, parentheses or a new sentence; an empty cell says `none`,
  `n/a` or `0m`. A range takes a plain hyphen (`09:00-10:30`, `21-27 September`), and two ISO dates
  take `to` (`2026-09-17 to 2026-09-23`). Model output goes through `NoEmDash` on its way to disk
  and to the reader; a range Foundation formatted goes through `NoEmDash.range`.
- **Second person.** "Nothing is being captured until 14:30", not "the user has paused capture".
- **Worklens is never "I".** The app has a name; use it, or use no subject at all. "Worklens could
  not read `2026-09-40` as a date", never "that is not a date I can read".
- **No scores, grades, rankings or comparisons**, not between days, not against anyone. Worklens
  says where your time went; it does not say how you did.
- **Week-over-week facts are allowed; verdicts are not.** A weekly may say what changed as two
  numbers and the day pattern behind them, never a percentage framed as improvement or decline,
  never a week called good, bad, better or worse, never a verdict on you.
- **State the fact, then the remedy.** "Screen Recording is off: nothing is being captured.
  Allow it in System Settings, then relaunch." Not the other way round, and never the remedy alone.
- **Say what is optional.** A grant Worklens runs happily without is introduced as optional in the
  same sentence that asks for it.
- **Never name a file, a window title, a URL or a key in a sentence that would land in a log.**
  Privacy rules outrank all of the above.

## One noun per concept

| Say | Never | Why |
|---|---|---|
| **screenshot** | frame, capture (as a noun), image | "Frame" is the database's word and the code's word. Nobody outside the repository knows it. |
| **summary**, *summarized* | description, described, describe (to a user) | The user sees one sentence about a screenshot. That is a summary. |
| **timeline** | activity log, history | |
| **project** | tag, label | |
| **budget** | spend limit, cap | |
| **waiting** | pending, queued | A screenshot with no summary yet is *waiting*. |
| **on hold** | held, skipped, over-budget (as a state of a screenshot) | A screenshot the budget stopped is *on hold*: it is still there, and a raise releases it. |
| **shipped** | wins, deliverables, productivity, output (to a user) | A PR merged or closed, an issue opened or closed, a review submitted, a company memo published or updated: a fact with a time, never a measure of you. Counts stay per kind and are never summed. |
| **document** | artifact, resource key (to a user) | A Google file, a GitHub PR or issue, or a local file a screenshot showed (#319). `byDocument` is the field; the person reads "document". |
| **your minutes** / **agent minutes** | time saved, leverage, multiplier, agent time as yours | Your minutes are the windows around prompts you typed; agent minutes are when an agent was working (#321). They are always printed side by side and never added together or divided into a ratio. |
| **day**, **week** | period, range | `period` is a parameter name, not a word for a person. |

"Over budget" stays a statement about the **day**, not about a screenshot: `$1.62 of $1.50: over
budget` is right; "12 over budget" is not.

## One verb per action

| Action | The verb | Never |
|---|---|---|
| Start or restart capture | **Capture** / **Resume** | Begin, Enable, Turn on |
| Stop capture for a while | **Pause** | Stop, Suspend, Disable |
| Remove data for good | **Delete** | Erase, Purge, Wipe, Clear |
| Fetch from an integration | **Sync** | Refresh, Pull, Update |
| Attach or detach an account | **Connect** / **Disconnect** | Link, Authorize, Sign in |
| Raise a macOS permission dialog | **Ask macOS for …** | Grant, Request access, Authorize |
| Let something through | **Allow** | Grant, Permit, Whitelist |

One name per action everywhere it appears: the item in the popover, the button in Settings, the
sentence in the alert that confirms it, and the notice that says it is done.

## Shapes

- **Menu and popover items are verb-first** and say what clicking them does: `Open Worklens`,
  not `Worklens`. An item that spends money says roughly how much.
- **A disabled item carries its reason**, `Syncing integrations: this comes back when that
  finishes.`, never a greyed-out row with nothing to read.
- **Status rows are one clause, about 40 characters.** They are read at a glance, beside an icon.
- **A pause says what it is waiting for, never the arithmetic behind it.** Four clauses and no
  others: `Paused until you resume` with no end, `Paused until tomorrow` at midnight,
  `Paused · 12 minutes left` when it ends inside the hour, and `Paused until 14:30` beyond that,
  where the time of day is the easier fact to hold.
- **What a screen reader is handed is written for speech, not for the eye.** `iconLabel` and
  `spokenTally` are sentences with commas and the word for every number; the interpunct rows
  beside them are for a glance and read aloud as punctuation.
- **Settings body copy is one sentence of 20 words or fewer**, plus a `Learn more…` link to the
  page in `docs/user/` that has the rest. A paragraph in a footer is a paragraph nobody reads. The
  same rule retires the maintainer's voice: how TCC caches a grant per code signature belongs in
  `docs/user/permissions.md`, not under a toggle.
- **Alerts name the thing and the number**: `Delete 143 screenshots from 1 - 7 Sep?` The confirming
  button repeats the verb, `Delete`, and never says `OK`.
- **Sentence case everywhere**, including buttons and section headers. An ellipsis (`…`) means a
  dialog or another window follows; nothing else takes one.
- **No configuration key and no filename is the explanation of record.** A sentence the user
  reads says what the setting does; `SCREENSHOT_DISK_BUDGET_GB` and `docs/decisions.md` are not
  that sentence. Since #286 a key name appears in exactly one place in Settings (Advanced's
  "Every value and where it comes from" table) and in no tooltip, and the page goes behind
  `Learn more…`. A build command appears in one place only, the foot of Advanced, beside a
  button that copies it, and only in a checkout. `scripts/design-lint.sh` fails on the rest.
- **An icon-only button always carries a spoken label.** A `.help()` tooltip is not read to
  anybody: a `Button` whose whole label is an `Image(systemName:)` takes an
  `.accessibilityLabel` naming the action ("Remove from the blocklist", "Forget this project")
  and keeps the tooltip as well. `scripts/design-lint.sh` fails on the rest.

## Numbers, money, clocks and dates

Never format one by hand. `Format` (`Sources/WorklensCore/Util/Format.swift`) is the only place
money, clocks, short dates, day names and the capture cadence become words, and it takes the
locale as an argument:

- Anything a **person reads on screen** passes `.autoupdatingCurrent`, so a Mac set to Portuguese
  (Brazil) reads `US$ 0,27 de US$ 1,50` and a Mac set to 12-hour time reads `2:05 PM`.
- Anything that lands in a **file, a prompt, a fixture or a pipe** keeps `Format.fixed`
  (`en_US_POSIX`): the timeline, the stats markdown, the spend CSV, the ledger log, and the CLI's
  own output, which is grepped and parsed. A decimal comma in a timeline changes what it says.

Money is always dollars, wherever the user is: Worklens is billed in dollars, so `US$` is the
right symbol abroad and `R$` would be a lie.

## When in doubt

Read the string out loud to someone who has never seen the code. If you have to explain a word,
it is the wrong word.
