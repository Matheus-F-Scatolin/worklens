#!/usr/bin/env bash
# One pasteable line for a Mac that has never seen Worklens (#243):
#
#   /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Matheus-F-Scatolin/worklens/main/scripts/bootstrap.sh)"
#
# It checks the toolchain, asks once — naming every write before the first one happens — installs
# Apple's command line tools when they are missing (Apple's own dialog asks the person, and this
# waits for it), clones the source into one fixed path, and hands over to scripts/setup.sh, which
# does the rest.
#
# The path is fixed on purpose: ~/Library/Application Support/Worklens/src. An installed Worklens
# finds the checkout it was built from by the absolute path stamped into the bundle, so a checkout
# that moves can never update the app again. A folder nobody has a reason to drag somewhere else
# is the cheapest way to make "Update and restart…" keep working forever.
#
# The data directory stays where the app puts it, beside that folder and never inside it:
# bootstrap never runs `make install-env`, which would pin DATA_DIR into a git checkout this
# script later pulls into.
#
# No sudo, anywhere. Nothing is downloaded on your behalf except the source itself, and Apple's
# command line tools through Apple's own installer when they are missing. Safe to re-run: an
# existing checkout is updated, never replaced.
#
# usage: bash scripts/bootstrap.sh [--dry-run] [--yes] [--clone-only]
#   --dry-run     print the plan, ask nothing, change nothing
#   --yes         the person has already read the plan and said yes (an agent asks them in chat)
#   --clone-only  clone or update the source and stop, without building or installing
set -euo pipefail

REPO_URL="https://github.com/Matheus-F-Scatolin/worklens.git"
SRC="$HOME/Library/Application Support/Worklens/src"

DRY_RUN=0
ASSUME_YES=0
CLONE_ONLY=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--dry-run) DRY_RUN=1 ;;
    -y|--yes) ASSUME_YES=1 ;;
    -c|--clone-only) CLONE_ONLY=1 ;;
    -h|--help) sed -n '/^# usage:/,/^#   --clone-only/p' "$0"; exit 0 ;;
    *) echo "error: unknown argument $1" >&2; exit 2 ;;
  esac
  shift
done

BOLD=$'\033[1m'; DIM=$'\033[2m'; PLAIN=$'\033[0m'
[[ -t 1 ]] || { BOLD=""; DIM=""; PLAIN=""; }

step()   { echo; echo "${BOLD}==> $*${PLAIN}"; }
detail() { echo "${DIM}    $*${PLAIN}"; }
die()    { echo "error: $*" >&2; exit 1; }

echo "${BOLD}Worklens bootstrap${PLAIN}"

# ------------------------------------------------------------------ 1. can this Mac build it

step "Checking this Mac"

[[ "$(uname -s)" == "Darwin" ]] || die "Worklens runs on macOS only, this is $(uname -s)"

macos_major="$(sw_vers -productVersion | cut -d. -f1)"
(( macos_major >= 14 )) || die "Worklens needs macOS 14 or later, this is $(sw_vers -productVersion)"
detail "macOS $(sw_vers -productVersion)"

# ready, missing (no developer directory at all) or broken (one is set, but Swift or git does not
# run from it). Never runs swift or git while there is no developer directory: on a Mac without
# the tools /usr/bin/swift and /usr/bin/git are stubs that open Apple's install dialog themselves,
# and that dialog belongs after the plan below, not before it.
toolchain_state() {
  local dir
  dir="$(xcode-select -p 2>/dev/null)" || { echo missing; return 0; }
  [[ -n "$dir" && -d "$dir" ]] || { echo broken; return 0; }
  if swift --version </dev/null >/dev/null 2>&1 && git --version </dev/null >/dev/null 2>&1; then
    echo ready
  else
    echo broken
  fi
}

# How long to wait for Apple's installer, in seconds: a check every CLT_POLL (short, so a dialog
# closed at once is still seen open first), a line every CLT_NOTE, a word after CLT_UNSEEN when
# no installer window ever showed up, and a stop at CLT_TIMEOUT. The overrides exist for
# scripts/bootstrap-test.sh; nobody needs to set them.
CLT_POLL="${WORKLENS_CLT_POLL:-2}"
CLT_NOTE="${WORKLENS_CLT_NOTE:-60}"
CLT_UNSEEN="${WORKLENS_CLT_UNSEEN:-60}"
CLT_TIMEOUT="${WORKLENS_CLT_TIMEOUT:-3600}"
TROUBLE_URL="https://github.com/Matheus-F-Scatolin/worklens/blob/main/docs/user/troubleshooting.md#the-command-line-tools-are-broken"

