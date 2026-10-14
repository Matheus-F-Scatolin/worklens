# Your first day with Worklens

What actually happens, in the order it happens. Nothing here needs watching: the interesting part
is the day itself, which fills in on its own while you work.

## Minute 0 — the welcome window

`make setup` finishes by launching the app: a small lens ring appears in the menu bar, and on a
first launch a welcome window opens in front of it. Worklens shows up in the Dock and in ⌘-Tab while one of its
windows is open, and lives only in the menu bar once you close the last one. Clicking the ring opens the menu,
whose first line says what Worklens is doing.

Find the ring now, while the menu bar is the only thing you are looking at. macOS stops drawing
status items when the bar is full, and on a laptop with a notch the items that do not fit simply
disappear — so hold ⌘ and drag the ring along the menu bar to somewhere you will find it again,
to the left of the crowd. If it does go missing, press ⌥⇧W or open Worklens again — either
brings its window to the front — and
[troubleshooting.md](troubleshooting.md#i-cannot-find-the-menu-bar-icon) has the other two ways
back in.

The window is six pages in the order they happen: light or dark, what Worklens does, a sample
week, Screen Recording, your keys, and where your days show up. The first page is three cards:
**Light**, **Dark** and **System** (which follows your Mac), with Light already ringed, because a
new install starts in light. Click a card and Worklens switches to it at once and goes on to the
next page; the arrow keys move the ring and Return picks the ringed card. You can change it any
time in Settings → General → **Appearance**. The third page is [the tour](#the-tour),
before macOS is asked for anything: a small drawing of the sample week and one button, **Take the
tour**, which opens Worklens over a week of made-up days. It takes about a minute, there is no
Skip on this page, and when the tour ends the welcome window comes back on the Screen Recording
page. If you go **Back** to the tour page after that, it also has **Continue**. The tour is not
one of the things setup counts, so the menu's count below stays the same three steps. Worklens does not start capturing on its own:
nothing is recorded until you press **Done** on the last page, and the rest of this page is what
happens after you do.

While the window is unfinished the menu carries **Finish setting up Worklens (2 of 3)**, which
re-opens it; afterwards, Settings → Advanced → **Show welcome again** does. The three are Screen
Recording, the Gemini key and finishing the window. An install that was already running
before this version was never shown the window and kept capturing as it was.

The Gemini key is pasted on the window's fifth page — the same field and masked display as
Settings → Connections, the key checked as it is pasted — and [setup.md](setup.md#keys) says where
it comes from. If you skip the page, the menu says **Add your Gemini API key to get started** over an **Open .env…** item once setup
is finished; that file is `~/Library/Application Support/Worklens/.env`, and **Reload
configuration** picks up what you paste into it.

## Minute 1 — granting Screen Recording

Worklens never asks for Screen Recording on its own. Press **Ask macOS for Screen Recording…** on
the welcome window's fourth page (the menu and Settings → Capture → Access have the same button) and
macOS shows its own dialog. Asking is also what puts Worklens *into* the System Settings list —
macOS lists an app there once it has requested the permission, not before.

The grant reaches a copy of Worklens that starts afterwards, so press **Relaunch Worklens** when
it asks. The welcome window comes back to the page you were on, with one line at the top saying
what happened — *Screen Recording is on — carry on.*, or *Screen Recording is still off.* if the
answer did not take. Anything you had already typed, a key included, is still there. Settings →
Advanced → **Show welcome again** is the other way in, and that one starts from the first page.

Worklens never asks for Notifications here. It offers them the first time one would be worth
reading — the first time Screen Recording goes, say — and Settings
→ Capture → Access has **Ask macOS for notifications…** if you would rather answer now.

Once you have reached the last page and pressed **Done**, the menu's top two lines start saying
so:

```
Capturing · every 60 s
2h 05m active · 45m in meetings · $0.02 of $1.50
```

Those two lines are the whole status. The first says what Worklens is doing and how often; the
second is today so far — time on screen, time in meetings, and today's spend against
`DAILY_BUDGET_USD`. Settings → General's status line says what, if anything, needs you.
[glossary.md](glossary.md) defines each of those words.

Two optional things are worth doing now: **Ask macOS for <browser>…** in Settings → Capture →
Access, so the timeline
can say *which* page rather than "Chrome", and Settings → General → **Shortcuts**, where the two
shortcuts live. **Pause or resume** is `⌥⇧P` and **Open Worklens** is `⌥⇧W` out of
the box — both shown with the letters your own keyboard layout puts on those keys, both work from
any app, and either can be re-recorded. A combination another app already owns is said so in its
own row rather than failing quietly. Nothing is captured while paused, and Worklens comes back
from a restart or an update *still paused*.

### The sample week, until your first moment arrives

Until Worklens has summarized a screenshot of yours, the Worklens window opens on a **sample
week**: all of last week (five full workdays and a light weekend) and this week up to today,
all invented, drawn by the same Today and Weeks pages your own days
use. A ribbon across the top says so, and its second line says what happens next: "Your first
moments show up in about a minute.", or the one thing in the way (Screen Recording, the Gemini
key, a pause, capture stopped, the day's budget). **Leave sample week** goes back to your own
days, and the sample does not come back on its own after that.

The sample lives in its own file under `sample-week/` in the data directory, and nothing but
that window reads it: Claude over MCP, the `worklens` commands, search, spend, retention, deletes
and exports only ever see your own ledger. When your first screenshot is summarized, the window
fades over to your real Today and one notification says "Your day has started." and quotes
that first summary, so you can see what Worklens saw without opening anything (only if
notifications are on; nothing else reminds you). Clicking it opens the Today page. That happens
once ever. Settings → Advanced →
**Show sample week** opens it again whenever you want to look around; it is rebuilt for today
each time and stays until you leave it.

## During the day — states you may see

The menu is one line of status, one tally, and at most one row asking to be fixed:

- **Capturing.** The two lines above, and nothing else. This is the normal state.
- **Paused.** You pressed the shortcut or the menu item. A banner said so, and Worklens reminds
  you every `PAUSE_REMINDER_HOURS` (4) that it is still paused, and the menu's first row becomes
  **Resume**. A pause with an end draws its own icon and counts down —
  `Paused · 12 minutes left` — so a pause that comes back by itself never looks like one that
  stays off until you say otherwise.
- **Working.** A thin arc joins whatever the icon was already showing while anything you set
  going — a sync, a reload, a deletion — is still running, and leaves when it finishes. It is a
  treatment over the state, not a state of its own: a paused Worklens that is syncing still reads
  as paused. Nothing in the menu bar animates.
- **Needs attention.** A single row such as "Screen Recording is off — Fix…", which does the fix
  when you click it. macOS re-asks for Screen Recording roughly monthly and capture stops
  *silently* if you miss it, so Worklens notices within a tick, posts one notification, and
  retries every five minutes until it is capturing again. A configuration or data-folder fault
  takes the same slot as a submenu, with the two or three answers that fault has.
- **Over budget.** The status line says `Budget reached — screenshots on hold`. Screenshots are
  still being taken, they are just not being described until the budget is raised
  ([cost.md](cost.md#the-hard-stop)).

**Open Worklens** (⌘O in the menu, or `⌥⇧W` from any app, or a click on the Dock tile while it is
there) opens the window where you read your days. It has two pages, one icon each down its left
edge. **Today** is the day so far as one chart: the time each app had on screen, the time in
meetings, and what that adds up to. **Weeks** is the week as a grid of what you worked on, half
an hour at a time. ← and → (or ⌘← and ⌘→) step to the day or the week before and after. Nothing in this window
calls a model, and an open page keeps itself up to date about once a minute.

## The tour

The tour is seven cards over the Worklens window, each beside the one thing it explains, with the
rest of the window dimmed: the day's chart on Today, its biggest app bar opened up with what you
were doing in that app, the **Weeks** button on the left (a calendar), the Weeks page, the pause
shortcut and **Delete** (drawn as key caps, with the shortcut you actually have), asking Claude about your day,
and the ring in the menu bar. The tour never changes page for you: the third card cuts out the
**Weeks** button, draws a terracotta ring round it that pulses until you click it (it stays still
under Reduce Motion), and goes on by itself once your week shows (if the
button cannot be found, the card has **Next** instead). Early in the week the Weeks card shows
last week, so it always lands on a week with at least four whole days. The last card hangs under
the ring itself;
if macOS is not drawing the ring (the notch, or a full menu bar), it says how to get back in
instead and links
[troubleshooting.md](troubleshooting.md#i-cannot-find-the-menu-bar-icon).

→ or Return goes on and ← goes back; VoiceOver reads each card as it arrives. From the welcome
window the tour has no **Skip** and Esc does nothing, though **Back** always works. Settings →
Advanced → **Take the tour again** runs it whenever you like, and that run has **Skip** and Esc
skips it. Worklens remembers that you finished it (or closed its window part-way), and never
starts it on its own.

## Tomorrow — a whole day behind you

Today and Weeks draw yesterday as a chart and a grid, and the MCP `timeline` tool hands it to
Claude as plain Markdown. From there on nothing needs doing. If you want to ask about
a specific day, that happens in Claude Desktop over `worklens mcp`
([claude-desktop.md](claude-desktop.md)).
