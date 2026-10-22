import Foundation

/// Decides whether Beeline may act by itself when you let go of ⌘Space, without waiting for Return.
/// Only for one thing that is plainly what you said and easy to take back: opening an app or a settings
/// page, switching to a window, or a short list of undoable toggles. Everything else waits for Return.
/// Dictation apps never act on their own, and command tools like Talon act only on an exact command; this
/// follows the second, narrowly.
enum AutoAct {
    /// Actions safe to run unasked: each is undone by "undo" or by doing it again, and none sends, deletes,
    /// closes or disconnects anything.
    static let safeActions: Set<String> = ["action:Mute", "action:Unmute", "action:Volume Up", "action:Volume Down",
                                           "action:Toggle Dark Mode", "action:Mission Control"]

    /// Words people put before a name that don't change what they mean.
    private static let leadIns = ["open", "launch", "start", "show", "go to", "switch to", "bring up", "show me", "turn on"]

    /// What to run on release, or nil to wait for Return.
    static func pick(_ results: [Item], spoken: String) -> Item? {
        let said = Usage.normalise(spoken.trimmingCharacters(in: .punctuationCharacters))
        guard !said.isEmpty, let top = results.first, isSafe(top), !top.isGuess else { return nil }
        // Your own alias, or what you picked for these very words before, is clear enough on its own.
        if top.isAlias || top.isLearned { return top }
        // Otherwise the words must name it, and nothing else in the list may share that name.
        guard names(said, top) else { return nil }
        if results.dropFirst().contains(where: { names(said, $0) }) { return nil }
        return top
    }

    static func isSafe(_ item: Item) -> Bool {
        guard !item.needsConfirm else { return false }
        switch item.kind {
        case .app, .setting: return true
        // Switching to a window, yes; moving one ("window left") waits for Return.
        case .window: return item.id.hasPrefix("window:")
        case .action: return safeActions.contains(item.id)
        default: return false
        }
    }

    /// True when the words are the item's name, with or without a lead-in like "open" or a trailing "settings".
    static func names(_ said: String, _ item: Item) -> Bool {
        let title = Usage.normalise(item.title)
        var core = said
        for lead in leadIns where core.hasPrefix(lead + " ") {
            core = String(core.dropFirst(lead.count + 1))
            break
        }
        if core.hasPrefix("the ") { core = String(core.dropFirst(4)) }
        for suffix in [" settings", " app", " window"] where core.hasSuffix(suffix) && core != title {
            core = String(core.dropLast(suffix.count))
        }
        return core == title
    }
}
