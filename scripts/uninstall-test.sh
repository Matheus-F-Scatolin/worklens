#!/usr/bin/env bash
# Checks scripts/uninstall.sh against a made-up Mac: a fake HOME (with a space in its path) that
# holds everything an install leaves behind, and stubs for every command that would reach the
# real machine (security, tccutil, pgrep, pkill, defaults, lsregister) first on PATH. Nothing here
# touches the real keychain, the real privacy database, a real app or a real configuration file.
#
# usage: scripts/uninstall-test.sh    (exits 1 on the first failed check)
set -uo pipefail

cd "$(dirname "$0")/.."
SCRIPT="$PWD/scripts/uninstall.sh"
REAL_HOME="$HOME"
# Every path below is under $T, so $T must be a real, fresh folder before anything is made or
# removed. It is taken as its real path, the way the uninstaller takes HOME.
T="$(mktemp -d "${TMPDIR:-/tmp}/uninstall-test.XXXXXX")" || { echo "FAIL: mktemp" >&2; exit 1; }
[[ "$T" == /?* && -d "$T" ]] || { echo "FAIL: mktemp gave '$T'" >&2; exit 1; }
T="$(cd "$T" && pwd -P)" || exit 1
trap 'rm -rf "$T"' EXIT
H="$T/fake home"
STUBS="$T/stubs"
STATE="$T/state"
LOG="$T/calls.log"
SUPPORT="$H/Library/Application Support/Worklens"
SRC="$SUPPORT/src"
CERT_HASH="7ED8D4ABC4786911F54194C8475777AE83ED36A9"
OTHER_HASH="1111111111111111111111111111111111111111"

passed=0
fail() { echo "FAIL: $*" >&2; [[ -f "$T/out" ]] && sed 's/^/    | /' "$T/out" >&2; exit 1; }
pass() { passed=$((passed + 1)); echo "ok    $*"; }

[[ -x "$SCRIPT" ]] || fail "$SCRIPT is not executable"
/bin/bash -n "$SCRIPT" || fail "$SCRIPT does not parse"
pass "uninstall.sh parses under /bin/bash $BASH_VERSION"

# ---------------------------------------------------------------- the stubs

mkdir -p "$STUBS" "$T/tmp"
stub() { printf '#!/bin/bash\nSTATE=%q\nLOG=%q\n%s\n' "$STATE" "$LOG" "$2" > "$STUBS/$1"; chmod +x "$STUBS/$1"; }

stub security 'echo "security $*" >> "$LOG"
case "$1" in
  find-certificate)
    [[ -f "$STATE/cert" ]] || exit 44
    for pair in "'"$CERT_HASH"':Worklens Dev" "'"$OTHER_HASH"':Worklens Dev 2"; do
      echo "SHA-256 hash: 00"; echo "SHA-1 hash: ${pair%%:*}"
      echo "keychain: \"$HOME/Library/Keychains/login.keychain-db\""
      echo "attributes:"; echo "    \"labl\"<blob>=\"${pair#*:}\""
    done ;;
  delete-identity) [[ -f "$STATE/cert" ]] || exit 44; rm -f "$STATE/cert" ;;
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
# TEST_PYTHON=/path/to/python3.11+ runs the TOML edit through tomllib's check as well.
if [[ -n "${TEST_PYTHON:-}" ]]; then ln -s "$TEST_PYTHON" "$STUBS/python3"; fi
for name in osascript killall sudo launchctl sfltool open; do
  stub "$name" "echo \"UNEXPECTED $name \$*\" >> \"\$LOG\"; exit 1"
done

# ---------------------------------------------------------------- the made-up Mac

# Git for the fixtures runs with nothing of this Mac's: no real HOME, global or system config,
# hooks, signing, or GIT_DIR pointing at a real repository.
mkdir -p "$T/gitHome"
git_() {
  env -i HOME="$T/gitHome" PATH=/usr/bin:/bin GIT_CONFIG_NOSYSTEM=1 \
    git -c core.hooksPath=/dev/null -c commit.gpgsign=false -c user.name=test \
      -c user.email=test@example.invalid -c init.defaultBranch=main "$@" >/dev/null 2>&1
}

