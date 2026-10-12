#!/usr/bin/env bash
# Run a build and show one line for it instead of a wall of compiler output (#353):
#
#   Building Worklens · 212 of 480 · 1:42
#
# The counts are SwiftPM's own: every `[n/m]` (classic build system) or `[n / m]` (swift-build)
# progress line it prints. The total grows while SwiftPM plans, so the second number can rise
# during a build; the first one never goes backwards. Every line the command prints goes to the
# log, with colour codes removed, and nowhere else.
#
# On a terminal the line is redrawn in place once a second, so the clock keeps moving through a
# long link step that prints nothing. Anywhere else — a pipe, a file, CI — the output is plain
# lines with no carriage returns: one when the build starts and one at every tenth of the way.
#
# When the command fails, this prints any warnings from scripts/doctor.sh, the last error lines
# from the log (paths made relative to --repo), the log's path, and the section of docs/user/troubleshooting.md that matches what
# went wrong, then exits with the command's status. The command's own exit status is always
# what this exits with.
#
# usage: scripts/build-progress.sh --log FILE [--repo DIR] [--plain] -- COMMAND [ARG...]
#   --log FILE   where the whole output goes; replaced on every run, its folder created
#   --repo DIR   shorten paths under DIR in the error lines (the checkout being built)
#   --plain      plain lines even on a terminal
#
# scripts/build-progress-test.sh checks it against captured output of real builds.
set -uo pipefail
shopt -s extglob

LABEL="Building Worklens"
DONE_LABEL="Built Worklens"
TROUBLESHOOTING="https://github.com/Matheus-F-Scatolin/worklens/blob/main/docs/user/troubleshooting.md"

LOG=""
REPO=""
PLAIN=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --log) [[ $# -ge 2 ]] || { echo "error: --log needs a file" >&2; exit 2; }; LOG="$2"; shift 2 ;;
    --repo) [[ $# -ge 2 ]] || { echo "error: --repo needs a folder" >&2; exit 2; }; REPO="${2%/}"; shift 2 ;;
    --plain) PLAIN=1; shift ;;
    -h|--help) sed -n '20,23p' "$0"; exit 0 ;;
    --) shift; break ;;
    *) echo "error: unknown argument $1" >&2; exit 2 ;;
  esac
