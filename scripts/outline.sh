#!/usr/bin/env bash
# Prints the declarations of one or more Swift files with line numbers, so an agent can find
# the region it needs and then Read just that range instead of dumping the whole file.
# Usage: scripts/outline.sh Sources/Worklens/App/AppModel.swift [more files]
set -euo pipefail
[ $# -ge 1 ] || { echo "usage: scripts/outline.sh <file.swift> [more files]" >&2; exit 2; }

MODIFIERS='(public|private|fileprivate|internal|open|final|static|override|nonisolated|mutating|convenience|required|indirect|@MainActor|@discardableResult|@objc)'
KINDS='(struct|class|actor|enum|protocol|extension|func|init|deinit|var|let|case|typealias|subscript)'

for f in "$@"; do
  [ $# -gt 1 ] && echo "## $f"
  grep -nE "^[[:space:]]{0,4}($MODIFIERS[[:space:]]+)*$KINDS[[:space:]]|^[[:space:]]*// MARK:" "$f" \
    | sed -E 's/[[:space:]]*\{[[:space:]]*$//; s/^([0-9]+):[[:space:]]*/\1\t/'
done
