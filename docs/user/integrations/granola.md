# Granola (meeting notes and transcripts)

1. Granola → Settings → API keys → create a personal key. **This needs a Granola Business plan**;
   without one, there is no way in — Granola encrypts its own on-disk cache.
2. Put it in `.env`: `GRANOLA_API_KEY=grn_…`
3. **Sync now** on the Granola row in Settings → Connections, or wait for the next sync round.

Meetings appear in the timeline with their title; the AI summary is stored in the database and
the full transcript is written to `data/context/granola/<note_id>.md`. **Transcripts never leave
the disk**: the describe prompt sees only the meeting's title, and the MCP `context_events` tool
returns the title, at most the first 400 characters of the summary, and the next steps and
decisions listed anywhere in the full summary.

## Which company a meeting counts toward

Each meeting is put on a company when it is read, from the email domains of the people on it
(#318). Your own domain is left out, along with your house project's `domains`, personal
mailboxes such as gmail.com, meeting rooms and any domain in `ignored_domains`. Then the first of
these that gives one answer wins, and the rule is named next to the company:

| Rule | When |
|---|---|
| `yours` | a domain on the invite is on one of your projects' `domains` |
| `domain` | exactly one company domain is on the invite: it counts toward `company:<domain>` |
| `title` | the title names exactly one of your projects, as whole words |
| `calendar_event` | a Granola note with no answer of its own takes its calendar event's, or that of the event it is one meeting with |

Otherwise the meeting has no company, as `several_companies` or `no_company_domain`. A Granola
note and the calendar event it was taken on are one meeting when their times overlap. A note
with no calendar event is also one meeting with an event it overlaps for more than half of the
shorter one, unless another note names that event; if that note also overlaps the event, the note
with no event is its second copy and is dropped. Any other two meetings stay two, and their minutes are counted once where they overlap.

`worklens projects learn` adds a `company:<domain>` project for each company domain that alone
named a meeting, named after the domain; a subdomain such as `mail.acme.com` counts as `acme.com`.
When a project already answers to that name, `learn` adds nothing and prints the merge to run
instead. `worklens projects merge company:acme.com acme` makes `acme.com` one of `acme`'s domains;
`worklens projects forget company:acme.com` stops its meetings counting, and removing the domain
from `ignored_domains` in `taxonomy.json` takes that back. Only domains are compared and kept, never addresses or names. The MCP
`context_events` tool prints each meeting's company and rule, and `stats` adds each company's
meeting minutes to its `byProject` row as `meetingMinutes`, leaving the screen `minutes` as they were.

## What is stored, and what is sent

| | |
|---|---|
| Stored | the meeting title and its AI summary in the database; the next steps and decisions listed in the summary, read from it without a model call; the full transcript as a file under `data/context/granola/<note_id>.md` |
| Sent to a model | the title, in the prompt for a frame the meeting covers; an MCP client you connect also reads at most the first 400 characters of the summary, and the summary's next steps and decisions. **Transcripts are never sent** |
| Sent to Granola | your personal API key and a request for your own recent notes, only while a sync runs |
| To turn it off | **Disconnect** in Granola's ••• menu under Settings → Connections, or unset `GRANOLA_API_KEY` |
