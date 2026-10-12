# Claude, Codex and other MCP clients (asking about your own day)

The one integration that goes the other way: instead of pulling context in, it lets an assistant
you already use read what Worklens recorded. `worklens mcp` is a
[Model Context Protocol](https://modelcontextprotocol.io) server over stdin/stdout, inside the same
binary — no separate install, no port, no network.

**Settings → Connections → Use Worklens from Claude or Codex** is where it lives: a row for each client on
this Mac, with **Connect** or **Disconnect**. The entry to paste anywhere else is under
Settings → Advanced → **Another MCP client**.

## Claude Desktop

**Settings → Connections → Claude Desktop → Connect** does the whole setup. It says what it found first
(not connected, connected to this app, connected to another build, pointing at a build that is
gone, or a file it cannot read), asks before touching the file, copies that file aside with a
timestamp, and merges only its own `mcpServers.worklens` entry — every other server you have keeps
working. Then it runs the server in process and says only what to do next — or, if the server did
not come up, why. **Disconnect** is the mirror: the same backup, and only that one entry taken
out. `worklens mcp install` is the same thing from a terminal, and `worklens mcp install --print`
prints the entry and changes nothing.

Two things are still yours: saying yes to the dialog, and **quitting Claude Desktop before you
connect, then opening it again**. It reads that file only at launch, and while it is open it
writes its own settings back over the file, which would undo the entry within minutes — so
**Connect** writes nothing while Claude Desktop is running and says so, and so does
`worklens mcp install`. Worklens will not quit it for you.

Then ask it *"what did I work on yesterday?"*. It should call `timeline` and answer from the
day's blocks rather than guessing.

## Claude Code

**Settings → Connections → Claude Code → Connect** writes the same entry into `~/.claude.json`, which
is where Claude Code keeps its own user-level servers. Everything about the write is the same:
your file is copied aside with a timestamp first, only `mcpServers.worklens` is merged, and a file
that does not parse is refused rather than replaced — which matters more here, because that file
holds the rest of your Claude Code state too. From a terminal it is
`worklens mcp install --client claudeCode`.

Claude Code writes that file too. Quit your Claude Code sessions before connecting, then start a
new one — a session that is open keeps its own copy of that file and can write it back out, which
would take the `worklens` entry away again.

Claude Code reads that file when a session starts, so start a new session afterwards. Then ask it
the same question.

## Codex

**Settings → Connections → Codex → Connect** adds a `[mcp_servers.worklens]` table to
`~/.codex/config.toml`, the file the Codex CLI, its IDE extension and the ChatGPT app share. The
file is TOML, so Worklens edits it as lines: it copies the file aside first, replaces or appends
only its own table, and leaves every other line exactly as it was. Servers written some other way —
an inline `mcp_servers = { … }` or dotted keys — are refused rather than rewritten; use
`worklens mcp install --client codex --print` and add the table yourself. From a terminal the whole
connect is `worklens mcp install --client codex`. Start a new Codex session afterwards.

## When the link breaks

Moving the app, reinstalling it or deleting the checkout it ran from leaves the client pointing at
a binary that is not there, and from the client's side that fails silently — the server simply
never appears. Worklens checks the link at launch and about once an hour, and when one that used
to work has gone stale it says so in the menu and on Settings → General's status line:

> An assistant on this Mac can no longer reach Worklens — reconnect it in Settings → Connections.

**Disconnect**, then **Connect**, on that client's row repoints the entry, with the same backup. An install that never
connected a client is never told anything: there is nothing to have broken. An entry that still
launches *another* copy of Worklens — this checkout's `build/Worklens.app` beside the one in
`/Applications`, say — still works, so it shows as "Connected to another build" on its row and
raises nothing.

Every request the server answers is one line in the client's log of it — for Claude Desktop,
`~/Library/Logs/Claude/mcp-server-worklens.log` — naming the method, the tool, how it ended and
how long it took, never what was asked or answered. A call the client says failed that has no
line there never reached Worklens.

## Another client, or by hand

For Cowork or any other MCP client, **Copy JSON** under Settings → Advanced → Another MCP client (and `--print`) gives you the entry with
this Mac's own path already in it:

```json
{
  "mcpServers": {
    "worklens": {
      "args": [ "mcp" ],
      "command": "/Applications/Worklens.app/Contents/MacOS/Worklens"
    }
  }
}
```

Claude Desktop's own copy lives in
`~/Library/Application Support/Claude/claude_desktop_config.json`; keep any `mcpServers` already
there and add this one beside them.

**`command` must be the absolute path to the binary you actually run.** The path above is the one
`make install` creates; without it the bundle stays in the checkout and the path is
`/Users/you/path/to/worklens/build/Worklens.app/Contents/MacOS/Worklens` instead. `which worklens`
will not help, and neither will `~` or the `worklens` symlink: the client launches the command
with a minimal environment and no shell, so nothing expands and nothing is looked up on `PATH`. A
wrong path fails silently — the server simply never appears — which is why the button resolves
the path itself and why Settings → Connections reads the file back and checks that the command
exists and that `args` and the pinned environment are what this build would write.

That last one is the other silent failure. With that minimal environment and no working
directory, `~/Library/Application Support/Worklens/.env` is the only layer the launched process
will ever see — unless the entry pins one, which is what the button writes when the app itself
was started with `WORKLENS_ENV_FILE` (running from a checkout, the usual case). Installed by hand
from a checkout, run `make install-env` once, or the server will answer from an empty database
without complaining. The smoke test after an install is what catches this: it reports the
directory the *client's* process would read, and says so when that is not the one this app is
using. From inside Claude Desktop the same answer is in the server's `initialize` — ask it what
directory Worklens says it is answering from.

## The prompts in the "+" menu

Claude Desktop lists Worklens under its "+" menu, with five things worth asking. Pick one and it
fills the conversation in for you, including which tools to call and in which order:

| Prompt | What it asks for |
|---|---|
| How did today go? | one day, from the numbers and the timeline; takes an optional day |
| What did I work on this week? | the week pulled together from the days that have data |
| When did I last touch this? | the last time a project, a document or a person was on screen |
| Where did my week go, by project? | the week's screen and meeting time split across every project, with the time no project claimed |
| What did I ship, and where did my time go? | what you shipped beside each project's minutes over a range (or the latest day), with the time no project claimed and the time nothing was recorded |

The prompts ask for the timeline and the numbers, and the server's `initialize` says the same, so
an assistant knows it before it calls anything.

## The tools

Nine, all read-only — and a client that shows a read-only badge shows it, because every tool
declares `readOnlyHint`, `openWorldHint: false` and `idempotentHint` in `tools/list`:

| Tool | What it answers |
|---|---|
| `days` | which local days have data, with frame counts and each day's headline — the call to make when the client does not know what to ask for |
| `timeline(day)` | the day's narrated timeline as markdown |
| `stats(day \| week)` | the computed numbers as JSON: minutes by app, category, project and document (a Google file, a GitHub PR or issue, or a local path, with your home folder as `~`), longest focus run, context switches, meetings, spend. On a one-day call, `projectSpans` cuts your screen and meeting time into stretches that never overlap, each with its project or why it has none (`no_evidence`, `undescribed`, `redacted`, `meeting_without_company`, `conflict`), the rule that decided it (`assignment`, `rule_url_prefix`, `rule_repo`, `rule_domain`, `meeting_company`, `agent_repo`, `resource_key`, `project_key`, `project_hint`, or `detour` and `gap_fill` for a one-frame detour or a short gap between two stretches of one project) and `overridden`, the projects weaker evidence also named; a meeting counts once, as the meeting, never also as the screen time under it. `byProject` is their sum: on a project row, `minutes` are screen minutes, `meetingMinutes` the meeting minutes counted toward it and `meetingRules` splits them by the rule that named the company, `share`, a day's or a week's, is of the screen and meeting minutes all the rows cover, and the `unattributed` row's `parts` split its screen minutes by reason and its `meetingRules` its meeting minutes (`several_companies`, `no_company_domain`, `meeting_without_company`, `conflict`). A day no stretch names a project on has an empty `byProject`; a timeline heading names the same project the stats do; plus `accounting`, every minute of the day in one bucket (meeting, away, screen, battery-sparse screen, asleep, locked, idle, paused, permission missing, not running, unexplained) over the whole day and over the window from your first to your last recorded moment, with the accounting's spans on a one-day call |
| `search(query, days?, limit?)` | full-text search over what was on screen; each hit names its day |
| `context_events(from, to, sources?, outcomes_only?, company?)` | meetings synced from Granola and Calendar, bodies cut at 400 characters; each Granola meeting also lists the next steps and decisions in its full summary and how many name you, and `outcomes_only` returns just those meetings. Each meeting says the company it counts toward and the rule that named it, and `company` (a key, a name, a domain, or `none`) keeps one company's meetings |
| `now(minutes?)` | what has been on screen in the last few minutes: the app and project in front, the blocks inside the window, and when the last screenshot was taken |
| `span(from, to, by?, project?)` | the numbers over an inclusive range: by day (the default, up to 31 days) per-day minutes and accounting buckets plus the range's top apps, categories, projects and documents; by project (up to 92 days) every project's screen, meeting and agent minutes per day and by rule, an unattributed row with its reasons, and the window's not-recorded minutes; project narrows that to one row |
| `vocabulary(days?)` | the projects, categories and app keys this install knows, each with the day it was last seen, and each project with the kind you gave it (house, company or side) and each catalog project's domain, repo and URL-prefix rules — the names to use in a filter instead of guessing |
| `shipped(from, to, project?)` | what you shipped on GitHub over up to 31 days: a count per kind, the sync status, then each PR merged or closed, issue opened or closed, review submitted and company memo a merged PR published or updated in the repos `MEMO_REPOS` lists, with its time, repo#number, title and link, and for a PR or issue the minutes its page was on your screen over the 30 days up to that day ([github.md](integrations/github.md)); under each PR, the Claude Code and Codex sessions that linked it, with your minutes and the agent's |
| `agent_sessions(from, to, repo?)` | your Claude Code and Codex sessions over up to 31 days, per repo and per session: your prompts, your minutes, the agents' minutes (never your time), the branch and how each ended — a PR's state, files edited, or no change ([agents.md](integrations/agents.md)) |

`search` also takes an optional `project` and `app`, and says how many other matching screenshots
the filter kept out. `now` answers with app keys, project names, minutes and a timestamp — never a
window title, a URL or a file name. A last screenshot much older than the window it asked about
means nothing is being captured at that moment.

There are no write tools: nothing an MCP client asks for can capture, pause, generate or delete
anything. Running it beside the menu-bar app is the normal case — it takes no lock and never
writes to the database. From a checkout, `swift run Worklens mcp` is the same server; a scripted
transcript is the quickest smoke test:

```bash
printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' | swift run Worklens mcp
```

**What this means for privacy:** tool results go to whichever client you configured, and from
there into that client's model. `PRIVACY.md` says it plainly under "What leaves your machine".
