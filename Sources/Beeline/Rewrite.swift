import AppKit
import Carbon.HIToolbox

/// Rewrites the text selected in the app in front: "make this shorter", "more formal", "fix the spelling".
/// The selection is read through Accessibility when the bar opens, so the clipboard is left alone until
/// the rewrite is pasted over it.
enum Rewrite {
    struct Selection {
        let text: String
        let app: pid_t
    }

    /// The text selected when the bar opened, if any. Main thread only.
    private(set) static var selection: Selection?

    /// Reads the selected text from the focused field of the app in front. Runs off the main thread
    /// because a slow app can take a moment to answer.
    static func refreshSelection(done: @escaping () -> Void) {
        selection = nil
        guard let app = NSWorkspace.shared.frontmostApplication, app.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let element = Accessibility.applicationElement(app)
            guard let focused: AXUIElement = Accessibility.attribute(element, kAXFocusedUIElementAttribute),
                  let text: String = Accessibility.attribute(focused, kAXSelectedTextAttribute),
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.count <= 8000 else { return }
            DispatchQueue.main.async {
                // Only if the same app is still in front; otherwise the selection belongs to something else.
                guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else { return }
                selection = Selection(text: text, app: app.processIdentifier)
                done()
            }
        }
    }

    /// Sets the selection directly. Used by the command-line test mode.
    static func useSelection(_ text: String) {
        selection = Selection(text: text, app: 0)
    }

    /// Words that mark a request as being about the selected text rather than about apps or settings.
    private static let cues: Set<String> = [
        "rewrite", "rephrase", "reword", "shorter", "longer", "shorten", "lengthen", "expand", "condense", "concise",
        "formal", "casual", "friendlier", "friendly", "polite", "professional", "simpler", "simplify", "clearer",
        "grammar", "spelling", "typos", "proofread", "polish", "tone", "translate", "summarize", "summarise",
        "bullet", "bullets", "punchier", "warmer", "softer", "firmer", "nicer", "improve", "edit",
    ]

    /// True when the request reads like an instruction for the selected text.
    static func isRequest(_ query: String) -> Bool {
        let words = query.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
        guard !words.isEmpty else { return false }
        if words.contains(where: cues.contains) { return true }
        // "make this …", "make it …", "fix this", "turn this into …"
        let start = words.prefix(2).joined(separator: " ")
        return ["make this", "make it", "fix this", "fix it", "turn this", "turn it", "change this", "say this"].contains(start)
    }

    /// The selected text rewritten by Claude, or why it could not be.
    static func ask(_ instruction: String, text: String) async -> Result<String, Planner.Failure> {
        await Planner.rewrite(text, instruction: instruction)
    }

    /// Pastes the rewrite over the selection, then puts the clipboard back as it was. If another app has
    /// come forward meanwhile, nothing is pasted and the rewrite is left on the clipboard instead.
    static func replace(with text: String, in app: pid_t) {
        let board = NSPasteboard.general
        let saved = board.pasteboardItems?.map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        } ?? []
        board.clearContents()
        board.setString(text, forType: .string)
        let written = board.changeCount

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app else {
                NSSound.beep()
                Log.append("rewrite: app changed, left on clipboard")
                return
            }
            guard Keyboard.press("v", flags: .maskCommand) else {
                Actions.report("Allow Accessibility for Beeline in Privacy & Security to paste. The rewrite is on the clipboard.")
                return
            }
            // Long enough for the app to read the clipboard. Skipped if anything else was copied meanwhile.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                guard board.changeCount == written, !saved.isEmpty else { return }
                board.clearContents()
                board.writeObjects(saved.map { pairs in
                    let item = NSPasteboardItem()
                    for (type, data) in pairs { item.setData(data, forType: type) }
                    return item
                })
            }
        }
    }
}
