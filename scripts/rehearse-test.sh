#!/usr/bin/env bash
# Checks the install rehearsal's scripts against a made-up Mac: scripts/app-identity.sh's guard,
# the refusal of every rehearsal script that would resolve to the real app, rehearse.sh's dry run
# and scripts/rehearse-clean.sh. A fake HOME (with a space in its path) holds a real install and
# a rehearsal side by side; stubs for every command that would reach the real machine (security,
# tccutil, pgrep, pkill, defaults, lsregister) come first on PATH. The scripts run from a copy in
# the fake folder, so not even this checkout's build/ is touched.
#
# usage: scripts/rehearse-test.sh    (exits 1 on the first failed check)
set -uo pipefail

cd "$(dirname "$0")/.."
SOURCE_REPO="$PWD"
REAL_HOME="$HOME"
T="$(mktemp -d "${TMPDIR:-/tmp}/rehearse-test.XXXXXX")" || { echo "FAIL: mktemp" >&2; exit 1; }
[[ "$T" == /?* && -d "$T" ]] || { echo "FAIL: mktemp gave '$T'" >&2; exit 1; }
T="$(cd "$T" && pwd -P)" || exit 1
trap 'rm -rf "$T"' EXIT
H="$T/fake home"
REPO="$T/repo"
STUBS="$T/stubs"
STATE="$T/state"
LOG="$T/calls.log"
REAL_SUPPORT="$H/Library/Application Support/Worklens"
SUPPORT="$H/Library/Application Support/Worklens Rehearsal"
DESKTOP="$H/Library/Application Support/Claude/claude_desktop_config.json"

passed=0
fail() { echo "FAIL: $*" >&2; [[ -f "$T/out" ]] && sed 's/^/    | /' "$T/out" >&2; exit 1; }
pass() { passed=$((passed + 1)); echo "ok    $*"; }

for s in app-identity.sh rehearse.sh rehearse-clean.sh setup.sh bundle.sh sign.sh install.sh installed-app.sh; do
  /bin/bash -n "scripts/$s" || fail "scripts/$s does not parse"
done
pass "the rehearsal scripts parse under /bin/bash $BASH_VERSION"

# ---------------------------------------------------------------- the guard

guard() { (source scripts/app-identity.sh; wl_identity "$1"; shift; wl_guard "$@") >/dev/null 2>&1; }
for real in "/Applications/Worklens.app" "/Applications/Worklens.app/Contents/MacOS/Worklens" \
    "$REAL_SUPPORT" "$REAL_SUPPORT/" "$REAL_SUPPORT/data" "$REAL_SUPPORT/src/build/Worklens Rehearsal.app" \
    "/usr/local/bin/worklens" "worklens" "dev.worklens.app" "dev.worklens.google"; do
  guard rehearsal "$real"; st=$?
  (( st == 70 )) || fail "the rehearsal guard let '$real' through (exit $st)"
done
for own in "/Applications/Worklens Rehearsal.app" "$SUPPORT" "$SUPPORT/data" "/usr/local/bin/worklens-rehearsal" \
    "worklens-rehearsal" "dev.worklens.rehearsal" "dev.worklens.rehearsal.google" "rm" "-rf"; do
  guard rehearsal "$own" || fail "the rehearsal guard refused its own '$own'"
done
guard main "/Applications/Worklens.app" "$REAL_SUPPORT" || fail "the guard refused the real app its own paths"
pass "the guard refuses the real app's paths in a rehearsal, and nothing else"

# ---------------------------------------------------------------- the stubs

mkdir -p "$STUBS" "$T/tmp"
stub() { printf '#!/bin/bash\nSTATE=%q\nLOG=%q\n%s\n' "$STATE" "$LOG" "$2" > "$STUBS/$1"; chmod +x "$STUBS/$1"; }
stub security 'echo "security $*" >> "$LOG"
[[ "$2" == "-s" && "$3" == dev.worklens.rehearsal.google ]] || { echo "UNEXPECTED security $*" >> "$LOG"; exit 1; }
case "$1" in
  find-generic-password) (( $(cat "$STATE/google" 2>/dev/null || echo 0) > 0 )) ;;
  delete-generic-password)
    n=$(cat "$STATE/google" 2>/dev/null || echo 0); (( n > 0 )) || exit 44
    echo $((n - 1)) > "$STATE/google" ;;
  *) echo "UNEXPECTED security $*" >> "$LOG"; exit 1 ;;
