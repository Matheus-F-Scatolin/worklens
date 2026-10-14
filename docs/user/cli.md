# The Worklens command line

Moved out of the README in #127; tidied in #158.

The same binary is the CLI, which is how every pipeline stage gets tested headlessly. After
`make install` it is on your `PATH` as `worklens`; from a checkout without installing, the same
commands are `swift run Worklens …`, which builds and runs a *different*, debug-signed binary and
says so once on stderr.

`worklens --help` lists the subcommands in three groups — **Everyday**, **Setup and
integrations** and **Diagnostics** — rather than as one flat alphabet.

The CLI keeps what MCP, setup and the app's own scripts need (#300). Everything else is a page in
the app or an MCP tool: Settings → Usage for costs, Settings → Privacy for the block lists,
Settings → Connections for Google Calendar and Granola, and the MCP `stats` tool for a day's
numbers.

```bash
worklens --help
worklens version                              # --json for {version, commit, pr, builtAt, dirty}
worklens config-dump                          # resolved config: value, source layer, secrets masked

worklens app                                  # launch the menu-bar app (installed Worklens.app only)
worklens capture-once --out frame.png         # one screenshot; --display main|mouse
worklens settings [--tab capture]             # front the running app's window on Settings

worklens describe-pending --dry-run           # print the exact prompt for the next frame, call nothing
worklens describe-pending --fake              # describe with the offline fake: no key, no network, $0
worklens describe-one 4812                    # describe one capture by id, whatever its state

worklens projects list --json                 # the canonical project list
worklens projects kind acme company           # mark a project house, company, side or none
worklens projects learn --dry-run             # what learning would add, companies from meetings included
worklens projects merge company:acme.com acme # acme.com's meetings now count toward acme
worklens projects forget company:acme.com     # acme.com's meetings stop counting toward anything
worklens projects check --dry-run             # count the house screenshots a check would re-ask
worklens projects coverage [--from --to]      # the last 14 complete days by default: minutes with a project, the rest by reason, next to each frame alone; counts only, never a name
worklens projects rule add --domain acme.com --project acme --dry-run   # the minutes and days a rule would move, then run it without --dry-run; --repo owner/repo and --url-prefix work the same, and a --repo rule also moves that repo's agent minutes, which the preview does not count
worklens projects rule list [--json]          # every rule and assignment, with each assignment's id
worklens projects rule remove --domain acme.com   # or --assignment <id>; --dry-run shows what moves back
worklens projects assign --from 2026-10-06T14:00 --to 2026-10-06T15:30 --project acme --dry-run   # local time, or add an offset; only screen and meeting minutes move, never idle, locked or asleep ones
worklens shipped [--from --to --project]      # what you shipped on GitHub; --json for counts and rows
worklens shipped sync [--days 30]             # ask gh now instead of waiting for the next sync; with MEMO_REPOS set, also reads your merged PRs there for company memos and prints memo counts
worklens shipped forget                       # delete the shipped ledger
worklens agents [--from --to --repo]          # your Claude Code and Codex sessions per repo; --json for rows
worklens agents sync [--days 30]              # read the agents' logs now instead of waiting for the next sync
worklens agents forget                        # delete what was read from them
worklens search invoice                       # find frames by the text that was on screen
worklens timeline --date=-3 --rebuild         # rebuild a past day's activity blocks for the Week page

worklens mcp                                  # MCP server on stdio, for Claude Desktop
worklens mcp install [--print]                # add it to Claude Desktop's configuration
```

## Days and exit codes

Every `--date` takes `YYYY-MM-DD`, `today`, `yesterday`, or `-N` for N days back. A negative number has to be
written with an `=` — `--date=-3`, not `--date -3` — because a bare `-3` looks like an option. A
day the calendar does not have is refused rather than quietly rolled forward.

Failures are numbered, so a script can tell a typo from a broken run:

| Exit | Meaning |
|---|---|
| 0 | success |
| 1 | the run failed — a model call, the database, an unwritable file |
| 3 | macOS has not granted a permission, or `DATA_DIR` is somewhere Worklens will not write |
| 4 | the configuration is unusable |
| 64 | the command line was wrong |

Anything but 64 prints one `error:` line on stderr; 64 prints the command's usage block, because
that is the case where the usage block helps.

## `app`, and the old `run`

`worklens app` launches the menu bar. A bare `worklens run` still opens it too, so nothing in an
alias or a login item breaks, but it is not a subcommand and `--help` does not list it. The
headless scheduler (formerly `run --headless`) was removed in #300: the app
is the one capture loop.

`worklens app` refuses to run from a checkout build (`swift run Worklens app`, `.build/debug`) and
tells you to use `make run` instead. That binary is not Worklens.app: it has no `Info.plist`, so a
Dock icon appears and the browser-URL probe has no automation permission, and macOS ties every
Screen Recording and Accessibility grant to the signature, so none of the real app's grants apply
to it.

`timeline --rebuild` is the one way to repair a day older than yesterday: the app rebuilds only
today and yesterday at launch, and the Week page draws whatever activity blocks a day has.

`settings` never starts a second Worklens: it asks the copy that is already running to bring its
window to the front on Settings, and says so when none is. `--tab` names the section to open on:
`general`, `capture`, `privacy`, `projects`, `connections`, `usage` or `advanced`. It is the developer's way back in when
the menu-bar icon cannot be found — for everyone else, re-opening the app does the same thing,
and Settings → General → **Keep Worklens in the Dock** is the permanent version
([troubleshooting.md](troubleshooting.md#i-cannot-find-the-menu-bar-icon)).

Asking questions about your own day happens in Claude Desktop over `worklens mcp`, not in
Worklens: the Ask window was removed in #95. The task list is a frozen, hand-edited
`taxonomy.json`; an update may add apps Worklens ships, never removing or renaming yours.

`capture-once` needs Screen Recording permission and exits 3 with instructions when it is
missing. macOS grants that to whatever *runs* the binary, not to the binary, so a `worklens`
typed at a prompt is asking on behalf of your terminal and `Worklens.app` asks for itself —
neither grant counts for the other, and the first of either only takes effect after a relaunch.
In the app that relaunch is one click: **Relaunch Worklens**, in the menu and in
Settings → Capture → Access. Reading a browser tab URL additionally needs Automation permission for
that browser; capture only reads from a browser you have already allowed, so ask for it with
**Ask macOS for <browser>…** in Settings → Capture → Access, and the next tick has it.

## Try it without keys

Once frames are waiting, `worklens describe-pending --fake` describes them with an offline fake
provider: the real worker and the real ledger, with the model client swapped for one that makes
things up. No key, no network, $0.00. Every sentence it produces says `sample — not a real
summary`. Point `DATA_DIR` at a scratch directory first if you do not want those rows in your own
history.
