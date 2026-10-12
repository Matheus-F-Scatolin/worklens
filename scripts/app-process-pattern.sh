#!/usr/bin/env bash
# Print the `pgrep -f`/`pkill -f` pattern that matches the Worklens *menu bar* running from one
# binary, and nothing else running from it.
#
# usage: scripts/app-process-pattern.sh /path/to/Worklens.app/Contents/MacOS/Worklens
#
# A bare `pkill -f "$binary"` also matches `Worklens mcp`, the server Claude Desktop, Claude Code
# and Codex launch from the same binary. Killing it is not a restart: the client keeps the tool
# list it already read and answers every call with a bare "Tool execution failed" until the user
# restarts it, and since #106 the update runs unattended. So the menu bar is matched by what it is
# launched with — nothing (`open`, `make run`), `app`, or the older `run` — and every other
# subcommand is left alone. A server left running keeps the binary it started with, which
# `rm -rf` unlinks rather than rewrites, and the client picks up the new build the next time it
# starts the server.
set -euo pipefail

binary="${1:?usage: scripts/app-process-pattern.sh <binary>}"

# `pgrep -f` reads an extended regular expression, and a checkout path may hold any of these.
escaped="$(printf '%s' "$binary" | sed -E 's/[][\.*^$+?(){}|]/\\&/g')"
printf '^%s( (app|run)( .*)?)?$\n' "$escaped"
