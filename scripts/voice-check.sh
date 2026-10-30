#!/bin/bash
# Generate speech and check the real voice path, without a microphone or keyboard input.
# Usage: bash scripts/voice-check.sh "open TextEdit" [--expect "<action title>"] [--run] [--installed | --app /path/Beeline.app]
set -euo pipefail
cd "$(dirname "$0")/.."
[ $# -gt 0 ] || { echo "Usage: $0 <phrase> [--expect title] [--run] [--installed | --app path]" >&2; exit 2; }
phrase="$1"
shift
app="${BEELINE_APP:-$PWD/build/Beeline.app}"
run=0
expect=""
has_expect=0
while [ $# -gt 0 ]; do
    case "$1" in
        --expect) [ $# -ge 2 ] || exit 2; expect="$2"; has_expect=1; shift 2 ;;
        --run) run=1; shift ;;
        --installed) app="$HOME/Applications/Beeline.app"; shift ;;
        --app) [ $# -ge 2 ] || exit 2; app="$2"; shift 2 ;;
        *) echo "Unknown flag: $1" >&2; exit 2 ;;
    esac
done
[ -n "$phrase" ] || { echo "Phrase must not be empty." >&2; exit 2; }
[ -x "$app/Contents/MacOS/Beeline" ] || { echo "No built app at $app" >&2; exit 2; }
out="$(mktemp -d "${TMPDIR:-/tmp}/beeline-voice-check.XXXXXX")"
log="$out/voice.jsonl"
pid=""
cleanup() {
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then kill "$pid" 2>/dev/null || true; fi
    rm -f "$out/voice.aiff"
}
trap cleanup EXIT
say -o "$out/voice.aiff" -- "$phrase"
BEELINE_DEMO=voice BEELINE_VOICE_FILE="$out/voice.aiff" BEELINE_VOICE_RUN="$run" \
    BEELINE_DEMO_LOG="$log" "$app/Contents/MacOS/Beeline" > "$out/app.log" 2>&1 &
pid=$!
deadline=$((SECONDS + 85))
while kill -0 "$pid" 2>/dev/null && [ "$SECONDS" -lt "$deadline" ]; do
    if [ -f "$log" ] && grep -q '"event":"result"' "$log"; then break; fi
    sleep 0.2
done
field() { plutil -extract "$2" raw -o - - <<< "$1" 2>/dev/null || true; }
result=""
engine="(not started)"
transcript="(none)"
plan="(none)"
if [ -f "$log" ]; then
    while IFS= read -r line; do
        case "$(field "$line" event)" in
            voice-engine) engine="$(field "$line" engine)" ;;
            voice-final) transcript="$(field "$line" text)" ;;
            voice-plan) plan="$(field "$line" action)" ;;
            result) result="$line" ;;
        esac
    done < "$log"
fi
echo "Engine: $engine"
echo "Transcript: $transcript"
echo "Plan: $plan"
echo "Log: $log"
if [ ! -s "$log" ]; then echo "FAIL: Beeline never reached test mode (see $out/app.log)"; exit 1; fi
if [ -z "$result" ]; then echo "FAIL: no result before exit or timeout"; exit 1; fi
if [ "$has_expect" = 1 ] && [ "$plan" != "$expect" ]; then
    echo "FAIL: expected plan '$expect', got '$plan'"
    exit 1
fi
if [ "$(field "$result" pass)" = true ]; then
    echo "PASS: $(field "$result" why)"
else
    echo "FAIL: $(field "$result" why)"
    exit 1
fi
