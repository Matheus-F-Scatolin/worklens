#!/usr/bin/env bash
# The install rehearsal (docs/rehearsal.md): walks you through a new person's first install with
# a second app, "Worklens Rehearsal", so the real Worklens, its data, its keychain item, its
# permissions and its Claude Desktop entry are never touched.
#
# It runs `scripts/setup.sh --rehearsal` (the real install flow; the download and the command
# line tools install are simulated), then a numbered checklist, one step at a time. You answer
# each with pass, fail or skip and an optional note, and the answers go to a dated report in
# ~/Library/Application Support/Worklens Rehearsal/rehearsals/.
#
# usage: scripts/rehearse.sh [--dry-run] [--yes] [--skip-setup]
#   --dry-run     print the plan and every step, run nothing that changes anything, write no report
#   --yes         answer yes to setup.sh's own questions (the checklist still asks you)
#   --skip-setup  the rehearsal app is already installed: go straight to the checklist
#
# It never signs in for you: `claude auth login` and `codex login` are yours to run, and nothing
# here reads their credentials. It never writes Claude Desktop's configuration; the app's own
# Connect button does that, and only for the `worklens-rehearsal` entry.
set -euo pipefail

cd "$(dirname "$0")/.."
REPO="$PWD"
# shellcheck source=scripts/app-identity.sh
source scripts/app-identity.sh
wl_identity rehearsal

DRY_RUN=0
SETUP_YES=0
SKIP_SETUP=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--dry-run) DRY_RUN=1 ;;
    -y|--yes) SETUP_YES=1 ;;
    --skip-setup) SKIP_SETUP=1 ;;
    -h|--help) sed -n '11,14p' "$0"; exit 0 ;;
    *) echo "error: unknown argument $1" >&2; exit 2 ;;
  esac
  shift
done

SUPPORT="$WL_SUPPORT"
DATA="$SUPPORT/data"
REPORTS="$SUPPORT/rehearsals"
CLAUDE_DESKTOP_CONFIG="${CLAUDE_DESKTOP_CONFIG:-$HOME/Library/Application Support/Claude/claude_desktop_config.json}"
WAIT_SECONDS="${REHEARSE_WAIT_SECONDS:-600}"
wl_guard "$SUPPORT" "$DATA" "$REPORTS" "$WL_BUILD_APP" "$WL_BUNDLE_ID" "$WL_CLI" "$WL_MCP_NAME"

BOLD=$'\033[1m'; DIM=$'\033[2m'; PLAIN=$'\033[0m'
[[ -t 1 ]] || { BOLD=""; DIM=""; PLAIN=""; }
step()  { echo; echo "${BOLD}==> $*${PLAIN}"; }
detail() { echo "${DIM}    $*${PLAIN}"; }
say() { echo "    $*"; }

# The rehearsal's own binary. The installed copy when there is one, the build otherwise. It runs
# from / with no DATA_DIR or WORKLENS_ENV_FILE inherited, so this checkout's .env (the real app's
# developer configuration) is never one of its layers; it reads its own folder, like the app.
app_path() {
  local app
  app="$(scripts/installed-app.sh --rehearsal 2>/dev/null || true)"
  [[ -n "$app" ]] || app="$REPO/$WL_BUILD_APP"
  wl_guard "$app"
  printf '%s\n' "$app"
}
rehearsal_cli() {
  local bin
  bin="$(app_path)/Contents/MacOS/Worklens"
  if (( DRY_RUN )); then
    printf '    would run: %s' "$WL_CLI"; printf ' %q' "$@"; printf '\n'
    return 0
  fi
  if [[ ! -x "$bin" ]]; then
    say "the rehearsal app is not built yet ($bin)"
    return 1
  fi
  (cd / && env -u DATA_DIR -u WORKLENS_ENV_FILE "$bin" "$@")
}

