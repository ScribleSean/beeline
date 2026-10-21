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

## Sean's design decisions (21 Oct 2026)

| Question | Choice | How it was built |
| --- | --- | --- |
| After you let go of ⌘Space | Words fill the bar; you press Return; then the bee does the work. Sean wants it to feel like a smart decision maker over time | Unchanged flow: live words in the bar, ranking picks the top row, Return runs it. "Smarter" (acting without Return) is left for a later conversation |
| The bee | Flies to each step | `Bee.swift`: a drawn bee (yellow body, ink bands, beating wings) in a click-through overlay. It leaves from the bar's search icon on an eased arc (0.3–0.62 s), faces where it flies, rests just off the target's corner, a thin yellow ring settles on the target with one soft pulse, and a small pill says what it is doing ("Press Send"). Then the action runs. It leaves after the last step. Reduce Motion: it appears in place, no flight. Your real pointer never moves |
| Voice and typing | One bar | While you hold ⌘Space the search icon becomes a mic, the placeholder says Listening…, and a five-bar level meter breathes at the right of the field |
| ⌘Space and Spotlight | Keep ⌘Space, guide the user | The welcome screen shows a card while Spotlight holds ⌘Space, with a button to Keyboard settings, and retries ⌘Space every few seconds while open |

Open-source check: CursorVoice (MIT) uses a floating panel with a halo and moves the real pointer; jasPreMar/this has a separate "ghost cursor" for running tasks (no license, so nothing was taken). Beeline's bee follows the ghost-cursor idea of a separate cursor and draws its own.

## What has a bee, and what doesn't

The bee flies only to things with a place on screen: buttons, links, fields and checkboxes in the front window, menu commands (it goes to the menu's title), windows and window tiling. Opening apps, settings, actions, tabs and files run at once, as before.

Before flying, the target is checked; after landing it is checked again, so nothing is pressed if the window changed while the bee was on its way.

## The Voice Control review's 49 findings

| Findings | What happened |
| --- | --- |
| #1 (High), #11, #21, #37 | The event tap is gone. Escape is watched, never swallowed, and only while something runs (`RunGuard`) |
| #3 | Pointer movement and scrolling never stop a run; clicks and keys do (`RunGuard.reason`, tested) |
| #8 | The bee's overlay ignores clicks and rests beside the target, never on it |
| #16, #26, #33 | One stop path: `RunGuard.stop` → `BarController.runStopped` |
| #32 | Screen lookup is inclusive at the edges and never force-unwraps (`BeeFlight.screen`, tested) |
| #36, #45 | One tag, `RunGuard.eventTag`, set once on each keystroke Beeline posts |
| #2 | Already solved in Beeline (`.signing-identity`) |
| #4, #6, #7, #10, #20, #22, #31 | Not carried: Beeline does not type dictated text into other apps |
| #5, #9, #12–#15, #17, #24, #25, #28–#30, #34, #35, #38–#44, #46, #49 | In code that was dropped (ledger, arbiter, executor, gate, native driver, fixture) |
| #18, #19, #27, #47, #48 | Prototype window and docs, dropped. Beeline already rechecks permissions while its welcome screen is open |
| #23 | Beeline lowercases without a locale already |