fake_app() {
  mkdir -p "$1/Contents/MacOS"
  printf '#!/bin/sh\n' > "$1/Contents/MacOS/Worklens"
  plutil -create xml1 "$1/Contents/Info.plist"
  plutil -insert CFBundleIdentifier -string "$2" "$1/Contents/Info.plist"
}

make_home() {
  rm -rf "$H" "$STATE" "$T/origin.git" "$LOG"
  mkdir -p "$STATE" "$H/Library/Keychains" "$H/Library/Preferences" "$H/Library/Caches/dev.worklens.app"
  : > "$H/Library/Keychains/login.keychain-db"
  : > "$H/Library/Preferences/dev.worklens.app.plist"
  : > "$STATE/cert"; echo 2 > "$STATE/google"; : > "$STATE/running"
  : > "$LOG"

  fake_app "$H/Apps/Worklens.app" dev.worklens.app
  fake_app "$H/Applications/Worklens.app" dev.worklens.app
  fake_app "$H/Apps/Other.app" com.example.other
  mkdir -p "$H/bin" "$H/.local/bin"
  ln -s "$H/Apps/Worklens.app/Contents/MacOS/Worklens" "$H/bin/worklens"
  ln -s /usr/bin/true "$H/.local/bin/worklens"

  mkdir -p "$SUPPORT/data/screenshots"
  printf 'GEMINI_API_KEY=test-not-a-key\n' > "$SUPPORT/.env"
  echo '{}' > "$SUPPORT/settings.json"
  echo db > "$SUPPORT/data/worklens.sqlite"
  echo jpg > "$SUPPORT/data/screenshots/one.jpg"

  git_ init --bare "$T/origin.git"
  mkdir -p "$SRC/scripts"
  echo '// swift-tools-version:6.1' > "$SRC/Package.swift"
  : > "$SRC/scripts/setup.sh"
  printf '.env\n.env.*\ndata/\n.build/\n*.sqlite\ncaptures/\n' > "$SRC/.gitignore"
  mkdir -p "$SRC/.build/debug"; : > "$SRC/.build/debug/Worklens"
  cp "$SCRIPT" "$SRC/scripts/uninstall.sh"
  git_ -C "$SRC" init
  git_ -C "$SRC" add -A
  git_ -C "$SRC" commit -m one
  git_ -C "$SRC" remote add origin "$T/origin.git"
  git_ -C "$SRC" push -u origin main

  mkdir -p "$H/Library/Application Support/Claude" "$H/.codex"
  cat > "$H/Library/Application Support/Claude/claude_desktop_config.json" <<EOF
{"mcpServers": {"other": {"command": "/bin/other"}, "worklens": {"command": "$H/Apps/Worklens.app/Contents/MacOS/Worklens", "args": ["mcp"]}}, "theme": "dark"}
EOF
  cat > "$H/.claude.json" <<EOF
{"numStartups": 3, "mcpServers": {"wl": {"command": "$H/Apps/Worklens.app/Contents/MacOS/Worklens", "args": ["mcp"]}, "keep": {"command": "/bin/keep"}}}
EOF
  cat > "$H/.codex/config.toml" <<EOF
model = "x"

[mcp_servers.other]
command = "/bin/other"

[mcp_servers.worklens]
command = "$H/Apps/Worklens.app/Contents/MacOS/Worklens"
args = ["mcp"]

[mcp_servers.worklens.env]
A = "b"

[[hooks]]
name = "h"

[profiles.fast]
model = "y"
notes = """
[mcp_servers.worklens]
keep me
"""
EOF
}