done
[[ -n "$LOG" ]] || { echo "error: --log is required" >&2; exit 2; }
[[ $# -gt 0 ]] || { echo "error: no command to run after --" >&2; exit 2; }
[[ -t 1 ]] || PLAIN=1

mkdir -p "$(dirname "$LOG")" || exit 1
: > "$LOG" || exit 1

ESC=$'\033'
CR=$'\r'
# Whatever sits around the slash: swift-build pads it with thin spaces (U+2009), not spaces.
COUNT_RE='^\[([0-9]+)[^]0-9/]{0,8}/[^]0-9]{0,8}([0-9]+)\]'

# Sets `clean` to $1 without colour codes, and without anything a carriage return was going to
# draw over. Parameter expansion rather than sed: this runs once per line of a long build.
strip_line() {
  clean="${1//${ESC}\[*([0-9;])[A-Za-z]/}"
  clean="${clean##*${CR}}"
}

# Sets `clock` to $1 seconds as m:ss.
format_clock() {
  printf -v clock '%d:%02d' $(( $1 / 60 )) $(( $1 % 60 ))
}

STATE_DIR=""
STATE=""
TICKER=""

# The terminal's line, drawn once a second from whatever the reader last wrote to $STATE. The
# reader never draws itself, so two writers never interleave on the terminal.
ticker() {
  local shown="starting" text owner=$$
  while :; do
    # The helper is gone (killed outright, so no trap ran): stop drawing and clean up after it.
    if ! kill -0 "$owner" 2>/dev/null; then
      rm -rf "$STATE_DIR"
      exit 0
    fi
    if IFS= read -r text < "$STATE" 2>/dev/null && [[ -n "$text" ]]; then shown="$text"; fi
    format_clock "$SECONDS"
    printf '\r%s\033[K' "$LABEL · $shown · $clock"
    sleep 1
  done
}

stop_ticker() {
  if [[ -n "$TICKER" ]]; then
    kill "$TICKER" 2>/dev/null
    wait "$TICKER" 2>/dev/null
    TICKER=""
    printf '\r\033[K'
  fi
  [[ -z "$STATE_DIR" ]] || rm -rf "$STATE_DIR"
  STATE_DIR=""
}
# Re-raised rather than `exit 130`, so setup.sh sees a signal death and stops quietly instead of
# reporting a failed build. Bash runs this once the build in front of it returns, so a TERM sent
# to this helper alone waits for the build; Ctrl-C reaches the whole process group at once.
on_signal() {
  stop_ticker
  echo
  echo "Stopped. The build so far is logged in $LOG" >&2
  trap - INT TERM
  kill -s "$1" "$$"
}
trap 'on_signal INT' INT
trap 'on_signal TERM' TERM

# Reads the build's output: every line to the log, the counts to the screen.
read_build() {
  local line n=0 m=0 bucket shown=-1
  exec 3>>"$LOG"
  while IFS= read -r line || [[ -n "$line" ]]; do
    strip_line "$line"
    printf '%s\n' "$clean" >&3
    [[ "$clean" =~ $COUNT_RE ]] || continue
    local seen="${BASH_REMATCH[1]}" total="${BASH_REMATCH[2]}"
    (( total > 0 )) || continue
    m=$total
    (( seen > n )) && n=$seen
    (( n > m )) && n=$m
    if (( PLAIN )); then
      # A line per tenth of the way. The total grows while SwiftPM plans, which can move the
      # fraction back down a tenth; that is a new tenth too, and gets its line.
      bucket=$(( n * 10 / m ))
      if (( bucket != shown )); then
        shown=$bucket
        format_clock "$SECONDS"
        echo "$LABEL · $n of $m · $clock"
      fi
    else
      printf '%s\n' "$n of $m" > "$STATE"
    fi
  done
  exec 3>&-
}

# The last error lines worth reading, most specific first: compiler diagnostics with a file and
# line, then any other `error:` line SwiftPM printed, then simply the end of the log. Long lines
# are a failed command's whole command line, which says nothing a person can act on.
error_lines() {
  local found
  found="$(grep -E '^[^[:space:]].*:[0-9]+:[0-9]+: (fatal )?error: ' "$LOG" | awk 'length($0) <= 400 && !seen[$0]++' | tail -n 8)"
  if [[ -z "$found" ]]; then
    found="$(grep -E '(^|[[:space:]])error: ' "$LOG" \
      | grep -v -E '^error: (Build failed|.*failed with a nonzero exit code)' \
      | awk 'length($0) <= 400 && !seen[$0]++' | tail -n 8)"
  fi
  if [[ -z "$found" ]]; then
    found="$(grep -v -E '^[[:space:]]*$' "$LOG" | awk 'length($0) <= 400' | tail -n 12)"
  fi
  if [[ -n "$REPO" ]]; then found="${found//"$REPO"\//}"; fi
  printf '%s\n' "$found"
}

# The section of docs/user/troubleshooting.md for what the log says went wrong.
troubleshooting_anchor() {
  if grep -q -E "SwiftUIMacros|plugin for module '[A-Za-z]+Macros' not found" "$LOG"; then
    echo "swiftuimacros-not-found"
  elif grep -q -i 'no space left on device' "$LOG"; then
    echo "no-space-left-on-device"
  elif grep -q -E 'invalid active developer path|xcrun: error|unable to find utility' "$LOG"; then
    echo "the-command-line-tools-are-broken"
  elif grep -q -i -E 'failed to clone|could not resolve host|unable to access .https://|failed to fetch|network connection was lost' "$LOG"; then
    echo "swift-could-not-download-the-packages"
  else
    echo "the-build-stopped-during-setup"
  fi
}

SECONDS=0
if (( PLAIN )); then
  echo "$LABEL · starting"
else
  STATE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/worklens-build.XXXXXX")" || exit 1
  STATE="$STATE_DIR/state"
  echo "starting" > "$STATE"
  ticker &
  TICKER=$!
fi

"$@" < /dev/null 2>&1 | read_build
status=${PIPESTATUS[0]}
elapsed=$SECONDS
stop_ticker
trap - INT TERM
format_clock "$elapsed"

# scripts/doctor.sh runs first in `make build` and never fails it. Its warnings are for
# contributors ("use `make test`", "the Makefile pins the SDK for you"), and a Command Line Tools
# Mac, the usual one for the one-line install, always has one. So they stay in the log when the
# build works, and come back on screen only when it fails, where one of them may be the reason.
if (( status == 0 )); then
  echo "$DONE_LABEL · $clock"
  exit 0
fi

warnings="$(grep -E '^warn  ' "$LOG" || true)"
{
  echo "$LABEL stopped after $clock."
  echo
  if [[ -n "$warnings" ]]; then
    echo "    The toolchain check flagged these. They are warnings, not errors, but one may explain it:"
    printf '%s\n' "$warnings" | sed 's/^/      /'
    echo
  fi
  echo "    The last errors:"
  error_lines | sed 's/^/      /'
  echo
  echo "    The whole log: $LOG"
  echo "    What to try:   $TROUBLESHOOTING#$(troubleshooting_anchor)"
} >&2
exit "$status"
