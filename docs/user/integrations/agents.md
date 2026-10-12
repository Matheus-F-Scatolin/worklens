# Agent sessions (Claude Code and Codex)

Worklens reads the logs your coding agents already keep on this Mac and keeps a ledger of each
session: which repo it worked in, when you typed a prompt, when the agent was working, and the PRs
it linked. From that it tells two numbers apart for every repo and every session:

- **your minutes**: the minutes around your own prompts while the agent's app was in front and you
  were active. Each prompt claims from 3 minutes before it to 10 minutes after it, and a later
  prompt takes over at its own instant, so no minute counts twice.
- **agent minutes**: the minutes an agent was working. They are never your time, and they are never
  added to it.

There is nothing to set up. It is on by default, reads three folders, and costs nothing:

| Store | Folder |
|---|---|
| Claude Code, in a terminal or the Claude app | `~/.claude/projects/` |
| The Claude app's Code tab (for its PR links) | `~/Library/Application Support/Claude/claude-code-sessions/` |
| Codex | `~/.codex/sessions/` and `~/.codex/archived_sessions/` |

The ledger fills on the next context sync (every `CONTEXT_SYNC_MINUTES`), or now with
`worklens agents sync --days 30`. The first read looks back 30 days and reads at most 256 MB a
round; every later one reads only what the logs gained since.

## What counts as a prompt

A prompt is something you typed. A task notification, a message from another agent, a tool's
result, a subagent's own thread and a slash command are not. A prompt sent from elsewhere (the SDK
or a phone) counts as a prompt but adds none of your minutes: you were not at this Mac. In Codex,
only a message typed in the Codex app counts; a `codex exec` run or a Codex subagent is a script
asking, not you. A forked session that repeats its parent's records adds no prompt twice.

## Which repo a session belongs to

In order: the repo of the PR the session itself linked; the git remote Codex recorded; the repo
other sessions in the same folder named, when they all named the same one; and otherwise the
folder's name. A worktree under `.claude/worktrees/` counts as the checkout it belongs to. A folder
where sessions named two different repos stays without one rather than guessing. A Codex run inside
a Claude Code worktree counts toward the Claude session it overlapped.

## Reading it

- Ask Claude: the MCP tool `agent_sessions(from, to, repo?)` answers for up to 31 days. The
  `shipped` tool lists, under each PR, the sessions that linked it with both numbers. See
  [claude-desktop.md](../claude-desktop.md).
- `worklens agents` prints the last 7 days per repo; `--from`, `--to`, `--repo` and `--json` narrow
  it. See [cli.md](../cli.md).

If a tool changes its log format, the sync says "format not recognized" for that store and stores
nothing from it until a Worklens that understands it.

## What is stored, and what is sent

| | |
|---|---|
| Stored | per session: the tool, where it ran (app or terminal), the folder, the repo and branch, its first and last instant and how many file edits it made; the instant of each prompt; the start and end of each agent turn; the PR links. Never a prompt's text, a command, a tool's output, a file's contents or a session's title |
| Sent to a model | nothing. No Gemini call reads it; an MCP client you connect reads the repo names, branches and minutes when it calls `agent_sessions` or `shipped` |
| Sent anywhere | nothing. It reads files on this Mac, runs no git command and makes no network call |
| Kept | like your captures: a retention pass and a date-range delete remove the prompts and turns they cover, and a later read does not bring them back |
| To turn it off | `AGENT_SESSIONS=false` stops reading and deletes the ledger. `worklens agents forget` deletes it once; with the key still on, the next sync reads it again |
