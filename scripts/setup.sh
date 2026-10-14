#!/usr/bin/env bash
# One command for a fresh clone: check the toolchain, make a .env, sign the app with a
# certificate that keeps its permissions, install it, and say what is left for a person to do
# (#119).
#
# Before this, an installed Worklens took seven steps spread across the README, two of them
# GUI-only. Every one of those steps is still its own make target — nothing here is magic, and
# each is printed before it runs — this just puts them in order and says plainly what is left
# that only you can do: pasting your API keys, and answering macOS's permission dialogs.
#
# It never blocks on either. Since #116 a Worklens with no configuration writes its own and asks
# for the keys in the menu, so a setup that refused to finish without them would be inventing a
# requirement the app does not have.
#
# Idempotent. Re-running after a failure, or after `git pull`, is the supported way to use it:
# every step checks whether it has already happened.
#
# Consent first, and no exceptions: each step that writes outside this checkout — the login
# keychain, ~/Library/Application Support, /Applications, your PATH — says what it is about to do
# and waits for an answer. Declining one is a supported outcome, not an error; the script says
# what you lose and carries on.
#
# usage: scripts/setup.sh [--dry-run] [--yes] [--no-link-checkout]
#   --dry-run            print every command this would run and change nothing at all
#   --yes                answer yes to every prompt except "Point the installed app at this
#                        checkout?", which stays at its N default (see step 5)
#   --no-link-checkout   leave that one question at N even on an interactive run
set -euo pipefail

cd "$(dirname "$0")/.."
REPO="$PWD"

DRY_RUN=0
ASSUME_YES=0
# Step 5 is the one question --yes must not answer: it runs `make install-env`, which pins
# DATA_DIR to this checkout's absolute path in the file that outranks every other layer. That is
# right while working on Worklens and wrong for an unattended install — scripts/bootstrap.sh
# clones into a directory it later pulls into, and a database inside a git checkout is not a
# thing to arrange behind someone's back. So --yes leaves it at N.
LINK_CHECKOUT=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--dry-run) DRY_RUN=1 ;;
    -y|--yes) ASSUME_YES=1; LINK_CHECKOUT=0 ;;
    --no-link-checkout) LINK_CHECKOUT=0 ;;
    -h|--help) sed -n '23,27p' "$0"; exit 0 ;;
    *) echo "error: unknown argument $1" >&2; exit 2 ;;
  esac
  shift
done

BOLD=$'\033[1m'; DIM=$'\033[2m'; PLAIN=$'\033[0m'
[[ -t 1 ]] || { BOLD=""; DIM=""; PLAIN=""; }

step()  { echo; echo "${BOLD}==> $*${PLAIN}"; }
detail() { echo "${DIM}    $*${PLAIN}"; }

SUPPORT="$HOME/Library/Application Support/Worklens"

