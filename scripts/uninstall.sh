#!/usr/bin/env bash
# Removes what installing Worklens put on this Mac: the mirror of scripts/bootstrap.sh and
# scripts/setup.sh (with `make dev-cert`, `make install` and `Worklens mcp install` inside them).
#
#   /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Matheus-F-Scatolin/worklens/main/scripts/uninstall.sh)"
#
# It looks first and changes nothing until you have read the list and said yes once. What it can
# remove: the running menu bar app, the `worklens` entry in Claude Desktop's, Claude Code's and
# Codex's MCP configuration (that entry only, with a copy of the old file kept beside it), the
# Screen Recording, Accessibility and Automation answers macOS keeps for dev.worklens.app, the
# Google token in your keychain, the "Worklens Dev" signing certificate with its trust
# setting, Worklens.app, its preferences and caches, the `worklens` symlink on your PATH, and the
# source checkout at ~/Library/Application Support/Worklens/src.
#
# Your data is not on that list. The database, the screenshots, settings.json and the .env with
# your key are your work: they stay unless you answer a separate question by typing `delete`, or
# pass --delete-data. --yes alone never deletes them.
#
# No sudo, anywhere. Safe to re-run: every step looks before it removes, and what is already gone
# is not mentioned again. Every path below derives from $HOME, except the two system folders
# `make install` may have used, which APPS_DIR and BIN_DIR override exactly as they do there.
#
# usage: bash scripts/uninstall.sh [--dry-run] [--yes] [--delete-data]
#   --dry-run      print what would be removed, ask nothing, change nothing
#   --yes          the person has read the list and said yes (an agent asks them in chat);
#                  it keeps the data
#   --delete-data  also delete ~/Library/Application Support/Worklens: the database,
#                  screenshots, settings and the .env holding your key
set -euo pipefail

# This file may live in the checkout it is about to delete, and bash reads a script as it runs
# it. So a run from a file continues from a private copy; the one-line `bash -c` form is already
# in memory and needs none.
# The copy is deleted on the way out only when this process is that copy: a WORKLENS_UNINSTALL_COPY
# inherited from anywhere else names nothing this script will remove.
SELF="${BASH_SOURCE[0]:-}"
OWN_COPY=""
if [[ -n "$SELF" && -f "$SELF" ]]; then
  if [[ "${WORKLENS_UNINSTALL_COPY:-}" == "$SELF" && "${SELF##*/}" == worklens-uninstall.* ]]; then
    OWN_COPY="$SELF"
  else
    copy="$(mktemp "${TMPDIR:-/tmp}/worklens-uninstall.XXXXXX")" || { echo "error: mktemp failed" >&2; exit 1; }
    cat "$SELF" > "$copy"
    WORKLENS_UNINSTALL_COPY="$copy" exec "${BASH:-/bin/bash}" "$copy" "$@"
  fi
fi
unset WORKLENS_UNINSTALL_COPY

cleanup() {
  if [[ -n "$OWN_COPY" ]]; then rm -f "$OWN_COPY"; fi
}
trap cleanup EXIT

usage() {
  cat <<'EOF'
usage: bash scripts/uninstall.sh [--dry-run] [--yes] [--delete-data]
  --dry-run      print what would be removed, ask nothing, change nothing
  --yes          the person has read the list and said yes; the data is kept
  --delete-data  also delete ~/Library/Application Support/Worklens (database, screenshots,
                 settings and the .env holding your key)
EOF
}

DRY_RUN=0
ASSUME_YES=0
DELETE_DATA=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--dry-run) DRY_RUN=1 ;;
    -y|--yes) ASSUME_YES=1 ;;
    --delete-data) DELETE_DATA=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown argument $1" >&2; exit 2 ;;
  esac
  shift
done

BOLD=$'\033[1m'; DIM=$'\033[2m'; PLAIN=$'\033[0m'
[[ -t 1 ]] || { BOLD=""; DIM=""; PLAIN=""; }

step()   { echo; echo "${BOLD}==> $*${PLAIN}"; }
detail() { echo "${DIM}    $*${PLAIN}"; }
die()    { echo "error: $*" >&2; exit 1; }