# Runs the uninstaller on the made-up Mac with a scrubbed environment; sets status and out.
# Stdin is $IN (default: no terminal at all).
IN=/dev/null
uninstall() {
  env -i HOME="${FAKE_HOME:-$H}" USER="${USER:-test}" TMPDIR="$T/tmp" \
    WORKLENS_UNINSTALL_COPY="${SPOOF:-}" \
    PATH="$STUBS:/usr/bin:/bin:/usr/sbin:/sbin" \
    APPS_DIR="$H/Apps" BIN_DIR="$H/bin" LSREGISTER="$STUBS/lsregister" \
    /bin/bash "$@" > "$T/out" 2>&1 < "$IN"
  status=$?
  out="$(cat "$T/out")"
  # VERBOSE=1 prints every run, to read what a person would see.
  if [[ -n "${VERBOSE:-}" ]]; then echo "--- uninstall.sh ${*:2} (exit $status)"; cat "$T/out"; fi
  return "$status"
}

mutations() { grep -E '^(security delete|tccutil|pkill|defaults delete|lsregister)' "$LOG" || true; }

check_log_is_fake() {
  ! grep -q '^UNEXPECTED' "$LOG" || fail "$1: an unexpected command ran: $(grep '^UNEXPECTED' "$LOG")"
  if [[ "$T" != "$REAL_HOME"* ]] && grep -qF "$REAL_HOME/" "$LOG"; then
    fail "$1: a command was handed a path in the real home: $(grep -F "$REAL_HOME/" "$LOG" | head -3)"
  fi
  if grep -q 'login.keychain-db' "$LOG" && grep 'login.keychain-db' "$LOG" | grep -vqF "$H/Library/Keychains/login.keychain-db"; then
    fail "$1: a keychain other than the fake one was named"
  fi
}

everything_still_there() {
  [[ -d "$H/Apps/Worklens.app" && -d "$H/Applications/Worklens.app" && -L "$H/bin/worklens" \
     && -d "$SRC" && -f "$SUPPORT/.env" && -f "$STATE/cert" && -f "$STATE/running" ]] \
    || fail "$1: something was removed"
  grep -q '"worklens"' "$H/Library/Application Support/Claude/claude_desktop_config.json" || fail "$1: Claude Desktop config changed"
  [[ -z "$(mutations)" ]] || fail "$1: mutating calls: $(mutations)"
}

# ---------------------------------------------------------------- dry run

make_home
uninstall "$SCRIPT" --dry-run
(( status == 0 )) || fail "dry run: exit $status"
for want in "quit the running Worklens" "Claude Desktop's settings" "Claude Code's settings" \
    "Codex's settings" "Google Calendar token" "\"Worklens Dev\" signing certificate" \
    "$H/Apps/Worklens.app" "$H/Applications/Worklens.app" "the worklens command at $H/bin/worklens" \
    "the source at $SRC" "keeping your data in $SUPPORT" "would run: tccutil reset ScreenCapture dev.worklens.app"; do
  [[ "$out" == *"$want"* ]] || fail "dry run: does not mention '$want'"
done
[[ "$out" != *"Other.app"* ]] || fail "dry run: lists an app that is not Worklens"
[[ "$out" == *"points at /usr/bin/true"* ]] || fail "dry run: does not say it keeps the unrelated worklens link"
everything_still_there "dry run"
check_log_is_fake "dry run"
pass "--dry-run lists everything and changes nothing"

uninstall -c "$(cat "$SCRIPT")" -- --dry-run
(( status == 0 )) && [[ "$out" == *"dry run: nothing above actually happened"* ]] || fail "one-line form: exit $status"
everything_still_there "one-line dry run"
pass "the one-line bash -c form runs (dry run)"

# ---------------------------------------------------------------- no terminal, no --yes

uninstall "$SCRIPT"
(( status == 0 )) && [[ "$out" == *"Nothing was changed."* ]] || fail "no terminal: exit $status"
everything_still_there "no terminal"
pass "without a terminal or --yes it asks, reads no answer and changes nothing"

