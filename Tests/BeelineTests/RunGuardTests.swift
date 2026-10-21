import AppKit
import Carbon.HIToolbox
import Testing
@testable import Beeline

private func reason(_ type: NSEvent.EventType, key: Int = 0, _ modifiers: NSEvent.ModifierFlags = [],
                    repeat isRepeat: Bool = false, tag: Int64 = 0) -> RunGuard.Reason? {
    RunGuard.reason(for: type, keyCode: UInt16(key), modifiers: modifiers, isRepeat: isRepeat, tag: tag)
}

@Test func escapeAnywhereStopsARun() {
    #expect(reason(.keyDown, key: kVK_Escape) == .escape)
    // Caps Lock and Fn are not held keys: Escape still means stop.
    #expect(reason(.keyDown, key: kVK_Escape, [.capsLock, .function]) == .escape)
}

@Test func yourOwnClickOrKeyMeansYouTookOver() {
    #expect(reason(.leftMouseDown) == .takeover)
    #expect(reason(.rightMouseDown) == .takeover)
    #expect(reason(.keyDown, key: kVK_ANSI_A) == .takeover)
    // ⌘⌥Esc is Force Quit, not a plain stop, but it is still you taking over.
    #expect(reason(.keyDown, key: kVK_Escape, [.command, .option]) == .takeover)
}

// Review #3: a hand on the trackpad must not cancel anything.
@Test func movingThePointerChangesNothing() {
    #expect(reason(.mouseMoved) == nil)
    #expect(reason(.scrollWheel) == nil)
    #expect(reason(.flagsChanged) == nil)
}

@Test func beelinesOwnKeysAndHeldRepeatsDoNotCount() {
    #expect(reason(.keyDown, key: kVK_ANSI_V, [.command], tag: RunGuard.eventTag) == nil)
    #expect(reason(.keyDown, key: kVK_Return, repeat: true) == nil)
}

@Test func stoppingIsImmediateAndOnlyOnce() {
    let guardian = RunGuard(watches: false)
    var reasons: [RunGuard.Reason] = []
    guardian.onStop = { reasons.append($0) }
    let first = guardian.begin()
    #expect(guardian.isCurrent(first))
    let second = guardian.begin()
    #expect(!guardian.isCurrent(first))
    #expect(reasons == [.replaced])
    guardian.stop(.escape)
    #expect(!guardian.isCurrent(second))
    guardian.stop(.escape)
    guardian.end(second)
    #expect(reasons == [.replaced, .escape])
}

@Test func aFinishedRunIsNotStopped() {
    let guardian = RunGuard(watches: false)
    var stopped = false
    guardian.onStop = { _ in stopped = true }
    let run = guardian.begin()
    guardian.end(run)
    guardian.stop(.takeover)
    #expect(!stopped && !guardian.isRunning)
}