[[ "$(uname -s)" == "Darwin" ]] || die "Worklens runs on macOS only, this is $(uname -s)"
# Every rm below is under $HOME. A HOME that is empty, relative or / would make those paths mean
# something else entirely, so it is taken as the real folder it names, and that cannot be /.
[[ "${HOME:-}" == /* ]] || die "HOME is '${HOME:-}', not a home folder"
HOME="$(cd "$HOME" 2>/dev/null && pwd -P)" || die "HOME is not a folder"
[[ "$HOME" == /*[!/]* ]] || die "HOME is /, not a home folder"

# Leave the folder this started in: it may be the checkout removed below. And git looks only at
# the checkout it is pointed at.
cd "$HOME"
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY

SUPPORT="$HOME/Library/Application Support/Worklens"
SRC="$SUPPORT/src"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
CERT_NAME="${SIGN_IDENTITY:-Worklens Dev}"
BUNDLE_ID="dev.worklens.app"
GOOGLE_SERVICE="dev.worklens.google"
APP_DIRS=("${APPS_DIR:-/Applications}" "$HOME/Applications")
BIN_DIRS=("${BIN_DIR:-/usr/local/bin}" "$HOME/.local/bin")
LSREGISTER="${LSREGISTER:-/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister}"
CLAUDE_DESKTOP_CONFIG="$HOME/Library/Application Support/Claude/claude_desktop_config.json"
CLAUDE_CODE_CONFIG="$HOME/.claude.json"
CODEX_CONFIG="$HOME/.codex/config.toml"

# Every mutating line goes through run(), so --dry-run is this same script with the removals
# turned into echoes, the way scripts/setup.sh does it.
# The echo goes to fd 3, this script's own stdout, so a step that silences the command's output
# still shows what it would have run.
exec 3>&1
run() {
  if (( DRY_RUN )); then
    { printf '    would run:'; printf ' %q' "$@"; printf '\n'; } >&3
  else
    "$@"
  fi
}

LEFT=()   # what is left for the person, printed last
left() { LEFT+=("$*"); }

# ------------------------------------------------------------------ helpers that only look

trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

unquote() {
  local v="$1"
  if [[ ${#v} -ge 2 && ( ( "$v" == \"*\" ) || ( "$v" == \'*\' ) ) ]]; then v="${v:1:${#v}-2}"; fi
  printf '%s' "$v"
}

# The last DATA_DIR in a .env file, read the way DotEnv.swift reads it: an `export ` in front,
# spaces around the `=`, one pair of quotes, and a ` #` comment after an unquoted value. The file
# is read, never sourced.
env_data_dir() {
  local line key value cut found="" prev c i
  [[ -f "$1" && -r "$1" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="$(trim "${line%$'\r'}")"
    [[ -z "$line" || "$line" == \#* ]] && continue
    if [[ "$line" == "export "* || "$line" == "export"$'\t'* ]]; then line="$(trim "${line#export}")"; fi
    [[ "$line" == *=* ]] || continue
    key="$(trim "${line%%=*}")"
    [[ "$key" == DATA_DIR ]] || continue
    value="${line#*=}"
    cut="$(trim "$value")"
    if [[ ${#cut} -ge 2 && ( ( "$cut" == \"*\" ) || ( "$cut" == \'*\' ) ) ]]; then
      value="${cut:1:${#cut}-2}"
    else
      # A `#` starts a comment only after whitespace, counted before the value is trimmed.
      prev=""
      for (( i = 0; i < ${#value}; i++ )); do
        c="${value:i:1}"
        if [[ "$c" == "#" && -n "$prev" && "$prev" == [[:space:]] ]]; then value="${value:0:i}"; break; fi
        prev="$c"
      done
      value="$(unquote "$(trim "$value")")"
    fi
    found="$value"
  done < "$1"
  printf '%s' "$found"
}

# A DATA_DIR value as the app reads it (Config.fileLayer): `~` expanded, a relative path taken
# from the folder of the file it came from.
resolve_dir() {
  local dir="$1" base="$2"
  [[ -n "$dir" ]] || return 0
  if [[ "$dir" == "~" ]]; then dir="$HOME"
  elif [[ "$dir" == "~/"* ]]; then dir="$HOME/${dir:2}"
  elif [[ "$dir" != /* ]]; then dir="$base/$dir"
  fi
  printf '%s\n' "$dir"
}

# The real path of a folder that may not exist yet: its deepest existing folder with every
# symlink and `..` resolved, then the rest as written.
physical() {
  local p="$1" rest="" base
  while [[ ! -d "$p" ]]; do
    base="${p##*/}"; p="${p%/*}"
    [[ -n "$p" ]] || p="/"
    rest="/$base$rest"
  done
  p="$(cd "$p" 2>/dev/null && pwd -P)" || p="$1"
  [[ "$p" == / ]] && p=""
  printf '%s%s\n' "$p" "$rest"
}

inside() { [[ "$1" == "$2" || "$1" == "$2/"* ]]; }

is_worklens_app() {
  [[ -d "$1" ]] || return 1
  [[ "$(plutil -extract CFBundleIdentifier raw -o - "$1/Contents/Info.plist" 2>/dev/null || true)" == "$BUNDLE_ID" ]]
}

# The menu bar app from any Worklens.app, matched the way scripts/app-process-pattern.sh does it:
# launched with nothing, `app` or `run`. A `Worklens mcp` server a client started is left alone;
# it keeps running on the binary it started with until that client restarts.
APP_PATTERN='^/.*/Worklens\.app/Contents/MacOS/Worklens( (app|run)( .*)?)?$'
app_running() { pgrep -a -f "$APP_PATTERN" >/dev/null 2>&1; }

# The SHA-1 of every certificate in the login keychain whose label is exactly $CERT_NAME
# (`-c` alone matches any name that contains it).
cert_hashes() {
  [[ -f "$KEYCHAIN" ]] || return 0
  security find-certificate -a -c "$CERT_NAME" -Z "$KEYCHAIN" 2>/dev/null \
    | awk -v want="\"labl\"<blob>=\"$CERT_NAME\"" '
        /^SHA-1 hash: / { hash = $3 }
        { line = $0; sub(/^[ \t]+/, "", line) }
        line == want && hash != "" { print hash; hash = "" }' \
    | sort -u
}

google_token_present() {
  security find-generic-password -s "$GOOGLE_SERVICE" >/dev/null 2>&1
}

# JSON and TOML surgery for the MCP entries, mirroring MCPClientConfig.remove: one key out,
# everything else kept, a copy of the old file beside it, and a file that does not parse left
# alone. `find FILE` prints the key Worklens is under (exit 1: none, 3: unreadable);
# `remove FILE KEY` takes it out and prints the backup's path.
MCP_PY='
import json, os, re, sys, tempfile, time

def backup(path, raw):
    candidate = path + ".worklens-" + time.strftime("%Y%m%d-%H%M%S") + ".bak"
    if not os.path.exists(candidate):
        fd = os.open(candidate, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "wb") as f:
            f.write(raw)
    return candidate

def write(path, text):
    mode = os.stat(path).st_mode & 0o7777
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".worklens-uninstall-")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(text)
        os.chmod(tmp, mode)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise

def json_key(obj):
    servers = obj.get("mcpServers") if isinstance(obj, dict) else None
    if not isinstance(servers, dict):
        return None
    if "worklens" in servers:
        return "worklens"
    for key in sorted(servers):
        entry = servers[key]
        if isinstance(entry, dict) and str(entry.get("command", "")).endswith("/Worklens"):
            return key
    return None

TABLE = re.compile(r"^\s*\[(?!\[)(.*)\]\s*(#.*)?$")
ARRAY = re.compile(r"^\s*\[\[(.*)\]\]\s*(#.*)?$")
PART = re.compile(r"\s*(\"(?:[^\"\\\\]|\\\\.)*\"|\x27[^\x27]*\x27|[A-Za-z0-9_-]+)\s*(\.|$)")
COMMAND = re.compile(r"^\s*command\s*=\s*([\"\x27])(.*)\1\s*(#.*)?$")

def keyparts(raw):
    parts, pos = [], 0
    while pos < len(raw):
        p = PART.match(raw, pos)
        if not p or p.end() == pos:
            return None
        parts.append(p.group(1).strip("\"\x27"))
        pos = p.end()
    return parts

def opens(line):
    # The delimiter of a multi-line string this line opens and does not close.
    found = [(line.find(d), d) for d in ("\"\"\"", "\x27\x27\x27") if line.count(d) % 2 == 1]
    return min(found)[1] if found else None

def scan(lines):
    # Each line with the table header it is, or None. A line inside a multi-line string is
    # never a header, and an [[array]] header ends a table like any other.
    delim = None
    for line in lines:
        if delim:
            if line.count(delim) % 2 == 1:
                delim = None
            yield line, None
            continue
        m = ARRAY.match(line) or TABLE.match(line)
        parts = keyparts(m.group(1)) if m else None
        if parts is None:
            delim = opens(line)
        yield line, parts

def toml_key(lines):
    current, renamed = None, []
    for line, parts in scan(lines):
        if parts is not None:
            current = parts
            if parts[:2] == ["mcp_servers", "worklens"]:
                return "worklens"
            continue
        m = COMMAND.match(line)
        if m and current and len(current) == 2 and current[0] == "mcp_servers" and m.group(2).endswith("/Worklens"):
            renamed.append(current[1])
    return sorted(renamed)[0] if renamed else None

def toml_remove(lines, key):
    kept, owned, removed = [], False, False
    for line, parts in scan(lines):
        if parts is not None:
            owned = len(parts) >= 2 and parts[0] == "mcp_servers" and parts[1] == key
        if owned:
            removed = True
        else:
            kept.append(line)
    while kept and not kept[-1].strip():
        kept.pop()
    return ("".join(kept).rstrip("\n") + "\n") if removed else None

try:
    import tomllib
except ImportError:
    tomllib = None

def toml_checked(before_text, after_text, key):
    # Where this Python can read TOML, the new file must be the old one minus that server.
    if tomllib is None:
        return True
    try:
        before, after = tomllib.loads(before_text), tomllib.loads(after_text)
    except Exception:
        return False
    servers = before.get("mcp_servers")
    if not isinstance(servers, dict) or key not in servers:
        return False
    del servers[key]
    if not servers and "mcp_servers" not in after:
        del before["mcp_servers"]
    return before == after

# The format comes from the name the client uses; the edit goes to the file it points at, which
# must be inside the home folder.
mode, given = sys.argv[1], sys.argv[2]
toml = given.endswith(".toml")
path = os.path.realpath(given)
home = os.path.realpath(os.environ.get("HOME", "/"))
if home == "/" or not path.startswith(home + os.sep):
    sys.exit(5)
try:
    with open(path, "rb") as f:
        raw = f.read()
    source = raw.decode("utf-8")
except OSError:
    sys.exit(1)
except UnicodeDecodeError:
    sys.exit(3)
if toml:
    if tomllib is not None:
        try:
            tomllib.loads(source)
        except Exception:
            sys.exit(3)
    lines = source.splitlines(True)
    key = toml_key(lines)
else:
    try:
        obj = json.loads(source)
    except ValueError:
        sys.exit(3)
    key = json_key(obj)
if mode == "find":
    if key is None:
        sys.exit(1)
    print(key)
    sys.exit(0)
key = sys.argv[3]
if toml:
    text = toml_remove(lines, key)
    if text is None or not toml_checked(source, text, key):
        sys.exit(4)
else:
    servers = obj.get("mcpServers") if isinstance(obj, dict) else None
    if not isinstance(servers, dict) or key not in servers:
        sys.exit(1)
    del servers[key]
    text = json.dumps(obj, indent=2, ensure_ascii=False) + "\n"
print(backup(path, raw))
write(path, text)
'

PYTHON=""
# /usr/bin/python3 without the command line tools raises an install dialog instead of running.
if xcode-select -p >/dev/null 2>&1 || [[ "$(command -v python3 2>/dev/null || true)" != /usr/bin/python3 ]]; then
  PYTHON="$(command -v python3 2>/dev/null || true)"
fi

mcp_key() {
  [[ -f "$1" && -n "$PYTHON" ]] || return 1
  "$PYTHON" -I -c "$MCP_PY" find "$1" 2>/dev/null
}

# ------------------------------------------------------------------ 1. look

echo "${BOLD}Worklens uninstall${PLAIN}"
if (( DRY_RUN )); then echo "${DIM}dry run: nothing will be quit, removed or deleted${PLAIN}"; fi

step "Looking for Worklens on this Mac"

APPS=()
for dir in "${APP_DIRS[@]}"; do
  candidate="${dir%/}/Worklens.app"
  is_worklens_app "$candidate" || continue
  case " ${APPS[*]-} " in *" $candidate "*) continue ;; esac
  APPS+=("$candidate")
