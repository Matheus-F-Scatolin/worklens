# Contributing to Worklens

Worklens is a personal optimization tool that happens to be open source: a macOS menu-bar app
that screenshots your own screen, describes each frame with a cheap vision model, and lays your
day out as a timeline. It is not a surveillance product, and the conventions below exist
mostly to keep it from drifting into one.

Issues and pull requests are welcome. Since this is one person's tool, the fastest way to get a
change merged is to open an issue first and agree on the shape of it.

## The toolchain

- **macOS 14 or later**, Apple silicon or Intel.
- **Swift 6.1+**. The reference machine has the **Command Line Tools only**, no `Xcode.app`
  (`xcode-select --install`). Everything below is written for that setup; a full Xcode works too
  and skips several of the workarounds.
- **SwiftPM, no Xcode project.** `Package.swift` is the whole build description. Do not add an
  `.xcodeproj`.

Copy `.env.example` to `.env` and add `GEMINI_API_KEY` before running the app. Never commit a `.env`. (An installed app needs no checkout: it writes its own `.env` under
`~/Library/Application Support/Worklens` on first launch and keeps its data beside it.)

You do not need the key to work on the pipeline: `worklens describe-pending --fake` runs the
describe stage with an offline fake provider, for $0. Point `DATA_DIR` at a scratch directory
first. Nothing in the configuration selects the fake — it is the flag or nothing.

## Make targets

These are all of them — `make help` prints the same list.

| Target | What it does |
|---|---|
| `make setup` | The whole first run on a new Mac, one consented step at a time (`SETUP_ARGS=--dry-run` prints it and changes nothing) |
| `make build` | Release build of the `Worklens` binary |
| `make dev` | Debug build |
| `make bundle` | Assemble `build/Worklens.app` from the release binary and stamp the build into its `Info.plist` |
| `make sign` | Codesign the app (the "Worklens Dev" certificate if present, ad-hoc otherwise) |
| `make dev-cert` | Create that certificate — once per Mac, asks for your login password |
| `make install` | Copy the app to `/Applications` and symlink `worklens` onto your `PATH` |
| `make uninstall` | Remove what setup put on this Mac and keep the data (`UNINSTALL_ARGS=--dry-run` prints the list; `--delete-data` deletes the data too) |
| `make run` | Launch the installed app if there is one, else `build/Worklens.app` |
| `make install-env` | Point an installed app at this checkout: `./.env` merged into `~/Library/Application Support/Worklens/.env` with `DATA_DIR` pinned here, keeping every key that file already sets unless `ARGS=--force` (optional — the app writes its own `.env` and uses Application Support when there is none) |
| `make update` | Pull, rebuild, re-sign, re-install and relaunch — what Settings → General → Updates' "Update and restart…" runs |
| `make test` | Run the test suite; `make test FILTER=<pattern>` runs a subset |
| `make format` | Rewrite `Sources` and `Tests` with `swift-format` |
| `make format-check` | Report formatting violations without changing anything |
| `make lint-strings` | Check the localization catalogs: `plutil -lint` on every `Resources/*.lproj`, and fail when a key the code asks for is missing from `en.lproj` |
| `make test-scripts` | Check `scripts/build-progress.sh` against captured builds, `scripts/bootstrap.sh`'s command line tools step against stand-in tools, `scripts/uninstall.sh` against a fake home with stubbed `security`, `tccutil` and `pkill`, and that every troubleshooting anchor they link to exists |
| `make check` | `format-check`, `lint-strings`, `lint-design`, `test-scripts`, then `test` |
| `make doctor-toolchain` | Check the build toolchain — `make build` runs these first and never fails on them |
| `make icon` | Re-render `Resources/AppIcon.icns`, the glyph previews and `docs/media/social-preview.png` from `WorklensMark.swift`; `ARGS=--banner` renders the social card alone. Uploading the card to the repository is the owner's step — see [docs/decisions.md](docs/decisions.md) → "Things only the user can do" |
| `make clean` | Remove build products |

`make check` fails today, and that is expected: 45 k lines of Swift predate `.swift-format`, so
`format-check` reports roughly 3 400 violations. Reformatting the tree is its own pull request —
a whole-repo `swift format -i` in the same commit as anything else buries that change — and CI's
lint step is `continue-on-error` until it lands. `make test` is the gate in the meantime.

