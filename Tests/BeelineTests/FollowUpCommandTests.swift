import Foundation
import Testing
@testable import Beeline

@Test(arguments: [
    ("undo that", FollowUpCommand.undo), ("Undo that.", .undo), ("now undo that", .undo), ("undo it", .undo),
    ("Undo", .undo), ("take that back", .undo),
    ("the other window", .otherWindow), ("The other window.", .otherWindow), ("now the other window", .otherWindow),
    ("switch to the other window", .otherWindow), ("go back to the other window", .otherWindow), ("other window", .otherWindow),
])
func theFollowUpPhrasesAreHeard(spoken: String, command: FollowUpCommand) {
    #expect(FollowUpCommand.parse(spoken) == command)
}

@Test(arguments: ["", "undoubtedly", "undo that file move to downloads", "other windows", "the other window manager",
                  "close the other window", "mail"])
func otherWordsAreNotAFollowUp(spoken: String) {
    #expect(FollowUpCommand.parse(spoken) == nil)
}

@Test func undoThatTakesBackWhatBeelineLastDid() {
    let log = UndoLog()
    let undone = UndoOutcome()
    #expect(log.item(for: "Undo that.") == nil, "nothing Beeline did can be undone yet")
    log.record("Toggle Dark Mode") { undone.set(true) }
    guard let item = log.item(for: "Undo that.") else { Issue.record("no undo row"); return }
    #expect(item.title == "Toggle Dark Mode")
    #expect(log.item(for: "now undo that")?.title == "Toggle Dark Mode")
    item.run()
    let until = Date().addingTimeInterval(2)
    while undone.value == nil, Date() < until { Thread.sleep(forTimeInterval: 0.01) }
    #expect(undone.value == true)
    #expect(log.item(for: "undo that") == nil, "an undo runs once")
}

private func window(_ title: String, app: String, pid: Int, current: Bool = false, run: @escaping () -> Void = {}) -> Item {
    var item = Item(id: "window:\(pid):0", kind: .window, verb: "Switch to window", title: title,
                    subtitle: app, keywords: app, icon: nil, run: run)
    item.isCurrentWindow = current
    return item
}

@Test func theHistoryRemembersTheWindowFocusedBefore() {
    let history = WindowHistory()
    let docs = window("Docs", app: "Safari", pid: 1)
    let inbox = window("Inbox", app: "Mail", pid: 2)
    #expect(history.other(in: [docs, inbox]) == nil)
    history.saw([window("Docs", app: "Safari", pid: 1, current: true), inbox])
    #expect(history.other(in: [docs, inbox]) == nil, "one window seen, none before it")
    history.saw([docs, window("Inbox", app: "Mail", pid: 2, current: true)])
    history.saw([docs, window("Inbox", app: "Mail", pid: 2, current: true)])
    history.saw([docs, inbox])
    #expect(history.other(in: [docs, inbox])?.title == "Docs", "rescans of the same window, or none in front, change nothing")
    history.saw([window("Docs", app: "Safari", pid: 1, current: true), inbox])
    #expect(history.other(in: [docs, inbox])?.title == "Inbox", "saying it twice goes back and forth")
    #expect(history.other(in: [docs]) == nil, "a closed window is not offered")
}

@Test func theOtherWindowSwitchesToThePreviouslyFocusedWindow() {
    TestEnvironment.prepare()
    var raised: [String] = []
    let docs = window("Docs", app: "Safari", pid: 1) { raised.append("Docs") }
    let inbox = window("Inbox", app: "Mail", pid: 2, current: true) { raised.append("Inbox") }
    let catalogue = Catalogue(apps: [], windows: [inbox], planOnlyWindows: [docs], quits: [], controls: [])
    #expect(!catalogue.search("the other window").contains { $0.id.hasPrefix("other-window:") }, "no window seen before")
    catalogue.windowHistory.saw([window("Docs", app: "Safari", pid: 1, current: true), inbox])
    catalogue.windowHistory.saw([docs, inbox])
    let spoken = "The other window."
    let results = catalogue.search(spoken)
    #expect(results.count == 1)
    guard let top = results.first else { return }
    #expect(top.title == "Docs")
    #expect(top.subtitle == "Safari")
    #expect(top.verb == "Switch to window")
    #expect(!BarModel.claudeLeads(question: false, words: 3, top: top, followUp: true, strong: true),
            "the local switch stays first even after a Claude plan")
    AutoAct.pick(results, spoken: spoken)?.run()
    #expect(raised == ["Docs"], "a window switch is safe, so letting go of the hotkey runs it")
    #expect(AutoAct.pick(results, spoken: "docs") == nil, "only the phrase that found it acts")
}

@Test func undoThatStillWaitsForReturnWhenSpoken() {
    let log = UndoLog()
    log.record("Move “a.txt” to Desktop") {}
    guard let item = log.item(for: "undo that") else { Issue.record("no undo row"); return }
    #expect(AutoAct.pick([item], spoken: "undo that") == nil)
}