done

LINKS=()
for dir in "${BIN_DIRS[@]}"; do
  link="${dir%/}/worklens"
  [[ -L "$link" ]] || continue
  target="$(readlink "$link" || true)"
  if [[ "$target" == */Worklens.app/Contents/MacOS/Worklens ]]; then
    case " ${LINKS[*]-} " in *" $link "*) continue ;; esac
    LINKS+=("$link")
  else
    detail "$link points at $target, not at a Worklens.app, so it stays"
  fi
done

RUNNING=0
app_running && RUNNING=1

CERTS=()
while IFS= read -r hash; do
  [[ -n "$hash" ]] && CERTS+=("$hash")
done < <(cert_hashes)

GOOGLE=0
google_token_present && GOOGLE=1

# Which MCP client files carry a Worklens entry, and under which key.
MCP_FILES=(); MCP_KEYS=(); MCP_NAMES=()
add_mcp() {
  local key status=0
  key="$(mcp_key "$2")" || status=$?
  if (( status == 0 )) && [[ -n "$key" ]]; then
    MCP_NAMES+=("$1"); MCP_FILES+=("$2"); MCP_KEYS+=("$key")
  elif (( status == 3 )); then
    detail "$2 does not parse, so it is left as it is; take any worklens entry out by hand"
  elif (( status == 5 )); then
    detail "$2 is a link to a file outside your home folder, so it is left as it is"
  fi
}
if [[ -z "$PYTHON" ]]; then
  for f in "$CLAUDE_DESKTOP_CONFIG" "$CLAUDE_CODE_CONFIG" "$CODEX_CONFIG"; do
    if [[ -f "$f" ]] && grep -q 'Worklens' "$f" 2>/dev/null; then
      left "Take the worklens entry out of $f by hand: this Mac has no python3 to do it safely."
    fi
  done
