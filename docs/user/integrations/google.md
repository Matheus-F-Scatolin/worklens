# Google Calendar

**Settings → Connections → Google Calendar → Connect…** walks through all of this with the
console pages linked, checks the shape of both credentials as you paste them, and connects in the same
sheet. The steps below are what it walks you through.

1. https://console.cloud.google.com → create or pick a project.
2. **APIs & Services → Library** → enable the **Google Calendar API**.
3. **OAuth consent screen** → External → fill in the app name and your email → add yourself
   under **Test users** while the screen is in testing.
4. **Credentials → Create Credentials → OAuth client ID → Desktop app**. Put the client id and
   secret in `GOOGLE_CLIENT_ID` / `GOOGLE_CLIENT_SECRET`.
5. **Connect** on the Google Calendar row in Settings → Connections.

## The sign-in expires every 7 days

Google expires a refresh token issued by a consent screen that is still in **Testing** after
seven days, and Worklens's screen stays in Testing on purpose: publishing one that asks for
`calendar.readonly`, a sensitive scope, means Google's verification review, and this is a tool you
run for yourself.

So about once a week Calendar pauses. Worklens says so where you would look: the row reads
**Paused until you reconnect**, the menu carries one line about it, and one
notification goes out per expiry — not one per sync round. **Reconnect** on the Google account
row in Settings → Connections is the whole fix; it is the same browser flow as the first connect,
and it takes about ten seconds because you are already signed in.

The browser window stays open for five minutes, there is a **Cancel** beside it, and **Open the
consent page again** brings back a tab you closed without starting a second flow.

That opens your own browser, runs Authorization Code + PKCE against a loopback redirect on
`http://127.0.0.1:<random port>/callback`, and stores the refresh token in your **Keychain**
under `dev.worklens.google` — you can see it in Keychain Access and revoke Worklens at
myaccount.google.com/permissions like any other app. Nothing lands in `DATA_DIR`, so a backup of
your data folder carries no credentials — unless you pick the **data folder** instead, which puts
the grant in `DATA_DIR/google-token.json` at mode 0600 and makes a backup of that folder worth
guarding. The Google Calendar setup sheet asks which one you want as you connect, and pre-selects the
data folder on a build with no Apple Developer Team ID — on those the keychain asks for your
login password again after every rebuild, and nothing the app can do prevents that. Changing
your mind later is one choice in Settings → Advanced → **Keep the Google sign-in in**: it
disconnects from the old store, revoking the grant at Google, and reconnects into the new one. Revoking at Google works the same either way, and
**Disconnect** in Settings → Connections revokes and deletes it.

Settings → Connections says who is connected, reading the address from `app_state` (where the
connect recorded it — an address is not a secret) rather than decrypting the Keychain item, so it
cannot raise the access dialog described [in the contributor notes](../../contributing/signing.md#the-keychain-dialog-after-every-rebuild).
A grant connected before the address was recorded shows as `Connected · account unknown —
Reconnect to confirm`; one reconnect fills it in.

The requested scopes are the narrowest that work:

| Scope | What it allows |
|---|---|
| `calendar.readonly` | read events on your primary calendar |
| `openid`, `email` | learn which account you connected, to label it |

Calendar events become meeting blocks (title, attendees and their responses); an all-day entry or
one you declined is recorded but is not counted as meeting time.

**If you connected Google before 23 September 2026**, that sign-in also granted `gmail.metadata`
for the Gmail source, which was removed then (#285). Nothing forces a reconnect: the same grant
keeps working for Calendar, and Worklens no longer asks for mail. To take the mail access back,
remove it at [myaccount.google.com/permissions](https://myaccount.google.com/permissions) and
press **Reconnect**, which asks for `calendar.readonly` alone.

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
| `calendar_event` | a Granola note with no answer of its own takes its calendar event's |

Otherwise the meeting has no company, as `several_companies` or `no_company_domain`. A Granola
note and the calendar event it was taken on are one meeting when their times overlap; any other
two meetings stay two, and their minutes are counted once where they overlap.

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
| Stored | calendar events as meeting blocks (title, attendees, their responses) |
| Sent to a model | those blocks, as timeline context |
| Sent to Google | the OAuth exchange (client id and secret, the authorisation code, a refresh token on renewal), then read-only Calendar requests for your own account |
| Where the grant lives | whichever you chose when you connected: your **Keychain** under `dev.worklens.google`, or `DATA_DIR/google-token.json` at 0600 (`GOOGLE_TOKEN_STORE`) |
| How long it lasts | 7 days, while the consent screen is in Testing — then the card reads "Paused until you reconnect" and **Reconnect** starts it again |
| To turn it off | **Disconnect** in Settings → Connections, which revokes at Google and deletes the token |
