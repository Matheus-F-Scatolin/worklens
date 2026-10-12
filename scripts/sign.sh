#!/usr/bin/env bash
# Code-signs build/Worklens.app.
#
# macOS ties Screen Recording permission to the code signature, so an ad-hoc signature ("-")
# makes every rebuild look like a brand-new app and the permission has to be re-granted.
# Run `make dev-cert` once to create the self-signed "Worklens Dev" certificate and plain
# `make sign` finds it; SIGN_IDENTITY overrides the name, and SIGN_IDENTITY=- forces ad-hoc.
set -euo pipefail

cd "$(dirname "$0")/.."

APP="build/Worklens.app"
DEFAULT_IDENTITY="Worklens Dev"
ENTITLEMENTS="Resources/Worklens.entitlements"

if [[ ! -d "$APP" ]]; then
  echo "error: $APP not found — run 'make bundle' first" >&2
  exit 1
fi

# Unset means "use the dev certificate if this Mac has one" — a keychain without it still
# signs ad-hoc, so a fresh clone needs no setup. An untrusted certificate does not count:
# `find-identity -v` lists only identities codesign will actually accept, and trusting it is a
# separate step from creating it — which is exactly what `make dev-cert` does for you.
IDENTITY="${SIGN_IDENTITY-}"
if [[ -z "$IDENTITY" ]]; then
  if security find-identity -v -p codesigning | grep -Fq "\"$DEFAULT_IDENTITY\""; then
    IDENTITY="$DEFAULT_IDENTITY"
  else
    IDENTITY="-"
  fi
fi

# The hardened runtime blocks Apple events unless the binary says it sends them, and a build
# without this entitlement cannot read a browser tab URL *or* provoke the consent dialog — it
# simply never appears under Privacy & Security → Automation (#64). Signed into both branches so
# an ad-hoc build behaves the same as a certificate one.
#
# The entitlements file holds one key and no comments: codesign parses it with AMFI's XML reader,
# which rejects an XML comment outright ("AMFIUnserializeXML: syntax error"). The explanation
# lives here instead. It grants only permission to *ask* — macOS still shows the per-application
# consent dialog, worded by NSAppleEventsUsageDescription in Info.plist.
if [[ ! -f "$ENTITLEMENTS" ]]; then
  echo "error: $ENTITLEMENTS not found" >&2
  exit 1
fi

if [[ "$IDENTITY" == "-" ]]; then
  echo "signing $APP ad-hoc — run \`make dev-cert\` once to create a \"$DEFAULT_IDENTITY\""
  echo "  certificate; without it this build's Screen Recording and Accessibility grants do not"
  echo "  survive the next rebuild, and auto-update stays off for the same reason"
else
  echo "signing $APP with identity: $IDENTITY"
fi

# `--options runtime` in both branches. It was only ever in the identity branch (31b4149 added
# the Apple Events entitlement to both but the hardened runtime to one), and an ad-hoc build
# worked anyway because without the hardened runtime the entitlement is not required — so this is
# a consistency change, not a bug fix: the two builds should differ in the identity and nothing
# else, or an ad-hoc build is not a rehearsal for a signed one.
codesign --force --deep --options runtime --entitlements "$ENTITLEMENTS" --sign "$IDENTITY" "$APP"

codesign --verify --verbose "$APP"

# Print what the signature actually carries: a silently dropped entitlement is exactly the
# failure #64 spent a day on.
echo "entitlements:"
codesign -d --entitlements - --xml "$APP" 2>/dev/null | plutil -p - | sed 's/^/  /' 