else
  add_mcp "Claude Desktop" "$CLAUDE_DESKTOP_CONFIG"
  add_mcp "Claude Code" "$CLAUDE_CODE_CONFIG"
  add_mcp "Codex" "$CODEX_CONFIG"
fi
CLAUDE_DESKTOP_OPEN=0
# -a: this script may itself be running under Claude Desktop, and BSD pgrep skips its ancestors.
pgrep -a -x Claude >/dev/null 2>&1 && CLAUDE_DESKTOP_OPEN=1

PREFS=()
for domain in "$BUNDLE_ID" Worklens; do
  [[ -f "$HOME/Library/Preferences/$domain.plist" ]] && PREFS+=("$domain")
done
# Every folder the app may keep data in, as real paths. The installed app reads $SUPPORT/.env; a
# relaunch may have pointed it at another file, which $SUPPORT/.launch-env records; a checkout's
# own .env and this shell's DATA_DIR or WORKLENS_ENV_FILE count too. Nothing below removes a
# path that is one of these folders, is inside one, or holds one, unless it is your data being
# deleted on your answer.
DATA_DIRS=()
add_data_dir() {
  local dir
  dir="$(resolve_dir "$1" "$2")"
  if [[ -n "$dir" ]]; then DATA_DIRS+=("$(physical "$dir")"); fi
}
add_env_file() {
  [[ -n "$1" && "$1" == /* && -f "$1" ]] || return 0
  add_data_dir "$(env_data_dir "$1")" "${1%/*}"
}
launch_env_file() {
  local line
  [[ -f "$SUPPORT/.launch-env" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="$(trim "$line")"
    [[ -z "$line" || "$line" == \#* ]] && continue
    printf '%s' "$line"; return 0
  done < "$SUPPORT/.launch-env"
}
add_data_dir "$SUPPORT/data" "$SUPPORT"
add_env_file "$SUPPORT/.env"
add_env_file "$(launch_env_file)"
add_env_file "${WORKLENS_ENV_FILE:-}"
add_env_file "$SRC/.env"
if [[ "${DATA_DIR:-}" == /* || "${DATA_DIR:-}" == "~"* ]]; then add_data_dir "$DATA_DIR" "$HOME"; fi

holds_data() {
  local real d
  real="$(physical "$1")"
  for d in "${DATA_DIRS[@]}"; do
    if inside "$d" "$real" || inside "$real" "$d"; then return 0; fi
  done
  return 1
}

CACHES=()
for path in "$HOME/Library/Caches/$BUNDLE_ID" "$HOME/Library/HTTPStorages/$BUNDLE_ID" \
    "$HOME/Library/HTTPStorages/$BUNDLE_ID.binarycookies" "$HOME/Library/WebKit/$BUNDLE_ID" \
    "$HOME/Library/Saved Application State/$BUNDLE_ID.savedState"; do
  [[ -e "$path" || -L "$path" ]] || continue
  if holds_data "$path"; then
    detail "$path holds a data folder, so it stays"
  else
    CACHES+=("$path")
  fi
done
KEEP_APPS=()
for app in ${APPS[@]+"${APPS[@]}"}; do
  if holds_data "$app"; then detail "$app holds a data folder, so it stays"; else KEEP_APPS+=("$app"); fi
done
APPS=(${KEEP_APPS[@]+"${KEEP_APPS[@]}"})

# The Worklens folder itself must be a real folder inside your home folder before anything in it
# is deleted; a link to somewhere else is named and left alone.
SUPPORT_REAL="$(physical "$SUPPORT")"
SUPPORT_ODD=0
if [[ -L "$SUPPORT" ]] || ! inside "$SUPPORT_REAL" "$HOME"; then SUPPORT_ODD=1; fi
HAVE_DATA=0
[[ -d "$SUPPORT" ]] && [[ -n "$(find "$SUPPORT/" -mindepth 1 -maxdepth 1 ! -name src ! -name .DS_Store -print -quit 2>/dev/null)" ]] && HAVE_DATA=1
DATA_OUTSIDE=()
for d in "${DATA_DIRS[@]}"; do
  [[ -d "$d" ]] || continue
  inside "$d" "$SUPPORT_REAL" && continue
  case " ${DATA_OUTSIDE[*]-} " in *" $d "*) continue ;; esac
  DATA_OUTSIDE+=("$d")
done

# The source checkout bootstrap made. Kept when something in it is yours: a data folder or a .env
# (deleting your data deletes those too), or changes, ignored files, commits or a stash that are
# nowhere else (never deleted here). Each is checked on its own.
SOURCE=0; SOURCE_DATA=""; SOURCE_KEEP=""
if [[ -e "$SRC" || -L "$SRC" ]]; then
  SOURCE=1
  if [[ -L "$SRC" ]] || (( SUPPORT_ODD )); then
    SOURCE_KEEP="it is a link to a folder somewhere else"
  elif [[ ! -d "$SRC/.git" || ! -f "$SRC/Package.swift" ]]; then
    SOURCE_KEEP="it is not a Worklens checkout"
  else
    if holds_data "$SRC" || [[ -e "$SRC/.env" || -e "$SRC/data" ]]; then
      SOURCE_DATA="your data or a .env is inside it"
    fi
    # Only what a build leaves behind may be ignored; .env and data/ are the data reason above.
    own=""
    if status="$(git -C "$SRC" status --porcelain --ignored 2>/dev/null)"; then
      own="$(printf '%s\n' "$status" \
        | grep -vE '^(!! (\.build/|build/|\.swiftpm/|\.env|data/|(.*/)?\.DS_Store))?$' | head -1 || true)"
    else
      status="unreadable"
    fi
    if [[ "$status" == unreadable ]]; then
      SOURCE_KEEP="git cannot read it"
    elif [[ -n "$own" ]]; then
      SOURCE_KEEP="it has changes or files of your own that are not on GitHub (${own:3})"
    elif ! log="$(git -C "$SRC" log HEAD --branches --not --remotes --oneline 2>/dev/null)"; then
      SOURCE_KEEP="git cannot read its history"
    elif [[ -n "$log" || -n "$(git -C "$SRC" stash list 2>/dev/null | head -1)" ]]; then
      SOURCE_KEEP="it has commits or a stash that are not on GitHub"
    fi
  fi
