# The install rehearsal

`make rehearse` lets you go through a new person's first install on your own Mac without
touching your real Worklens. It installs a second app, **Worklens Rehearsal**, walks you through
its welcome window one step at a time, and writes down what passed and what did not.

## A second app, not a second copy

The rehearsal is the same binary under its own bundle identifier, `dev.worklens.rehearsal`.
The binary reads that identifier back (`AppIdentity`, in `WorklensCore/Config/AppIdentity.swift`)
and takes every name that ties an install to this Mac from it:

| | Worklens | Worklens Rehearsal |
|---|---|---|
| App | `/Applications/Worklens.app` | `/Applications/Worklens Rehearsal.app` |
| Bundle identifier | `dev.worklens.app` | `dev.worklens.rehearsal` |
| Folder | `~/Library/Application Support/Worklens` | `~/Library/Application Support/Worklens Rehearsal` |
| Command | `worklens` | `worklens-rehearsal` |
| Keychain items | `dev.worklens.*` | `dev.worklens.rehearsal.*` |
| MCP entry | `worklens` | `worklens-rehearsal` |

Because macOS keys Screen Recording, notifications, preferences and Launch Services on the
bundle identifier, the rehearsal asks for everything again, like a new install does, and its
answers are its own. Both apps can run at once; each takes its own lock.

The identity comes only from the running bundle, never from the environment or a `.env`.
`swift run`, the tests and anything unbundled are the real app, exactly as before. The
rehearsal refuses a `DATA_DIR` inside the real app's folder, whatever a file says, and its
**Update and restart…** is off: it never pulls or builds from the real app's `src`. Run
`make rehearse` again for a newer build.

## What is real and what is simulated

| Step | In the rehearsal |
|---|---|
| The download (`bootstrap.sh` cloning into Application Support) | Simulated: it builds this checkout as it is, uncommitted changes included |
| Apple's command line tools install | Simulated when they are already there, which they are on a Mac that builds Worklens |
| The "Worklens Dev" certificate | Real, and shared: the rehearsal reuses yours |
| Build, bundle, sign, install, the command on your `PATH` | Real, under the rehearsal's names |
| The welcome window, Screen Recording, Relaunch | Real |
| Connect for your Claude or ChatGPT plan | Real: the same signed-in `claude` and `codex` commands as the real app |
| Screenshots and summaries | Real: it captures your screen, and summaries count against your plan's usage |
| Claude Desktop | Real, as `worklens-rehearsal`; `worklens` is never touched |
| Notifications | Real, as their own app in System Settings |

The rehearsal never signs in for you and never reads the `claude` or `codex` credentials:
`claude auth login` and `codex login` are yours to run.

## Running it

```bash
make rehearse REHEARSE_ARGS=--dry-run   # the whole plan, nothing done
make rehearse                           # the real thing
```

It runs `scripts/setup.sh --rehearsal`, which is the same flow a new person sees, then a
numbered checklist: the welcome window, the sample week, Screen Recording and Relaunch, how
Worklens summarizes, Connect for each plan (`worklens-rehearsal summaries check` before and
after), the first screenshots, their summaries (`worklens-rehearsal describe-pending --provider
claude --limit 3`), the timeline, Claude Desktop, notifications, and a last check that the real
`worklens` command and Claude Desktop entry are as they were. You answer each step pass, fail or
skip, with a note if you like. The report lands in
`~/Library/Application Support/Worklens Rehearsal/rehearsals/<date-time>.md`.

`REHEARSE_ARGS=--skip-setup` goes straight to the checklist when the rehearsal app is already
installed. Claude Desktop puts its old settings back while it is open: quit it, press Connect,
then open it again. If you run the rehearsal from inside Claude Desktop, quitting it ends that
session, so leave that step for last.

## Cleaning up

```bash
make rehearse-clean                              # what it would remove
make rehearse-clean REHEARSE_CLEAN_ARGS=--yes    # remove it
make rehearse-clean REHEARSE_CLEAN_ARGS="--yes --all"   # the reports too
```

It quits the rehearsal app and removes `Worklens Rehearsal.app` (installed and in `build/`), the
`worklens-rehearsal` command, the rehearsal's folder (its reports stay unless `--all`), its
keychain item, Launch Services registration, preferences and caches, its Screen Recording,
Accessibility and Automation answers, and its Claude Desktop entry while Claude Desktop is
closed. A Claude Code or Codex entry it names for you to remove with their own commands.

## The guard

Every rehearsal script passes each path, link and identifier it is about to use through
`wl_guard` in `scripts/app-identity.sh`. Anything that is the real app's (`Worklens.app`,
`~/Library/Application Support/Worklens`, the `worklens` command, `dev.worklens.app`) stops the
script before it does anything. One case worth knowing: a checkout inside
`~/Library/Application Support/Worklens/src`, the one the one-line install makes, cannot run the
rehearsal, because its `build/` is inside the real app's folder. Rehearse from another checkout.
`scripts/rehearse-test.sh` (part of `make test-scripts`) holds all of this to a fake home.