# One MCP entry's command, or "(none)". Reads Claude Desktop's file, never writes it, and prints
# nothing else from it: other servers' entries can carry keys.
mcp_command() {
  [[ -f "$CLAUDE_DESKTOP_CONFIG" ]] || { echo "(no file)"; return 0; }
  python3 -I - "$CLAUDE_DESKTOP_CONFIG" "$1" <<'PYEOF' 2>/dev/null || echo "(unreadable)"
import json, sys
try:
    servers = json.load(open(sys.argv[1])).get("mcpServers") or {}
except Exception:
    print("(unreadable)"); sys.exit(0)
entry = servers.get(sys.argv[2])
print(entry.get("command", "(no command)") if isinstance(entry, dict) else "(none)")
PYEOF
}

# Screenshots the rehearsal has taken, read-only. Nothing about them but the count.
capture_count() {
  local db="$DATA/worklens.sqlite"
  [[ -f "$db" ]] || { echo 0; return 0; }
  sqlite3 -readonly "$db" "SELECT count(*) FROM captures WHERE skip_reason IS NULL" 2>/dev/null || echo 0
}

# ---------------------------------------------------------------- the report

STAMP="$(date '+%Y-%m-%d-%H%M%S')"
REPORT="$REPORTS/$STAMP.md"
RESULTS=()   # "number|title|result|note", in order
PASSED=0; FAILED=0; SKIPPED=0

record() {
  local n="$1" title="$2" result="$3" note="${4:-}"
  RESULTS+=("$n|$title|$result|$note")
  case "$result" in
    pass) PASSED=$((PASSED + 1)) ;;
    fail) FAILED=$((FAILED + 1)) ;;
    *) SKIPPED=$((SKIPPED + 1)) ;;
  esac
}

# Ask pass, fail or skip, then an optional note. A closed stdin counts as a skip.
STEP_N=0
STEP_TITLE=""
begin() {
  STEP_N=$((STEP_N + 1))
  STEP_TITLE="$*"
  step "$STEP_N. $STEP_TITLE"
}
verdict() {
  if (( DRY_RUN )); then
    say "would ask: [p]ass, [f]ail or [s]kip, then a note"
    return 0
  fi
  local reply result note=""
  while true; do
    if ! read -r -p "    [p]ass, [f]ail or [s]kip? " reply; then result=skip; note="no answer"; break; fi
    case "$reply" in
      p|P|pass) result=pass; break ;;
      f|F|fail) result=fail; break ;;
      s|S|skip) result=skip; break ;;
    esac
  done
  if [[ "$note" != "no answer" ]]; then
    read -r -p "    note (Return for none): " note || note=""
  fi
  record "$STEP_N" "$STEP_TITLE" "$result" "$note"
}
auto_skip() {
  say "skipped: $*"
  (( DRY_RUN )) || record "$STEP_N" "$STEP_TITLE" skip "$*"
}

write_report() {
  (( DRY_RUN )) && return 0
  wl_guard "$REPORTS" "$REPORT"
  mkdir -p "$REPORTS"
  local commit dirty=""
  commit="$(git -C "$REPO" rev-parse --short HEAD 2>/dev/null || echo unknown)"
  [[ -n "$(git -C "$REPO" status --porcelain 2>/dev/null)" ]] && dirty=" (with uncommitted changes)"
  {
    echo "# Install rehearsal, $(date '+%Y-%m-%d %H:%M')"
    echo
    echo "- Built from: \`$commit\`$dirty"
    echo "- macOS $(sw_vers -productVersion 2>/dev/null || echo unknown)"
    echo "- $PASSED passed, $FAILED failed, $SKIPPED skipped"
    echo
    echo "| # | Step | Result | Note |"
    echo "|---|------|--------|------|"
    local row n title result note
    for row in ${RESULTS[@]+"${RESULTS[@]}"}; do
      IFS='|' read -r n title result note <<<"$row"
      note="${note//|/\\|}"
      echo "| $n | $title | $result | $note |"
    done
  } >"$REPORT"
  echo
  echo "${BOLD}Report:${PLAIN} $REPORT"
}
trap 'write_report' EXIT

# ---------------------------------------------------------------- before anything

