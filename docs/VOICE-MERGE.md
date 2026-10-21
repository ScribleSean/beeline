# Folding Voice Control into Beeline

One app, named Beeline. You type, or hold ⌘Space and talk. The bee shows where Beeline is acting.

## What each app had

| | Beeline | Voice Control (Oct 2026 snapshot) |
| --- | --- | --- |
| Speech | On-device speech while ⌘Space is held (`Voice.swift`) | None. "Speech is not enabled in this build." |
| Hotkey | ⌘Space through Carbon: no permission, takes only its own key | Right Option through an event tap: needs Input Monitoring, swallowed Escape and Right Option in every app (review #1, High) |
| Reading the screen | `Controls.swift`: buttons, links, fields in the front window, with Return-twice for anything irreversible | `NativeObservation`: the same scan, plus a matcher with known bugs (#4, #6, #10, #23) |
| Acting | Plans from Claude, previewed and confirmed, run step by step with a check before and after each step | `NativeActionDriver` + `SerialExecutor` + `DispatchGate`: pointer moves, scroll, AX focus, typing text. Only the test fixture used it |
| Stopping | Escape, only while the bar has focus | Escape anywhere (by eating it), sleep, any mouse movement |
| On-screen feedback | The bar | `CursorPrompt`: a small panel next to the pointer |
| Streaming | — | `TranscriptLedger` and `SessionArbiter`: run actions while you are still speaking. No caller in the app |

Voice Control was an earlier prototype of the same repo. Beeline replaced it, so most of its pieces already exist in Beeline in a better-tested form.

## What moves

1. **The bee.** `CursorPrompt` becomes the bee: a small overlay that goes to where Beeline is about to act and says what it is doing. Fixes carried in: it never takes clicks and never sits over the thing it points at (#8); it finds the screen the pointer is on even at the edge, and never force-unwraps a screen (#32).
2. **Stop from anywhere.** While a plan runs, Escape stops it in any app. Beeline *watches* Escape with a global monitor and never *eats* it, so Escape keeps working everywhere (the fix for #1 by design). The monitor exists only while a plan runs.
3. **Hands back on the wheel.** While a plan runs, your own click or keypress stops the steps still to come. Moving the pointer does not (#3). Beeline's own synthetic keys carry one tag so they never count as yours (#36, #45).
4. **One way to cancel.** Escape, your takeover, sleep, a new plan and closing all go through one stop call, so nothing is half-cancelled (#26, #16, #33).
5. **Sleep stops a plan,** as Voice Control's executor did.
6. **A token per run.** From `DispatchGate`: each plan run has a number, and a step only runs if its number is still current. A late callback from an old run cannot act.

## What gets dropped

- **Right Option, the event tap and Input Monitoring.** Duplicates hold-⌘Space, costs a permission, and caused the High bug.
- **The test window, fixture and `--preflight`.** Test scaffolding for the prototype.
- **`TranscriptLedger`, `SessionArbiter`, `SerialExecutor`, `DispatchGate` as types.** They exist to act *while* you speak. Beeline's model is speak, see, confirm. Nothing called them, and #12–#17 and #28 were latent bugs in them. The one idea worth keeping (a current-run token) moves in as a few lines.
- **`NativeObservation` and `NativeActionDriver`.** Duplicates of `Controls.swift` and the plan runner. Typing dictated text into other apps' fields is left out on purpose: today voice only fills the bar and you press Return, which is why #4, #6 and #7 (wrong field, password field, focus moving mid-typing) cannot happen in Beeline. If it is wanted later, it needs those fixes first.

## Hotkeys

| Key | Does |
| --- | --- |
| ⌘Space tap | Open or close the bar |
| ⌘Space hold | Talk; let go to stop |
| esc in the bar | Back, then close (unchanged) |
| esc anywhere, while a plan runs | Stop the plan. Escape still reaches the app in front |

If Spotlight still owns ⌘Space, Beeline falls back to ⌥Space, then ⌃Space, as today.

## Permissions

Unchanged: Accessibility, Automation, Files & Folders, Reminders, Microphone and Speech Recognition. Watching Escape while a plan runs uses Accessibility, which plans already need. **No Input Monitoring.**

## Design decisions for Sean

Asked in one question card before any UI work; answers recorded below.

- How hold-to-talk feels after you let go
- What the bee looks like and when it shows
- Whether voice and typing share the bar
- ⌘Space and Spotlight
