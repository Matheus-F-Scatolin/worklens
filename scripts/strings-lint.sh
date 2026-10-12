#!/usr/bin/env bash
# The gate behind `make lint-strings` (#161). Four checks, in the order they go wrong:
#
#   1. every `.strings`/`.stringsdict` in Resources/*.lproj parses (`plutil -lint`);
#   2. every key the code asks for is in `en.lproj` — a new string that nobody can translate is
#      the failure this catches, and it is the one that happens;
#   3. every translated value carries the same format specifiers as its English one, because
#      `String(format:)` reads them positionally: a dropped `%@` silently loses the clock and a
#      `%lld` translated as `%@` reads an Int as a pointer, which crashes the menu. `plutil -lint`
#      passes both;
#   4. every key a translation declares still exists in the code, so a reworded sentence leaves
#      no orphan behind. A warning, not a failure: a stale line in pt-BR translates nothing and
#      breaks nothing.
#
# There is a CI workflow (.github/workflows/ci.yml), but it is not the gate this repository runs
# on today — this target is. Run it before pushing a change that touches interface copy.
set -euo pipefail

cd "$(dirname "$0")/.."

status=0

echo "== plutil =="
shopt -s nullglob
for catalog in Resources/*.lproj/Localizable.strings Resources/*.lproj/Localizable.stringsdict; do
  plutil -lint "$catalog" || status=1
done
shopt -u nullglob

echo "== keys in the code but not in en.lproj =="
missing=$(scripts/strings-extract.sh --missing)
if [[ -n "$missing" ]]; then
  echo "$missing" | sed 's/^/  missing: /'
  echo "  → add them with: scripts/strings-extract.sh --strings > Resources/en.lproj/Localizable.strings"
  echo "  → a plural belongs in Resources/en.lproj/Localizable.stringsdict, keyed by its English 'other'"
  status=1
else
  echo "  none"
fi

echo "== format specifiers a translation does not match en.lproj on =="
# `L10n.format` hands the translated value straight to `String(format:)`, so a translator who drops
# a `%@` loses the clock, and one who turns a `%lld` into a `%@` makes `String(format:)` read an
# Int as a String pointer — a crash in the menu render path. `plutil -lint` is happy with both, so
# this is the check that has to say no. Reordering is allowed only the way `String(format:)` can
# follow it: with positional `%1$@` markers on both sides.
shopt -s nullglob
for catalog in Resources/*.lproj/Localizable.strings Resources/*.lproj/Localizable.stringsdict; do
  [[ "$catalog" == Resources/en.lproj/* ]] && continue
  english="Resources/en.lproj/$(basename "$catalog")"
  [[ -f "$english" ]] || continue
  mismatches=$(
    python3 - "$english" "$catalog" <<'PY'
import json, re, subprocess, sys

SPEC = re.compile(
    r"%(?:(\d+)\$)?[-+ #0']*(?:\d+|\*)?(?:\.(?:\d+|\*))?(?:hh|h|ll|l|q|L|z|t|j)?([@diouxXeEfgGcCsSpaAF])"
)


def specs(text):
    """The conversions in `text`, in order, as (position or None, normalised spec)."""
    text = re.sub(r"%#@\w+@", "\x00", text).replace("%%", "")
    out = []
    for index, chunk in enumerate(text.split("\x00")):
        if index:
            out.append((None, "#@"))
        for match in SPEC.finditer(chunk):
            body = match.group(0)
            length = "ll" if "ll" in body[:-1] else ""
            out.append((int(match.group(1)) if match.group(1) else None, "%" + length + match.group(2)))
    return out


def shape(text):
    """What `String(format:)` actually sees: an ordered list, or a position->spec map."""
    found = specs(text)
    if any(position for position, _ in found):
        return dict((position, spec) for position, spec in found if position)
    return [spec for _, spec in found]


def load(path):
    return json.loads(subprocess.run(
        ["plutil", "-convert", "json", "-o", "-", path], check=True, capture_output=True).stdout)


def leaves(catalog, stringsdict):
    """key -> {label: string} for everything a mismatch can hide in."""
    out = {}
    for key, value in catalog.items():
        if not stringsdict:
            out[key] = {"": value}
            continue
        rows = {"NSStringLocalizedFormatKey": value.get("NSStringLocalizedFormatKey", "")}
        for name, variable in value.items():
            if not isinstance(variable, dict):
                continue
            for category, text in variable.items():
                if category.startswith("NSString"):
                    continue
                rows["%s/%s" % (name, category)] = text
        out[key] = rows
    return out


english_path, translated_path = sys.argv[1], sys.argv[2]
is_dict = english_path.endswith(".stringsdict")
english = leaves(load(english_path), is_dict)
translated = leaves(load(translated_path), is_dict)

for key in sorted(translated):
    if key not in english:
        continue  # an orphan; the check above already warns about it
    for label, text in sorted(translated[key].items()):
        # A plural category English does not have (pt-BR has one/other, Russian four) is still
        # held to the shape of English's `other`.
        want = english[key].get(label) or english[key].get(label.split("/")[0] + "/other")
        if want is None:
            continue
        if shape(want) != shape(text):
            where = key if not label else "%s [%s]" % (key, label)
            print("%s\n      en: %s\n      tr: %s" % (where, shape(want), shape(text)))
PY
  )
  if [[ -n "$mismatches" ]]; then
    echo "$mismatches" | sed "s|^|  $catalog: |"
    status=1
  fi
done
shopt -u nullglob
echo "  checked"

echo "== keys in a translation that the code no longer uses =="
code_keys=$(mktemp)
{ scripts/strings-extract.sh; scripts/strings-extract.sh --plurals; } | LC_ALL=C sort -u > "$code_keys"
shopt -s nullglob
for catalog in Resources/*.lproj/Localizable.strings Resources/*.lproj/Localizable.stringsdict; do
  [[ "$catalog" == Resources/en.lproj/* ]] && continue
  orphans=$(
    plutil -convert json -o - "$catalog" \
      | python3 -c 'import json,sys; [print(k) for k in json.load(sys.stdin)]' \
      | LC_ALL=C sort -u \
      | LC_ALL=C comm -23 - "$code_keys"
  )
  [[ -n "$orphans" ]] && echo "$orphans" | sed "s|^|  warning: $catalog: |"
done
shopt -u nullglob
rm -f "$code_keys"

exit "$status"
