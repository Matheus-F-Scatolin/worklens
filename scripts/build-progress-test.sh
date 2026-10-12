#!/usr/bin/env bash
# Checks scripts/build-progress.sh against captured output of real builds (#353).
#
# The fixtures in scripts/fixtures/build-progress/ are what `swift build -c release` printed on
# this project, with home-directory paths replaced:
#   swiftbuild-success.txt  `make build` on a clean checkout, swift-build (Swift 6.4, `[n / m]`)
#   native-success.txt      the same build with the classic build system (`[n/m] Linking …`)
#   swiftbuild-failure.txt  a two-error package, colour codes and the failed command line kept
#
# usage: scripts/build-progress-test.sh    (exits 1 on the first failed check)
set -uo pipefail

cd "$(dirname "$0")/.."
HELPER="scripts/build-progress.sh"
FIX="scripts/fixtures/build-progress"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/build-progress-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
SRC="/Users/you/Library/Application Support/Worklens/src"
ESC=$'\033'
CR=$'\r'

passed=0
fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { passed=$((passed + 1)); echo "ok    $*"; }

# Runs the helper in plain mode; sets out, err and status.
run_plain() {
  "$HELPER" --plain --log "$TMP/build.log" --repo "$SRC" -- "$@" > "$TMP/out" 2> "$TMP/err"
  status=$?
  out="$(cat "$TMP/out")"
  err="$(cat "$TMP/err")"
}

# Every progress line: counts that never go backwards and never pass their total.
check_progress_lines() {
  local name="$1" min_lines="$2" prev=0 lines=0 n m
  while IFS= read -r line; do
    if [[ "$line" =~ ^Building\ Worklens\ ·\ ([0-9]+)\ of\ ([0-9]+)\ ·\ [0-9]+:[0-9][0-9]$ ]]; then
      n="${BASH_REMATCH[1]}"; m="${BASH_REMATCH[2]}"
      (( n >= prev )) || fail "$name: count went backwards ($prev, then $n)"
      (( n <= m )) || fail "$name: $n of $m"
      prev=$n; lines=$((lines + 1))
    fi
  done <<< "$out"
  (( lines >= min_lines )) || fail "$name: expected at least $min_lines progress lines, got $lines"$'\n'"$out"
}

[[ -x "$HELPER" ]] || fail "$HELPER is not executable"
bash -n "$HELPER" || fail "$HELPER does not parse"
pass "$HELPER parses"

# ---------------------------------------------------------------- the two successful builds

for fixture in swiftbuild-success native-success; do
  run_plain cat "$FIX/$fixture.txt"
  (( status == 0 )) || fail "$fixture: exit $status"
  [[ "$out$err" != *"$CR"* ]] || fail "$fixture: plain output has a carriage return"
  [[ "$(head -1 "$TMP/out")" == "Building Worklens · starting" ]] || fail "$fixture: first line is '$(head -1 "$TMP/out")'"
  [[ "$(tail -1 "$TMP/out")" =~ ^Built\ Worklens\ ·\ [0-9]+:[0-9][0-9]$ ]] || fail "$fixture: last line is '$(tail -1 "$TMP/out")'"
  [[ -z "$err" ]] || fail "$fixture: printed to stderr: $err"
  [[ "$(wc -l < "$TMP/build.log")" -eq "$(wc -l < "$FIX/$fixture.txt")" ]] || fail "$fixture: the log is not the whole output"
  ! grep -q "$ESC" "$TMP/build.log" || fail "$fixture: the log kept colour codes"
  pass "$fixture: plain lines, whole log, ends in 'Built Worklens'"
done

# swift-build's total grows from 82 to 212 while it plans; the last count is the real one.
run_plain cat "$FIX/swiftbuild-success.txt"
check_progress_lines swiftbuild-success 5
[[ "$out" == *"· 49 of 82 ·"* ]] || fail "swiftbuild-success: the first count '[49 / 82]' was not shown"$'\n'"$out"
[[ "$out" == *"· 193 of 207 ·"* ]] || fail "swiftbuild-success: never reached the last tenth"$'\n'"$out"
[[ "$out" == *"· 128 of 207 ·"* ]] || fail "swiftbuild-success: a grown total moved the fraction back and got no line"$'\n'"$out"
pass "swiftbuild-success: '[n / m]' counted, never backwards, total allowed to grow"

run_plain cat "$FIX/native-success.txt"
check_progress_lines native-success 3
[[ "$out" == *"· 16 of 17 ·"* ]] || fail "native-success: '[16/17] Linking Worklens' was not shown"$'\n'"$out"
pass "native-success: '[n/m] …' counted"

# '[Pre-planning 1 / 185]' is not a count of build steps.
run_plain cat "$FIX/swiftbuild-success.txt"
[[ "$out" != *" of 185 "* ]] || fail "swiftbuild-success: counted '[Pre-planning 1 / 185]'"
pass "pre-planning lines are not counted"

# ---------------------------------------------------------------- a failed build

run_plain bash -c 'cat "$1"; exit 1' _ "$FIX/swiftbuild-failure.txt"
(( status == 1 )) || fail "failure: exit $status, expected the command's 1"
[[ "$err" == *"Building Worklens stopped after "* ]] || fail "failure: no 'stopped after' line"$'\n'"$err"
[[ "$err" == *"Sources/Demo/main.swift:1:21: error: cannot convert value of type 'String' to specified type 'Int'"* ]] \
  || fail "failure: first diagnostic missing or not relative to --repo"$'\n'"$err"