### Run tests with `make test`, never bare `swift test`

On a Command Line Tools machine, `swift test` by itself is worse than useless: it prints "Build
complete!", runs nothing, and exits **0**. The CLT toolchain keeps Swift Testing in
`$(xcode-select -p)/Library/Developer/{Frameworks,usr/lib}` and does not put it on a package's
search paths, so SwiftPM builds the test bundle without the swift-testing entry point. Since the
September 2026 CLT it also keeps `libTestingMacros.dylib` in a `plugins/testing/` subdirectory
the compiler's default plugin search does not descend into, so `@Test` and `@Suite` fail to
expand. `make test` adds `-Xswiftc -F …`, `-Xswiftc -plugin-path …` and the matching rpaths, and
skips all of them where a full Xcode is installed.

A green run ends with a line like `Test run with 936 tests in 144 suites passed`. If you do not
see a count, the tests did not run.

### Other Command Line Tools traps

- **A CLT update can install an SDK newer than the Swift beside it, and then nothing UI builds.**
  When `SDKs/MacOSX.sdk` points at a macOS 27 SDK while `swift -version` still reports
  `arm64-apple-macosx26.0`, every `@State` fails with `plugin for module 'SwiftUIMacros' not
  found` — SDK 27's SwiftUI declares those as macros and that Swift ships no
  `libSwiftUIMacros.dylib`. `scripts/sdkroot.sh` spots the mismatch and names the older SDK
  still on disk; the `Makefile` and `scripts/update.sh` both consult it, so `make build`,
  `make test` and Settings → General → Updates' "Update and restart…" work unattended. Setting `SDKROOT` yourself
  always wins, and on a matched toolchain the script prints nothing. The real fix is a
  toolchain whose Swift matches its SDK.
- **The hardened runtime needs an Apple Events entitlement to talk to a browser.** `make sign`
  passes `--options runtime` so TCC grants survive a rebuild, and that flag refuses every Apple
  event unless the signature carries `com.apple.security.automation.apple-events`
  (`Resources/Worklens.entitlements`). Keep that file free of XML comments: codesign parses it
  with AMFI's reader, which fails with `AMFIUnserializeXML: syntax error`.
- **The global hotkey uses Carbon `RegisterEventHotKey`, not a library.** `KeyboardShortcuts` 3.x
  needs SwiftUI's `@Entry` macro and the CLT ships no `SwiftUIMacros` plugin, so it could never be
  linked here. See `Sources/Worklens/App/GlobalHotkey.swift`.
- **`pkill`/`pgrep` skip their own ancestors.** BSD `pgrep -f` excludes the calling process and
  everything above it, so a script the app itself launches cannot see the app without `-a`.

## The shape of the code

- **Two targets, and the split is load-bearing.** `WorklensCore` holds all the logic, imports no
  SwiftUI, and is fully testable. `Worklens` is the SwiftUI menu-bar app plus the CLI. If you find
  yourself testing something by launching the app, it probably belongs in `WorklensCore`.
- **Swift 5 language mode** (`swiftLanguageModes: [.v5]` in `Package.swift`). Use `actor` for
  services with shared mutable state and `@MainActor` for anything touching AppKit or SwiftUI.
- **No SPM resources.** `Bundle.module` is unreliable in a hand-built `.app`, so seed data is
  embedded as Swift string constants.
- **Every LLM call goes through `LLMCallLedger`** (tokens and USD). Model IDs and prices live in
  one place, `ModelPricing`.
- **The model client sits behind a protocol**, `VisionDescriber`, for describing a frame. It
  names itself, and what it names itself is what lands in `llm_calls.provider`. `FakeDescriber`
  is the offline one.
- **Tests never touch the network.** Not once, not behind a flag.
- **One CLI subcommand per file**: `Sources/Worklens/CLI/<Name>Command.swift`, plus one line in
  `WorklensCLI.subcommands`.
- **Configuration has one registry.** `Sources/WorklensCore/Config/ConfigKeys.swift` is where
  every key list derives from; grep there rather than reading `.env.example`.
- Shared types live where `docs/architecture.md` → "Shared building blocks" says they do.

## Add a language

