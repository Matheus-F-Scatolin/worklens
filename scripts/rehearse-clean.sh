#!/usr/bin/env bash
# Removes everything the install rehearsal added (docs/rehearsal.md), and nothing of the real
# Worklens. A dry run unless you pass --yes.
#
# usage: scripts/rehearse-clean.sh [--yes] [--all]
#   (none)  print what would be removed, change nothing
#   --yes   remove it
#   --all   the rehearsal reports too (~/Library/Application Support/Worklens Rehearsal/rehearsals)
#
# What it removes: Worklens Rehearsal.app (in /Applications, ~/Applications and this checkout's
# build/), the worklens-rehearsal command, ~/Library/Application Support/Worklens Rehearsal
# except its reports, the dev.worklens.rehearsal keychain item, Launch Services registration,
# preferences and caches, its Screen Recording, Accessibility and Automation answers, and its
# "worklens-rehearsal" entry in Claude Desktop (only while Claude Desktop is not open).
#
# Every path it would touch passes scripts/app-identity.sh's guard first: one that is the real
# app's (Worklens.app, Application Support/Worklens, the worklens command, dev.worklens.app)
# stops the script before anything is removed.
set -euo pipefail

cd "$(dirname "$0")/.."
REPO="$PWD"
# shellcheck source=scripts/app-identity.sh
source scripts/app-identity.sh

DRY_RUN=1
ALL=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    -y|--yes) DRY_RUN=0 ;;
    -n|--dry-run) DRY_RUN=1 ;;
    --all) ALL=1 ;;
    -h|--help) sed -n '5,8p' "$0"; exit 0 ;;
    *) echo "error: unknown argument $1" >&2; exit 2 ;;
  esac
  shift
done

BOLD=$'\033[1m'; DIM=$'\033[2m'; PLAIN=$'\033[0m'
[[ -t 1 ]] || { BOLD=""; DIM=""; PLAIN=""; }
step()   { echo; echo "${BOLD}==> $*${PLAIN}"; }
detail() { echo "${DIM}    $*${PLAIN}"; }
die()    { echo "error: $*" >&2; exit 1; }

