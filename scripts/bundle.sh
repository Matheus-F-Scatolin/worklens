#!/usr/bin/env bash
# Assembles build/Worklens.app from the release binary. Run `make build` first.
set -euo pipefail

cd "$(dirname "$0")/.."

BIN=".build/release/Worklens"
APP="build/Worklens.app"

if [[ ! -x "$BIN" ]]; then
  echo "error: $BIN not found — run 'make build' first" >&2
  exit 1
fi

# The icon `Info.plist`'s CFBundleIconFile names. Checked in, so a fresh clone bundles an icon
# without running `make icon`; `scripts/render-icon.sh` regenerates it from WorklensMark.swift.
#
# Missing used to be a warning, on the grounds that an app with a placeholder icon still runs.
# It does, but the damage outlives the bundle: Notification Center caches an app's icon per
# *bundle identifier* and holds it for the life of that daemon, so one launch of an icon-less
# `dev.worklens.app` leaves every Worklens banner drawing a blank white tile — on every later
# build, however correct its icon — until the user restarts NotificationCenter. The Finder and
# System Settings keep showing the real icon throughout, so nothing points at the cause.
#
# Checked here, beside the binary and before anything is deleted, because `update.sh` calls this
# with the app already quit: a script that bailed halfway would leave nothing to relaunch.
if [[ ! -f Resources/AppIcon.icns ]]; then
  echo "error: Resources/AppIcon.icns not found — run 'make icon'" >&2
  exit 1
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/Worklens"
cp Resources/Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# #161: the localization catalogs, copied whole. They have to land *before* scripts/sign.sh runs
# — a resource added after signing invalidates the signature, and the app then refuses to launch
# on a Mac with Gatekeeper's usual settings. `CFBundleDevelopmentRegion` in Info.plist says which
# of these is the development language; everything else is a translation, and a missing key falls
# back to the English sentence the code passes as `L10n.string(_:value:)`'s value.
shopt -s nullglob
for lproj in Resources/*.lproj; do
  cp -R "$lproj" "$APP/Contents/Resources/"
done
shopt -u nullglob

# #153: the documents the app links to, carried inside the bundle under the same repo-relative
# paths the enum in `HelpDoc` spells. An installed Worklens has no checkout beside it — and
# `Config.currentDirectory` is `/` for a Finder launch — so without these the privacy document,
# the troubleshooting page and every "Learn more" resolved to a github.com URL on a repository
# that is private. README.md comes along because docs/user/index.md links sideways to it and to
# PRIVACY.md; keeping the directories is what keeps those relative links working offline.
cp PRIVACY.md README.md "$APP/Contents/Resources/"
mkdir -p "$APP/Contents/Resources/docs"
cp -R docs/user "$APP/Contents/Resources/docs/user"

# Stamp what this bundle was built from into its own Info.plist, read back by
# `BuildStamp`: Settings' **This build** line, `worklens version`, and the auto-updater's "am I
# behind origin/main?". The bundle has to carry it, because the checkout's HEAD moves on the
# moment you pull and the question is which commit is *running*.
#
# plutil rather than PlistBuddy: the value arrives as its own argument, so a commit subject with
# quotes or semicolons in it cannot be misread as more of the command. Stamping happens before
# sign.sh, which is the only order the signature stays valid in.
PLIST="$APP/Contents/Info.plist"
plutil -replace WLBuildDate -string "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$PLIST"

# The version this bundle reports (#130), derived from the tag rather than hand-edited. The
# checked-in Info.plist values stay as the fallback for a tree with no tag and for a build made
# outside a git checkout, and `WorklensVersion.fallback` holds the same pair on the Swift side.
#
# `--abbrev=0` on purpose: the bare `git describe` form (`v0.1.0-12-g9772c6a`, and `--dirty`
# worse still) is not a valid CFBundleShortVersionString, which has to be one to three
# dot-separated integers or Finder, `mdls` and every installer misread it. The commit count is
# the build number: it is the only thing about this history that is guaranteed to go up.
# The regex is belt and braces — an annotated tag named `v2.0-rc1` would otherwise land in a key
# that cannot hold it.
if tag=$(git describe --tags --match 'v*' --abbrev=0 2>/dev/null) && [[ -n "$tag" ]]; then
  version="${tag#v}"
  if [[ "$version" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]]; then
    plutil -replace CFBundleShortVersionString -string "$version" "$PLIST"
  else
    echo "warning: tag '$tag' is not 1-3 dot-separated integers; keeping the Info.plist version" >&2
  fi
fi
if count=$(git rev-list --count HEAD 2>/dev/null) && [[ -n "$count" ]]; then
  plutil -replace CFBundleVersion -string "$count" "$PLIST"
fi

# Where this bundle was built, so a copy of it can find its way home (#119). `make install`
# dittos the bundle to /Applications, and the app used to locate its own checkout by looking two
# directories up from itself — true only while it sits in <repo>/build/, so installing it turned
# "Update and restart…" off without saying so. Stamped here rather than adjusted afterwards:
# the signature seals Info.plist, so anything written to the installed copy would invalidate it.
plutil -replace WLRepoPath -string "$PWD" "$PLIST"

# A tarball or a bundle built outside a checkout has no git to ask; the app copes with an
# unstamped build and says so, so this is not worth failing over.
if commit=$(git rev-parse HEAD 2>/dev/null); then
  subject=$(git log -1 --pretty=%s)
  merge_re='^Merge pull request #([0-9]+)'
  trailer_re='\(#([0-9]+)\)$'
  pr=""
  title="$subject"
  # On main every commit is a merge of one pull request, and the sentence a person recognises is
  # the merged branch's subject (the second parent), not "Merge pull request #105 from …".
  # A commit that landed directly still names its issue in a `(#95)` trailer.
  if [[ "$subject" =~ $merge_re ]]; then
    pr="${BASH_REMATCH[1]}"
    title=$(git log -1 --pretty=%s 'HEAD^2' 2>/dev/null || echo "$subject")
  elif [[ "$subject" =~ $trailer_re ]]; then
    pr="${BASH_REMATCH[1]}"
  fi
  dirty=false
  [[ -n "$(git status --porcelain)" ]] && dirty=true

  # Where this bundle came from, so the menu's privacy item can open *this* repository's
  # PRIVACY.md instead of a URL compiled into the binary. An ssh remote normalises to its https
  # form; a checkout with no `origin` just gets no key and the app falls back to its constant.
  if remote=$(git remote get-url origin 2>/dev/null) && [[ -n "$remote" ]]; then
    remote=$(printf '%s' "$remote" \
      | sed -E 's#^ssh://git@#https://#; s#^git@([^:]+):#https://\1/#; s#/+$##; s#\.git$##')
    plutil -replace WLRepositoryURL -string "$remote" "$PLIST"
  fi

  plutil -replace WLCommit -string "$commit" "$PLIST"
  plutil -replace WLCommitShort -string "$(git rev-parse --short HEAD)" "$PLIST"
  plutil -replace WLCommitSubject -string "$title" "$PLIST"
  plutil -replace WLDirty -string "$dirty" "$PLIST"
  [[ -n "$pr" ]] && plutil -replace WLPullRequest -string "$pr" "$PLIST"
  echo "stamped ${pr:+#$pr }$(git rev-parse --short HEAD)$([[ $dirty == true ]] && echo '+')"
fi

# SPM resource bundles, if any target ever grows one. Harmless when there are none.
shopt -s nullglob
for bundle in .build/release/*.bundle; do
  cp -R "$bundle" "$APP/Contents/Resources/"
done
shopt -u nullglob

bundled_version=$(plutil -extract CFBundleShortVersionString raw -o - "$PLIST")
bundled_build=$(plutil -extract CFBundleVersion raw -o - "$PLIST")
echo "bundled $APP $bundled_version ($bundled_build) ($(du -sh "$APP" | cut -f1))"
