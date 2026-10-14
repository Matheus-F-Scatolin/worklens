# Troubleshooting

Every symptom this page has an answer for, with the section that answers it:

| Symptom | Likely cause | Where |
|---|---|---|
| The menu-bar icon is red | today's budget is spent, or capture stopped | [the menu-bar icon is red](#the-menu-bar-icon-is-red) |
| I cannot find the menu-bar icon | the menu bar is full, or an item hider has it | [I cannot find the menu-bar icon](#i-cannot-find-the-menu-bar-icon) |
| Nothing is being captured at all | Screen Recording was lost or never granted | [nothing is being captured](#nothing-is-being-captured) |
| Frames are captured but none are described | no Gemini key, over budget, or the queue is behind | [frames pile up](#frames-pile-up-as-pending-or-over-budget) |
| Today's counts reset after a `make run` | a different `DATA_DIR` layer won | [today's counts reset](#todays-counts-reset-after-a-make-run) |
| The timeline says "Chrome" but never which page | the per-browser Automation grant | [only the browser, never the page](#the-timeline-says-chrome-but-never-which-page) |
| macOS asks for a permission again after a rebuild | the signature changed | [asked again after a rebuild](#macos-asks-for-a-permission-again-after-a-rebuild) |
| A keychain dialog on every new build | the per-build partition list | [keychain dialog](#a-keychain-dialog-on-every-new-build) |
| The menu has no **Update and restart…** item | the app cannot find its checkout | [no update item](#there-is-no-update-and-restart-item) |
| Worklens cannot update itself after I moved the source folder | the path is stamped in at build time | [the source folder moved](#worklens-cannot-update-itself-after-i-moved-the-source-folder) |
| Setup stopped at "Building Worklens stopped after …" | a compiler error, a toolchain mismatch, a full disk or no network | [the build stopped](#the-build-stopped-during-setup) |
| The update failed | read `build/update.log` | [the update failed](#the-update-failed) |
| The menu says the data directory is synced | `DATA_DIR` is inside a file provider's folder | [synced folder](#the-menu-says-the-data-directory-is-in-a-synced-folder) |
| Claude Desktop lists no Worklens tools | the `command` path in its config | [Claude Desktop](#claude-desktop-does-not-show-the-worklens-tools) |
| Every Worklens call in Claude says "Tool execution failed" | the server Claude started has gone | [every call fails](#every-worklens-call-in-claude-fails) |
| A notification with a blank or old icon | Notification Center's icon cache | [notification icon](#a-notification-with-a-blank-or-old-icon) |
| The timeline says Worklens was not running when it was | a second copy quit at launch and wrote a stray `stopped` | [not running when it was](#the-timeline-says-worklens-was-not-running-when-it-was) |

The rows about macOS dialogs — Screen Recording, Automation, the keychain prompt — are written
from the behaviour recorded in [PRIVACY.md](../../PRIVACY.md), the contributor notes and the code
that implements them, rather than by triggering each dialog again: re-triggering them resets
grants you would then have to approve a second time.

## Start here

The menu says what is wrong as it happens: a missing permission, a key that stopped working, a
describe queue that is behind. Settings → Capture has the permission rows, which are the only
place that can answer for `Worklens.app` itself — macOS reports a permission only to the process
that asks, so a terminal gets the terminal's grants. Settings → Connections shows whether each key
and each assistant works, and **Verify** asks the provider about a key. `worklens config-dump`
prints every setting and the file it came from.

## Nothing is being captured

The menu says so: **Screen Recording is off — Fix…**. macOS re-asks for that permission roughly
monthly, and if you miss the dialog capture stops *silently* — the API simply returns nothing.
Worklens notices within one tick, posts a notification, and retries every five minutes. Grant it,
then press **Relaunch Worklens**: the new answer only reaches a copy of the app that starts
afterwards.

A `worklens capture-once` at a terminal exits 3 with the same message for a different reason —
macOS grants Screen Recording to whatever *runs* the binary, so the terminal needs its own grant.
Neither grant counts for the other.

## Frames pile up as "pending" or "over budget"

*Pending* means the describer is behind; `worklens describe-pending` drains it. *Over budget*
means today's spend reached `DAILY_BUDGET_USD` — click **Allow $X more today…** in the menu (or
the same button in Settings → Usage) and those frames go back in the queue
([cost.md](cost.md#the-hard-stop)). Raising `DAILY_BUDGET_USD` itself only lifts the stop for
what comes next; the frames already skipped today are requeued by the button alone.

If the menu says **GEMINI_API_KEY is not set**, frames are being captured and kept but nothing is
describing them; [setup.md](setup.md#keys) says where the key comes from.

## The menu says the data directory is in a synced folder

Worklens will not capture into iCloud Drive, Dropbox, Google Drive, OneDrive or a network share,
because a file provider can sync a SQLite write-ahead log out from under an open database.
Reading, the MCP tools and `search` keep working. [data.md](data.md) explains it
and names the override.

## Claude Desktop does not show the Worklens tools

Almost always the `command` path in `claude_desktop_config.json`: the client launches it with a
minimal environment and no shell, so `~`, `$PATH` and the `worklens` symlink do not resolve. Use
the absolute path to the binary, quit and reopen the client, and let Settings → Connections check
the file for you ([claude-desktop.md](claude-desktop.md)).

## Every Worklens call in Claude fails

Claude Desktop lists the tools but answers every call, even `days`, with "Tool execution failed"
and nothing else. The tool list is the one it read when it started the server; the server
itself has gone, and Claude Desktop does not start it again on its own. Quit Claude Desktop (⌘Q)
and open it again. Before this was fixed, every update ended the server this way.

`~/Library/Logs/Claude/mcp-server-worklens.log` has one line per request the server answered. If
the failed calls are not in it, they never reached Worklens.

## A keychain dialog on every new build

Expected when you build from source and have connected Google — the cause is the per-build
partition list, and there are three ways out, all in
[the contributor notes](../contributing/signing.md#the-keychain-dialog-after-every-rebuild).


## A notification with a blank or old icon

Notification Center caches an app's icon per bundle identifier and keeps it for as long as that
daemon has been running, which on a Mac that is only ever slept means since the last restart.
So a banner can show an icon Worklens no longer has: the previous design after the icon
changes, or an empty white tile if one build ever launched without `AppIcon.icns`. The Finder
and System Settings → Notifications → Worklens show the right icon throughout, so nothing
points at the cause. Nothing in the app can clear it:

```bash
killall NotificationCenter usernoted
```

Both relaunch by themselves and the next banner has the current icon. `scripts/update.sh` runs
this for you whenever an update changes the icon, and `scripts/bundle.sh` refuses to assemble
an icon-less bundle, so a current checkout should not leave a Mac in this state.

If the old icon survives the restart, look for a second copy of the app: another
`Worklens.app` in `/Applications` or `~/Applications`, installed from a different checkout,
shares the bundle identifier, and updates from this checkout leave it alone. Reinstall it from
here with `make install`, or remove it.

## I cannot find the menu-bar icon

Nothing has gone wrong: macOS simply stops drawing status items when the menu bar runs out of
room, and on a laptop with a notch that happens sooner than you would think. An item hider such
as Bartender can also be holding it, and on two displays the item is only ever on the one with
the menu bar.

You have three ways back into the window, and none of them needs the icon:

- **Press ⌥⇧W, or open Worklens again** — from Spotlight, from `/Applications`, from the Dock.
  It does not start a second copy; the one already running brings its window to the front. The
  shortcut is Settings → General → Shortcuts, and you can record another there.
- **Turn on Settings → General → Keep Worklens in the Dock.** Worklens is in the Dock while one
  of its windows is open anyway; this keeps the icon after you close the last one, so a click on
  it always brings that window up, and Worklens stays in ⌘-Tab. It is off by default and
  you can turn it back off the moment the icon is findable again — no relaunch either way.
- **Run `worklens settings`** (or `worklens settings --tab capture` for one section) — the way
  straight to Settings in that window, where ⌘, also takes you once it is in front. From a
  checkout without installing, that is `swift run Worklens settings`, and from a built bundle
  `build/Worklens.app/Contents/MacOS/Worklens settings`. Like re-opening the app, it fronts the
  running copy rather than starting another one, and says so if nothing is running.

To make room in the menu bar itself, hold ⌘ and drag status items along it — that reorders them,
and dragging one off the bar removes it. Moving Worklens to the left of the crowd keeps it out of
the space the notch takes.

## The menu-bar icon is red

Two things turn it red, and the menu's first line says which.

Usually today's spend has reached `DAILY_BUDGET_USD`. Frames are still captured and kept, but
they queue as *over budget* and nothing is described until you click **Allow $X more today…** in
the menu, which raises the budget for today alone and puts those frames back in the queue
([cost.md](cost.md#the-hard-stop)).

The other is capture itself having stopped — Screen Recording lost, which drops the menu to a
single **Screen Recording is off — Fix…** line ([above](#nothing-is-being-captured)).

## Today's counts reset after a `make run`

Nothing was deleted: you are looking at a different data directory. Configuration resolves one
key at a time through the layers in [configuration.md](configuration.md#the-layers), and
`~/Library/Application Support/Worklens/.env` outranks the `.env` in a checkout — so an installed
app and a checkout can disagree about `DATA_DIR` without either of them being wrong.

```bash
worklens config-dump          # every key with the layer that supplied it, secrets masked
```

The `DATA_DIR` row names the file that won. To point an installed app at this checkout's data
instead, `make install-env` merges `./.env` into the Application Support one with `DATA_DIR`
pinned here.

## The timeline says "Chrome" but never which page

Reading the frontmost tab's URL is an Apple Events (Automation) grant, and macOS asks **per
browser**. Until one is allowed, its frames record the app and no page — which looks like
"Worklens only supports Chrome" when Chrome happens to be the browser you granted.

Ask for it from the menu's browser line (**Ask…**) or Settings → Capture → Access →
**Ask macOS for <browser>…**. Two timings are worth knowing: a probe is given 1.5 seconds to answer, and
a browser that fails is skipped for ten minutes so a refusal is not re-prompted every tick. The
backoff window ends the moment the browser is allowed, so a fresh grant takes effect on the next
frame rather than ten minutes later. `COLLECT_BROWSER_URL=false` turns the whole thing off and
the timeline keeps the app name.

## macOS asks for a permission again after a rebuild

TCC binds Screen Recording, Accessibility and Automation to the **code signature**, and an
ad-hoc build gets a new identity every time, so every build is a new app as far as macOS is
concerned. `make dev-cert` creates the "Worklens Dev" certificate once per Mac; builds signed
with it keep their grants. The first build signed with the new certificate still needs one more
grant and one relaunch — after that they stick.

The full account, including what to do when the grant is stuck, is in
[the contributor notes](../contributing/signing.md#keeping-screen-recording-permission-across-rebuilds).

## There is no **Update and restart…** item

That item appears only when the running app can find the checkout it was built from — the
absolute path stamped into the bundle at build time, or the checkout it still sits inside at
`<repo>/build/Worklens.app` — and only while that directory still contains `scripts/update.sh`
and `Package.swift`. A downloaded zip, or a checkout renamed, moved or deleted after the build,
gets no item and never polls GitHub at all.

Update by hand from the checkout instead:

```bash
make update
```

[The contributor notes](../contributing/updating.md) describe what that runs.

## Worklens cannot update itself after I moved the source folder

The path to the source is stamped into the app at build time, so Worklens looks for the folder it
was built from exactly where it was. Rename, move or delete that folder and the app can no longer
find it: **Update and restart…** disappears from the menu and it stops checking GitHub at all. The
one-line install puts the source at `~/Library/Application Support/Worklens/src` for this reason —
it is a folder nobody has a reason to drag somewhere else.

Nothing is lost. Your database, `.env` and screenshots live in
`~/Library/Application Support/Worklens` and are not in the source folder, so they are unaffected.

To get updating back, put the source where the app expects it and rebuild from there:

```bash
mv /wherever/you/moved/worklens "$HOME/Library/Application Support/Worklens/src"
cd "$HOME/Library/Application Support/Worklens/src" && make update
```

If you no longer have the folder, run the one-line install from
[the README](../../README.md#install) again: it clones the source fresh to that path and rebuilds
the installed app, leaving your data where it is.

## The build stopped during setup

`make setup` and the one-line install show the build as one line, and send everything the
compiler prints to `logs/build.log` in the data folder
(`~/Library/Application Support/Worklens/data/logs/build.log` unless you moved `DATA_DIR`; setup
prints the exact path). When the build stops, setup stops with it and prints the last error
lines, that log's path and a link to one of the sections below. Nothing after the build ran, and
running the same command again is safe: every step checks whether it already happened.

### SwiftUIMacros not found

`plugin for module 'SwiftUIMacros' not found` means a Command Line Tools update installed a
macOS SDK newer than the Swift beside it. `make build` already looks for an older SDK on disk
(`scripts/sdkroot.sh`) and uses it, so seeing this means there is none. Install the Command Line
Tools that match your macOS (`softwareupdate --list`), or Xcode, and run setup again.

### No space left on device

A first build needs a couple of gigabytes free for `.build`. Free some space and run setup again.

### The command line tools are broken

`xcrun: error: invalid active developer path`, or Swift or git that will not run although
`xcode-select -p` names a folder, usually follows a macOS update. The one-line install sees this
and asks macOS to install the tools again: answer Apple's dialog, and it carries on by itself.
From a checkout, run `xcode-select --install`, let it finish, and run setup again.

If you closed Apple's dialog, or the install waited an hour with no tools, nothing else was
changed: run the same line again when you are ready.

When macOS answers that the tools are already installed, they cannot be installed over the top:

1. Look in System Settings > General > Software Update for a Command Line Tools update, install
   it, and run the line again.
2. If `xcode-select -p` names an Xcode you have since deleted, `sudo xcode-select --reset` points
   it back at the command line tools. If it names an Xcode you still have, open Xcode once, or run
   `sudo xcodebuild -license`, to accept its license.
3. Otherwise remove the broken copy, `sudo rm -rf /Library/Developer/CommandLineTools`, and run
   the line again: it installs a fresh one.

The commands in 2 and 3 ask for your password, so they are yours to run; the install itself never
uses sudo.

### Swift could not download the packages

The first build downloads two Swift packages from GitHub. Check that you are online and that
`github.com` is reachable, then run setup again.

## The update failed

The menu's **Update and restart…** runs `scripts/update.sh --gui`, which logs every step to
`build/update.log` in the checkout and opens that log when a step fails. Read it first — the last
lines name the step. Running `make update` in the checkout re-runs the same steps in a terminal,
where the output is easier to follow, and
[the contributor notes](../contributing/updating.md#doing-that-by-itself) break the update into
the individual make targets so you can restart from the one that failed.

## The timeline says Worklens was not running when it was

Opening Worklens while it is already running starts a second copy that quits at once. In older
versions that copy wrote a "stopped" row on its way out, and the running copy's coverage
read as stopped until its next restart, sometimes for days, while it went on capturing. A day's
footer then says "not running" for hours you can see frames for.

Worklens now writes no "stopped" from a copy that never started, and it reads any frame or app
switch more than a minute after a "stopped" as proof that it was running, so the old stray rows
are overridden when the day is read. The footer is worked out each time a day is read, so past
days read right as soon as you update; there is nothing to rebuild.

The minute or two between the stray row and the next frame stays in the footer; that is the
grace that keeps a real quit from being erased by one late frame.
