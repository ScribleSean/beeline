#!/bin/bash
# Builds build/Beeline.app from the Swift package and signs it.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build

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
final="build/Beeline.app"
app="$(mktemp -d build/Beeline.new.XXXXXX)"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp ".build/release/Beeline" "$app/Contents/MacOS/Beeline"
cp "Resources/Info.plist" "$app/Contents/Info.plist"
cp "Resources/AppIcon.icns" "$app/Contents/Resources/AppIcon.icns"
cp "Resources/MenuBarGlyph.png" "$app/Contents/Resources/MenuBarGlyph.png"
commit="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
[ -n "$(git status --porcelain --untracked-files=no 2>/dev/null)" ] && commit="$commit-dirty"
plutil -insert BeelineSourceRoot -string "$PWD" "$app/Contents/Info.plist"
plutil -insert BeelineCommit -string "$commit" "$app/Contents/Info.plist"
# macOS ties Accessibility and the other permissions to the signing identity, so only a stable
# identity keeps them across rebuilds.
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
rm -rf "$final.previous"
[ -d "$final" ] && mv "$final" "$final.previous"
mv "$app" "$final"
echo "$final"