[[ "$(uname -s)" == "Darwin" ]] || die "Worklens runs on macOS only, this is $(uname -s)"
# Every rm below is under $HOME or this checkout. A HOME that is empty, relative or / would make
# those paths mean something else, so it is taken as the real folder it names.
[[ "${HOME:-}" == /* ]] || die "HOME is '${HOME:-}', not a home folder"
HOME="$(cd "$HOME" 2>/dev/null && pwd -P)" || die "HOME is not a folder"
[[ "$HOME" == /*[!/]* ]] || die "HOME is /, not a home folder"

wl_identity rehearsal
[[ "$WL_BUNDLE_ID" == dev.worklens.rehearsal ]] || die "identity is not the rehearsal's"

SUPPORT="$WL_SUPPORT"
REPORTS="$SUPPORT/rehearsals"
APP_DIRS=("${APPS_DIR:-/Applications}" "$HOME/Applications")
BIN_DIRS=("${BIN_DIR:-/usr/local/bin}" "$HOME/.local/bin")
LSREGISTER="${LSREGISTER:-/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister}"
CLAUDE_DESKTOP_CONFIG="$HOME/Library/Application Support/Claude/claude_desktop_config.json"
CLAUDE_CODE_CONFIG="$HOME/.claude.json"
CODEX_CONFIG="$HOME/.codex/config.toml"
wl_guard "$SUPPORT" "$REPORTS" "$WL_BUNDLE_ID" "$WL_GOOGLE_SERVICE" "$WL_MCP_NAME" "$WL_CLI"

# Every mutating line goes through run(): a dry run is this same script with the removals turned
# into echoes. Each argument passes the guard first, dry run or not.
exec 3>&1
run() {
  wl_guard "$@"
  if (( DRY_RUN )); then
    { printf '    would run:'; printf ' %q' "$@"; printf '\n'; } >&3
  else
    "$@"
  fi
}

LEFT=()
left() { LEFT+=("$*"); }
FAILED=0
failed() { FAILED=$((FAILED + 1)); echo "    $*" >&2; }

is_rehearsal_app() {
  [[ -d "$1" ]] || return 1
  [[ "$(plutil -extract CFBundleIdentifier raw -o - "$1/Contents/Info.plist" 2>/dev/null || true)" == "$WL_BUNDLE_ID" ]]
}

# The rehearsal's menu bar app, matched like scripts/app-process-pattern.sh matches the real one.
# It cannot match Worklens.app: the bundle name differs.
APP_PATTERN='^/.*/Worklens Rehearsal\.app/Contents/MacOS/Worklens( (app|run)( .*)?)?$'
app_running() { pgrep -a -f "$APP_PATTERN" >/dev/null 2>&1; }

# The "worklens-rehearsal" key in one JSON file's mcpServers: `find FILE` exits 0 when it is there,
# `remove FILE` takes out that key and nothing else, keeping a copy of the old file beside it.
MCP_PY='
import json, os, sys, tempfile, time
mode, path, key = sys.argv[1], sys.argv[2], sys.argv[3]
assert key == "worklens-rehearsal"
raw = open(path, "rb").read()
obj = json.loads(raw)
servers = obj.get("mcpServers") if isinstance(obj, dict) else None
if not isinstance(servers, dict) or key not in servers:
    sys.exit(1)
if mode == "find":
    sys.exit(0)
backup = path + ".worklens-rehearsal-" + time.strftime("%Y%m%d-%H%M%S") + ".bak"
fd = os.open(backup, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
with os.fdopen(fd, "wb") as f:
    f.write(raw)
del servers[key]
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".worklens-rehearsal-clean-")
with os.fdopen(fd, "w", encoding="utf-8") as f:
    json.dump(obj, f, indent=2)
    f.write("\n")
os.chmod(tmp, os.stat(path).st_mode & 0o7777)
os.replace(tmp, path)
print(backup)
'
mcp_has_key() { [[ -f "$1" ]] && python3 -I -c "$MCP_PY" find "$1" "$WL_MCP_NAME" 2>/dev/null; }

# ------------------------------------------------------------------ what is there

echo "${BOLD}Removing the install rehearsal${PLAIN}"
if (( DRY_RUN )); then
  echo "${DIM}dry run: nothing will be removed. 'make rehearse-clean REHEARSE_CLEAN_ARGS=--yes' removes it.${PLAIN}"
fi

APPS=()
for dir in "${APP_DIRS[@]}" "$REPO/build"; do
  app="$dir/$WL_APP_BUNDLE"
  wl_guard "$app"
  if is_rehearsal_app "$app"; then
    APPS+=("$app")
  elif [[ -e "$app" ]]; then
    detail "$app is not the rehearsal's ($WL_BUNDLE_ID), so it stays"
  fi
done

LINKS=()
for dir in "${BIN_DIRS[@]}"; do
  link="$dir/$WL_CLI"
  wl_guard "$link"
  if [[ -L "$link" ]]; then LINKS+=("$link"); fi
done

KEYCHAIN_ITEM=0
security find-generic-password -s "$WL_GOOGLE_SERVICE" >/dev/null 2>&1 && KEYCHAIN_ITEM=1

PREFS=0
[[ -f "$HOME/Library/Preferences/$WL_BUNDLE_ID.plist" ]] && PREFS=1
CACHES=()
for path in "$HOME/Library/Caches/$WL_BUNDLE_ID" "$HOME/Library/HTTPStorages/$WL_BUNDLE_ID" \
    "$HOME/Library/HTTPStorages/$WL_BUNDLE_ID.binarycookies" "$HOME/Library/WebKit/$WL_BUNDLE_ID" \
    "$HOME/Library/Saved Application State/$WL_BUNDLE_ID.savedState"; do
  wl_guard "$path"
  if [[ -e "$path" || -L "$path" ]]; then CACHES+=("$path"); fi
done

# The folder, except its reports unless --all.
SUPPORT_ITEMS=()
if [[ -d "$SUPPORT" ]]; then
  if (( ALL )); then
    SUPPORT_ITEMS=("$SUPPORT")
  else
    shopt -s nullglob dotglob
    for item in "$SUPPORT"/*; do
      [[ "$item" == "$REPORTS" ]] && continue
      SUPPORT_ITEMS+=("$item")
    done
    shopt -u nullglob dotglob
  fi
fi
for item in ${SUPPORT_ITEMS[@]+"${SUPPORT_ITEMS[@]}"}; do wl_guard "$item"; done

CLAUDE_DESKTOP_OPEN=0
# -a: this may itself run under Claude Desktop, and BSD pgrep skips its ancestors.
pgrep -a -x Claude >/dev/null 2>&1 && CLAUDE_DESKTOP_OPEN=1

# ------------------------------------------------------------------ the removals

if app_running; then
  step "Quitting $WL_APP_NAME"
  run pkill -a -f "$APP_PATTERN" || true
  if (( ! DRY_RUN )); then
    for _ in $(seq 1 100); do app_running || break; sleep 0.1; done
    app_running && die "$WL_APP_NAME is still running after 10 seconds. Quit it from the menu bar, then run this again. Nothing else was changed."
    detail "quit"
  fi
fi

step "Claude Desktop, Claude Code and Codex"
if mcp_has_key "$CLAUDE_DESKTOP_CONFIG"; then
  if (( CLAUDE_DESKTOP_OPEN )); then
    detail "Claude Desktop is open, and it puts its old settings back while it runs: left as it is"
    left "Quit Claude Desktop, then run 'make rehearse-clean REHEARSE_CLEAN_ARGS=--yes' again in Terminal to take \"$WL_MCP_NAME\" out of its settings. (Quitting it ends any session running inside it.)"
  elif (( DRY_RUN )); then
    detail "would take \"$WL_MCP_NAME\" out of $CLAUDE_DESKTOP_CONFIG, keeping a copy beside it"
  elif backup="$(python3 -I -c "$MCP_PY" remove "$CLAUDE_DESKTOP_CONFIG" "$WL_MCP_NAME")"; then
    detail "took \"$WL_MCP_NAME\" out of Claude Desktop's settings; the old file is at $backup"
  else
    failed "could not take \"$WL_MCP_NAME\" out of $CLAUDE_DESKTOP_CONFIG: remove that entry by hand"
  fi
else
  detail "Claude Desktop has no \"$WL_MCP_NAME\" entry"
fi
# Claude Code rewrites its own file while it runs (this may be running inside it), so its entry
# is the person's to remove, with its own command. The same for Codex, whose TOML it owns.
if mcp_has_key "$CLAUDE_CODE_CONFIG"; then
  left "Run 'claude mcp remove --scope user $WL_MCP_NAME' to take it out of Claude Code."
fi
if [[ -f "$CODEX_CONFIG" ]] && grep -Eq "^[[:space:]]*\[mcp_servers\.\"?$WL_MCP_NAME\"?[].]" "$CODEX_CONFIG"; then
  left "Run 'codex mcp remove $WL_MCP_NAME' to take it out of Codex."
fi

if (( ${#APPS[@]} )); then
  step "Privacy answers"
  # tccutil looks the bundle up by identifier, so it runs while the app is still installed.
  for service in ScreenCapture Accessibility AppleEvents; do
    if run tccutil reset "$service" "$WL_BUNDLE_ID" >/dev/null 2>&1; then
      (( DRY_RUN )) || detail "reset $service"
    else
      failed "macOS did not reset $service: remove $WL_APP_NAME in System Settings, Privacy & Security"
    fi
  done
fi

if (( KEYCHAIN_ITEM )); then
  step "Keychain"
  if (( DRY_RUN )); then
    run security delete-generic-password -s "$WL_GOOGLE_SERVICE"
  else
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      run security delete-generic-password -s "$WL_GOOGLE_SERVICE" >/dev/null 2>&1 || break
    done
    detail "deleted \"$WL_GOOGLE_SERVICE\""
  fi
fi

if (( ${#APPS[@]} )); then
  step "The app"
  for app in "${APPS[@]}"; do
    [[ -x "$LSREGISTER" ]] && { run "$LSREGISTER" -u "$app" >/dev/null 2>&1 || true; }
    if run rm -rf "$app"; then
      (( DRY_RUN )) || detail "removed $app"
    else
      failed "could not remove $app: drag it to the Trash"
    fi
  done
  left "Look in System Settings, General, Login Items: if $WL_APP_NAME is still listed, remove it."
fi

if (( ${#LINKS[@]} )); then
  step "The $WL_CLI command"
  for link in "${LINKS[@]}"; do
    if run rm -f "$link"; then (( DRY_RUN )) || detail "removed $link"; else failed "could not remove $link"; fi
  done
fi

if (( PREFS + ${#CACHES[@]} )); then
  step "Preferences and caches"
  if (( PREFS )); then
    run defaults delete "$WL_BUNDLE_ID" >/dev/null 2>&1 || true
    (( DRY_RUN )) || detail "removed the $WL_BUNDLE_ID preferences"
  fi
  for path in ${CACHES[@]+"${CACHES[@]}"}; do
    run rm -rf "$path"
    (( DRY_RUN )) || detail "removed $path"
  done
fi

if (( ${#SUPPORT_ITEMS[@]} )); then
  step "Its folder, $SUPPORT"
  for item in "${SUPPORT_ITEMS[@]}"; do
    run rm -rf "$item"
    (( DRY_RUN )) || detail "removed $item"
  done
fi
if (( ! ALL )) && [[ -d "$REPORTS" ]]; then
  detail "the reports stay in $REPORTS ('--all' removes them too)"
fi

# ------------------------------------------------------------------ what is left

echo
if (( ${#APPS[@]} + ${#LINKS[@]} + ${#SUPPORT_ITEMS[@]} + ${#CACHES[@]} + KEYCHAIN_ITEM + PREFS == 0 )); then
  echo "Nothing of the rehearsal's is installed."
fi
if (( ${#LEFT[@]} )); then
  echo "${BOLD}Left for you:${PLAIN}"
  for line in "${LEFT[@]}"; do echo "    - $line"; done
fi
if (( DRY_RUN )); then
  echo "(dry run — nothing above actually happened)"
elif (( FAILED )); then
  echo "Done, with $FAILED step(s) to finish by hand (above)."
  exit 1
else
  echo "${BOLD}Done.${PLAIN} The real Worklens was not touched."
fi