echo "${BOLD}Worklens install rehearsal${PLAIN} — $REPO"
(( DRY_RUN )) && echo "${DIM}dry run: nothing will be installed, captured, summarized or written${PLAIN}"
cat <<EOF

    The rehearsal installs a second app, $WL_APP_BUNDLE, and walks you through what a new
    person sees. It is real where it matters:

    - it captures your screen, exactly like Worklens does, once you allow Screen Recording;
    - its summaries use your own Claude plan (and ChatGPT plan, if Codex is signed in), so they
      count against that plan's usage;
    - it never signs in for you: 'claude auth login' and 'codex login' are yours to run.

    It never touches Worklens.app, ~/Library/Application Support/Worklens, the worklens command,
    dev.worklens.app or the "worklens" entry in Claude Desktop. 'make rehearse-clean' removes
    everything it adds.
EOF
if (( ! DRY_RUN )); then
  read -r -p "    Go on? [y/N] " go || go=""
  [[ "$go" == [Yy]* ]] || { echo "    Nothing was done."; trap - EXIT; exit 0; }
fi

# What the real app looks like before the rehearsal, to check it is unchanged at the end.
REAL_LINK_BEFORE="$(readlink "$(command -v worklens 2>/dev/null || echo /nonexistent)" 2>/dev/null || echo "(none)")"
REAL_MCP_BEFORE="$(mcp_command worklens)"

# ---------------------------------------------------------------- the install

begin "Install (setup.sh --rehearsal)"
if (( SKIP_SETUP )); then
  auto_skip "--skip-setup: using the rehearsal app already installed"
else
  setup_args=(--rehearsal)
  (( DRY_RUN )) && setup_args+=(--dry-run)
  (( SETUP_YES )) && setup_args+=(--yes)
  if scripts/setup.sh "${setup_args[@]}"; then
    if (( DRY_RUN )); then say "would record: pass when setup.sh finishes"
    else record "$STEP_N" "$STEP_TITLE" pass ""; fi
  else
    status=$?
    record "$STEP_N" "$STEP_TITLE" fail "setup.sh exited $status"
    say "setup.sh stopped (exit $status). Its last lines above say why; the report keeps the rest."
    exit "$status"
  fi
fi

# ---------------------------------------------------------------- the welcome window

begin "The welcome window opens"
say "$WL_APP_NAME opens on its welcome window, on the page that picks how it looks, and its lens"
say "ring is in the menu bar. If the real Worklens is running too, you see two rings."
verdict

begin "What Worklens does, and the sample week"
say "Read the next two pages as a new person would: what Worklens does and what leaves your"
say "Mac, then the drawing of a sample week. Note anything unclear."
verdict

begin "Screen Recording, then Relaunch"
say "On the Screen Recording page, allow it when macOS asks. System Settings lists"
say "\"$WL_APP_NAME\" as its own row, apart from Worklens. Then choose Relaunch Worklens: the"
say "app quits, comes back on the same page, and says it is granted."
verdict

# ---------------------------------------------------------------- how Worklens summarizes

begin "How Worklens summarizes: the page"
say "The next page offers your Claude plan, your ChatGPT plan and a Gemini key. Check the"
say "wording and that it says which ones it found on this Mac. Before you press anything:"
rehearsal_cli summaries check || true
verdict

begin "Connect Claude"
if command -v claude >/dev/null 2>&1; then
  say "Press Connect next to your Claude plan. If it says you are signed out, run"
  say "'claude auth login' in Terminal yourself, then press Connect again. Afterwards:"
  if (( ! DRY_RUN )); then read -r -p "    Return once you have pressed Connect " _ || true; fi
  rehearsal_cli summaries check || true
  verdict
else
  auto_skip "Claude Code is not installed: install it, run 'claude auth login' yourself, then rehearse again"
fi

begin "Connect ChatGPT (Codex)"
if command -v codex >/dev/null 2>&1; then
  say "Press Connect next to your ChatGPT plan. If it says you are signed out, run"
  say "'codex login' in Terminal yourself, then press Connect again. Afterwards:"
  if (( ! DRY_RUN )); then read -r -p "    Return once you have pressed Connect " _ || true; fi
  rehearsal_cli summaries check || true
  verdict
else
  auto_skip "Codex is not installed: install Codex and run 'codex login' yourself"
fi

# ---------------------------------------------------------------- the first screenshots

