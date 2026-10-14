#!/usr/bin/env bash
# Checks scripts/bootstrap.sh's toolchain step against stand-in tools: a Mac with no command line
# tools, one whose tools are broken, and an install that finishes, is cancelled or never ends.
#
# Nothing real is touched. xcode-select, swift, git and pgrep are small scripts first on PATH that
# keep their state in a temporary folder, HOME points into that folder too, and every run that
# gets past the consent uses --clone-only with a git that only writes down what it was asked.
#
# usage: scripts/bootstrap-test.sh    (exits 1 on the first failed check)
set -uo pipefail

cd "$(dirname "$0")/.."
SCRIPT="scripts/bootstrap.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { passed=$((passed + 1)); echo "ok    $*"; }
passed=0

# Every path below hangs off TMP, HOME included, so no TMP means no run at all.
TMP="$(mktemp -d "${TMPDIR:-/tmp}/bootstrap-test.XXXXXX")" && [[ -d "$TMP" ]] || fail "mktemp failed"
trap 'rm -rf "$TMP"' EXIT
BIN="$TMP/bin"
STATE="$TMP/state"
mkdir -p "$BIN" || fail "could not make $BIN"

# ---------------------------------------------------------------- the stand-in tools

# $STATE/dev is the developer directory once it exists; $STATE/installed means the tools work;
# $STATE/requested means bootstrap ran `xcode-select --install`. STUB_INSTALL says how the install
# goes, counted in bootstrap's own checks rather than in seconds, so a slow machine sees the same
# sequence: `finish` brings the tools on the third check with the installer window still open,
# `cancel` shows the window for two checks and then closes it, `hang` keeps it open forever,
# `nowindow` never shows one, `already` and `fail` refuse to start.
cat > "$BIN/xcode-select" <<'EOF'
#!/bin/bash
S="$STUB_STATE"
case "$1" in
  -p)
    if [[ -e "$S/requested" && "$STUB_INSTALL" == finish ]]; then
      echo x >> "$S/checks"
      if (( $(wc -l < "$S/checks") >= 3 )); then
        mkdir -p "$S/dev"; rm -f "$S/broken" "$S/swift-ok"; touch "$S/installed"
      fi
    fi
    if [[ -e "$S/installed" || -e "$S/broken" ]]; then echo "$S/dev"; exit 0; fi
    echo "xcode-select: error: unable to get active developer directory" >&2
    exit 2 ;;
  --install)
    echo install >> "$S/calls"
    case "$STUB_INSTALL" in
      already)
        echo 'xcode-select: error: command line tools are already installed, use "Software Update" in System Settings to install updates' >&2
        exit 1 ;;
      fail)
        echo 'xcode-select: error: the install could not be requested (stand-in)' >&2
        exit 1 ;;
    esac
    echo "xcode-select: note: install requested for command line developer tools"
    touch "$S/requested" ;;
esac
EOF
cat > "$BIN/swift" <<'EOF'
#!/bin/bash
echo swift >> "$STUB_STATE/calls"
[[ -e "$STUB_STATE/installed" || -e "$STUB_STATE/swift-ok" ]] || { echo "xcrun: error: unable to find utility \"swift\"" >&2; exit 72; }
echo "swift-driver version: 1.0 Apple Swift version 6.4 (stand-in)"
EOF
cat > "$BIN/git" <<'EOF'
#!/bin/bash
echo "git $1" >> "$STUB_STATE/calls"
[[ -e "$STUB_STATE/installed" ]] || exit 72
[[ "$1" == clone ]] && echo "clone $3" >> "$STUB_STATE/calls"
exit 0
EOF
cat > "$BIN/pgrep" <<'EOF'
#!/bin/bash
S="$STUB_STATE"
[[ -e "$S/requested" ]] || exit 1
case "$STUB_INSTALL" in
  cancel) echo x >> "$S/looks"; (( $(wc -l < "$S/looks") <= 2 )) ;;
  nowindow) exit 1 ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$BIN"/* || fail "could not make the stand-in tools executable"
for tool in xcode-select swift git pgrep; do
  [[ "$(PATH="$BIN:/usr/bin:/bin" command -v "$tool")" == "$BIN/$tool" ]] || fail "the stand-in $tool is not first on PATH"
done

