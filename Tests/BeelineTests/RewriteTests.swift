import AppKit
import Testing
@testable import Beeline

private func capturedRewrite() -> Rewrite.Selection {
    Rewrite.Selection(text: "original", app: 42,
                      element: AXUIElementCreateApplication(42), window: AXUIElementCreateApplication(43),
                      range: NSRange(location: 3, length: 8))
}

@Test(arguments: ["field", "window", "range", "text", "app", "unavailable", "missing range"])
func rewriteRefusesAChangedTarget(change: String) {
    let captured = capturedRewrite()
    var current: Rewrite.Selection? = captured
    var scheduled: [() -> Void] = []
    var pastes = 0
    var reports: [String] = []
    var clipboard = "old secret"
    let io = Rewrite.PasteIO(read: { _ in current }, write: { clipboard = $0; return true }, contains: { clipboard == $0 },
                             paste: { pastes += 1; return true }, later: { scheduled.append($0) },
                             report: { reports.append($0) })
    Rewrite.replace(with: "rewritten", in: captured, io: io)
    // Change after scheduling, just before the queued paste, including identical text in another field.
    switch change {
    case "field": current?.element = AXUIElementCreateApplication(99)
    case "window": current?.window = AXUIElementCreateApplication(99)
    case "range": current?.range = NSRange(location: 12, length: 8)
    case "text": current = Rewrite.Selection(text: "different", app: captured.app, element: captured.element,
                                             window: captured.window, range: captured.range)
    case "app": current = Rewrite.Selection(text: captured.text, app: 99, element: captured.element,
                                            window: captured.window, range: captured.range)
    case "missing range": current?.range = nil
    default: current = nil
    }
    scheduled.removeFirst()()
    #expect(pastes == 0)
    #expect(reports.count == 1)
    #expect(clipboard == "rewritten")
}

@Test func aSlowPasteNeverReadsThePreviousClipboard() {
    let captured = capturedRewrite()
    var scheduled: [() -> Void] = []
    var clipboard = "old secret"
    var appRead: (() -> String)?
    let io = Rewrite.PasteIO(read: { _ in captured }, write: { clipboard = $0; return true }, contains: { clipboard == $0 },
                             paste: { appRead = { clipboard }; return true },
                             later: { scheduled.append($0) }, report: { _ in Issue.record("Unexpected refusal") })
    Rewrite.replace(with: "rewritten", in: captured, io: io)
    scheduled.removeFirst()()
    // Drain every scheduled callback before the app finally reads its paste. A timed restore would leak.
    while !scheduled.isEmpty { scheduled.removeFirst()() }
    #expect(appRead?() == "rewritten")
    clipboard = "user copied something else"
    #expect(scheduled.isEmpty)
    #expect(clipboard == "user copied something else")
}

@Test func rewriteWithoutAXIdentityCannotPaste() {
    let captured = Rewrite.Selection(text: "original", app: 42)
    #expect(!captured.matches(captured))
}

@Test func rewriteDoesNotPasteANewerClipboardItem() {
    let captured = capturedRewrite()
    var scheduled: [() -> Void] = []
    var clipboard = "old"
    var pastes = 0
    let io = Rewrite.PasteIO(read: { _ in captured }, write: { clipboard = $0; return true },
                             contains: { clipboard == $0 }, paste: { pastes += 1; return true },
                             later: { scheduled.append($0) }, report: { _ in })
    Rewrite.replace(with: "rewritten", in: captured, io: io)
    clipboard = "new secret"
    scheduled.removeFirst()()
    #expect(pastes == 0)
    #expect(clipboard == "new secret")
}
