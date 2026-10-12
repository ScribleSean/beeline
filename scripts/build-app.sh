#!/bin/bash
# Builds build/Beeline.app from the Swift package and signs it ad hoc.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
app="build/Beeline.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp ".build/release/Beeline" "$app/Contents/MacOS/Beeline"
cp "Resources/Info.plist" "$app/Contents/Info.plist"
cp "Resources/AppIcon.icns" "$app/Contents/Resources/AppIcon.icns"
# The menu bar's Update item rebuilds from this folder, and compares this commit with the newest
# one to decide whether there is anything to update. Uncommitted edits always count as newer.
commit="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
[ -n "$(git status --porcelain 2>/dev/null)" ] && commit="$commit-dirty"
/usr/libexec/PlistBuddy -c "Add :BeelineSourceRoot string $(pwd)" -c "Add :BeelineCommit string $commit" "$app/Contents/Info.plist"
# A stable identity keeps macOS permissions across rebuilds. It comes from
# BEELINE_SIGNING_IDENTITY, else the untracked .signing-identity file, else ad hoc.
identity="${BEELINE_SIGNING_IDENTITY:-$(cat .signing-identity 2>/dev/null || echo -)}"
codesign --force --sign "$identity" "$app"
echo "$app"
