#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
cache_root="${VOICECONTROL_BUILD_ROOT:-$HOME/Library/Caches/VoiceControlPrototype}"
swift build -c debug --scratch-path "$cache_root/swift"
binary_dir="$(swift build -c debug --scratch-path "$cache_root/swift" --show-bin-path)"
bundle="$cache_root/Voice Control.app"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
cp "$binary_dir/VoiceControl" "$bundle/Contents/MacOS/VoiceControl"
cp Resources/Info.plist "$bundle/Contents/Info.plist"
codesign --force --sign - --identifier local.voicecontrol.prototype "$bundle"
printf '%s\n' "$bundle"