IN="$T/no"; echo n > "$IN"
uninstall "$SCRIPT"
[[ "$out" == *"Nothing was changed."* ]] || fail "answer n: went ahead"
everything_still_there "answer n"
IN=/dev/null
pass "answering n changes nothing"

# ---------------------------------------------------------------- --yes keeps the data

make_home
uninstall "$SCRIPT" --yes
(( status == 0 )) || fail "--yes: exit $status"
[[ ! -e "$H/Apps/Worklens.app" && ! -e "$H/Applications/Worklens.app" ]] || fail "--yes: an app is still there"
[[ -d "$H/Apps/Other.app" ]] || fail "--yes: removed an app that is not Worklens"
[[ ! -e "$H/bin/worklens" ]] || fail "--yes: the worklens link is still there"
[[ -L "$H/.local/bin/worklens" ]] || fail "--yes: removed a worklens link that pointed elsewhere"
[[ ! -e "$SRC" ]] || fail "--yes: the source is still there"
[[ -f "$SUPPORT/.env" && -f "$SUPPORT/settings.json" && -f "$SUPPORT/data/worklens.sqlite" && -f "$SUPPORT/data/screenshots/one.jpg" ]] \
  || fail "--yes: deleted data"
[[ "$out" == *"Your data stays in $SUPPORT"* ]] || fail "--yes: does not say where the data stays"
[[ ! -f "$STATE/cert" && "$(cat "$STATE/google")" == 0 && ! -f "$STATE/running" ]] || fail "--yes: cert, token or app left"
grep -q "security delete-identity -Z $CERT_HASH -t $H/Library/Keychains/login.keychain-db" "$LOG" || fail "--yes: certificate not deleted by hash"
! grep -q "$OTHER_HASH" <(grep delete "$LOG") || fail "--yes: deleted a certificate with a different name"
for service in ScreenCapture Accessibility AppleEvents; do
  grep -q "tccutil reset $service dev.worklens.app" "$LOG" || fail "--yes: $service not reset"
done
grep -q "defaults delete dev.worklens.app" "$LOG" || fail "--yes: preferences kept"
[[ ! -e "$H/Library/Caches/dev.worklens.app" ]] || fail "--yes: caches kept"
check_log_is_fake "--yes"
pass "--yes removes the app, link, source, certificate, token and privacy answers, and keeps the data"

cd_json="$H/Library/Application Support/Claude/claude_desktop_config.json"
/usr/bin/python3 -I - "$cd_json" "$H/.claude.json" <<'EOF' || fail "--yes: JSON configs are wrong"
import json, sys
desktop = json.load(open(sys.argv[1])); code = json.load(open(sys.argv[2]))
assert desktop["mcpServers"] == {"other": {"command": "/bin/other"}}, desktop
assert desktop["theme"] == "dark"
assert code["numStartups"] == 3 and list(code["mcpServers"]) == ["keep"], code
EOF
ls "$cd_json".worklens-*.bak >/dev/null 2>&1 || fail "--yes: no backup beside Claude Desktop's config"
grep -q '"worklens"' "$cd_json".worklens-*.bak || fail "--yes: the backup is not the old file"
toml="$(cat "$H/.codex/config.toml")"
[[ "$toml" != *'args = ["mcp"]'* && "$toml" != *'A = "b"'* && "$toml" == *"[mcp_servers.other]"* \
   && "$toml" == *"[[hooks]]"* && "$toml" == *'name = "h"'* && "$toml" == *"[profiles.fast]"* \
   && "$toml" == *'model = "y"'* && "$toml" == *"keep me"* ]] \
  || fail "--yes: Codex config is wrong:"$'\n'"$toml"
pass "only the Worklens MCP entry goes (a renamed one too); [[arrays]], strings and the rest stay; a backup is kept"

uninstall "$SCRIPT" --yes
(( status == 0 )) || fail "re-run: exit $status"
[[ "$out" == *"Worklens is already removed; only your data is left"* ]] || fail "re-run: did not say only data is left"
[[ -f "$SUPPORT/data/worklens.sqlite" ]] || fail "re-run: deleted data"
pass "running it again is safe and says only the data is left"

