import Testing
@testable import Beeline

private func entry(_ enabled: Int, _ modifiers: Int) -> [String: Any] {
    ["enabled": enabled, "value": ["parameters": [32, 49, modifiers], "type": "standard"]]
}

// The welcome screen names what holds ⌘Space, read from macOS's own shortcut list.
@Test func spotlightIsNamedWhenItHoldsCommandSpace() {
    let hotkeys: [String: Any] = ["64": entry(1, 1_048_576), "60": entry(1, 262_144)]
    #expect(ShortcutConflicts.holders(of: "command", in: hotkeys) == [.init(section: "Spotlight", name: "Show Spotlight search")])
    #expect(ShortcutConflicts.holders(of: "control", in: hotkeys).first?.section == "Input Sources")
    #expect(ShortcutConflicts.holders(of: "option", in: hotkeys).isEmpty)
}

@Test func switchedOffShortcutsHoldNothing() {
    #expect(ShortcutConflicts.holders(of: "command", in: ["64": entry(0, 1_048_576)]).isEmpty)
    #expect(ShortcutConflicts.holders(of: "command", in: [:]).isEmpty)
}

// A Mac that never changed Spotlight's shortcut has no entry for it, and Spotlight still holds ⌘Space.
@Test func anUnchangedSpotlightStillHoldsCommandSpace() {
    #expect(ShortcutConflicts.holders(of: "command", in: ShortcutConflicts.withDefaults([:])).first?.section == "Spotlight")
    #expect(ShortcutConflicts.holders(of: "command", in: ShortcutConflicts.withDefaults(["64": entry(0, 1_048_576)])).isEmpty)
}
