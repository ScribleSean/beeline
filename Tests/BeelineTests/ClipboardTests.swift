import AppKit
import Testing
@testable import Beeline

private func privateBoard() -> NSPasteboard {
    NSPasteboard(name: NSPasteboard.Name("beeline-test-" + UUID().uuidString))
}

@MainActor private func settle(_ clipboard: Clipboard) async {
    clipboard.readQueue.sync {}
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

@MainActor @Test func aPasswordCopiedDuringTheReadIsNotKept() async {
    UserDefaults.standard.set(true, forKey: Settings.clipboardHistory)
    let board = privateBoard()
    let clipboard = Clipboard(board: board)
    board.clearContents()
    board.setString("harmless", forType: .string)
    clipboard.readQueue.suspend()
    clipboard.check()
    board.clearContents()
    board.declareTypes([.string, concealed], owner: nil)
    board.setString("hunter2", forType: .string)
    clipboard.readQueue.resume()
    await settle(clipboard)
    clipboard.check()
    await settle(clipboard)
    #expect(!clipboard.entries.contains { $0.text == "hunter2" })
}

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