# A DATA_DIR value as the app reads it (Config.fileLayer): quotes off, `~` expanded, and a
# relative path taken from `$2`, the folder of the file it came from (or the working directory,
# for the environment).
resolve_dir() {
  local dir="$1" base="$2"
  if [[ "$dir" == \"*\" ]]; then dir="${dir#\"}"; dir="${dir%\"}"; fi
  if [[ "$dir" == \'*\' ]]; then dir="${dir#\'}"; dir="${dir%\'}"; fi
  [[ -n "$dir" ]] || return 0
  if [[ "$dir" == "~" ]]; then dir="$HOME"
  elif [[ "$dir" == "~/"* ]]; then dir="$HOME/${dir:2}"
  elif [[ "$dir" != /* ]]; then dir="$base/${dir#./}"
  fi
  printf '%s\n' "${dir%/}"
}

# One .env file's DATA_DIR, resolved, or nothing.
env_file_data_dir() {
  local file="$1" dir
  [[ -f "$file" ]] || return 0
  dir="$(grep -E '^DATA_DIR=' "$file" 2>/dev/null | tail -1 | cut -d= -f2- || true)"
  resolve_dir "$dir" "$(dirname "$file")"
}

# Where the app keeps its data, worked out the way the app would before it exists: DATA_DIR from
# the environment, then from the installed .env (which outranks every checkout's), then, with no
# installed .env, this checkout's (what `make run` points the app at), then the default. Only the
# build log uses it. Like the key check below, it greps the file and never sources it.
data_dir() {
  local dir=""
  if [[ -n "${DATA_DIR:-}" ]]; then
    dir="$(resolve_dir "$DATA_DIR" "$PWD")"
  elif [[ -f "$SUPPORT/.env" ]]; then
    dir="$(env_file_data_dir "$SUPPORT/.env")"
  else
    dir="$(env_file_data_dir "$REPO/.env")"
  fi
  [[ -n "$dir" ]] || dir="$SUPPORT/data"
  printf '%s\n' "$dir"
}

# Every mutating line goes through run(), so --dry-run is this same script with the writes turned
# into echoes rather than a second description of it that could drift.
run() {
  if (( DRY_RUN )); then
    printf '    would run:'; printf ' %q' "$@"; printf '\n'
  else
    "$@"
  fi
}

# --dry-run answers yes to everything so it prints the whole sequence, including the steps a
# cautious person would decline.
ask() {
  local prompt="$1"
  if (( DRY_RUN || ASSUME_YES )); then
    echo "    $prompt [y/N] y"
    return 0
  fi
  local reply
  read -r -p "    $prompt [y/N] " reply || reply=""
  [[ "$reply" == [Yy]* ]]
}

echo "${BOLD}Worklens setup${PLAIN} — $REPO"
if (( DRY_RUN )); then echo "${DIM}dry run: nothing will be created, copied, signed or launched${PLAIN}"; fi

# ------------------------------------------------------------------ 1. the toolchain

step "Checking the toolchain"
# A hard stop, unlike scripts/bootstrap.sh, which installs the tools itself before it gets here.
# The two say the same thing about them: missing, broken, or too old, and what to do.
if ! xcode-select -p >/dev/null 2>&1; then
  echo "error: Apple's command line tools are not installed. Run 'xcode-select --install', let it finish, then run setup again." >&2
  exit 1
fi
detail "developer directory: $(xcode-select -p)"

if ! swift -version >/dev/null 2>&1 </dev/null || ! git --version >/dev/null 2>&1 </dev/null; then
  echo "error: Apple's command line tools are set up, but Swift or git does not run from them, so they look broken." >&2
  echo "       docs/user/troubleshooting.md, \"The command line tools are broken\", says what to do; then run setup again." >&2
  exit 1
fi
swift_version="$(swift -version 2>&1 | sed -n 's/.*Apple Swift version \([0-9][0-9]*\.[0-9][0-9]*\).*/\1/p' | head -1)"
if [[ -z "$swift_version" ]] || ! printf '6.1\n%s\n' "$swift_version" | sort -C -V; then
  echo "error: Package.swift needs Swift 6.1 or newer, found '${swift_version:-none}'" >&2
  exit 1
fi
detail "Swift $swift_version"

macos_major="$(sw_vers -productVersion | cut -d. -f1)"
if (( macos_major < 14 )); then
  echo "error: Worklens needs macOS 14 or later, this is $(sw_vers -productVersion)" >&2
  exit 1
fi
detail "macOS $(sw_vers -productVersion)"

# ------------------------------------------------------------------ 2. .env and the keys

step "Configuration"
# A checkout keeps its configuration in the checkout. The app itself needs none — since #116 it
# writes ~/Library/Application Support/Worklens/.env on its first launch and says "Add your API
# keys to get started" in the menu — so this creates the file and reports what is missing rather
# than refusing to continue. A Worklens with no key still captures; it just describes nothing,
# and the menu says so.
#
# An unattended run (--yes, which is what scripts/bootstrap.sh passes) makes no checkout .env at
# all: that run never points the app at this checkout, the key goes into the welcome window, and
# a .env here would only tell the person to paste it in the wrong place.
checkout_env=1
if (( LINK_CHECKOUT == 0 )) && [[ ! -f "$REPO/.env" ]]; then
  checkout_env=0
  detail "no checkout .env — the app writes its own on first launch, and its welcome window"
  detail "asks for the Gemini key"
elif [[ -f "$REPO/.env" ]]; then
  detail "$REPO/.env exists"
  # It holds the API key: owner-only, whatever mode an earlier copy or editor left it with.
  run chmod 600 "$REPO/.env"
else
  detail "creating $REPO/.env from .env.example"
  # 0600 from the start (`install -m`), not a copy of the example's 0644 that a key goes into.
  run install -m 600 "$REPO/.env.example" "$REPO/.env"
fi

# Read with grep rather than sourcing the file: a .env is data, and a stray backtick in a value
# is not something a setup script should execute. The values themselves are never read, printed
# or copied anywhere — only whether each key has one.
missing=()
for key in GEMINI_API_KEY; do
  value="$(grep -E "^${key}=" "$REPO/.env" 2>/dev/null | tail -1 | cut -d= -f2- || true)"
  [[ -n "$value" ]] || missing+=("$key")
done
if (( ! checkout_env )); then
  :
elif (( ${#missing[@]} )); then
  detail "not set yet: ${missing[*]}"
  detail "paste it into the welcome window when Worklens opens — or into $REPO/.env, if you"
  detail "point the app at this checkout in step 5."
  detail "Worklens captures without it; it just describes nothing until it is there, and the"
  detail "menu says so. Setup carries on."
else
  detail "GEMINI_API_KEY is set (this script never reads its value)"
fi

# ------------------------------------------------------------------ 3. the certificate

step "Code-signing certificate"
if security find-identity -v -p codesigning 2>/dev/null | grep -Fq '"Worklens Dev"'; then
  detail "\"Worklens Dev\" is already installed and trusted"
else
  cat <<EOF
    macOS ties Screen Recording and Accessibility to an app's code signature. Without a stable
    certificate every rebuild looks like a brand-new app, both permissions have to be granted
    again, and auto-update refuses to run at all.

    'make dev-cert' creates a self-signed "Worklens Dev" certificate in your login keychain and
    marks it trusted for code signing. The trust step raises the macOS password dialog — that is
    your login password, asked for by macOS, and this script never sees it. Nothing here needs an
    Apple Developer account.
EOF
  if ask "Create the certificate now?"; then
    run scripts/make-dev-cert.sh
  else
    detail "skipped — the app will be signed ad-hoc, so its permissions will not survive a rebuild"
  fi
fi

# ------------------------------------------------------------------ 4. build, bundle, sign

step "Building Worklens (release)"
# One live line instead of the compiler's wall of output (#353). The whole log goes beside the
# app's own logs, where it outlives a closed terminal, and is replaced on every run.
BUILD_LOG="$(data_dir)/logs/build.log"
detail "a few minutes the first time; the whole log goes to $BUILD_LOG"
if (( DRY_RUN )); then
  run scripts/build-progress.sh --log "$BUILD_LOG" --repo "$REPO" -- make build
else
  build_status=0
  scripts/build-progress.sh --log "$BUILD_LOG" --repo "$REPO" -- make build || build_status=$?
  # Stopped by Ctrl-C or a TERM: the helper already said where the log is, and there is no
  # failure to explain.
  if (( build_status > 128 )); then exit "$build_status"; fi
  if (( build_status != 0 )); then
    echo >&2
    echo "Setup stopped at the build, and nothing after it ran. Once that is fixed, run it again:" >&2
    echo "every step before the build checks whether it already happened." >&2
    exit 1
  fi
fi

step "Assembling and signing build/Worklens.app"
run make bundle
run make sign

# ------------------------------------------------------------------ 5. the shared .env

step "Installing the configuration where a bundled app can find it"
cat <<EOF
    A bundled app does not inherit a shell's working directory, so it cannot see ./.env. It does
    not need to: with no configuration anywhere it writes its own
    ~/Library/Application Support/Worklens/.env and keeps its data beside it (#116).

    'make install-env' is the other choice — it merges this checkout's .env into that file with
    DATA_DIR rewritten to this checkout's absolute path, which is what you want while working on
    Worklens and not what you want if you are only running it. Nothing already in that file is
    lost: a key the two set differently is printed and left alone. The merged file outranks the
    .env of every checkout on this Mac, so it decides where an app launched from Spotlight
    writes.
EOF
if (( LINK_CHECKOUT == 0 )); then
  echo "    Point the installed app at this checkout? [y/N] N"
  detail "declined for you — an unattended run keeps the app's own configuration and data in"
  detail "Application Support. Run this script by hand, or 'make install-env', to change that."
elif ask "Point the installed app at this checkout?"; then
  run make install-env
else
  detail "skipped — the app keeps its own configuration and data in Application Support"
fi

# ------------------------------------------------------------------ 6. the install

step "Installing the app and the worklens command"
cat <<EOF
    'make install' copies build/Worklens.app to /Applications (or ~/Applications when that is not
    writable) so Spotlight can find it, and symlinks that copy's binary to /usr/local/bin/worklens
    when that directory already exists and is writable, or ~/.local/bin otherwise.

    It does not carry permissions over: a command run from a terminal is attributed to the
    terminal, so 'worklens capture-once' asks for Screen Recording on its own account.
EOF
installed=""
if ask "Install the app now?"; then
  if (( DRY_RUN )); then
    run scripts/install.sh
  else
    scripts/install.sh
    installed="$(scripts/installed-app.sh || true)"
  fi
else
  detail "skipped — the app stays at $REPO/build/Worklens.app"
fi

# ------------------------------------------------------------------ 7. MCP clients

step "Claude Desktop and other MCP clients (optional)"
mcp_binary="${installed:-$REPO/build/Worklens.app}/Contents/MacOS/Worklens"
cat <<EOF
    To ask Claude Desktop about your own day, add this to
    ~/Library/Application Support/Claude/claude_desktop_config.json, keeping any mcpServers you
    already have, then quit and reopen Claude Desktop:

      {
        "mcpServers": {
          "worklens": { "command": "$mcp_binary", "args": ["mcp"] }
        }
      }

    Or let the app do it: Settings -> Integrations -> Install into Claude Desktop, or
    \`$mcp_binary mcp install\`. Either one asks first, copies that file aside with a timestamp,
    merges only its own entry, and then says how many tools came up and which data directory
    they read. Quitting and reopening Claude Desktop is still yours to do.
EOF

# ------------------------------------------------------------------ 8. does it work

step "Checking the result"
worklens_bin="${installed:-$REPO/build/Worklens.app}/Contents/MacOS/Worklens"
if (( DRY_RUN )); then
  run "$worklens_bin" config-dump
elif [[ -x "$worklens_bin" ]]; then
  # config-dump answers the first question: which configuration file won, and what it resolved to.
  "$worklens_bin" config-dump
fi

# ------------------------------------------------------------------ 9. run it

step "Opening Worklens"
cat <<EOF
    The first time Worklens opens, it opens to its welcome window and captures nothing until you
    finish it. On a Mac where Worklens is already set up, it just comes back to the menu bar.
EOF
launched=0
if ask "Open Worklens now?"; then
  run scripts/launch.sh
  launched=1
else
  detail "skipped — 'make run' opens it whenever you are ready"
fi

# ------------------------------------------------------------------ 10. what is left for you

# The one-line install ends here too, since it runs this script: these are the steps no script
# can take for you, so they are the last thing on screen.
step "What is left for you"
if (( launched )); then
  echo "    Worklens is open. Two steps in its welcome window are yours:"
else
  echo "    When you open Worklens, two steps in its welcome window are yours:"
fi
cat <<EOF

    1. Allow Screen Recording when macOS asks, then choose Relaunch Worklens. macOS only hands
       the answer to a copy that starts afterwards, and a grant you gave a terminal does not
       count for the app.
    2. Paste your Gemini key. Get one at https://aistudio.google.com/apikey, on a paid,
       billing-enabled project. Or look around the sample week first, no key needed.

    Closed the window? Finish setting up Worklens, in the menu, brings it back.
EOF

# install.sh says this too, but mid-output, where it scrolls away: on a clean Apple-silicon Mac
# the command lands in ~/.local/bin, which no shell has on its PATH yet.
if [[ -n "$installed" ]] && ! command -v worklens >/dev/null 2>&1 && [[ -L "$HOME/.local/bin/worklens" ]]; then
  cat <<'EOF'

    For the worklens command in a terminal, put ~/.local/bin on your PATH and open a new shell:
      echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc
EOF
fi

echo
echo "${BOLD}Done.${PLAIN} 'worklens --help' lists the commands; the lens ring in the menu bar is the app."
if (( DRY_RUN )); then echo "${DIM}(dry run — nothing above actually happened)${PLAIN}"; fi
exit 0