clock() { printf '%d:%02d' $(($1 / 60)) $(($1 % 60)); }
span() { if (( $1 >= 120 && $1 % 60 == 0 )); then echo "$(($1 / 60)) minutes"; else echo "$1 seconds"; fi; }

toolchain="$(toolchain_state)"
case "$toolchain" in
  ready)
    detail "$(swift --version 2>&1 | head -1)" ;;
  missing)
    detail "Apple's command line tools are not installed. Worklens needs them to build, so this"
    detail "installs them first, once you say yes." ;;
  broken)
    detail "Apple's command line tools are set up, but Swift or git does not run from them, so"
    detail "they look broken. This asks macOS to install them again, once you say yes." ;;
esac

# Asks macOS to install the tools, then waits for them. Apple's own dialog asks the person first
# and its download is about a gigabyte, so the wait is long and its end is theirs: Install, or
# Cancel. A closed installer with no tools is a cancel; no tools by the ceiling is a stop. Either
# way nothing else has happened yet, and running the line again starts from here.
install_toolchain() {
  local out started elapsed last_note=0 seen=0 gone=0 unseen_said=0 waiting_note=""

  step "Installing Apple's command line tools"
  if ! out="$(xcode-select --install 2>&1)"; then
    if [[ "$out" == *"already installed"* ]]; then
      cat >&2 <<EOF

macOS says its command line tools are already installed, but Swift or git does not run from
them, so this cannot install them again. Look in System Settings > General > Software Update
for a Command Line Tools update first. The section "The command line tools are broken" says
what to do when there is none:
  $TROUBLE_URL
Nothing was changed. Run this line again afterwards; that is safe.
EOF
    else
      cat >&2 <<EOF

macOS could not start installing its command line tools. It said:
  $out
Nothing was changed. Run this line again to retry; that is safe. More in the section "The
command line tools are broken":
  $TROUBLE_URL
EOF
    fi
    exit 1
  fi

  detail "macOS is showing its own dialog for this. Click Install there and agree to Apple's"
  detail "license; the download is about a gigabyte and can take a while."
  detail "This waits up to $(span "$CLT_TIMEOUT") for the tools, then carries on by itself."
  if [[ -t 1 ]]; then
    detail "Press Control-C to stop waiting; running this line again is safe."
  else
    echo "A macOS dialog is waiting for you on this Mac's screen: \"Install Command Line Developer"
    echo "Tools\". It is yours to answer; nothing here can click it for you."
    waiting_note=" · the macOS dialog on your screen is yours to answer"
  fi

  started=$SECONDS
  while true; do
    sleep "$CLT_POLL"
    [[ "$(toolchain_state)" == ready ]] && break
    elapsed=$((SECONDS - started))

    # Apple's installer is a process of its own. Once it has been seen, and then missing for two
    # checks running with still no tools, the dialog was cancelled or the install failed. The
    # [s] keeps the pattern from matching this script's own text, which is in bash's argv when
    # it runs from the one pasteable line.
    if pgrep -f 'CoreServices/Install Command Line Developer Tool[s]' >/dev/null 2>&1; then
      seen=1; gone=0
    elif (( seen )); then
      gone=$((gone + 1))
      if (( gone >= 2 )); then
        cat >&2 <<EOF

The command line tools were not installed: Apple's dialog closed before they finished.
Nothing else was changed. Run this line again when you are ready; that is safe.
EOF
        exit 1
      fi
    elif (( ! unseen_said && elapsed >= CLT_UNSEEN )); then
      # Never seen: closed before the first check, or an installer by another name. Waiting on
      # is still right for the second, so say what to do about the first and keep going.
      detail "Apple's installer window has not shown up here. If you closed it, stop this and run"
      detail "the line again when you are ready; otherwise this keeps waiting."
      unseen_said=1
    fi

    if (( elapsed >= CLT_TIMEOUT )); then
      cat >&2 <<EOF

The command line tools did not appear within $(span "$CLT_TIMEOUT"). Nothing else was changed.
If Apple's installer is still working, let it finish, then run this line again; that is safe,
and it goes on from the tools.
EOF
      exit 1
    fi
    if (( elapsed - last_note >= CLT_NOTE )); then
      detail "Waiting for the command line tools · $(clock "$elapsed")$waiting_note"
      last_note=$elapsed
    fi
  done

  detail "The command line tools are installed."
  detail "$(swift --version 2>&1 | head -1)"
}