The interface is localizable; **the English sentence is the key** (#161). `swift test` and
`swift run` load no `.lproj` at all — see "No SPM resources" above — so a lookup that misses has
to produce correct English, and it does: the key is the English, and the helper repeats it as the
fallback value.

Write new interface copy through one of four shapes, and one literal on one line — a sentence
split with `+` is invisible to `scripts/strings-extract.sh` and therefore to every translator:

| Target | Shape |
|---|---|
| `Worklens` (SwiftUI, alerts, notifications) | `String(localized: "Capture now", comment: "Button")` |
| `WorklensCore` (no SwiftUI to import) | `L10n.string("Stopped")` |
| …with a hole in it | `L10n.format("Paused until %@", clock)` |
| …a counted noun | `L10n.plural(count: n, one: "Today: %lld screenshot", other: "Today: %lld screenshots")` |

A bare literal in a `TableColumn`, `DatePicker`, `.alert`, `Picker` or `TextField` is a
`LocalizedStringKey`, so it *is* looked up at render time — but the extractor never saw it, so the
key reached no catalog and the row was translated only by accident, when another pane happened to
add the same sentence. `TableColumn(`, `DatePicker(` and `.alert(` are read now, which makes
`make lint-strings` fail on the bare form: wrap it in `String(localized:)` like everything else.

Then:

1. `scripts/strings-extract.sh --strings > Resources/en.lproj/Localizable.strings` regenerates the
   English catalog (English on both sides — it exists to be copied and linted, not to translate).
   A plural is added by hand to `Resources/en.lproj/Localizable.stringsdict`, keyed by its English
   `other` string.
2. `cp -R Resources/en.lproj Resources/pt-BR.lproj` (or whichever language code) and translate the
   right-hand sides. A partial catalog is fine and normal: a key you leave out falls back to
   English, one row at a time. `Resources/pt-BR.lproj` is deliberately partial today — the
   popover, the status and counts lines, the spoken menu-bar label and the notifications.
3. `make lint-strings` — `plutil -lint` on every catalog, plus a failure for any key the code asks
   for that `en.lproj` does not have, plus a failure for a translated value whose format
   specifiers do not match English's (`L10n.format` hands the value straight to `String(format:)`,
   so a dropped `%@` loses the clock and a `%lld` translated as `%@` crashes the menu; reorder
   only with positional `%1$@` markers), plus a warning for a translated key the code dropped.
4. `make bundle` copies `Resources/*.lproj` into the app before `scripts/sign.sh` runs. Adding a
   resource after signing invalidates the signature, so never copy one in afterwards.
5. To try it: `defaults write dev.worklens.app AppleLanguages '(pt-BR)'`, relaunch, and
   `defaults delete dev.worklens.app AppleLanguages` when you are done.

**What stays English:** timeline text, model prompts, log messages, CLI output and every
value written to the database — and nothing else. Every window is localizable, the welcome pages
and the reader's empty states included; a paragraph left as a plain constant
beside a wrapped heading is the half-translated pane this whole mechanism exists to avoid.
 Those are read by models, by golden fixtures and by whoever is
debugging, and a translated one would change a timeline's meaning or a test's outcome. Most of them
are English by construction; the CLI is the one that needs care, because the installed `worklens`
is a symlink into the app bundle, so `Bundle.main` there is that bundle and the catalogs *are*
loaded. Print the stable spelling — a `rawValue`, a slug — never a localized `title`.
`REPORT_LANGUAGE` is the separate setting that tells the describe model which language to
*write* each summary in; localization decides which language the *interface* is in. The two are not the same knob.

## Privacy and voice conventions

These are not style preferences; they are what makes this a tool you would run on your own
machine.

- **Never log screenshot contents, window titles, URLs or API keys at `info` level or above.**
- **Prompts and everything written about your day address the user as "you".** Not "the user", not third person.
- **Every other string a person reads follows [`docs/copy.md`](docs/copy.md)** — one noun per
  concept (a *screenshot*, never a "frame"), one verb per action (*Delete*, never "erase" or
  "purge"), Settings copy one sentence plus a `Learn more…` link, and no number, clock or date
  formatted by hand: `Format` (`WorklensCore/Util/Format.swift`) is the only place those become
  words. Display strings only — renaming a column value or a `--json` key breaks the schema.
