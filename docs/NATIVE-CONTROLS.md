# Native controls

`NativeObservationProvider` implements the core observation contract. `NativeActionDriver(observations:)` implements the action contract. Share the same observation instance between resolution and execution. `NativeActionDriver.eventTag` is `0x56434F4E54524F4C`.

The shell must ignore that marker on app-generated events and call `invalidate()` synchronously for physical mouse, scroll and keyboard interaction. Handle consumed Right Option, Escape and confirmation gestures before that invalidation hook. Cancellation and invalidation must precede any queued continuation. The driver is intended for one serial executor, and `perform` and `releaseHeldInputs` must run under its dispatch gate.

## Observation and target identity

AX reads run on one dedicated queue, with notification registration on the main actor. A small lock protects the invalidation epoch and latest snapshot; AX handles are never serialized or logged. Observations preserve opaque target and window identities when AX handles compare equal, while the observation ID changes. Only references issued by the latest observation are accepted. Enumeration is bounded to 800 visited nodes, 18 levels and a nominal 800 ms traversal budget. Each AX IPC uses a 30 ms messaging timeout. The time budget is checked between nodes, so a slow node may exceed it by several bounded calls.

Validation rechecks the focused app PID and bundle ID, focused window handle and bounds, target role, label, bounds, enabled state, hidden state and visibility. A center-point AX hit test must return the target or a descendant. A changed window, target, manual-interaction epoch or permission invalidates the reference. This is deliberately conservative: obscured centers, unavailable accessibility attributes and inaccessible apps fail closed. There is no OCR fallback in this slice.

Labels use AX title, description and placeholder. Field values and window titles are never used as label fallbacks. Natural matching normalizes case and accents, recognizes field descriptions, and returns all matching candidates when several qualify. It never chooses a top-scoring candidate silently. Labels and literal field values remain local data; these contracts are not cloud export objects.

## Dispatch and supported effects

`validate`, `prepare` and `verify` do not post input. Preparation builds the complete bounded event array and retains the matching AX handle or running-app handle. `perform` accepts only the next prepared step, checks its epoch and performs one event or one native effect. It does not enumerate the tree, sleep, call a model or start a detached input task. AX focus is a single IPC with the element's 30 ms timeout; application activation uses `NSRunningApplication.activate(options: [])` and needs post-action verification. Native activation does not inherit Right Option as a click modifier.

- App switching supports applications already running. It does not launch a missing app.
- Pointer movement uses AX global logical points with a top-left origin. No screenshot pixel conversion is needed.
- Editable field focus uses AX focus. A click on an editable field is the same safe effect.
- Generic buttons and links are discoverable but clicks are rejected until a classified effect adapter exists. Deletion, message sending and spending are rejected even if the core receives an approval. This prevents an unclassified click from bypassing confirmation.
- Scroll accepts at most 600 pixels in either direction and splits the amount into at most 20 pixels per posted event. It first moves the pointer to the validated target center.
- Text insertion requires an editable focused field and a readable empty selection. At most 4096 UTF-16 code units are accepted. Control characters, including newline and tab, are rejected because they can submit a form or move focus. Secure-field subroles are excluded. Text is split by Unicode scalar, preserving surrogate pairs, and each down/up is a separate cancellation boundary. Cancellation may leave a partial grapheme cluster.

Every CGEvent has explicitly empty flags, a private event source and the app marker. Held synthetic key/button state is tracked under the driver's lock. Cancellation or an exception clears the prepared plan and posts only needed release events. Releases cannot undo already delivered text.

## Evidence and remaining checks

The layer was written on Windows, which has no Swift compiler or macOS AX runtime. Compilation, Accessibility permission behavior, Right Option-held input and Safari/TextEdit behavior must be verified by the authoritative Mac build and fixture run. No runtime success or latency result is claimed here.

App activation verifies the focused bundle; focus verifies the AX focused attribute; pointer movement checks its current position. Text checks an exact expected field value when the pre-insertion AX value is readable. A mismatch returns unknown because the app may still be processing input. Scroll returns unknown because a posted event does not prove a scroll effect; it invalidates observations. Unknown effects must not be automatically retried.

AX handles are retained locally across asynchronous preparation. The classes use `@unchecked Sendable` because framework handles are not Swift Sendable types; reads are queue-confined and plan/state mutation is lock-protected. The synchronous effect touches only the prepared handle. This isolation needs Swift 6 compilation and targeted concurrency review on the Mac. The validation-to-dispatch gap cannot atomically lock another application's UI; the shell's synchronous invalidation hook closes physical-interaction races, while fresh predispatch AX checks handle other observed changes. App activation and AX window focus, movement, resize, destruction and layout notifications invalidate observations. Unsupported notifications still rely on fresh validation. Layout notifications may conservatively interrupt scrolling; adapter-specific scroll verification remains future work.

## Apple references

- [AX attribute reads](https://developer.apple.com/documentation/applicationservices/1462085-axuielementcopyattributevalue)
- [Bounded AX child reads](https://developer.apple.com/documentation/applicationservices/1462060-axuielementcopyattributevalues)
- [AX messaging timeout](https://developer.apple.com/documentation/applicationservices/1459345-axuielementsetmessagingtimeout)
- [AX attribute writes](https://developer.apple.com/documentation/applicationservices/1460434-axuielementsetattributevalue)
- [Native app activation](https://developer.apple.com/documentation/appkit/nsrunningapplication/activate(options:))
- [Unicode keyboard payloads](https://developer.apple.com/documentation/coregraphics/cgevent/keyboardsetunicodestring(stringlength:unicodestring:))
- [Event modifier flags](https://developer.apple.com/documentation/coregraphics/cgeventflags)
- [Event source user data](https://developer.apple.com/documentation/coregraphics/cgeventsource/userdata)
