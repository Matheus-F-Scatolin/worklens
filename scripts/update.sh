#!/usr/bin/env bash
# Pull, rebuild, re-sign and relaunch Worklens: the whole "main moved and I want to be running
# it" round trip in one step. Run it as `make update`, or from the menu's "Update and restart…"
# item, which runs it with --gui (output to build/update.log, opened if anything fails), or from
# the app's own auto-update poll, which runs it with --log: same log, no window — nothing
# nobody asked for should put a text editor in front of somebody mid-sentence.
#
# Order matters. The build happens while the old app is still running, so a compile error costs
# nothing: bundle.sh deletes build/Worklens.app, and the app only quits once there is a new
# binary to replace it with.
#
# Everything lives in main(), called from the last line, because `git pull` below can rewrite
# this very file: bash reads a script lazily by byte offset, so a script that updates itself
# mid-run executes whatever now sits at that offset. Parsing the whole file first, then running
# from memory, is what makes that safe.
# -E so the ERR trap set in main() survives into the functions it calls.
set -Eeuo pipefail

main() {
  cd "$(dirname "$0")/.."
  REPO="$PWD"
  APP="build/Worklens.app"
  LOG="build/update.log"
  APP_BIN="$REPO/$APP/Contents/MacOS/Worklens"
  GUI=0
  LOG_TO_FILE=0
  PULL=1

  # LaunchServices hands a GUI app a minimal environment; everything used below lives in
  # /usr/bin, appended rather than prepended so a shell that already has its own toolchain wins.
  export PATH="${PATH:-}:/usr/bin:/bin:/usr/sbin:/sbin"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --gui) GUI=1; LOG_TO_FILE=1 ;;
      --log) LOG_TO_FILE=1 ;;
      --no-pull) PULL=0 ;;
      -h|--help) echo "usage: $0 [--gui] [--log] [--no-pull]"; exit 0 ;;
      *) echo "error: unknown argument $1" >&2; exit 2 ;;
    esac
    shift
  done

  mkdir -p build
  if (( LOG_TO_FILE )); then exec > "$LOG" 2>&1; fi
  trap on_error ERR

  echo "Worklens update — $(date '+%Y-%m-%d %H:%M:%S')"
  echo "checkout: $REPO"

  if (( PULL )); then
    step "Pulling"
    local branch; branch="$(git branch --show-current)"
    if [[ -n "$(git status --porcelain)" ]]; then
      echo "skipped: this checkout has uncommitted changes — building them as they are"
    elif ! git rev-parse --abbrev-ref '@{u}' >/dev/null 2>&1; then
      echo "skipped: branch '$branch' has no upstream — building what is checked out"
    else
      git pull --ff-only
    fi
  fi
  echo "HEAD: $(git log -1 --oneline)"

  step "Building (release)"
  # Same mismatch the Makefile handles: a Command Line Tools update can pair a macOS SDK with
  # a Swift too old to build against it. This one matters most here, because the menu's
  # "Update and restart…" runs this script with no shell of the user's to set SDKROOT in.
  if [[ -z "${SDKROOT:-}" ]]; then
    local matched_sdk; matched_sdk="$(scripts/sdkroot.sh || true)"
    if [[ -n "$matched_sdk" ]]; then
      echo "using SDKROOT=$matched_sdk (the default SDK is newer than this Swift)"
      export SDKROOT="$matched_sdk"
    fi
  fi
  swift build -c release

  step "Quitting the running Worklens"
  quit_running_app

  local old_icon; old_icon="$(icon_digest "$APP")"

  step "Bundling"
  scripts/bundle.sh

  step "Signing"
  scripts/sign.sh

  # An installed copy is the one the user actually opens, so a rebuild that stopped at
  # build/Worklens.app would leave them on the old app for good (#119). Only ever the copy
  # stamped with this checkout — scripts/installed-app.sh does not name anyone else's — and back
  # into the directory it is already in, so an app installed to ~/Applications (because
  # /Applications was not writable that day) is replaced rather than duplicated.
  local installed_app; installed_app="$(scripts/installed-app.sh || true)"
  if [[ -n "$installed_app" ]]; then
    step "Re-installing"
    APPS_DIR="$(dirname "$installed_app")" scripts/install.sh
  fi

  if [[ "$(icon_digest "$APP")" != "$old_icon" ]]; then
    step "Refreshing the notification icon"
    refresh_icon_caches "$APP" "$installed_app"
  fi

  step "Launching"
  launch
  echo
  echo "Worklens is running the new build."
}

step() { echo; echo "==> $*"; }

# Relaunch exactly the way a double-click does, which since #119 can mean the copy in
# /Applications rather than the one in build/. scripts/launch.sh holds the whole rule — which
# bundle, and whether the WORKLENS_ENV_FILE override applies — so `make run` and this cannot
# drift apart about it.
#
# `--restore` is the difference between the two callers (#129): an update quits an app that was
# already reading some configuration and has to put it back on that same file, which it knows
# only because Worklens wrote it down at launch. `make run` starts the app from this checkout
# and has no such history to honour.
launch() {
  scripts/launch.sh --restore
}