- **No scores, rankings, grades or comparisons** — not between days, not against anyone else.
  Worklens describes where your time went; it does not judge it.
- Anything that changes what is captured, kept, or sent must be reflected in `PRIVACY.md` in the
  same pull request.
- **A new network destination is a new row in `PRIVACY.md`'s "What leaves your machine" table** —
  what is sent, when, how to turn it off, and the file that implements it.
  `NetworkDestinationsDocTests` scans `Sources/` for URL literals and for `git` subcommands that
  reach a remote, and fails the build when one has no row.

## Continuous integration

`.github/workflows/ci.yml` runs on pushes to `main` and on every pull request, on `macos-15`
with the newest Xcode the runner image carries (asserted to be Swift 6.1+, because `Package.swift`
is `swift-tools-version:6.1` and because `swift-format`'s output differs between toolchains).
It is deliberately the same commands you run locally: `swift build -c release`, `make test`,
`make bundle`, `SIGN_IDENTITY=- make sign`, then `codesign --verify --strict` plus an assertion
that the Apple Events entitlement survived the signature, the bundled binary's `version`, a
`config-dump` with an empty environment, and `make format-check`.

Three things worth knowing:

- **The runner is the only machine that takes the other branch of the Swift Testing workaround.**
  `SWIFT_TEST_FLAGS` is added only where the Command Line Tools keep `Testing.framework`, which a
  full Xcode does not — so until CI existed, the full-Xcode path had never been run at all.
- **CI signs ad-hoc and cannot do better.** There is no Apple Developer account, so no Developer
  ID signature and no notarization. Both branches of `scripts/sign.sh` pass `--options runtime`
  and the same entitlements, so the hardened-runtime flags *are* exercised; what is not is whether
  TCC grants survive a rebuild, which needs a real signing identity on a real Mac.
- **The artifact is `build/Worklens.app` and nothing else.** Never `data/`, never a `.env`, never
  `~/Library/Application Support/Worklens/`. The `config-dump` step is safe to print because
  `ConfigDumpCommand` masks every secret.

A second job scans the full git history with gitleaks. `.gitleaks.toml` allowlists by path —
`Tests/`, and `evals/tests/`, `docs/history/` and `docs/reviews/`, which are deleted but still in
the history that job scans — never by key string, so a real
credential that happened to start like a fixture one is still caught. The history is clean: a
full scan on 2026-09-12 (117 commits, gitleaks 8.30.1) found nothing with or without that
allowlist. Dependabot opens monthly grouped pull requests for SwiftPM and GitHub
Actions; the gitleaks version is pinned in the workflow and bumped by hand.

## Pull requests

- **One issue per pull request.** Keep changes small and surgical; a refactor that rides along
  with a fix makes both harder to review.
- `make test` green, with the count visible in the PR description.
- Update `docs/architecture.md` in the same PR when you add a config key or a table.
- A new config key is one `ConfigKey` entry plus its `Config` property. Regenerate the example
  file with `swift run Worklens config-example > .env.example` rather than editing it by hand —
  a test compares the two.
- Update `CHANGELOG.md` under `## [Unreleased]` when the change is visible to someone running the
  app.
- Fill in the checklist in `.github/PULL_REQUEST_TEMPLATE.md`, including the privacy line.

## Where things are documented

| You need | Read |
|---|---|
| Principles, stack, build order | `docs/PLAN.md` |
| Where a type, table or config key lives; wiring; CLI conventions | `docs/architecture.md` |
| The exact Gemini request and response shapes | `docs/api-shapes.md` |
| Why a decision was made; the cost model; milestones | `docs/decisions.md` |
| The words a user reads, and how numbers and dates are formatted | `docs/copy.md` |
| How the app shell wires a stack together | `docs/wiring/*.md` |
| What the app records and what it never records | `PRIVACY.md` |
| What a *user* needs: install, keys, cost, the first day, the CLI | `docs/user/*.md` |
| Building from a checkout, updating, code signing and the Keychain | `docs/contributing/*.md` |
| The original milestone specs (#1–#25) | GitHub issues #1–#25, and git history |

If you are working through an AI coding agent, `CLAUDE.md` has the session hygiene rules for this
repository and points back here for everything else.

## Code of conduct

By participating you agree to the [Code of Conduct](CODE_OF_CONDUCT.md).
