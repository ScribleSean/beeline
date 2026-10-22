import Foundation
import Testing
@testable import Beeline

/// The undo log is shared, so these run one at a time and tidy up after themselves.
@Suite(.serialized) struct UndoTests {
    @Test func undoRunsTheLatestOnce() {
        let log = UndoLog()
        var undone = 0
        log.record("Mute") { undone += 1 }
        #expect(log.undoLatest() == "Mute")
        #expect(log.undoLatest() == nil)
        #expect(undone == 1)
    }

    @Test func onlyTheLatestIsKept() {
        let log = UndoLog()
        var which = ""
        log.record("Mute") { which = "mute" }
        log.record("Turn Wi-Fi Off") { which = "wifi" }
        log.undoLatest()
        #expect(which == "wifi")
    }

    @Test func oldThingsCanNoLongerBeUndone() {
        let log = UndoLog()
        let then = Date()
        log.record("Mute", now: then) {}
        #expect(log.latest(now: then.addingTimeInterval(UndoLog.lifetime - 1)) != nil)
        #expect(log.undoLatest(now: then.addingTimeInterval(UndoLog.lifetime + 1)) == nil)
    }

    // "undo" offers a row; an empty bar only hints, for a couple of minutes, so Return there undoes nothing.
    @Test func theUndoRowAppearsOnlyWhenAskedFor() {
        let log = UndoLog()
        let then = Date()
        log.record("Toggle Dark Mode", now: then) {}
        #expect(log.item(for: "undo", now: then.addingTimeInterval(300))?.title == "Toggle Dark Mode")
        #expect(log.item(for: "", now: then) == nil)
        #expect(log.item(for: "undoubtedly", now: then) == nil)
        #expect(log.hint(now: then.addingTimeInterval(60)) == "“undo” takes back Toggle Dark Mode")
        #expect(log.hint(now: then.addingTimeInterval(300)) == nil)
    }

    // A row undoes only what it showed, never something recorded after it was drawn.
    @Test func aRowUndoesOnlyWhatItShowed() {
        let log = UndoLog()
        var undone = ""
        log.record("Toggle Dark Mode") { undone = "dark" }
        let shown = log.latest()!.id
        log.record("Move “a.txt” to Desktop") { undone = "move" }
        #expect(log.undoLatest(id: shown) == nil)
        #expect(undone == "")
        #expect(log.undoLatest() == "Move “a.txt” to Desktop")
    }

    // The undo row itself is never learned or given an alias.
    @Test func undoIsOneOfAKind() {
        let row = Item(id: "undo", kind: .action, verb: "Undo", title: "Mute", subtitle: "Undo", keywords: "", icon: nil, run: {})
        #expect(!Catalogue.canHaveAlias(row))
    }
}
