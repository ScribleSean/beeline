#!/bin/bash
# Hands-free live check of the bee, the stop keys and the welcome card.
#
#   bash scripts/live-check.sh                 # every scenario
#   bash scripts/live-check.sh press escape    # some of them
#
# Each scenario launches Beeline with BEELINE_DEMO set. Beeline then opens a throwaway TextEdit document,
# works only in it (TextEdit's ruler and zoom commands), closes it, and quits. Screenshots are taken at the
# moments Beeline marks in its log. Keep your hands off the keyboard and mouse while it runs: a click or a
# key stops a run, which is the point of two of the checks.
#
# Needs: Beeline built with this live-check mode, at ~/Applications/Beeline.app (or BEELINE_APP), with
# Accessibility allowed; and Screen Recording allowed for the terminal, for the screenshots.
set -uo pipefail

app="${BEELINE_APP:-$HOME/Applications/Beeline.app}"
[ -d "$app" ] || { echo "No Beeline at $app (set BEELINE_APP)." >&2; exit 2; }
if [ $# -gt 0 ]; then scenarios=("$@"); else scenarios=(press plan escape click welcome); fi
out="$(mktemp -d "${TMPDIR:-/tmp}/beeline-live-check.XXXXXX")"
echo "Screenshots and logs: $out"
echo "Hands off the keyboard and mouse until it finishes."

# One value from one JSON line, or nothing.
field() { printf '%s' "$1" | plutil -extract "$2" raw -o - - 2>/dev/null; }

shots=0
capture() {
    shots=$((shots + 1))
    screencapture -x "$out/$scenario-$(printf '%02d' "$shots")-$1.png"
}

# Only one Beeline runs at a time, so the usual one steps aside and comes back at the end.
was_running=false
if pgrep -xq Beeline; then
    was_running=true
    pkill -x Beeline
    for _ in $(seq 50); do pgrep -xq Beeline || break; sleep 0.1; done
fi

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
                # Partway through the flight, so the bee is caught in the air (and before the escape and
                # click checks interrupt it, at 40%).
                bee-takeoff) sleep "$(awk -v s="$(field "$line" seconds)" 'BEGIN { print s * 0.3 }')"; capture flight ;;
                bee-landed) capture landed ;;
            esac
        done
        sleep 0.1
    done
    if kill -0 "$opener" 2>/dev/null; then
        pkill -x Beeline
        echo "   gave up after a minute"
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

if $was_running; then open "$app"; fi
echo
printf '%s' "$summary"
echo "Screenshots and logs: $out"
exit $((failed > 0))
