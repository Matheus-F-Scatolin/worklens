# Security policy

Worklens runs on one person's Mac and reads that person's own screen. There is no server, no
account and no shared database, so almost every security question here is really a question
about what sits in one folder on one machine — and about the one API key that lets that folder
talk to the outside world.

## Reporting a vulnerability

**Please do not open a public issue for a security report.** A bug in this project is most
likely to be one that leaks screen contents or an API key, and the reproduction usually *is* the
leak.

Report it privately through GitHub: this repository's **Security** tab → **Advisories** →
**Report a vulnerability**. That opens a draft advisory only you and the maintainer can read.

If that button is not there, private reporting has not been switched on yet. In that case open a
normal issue that says only "I have a security report, please open a private channel" — no
details, no logs, no screenshots — and wait for a reply.

Expect a first response within a week. This is a personal project maintained by one person in
their own time; there is no SLA and no bug bounty.

## What counts as sensitive here

In rough order of how much damage a leak does:

- **API keys.** `GEMINI_API_KEY` lives in `~/Library/Application Support/Worklens/settings.json`
  when you paste it into the app, or in a `.env` (that folder's, or a checkout's) when you put it
  there. `GRANOLA_API_KEY` sits beside it once you connect Granola, and a Google OAuth refresh
  token lives in the Keychain once you connect Google Calendar. These are the only credentials
  Worklens holds, and the Gemini key is billable.
- **Screenshots.** JPEGs of whatever was on screen, under `DATA_DIR/screenshots/`. Assume every
  one of them contains something private: a password manager, a bank tab, someone else's message.
- **Window text and titles.** The accessibility outline of the focused window, plus window titles
  and browser URLs, in the SQLite database. Text is often more revealing than the pixels.
- **Descriptions.** Model-written prose about the above, in the database.
- **The database itself.** `DATA_DIR/worklens.sqlite` is unencrypted by design (see
  [PRIVACY.md](PRIVACY.md)); it is protected by the Mac's own disk encryption and file
  permissions, nothing else.

So the bugs worth reporting are the ones that move any of that somewhere it was not meant to go:
into a log line, into a crash report, into a prompt sent to a model when the frame should have
been skipped, into a file outside `DATA_DIR`, or into the hands of another process.

Two rules the code already tries to keep, and a violation of either is a bug worth reporting:

- Screenshot contents, window titles, URLs and API keys are never logged at `info` level or
  above.
- Nothing reaches the network except the Gemini calls Worklens makes on purpose, the update
  check against GitHub, and the optional integrations you switch on yourself — the hosts listed in
  [PRIVACY.md](PRIVACY.md#what-leaves-your-machine).

## Out of scope

- Anything that needs an attacker to already have code execution or Full Disk Access on the Mac.
  At that point they can read the screen directly.
- The database being unencrypted. That is a documented decision, not a defect —
  see [PRIVACY.md](PRIVACY.md).
- The self-signed ("Worklens Dev") or ad-hoc code signature. There is no Apple Developer account
  for this project, so builds are not notarized and macOS treats them accordingly.
- Sending your own screen contents to Google. That is what the app is for; what it sends, and
  how to stop it, is in [PRIVACY.md](PRIVACY.md).

## If you think a key leaked

Rotate it first, then report. Google lets you revoke a Gemini key at
<https://aistudio.google.com/apikey>, and Granola from its own settings. Paste the new one into
Settings → Connections — nothing else has to change.
