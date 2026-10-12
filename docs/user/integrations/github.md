# GitHub (what you shipped)

Worklens keeps a ledger of what you shipped on GitHub: the PRs you merged or closed, the issues you
opened or closed, and the reviews you submitted on other people's PRs. PRs an agent wrote under
your account count too. Each item keeps its exact time, its repo and number, its title and its
link.

It reads through the GitHub CLI, so there is no key to paste:

1. Install it: `brew install gh`.
2. Log in once in Terminal: `gh auth login`.
3. Nothing else. The ledger fills on the next context sync (every `CONTEXT_SYNC_MINUTES`), or now
   with `worklens shipped sync --days 30`.

The first sync looks back 30 days; every later one starts a day before the last one that worked.
Without `gh`, or with `gh` logged out or rate-limited, the sync records why, waits 1, 5, 15 and then
60 minutes between tries, and changes nothing else.

## Reading it

- Ask Claude: the MCP tool `shipped(from, to, project?)` answers for up to 31 days at a time, with a
  count per kind, the sync status and one line per item. See [claude-desktop.md](../claude-desktop.md).
- `worklens shipped` prints the last 30 days; `--from`, `--to`, `--project` and `--json` narrow it.
  See [cli.md](../cli.md).
- A day's timeline gains a `## Shipped` section, grouped by project, right before `## Context`.

An item belongs to the project whose name or alias is the repo's name, and otherwise to the repo.
Nothing is attributed to the minutes before it: several PRs can merge in the same hour, so this
version does not guess which work led to which.

## Company memos

If your memos live in a GitHub repo, list it in `MEMO_REPOS` (for example
`MEMO_REPOS=your-org/memos`; several are separated by commas). Then each merged PR of
yours in that repo is checked once for which company memos it touched:

- a PR that adds `corpus/companies/<company>/<memo>.md` records that you published the memo for
  that company;
- one that changes it records that you updated it.

Only the memo itself counts: the rendered `.html` beside it, the `_history/` snapshots and the
`_updates/` logs do not, and a deleted memo records nothing. One PR that touches three companies
gives three rows; PRs you only reviewed give none.

Each row goes under the company's project. The folder name is matched to your project list as
written, with `-` and `_` read as spaces, and against a web domain the project answers to
(`acme-corp` finds `Acme Corp`, an alias `acme-corp` or `acmecorp.com`). A company the list does
not have yet is added to it as a `company` project named from the folder (`acme-corp` becomes
`Acme Corp`, with `acme-corp` as an alias); rename or merge it with `worklens projects` and the
rows follow on the next sync. A folder that two projects answer to is left without a project.

They read like this, in `shipped` and in the timeline's `## Shipped`:

```
Acme Corp: 1 memo updated
- 13:00 You updated the memo for Acme Corp in your-org/memos#41
```

The PR itself still counts once, as a merged PR. When `MEMO_REPOS` is first set, the PRs already in
the ledger are read once too; `worklens shipped sync` prints how many memos it found, as counts.

## What is stored, and what is sent

| | |
|---|---|
| Stored | one row per item in the `outputs` table: kind, time, repo, number, title, link, and the search that found it. Never a PR or issue body, review text, diff or commit message. A memo row keeps the company's name, the memo's path and the PR; the memo's text is never read |
| Sent to a model | nothing. No Gemini call reads the ledger; an MCP client you connect reads the titles and links when it calls `shipped` or `timeline` |
| Sent to GitHub | by `gh`, under its own login: three searches (your PRs, your issues, the PRs you reviewed), one call for your username, and one reviews list per PR of someone else's you reviewed, on every context sync; with `MEMO_REPOS` set, one file list per merged PR of yours in those repos, once |
| Kept | until you delete it. A retention pass and a date-range delete leave it alone, the same as your meetings |
| To turn it off | `GITHUB_SHIPPED=false` stops the sync and deletes the ledger; an empty `MEMO_REPOS` deletes only the memo rows. `worklens shipped forget` deletes it once; with the key still on, the next sync fills it again |
