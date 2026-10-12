#!/usr/bin/env bash
# Install build/Worklens.app where macOS expects an application, and put a `worklens` command on
# PATH pointing at that copy's binary (#119).
#
# Until this existed the app only ever lived at <repo>/build/Worklens.app: Spotlight could not
# find it, the Claude Desktop MCP path in the README was a path nobody had, and the CLI called
# itself `worklens` in its own help while the only way to run it was `swift run Worklens`.
#
# Two things this deliberately does NOT promise:
#   * It does not carry permissions over from a terminal. A process launched from a shell is
#     attributed to the shell's app (Terminal, iTerm, Claude) for TCC, so `worklens capture-once`
#     asks for Screen Recording on its own account even though it is byte-for-byte the binary
#     inside Worklens.app. What the symlink buys is one name, a release build, and the exact
#     path an MCP client needs.
#   * It does not touch ~/Library/Application Support/Worklens/.env. That file outranks every
#     checkout's .env (#34) and pointing an installed app at a checkout would move DATA_DIR out
#     from under it. `make install-env` is the command that decides that, and only it.
#
# usage: scripts/install.sh [--dry-run]
#   APPS_DIR   where the bundle goes      (default: /Applications, else ~/Applications)
#   BIN_DIR    where the symlink goes     (default: /usr/local/bin if it exists and is
#                                          writable, else ~/.local/bin)
set -euo pipefail

cd "$(dirname "$0")/.."
REPO="$PWD"
APP="build/Worklens.app"

DRY_RUN=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--dry-run) DRY_RUN=1 ;;
    -h|--help) sed -n '2,24p' "$0"; exit 0 ;;
    *) echo "error: unknown argument $1" >&2; exit 2 ;;
  esac
  shift
done

# Every mutating line goes through this, so --dry-run is the same script with the writes turned
# into echoes rather than a second, drifting description of what it would have done.
run() {
  if (( DRY_RUN )); then
    printf '  would run:'; printf ' %q' "$@"; printf '\n'
  else
    "$@"
  fi
}

if [[ ! -d "$REPO/$APP" ]]; then
  echo "error: $APP not found — run 'make build bundle sign' first" >&2
  exit 1
fi

# An unsigned or broken bundle is worth catching here rather than after it is in /Applications:
# ditto copies the signature verbatim, so whatever is wrong now stays wrong there.
if ! codesign --verify --strict "$REPO/$APP" 2>/dev/null; then
  echo "error: $APP is not validly signed — run 'make sign'" >&2
  exit 1
fi

# ---------------------------------------------------------------- where the bundle goes

if [[ -n "${APPS_DIR:-}" ]]; then
  :
elif [[ -w /Applications ]]; then
  APPS_DIR=/Applications
else
  APPS_DIR="$HOME/Applications"
  echo "note: /Applications is not writable, installing to $APPS_DIR instead"
fi
DEST="$APPS_DIR/Worklens.app"

if [[ -d "$DEST" ]]; then
  previous="$(plutil -extract WLRepoPath raw -o - "$DEST/Contents/Info.plist" 2>/dev/null || true)"
  if [[ -n "$previous" && "$previous" != "$REPO" ]]; then
    echo "note: replacing an installed Worklens built from $previous"
  fi
fi

# ditto over a bundle whose binary is executing leaves a half-replaced app and a process with no
# files behind it. `-a` is load-bearing for the same reason it is in scripts/update.sh: BSD
# pkill silently skips its own ancestors, and `make install` can be run by a script the app
# started. Only the menu bar: a `Worklens mcp` server an assistant launched keeps running on the
# binary `rm -rf` unlinks below (scripts/app-process-pattern.sh says why).
app_pattern="$(scripts/app-process-pattern.sh "$DEST/Contents/MacOS/Worklens")"
if [[ -d "$DEST" ]] && pgrep -a -f "$app_pattern" >/dev/null; then
  echo "quitting the running $DEST"
  run pkill -a -f "$app_pattern" || true
  if (( ! DRY_RUN )); then
    for _ in $(seq 1 100); do
      pgrep -a -f "$app_pattern" >/dev/null || break
      sleep 0.1
    done
    if pgrep -a -f "$app_pattern" >/dev/null; then
      echo "error: it is still running after 10s — not replacing the bundle" >&2
      exit 1
    fi
  fi
fi

echo "installing $APP to $DEST"
run mkdir -p "$APPS_DIR"
# rm first: ditto merges into an existing directory, so a file this build no longer ships would
# survive inside the installed copy and break its signature.
run rm -rf "$DEST"
run ditto "$REPO/$APP" "$DEST"
run codesign --verify --strict "$DEST"

# ---------------------------------------------------------------- where the command goes

# /usr/local/bin does not exist on a clean Apple-silicon Mac and creating it needs sudo, so it is
# used when it is already there and writable — never created.
if [[ -n "${BIN_DIR:-}" ]]; then
  :
elif [[ -d /usr/local/bin && -w /usr/local/bin ]]; then
  BIN_DIR=/usr/local/bin
else
  BIN_DIR="$HOME/.local/bin"
fi
LINK="$BIN_DIR/worklens"

# The symlink points into the installed bundle, not into the checkout: run through it, the CLI is
# the same signed release binary the menu bar is running, reading the same database.
echo "linking $LINK -> $DEST/Contents/MacOS/Worklens"
run mkdir -p "$BIN_DIR"
run ln -sfn "$DEST/Contents/MacOS/Worklens" "$LINK"

case ":${PATH}:" in
  *":$BIN_DIR:"*) ;;
  *)
    echo
    echo "$BIN_DIR is not on your PATH. Add it, then open a new shell:"
    echo "  echo 'export PATH=\"$BIN_DIR:\$PATH\"' >> ~/.zshrc"
    ;;
esac

echo
echo "installed. \`worklens --help\` lists the commands; Worklens.app is in $APPS_DIR."
echo "macOS will ask this copy for Screen Recording the first time it captures, and a"
echo "permission granted to a terminal does not count for it — they are different applications."