esac'
stub tccutil 'echo "tccutil $*" >> "$LOG"'
stub pgrep 'echo "pgrep $*" >> "$LOG"
case " $* " in *" Claude "*) [[ -f "$STATE/claude" ]] ;; *) [[ -f "$STATE/running" ]] ;; esac'
stub pkill 'echo "pkill $*" >> "$LOG"; rm -f "$STATE/running"'
stub defaults 'echo "defaults $*" >> "$LOG"; [[ "$1" == delete ]] && rm -f "$HOME/Library/Preferences/$2.plist"; true'
stub lsregister 'echo "lsregister $*" >> "$LOG"'
for name in osascript killall sudo launchctl sfltool open codesign ditto make swift git; do
  stub "$name" "echo \"UNEXPECTED $name \$*\" >> \"\$LOG\"; exit 1"
done

# ---------------------------------------------------------------- the made-up Mac

fake_app() {
  mkdir -p "$1/Contents/MacOS"
  printf '#!/bin/sh\n' > "$1/Contents/MacOS/Worklens"; chmod +x "$1/Contents/MacOS/Worklens"
  plutil -create xml1 "$1/Contents/Info.plist"
  plutil -insert CFBundleIdentifier -string "$2" "$1/Contents/Info.plist"
}

copy_scripts() {  # $1: the checkout to copy the scripts into
  mkdir -p "$1/scripts"
  for s in app-identity.sh rehearse.sh rehearse-clean.sh setup.sh bundle.sh sign.sh install.sh installed-app.sh; do
    cp "$SOURCE_REPO/scripts/$s" "$1/scripts/$s"
  done
}

make_home() {
  rm -rf "$H" "$STATE" "$REPO" "$LOG"
  mkdir -p "$STATE" "$H/Library/Preferences" "$H/Library/Caches/dev.worklens.app" \
    "$H/Library/Caches/dev.worklens.rehearsal" "$H/Library/Application Support/Claude"
  : > "$LOG"
  : > "$H/Library/Preferences/dev.worklens.app.plist"
  : > "$H/Library/Preferences/dev.worklens.rehearsal.plist"
  echo 1 > "$STATE/google"; : > "$STATE/running"

  copy_scripts "$REPO"
  fake_app "$REPO/build/Worklens Rehearsal.app" dev.worklens.rehearsal
  fake_app "$REPO/build/Worklens.app" dev.worklens.app
  fake_app "$H/Apps/Worklens.app" dev.worklens.app
  fake_app "$H/Apps/Worklens Rehearsal.app" dev.worklens.rehearsal
  fake_app "$H/Applications/Worklens Rehearsal.app" dev.worklens.rehearsal
  mkdir -p "$H/bin" "$H/.local/bin"
  ln -s "$H/Apps/Worklens.app/Contents/MacOS/Worklens" "$H/bin/worklens"
  ln -s "$H/Apps/Worklens Rehearsal.app/Contents/MacOS/Worklens" "$H/bin/worklens-rehearsal"
  ln -s "$H/Applications/Worklens Rehearsal.app/Contents/MacOS/Worklens" "$H/.local/bin/worklens-rehearsal"

  mkdir -p "$REAL_SUPPORT/data" "$SUPPORT/data" "$SUPPORT/rehearsals"
  echo real > "$REAL_SUPPORT/data/worklens.sqlite"
  printf 'GEMINI_API_KEY=test-not-a-key\n' > "$REAL_SUPPORT/.env"
  echo rehearsal > "$SUPPORT/data/worklens.sqlite"
  : > "$SUPPORT/.env"
  echo "# report" > "$SUPPORT/rehearsals/2026-01-01-000000.md"

  cat > "$DESKTOP" <<EOF
{"mcpServers": {"other": {"command": "/bin/other"},
 "worklens": {"command": "$H/Apps/Worklens.app/Contents/MacOS/Worklens", "args": ["mcp"]},
 "worklens-rehearsal": {"command": "$H/Apps/Worklens Rehearsal.app/Contents/MacOS/Worklens", "args": ["mcp"]}},
 "theme": "dark"}
EOF
}

# Runs one script on the made-up Mac with a scrubbed environment; sets status and out.
run_fake() {
  env -i HOME="$H" USER="${USER:-test}" TMPDIR="$T/tmp" \
    PATH="$STUBS:/usr/bin:/bin:/usr/sbin:/sbin" \
    APPS_DIR="${FAKE_APPS_DIR:-$H/Apps}" BIN_DIR="${FAKE_BIN_DIR:-$H/bin}" LSREGISTER="$STUBS/lsregister" \
    /bin/bash "$@" > "$T/out" 2>&1 < /dev/null
  status=$?
  out="$(cat "$T/out")"
  if [[ -n "${VERBOSE:-}" ]]; then echo "--- $* (exit $status)"; cat "$T/out"; fi
  return 0
}