uninstall "$SCRIPT" --yes --delete-data
(( status == 0 )) && [[ ! -e "$SUPPORT" ]] || fail "--delete-data after --yes: exit $status, data still there"
pass "--yes --delete-data deletes the data folder"

uninstall "$SCRIPT" --yes
(( status == 0 )) && [[ "$out" == *"Worklens is not on this Mac"* ]] || fail "nothing left: exit $status"
pass "on a Mac with nothing left it says so"

# ---------------------------------------------------------------- the data question

make_home
IN="$T/answers"; printf 'y\ny\n' > "$IN"
uninstall "$SCRIPT"
[[ -f "$SUPPORT/data/worklens.sqlite" && ! -e "$H/Apps/Worklens.app" ]] || fail "interactive y, y: data deleted or app kept"
pass "interactive: a y to the data question keeps the data (only 'delete' deletes it)"

make_home
printf 'y\ndelete\n' > "$IN"
uninstall "$SCRIPT"
[[ ! -e "$SUPPORT" ]] || fail "interactive y, delete: data kept"
pass "interactive: typing delete deletes the data"
IN=/dev/null

# ---------------------------------------------------------------- what makes it keep things

make_home
: > "$STATE/claude"
uninstall "$SCRIPT" --yes
grep -q '"worklens"' "$cd_json" || fail "Claude Desktop open: its config was changed"
[[ "$out" == *"Quit Claude Desktop, then run this again"* ]] || fail "Claude Desktop open: does not say to quit it"
[[ "$(cat "$H/.claude.json")" != *'"wl"'* ]] || fail "Claude Desktop open: Claude Code entry not removed"
pass "with Claude Desktop open its config is left alone and you are told to quit it first"

make_home
echo change >> "$SRC/Package.swift"
uninstall "$SCRIPT" --yes
[[ -d "$SRC" && "$out" == *"keeping $SRC: it has changes or files of your own"* ]] || fail "dirty checkout: removed"
pass "a checkout with uncommitted changes is kept"

make_home
git_ -C "$SRC" commit --allow-empty -m local
uninstall "$SCRIPT" --yes
[[ -d "$SRC" && "$out" == *"not on GitHub"* ]] || fail "unpushed commit: removed"
uninstall "$SCRIPT" --yes --delete-data
[[ -d "$SRC" && ! -e "$SUPPORT/data" && ! -e "$SUPPORT/.env" ]] || fail "unpushed commit + --delete-data: wrong"
pass "a checkout with unpushed commits is kept, even when the data beside it is deleted"

make_home
printf 'DATA_DIR=src/data\n' >> "$SUPPORT/.env"
mkdir -p "$SRC/data"; echo db > "$SRC/data/worklens.sqlite"
uninstall "$SCRIPT" --yes
[[ -f "$SRC/data/worklens.sqlite" ]] || fail "data inside the checkout: deleted"
pass "a checkout that holds the data folder is kept"

make_home
printf 'DATA_DIR=data/../src/private\n' >> "$SUPPORT/.env"
mkdir -p "$SRC/private"; echo db > "$SRC/private/worklens.sqlite"
uninstall "$SCRIPT" --yes --delete-data
[[ -f "$SRC/private/worklens.sqlite" ]] || fail "DATA_DIR through ..: deleted with the checkout"
pass "a DATA_DIR that reaches into the checkout through .. keeps it"

make_home
echo GEMINI_API_KEY=other > "$SRC/.env.production"
uninstall "$SCRIPT" --yes
[[ -f "$SRC/.env.production" && "$out" == *"files of your own"*".env.production"* ]] || fail "ignored .env.production: deleted"
pass "a checkout holding a file git ignores (not a build folder) is kept"

