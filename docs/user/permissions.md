# Permissions macOS will ask for

| Permission | Why | When |
|---|---|---|
| Screen Recording | taking the screenshots that Worklens describes | when you press **Ask macOS for Screen Recording…** — in the menu, or in Settings → Capture → Access |
| Automation (Apple Events) | reading the frontmost browser tab URL so the timeline can say *which* page, not just "Chrome" — turn it off with `COLLECT_BROWSER_URL=false` | when you press **Ask macOS for <browser>…** in Settings → Capture → Access |
| Notifications | one banner per Screen Recording outage, and a few others: the daily budget reached, a pause that ended, summaries that stopped | the first time one of those two would have been worth reading, or when you press **Ask macOS for notifications…** in Settings → Capture → Access. macOS asks once |

Nothing is asked for by a capture tick. Asking is also what puts Worklens *in* the System
Settings list — macOS lists an app under Screen Recording or Automation once it has requested the
permission, not before — which is why the button asks rather than opening a pane you are not yet
listed in. The first grant reaches a copy of Worklens that starts afterwards, so allow it and
press **Relaunch Worklens**.

macOS also re-asks for Screen Recording roughly monthly, and if you miss it capture stops
**silently** — the API just returns nothing. Worklens notices within one tick, drops the menu to
a single "Screen Recording is off — Fix…" line, posts a notification you can click to open the
right pane, retries every five minutes, and tells you when it is capturing again. On a Mac that
has never granted it, the same line and the same notification say *not on yet* instead of *lost*.

## Notifications

Worklens asks for these at the first moment a banner pays off, and at no other: the first time
Screen Recording goes while it is capturing, or the first other banner worth reading. It never asks at
launch, never while the welcome window is open, and never twice — macOS answers a second request
without showing anything, so a second ask would only lose the banner that prompted it.

To answer before then, press **Ask macOS for notifications…** in Settings → Capture → Access. To
change an answer you have already given, open System Settings → Notifications → Worklens; the
Access card's **Open System Settings** button goes straight there. Saying no costs you nothing you
need: an outage drops the menu to its single "Screen Recording is off — Fix…" line either way.

## Accessibility

Optional, and asked for the same way. With it Worklens reads the focused window's text, so the
timeline names the document rather than only the app; a secure text field — a password box — is
never read. Without it nothing else changes.

All three grants are bound by macOS to the app's **code signature**, not to its path. Rebuild
Worklens and the new binary looks like a different app, so every grant you had is gone and has to
be given again. That is the usual reason a permission that worked yesterday is suddenly missing;
[asked again after a rebuild](troubleshooting.md#macos-asks-for-a-permission-again-after-a-rebuild)
has the rest.