q() { printf '%q' "$1"; }
mutations() { grep -E '^(security delete|tccutil|pkill|defaults delete|lsregister)' "$LOG" || true; }
listing() { (cd "$H" && find . | LC_ALL=C sort; cat "$DESKTOP"); (cd "$REPO" && find . | LC_ALL=C sort); }

check_log() {
  ! grep -q '^UNEXPECTED' "$LOG" || fail "$1: an unexpected command ran: $(grep '^UNEXPECTED' "$LOG")"
  if [[ "$T" != "$REAL_HOME"* ]] && grep -qF "$REAL_HOME/" "$LOG"; then
    fail "$1: a command was handed a path in the real home: $(grep -F "$REAL_HOME/" "$LOG" | head -3)"
  fi
  # Nothing the rehearsal cleaner runs may name the real app.
  if mutations | grep -E 'dev\.worklens\.app|/Worklens\.app|dev\.worklens\.google'; then
    fail "$1: a mutating call named the real app"
  fi
}

real_app_untouched() {
  [[ -d "$H/Apps/Worklens.app" && -L "$H/bin/worklens" && -f "$REAL_SUPPORT/.env" \
     && -f "$REAL_SUPPORT/data/worklens.sqlite" && -f "$H/Library/Preferences/dev.worklens.app.plist" \
     && -d "$H/Library/Caches/dev.worklens.app" && -d "$REPO/build/Worklens.app" ]] \
    || fail "$1: something of the real app's was removed"
  python3 -I - "$DESKTOP" "$H" <<'PYEOF' || fail "$1: the real \"worklens\" entry changed"
import json, sys
servers = json.load(open(sys.argv[1]))["mcpServers"]
assert servers["worklens"]["command"] == sys.argv[2] + "/Apps/Worklens.app/Contents/MacOS/Worklens"
assert servers["other"]["command"] == "/bin/other"
PYEOF
}

# ---------------------------------------------------------------- refusals

# A checkout inside the real app's folder (where the one-line install puts it): every path the
# rehearsal would build under it is inside ~/Library/Application Support/Worklens.
make_home
INSIDE="$REAL_SUPPORT/src"
copy_scripts "$INSIDE"
before="$(listing)"
for cmd in "bundle.sh --rehearsal" "sign.sh --rehearsal" "install.sh --rehearsal" \
    "setup.sh --rehearsal --dry-run --yes" "rehearse.sh --dry-run" "rehearse-clean.sh --yes"; do
  # shellcheck disable=SC2086
  run_fake "$INSIDE/scripts/"$cmd
  (( status == 70 )) || fail "$cmd in a checkout inside the real folder: exit $status, wanted 70"
  [[ "$out" == *"refusing to go on"* ]] || fail "$cmd: no refusal message"
done
[[ "$(listing)" == "$before" ]] || fail "a refused run changed something"
[[ -z "$(mutations)" ]] || fail "a refused run made mutating calls: $(mutations)"
check_log "refusals"
pass "every rehearsal script refuses a checkout inside the real app's folder"

make_home
before="$(listing)"
FAKE_APPS_DIR="$REAL_SUPPORT/apps" run_fake "$REPO/scripts/install.sh" --rehearsal
(( status == 70 )) || fail "install.sh --rehearsal into the real folder: exit $status"
FAKE_BIN_DIR="$REAL_SUPPORT/bin" FAKE_APPS_DIR="$T/apps" run_fake "$REPO/scripts/install.sh" --rehearsal
(( status == 70 )) || fail "install.sh --rehearsal linking into the real folder: exit $status"
[[ "$(listing)" == "$before" ]] || fail "a refused install changed something"
pass "install.sh --rehearsal refuses destinations inside the real app's folder"

# ---------------------------------------------------------------- rehearse.sh --dry-run

make_home
before="$(listing)"
run_fake "$REPO/scripts/rehearse.sh" --dry-run --skip-setup
(( status == 0 )) || fail "rehearse.sh --dry-run: exit $status"
for want in "captures your screen" "your own Claude plan" "never signs in for you" \
    "would run: worklens-rehearsal summaries check" \
    "would run: worklens-rehearsal describe-pending --provider claude --limit 3" \
    "worklens-rehearsal\" and leaves \"worklens\" alone" "would write the report to $SUPPORT/rehearsals/"; do
  [[ "$out" == *"$want"* ]] || fail "rehearse.sh --dry-run does not say '$want'"
done
[[ "$(listing)" == "$before" ]] || fail "rehearse.sh --dry-run changed something"
check_log "rehearse.sh --dry-run"
pass "rehearse.sh --dry-run prints the checklist and changes nothing"

# ---------------------------------------------------------------- rehearse-clean.sh