make_home
echo change >> "$SRC/Package.swift"
echo KEY=x > "$SRC/.env"
uninstall "$SCRIPT" --yes --delete-data
[[ -d "$SRC" && "$(tail -1 "$SRC/Package.swift")" == change && ! -e "$SUPPORT/data" ]] || fail "dirty + --delete-data: wrong"
pass "--delete-data deletes the data but never a checkout with changes of your own"

make_home
git_ -C "$SRC" checkout --detach
git_ -C "$SRC" commit --allow-empty -m detached
uninstall "$SCRIPT" --yes
[[ -d "$SRC" && "$out" == *"not on GitHub"* ]] || fail "detached unpushed commit: removed"
pass "a checkout with an unpushed commit on a detached HEAD is kept"

make_home
printf 'DATA_DIR=~/Library/Caches/dev.worklens.app\n' >> "$SUPPORT/.env"
echo db > "$H/Library/Caches/dev.worklens.app/worklens.sqlite"
uninstall "$SCRIPT" --yes
[[ -f "$H/Library/Caches/dev.worklens.app/worklens.sqlite" ]] || fail "data in the caches folder: deleted"
pass "a cache folder that is a data folder stays"

make_home
mkdir -p "$H/dotfiles"; mv "$H/.codex/config.toml" "$H/dotfiles/codex-config"
ln -s "$H/dotfiles/codex-config" "$H/.codex/config.toml"
mv "$H/.claude.json" "$T/outside.json"; ln -s "$T/outside.json" "$H/.claude.json"
uninstall "$SCRIPT" --yes
[[ -L "$H/.codex/config.toml" && "$(cat "$H/dotfiles/codex-config")" != *'args = ["mcp"]'* ]] || fail "linked Codex config: not edited through the link"
[[ "$(cat "$T/outside.json")" == *'"wl"'* && "$out" == *"outside your home folder"* ]] || fail "config outside HOME: edited"
pass "a linked config is edited where it points, and never outside the home folder"

make_home
echo keep > "$T/victim"
SPOOF="$T/victim" uninstall "$SCRIPT" --dry-run
[[ -f "$T/victim" ]] || fail "spoofed WORKLENS_UNINSTALL_COPY: deleted"
pass "an inherited WORKLENS_UNINSTALL_COPY names nothing it deletes"

FAKE_HOME=// uninstall "$SCRIPT" --dry-run
(( status == 1 )) && [[ "$out" == *"HOME is /"* ]] || fail "HOME=//: exit $status"
pass "a HOME that is / is refused"

make_home
mkdir -p "$H/elsewhere"; echo db > "$H/elsewhere/worklens.sqlite"
printf 'export DATA_DIR = "~/elsewhere"  # spelled every way DotEnv.swift reads\n' >> "$SUPPORT/.env"
uninstall "$SCRIPT" --yes --delete-data
[[ -f "$H/elsewhere/worklens.sqlite" && ! -e "$SUPPORT" ]] || fail "outside DATA_DIR: deleted, or the support folder kept"
[[ "$out" == *"$H/elsewhere is outside"* ]] || fail "outside DATA_DIR: not named"
pass "a DATA_DIR outside Application Support is never deleted, and is named"

# ---------------------------------------------------------------- the checkout it lives in

make_home
leftovers_before="$(ls "$T/tmp" | wc -l | tr -d ' ')"
(cd "$SRC" && uninstall "$SRC/scripts/uninstall.sh" --yes --delete-data)
status=$?; out="$(cat "$T/out")"
(( status == 0 )) || fail "run from the checkout it removes: exit $status"
[[ ! -e "$SRC" && ! -e "$SUPPORT" ]] || fail "run from the checkout: not removed"
[[ "$(tail -1 "$T/out")" == *"Worklens is removed from this Mac."* ]] || fail "run from the checkout: did not reach its last line"
[[ "$(ls "$T/tmp" | wc -l | tr -d ' ')" == "$leftovers_before" ]] || fail "run from the checkout: left a temporary copy behind"
check_log_is_fake "self-removal"
pass "run from inside the checkout it deletes, it finishes from a copy and cleans the copy up"

echo
echo "$passed checks passed"
