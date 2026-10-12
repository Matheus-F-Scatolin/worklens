#!/usr/bin/env bash
# The toolchain checks (#118).
#
# It is a shell script and not a subcommand because of what it checks: a Swift binary cannot
# diagnose the toolchain that failed to build it. Everything here has to be true *before*
# `swift build` runs, which is why `make build` calls it first.
#
# Never fails the build. A warning that stops you working is worse than the trap it warns about;
# every one of these is "this will bite you later", not "this cannot proceed".
set -uo pipefail

cd "$(dirname "$0")/.."

# The floor in Package.swift, which is the only number that has to hold: `// swift-tools-version`
# is what SwiftPM refuses to build below.
REQUIRED_SWIFT="$(sed -n '1s/.*swift-tools-version:\([0-9.]*\).*/\1/p' Package.swift)"
REQUIRED_SWIFT="${REQUIRED_SWIFT:-6.1}"

status=0
ok()   { printf 'ok    %-22s %s\n' "$1" "$2"; }
warn() { printf 'warn  %-22s %s\n' "$1" "$2"; status=1; }

# --- the toolchain itself -----------------------------------------------------------------
if ! command -v swift >/dev/null 2>&1; then
  warn "swift" "not on PATH — run \`xcode-select --install\`"
else
  VERSION="$(swift --version 2>&1 | sed -n 's/.*Swift version \([0-9][0-9.]*\).*/\1/p' | head -1)"
  if [[ -z "$VERSION" ]]; then
    warn "swift" "could not read a version out of \`swift --version\`"
  # sort -V puts the required version first when the installed one is at least as new.
  elif [[ "$(printf '%s\n%s\n' "$REQUIRED_SWIFT" "$VERSION" | sort -V | head -1)" != "$REQUIRED_SWIFT" ]]; then
    warn "swift" "$VERSION is below the $REQUIRED_SWIFT this package needs"
  else
    ok "swift" "$VERSION (needs $REQUIRED_SWIFT)"
  fi
fi

DEVELOPER_DIR="$(xcode-select -p 2>/dev/null || true)"
if [[ -z "$DEVELOPER_DIR" || ! -d "$DEVELOPER_DIR" ]]; then
  warn "xcode-select" "no developer directory — run \`xcode-select --install\`"
else
  ok "xcode-select" "$DEVELOPER_DIR"
fi

# --- the trap that costs a whole session --------------------------------------------------
# On a Command Line Tools machine bare `swift test` prints "Build complete!", runs nothing and
# exits 0. The Makefile passes the -F, -plugin-path and rpath flags that fix it; nothing else
# does. So the check is not "is this broken" — it is "on this machine, `swift test` lies".
if [[ -n "$DEVELOPER_DIR" && -d "$DEVELOPER_DIR/Library/Developer/Frameworks/Testing.framework" ]]; then
  warn "swift-testing" \
    "Testing.framework is in $DEVELOPER_DIR/Library/Developer/Frameworks, not on the package's search paths — use \`make test\`, because bare \`swift test\` runs nothing and still exits 0"
elif [[ -n "$DEVELOPER_DIR" ]]; then
  ok "swift-testing" "on the default search paths (full Xcode) — \`make test\` is still the documented way"
fi

# --- the SDK / Swift mismatch -------------------------------------------------------------
# scripts/sdkroot.sh prints an older SDK when the installed one is newer than the Swift beside
# it, which is the state where every `@State` fails with "plugin for module 'SwiftUIMacros' not
# found". Printing nothing means the pair matches.
# An SDKROOT already in the environment always wins, including the one the Makefile exports
# from this same script — so say which it is rather than reporting a match nobody arranged.
if [[ -n "${SDKROOT:-}" ]]; then
  ok "sdk" "pinned by SDKROOT=$SDKROOT"
else
  MATCHED="$(scripts/sdkroot.sh 2>/dev/null || true)"
  if [[ -n "$MATCHED" ]]; then
    warn "sdk" "the installed SDK is newer than this Swift; build against $MATCHED — which is what the Makefile does for you"
  else
    ok "sdk" "matches this Swift"
  fi
fi

if (( status != 0 )); then
  echo
  echo "note: these are warnings, not errors — the build continues."
fi
exit 0