make_home
before="$(listing)"
run_fake "$REPO/scripts/rehearse-clean.sh"
(( status == 0 )) || fail "dry run: exit $status"
for want in "would run: pkill" "would run: tccutil reset ScreenCapture dev.worklens.rehearsal" \
    "would run: security delete-generic-password -s dev.worklens.rehearsal.google" \
    "rm -rf $(q "$H/Apps/Worklens Rehearsal.app")" "rm -rf $(q "$H/Applications/Worklens Rehearsal.app")" \
    "rm -rf $(q "$REPO/build/Worklens Rehearsal.app")" "rm -f $(q "$H/bin/worklens-rehearsal")" \
    "rm -f $(q "$H/.local/bin/worklens-rehearsal")" \
    "would run: defaults delete dev.worklens.rehearsal" "rm -rf $(q "$SUPPORT/data")" \
    "would take \"worklens-rehearsal\" out of" "the reports stay"; do
  [[ "$out" == *"$want"* ]] || fail "rehearse-clean dry run does not mention '$want'"
done
for unwanted in "/Apps/Worklens.app" "dev.worklens.app" "$REAL_SUPPORT/" "$(q "$REAL_SUPPORT")/" \
    "$(q "$H/bin/worklens") " "$(q "$H/bin/worklens")"$'\n'; do
  [[ "$out" != *"$unwanted"* ]] || fail "rehearse-clean dry run mentions the real app's '$unwanted'"
done
[[ "$(listing)" == "$before" ]] || fail "the dry run changed something"
[[ -z "$(mutations)" ]] || fail "the dry run made mutating calls: $(mutations)"
check_log "rehearse-clean dry run"
pass "rehearse-clean without --yes lists only the rehearsal's things and changes nothing"

# --yes while Claude Desktop is open: everything but its settings.
make_home
: > "$STATE/claude"
run_fake "$REPO/scripts/rehearse-clean.sh" --yes
(( status == 0 )) || fail "--yes: exit $status"
for gone in "$H/Apps/Worklens Rehearsal.app" "$H/Applications/Worklens Rehearsal.app" \
    "$REPO/build/Worklens Rehearsal.app" "$H/bin/worklens-rehearsal" "$H/.local/bin/worklens-rehearsal" \
    "$SUPPORT/data" "$SUPPORT/.env" "$H/Library/Preferences/dev.worklens.rehearsal.plist" \
    "$H/Library/Caches/dev.worklens.rehearsal"; do
  [[ ! -e "$gone" && ! -L "$gone" ]] || fail "--yes left $gone"
done
[[ -f "$SUPPORT/rehearsals/2026-01-01-000000.md" ]] || fail "--yes removed the reports"
[[ ! -f "$STATE/running" ]] || fail "--yes did not quit the rehearsal app"
[[ "$(cat "$STATE/google")" == 0 ]] || fail "--yes left the keychain item"
grep -q '"worklens-rehearsal"' "$DESKTOP" || fail "--yes edited Claude Desktop's settings while it was open"
[[ "$out" == *"Quit Claude Desktop"* ]] || fail "--yes did not say to quit Claude Desktop"
for service in ScreenCapture Accessibility AppleEvents; do
  grep -q "^tccutil reset $service dev.worklens.rehearsal$" "$LOG" || fail "--yes did not reset $service"
done
real_app_untouched "--yes"
check_log "--yes"
pass "rehearse-clean --yes removes the rehearsal, keeps its reports and leaves the real app alone"

# --yes again with Claude Desktop closed: its entry goes, the real one stays.
rm -f "$STATE/claude"
run_fake "$REPO/scripts/rehearse-clean.sh" --yes
(( status == 0 )) || fail "second --yes: exit $status"
! grep -q '"worklens-rehearsal"' "$DESKTOP" || fail "the rehearsal's Claude Desktop entry is still there"
ls "$DESKTOP".worklens-rehearsal-*.bak >/dev/null 2>&1 || fail "no copy of the old Claude Desktop settings"
real_app_untouched "second --yes"
check_log "second --yes"
pass "with Claude Desktop closed it takes out \"worklens-rehearsal\" and only that"

run_fake "$REPO/scripts/rehearse-clean.sh" --yes --all
(( status == 0 )) || fail "--all: exit $status"
[[ ! -e "$SUPPORT" ]] || fail "--all left $SUPPORT"
real_app_untouched "--all"
pass "--all removes the reports too"

run_fake "$REPO/scripts/rehearse-clean.sh"
[[ "$out" == *"Nothing of the rehearsal's is installed."* ]] || fail "a clean Mac does not say so"
pass "a second run finds nothing"

echo "$passed checks passed"
