# Integrations (optional)

Worklens can pull a little context from outside the screen so the timeline can say *what* a
meeting was, not just which app was frontmost. Every integration is optional
and every one of them stores **only your own activity**.

**The app can do all of this for you.** Settings → Connections → **Sources** has a row per source;
**Connect…** (or **Change…** in its ••• menu, once connected) opens the same steps these pages
describe, with a field for the key, a **Test** button that asks the provider straight away, and a
**Save** that writes the key to Worklens's own settings file — no `.env` editing, no relaunch, and
capture is not interrupted. Each page below is the same walkthrough for
anyone who would rather use a text file and the CLI.

| Source | What it adds | What it needs | Page |
|---|---|---|---|
| Granola | meeting titles and summaries; transcripts stay on disk and never reach a prompt | a personal API key (Granola Business plan) | [granola.md](integrations/granola.md) |
| Google Calendar | meetings as blocks: title, attendees, responses | `calendar.readonly` on your own OAuth client | [google.md](integrations/google.md) |
| GitHub | what you shipped: PRs merged or closed, issues opened or closed, reviews on others' PRs, and the company memos your merged PRs published or updated in the repos `MEMO_REPOS` lists | the GitHub CLI, logged in (`gh auth login`); on by default, `GITHUB_SHIPPED=false` turns it off; memos also need `MEMO_REPOS` (empty by default) | [github.md](integrations/github.md) |
| Claude Code and Codex | your agent sessions per repo: your prompts, your minutes and the agents' minutes kept apart, and the PRs each session linked | nothing: it reads the agents' own logs on this Mac; on by default, `AGENT_SESSIONS=false` turns it off | [agents.md](integrations/agents.md) |

Each page ends with what that source stores, what of it reaches a model, and how to turn it off.

**Slack and Gmail were sources until 23 September 2026 (#285).** Neither earned its setup cost, so
both were removed; Slack and Gmail as apps you use are recorded as before. The builds between #285
and #299 deleted what they stored on their first launch; an install that skipped those builds keeps
any old Slack or Gmail rows until you erase their days. What is left for you: remove the Worklens app at
[api.slack.com/apps](https://api.slack.com/apps), and, if you like, the Gmail access at
[myaccount.google.com/permissions](https://myaccount.google.com/permissions). A `.env` that still
sets `SLACK_USER_TOKEN` keeps working — the line is ignored, and `worklens config-dump` names it as
one to delete.

Claude and Codex are not context sources — nothing is read from them — but they are the other thing
you connect Worklens to. They have their own group, **Settings → Connections → Use Worklens from
Claude or Codex**, and their
own page:
[claude-desktop.md](claude-desktop.md).