# Runs bootstrap from a fresh state; $1 is the starting toolchain: missing, ready, broken (a
# developer directory that runs neither), broken-git (Swift runs, git does not) or gone (a
# developer directory that no longer exists).
# Sets out, err, calls and status.
run() {
  local start="$1"; shift
  rm -rf "$STATE" "$TMP/home"; mkdir -p "$STATE" "$TMP/home"; : > "$STATE/calls"
  case "$start" in
    ready) mkdir -p "$STATE/dev"; touch "$STATE/installed" ;;
    broken) mkdir -p "$STATE/dev"; touch "$STATE/broken" ;;
    broken-git) mkdir -p "$STATE/dev"; touch "$STATE/broken" "$STATE/swift-ok" ;;
    gone) touch "$STATE/installed" ;;  # xcode-select names a folder that is not there
  esac
  env HOME="$TMP/home" PATH="$BIN:/usr/bin:/bin" STUB_STATE="$STATE" \
    STUB_INSTALL="${STUB_INSTALL:-finish}" WORKLENS_CLT_POLL=0.1 WORKLENS_CLT_NOTE=0 \
    WORKLENS_CLT_UNSEEN="${UNSEEN:-600}" WORKLENS_CLT_TIMEOUT="${TIMEOUT:-60}" \
    bash "$SCRIPT" "$@" > "$TMP/out" 2> "$TMP/err" < /dev/null
  status=$?
  out="$(cat "$TMP/out")"
  err="$(cat "$TMP/err")"
  calls="$(cat "$STATE/calls")"
}

# No em or en dash in what a person reads (docs/copy.md).
no_dashes() {
  [[ "$out$err" != *"—"* && "$out$err" != *"–"* ]] || fail "$1: printed a dash"$'\n'"$out$err"
}

bash -n "$SCRIPT" || fail "$SCRIPT does not parse"
pass "$SCRIPT parses"

run ready --help
[[ "$out" == *"--dry-run"* && "$out" == *"--clone-only"* ]] || fail "--help: no usage"$'\n'"$out"
pass "--help prints the usage"

# ---------------------------------------------------------------- the plan, before any write

run missing --dry-run
(( status == 0 )) || fail "missing, dry run: exit $status"$'\n'"$err"
[[ "$out" == *"install Apple's command line tools"* ]] || fail "missing, dry run: the plan does not name the tools"$'\n'"$out"
[[ "$out" == *"would run 'xcode-select --install'"* ]] || fail "missing, dry run: does not say it would install them"$'\n'"$out"
[[ -z "$calls" ]] || fail "missing, dry run: ran $calls"
[[ ! -e "$TMP/home/Library" ]] || fail "missing, dry run: wrote under HOME"
pass "missing tools, dry run: named in the plan, nothing run, swift and git never touched"

run ready --dry-run
(( status == 0 )) || fail "ready, dry run: exit $status"
[[ "$out" != *"command line tools"* ]] || fail "ready, dry run: mentions the tools"$'\n'"$out"
[[ "$out" == *"Apple Swift version 6.4"* ]] || fail "ready, dry run: no Swift version"$'\n'"$out"
[[ "$calls" != *install* ]] || fail "ready, dry run: asked for an install"
pass "tools present, dry run: the plan is unchanged"

run missing
(( status == 0 )) || fail "missing, declined: exit $status"
[[ "$out" == *"Nothing was changed."* ]] || fail "missing, declined: $out"
[[ -z "$calls" ]] || fail "missing, declined: ran $calls"
pass "missing tools, no answer: nothing is installed"

# ---------------------------------------------------------------- the install

STUB_INSTALL=finish run missing --yes --clone-only
(( status == 0 )) || fail "missing, install: exit $status"$'\n'"$out"$'\n'"$err"
[[ "$out" == *"Installing Apple's command line tools"* ]] || fail "missing, install: no step"$'\n'"$out"
[[ "$out" == *"A macOS dialog is waiting for you"* ]] || fail "missing, install: off a terminal, does not say a dialog is waiting"$'\n'"$out"
[[ "$out" == *"Waiting for the command line tools · 0:0"* ]] || fail "missing, install: no progress line"$'\n'"$out"
[[ "$out" == *"The command line tools are installed."* ]] || fail "missing, install: never said the tools arrived"$'\n'"$out"
[[ "$calls" == *"clone $TMP/home/Library/Application Support/Worklens/src"* ]] || fail "missing, install: did not go on to the clone"$'\n'"$calls"
[[ "$(head -1 "$STATE/calls")" == install ]] || fail "missing, install: ran something before the install: $calls"
no_dashes "missing, install"
pass "missing tools, --yes: installed through Apple's dialog, waited, then carried on to the clone"

