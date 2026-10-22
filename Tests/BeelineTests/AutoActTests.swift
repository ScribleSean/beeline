import Foundation
import Testing
@testable import Beeline

private func item(_ id: String, _ kind: Kind, _ title: String, verb: String = "Open") -> Item {
    Item(id: id, kind: kind, verb: verb, title: title, subtitle: "", keywords: "", icon: nil, run: {})
}

private let safari = item("/Applications/Safari.app", .app, "Safari")
private let nightShift = item("setting:night", .setting, "Night Shift")

@Test func plainlyNamedAppsOpenOnRelease() {
    #expect(AutoAct.pick([safari], spoken: "Safari")?.id == safari.id)
    #expect(AutoAct.pick([safari], spoken: "open Safari.")?.id == safari.id)
    #expect(AutoAct.pick([nightShift], spoken: "night shift settings")?.id == nightShift.id)
}

@Test func anythingLessThanPlainWaitsForReturn() {
    #expect(AutoAct.pick([safari], spoken: "browser") == nil)
    var guess = safari
    guess.isGuess = true
    #expect(AutoAct.pick([guess], spoken: "safari") == nil)
    let other = item("/Users/x/Safari.app", .app, "Safari")
    #expect(AutoAct.pick([safari, other], spoken: "safari") == nil)
    #expect(AutoAct.pick([], spoken: "safari") == nil)
}

@Test func onlySafeKindsRunByThemselves() {
    #expect(AutoAct.isSafe(item("action:Mute", .action, "Mute", verb: "")))
    #expect(!AutoAct.isSafe(item("action:Turn Wi-Fi Off", .action, "Turn Wi-Fi Off", verb: "")))
    #expect(!AutoAct.isSafe(item("action:Sleep", .action, "Sleep", verb: "")))
    #expect(!AutoAct.isSafe(item("shortcut:Morning", .action, "Morning", verb: "Run Shortcut")))
    #expect(!AutoAct.isSafe(item("menu:1:x", .menu, "Close Tab", verb: "Run")))
    #expect(!AutoAct.isSafe(item("control:1:0", .control, "Send", verb: "Press")))
    #expect(!AutoAct.isSafe(item("tile:Left", .window, "Move This Window to the Left Half", verb: "")))
    #expect(AutoAct.isSafe(item("window:1:0", .window, "Inbox", verb: "Switch to window")))
    var confirm = safari
    confirm.needsConfirm = true
    #expect(!AutoAct.isSafe(confirm))
}

@Test func aliasesAndLearnedPicksRunOnRelease() {
    var aliased = safari
    aliased.source = .alias
    #expect(AutoAct.pick([aliased], spoken: "web")?.id == safari.id)
    var learnedSleep = item("action:Sleep", .action, "Sleep", verb: "")
    learnedSleep.source = .learned(4)
    #expect(AutoAct.pick([learnedSleep], spoken: "nap") == nil)
}
