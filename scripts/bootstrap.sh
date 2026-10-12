#!/usr/bin/env bash
# One pasteable line for a Mac that has never seen Worklens (#243):
#
#   /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Matheus-F-Scatolin/worklens/main/scripts/bootstrap.sh)"
#
# It checks the toolchain, asks once — naming every write before the first one happens — clones
# the source into one fixed path, and hands over to scripts/setup.sh, which does the rest.
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
# No sudo, anywhere. Nothing is downloaded on your behalf except the source itself. Safe to
# re-run: an existing checkout is updated, never replaced.
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
    -h|--help) sed -n '21,24p' "$0"; exit 0 ;;
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

if ! xcode-select -p >/dev/null 2>&1 || ! command -v swift >/dev/null 2>&1; then
  cat >&2 <<'EOF'

Worklens needs Apple's command line tools. Run `xcode-select --install`, let it finish — it is
about a gigabyte — then run this line again.
EOF
  exit 1
fi
command -v git >/dev/null 2>&1 || die "git is missing — run 'xcode-select --install' and try again"
detail "$(swift --version 2>&1 | head -1)"

# ------------------------------------------------------------------ 2. one consent

step "What this will do"
cat <<EOF
Worklens will:
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
# at N, and every macOS dialog is still the person's to answer.
if (( ASSUME_YES )); then
  echo "Continue? [y/N] y (--yes)"
  reply=y
else
  read -r -p "Continue? [y/N] " reply || reply=""
fi
# Declining is a supported outcome, not an error — the same rule scripts/setup.sh states.
[[ "$reply" == [Yy]* ]] || { echo "Nothing was changed."; exit 0; }

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