# ------------------------------------------------------------------ 2. one consent

step "What this will do"
echo "Worklens will:"
if [[ "$toolchain" != ready ]]; then
  echo "  • install Apple's command line tools (about a gigabyte), through Apple's own dialog"
fi
cat <<EOF
  • download its source to ~/Library/Application Support/Worklens/src
  • build it (a few minutes the first time, shown as one progress line)
  • create a certificate in your login keychain, so macOS remembers your permissions
  • install Worklens to /Applications
  • put a \`worklens\` command on your PATH
  • open Worklens, which starts on its welcome window
EOF
detail "Nothing here uses sudo, and your keys and database stay in"
detail "~/Library/Application Support/Worklens, beside that folder and never inside it."

if (( DRY_RUN )); then
  echo
  detail "dry run: that is the whole plan, and nothing above or below has happened."
  if [[ "$toolchain" != ready ]]; then
    detail "would run 'xcode-select --install', which opens Apple's dialog for you to answer,"
    detail "then wait up to $(span "$CLT_TIMEOUT") for the tools before going on."
  fi
  if [[ -d "$SRC/.git" ]]; then
    detail "would update the existing checkout at $SRC"
  else
    detail "would clone $REPO_URL into $SRC"
  fi
  detail "would then run scripts/setup.sh --yes there, which never runs 'make install-env'."
  detail "it shows the build as one progress line and keeps the whole log in the data"
  detail "folder's logs/build.log, and prints that path when it starts."
  detail "'make setup SETUP_ARGS=--dry-run' in a checkout prints each of its commands."
  exit 0
fi

# --yes is for a run with no terminal to answer on — Claude Code's, say — where the agent has
# shown the person this plan (from --dry-run) and they said yes in chat. It skips this one
# question and nothing else: setup.sh still leaves "Point the installed app at this checkout?"
# at N, and every macOS dialog, Apple's command line tools installer included, is still the
# person's to answer.
if (( ASSUME_YES )); then
  echo "Continue? [y/N] y (--yes)"
  reply=y
else
  read -r -p "Continue? [y/N] " reply || reply=""
fi
# Declining is a supported outcome, not an error — the same rule scripts/setup.sh states.
[[ "$reply" == [Yy]* ]] || { echo "Nothing was changed."; exit 0; }

[[ "$toolchain" == ready ]] || install_toolchain

# ------------------------------------------------------------------ 3. the fixed checkout

step "Getting the source"
if [[ -e "$SRC" ]]; then
  if [[ -d "$SRC/.git" && -f "$SRC/Package.swift" && -f "$SRC/scripts/setup.sh" ]]; then
    detail "already here — updating $SRC"
    if ! git -C "$SRC" pull --ff-only; then
      die "$SRC could not be updated. Move or remove it and run this again; nothing was changed."
    fi
  else
    die "$SRC exists but is not a Worklens checkout. Move or remove it and run this again; nothing was changed."
  fi
else
  detail "cloning into $SRC"
  mkdir -p "$(dirname "$SRC")"
  git clone "$REPO_URL" "$SRC"
fi
detail "Worklens updates itself from this folder, so leave it where it is. A checkout of your"
detail "own somewhere else is untouched and stays yours to build by hand."

if (( CLONE_ONLY )); then
  echo
  detail "--clone-only: stopping here. Run 'make setup' in that folder when you are ready."
  exit 0
fi

# ------------------------------------------------------------------ 4. the rest is setup.sh

step "Building and installing"
detail "scripts/setup.sh does the rest; you have already said yes to all of it."
# --yes answers every question in setup.sh except one: it leaves "Point the installed app at this
# checkout?" at its N default. That question runs `make install-env`, which pins DATA_DIR to the
# checkout's absolute path — and the merged file outranks every other layer, so it would put the
# database inside a git checkout this script pulls into. The installed app keeps the standard
# data directory instead, and this folder holds only source.
#
# setup.sh ends with "What is left for you" — Screen Recording and the Gemini key, the two steps
# no script can take — so that is the last thing on screen for both paths, and this script adds
# nothing after it. A failed build stops setup.sh with the log's path and what to try, and
# running this line again picks up from there.
"$SRC/scripts/setup.sh" --yes
exit 0