begin "Start capturing, and the first screenshots"
say "On the last page, choose Start capturing, then use your Mac as usual for a few minutes."
if (( DRY_RUN )); then
  say "would wait up to $((WAIT_SECONDS / 60)) minutes for 3 screenshots, reading $DATA/worklens.sqlite read-only"
else
  say "Waiting for 3 screenshots (up to $((WAIT_SECONDS / 60)) minutes; Return stops waiting)."
  waited=0
  count="$(capture_count)"
  while (( count < 3 && waited < WAIT_SECONDS )); do
    if read -r -t 15 _; then break; fi
    waited=$((waited + 15))
    count="$(capture_count)"
    say "$count so far"
  done
  say "$count screenshots taken"
fi
verdict

# ---------------------------------------------------------------- summaries

begin "Summaries of the first screenshots"
say "Summarizes up to 3 waiting screenshots with each plan that is connected, the way the app"
say "does every few minutes. It uses your plan's usage. The app may have got there first; then"
say "this says there is nothing waiting, and the timeline already has them."
rehearsal_cli describe-pending --provider claude --limit 3 || true
if command -v codex >/dev/null 2>&1 && { (( DRY_RUN )) || codex login status >/dev/null 2>&1; }; then
  rehearsal_cli describe-pending --provider codex --limit 3 || true
fi
verdict

begin "The timeline shows them"
say "Open $WL_APP_NAME's window from the menu. Today shows the stretch you just worked, with"
say "the summaries in it."
verdict

# ---------------------------------------------------------------- the optional parts

begin "Claude Desktop (optional)"
say "The welcome window's last page offers to add Worklens to Claude Desktop. In the rehearsal"
say "its Connect adds an entry called \"$WL_MCP_NAME\" and leaves \"worklens\" alone. Claude"
say "Desktop puts its old settings back while it is open: quit it first, press Connect, then open"
say "it again. If you are running this from inside Claude Desktop, quitting it ends that session."
if (( DRY_RUN )); then
  say "would show: the \"$WL_MCP_NAME\" and \"worklens\" entries' commands, read-only"
else
  read -r -p "    Return when you are done, or have decided to skip it " _ || true
  say "\"$WL_MCP_NAME\": $(mcp_command "$WL_MCP_NAME")"
  say "\"worklens\": $(mcp_command worklens)"
fi
verdict

begin "Notifications"
say "When macOS asks whether $WL_APP_NAME may send notifications, answer as a new person would."
say "System Settings -> Notifications lists it as its own app, apart from Worklens."
verdict

# ---------------------------------------------------------------- the real app

begin "The real Worklens is untouched"
if (( DRY_RUN )); then
  say "would compare: where the worklens command points and the \"worklens\" Claude Desktop entry,"
  say "before and after"
else
  real_link_after="$(readlink "$(command -v worklens 2>/dev/null || echo /nonexistent)" 2>/dev/null || echo "(none)")"
  real_mcp_after="$(mcp_command worklens)"
  untouched=1
  if [[ "$real_link_after" != "$REAL_LINK_BEFORE" ]]; then
    untouched=0; say "the worklens command moved: $REAL_LINK_BEFORE -> $real_link_after"
  fi
  if [[ "$real_mcp_after" != "$REAL_MCP_BEFORE" ]]; then
    untouched=0; say "the \"worklens\" entry changed: $REAL_MCP_BEFORE -> $real_mcp_after"
  fi
  if (( untouched )); then
    say "the worklens command and the \"worklens\" Claude Desktop entry are as they were"
    record "$STEP_N" "$STEP_TITLE" pass ""
  else
    record "$STEP_N" "$STEP_TITLE" fail "the real app's command or Claude Desktop entry changed"
  fi
fi

# ---------------------------------------------------------------- after

step "Cleaning up, when you are done"
cat <<EOF
    'make rehearse-clean' shows what it would remove: $WL_APP_BUNDLE, the $WL_CLI command,
    its folder in Application Support (the reports stay), its keychain item, its Screen
    Recording, Accessibility and Automation grants and its Claude Desktop entry.
    'make rehearse-clean REHEARSE_CLEAN_ARGS=--yes' removes them.
EOF
if (( DRY_RUN )); then
  echo
  say "would write the report to $REPORT"
  echo "(dry run — nothing above actually happened)"
fi
