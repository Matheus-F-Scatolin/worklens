#!/usr/bin/env bash
# Print the path of an installed Worklens.app that belongs to THIS checkout, or nothing at all.
#
# "Belongs to" is the `WLRepoPath` scripts/bundle.sh stamps (#119), not merely "exists": several
# checkouts of this repository live on the reference machine at once, and an installed copy built
# from another one is somebody else's app. `make run` must not open it, `scripts/update.sh` must
# not quit it, and `make install` warns before replacing it.
#
# Exit 1 and silence when there is no such copy — callers treat that as "use build/Worklens.app".
#
# usage: scripts/installed-app.sh [--rehearsal]   (--rehearsal: Worklens Rehearsal.app instead)
set -euo pipefail

cd "$(dirname "$0")/.."
REPO="$PWD"
# shellcheck source=scripts/app-identity.sh
source scripts/app-identity.sh
wl_identity "$([[ "${1:-}" == --rehearsal ]] && echo rehearsal || echo main)"

for candidate in "/Applications/$WL_APP_BUNDLE" "$HOME/Applications/$WL_APP_BUNDLE"; do
  wl_guard "$candidate"
  [[ -d "$candidate" ]] || continue
  stamped="$(plutil -extract WLRepoPath raw -o - "$candidate/Contents/Info.plist" 2>/dev/null || true)"
  [[ "$stamped" == "$REPO" ]] || continue
  echo "$candidate"
  exit 0
done

exit 1