STUB_INSTALL=cancel run missing --yes --clone-only
(( status == 1 )) || fail "missing, cancelled: exit $status"
[[ "$err" == *"Apple's dialog closed"* && "$err" == *"safe"* ]] || fail "missing, cancelled: $err"
[[ "$calls" != *clone* ]] || fail "missing, cancelled: cloned anyway"
no_dashes "missing, cancelled"
pass "missing tools, dialog cancelled: stops, says re-running is safe"

TIMEOUT=2 STUB_INSTALL=hang run missing --yes --clone-only
(( status == 1 )) || fail "missing, timeout: exit $status"
[[ "$err" == *"did not appear within 2 seconds"* && "$err" == *"safe"* ]] || fail "missing, timeout: $err"
[[ "$calls" != *clone* ]] || fail "missing, timeout: cloned anyway"
no_dashes "missing, timeout"
pass "missing tools, no tools by the ceiling: stops, says re-running is safe"

UNSEEN=0 TIMEOUT=1 STUB_INSTALL=nowindow run missing --yes --clone-only
(( status == 1 )) || fail "missing, no window: exit $status"
[[ "$out" == *"installer window has not shown up"* ]] || fail "missing, no window: never said so"$'\n'"$out"
[[ "$(grep -c 'has not shown up' "$TMP/out")" -eq 1 ]] || fail "missing, no window: said it more than once"
[[ "$err" == *"did not appear within"* ]] || fail "missing, no window: did not wait to the ceiling: $err"
pass "missing tools, no installer window ever seen: says so once, keeps waiting"

STUB_INSTALL=fail run missing --yes --clone-only
(( status == 1 )) || fail "missing, install refused: exit $status"
[[ "$err" == *"could not start installing"* && "$err" == *"(stand-in)"* && "$err" == *"safe"* ]] || fail "missing, install refused: $err"
[[ "$calls" != *clone* ]] || fail "missing, install refused: cloned anyway"
no_dashes "missing, install refused"
pass "missing tools, xcode-select refuses: stops with what macOS said"

# ---------------------------------------------------------------- the half-broken case

STUB_INSTALL=already run broken --yes --clone-only
(( status == 1 )) || fail "broken, already installed: exit $status"
[[ "$out" == *"they look broken"* ]] || fail "broken: not called broken"$'\n'"$out"
[[ "$err" == *"already installed"* && "$err" == *"#the-command-line-tools-are-broken"* ]] || fail "broken, already installed: $err"
[[ "$calls" != *clone* ]] || fail "broken, already installed: cloned anyway"
no_dashes "broken, already installed"
pass "broken tools macOS will not reinstall: stops with the troubleshooting section"

STUB_INSTALL=finish run broken --yes --clone-only
(( status == 0 )) || fail "broken, reinstalled: exit $status"$'\n'"$err"
[[ "$calls" == *clone* ]] || fail "broken, reinstalled: did not go on to the clone"
pass "broken tools macOS reinstalls: carries on"

run broken-git --dry-run
(( status == 0 )) || fail "broken git, dry run: exit $status"
[[ "$out" == *"they look broken"* && "$out" == *"install Apple's command line tools"* ]] || fail "broken git: Swift alone counted as ready"$'\n'"$out"
[[ "$calls" != *install* ]] || fail "broken git, dry run: asked for an install"
pass "Swift runs but git does not: broken, and named in the plan"

run gone --dry-run
(( status == 0 )) || fail "deleted developer folder, dry run: exit $status"
[[ "$out" == *"they look broken"* ]] || fail "deleted developer folder: not called broken"$'\n'"$out"
[[ "$calls" != *swift* && "$calls" != *git* ]] || fail "deleted developer folder: ran $calls"
pass "a developer folder that no longer exists: broken, without running swift or git"

# ---------------------------------------------------------------- the docs it points at

anchor="$(sed -n 's/^TROUBLE_URL=.*#\([a-z0-9-]*\)"$/\1/p' "$SCRIPT")"
[[ -n "$anchor" ]] || fail "no troubleshooting link in $SCRIPT"
grep -E '^#{2,3} ' docs/user/troubleshooting.md \
  | sed -E 's/^#+ //' | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9 -]//g; s/ /-/g' \
  | grep -Fxq "$anchor" || fail "docs/user/troubleshooting.md has no #$anchor section"
pass "the troubleshooting section it links to exists"

echo "$passed checks passed"