fi
# Whether the checkout goes: nothing of yours in it, or only data you have said to delete.
source_goes() { (( SOURCE )) && [[ -z "$SOURCE_KEEP" ]] && { [[ -z "$SOURCE_DATA" ]] || (( DELETE_DATA )); }; }
source_reason() { printf '%s' "${SOURCE_KEEP:-$SOURCE_DATA}"; }

# A Worklens folder that is a link elsewhere is never deleted from here, even when asked.
if (( SUPPORT_ODD )) && [[ -e "$SUPPORT" ]]; then
  detail "$SUPPORT is a link to $SUPPORT_REAL, so nothing in it is deleted"
  if (( DELETE_DATA )); then left "Your data is in $SUPPORT_REAL. Delete that folder yourself if you want it gone."; fi
  DELETE_DATA=0
  HAVE_DATA=0
fi

# ------------------------------------------------------------------ 2. the list, and one yes

step "What this will remove"
found=0
item() { echo "  • $*"; found=1; }
(( RUNNING )) && item "quit the running Worklens"
for i in ${MCP_NAMES[@]+"${!MCP_NAMES[@]}"}; do
  if [[ "${MCP_NAMES[$i]}" == "Claude Desktop" ]] && (( CLAUDE_DESKTOP_OPEN )); then
    item "the \"${MCP_KEYS[$i]}\" server in Claude Desktop's settings, once you quit Claude Desktop"
  else
    item "the \"${MCP_KEYS[$i]}\" server in ${MCP_NAMES[$i]}'s settings (your other servers stay)"
  fi
