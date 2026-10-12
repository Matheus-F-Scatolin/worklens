# Running the newest build

Moved out of the README in #127, unchanged.

After merging something, one step picks it up:

```bash
make update
```

It pulls (skipping the pull when the checkout is dirty or the branch has no upstream), builds,
quits the running Worklens, re-bundles, re-signs and launches the new one. The build happens
while the old app is still running, so a compile error costs you nothing: nothing is replaced
and the app you had keeps going.

It relaunches the way a double-click does, so an installed
`~/Library/Application Support/Worklens/.env` keeps deciding `DATA_DIR`. `make run` follows the
same rule: it only forces this checkout's `.env` on a Mac that has no installed one, because
doing it anywhere else would point the app at a different data directory and look for all the
world like a day of captures had vanished. The quit itself is a plain `SIGTERM`, which ends the
app without its usual checkpoint — SQLite recovers on the next launch, but quit from the menu
first if you would rather it be clean.

Settings → General → **Updates** has the same thing as **Update and restart…** (#136 moved it out
of the menu, where it sat above Quit) — it runs
`scripts/update.sh --gui`, which logs to `build/update.log` and opens that log if any step
fails. An installed `/Applications/Worklens.app` gets the item too: `make bundle` stamps the
checkout's path into the bundle, so the copy knows where it came from, and `make update` quits,
rebuilds, re-installs and relaunches *that* copy rather than leaving you on the old one. A bundle
with no checkout behind it any more — moved by hand from another Mac, or built from a repository
that has since been deleted — has no repository to pull and gets no item.

## Doing that by itself

With `AUTO_UPDATE_ENABLED=true` (off by default; turn it on in Settings → General → Updates or the
`.env`), Worklens asks the remote every
`AUTO_UPDATE_POLL_MINUTES` what `main` points at, and when it has moved it runs the same round
trip on its own — build, quit, re-bundle, re-sign, relaunch, about a minute in which nothing is
captured. So a merge on GitHub is enough; nothing on this Mac needs clicking.

This is not something CI can do — a GitHub runner cannot reach your Mac, and the release build,
the signature and the relaunch are the whole point — so the app that is already running does the
polling. It declines, and says why in the menu, when the checkout is dirty, is on a branch other
than `main`, has no upstream, or when this Mac has no **Worklens Dev** certificate: signing
ad-hoc would look to macOS like a different app and quietly take Screen Recording with it. It
also waits while the app is busy (a sync, a reload, a deletion), and never tries the same commit twice in one run — so
a commit that fails to build stops the app you have, once, and leaves it running.

Which build you are on is the line above that button, **This build** — `#105 · 0ae882e · updated 3
hours ago`, the pull request and commit the *running* app was built from, not whatever the
checkout has moved on to since. `scripts/bundle.sh` stamps it into the bundle, so
`worklens version` prints it too.
