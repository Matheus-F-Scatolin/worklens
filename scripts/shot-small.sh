#!/usr/bin/env bash
# Shrinks a screenshot before it enters an agent transcript: 800 px on the long side, JPEG q60,
# ~50 KB instead of the ~500 KB a retina PNG costs. Read the small file, once.
# Usage: scripts/shot-small.sh <in.png> [out.jpg]
#        scripts/shot-small.sh --capture [out.jpg]     # screencapture the whole screen first
set -euo pipefail
[ $# -ge 1 ] || { echo "usage: scripts/shot-small.sh <in.png> [out.jpg] | --capture [out.jpg]" >&2; exit 2; }

if [ "$1" = "--capture" ]; then
  in="$(mktemp -t wl-shot).png"
  screencapture -x "$in"
  out="${2:-${TMPDIR:-/tmp}/wl-shot-small.jpg}"
else
  in="$1"
  out="${2:-${1%.*}-small.jpg}"
fi

sips -Z 800 -s format jpeg -s formatOptions 60 "$in" --out "$out" >/dev/null
echo "$out ($(du -k "$out" | cut -f1) KB)"