# Empty when the bundle has no icon yet, so a first build counts as a change.
icon_digest() {
  shasum -a 256 "$1/Contents/Resources/AppIcon.icns" 2>/dev/null | cut -d' ' -f1 || true
}

# Notification Center caches an app's icon per bundle identifier for the life of the daemon,
# which on a Mac that is only ever slept means weeks. The Finder and System Settings pick up a
# new AppIcon.icns at once, but every banner keeps the old one until NotificationCenter and
# usernoted restart. Re-register the bundles first so the daemons read the new icon when they
# come back; launchd relaunches both within a second, and only a changed icon gets here.
refresh_icon_caches() {
  local lsregister="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
  local bundle
  for bundle in "$@"; do
    [[ -n "$bundle" && -d "$bundle" ]] || continue
    "$lsregister" -f "$bundle" || true
  done
  killall NotificationCenter usernoted 2>/dev/null || true
  echo "restarted Notification Center so banners show the new icon."
}

# SIGTERM ends the app outright: AppKit runs no `applicationShouldTerminate`, so the WAL is not
# checkpointed and an in-flight describe call is dropped. SQLite survives that — the next launch
# recovers the WAL, and frames that were never described stay pending — but quitting from the
# menu first is the clean way if something long is running.
#
# Both bundles this checkout owns, not just build/Worklens.app (#119). An app running from
# /Applications matches neither the checkout path nor a pkill for it, so before `make install`
# existed this step would print "not running.", the rebuild would land, and `open` would merely
# re-activate the old process — an update that silently did nothing. scripts/installed-app.sh
# only names an installed copy stamped with *this* checkout, so a Worklens running from another
# worktree is still left alone.
# `-a` is load-bearing: BSD pgrep/pkill silently exclude their own ancestors, and when the
# menu's "Update and restart…" runs this script the app *is* one (app → bash → pkill). Without
# it the quit step reports "not running.", bundle.sh rebuilds under the live process and `open`
# only re-activates the old build. `make update` from a terminal never hits this.
quit_running_app() {
  local installed binary pattern binaries=("$APP_BIN") quit=0
  installed="$(scripts/installed-app.sh || true)"

  mark_expected_restart
  # `if`, not `[[ … ]] && …`: that form's exit status is the test's, and an empty $installed
  # would trip `set -e` before the loop ever ran.
  if [[ -n "$installed" ]]; then
    binaries+=("$installed/Contents/MacOS/Worklens")
  fi

  for binary in "${binaries[@]}"; do
    # The menu bar only: `Worklens mcp` runs from the same binary, and killing it leaves Claude
    # failing every Worklens call until it is restarted (scripts/app-process-pattern.sh).
    pattern="$(scripts/app-process-pattern.sh "$binary")"
    pkill -a -f "$pattern" || continue
    quit=1
    for _ in $(seq 1 100); do
      pgrep -a -f "$pattern" >/dev/null || break
      sleep 0.1
    done
    # Refuse to delete a bundle out from under a live process: bundle.sh would leave the running
    # app with no files behind it and the user with no way to tell what happened.
    if pgrep -a -f "$pattern" >/dev/null; then
      echo "error: $binary is still running after 10s — not touching the bundle" >&2
      return 1
    fi
  done

  if (( quit )); then echo "quit."; else echo "not running."; fi
  return 0
}

# #156: say so before the kill, or the next launch reports this update as a crash.
#
# The app writes a clean-exit marker only from `applicationShouldTerminate`, which a SIGTERM
# never runs — and since #106 this script runs unattended every AUTO_UPDATE_POLL_MINUTES, so
# the most frequent restart on this machine would be the one that cried wolf. The binary just
# built is the one that is certain to exist here (bundling happens after this step), and it
# resolves the same DATA_DIR the running app does. The claim expires after half an hour, so an
# update that dies half-way through cannot excuse a real crash tomorrow.
mark_expected_restart() {
  local binary=".build/release/Worklens"
  [[ -x "$binary" ]] || return 0
  if ! "$binary" expect-restart >/dev/null 2>&1; then
    echo "note: could not record the expected restart; the next launch may report this as an unclean exit"
  fi
}

on_error() {
  local code=$?
  echo
  echo "update failed (exit $code) — nothing else will be replaced"
  # Put the user back where they were: `open` on an app that never quit just activates it.
  # Either bundle will do — if bundle.sh deleted build/Worklens.app and then failed, the
  # installed copy is the intact one and the one the user was running (#119).
  if [[ -d "$APP" || -n "$(scripts/installed-app.sh || true)" ]]; then launch || true; fi
  if (( GUI )); then open "$REPO/$LOG" || true; fi
  exit "$code"
}

main "$@"; exit $?
