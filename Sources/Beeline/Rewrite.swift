import AppKit
import Carbon.HIToolbox

enum Rewrite {
    struct Selection {
        let text: String
        let app: pid_t
        var element: AXUIElement? = nil
        var window: AXUIElement? = nil
        var range: NSRange? = nil

        func matches(_ current: Selection?) -> Bool {
            guard let current, let element, let window,
                  let currentElement = current.element, let currentWindow = current.window else { return false }
            return app == current.app && text == current.text && range == current.range
                && CFEqual(element, currentElement) && CFEqual(window, currentWindow)
        }
    }

    private(set) static var selection: Selection?

    /// Accessibility calls block until the target app answers, which a busy app can take a while to do.
    static func refreshSelection(done: @escaping () -> Void) {
        selection = nil
        guard let app = NSWorkspace.shared.frontmostApplication, app.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            guard let captured = readSelection(in: app.processIdentifier),
                  !captured.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  captured.text.count <= 8000 else { return }
            DispatchQueue.main.async {
                guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else { return }
                selection = captured
                done()
            }
        }
    }

    static func useSelection(_ text: String) {
        selection = Selection(text: text, app: 0)
    }

    private static let cues: Set<String> = [
        "rewrite", "rephrase", "reword", "shorter", "longer", "shorten", "lengthen", "expand", "condense", "concise",
        "formal", "casual", "friendlier", "friendly", "polite", "professional", "simpler", "simplify", "clearer",
        "grammar", "spelling", "typos", "proofread", "polish", "tone", "translate", "summarize", "summarise",
        "bullet", "bullets", "punchier", "warmer", "softer", "firmer", "nicer", "improve", "edit",
    ]

    static func isRequest(_ query: String) -> Bool {
        let words = query.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
        guard !words.isEmpty else { return false }
        if words.contains(where: cues.contains) { return true }
        let start = words.prefix(2).joined(separator: " ")
        return ["make this", "make it", "fix this", "fix it", "turn this", "turn it", "change this", "say this"].contains(start)
    }

    static func ask(_ instruction: String, text: String) async -> Result<String, Planner.Failure> {
        await Planner.rewrite(text, instruction: instruction)
    }

    static func readSelection(in pid: pid_t) -> Selection? {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        guard let focused: AXUIElement = Accessibility.attribute(app, kAXFocusedUIElementAttribute),
              let window: AXUIElement = Accessibility.attribute(app, kAXFocusedWindowAttribute),
              let text: String = Accessibility.attribute(focused, kAXSelectedTextAttribute) else { return nil }
        // Some apps don't report a range; then field, window and text still have to match.
        var range: NSRange?
        var raw = CFRange()
        if let value: AXValue = Accessibility.attribute(focused, kAXSelectedTextRangeAttribute),
           AXValueGetType(value) == .cfRange, AXValueGetValue(value, .cfRange, &raw) {
            range = NSRange(location: raw.location, length: raw.length)
        }
        return Selection(text: text, app: pid, element: focused, window: window, range: range)
    }

    struct PasteIO {
        var read: (pid_t) -> Selection? = { readSelection(in: $0) }
        var write: (String) -> Bool = {
            NSPasteboard.general.clearContents()
            return NSPasteboard.general.setString($0, forType: .string)
        }
        var contains: (String) -> Bool = { NSPasteboard.general.string(forType: .string) == $0 }
        var paste: () -> Bool = { Keyboard.press("v", flags: .maskCommand) }
        var later: (@escaping () -> Void) -> Void = { work in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
        }
        var report: (String) -> Void = { Actions.report($0) }
    }

    static func replace(with text: String, in captured: Selection, io: PasteIO = PasteIO()) {
        guard io.write(text) else { return }
        io.later {
            guard captured.matches(io.read(captured.app)) else {
                io.report("The field or selection changed. The rewrite is on the clipboard; select where it belongs and paste it yourself.")
                return
            }
            guard io.contains(text) else {
                io.report("The clipboard changed. Paste was cancelled; run the rewrite again when ready.")
                return
            }
            guard io.paste() else {
                io.report("Allow Accessibility for Beeline in Privacy & Security to paste. The rewrite is on the clipboard.")
                return
            }
            // Cmd-V only queues an event. There is no acknowledgement that the app has read the
            // pasteboard, so leave the rewrite there rather than risk pasting an old clipboard item.
        }
    }
}
