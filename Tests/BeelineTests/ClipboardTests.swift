import AppKit
import Testing
@testable import Beeline

/// A pasteboard of its own, so the real clipboard is never read or changed.
private func privateBoard() -> NSPasteboard {
    NSPasteboard(name: NSPasteboard.Name("beeline-test-" + UUID().uuidString))
}

/// Lets the read queue and then the main queue finish what the last check started.
@MainActor private func settle(_ clipboard: Clipboard) async {
    clipboard.readQueue.sync {}
    // Waiting, rather than blocking, lets the main queue run the save.
    try? await Task.sleep(nanoseconds: 100_000_000)
}

private let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

@MainActor @Test func aPlainCopyIsKept() async {
    UserDefaults.standard.set(true, forKey: Settings.clipboardHistory)
    let board = privateBoard()
    let clipboard = Clipboard(board: board)
    board.clearContents()
    board.setString("invoice 42", forType: .string)
    clipboard.check()
    await settle(clipboard)
    #expect(clipboard.entries.map(\.text) == ["invoice 42"])
}

@MainActor @Test func aPasswordManagersCopyIsNeverKept() async {
    UserDefaults.standard.set(true, forKey: Settings.clipboardHistory)
    let board = privateBoard()
    let clipboard = Clipboard(board: board)
    board.clearContents()
    board.declareTypes([.string, concealed], owner: nil)
    board.setString("hunter2", forType: .string)
    clipboard.check()
    await settle(clipboard)
    #expect(clipboard.entries.isEmpty)
}

// Codex 3: a password copied between the check and the read must not be saved.
@MainActor @Test func aPasswordCopiedDuringTheReadIsNotKept() async {
    UserDefaults.standard.set(true, forKey: Settings.clipboardHistory)
    let board = privateBoard()
    let clipboard = Clipboard(board: board)
    board.clearContents()
    board.setString("harmless", forType: .string)
    clipboard.readQueue.suspend()
    clipboard.check()
    // The password manager copies while the read is still waiting.
    board.clearContents()
    board.declareTypes([.string, concealed], owner: nil)
    board.setString("hunter2", forType: .string)
    clipboard.readQueue.resume()
    await settle(clipboard)
    clipboard.check()
    await settle(clipboard)
    #expect(!clipboard.entries.contains { $0.text == "hunter2" })
}

// Codex 3: clearing the history also drops a copy still being read.
@MainActor @Test func clearingDropsACopyOnItsWay() async {
    UserDefaults.standard.set(true, forKey: Settings.clipboardHistory)
    let board = privateBoard()
    let clipboard = Clipboard(board: board)
    board.clearContents()
    board.setString("meeting notes", forType: .string)
    clipboard.check()
    clipboard.clear()
    await settle(clipboard)
    #expect(clipboard.entries.isEmpty)
}
