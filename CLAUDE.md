# Worklens — notes for AI coding agents

Worklens is a macOS menu-bar app (Swift, SwiftPM, no Xcode project) that screenshots the
user's own screen, describes frames with Gemini 3.5 Flash-Lite, and lays each day out as a
timeline. It is a personal optimization tool, not surveillance.
Each GitHub issue is the spec for one unit of work.

**Read [CONTRIBUTING.md](CONTRIBUTING.md) once, at the start of a session that will touch code.**
It has the toolchain, the make targets, the Command Line Tools traps, the two-target rule and the
privacy and voice conventions — everything a human contributor needs, which is everything you
need too. This file is only the part that is specific to working through an agent session.

## If someone asks you to install Worklens

They pasted the repository link and said *set it up*, or something like it. You may be reading
this from GitHub before any clone exists; that is expected. Installing touches no code, so skip
CONTRIBUTING.md and the rest of this file.

**What to run.** Pick one, then follow the steps below for it.

- No checkout yet (the usual case): the one-line install. It clones into
  `~/Library/Application Support/Worklens/src`, the folder the app updates itself from.
  ```bash
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Matheus-F-Scatolin/worklens/main/scripts/bootstrap.sh)" -- --dry-run
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Matheus-F-Scatolin/worklens/main/scripts/bootstrap.sh)" -- --yes
  ```
- Already inside a Worklens checkout (there is a `Package.swift` and `scripts/setup.sh`):
  `make setup SETUP_ARGS="--dry-run --yes"`, then `make setup SETUP_ARGS=--yes`.

**The steps.**

1. Run the dry run first and show the person its plan: what is downloaded, built, put in their
   login keychain, copied to `/Applications` and put on their `PATH`. Run the real command only
   after they say yes in chat. `--yes` stands in for the one question the script would have
   asked them on a terminal, so it is their answer, not yours.
2. Before the real run, tell them what they will see on their screen during it: a macOS
   authentication dialog to trust the "Worklens Dev" certificate, and maybe a keychain dialog
   when the app is signed (**Always Allow**). Those are theirs to answer.
3. Run the real command in the background and read its output as it goes. A first install
   clones, resolves packages, builds from clean and then waits on the dialogs above, which can
   take longer than a 10-minute foreground timeout on a slower Mac or while the person reads a
   dialog. Off a terminal it prints a plain progress line at every tenth of the way. If you can
   only run it in the foreground and it times out, run the same command again: it is safe, and
   it picks up where the last one stopped.
4. If it fails, the script prints the last error lines, the path of the whole build log and a
   `docs/user/troubleshooting.md` section. Read those, say what went wrong in a sentence, and
   offer to run it again. Re-running is safe: every step checks whether it already happened.
5. When it finishes, Worklens is open on its welcome window. Pass on the script's last block,
   *What is left for you*, and stop there.

**Never do these.**

- Never ask for, echo or paste an API key in chat. The Gemini key goes into the welcome window
  (or Settings → Connections) by the person's own hand, never through you.
- Never write a real key into any `.env`, and do not edit `.env` files at all for an install.
- Never grant a permission, answer a macOS dialog or click anything in System Settings for the
  person: Screen Recording, Accessibility, Automation, the keychain and the certificate trust
  prompt are all theirs.
- Never run `make install-env` or set `DATA_DIR`; the installed app keeps its data in
  `~/Library/Application Support/Worklens` on its own.
- Do not create an `AGENTS.md` or any other file in the checkout. An untracked file there makes
  the app's **Update and restart…** skip its `git pull`.
- No `sudo`. Nothing in the install needs it; if a step seems to, stop and say so.

**The person's own steps**, which you name and leave to them:

- Allowing **Screen Recording** when macOS asks, then **Relaunch Worklens** in the welcome window.
- Creating a Gemini key at <https://aistudio.google.com/apikey> on a paid, billing-enabled project
  and pasting it into the welcome window. Or looking around the sample week first: it needs no key.
- Optionally, adding Worklens to Claude Desktop: quit Claude Desktop first (while it is open it
  puts its old settings back), then **Connect** on the welcome window's last page, then open
  Claude Desktop again. If this session runs inside Claude Desktop, quitting it ends the session,
  so leave this step for last and say so.

## Where things are documented (open only the one you need)

| You need | Read |
|---|---|
| Toolchain, make targets, conventions, privacy and voice rules | `CONTRIBUTING.md` |
| Principles, stack, build order | `docs/PLAN.md` (a short index) |
| The words a user reads: vocabulary, copy shapes, how numbers and dates are formatted | `docs/copy.md` |
| Where a type, table or config key lives; wiring; CLI convention | `docs/architecture.md` |
| The exact Gemini request and response shapes | `docs/api-shapes.md` |
| Why a decision was made; cost model; milestones; user-only steps | `docs/decisions.md` |
| How the app shell wires a stack together | `docs/wiring/*.md` |
| What a *user* needs: install, permissions, configuration, cost, integrations | `docs/user/index.md` (the index), then the one page it names |
| A symptom the app or the CLI is showing | `docs/user/troubleshooting.md`, whose anchors `HelpLink` names |

## Keep the session small

Sessions in this repo have bloated on whole-file dumps, raw screenshots and re-reading the
plan. `python3 scripts/session-audit.py` shows where a session's context went.

- Orient with `scripts/outline.sh <file>` (declarations with line numbers, ~2 k chars) or
  `Grep`, then `Read` with `offset`/`limit`. Never `cat` a whole `.swift` file, and never
  several files in one Bash call. `Sources/Worklens/App/AppModel.swift` (148 k chars) is the
  worst offender.
- Filter build output: `swift build 2>&1 | grep -E 'error|warning:' | head -40`; tests:
  `make test 2>&1 | tail -30`.
- Screenshots: `scripts/shot-small.sh <in.png>` first (800 px JPEG, ~50 KB instead of
  ~500 KB), then `Read` the small file once.
- Config keys: grep `Sources/WorklensCore/Config/ConfigKeys.swift`, the one registry every key
  list derives from; do not re-read `.env.example` or `Package.swift` to remember them.
- One session per issue (worktrees already do this); `/compact` after a milestone.

## The three facts worth repeating

Everything else is in `CONTRIBUTING.md`; these are the ones that quietly ruin a session.

- **`make test`, never bare `swift test`.** On this machine `swift test` prints "Build complete!",
  runs nothing and exits **0**. A run that does not end in a test count did not happen.
- **`WorklensCore` holds the logic, `Worklens` holds SwiftUI and the CLI.** If something is hard
  to test, it is probably on the wrong side of that line.
- **Never log screenshot contents, window titles, URLs or API keys at `info` or above**, and keep
  everything written about the day in the second person with no scores or comparisons.

## Verified external API shapes

Do not re-derive these from memory; they were checked live on 2026-09-07 and are quoted in
`docs/api-shapes.md`: Gemini `generateContent` (camelCase `generationConfig`, `thinkingConfig.thinkingLevel`,
`mediaResolution`, `responseJsonSchema`).
