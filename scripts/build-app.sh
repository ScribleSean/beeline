#!/bin/bash
# Builds build/Beeline.app from the Swift package and signs it.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build

# One build at a time: two runs sharing build/ could each delete the other's half-built bundle. The lock
# is a folder, made in one step; one older than an hour is left over from a run that died.
lock="build/.build-lock"
if ! mkdir "$lock" 2>/dev/null; then
    if [ -n "$(find "$lock" -maxdepth 0 -mmin +60 2>/dev/null)" ]; then
        rmdir "$lock" && mkdir "$lock"
    else
        echo "Another build is already running (remove $lock if it is not)." >&2
        exit 1
    fi
fi
trap 'rmdir "$lock" 2>/dev/null || true' EXIT

swift build -c release
# Built in a folder of its own and swapped in at the end. The app it replaces is kept as
# Beeline.app.previous until the next build, so a new build that will not start can be put back by hand.
final="build/Beeline.app"
app="$(mktemp -d build/Beeline.new.XXXXXX)"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp ".build/release/Beeline" "$app/Contents/MacOS/Beeline"
cp "Resources/Info.plist" "$app/Contents/Info.plist"
cp "Resources/AppIcon.icns" "$app/Contents/Resources/AppIcon.icns"
cp "Resources/MenuBarGlyph.png" "$app/Contents/Resources/MenuBarGlyph.png"
# The menu bar's Update item rebuilds from this folder, and compares this commit with the newest
# one to decide whether there is anything to update. Uncommitted edits always count as newer;
# untracked files (Xcode's .swiftpm, say) do not.
commit="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
[ -n "$(git status --porcelain --untracked-files=no 2>/dev/null)" ] && commit="$commit-dirty"
# plutil takes the values as arguments, so a path with a quote or a backslash in it is stored as it is.
plutil -insert BeelineSourceRoot -string "$PWD" "$app/Contents/Info.plist"
plutil -insert BeelineCommit -string "$commit" "$app/Contents/Info.plist"
# A stable identity keeps macOS permissions across rebuilds. It comes from
# BEELINE_SIGNING_IDENTITY, else the untracked .signing-identity file, else ad hoc. A git worktree has no
# copy of that untracked file, so it falls back to the one in the main checkout.
main_checkout="$(cd "$(git rev-parse --git-common-dir 2>/dev/null || echo .)/.." 2>/dev/null && pwd)"
identity_file=".signing-identity"
[ -f "$identity_file" ] || identity_file="$main_checkout/.signing-identity"
identity="${BEELINE_SIGNING_IDENTITY:-$(cat "$identity_file" 2>/dev/null || echo -)}"
if [ "$identity" = "-" ]; then
    echo "warning: signing ad hoc. Each ad hoc build is a new app to macOS, so Accessibility and the other" >&2
    echo "permissions stop working after it: remove Beeline from each list and add it again, or put a" >&2
    echo "certificate name in .signing-identity (see README)." >&2
fi
codesign --force --sign "$identity" "$app"
# Only Beeline's own build output is ever removed here.
rm -rf "$final.previous"
[ -d "$final" ] && mv "$final" "$final.previous"
mv "$app" "$final"
echo "$final"
