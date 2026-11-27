# shellcheck shell=bash
# Sourced, never run: the shell side of `AppIdentity` (Sources/WorklensCore/Config/AppIdentity.swift).
#
# Worklens has two identities. `main` is the real app; `rehearsal` is "Worklens Rehearsal", the
# second app `make rehearse` installs so the owner can walk through a first install without
# touching the real one (docs/rehearsal.md). Every name that ties an install to this Mac comes
# from here, so bundle.sh, sign.sh, install.sh, setup.sh, rehearse.sh and rehearse-clean.sh
# cannot disagree about them, and the Swift side's test pins the same strings.
#
#   source scripts/app-identity.sh
#   wl_identity rehearsal          # or main
#   wl_guard "$path" "$link" …     # rehearsal: exit 70 if any of them is the real app's
#
# The guard is the point. A rehearsal run that would resolve to `Worklens.app`, anything in
# `~/Library/Application Support/Worklens`, the `worklens` link or `dev.worklens.app` (or a
# keychain service of the real app's) stops before it does anything.

wl_identity() {
  case "${1:-main}" in
    main)
      WL_IDENTITY=main
      WL_APP_NAME="Worklens"
      WL_BUNDLE_ID="dev.worklens.app"
      WL_CLI="worklens"
      WL_MCP_NAME="worklens"
      WL_KEYCHAIN_PREFIX="dev.worklens"
      ;;
    rehearsal)
      WL_IDENTITY=rehearsal
      WL_APP_NAME="Worklens Rehearsal"
      WL_BUNDLE_ID="dev.worklens.rehearsal"
      WL_CLI="worklens-rehearsal"
      WL_MCP_NAME="worklens-rehearsal"
      WL_KEYCHAIN_PREFIX="dev.worklens.rehearsal"
      ;;
    *) echo "error: unknown identity '$1'" >&2; return 2 ;;
  esac
  WL_APP_BUNDLE="$WL_APP_NAME.app"
  WL_BUILD_APP="build/$WL_APP_BUNDLE"
  WL_SUPPORT="$HOME/Library/Application Support/$WL_APP_NAME"
  WL_GOOGLE_SERVICE="$WL_KEYCHAIN_PREFIX.google"
}

# True when one string names something of the real app's: a path to Worklens.app or into it,
# ~/Library/Application Support/Worklens or anything inside it, a file or MCP key called
# `worklens`, the real bundle identifier, or a keychain service of the real app's.
wl_is_real() {
  local s="${1%/}"
  case "$s" in
    "") return 1 ;;
    */Worklens.app|*/Worklens.app/*|Worklens.app) return 0 ;;
    *"/Application Support/Worklens"|*"/Application Support/Worklens/"*) return 0 ;;
    */worklens|worklens) return 0 ;;
    dev.worklens.rehearsal|dev.worklens.rehearsal.*) return 1 ;;
    dev.worklens.app|dev.worklens.app.*|dev.worklens.*) return 0 ;;
  esac
  return 1
}

# In a rehearsal, refuse (exit 70, before anything happens) when any argument is the real app's.
# A no-op for the real identity, whose scripts are allowed to touch the real app.
wl_guard() {
  [[ "${WL_IDENTITY:-main}" == rehearsal ]] || return 0
  local s
  for s in "$@"; do
    if wl_is_real "$s"; then
      echo "error: refusing to go on: this rehearsal would touch the real Worklens ($s)." >&2
      echo "       The rehearsal only ever uses Worklens Rehearsal.app, worklens-rehearsal," >&2
      echo "       dev.worklens.rehearsal and ~/Library/Application Support/Worklens Rehearsal." >&2
      exit 70
    fi
  done
}
