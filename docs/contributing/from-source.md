# Building and running from a checkout

Moved out of the README in #127, unchanged. [CONTRIBUTING.md](../../CONTRIBUTING.md) has the
toolchain, the make targets and the conventions; this page is the parts that were in the README.

## Quick start from a checkout

```bash
make build bundle sign
open build/Worklens.app
```

That puts a small lens ring in the menu bar — its centre says what Worklens is doing, and
hovering it spells that out; the menu has a Quit item. There is no Dock icon
(`LSUIElement`) unless you turn on Settings → General → Show Worklens in the Dock (#147).
On its first launch the app finds no configuration, so it writes itself one at
`~/Library/Application Support/Worklens/.env`, keeps its data in
`~/Library/Application Support/Worklens/data`, and the menu says **Add your Gemini API key to get
started** over an **Open .env…** item. Put `GEMINI_API_KEY` in that
file, choose **Reload configuration**, and it is set up. Nothing else in the file has to change.

If anything here does not behave, `make doctor-toolchain` checks the build tools,
`worklens config-dump` prints the configuration layers and which one won, and
[docs/user/troubleshooting.md](../user/troubleshooting.md#start-here) covers the rest.

## Working on Worklens rather than just running it

Then keep the configuration in the checkout rather than in Application Support:

```bash
cp .env.example .env      # then add GEMINI_API_KEY
make run                  # launches the app against this checkout's .env
make install-env          # optional: a Finder or Spotlight launch reads this checkout too
```

`make run` hands the app this checkout's `.env` through `WORKLENS_ENV_FILE`, which a
Finder, Spotlight or login-item launch has no way to receive — it says so in a line, and
`make install-env` is what fixes it. That command *merges* this checkout's `.env` into
`~/Library/Application Support/Worklens/.env`: keys only the installed file sets are kept, keys
only this checkout sets are added, and a key the two disagree about is printed as a three-column
diff and left at the installed value until you pass `--force`. A key this checkout leaves blank —
`GEMINI_API_KEY=`, the shape `.env.example` ships — is not a value at all, so not even `--force`
can blank an installed key. `DATA_DIR` is pinned to this checkout's absolute path on the way in
and appended when the installed file sets none; when that file already names a different one the
pin is a disagreement like any other, kept until `--force` or `--data-dir`. Either way the path
the installed file ends on is printed. A relative `DATA_DIR` in either file means "next to that
file", since the app's own working directory is `/`. The installed file outranks every
checkout's `.env`, so if a value surprises you, `worklens config-dump` — or Settings → General →
Advanced, which shows the same thing — says which layer supplied it.
`scripts/install-env.sh --data-dir <path>` moves the pin, and `--no-pin` hands the data
directory back to the app's default. On a Mac that has run `make install-env`, `make run` opens
the installed app with no override at all rather than pointing it back at this checkout.

While `WORKLENS_ENV_FILE` is in play, the menu and Settings both show
`Dev override: reading <path>`, and Worklens records that path at
`~/Library/Application Support/Worklens/.launch-env` so "Update and restart…" puts the app back
on the same file instead of guessing.

## What `make install` and `make install-env` actually do

The make targets themselves are listed in [CONTRIBUTING.md](../../CONTRIBUTING.md#make-targets) —
one table, not three copies of one. The two paragraphs the README carried under it are these.

`make install` picks `/Applications` when it is writable and `~/Applications` otherwise, and
`/usr/local/bin` for the `worklens` symlink only when that directory already exists and is
writable — it is absent on a clean Apple-silicon Mac and creating it needs `sudo` — falling back
to `~/.local/bin` and printing the `PATH` line to add if it is not already there. `APPS_DIR` and
`BIN_DIR` override both, and `scripts/install.sh --dry-run` prints what it would do.

A bundled app does not inherit your shell's working directory, so it will not see `./.env`. It
does not need to — it reads `~/Library/Application Support/Worklens/.env`, writing a starter one
there if there is none. `make install-env` is what merges this checkout's into it, and the result
gets an absolute `DATA_DIR` — the checkout you ran it from, unless that file already names a
different one, which the command reports and keeps — because the file it writes outranks the
`.env` of every checkout on the machine. The path it ends on is printed either way. Nothing
already in that file is thrown away: a key the two set differently is listed in a three-column
diff and left alone unless `ARGS=--force` says otherwise, and a key blank in this checkout is
never written over a value the installed file has.
`make install-env ARGS="--data-dir <path>"` pins somewhere else; `ARGS=--no-pin` leaves the data
directory to the app.
A key you type into Settings → Models & cost → Accounts is not in that file at all (#124): it
lives in `settings.json` beside it, which `install-env` never reads or writes.

## Known limitations (Command Line Tools only)

This repo is developed on a machine with the Command Line Tools and no Xcode.app. Two
consequences, both visible in `Package.swift` and the `Makefile`:

- **Swift Testing needs explicit search paths.** The CLT toolchain ships `Testing.framework`
  under `$(xcode-select -p)/Library/Developer/` but does not put it on a package's search
  paths. Without `-Xswiftc -F …` SwiftPM builds the test bundle *without* the swift-testing
  entry point and plain `swift test` exits 0 having run nothing. `make test` adds the flags
  (and skips them on a machine with a full Xcode, where they are unnecessary).
- **The global pause hotkey is registered with Carbon, not `KeyboardShortcuts`.** That
  dependency's 3.x line uses SwiftUI's `@Entry` macro and the CLT toolchain ships no
  `SwiftUIMacros` plugin, so it could never be linked here. `RegisterEventHotKey`
  (`Sources/Worklens/App/GlobalHotkey.swift`) is 40 lines, is what every such library calls
  underneath, and needs no Accessibility permission — so the dependency is gone from
  `Package.swift` rather than pinned.

## Development

Two SwiftPM targets: `WorklensCore` (all logic, no SwiftUI, fully testable) and `Worklens`
(the SwiftUI menu-bar app plus the CLI). [CONTRIBUTING.md](../../CONTRIBUTING.md) has the toolchain,
the make targets, why the tests must be run with `make test` and not `swift test`, and the
privacy and voice conventions. [`docs/architecture.md`](../architecture.md) says where every type, table and config key
lives.

From a checkout you can run any CLI command without installing anything —
`swift run Worklens <command>`. That is a *different* binary from the app's: it is a debug build
with its own code signature, so macOS treats it as a separate application and its permissions are
its own. It says so once on stderr, and `make install` is the way out of that.

`.github/workflows/ci.yml` runs on every pull request: release build, `make test`, bundle,
ad-hoc sign, `codesign --verify` with an assertion that the Apple Events entitlement survived,
the version and `config-dump` subcommands with no configuration at all, and `swift-format` lint.
It uploads `build/Worklens.app` so a reviewer can run the change, and nothing else — never
`data/`, never a `.env`. A second job scans the full git history with gitleaks. What CI cannot do
is the part that needs a real Mac: a Developer ID signature, notarization, or whether TCC grants
survive a rebuild.

Each unit of work is specified by its GitHub issue (`gh issue view NN`). The 25 original
milestone specs the project was built from are GitHub issues #1–#25; the copies and the agent
prompts they were dispatched with live in git history.