done
(( ${#APPS[@]} )) && item "the Screen Recording, Accessibility and Automation answers macOS keeps for Worklens"
(( GOOGLE )) && item "the Google Calendar token in your keychain"
(( ${#CERTS[@]} )) && item "the \"$CERT_NAME\" signing certificate, its key and its trust setting"
for app in ${APPS[@]+"${APPS[@]}"}; do item "$app"; done
(( ${#PREFS[@]} + ${#CACHES[@]} )) && item "the app's preferences and caches in ~/Library"
for link in ${LINKS[@]+"${LINKS[@]}"}; do item "the worklens command at $link"; done
if source_goes; then item "the source at $SRC"; fi
if (( HAVE_DATA && DELETE_DATA )); then
  item "${BOLD}your data${PLAIN}: everything in $SUPPORT, including the database, the screenshots and the .env with your key"
fi

if (( SOURCE )) && ! source_goes; then
  detail "keeping $SRC: $(source_reason)"
fi
if (( HAVE_DATA && ! DELETE_DATA )); then
  detail "keeping your data in $SUPPORT: the database, screenshots, settings and the .env with your key"
fi
for d in ${DATA_OUTSIDE[@]+"${DATA_OUTSIDE[@]}"}; do
  detail "keeping $d, a data folder outside $SUPPORT: this never deletes one"
done
detail "Nothing here uses sudo. A checkout of your own somewhere else is left alone."

if (( ! found )) && ! (( HAVE_DATA && DELETE_DATA )); then
  echo
  if (( HAVE_DATA )); then
    echo "Worklens is already removed; only your data is left, in $SUPPORT."
    echo "Run this again with --delete-data to delete it as well."
  else
    echo "Worklens is not on this Mac: there is nothing to remove."
  fi
  exit 0
fi

if (( ${#CERTS[@]} )) && (( ! DRY_RUN )); then
  detail "macOS may ask for your password to take the certificate's trust setting out. That dialog is"
  detail "yours to answer; Cancel keeps the certificate and the rest carries on."
fi

if (( DRY_RUN )); then
  echo "    Remove these? [y/N] y (dry run)"
elif (( ASSUME_YES )); then
  echo "Remove these? [y/N] y (--yes)"
else
  reply=""
  read -r -p "Remove these? [y/N] " reply || reply=""
  [[ "$reply" == [Yy]* ]] || { echo "Nothing was changed."; exit 0; }
fi

# The data gets its own answer, asked now so every question comes before the first change. Only
# the word `delete` deletes it; a y, a Return or no terminal at all keeps it.
if (( HAVE_DATA )) && ! (( DELETE_DATA || DRY_RUN || ASSUME_YES )); then
  step "Your data"
  size="$(du -sh "$SUPPORT" 2>/dev/null | cut -f1 || true)"
  cat <<EOF
    $SUPPORT${size:+ ($size)} holds your database, your screenshots, your
    settings and the .env with your Gemini key. There is no other copy, and this keeps it
    unless you say otherwise.
EOF
  reply=""
  read -r -p "    Type delete to delete it too, or press Return to keep it: " reply || reply=""
  if [[ "$reply" == "delete" ]]; then
    DELETE_DATA=1
    detail "your data will be deleted last"
  else
    detail "kept"
  fi
fi

# ------------------------------------------------------------------ 3. the removals

FAILED=0
failed() { FAILED=$((FAILED + 1)); echo "    $*" >&2; }

if (( RUNNING )); then
  step "Quitting Worklens"
  run pkill -a -f "$APP_PATTERN" || true
  if (( ! DRY_RUN )); then
    for _ in $(seq 1 100); do app_running || break; sleep 0.1; done
    if app_running; then
      die "Worklens is still running after 10 seconds. Quit it from the menu bar, then run this again. Nothing else was changed."
    fi
    detail "quit"
  fi
fi

if (( ${#MCP_NAMES[@]} )); then
  step "MCP settings"
  for i in "${!MCP_NAMES[@]}"; do
    name="${MCP_NAMES[$i]}"; file="${MCP_FILES[$i]}"; key="${MCP_KEYS[$i]}"
    if [[ "$name" == "Claude Desktop" ]] && (( CLAUDE_DESKTOP_OPEN )); then
      detail "Claude Desktop is open, and it puts its old settings back while it runs: left as it is"
      left "Quit Claude Desktop, then run this again in Terminal to take Worklens out of its settings. (Quitting it ends any session running inside it, this one included.)"
      continue
    fi
    if (( DRY_RUN )); then
      detail "would take \"$key\" out of $file and keep a copy of the old file beside it"
      left "Reopen $name, so it stops starting the Worklens server."
      continue
    fi
    if backup="$("$PYTHON" -I -c "$MCP_PY" remove "$file" "$key")"; then
      detail "took \"$key\" out of $file"
      detail "the old file is at $backup"
      left "Reopen $name, so it stops starting the Worklens server."
    else
      failed "could not take \"$key\" out of $file: remove that entry by hand"
    fi
  done
fi

if (( ${#APPS[@]} )); then
  step "Privacy answers"
  # tccutil resets this user's answers for one bundle and needs no sudo. It looks the bundle up
  # by identifier, so it runs while the app is still installed.
  for service in ScreenCapture Accessibility AppleEvents; do
    if run tccutil reset "$service" "$BUNDLE_ID" >/dev/null 2>&1; then
      (( DRY_RUN )) || detail "reset $service"
    else
      failed "macOS did not reset $service: remove Worklens in System Settings, Privacy & Security"
    fi
  done
fi

if (( GOOGLE )); then
  step "Google Calendar token"
  if (( DRY_RUN )); then
    run security delete-generic-password -s "$GOOGLE_SERVICE"
  else
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      security delete-generic-password -s "$GOOGLE_SERVICE" >/dev/null 2>&1 || break
    done
    if google_token_present; then
      failed "a Google token is still in your keychain: delete \"$GOOGLE_SERVICE\" in Keychain Access"
    else
      detail "deleted from your keychain"
    fi
  fi
  left "Check https://myaccount.google.com/permissions and remove Worklens there if it is listed."
fi

if (( ${#CERTS[@]} )); then
  step "Signing certificate"
  for hash in "${CERTS[@]}"; do
    # -t takes the user trust setting `make dev-cert` added with it.
    if run security delete-identity -Z "$hash" -t "$KEYCHAIN" >/dev/null 2>&1 \
        || run security delete-certificate -Z "$hash" -t "$KEYCHAIN" >/dev/null 2>&1; then
      (( DRY_RUN )) || detail "removed \"$CERT_NAME\" ($hash)"
    else
      failed "\"$CERT_NAME\" is still in your login keychain: delete it in Keychain Access"
    fi
  done
fi

if (( ${#APPS[@]} )); then
  step "The app"
  for app in "${APPS[@]}"; do
    # Unregistered first, so a dead copy cannot keep its icon or its name in Launch Services.
    [[ -x "$LSREGISTER" ]] && { run "$LSREGISTER" -u "$app" >/dev/null 2>&1 || true; }
    if run rm -rf "$app"; then
      (( DRY_RUN )) || detail "removed $app"
    else
      failed "could not remove $app: drag it to the Trash"
    fi
  done
  left "Look in System Settings, General, Login Items: if Worklens is still listed, remove it."
fi

if (( ${#PREFS[@]} + ${#CACHES[@]} )); then
  step "Preferences and caches"
  for domain in ${PREFS[@]+"${PREFS[@]}"}; do
    run defaults delete "$domain" >/dev/null 2>&1 || true
    (( DRY_RUN )) || detail "removed the $domain preferences"
  done
  for path in ${CACHES[@]+"${CACHES[@]}"}; do
    run rm -rf "$path"
    (( DRY_RUN )) || detail "removed $path"
  done
fi

if (( ${#LINKS[@]} )); then
  step "The worklens command"
  for link in "${LINKS[@]}"; do
    if run rm -f "$link"; then
      (( DRY_RUN )) || detail "removed $link"
    else
      failed "could not remove $link"
    fi
  done
fi

if source_goes && ! (( DELETE_DATA )); then
  step "The source"
  run rm -rf "$SRC"
  (( DRY_RUN )) || detail "removed $SRC"
fi

# ------------------------------------------------------------------ 4. your data

if (( DELETE_DATA )) && [[ -d "$SUPPORT" ]]; then
  step "Deleting your data"
  if (( SOURCE )) && ! source_goes; then
    # The checkout stays, so everything beside it goes and it does not.
    while IFS= read -r -d '' entry; do
      run rm -rf "$entry"
    done < <(find "$SUPPORT" -mindepth 1 -maxdepth 1 ! -name src -print0)
    (( DRY_RUN )) || detail "deleted everything in $SUPPORT except src"
  else
    run rm -rf "$SUPPORT"
    (( DRY_RUN )) || detail "deleted $SUPPORT"
  fi
  left "Delete your Gemini key at https://aistudio.google.com/apikey if nothing else uses it."
elif (( HAVE_DATA )); then
  left "Your data stays in $SUPPORT. Delete that folder when you no longer want it, or run this again with --delete-data."
fi
for d in ${DATA_OUTSIDE[@]+"${DATA_OUTSIDE[@]}"}; do
  left "The data folder $d is outside $SUPPORT and stays. Delete it yourself if you want it gone."
done

# ------------------------------------------------------------------ 5. what is left for you

step "What is left for you"
if (( ${#LEFT[@]} )); then
  for line in "${LEFT[@]}"; do echo "    • $line"; done
else
  echo "    Nothing."
fi

echo
if (( DRY_RUN )); then
  echo "${BOLD}Done.${PLAIN} ${DIM}(dry run: nothing above actually happened)${PLAIN}"
elif (( FAILED )); then
  echo "${BOLD}Done, with $FAILED step(s) to finish by hand${PLAIN} (named above). Running this again is safe."
else
  echo "${BOLD}Done.${PLAIN} Worklens is removed from this Mac."
fi
exit 0