[[ "$err" == *"Sources/Demo/main.swift:2:7: error: cannot find 'missingName' in scope"* ]] || fail "failure: second diagnostic missing"$'\n'"$err"
[[ "$err" != *"$SRC/Sources"* ]] || fail "failure: a path was not shortened"
[[ "$err" != *"$ESC"* ]] || fail "failure: colour codes on screen"
[[ "$err" != *"swift-frontend -frontend"* ]] || fail "failure: printed the failed command line"
[[ "$err" == *"The whole log: $TMP/build.log"* ]] || fail "failure: the log path is not named"
[[ "$err" == *"troubleshooting.md#the-build-stopped-during-setup"* ]] || fail "failure: no troubleshooting link"$'\n'"$err"
[[ "$out$err" != *"$CR"* ]] || fail "failure: plain output has a carriage return"
grep -q 'Failed frontend command' "$TMP/build.log" || fail "failure: the log lost lines the screen left out"
pass "failure: exit status kept, two diagnostics, relative paths, log path, troubleshooting link"

# Each kind of failure names its own section.
expect_anchor() {
  local anchor="$1" text="$2"
  run_plain bash -c 'printf "%s\n" "$1"; exit 1' _ "$text"
  [[ "$err" == *"troubleshooting.md#$anchor"* ]] || fail "'$text' should point at #$anchor"$'\n'"$err"
}
expect_anchor swiftuimacros-not-found \
  "$SRC/Sources/Worklens/App/X.swift:4:6: error: external macro implementation type 'SwiftUIMacros.EntryMacro' could not be found for macro 'Entry()'; plugin for module 'SwiftUIMacros' not found"
expect_anchor no-space-left-on-device "error: write: No space left on device"
expect_anchor the-command-line-tools-are-broken "xcrun: error: invalid active developer path (/Library/Developer/CommandLineTools), missing xcrun"
expect_anchor swift-could-not-download-the-packages "error: Failed to clone repository https://github.com/groue/GRDB.swift.git: fatal: unable to access 'https://github.com/groue/GRDB.swift.git/': Could not resolve host: github.com"
expect_anchor the-build-stopped-during-setup "make: *** [build] Error 1"
pass "each kind of failure names its own troubleshooting section"

# Nothing that looks like an error: the end of the log instead.
run_plain bash -c 'printf "one\ntwo\nlast words\n"; exit 4' _
(( status == 4 )) || fail "exit status 4 came back as $status"
[[ "$err" == *"last words"* ]] || fail "no error lines: the end of the log is not shown"$'\n'"$err"
pass "no error lines: the end of the log, and any exit status passes through"

# doctor.sh's warnings stay in the log when the build works; on a failure they are repeated,
# its 'ok' lines are not.
doctor='printf "ok    swift                  6.4\nwarn  swift-testing          use make test\n[1/2] x\n[2/2] y\n"'
run_plain bash -c "$doctor" _
(( status == 0 )) || fail "toolchain warnings: exit $status"
[[ "$out$err" != *"warn  "* && "$out$err" != *"flagged"* ]] || fail "a working build shows toolchain warnings"$'\n'"$out$err"
grep -q '^warn  swift-testing' "$TMP/build.log" || fail "toolchain warnings are missing from the log"
run_plain bash -c "$doctor; echo 'error: the build failed'; exit 1" _
[[ "$err" == *"warn  swift-testing"* && "$err" == *"warnings, not errors"* && "$err" != *"ok    swift"* ]] \
  || fail "a failed build does not show the toolchain warnings"$'\n'"$err"
pass "toolchain warnings: kept in the log on success, shown on failure"

# ---------------------------------------------------------------- a terminal

if command -v script >/dev/null 2>&1; then
  # macOS script(1): `script -q FILE COMMAND…` runs COMMAND on a pseudo-terminal.
  script -q "$TMP/tty" "$HELPER" --log "$TMP/tty.log" -- bash -c 'cat "$1"; sleep 2' _ "$FIX/swiftbuild-success.txt" > /dev/null 2>&1 < /dev/null
  tty_out="$(cat "$TMP/tty")"
  [[ "$tty_out" == *"${CR}Building Worklens · 211 of 212 · "* ]] || fail "terminal: the line is not redrawn in place"$'\n'"$(printf '%q' "$tty_out")"
  [[ "$tty_out" == *"Built Worklens · 0:0"* ]] || fail "terminal: no 'Built Worklens' line"
  [[ "$(grep -c 'Building Worklens' "$TMP/tty")" -le 2 ]] || fail "terminal: progress printed as separate lines"
  pass "terminal: one line, redrawn in place, cleared at the end"
else
  echo "skip  terminal: no script(1) here"
fi

# ---------------------------------------------------------------- the docs it points at

# The anchors live in docs/user/troubleshooting.md, and every one the helper links to must exist
# there: a missing one opens the top of the page instead of the answer.
for anchor in the-build-stopped-during-setup swiftuimacros-not-found no-space-left-on-device \
  the-command-line-tools-are-broken swift-could-not-download-the-packages; do
  heading="$(grep -E '^#{2,3} ' docs/user/troubleshooting.md \
    | sed -E 's/^#+ //' | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9 -]//g; s/ /-/g' \
    | grep -Fx "$anchor" || true)"
  [[ -n "$heading" ]] || fail "docs/user/troubleshooting.md has no #$anchor section"
done
pass "every anchor the failure report links to is a troubleshooting section"

echo "$passed checks passed"
