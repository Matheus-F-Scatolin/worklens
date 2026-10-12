#!/usr/bin/env bash
# The design rules a pane has to keep, checked (#237, #251). `make lint-design` runs this, and
# #251 put it in `make check`.
#
# Three rules. The first is advisory — it fails only when the count goes up — and the two #251
# added are gates, because both of them are things a reader meets rather than things a
# maintainer tidies:
#
#   1. `.font(.system(size:` and `RoundedRectangle(cornerRadius: <number>` under
#      Sources/Worklens: a point size does not follow the user's text size, and a raw corner is
#      one more number to keep in step. Use a `Theme.Text` role, `Theme.Layout.cornerRadius`,
#      or `.card()` / `.panel()`.
#   2. No SHOUTING_SNAKE_CASE key and no `*.md` filename inside a sentence the user reads, under
#      Sources/Worklens/Settings. The key name belongs in the row's `.help()` tooltip, where a
#      maintainer looks for it; the documentation belongs behind "Learn more…". `.help(` lines
#      and comments are therefore exempt — they are the allow-list.
#   3. An `Image(systemName:)` that is a `Button`'s whole label carries an
#      `.accessibilityLabel`. A tooltip is not spoken; an unlabelled icon button reads as
#      "button" and nothing else.
#
# Rules 2 and 3 are scoped to Sources/Worklens/Settings, which is where the Settings copy this
# repository keeps rewriting lives. Widening them is a matter of fixing the hits first.
set -euo pipefail

cd "$(dirname "$0")/.."

status=0

# ---------------------------------------------------------------- 1. design literals

# The count the tree is at. Lower it whenever you remove literals; never raise it.
BASELINE=0

hits=$(grep -rn '\.font(\.system(size:' Sources/Worklens || true)
radii=$(grep -rnE 'RoundedRectangle\(cornerRadius: *[0-9]' Sources/Worklens || true)

report=""
[ -n "$hits" ] && report+="$hits"$'\n'
[ -n "$radii" ] && report+="$radii"$'\n'
report=${report%$'\n'}

count=0
if [ -n "$report" ]; then
    printf '%s\n' "$report"
    count=$(printf '%s\n' "$report" | wc -l | tr -d ' ')
fi

echo "design literals: $count (baseline $BASELINE)"

if [ "$count" -gt "$BASELINE" ]; then
    echo "A new hand-written size or corner landed. Use a Theme role, Theme.Layout, or .card()/.panel()." >&2
    status=1
fi

if [ "$count" -lt "$BASELINE" ]; then
    echo "Below the baseline — lower BASELINE in scripts/design-lint.sh to $count."
fi

# ---------------------------------------------------------------- 2. keys and filenames in copy

echo
echo "== config keys and *.md filenames in Settings copy =="
# Whole files, not line by line: swift-format wraps a long `String(localized:)` so the sentence
# sits on a line of its own, starting with a bare quote — which is the shape most of the
# violations #251 cleared up were in. A grep anchored on the call never sees them.
keys=$(python3 - <<'PY'
import pathlib
import re

KEY = re.compile(r"[A-Z][A-Z0-9]+_[A-Z0-9_]+|[A-Za-z0-9_-]+\.md")
CALL = re.compile(r'String\(\s*localized:\s*|Text\(\s*(?=")|\+\s*(?=")')
LITERAL = re.compile(r'"(?:[^"\\]|\\.)*"')

# Files the rules do not read. Empty since #252 landed its PrivacySettingsView rewrites.
SKIP = set()


def in_help(text, pos):
    """True when `pos` sits inside an unclosed `.help(` — the tooltip is the allow-list."""
    start = text.rfind(".help(", 0, pos)
    if start < 0:
        return False
    depth = 0
    for ch in text[start + len(".help(") - 1 : pos]:
        if ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
    return depth > 0


bad = []
for path in sorted(pathlib.Path("Sources/Worklens/Settings").rglob("*.swift")):
    if path.name in SKIP:
        continue
    # A `//` line is a comment, and comments are the other half of the allow-list. Blanking them
    # rather than dropping them keeps every line number honest.
    text = "\n".join(
        "" if line.lstrip().startswith("//") else line
        for line in path.read_text().splitlines()
    )
    for call in CALL.finditer(text):
        literal = LITERAL.match(text, call.end())
        if literal is None or in_help(text, call.start()):
            continue
        hit = KEY.search(literal.group())
        if hit:
            line = text.count("\n", 0, literal.start()) + 1
            bad.append(f"{path}:{line}: {hit.group()}")
print("\n".join(sorted(set(bad))))
PY
)
if [ -n "$keys" ]; then
    printf '%s\n' "$keys"
    echo "A key name or a filename is the explanation of record in a sentence the user reads." >&2
    echo "Move it into the row's .help() tooltip and say what the setting does instead." >&2
    status=1
else
    echo "  none"
fi

# ---------------------------------------------------------------- 3. icon-only buttons

echo
echo "== icon-only buttons with no spoken label =="
unlabelled=$(python3 - <<'PY'
import pathlib
import re

LOOKAHEAD = 10
bad = []
for path in sorted(pathlib.Path("Sources/Worklens/Settings").rglob("*.swift")):
    lines = path.read_text().splitlines()
    for i, line in enumerate(lines):
        if "} label: {" not in line:
            continue
        body = [l.strip() for l in lines[i + 1:i + 4]]
        # The label closure is one `Image(systemName:)` and nothing else.
        if not body or not body[0].startswith("Image(systemName:"):
            continue
        if len(body) > 1 and body[1] not in ("}", "):"):
            if not body[1].startswith("."):
                continue
        window = "\n".join(lines[i:i + LOOKAHEAD])
        if ".accessibilityLabel" in window:
            continue
        bad.append(f"{path}:{i + 1}: icon-only button with no .accessibilityLabel")
print("\n".join(bad))
PY
)
if [ -n "$unlabelled" ]; then
    printf '%s\n' "$unlabelled"
    echo "Give the button an .accessibilityLabel naming the action; the .help() tooltip is not spoken." >&2
    status=1
else
    echo "  none"
fi

exit "$status"
