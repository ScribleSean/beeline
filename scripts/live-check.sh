#!/bin/bash
# Hands-free live check of the bee, the stop keys, the welcome card, the shortcut, rewriting, browser tabs
# and the permissions a signed build needs (mic audio, speech, Reminders, Accessibility, Automation).
#
#   bash scripts/live-check.sh                 # every scenario
#   bash scripts/live-check.sh press escape    # some of them
#
# Beeline works in a throwaway TextEdit document, and `tab` in a Safari window it opens and closes itself
# (Safari must be open; Beeline needs Automation for Safari). `rewrite` asks Claude, so it needs Claude Code
# signed in; it puts your clipboard back when it ends. Keep your hands off the keyboard and mouse while it
# runs: a click or a key stops a run.
#
# Needs: Beeline built with this live-check mode, at ~/Applications/Beeline.app (or BEELINE_APP), with
# Accessibility allowed; and Screen Recording allowed for the terminal, for the screenshots.
set -uo pipefail

app="${BEELINE_APP:-$HOME/Applications/Beeline.app}"
[ -d "$app" ] || { echo "No Beeline at $app (set BEELINE_APP)." >&2; exit 2; }
known=" press plan escape click welcome release open rewrite tab permissions "
if [ $# -gt 0 ]; then scenarios=("$@"); else scenarios=(press plan escape click welcome release open rewrite tab permissions); fi
for scenario in "${scenarios[@]}"; do
    case "$known" in *" $scenario "*) ;; *) echo "Unknown scenario “$scenario”. Known:$known" >&2; exit 2 ;; esac
done
out="$(mktemp -d "${TMPDIR:-/tmp}/beeline-live-check.XXXXXX")"
echo "Screenshots and logs: $out"
echo "Hands off the keyboard and mouse until it finishes."

field() { printf '%s' "$1" | plutil -extract "$2" raw -o - - 2>/dev/null; }

shots=0
capture() {
    shots=$((shots + 1))
    # screencapture takes one file name per display.
    local name="$out/$scenario-$(printf '%02d' "$shots")-$1"
    screencapture -x "$name.png" "$name-display2.png" "$name-display3.png"
}

running_copy=""
if pid="$(pgrep -x Beeline | head -1)"; then
    executable="$(ps -o comm= -p "$pid")"
    running_copy="${executable%/Contents/MacOS/Beeline}"
    pkill -x Beeline
    for _ in $(seq 50); do pgrep -xq Beeline || break; sleep 0.1; done
    if pgrep -xq Beeline; then
        echo "Beeline didn't quit, so the check can't start its own copy. Quit it and try again." >&2
        exit 2
    fi
fi
bring_back() { if [ -n "$running_copy" ] && [ -d "$running_copy" ] && ! pgrep -xq Beeline; then open "$running_copy"; fi; }
trap bring_back EXIT

failed=0
summary=""
for scenario in "${scenarios[@]}"; do
    log="$out/$scenario.jsonl"
    : > "$log"
    shots=0
    echo "— $scenario"
    open -n -W --env "BEELINE_DEMO=$scenario" --env "BEELINE_DEMO_LOG=$log" "$app" &
    opener=$!
    seen=0
    deadline=$((SECONDS + 60))
    while kill -0 "$opener" 2>/dev/null && [ "$SECONDS" -lt "$deadline" ]; do
        total=$(wc -l < "$log" | tr -d ' ')
        while [ "$seen" -lt "$total" ]; do
            seen=$((seen + 1))
            line="$(sed -n "${seen}p" "$log")"
            case "$(field "$line" event)" in
                shot) capture "$(field "$line" name)" ;;
                bee-takeoff) sleep "$(awk -v s="$(field "$line" seconds)" 'BEGIN { print s * 0.3 }')"; capture flight ;;
                bee-landed) capture landed ;;
            esac
        done
        sleep 0.1
    done
    if kill -0 "$opener" 2>/dev/null; then
        pkill -x Beeline
        echo "   gave up after a minute. Its TextEdit document (“Beeline live check …”) may still be open: close it without saving."
    fi
    wait "$opener" 2>/dev/null

    result="$(grep '"event":"result"' "$log" | tail -1)"
    if [ -z "$result" ]; then
        if [ ! -s "$log" ]; then why="no log: this build has no live-check mode, or it didn't start"; else why="it never reported a result"; fi
        verdict=FAIL
    else
        why="$(field "$result" why)"
        [ "$(field "$result" pass)" = "true" ] && verdict=PASS || verdict=FAIL
    fi
    [ "$verdict" = PASS ] || failed=$((failed + 1))
    echo "   $verdict: $why"
    summary+="$verdict  $scenario: $why"$'\n'
done

echo
printf '%s' "$summary"
echo "Screenshots and logs: $out"
exit $((failed > 0))
