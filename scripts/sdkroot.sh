#!/usr/bin/env bash
# Print an SDKROOT that matches the installed Swift, or nothing when the default SDK already
# does. Nothing is the normal answer; this exists for one specific mismatch.
#
# A Command Line Tools update can install a macOS SDK newer than the Swift that ships beside
# it. That combination does not build the app target: SDK 27's SwiftUI declares `@State` and
# friends as macros, and a Swift 6.4 whose own target is `arm64-apple-macosx26.0` carries no
# `libSwiftUIMacros.dylib`, so every `@State` fails with "plugin for module 'SwiftUIMacros'
# not found". The older SDK is still on disk in those cases, and building against it works.
#
# Deliberately silent and exit 0 on anything unexpected — a build must not fail because this
# heuristic could not read a version string.
set -euo pipefail

# "Target: arm64-apple-macosx26.0" -> 26
swift_major="$(swift -version 2>/dev/null | sed -n 's/.*-apple-macosx\([0-9][0-9]*\).*/\1/p' | head -1)"
sdk_major="$(xcrun --show-sdk-version 2>/dev/null | cut -d. -f1)"
[[ "$swift_major" =~ ^[0-9]+$ && "$sdk_major" =~ ^[0-9]+$ ]] || exit 0
(( sdk_major > swift_major )) || exit 0

default_sdk="$(xcrun --show-sdk-path 2>/dev/null)" || exit 0
sdk_dir="$(dirname "$default_sdk")"

# Prefer the unsuffixed MacOSX<major>.sdk (a symlink to the newest point release), else the
# highest MacOSX<major>.<minor>.sdk sitting next to it.
if [[ -d "$sdk_dir/MacOSX$swift_major.sdk" ]]; then
  echo "$sdk_dir/MacOSX$swift_major.sdk"
  exit 0
fi
for sdk in $(ls -d "$sdk_dir/MacOSX$swift_major."*.sdk 2>/dev/null | sort -V -r); do
  echo "$sdk"
  exit 0
done
