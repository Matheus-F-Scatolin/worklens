#!/usr/bin/env bash
# Renders Resources/AppIcon.icns, the glyph previews and docs/media/social-preview.png from
# Sources/.../WorklensMark.swift.
#
# `swiftc` over two files rather than `swift run`: the mark is a leaf with no dependencies, so
# the renderer needs no package build, and compiling it *with* the app's own copy is what keeps
# the icon, the menu-bar glyphs and the social card one shape instead of three that look alike.
#
# `--banner` renders the social card alone and `--candidates` the two icon candidates alone;
# both skip the icns step.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"

BUILD=$(mktemp -d)
trap 'rm -rf "$BUILD"' EXIT

swiftc -O Sources/WorklensCore/UI/WorklensMark.swift scripts/render-icon.swift \
  -o "$BUILD/render-icon"
"$BUILD/render-icon" "$ROOT" "$@"

if [[ " $* " == *" --banner "* ]]; then
  echo "rendered docs/media/social-preview.png ($(du -h docs/media/social-preview.png | cut -f1))"
  exit 0
fi

if [[ " $* " == *" --candidates "* ]]; then
  exit 0
fi

# iconutil is in the base system, not gated behind Xcode.app.
rm -f Resources/AppIcon.icns
iconutil --convert icns --output Resources/AppIcon.icns Resources/AppIcon.iconset
echo "rendered Resources/AppIcon.icns ($(du -h Resources/AppIcon.icns | cut -f1))"
