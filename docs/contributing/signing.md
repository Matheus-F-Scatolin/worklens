# Signing, and keeping macOS permissions across rebuilds

Moved out of the README in #127, unchanged. This is build-from-source lore: nothing here is
needed to *use* Worklens.

## Keeping Screen Recording permission across rebuilds

macOS ties Screen Recording *and* Accessibility to the app's code signature, so an ad-hoc
signature makes every rebuild look like a brand-new app and you have to grant both again. It is
also why Worklens refuses to update itself without a certificate: an automatic update would cost
you the grants silently. One self-signed code-signing certificate fixes all of that — the
signature stops changing, so you grant once and it stays granted. It does **not** fix the
Keychain dialog — see [below](#the-keychain-dialog-after-every-rebuild).

```bash
make dev-cert     # once per Mac
```

It creates a `Worklens Dev` certificate, imports it into your login keychain, sets the key's
partition list and marks it trusted for code signing — the last two being the steps Certificate
Assistant does not do, and without which `codesign` either refuses the identity outright or
raises a keychain dialog on every build. Expect **two** prompts: your login password, typed in
the terminal, and one macOS authentication for the trust setting. Re-running it when the
certificate already exists does nothing.

Then:

```bash
security find-identity -v -p codesigning     # "1 valid identities found"
make bundle sign run
```

macOS sees a signature it has not seen before, so it asks for Screen Recording and Accessibility
one final time. Settings → Permissions says which signature the running build carries, so you
can tell "this Mac has no certificate" from "this build was made before the certificate existed".

This certificate is for **building from source**, which today is the only way to run Worklens. A
release build would be signed with an Apple Developer ID and notarized; this project has no
Apple Developer account, so that path does not exist yet.

<details>
<summary>Doing it by hand in Keychain Access</summary>

1. Open Keychain Access — it lives in `/System/Library/CoreServices/Applications/`, not in
   Applications → Utilities, so Spotlight or `open` is the quickest way there.
2. Keychain Access menu (the app menu, in the menu bar) → Certificate Assistant → Create a
   Certificate… → Name `Worklens Dev`, Identity Type `Self Signed Root`, Certificate Type
   `Code Signing`.
3. **Trust it for code signing.** The wizard does not, and `codesign` refuses an untrusted
   identity — `find-identity` reports it as `CSSMERR_TP_NOT_TRUSTED` and finds 0 *valid*
   identities. Search the login keychain for `Worklens`, double-click the certificate, expand
   ▸ Trust, set **Code Signing** to **Always Trust** (that row only, not the blanket "When
   using this certificate"), close the window and authenticate.
4. The first `make sign` will raise "codesign wants to access key …" — click **Always Allow**.
   `make dev-cert` avoids this by setting the key's partition list for you.

</details>

`make sign` signs ad-hoc when this Mac has no such certificate, so a fresh clone needs no
setup. `SIGN_IDENTITY="Some Other Name"` overrides the name and `SIGN_IDENTITY=-` forces
ad-hoc. Without the certificate nothing breaks, it just asks more: re-grant Screen Recording and
Accessibility in System Settings after each rebuild.

## The Keychain dialog after every rebuild

If you have connected Google, the first read of the refresh token after a rebuild raises
"Worklens wants to access key `dev.worklens.google` in your keychain" and asks for your **login
keychain password**. The app reads it at launch (the context sync runs one round immediately), so
in practice it arrives on the first launch of every new build.

**"Always Allow" does not stop it, and neither does the certificate.** Two things gate a
login-keychain item, and only the first is about the app list you see in Keychain Access. The
second is the item's *partition list*, and for code signed **without an Apple Developer Team ID**
— which is every self-signed and ad-hoc build — macOS stamps it with the exact binary hash:

```
Partitions = ( cdhash:43f5924cca1e125451e93dc8f6f72d5f3db98c72 )
```

Every build has a new hash, so every build is a new partition, so the password is asked again;
clicking Always Allow appends that build's hash and buys you exactly that build. The partition
list is written by `securityd` when the item is created and can only be changed with the keychain
password (`security set-generic-password-partition-list -k …`, or Keychain Access), so no amount
of code in Worklens can pre-authorise it. A Developer ID signature would be stamped
`teamid:<TEAM>` instead — stable across rebuilds, and asked for exactly once.

Three ways out:

1. **Keep the token somewhere else** — `GOOGLE_TOKEN_STORE=file` in `.env` puts it in
   `DATA_DIR/google-token.json` at mode `0600`. No dialog, ever, for any build or worktree. The
   keychain was the only place Worklens kept a credential *outside* `.env`, which already holds
   `GOOGLE_CLIENT_SECRET`, `GEMINI_API_KEY` and `GRANOLA_API_KEY` in plain
   text, so this makes the grant exactly as exposed as the rest: unreadable by other accounts on
   the Mac, readable by anything running as you. Switching stores does not move a grant, and only
   a disconnect revokes one at Google. Settings → Advanced → **Keep the Google sign-in in** does
   it in that order in one click: it disconnects from the old store and connects into the new one.
2. **Sign with a Developer ID** (paid Apple Developer Program). `SIGN_IDENTITY="Developer ID
   Application: …" make sign`, then authorise once, for good — the partition becomes
   `teamid:<TEAM>` and stops changing.
3. **Live with it.** One password per rebuild. Nothing else breaks: status in Settings → Connections
   never reads the token, and a missed dialog only
   skips that Calendar sync.
