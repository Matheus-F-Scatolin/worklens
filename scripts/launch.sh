#!/usr/bin/env bash
# Open Worklens the way it should be opened from this checkout: the installed copy when there is
# one, build/Worklens.app otherwise, and with the .env override only where it is the difference
# between a configured app and a degraded one.
#
# Shared by `make run` and scripts/update.sh so the two cannot drift. The rule about the
# environment is #34's: ~/Library/Application Support/Worklens/.env outranks every checkout, so
# forcing WORKLENS_ENV_FILE at an installed setup would point the app at this checkout's DATA_DIR
# and look, convincingly, like a day of captures had vanished. Only build/Worklens.app, on a
# machine with no installed .env and a checkout that has one, gets the override. An installed app
# never does: that is what a fresh one-line install launches, and pointing it at the clone's .env
# put its database inside the git checkout and hid every Settings change behind that file's
# defaults. Opened plainly, it writes its own Application Support .env on first launch (#116).
#
# Usage: scripts/launch.sh [--restore]
#   --restore  relaunch into the configuration the running app was reading, from the handshake
#              Worklens writes at ~/Library/Application Support/Worklens/.launch-env (#129).
#              This is what `scripts/update.sh` wants: it quits a running app and has to put it
#              back on the same file, which no amount of guessing from this checkout can work
#              out. A missing record — or one naming a file that is gone — falls through to the
#              rule above. `make run` deliberately does not use it: it is a launch *from this
#              checkout*, not a restart of whatever was running.
set -euo pipefail

RESTORE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --restore) RESTORE=1; shift ;;
    -h|--help) sed -n '2,19p' "$0"; exit 0 ;;
    *) echo "error: unknown option $1" >&2; exit 2 ;;
  esac
done

cd "$(dirname "$0")/.."
REPO="$PWD"
SUPPORT="$HOME/Library/Application Support/Worklens"
INSTALLED_ENV="$SUPPORT/.env"
LAUNCH_ENV="$SUPPORT/.launch-env"

APP="$(scripts/installed-app.sh || true)"
if [[ -n "$APP" ]]; then
  echo "app: $APP (installed)"
else
  APP="$REPO/build/Worklens.app"
  echo "app: $APP"
fi

if [[ ! -d "$APP" ]]; then
  echo "error: $APP not found — run 'make build bundle sign' first" >&2
  exit 1
fi

# The first line of .launch-env that is neither blank nor a comment: the file the app that just
# quit was told to read.
recorded=""
if [[ $RESTORE -eq 1 && -f "$LAUNCH_ENV" ]]; then
  recorded="$(grep -v -e '^[[:space:]]*#' -e '^[[:space:]]*$' "$LAUNCH_ENV" | head -1 || true)"
  if [[ -n "$recorded" && ! -f "$recorded" ]]; then
    echo "note: $LAUNCH_ENV names $recorded, which is gone — falling back"
    recorded=""
  fi
fi

if [[ -n "$recorded" ]]; then
  echo "configuration: $recorded (what this app was reading before the restart)"
  open --env WORKLENS_ENV_FILE="$recorded" "$APP"
elif [[ -f "$INSTALLED_ENV" ]]; then
  echo "configuration: $INSTALLED_ENV"
  open "$APP"
elif [[ "$APP" != "$REPO/build/Worklens.app" || ! -f "$REPO/.env" ]]; then
  echo "configuration: the app's own, in $SUPPORT (written on first launch)"
  open "$APP"
else
  echo "configuration: $REPO/.env (no installed .env — see \`make install-env\`)"
  echo "note: only a launch from this checkout reads that file. A Finder, Spotlight or"
  echo "      login-item launch reads $INSTALLED_ENV instead, which \`make install-env\` writes."
  open --env WORKLENS_ENV_FILE="$REPO/.env" "$APP"
fi
