# Setting Worklens up

Worklens is built from source: there is no signed download, because this project has no Apple
Developer ID and an unsigned zip would be stopped by Gatekeeper and would lose its Screen
Recording grant on every rebuild anyway. Building it is one command.

## Requirements

- macOS 14 or later (Apple silicon or Intel)
- A Swift 6.1+ toolchain — Xcode, or the Command Line Tools: `xcode-select --install`
- A Gemini API key — [keys](#keys)

## Things only you can do

Six steps in a Worklens setup cannot be done for you — they are grants, accounts and keychain
entries that belong to your Mac and your provider accounts. None of them can be automated.

| Step | Why it is yours | When |
|---|---|---|
| Run `make dev-cert` once and answer both prompts (your login password, then one macOS authentication for the trust setting) | it writes to your login keychain and changes a certificate's trust settings | before the first build, so Screen Recording and Accessibility survive rebuilds — [signing.md](../contributing/signing.md) |
| Grant **Screen Recording** and **Accessibility** again after the first certificate-signed build, and after `make install` | the signature changed, so macOS sees a new app; the first grant only reaches a copy that starts afterwards | once, then relaunch |
| Approve the monthly "continue to allow screen recording" dialog | only you can answer a macOS dialog, and missing it stops capture silently | roughly monthly — [permissions.md](permissions.md) |
| Put the Gemini key on a **paid, billing-enabled** project | on the free tier Google may train on your prompts and images | when you create the key — [keys](#keys) |
| Approve the Google consent screen (**Connect** in Settings → Connections) and keep yourself on the OAuth client's **test users** list while the screen is in testing | it is your Google account and your OAuth client | only if you connect Calendar — [integrations](integrations.md) |
| Confirm your Granola plan allows personal API keys (Business plan) | Granola issues the key to you, and encrypts its own on-disk cache, so there is no fallback | only if you connect Granola — [integrations](integrations.md) |

## Install

One line, on a Mac that has never seen Worklens:

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Matheus-F-Scatolin/worklens/main/scripts/bootstrap.sh)"
```

It checks macOS and the Swift toolchain first — if the command line tools are missing it says to
run `xcode-select --install` and stops, downloading nothing on your behalf. Then it names every
write in one block and waits for a single yes:

```
Worklens will:
  • download its source to ~/Library/Application Support/Worklens/src
  • build it (a few minutes the first time, shown as one progress line)
  • create a certificate in your login keychain, so macOS remembers your permissions
  • install Worklens to /Applications
  • put a `worklens` command on your PATH
  • open Worklens, which starts on its welcome window
Continue? [y/N]
```

After that it hands over to `make setup`. The build, the long part, is one line that keeps
moving, counted from Swift's own build steps:

```
Building Worklens · 212 of 480 · 1:42
```

The second number can grow while Swift works out what to build; the first never goes back.
Everything the compiler prints goes to the data folder's `logs/build.log`
(`~/Library/Application Support/Worklens/data/logs/build.log` unless you set `DATA_DIR`; setup
prints the exact path) instead of your terminal, and that file is replaced on every run. If the build stops, setup stops with it and prints the last error
lines, the log's path and the section of [troubleshooting](troubleshooting.md) for what went
wrong; fix that and run the line again. Piped into a file or run by another program, the line
becomes plain lines, one at every tenth of the way.

It ends by opening Worklens on its welcome window and printing the two things only you can do:
allow Screen Recording, and paste your Gemini key. Or look around the sample week first, no key
needed.

Two things worth knowing about that path:

- **The source folder is fixed, and moving it breaks updating.** An installed Worklens finds the
  checkout it was built from by the absolute path stamped into the bundle at build time, so a
  folder that is renamed, moved or deleted leaves the app with no **Update and restart…** item
  ever again — [troubleshooting](troubleshooting.md#worklens-cannot-update-itself-after-i-moved-the-source-folder).
  `~/Library/Application Support/Worklens/src` is chosen because nobody has a reason to drag it
  somewhere else.
- **Your data never moves into it.** The app keeps its `.env`, its database and its screenshots in
  `~/Library/Application Support/Worklens`, beside that folder and not inside it. The unattended
  path deliberately declines `make install-env`, the step that would pin `DATA_DIR` to the
  checkout — see [Configuration](#configuration).

Re-running the line is supported and is how you recover from a failure: an existing checkout at
that path is updated with `git pull --ff-only`, never replaced, and every step below it checks
whether it has already happened. A directory that is there but is not a Worklens checkout stops
the script with a sentence and is left alone. To read the plan before any of it happens, add
`-- --dry-run` to the same line — it prints every step, asks nothing and changes nothing:

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Matheus-F-Scatolin/worklens/main/scripts/bootstrap.sh)" -- --dry-run
```

### Install with Claude Code

Paste the repository link into [Claude Code](https://claude.com/claude-code) and ask it to set
Worklens up:

```text
Set up Worklens on this Mac: https://github.com/Matheus-F-Scatolin/worklens
Follow the "If someone asks you to install Worklens" section of its CLAUDE.md.
```

That section of [CLAUDE.md](../../CLAUDE.md) tells it what to run and what not to do. It runs the
dry run and shows you the plan, and runs the line itself with `--yes` only after you say yes in
the chat, since it has no terminal to ask you on. It never asks for your Gemini key or puts one in
a file, and it does not answer macOS dialogs or grant permissions: the certificate's
authentication prompt, Screen Recording and the key stay yours, as they are on the line above.

### A checkout of your own

Already have a checkout of your own, or planning to change Worklens? Clone where you like and
run setup there instead — the one-line path leaves your checkout untouched, and only the app
built from the fixed path updates from it:

```bash
git clone https://github.com/Matheus-F-Scatolin/worklens.git
cd worklens
make setup
```

`make setup` checks the toolchain, offers the self-signed certificate that keeps macOS
permissions across rebuilds, builds and signs the app, copies it to `/Applications` with a
`worklens` command on your `PATH`, and launches it. Every step says what it is about to do and
waits for an answer, every step is also its own make target, and re-running it after a failure or
a `git pull` is the supported way to use it. `make setup SETUP_ARGS=--dry-run` prints the whole
sequence and changes nothing.

By hand, that is:

```bash
make dev-cert             # once per Mac — see ../contributing/signing.md
make build bundle sign
make install              # /Applications/Worklens.app, plus `worklens` on PATH
make run
```

`make install` symlinks `worklens` to the installed app's own binary, so the command and the
menu bar are the same signed release build reading the same database. What it does **not** do is
share permissions: macOS attributes a process launched from a shell to the shell's application,
so `worklens capture-once` asks for Screen Recording on its own account even though the bytes are
identical. That is a macOS rule, not a Worklens one.

Running it out of the checkout instead — `make build bundle sign && open build/Worklens.app` — is
[in the contributor notes](../contributing/from-source.md), along with what to do if you are
working on Worklens rather than only running it.

## The first launch

The first time Worklens starts it opens a welcome window and captures nothing until you finish
it. Six pages:

1. **Light or dark.** Three cards, **Light**, **Dark** and **System** (which follows your Mac),
   with Light ringed: a new install starts in light. Clicking a card switches Worklens to it at
   once and goes on; the arrow keys move the ring and Return picks it. Settings → General →
   **Appearance** changes it later.
2. **What Worklens does** — what it records, where it stays and what you get, in three lines,
   with the whole of what it records and never records one disclosure away.
3. **See a sample week.** **Take the tour** opens Worklens over a week of made-up days and points
   at each part of it, one card at a time; when it ends, the window comes back on the next page.
   The tour is part of setting up, so this page has no **Skip**. Once you have taken it, the page
   also has **Continue**, so going **Back** to it never means taking the tour twice.
4. **Screen Recording**, which macOS only hands to a copy of Worklens that starts *after* you
   allow it, so the page offers to relaunch. **Skip for now** leaves it for later; the menu keeps
   offering the grant.
5. **Your key.** The Gemini key is the one Worklens needs — it is what describes your screen —
   and **Continue** waits for it. **I'll add the key later** skips the page entirely.
6. **Ready.** One click adds Worklens to Claude Desktop, and **Open Worklens** opens the window
   your days are read in. Accessibility and browser access are optional and live in
   Settings → Capture → Access. **Done** closes the window, and that is what starts capture: until
   you press it nothing is recorded.

The menu offers **Finish setting up Worklens** while Screen Recording, the Gemini key or the
window itself is outstanding — three things. Settings
→ Advanced → **Show welcome again** re-opens the window whenever you like. An install that was
already running is never shown it.

After **Done**, the first screenshot Worklens summarizes is the proof that capture, Screen
Recording and the Gemini key all work, and one notification says so in its own words: "Your
day has started." with that first summary quoted underneath, for example *Worklens summarized
your first screenshot: "Edits setup.sh in VS Code." Click to open the Today page.* Clicking it
opens the Today page. It is posted once per install and only if notifications are on. The
quote is the summary stored on your timeline, never read from the window's title or address,
and a summary that names a web address, or one the model marked sensitive, is not quoted. An install that was already running never
gets it. If the first summary fails instead (a rejected key, the day's budget, no Screen
Recording), there is no notification: the menu's status line says what is wrong, as it always
does.

## Keys

Worklens uses one model and you pay Google directly. There is no Worklens account and no key of
ours in the middle.

| Key | What it is for | Where to get it |
|---|---|---|
| `GEMINI_API_KEY` | Gemini 3.5 Flash-Lite describes each frame | <https://aistudio.google.com/apikey> → create a key **in a billing-enabled project** |

> **Use a billing-enabled Gemini project.** On Google's free tier your prompts and images may be
> used to improve their models. On a paid project they are not.

Put it in `~/Library/Application Support/Worklens/.env` — the app writes that file itself on
first launch, and the menu's **Open .env…** item opens it — then choose **Reload configuration**.
Nothing else in the file has to change. What the model costs is in [cost.md](cost.md).

If anything does not behave, [troubleshooting.md](troubleshooting.md#start-here) says where to
look first.

## Configuration

The Gemini key can be typed in the app, and everything else comes from `.env` and the settings
file, resolved one key at a time through six layers. The order, the CLI that reads and writes
them, and why `DATA_DIR` is the one key Worklens never writes for itself, are in
[configuration.md](configuration.md).
