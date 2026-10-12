#!/usr/bin/env bash
# Thin wrapper around `worklens install-env` (#129).
#
# The merge itself is Swift now — Sources/Worklens/CLI/InstallEnvCommand.swift on top of
# WorklensCore's EnvInstall — so it shares `DotEnv` with the loader that will read the result and
# its rules are unit-tested. This script survives because README, `make install-env` and
# scripts/setup.sh all name it, and because it is the one place that knows how to find a binary
# in a checkout.
#
# What the command does: it merges ./.env into ~/Library/Application Support/Worklens/.env, where
# a bundled Worklens.app looks for it. Keys only the installed file sets are kept, keys only this
# checkout sets are added, and a key the two disagree about is printed as a three-column diff and
# left at the installed value — `--force` takes this checkout's instead. It used to be a copy,
# which is how an edit made anywhere but a checkout was silently thrown away.
#
# That merge is also what keeps an installed API key safe (#124): the destination is where
# Settings and `worklens config set` write, and a key only that file has is never touched —
# no timestamp check needed, because nothing installed is overwritten without --force.
#
# DATA_DIR is pinned to an absolute path on the way in: the copy is read from a different
# directory than the one it was written in, and the app's own working directory is `/`, so a
# verbatim `DATA_DIR=./data` would mean "wherever install-env last ran" — and an absolute
# DATA_DIR here outranks every checkout's own .env, which is how two agents' captures landed in
# another worktree's database (#34).
#
# Usage: scripts/install-env.sh [--data-dir PATH] [--no-pin] [--force]
#   --data-dir PATH  pin DATA_DIR to PATH instead of this checkout's ./data
#   --no-pin         copy the file through untouched, leaving the data directory to the .env
#                    itself or, when it sets none, to the app's own default
#   --force          take this checkout's value for every key the two files disagree about
set -euo pipefail

ORIGIN="$PWD"
ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --data-dir)
      [[ $# -ge 2 ]] || { echo "error: --data-dir needs a path" >&2; exit 2; }
      path="$2"
      # Absolute before the `cd` below, so a relative path means what the user typed it next to.
      [[ "$path" == /* || "$path" == "~"* ]] || path="$ORIGIN/$path"
      ARGS+=(--data-dir "$path")
      shift 2
      ;;
    --no-pin) ARGS+=(--no-pin); shift ;;
    --force) ARGS+=(--force); shift ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "error: unknown option $1" >&2; exit 2 ;;
  esac
done

cd "$(dirname "$0")/.."
CHECKOUT="$PWD"

if [[ ! -f "$CHECKOUT/.env" ]]; then
  echo "error: no .env in $CHECKOUT (cp .env.example .env)" >&2
  exit 1
fi
# The checkout's .env holds the API key too: owner-only, like the copy this installs.
chmod 600 "$CHECKOUT/.env"

# A checkout's own build first — the point of the command is to install *this* checkout's
# configuration, and an older `worklens` on PATH may not have the subcommand at all.
BIN=""
for candidate in \
  "${WORKLENS_BIN:-}" \
  "$CHECKOUT/.build/release/Worklens" \
  "$CHECKOUT/.build/debug/Worklens" \
  "$CHECKOUT/build/Worklens.app/Contents/MacOS/Worklens"; do
  if [[ -n "$candidate" && -x "$candidate" ]]; then BIN="$candidate"; break; fi
done
if [[ -z "$BIN" ]]; then
  # Only if it actually has the subcommand — an older installed binary would otherwise fail
  # with ArgumentParser's "Unknown subcommand" instead of the advice below.
  fallback="$(command -v worklens || true)"
  if [[ -n "$fallback" ]] && "$fallback" install-env --help >/dev/null 2>&1; then
    BIN="$fallback"
  fi
fi
if [[ -z "$BIN" ]]; then
  echo "error: no Worklens binary to run — 'make build' first (or set WORKLENS_BIN)" >&2
  exit 1
fi

"$BIN" install-env --from "$CHECKOUT/.env" ${ARGS+"${ARGS[@]}"}
