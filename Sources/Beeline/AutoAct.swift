import AppKit

enum AutoAct {
    static let safeActions: Set<String> = ["action:Mute", "action:Unmute", "action:Volume Up", "action:Volume Down",
                                           "action:Toggle Dark Mode", "action:Mission Control"]

    /// How long a voice result waits before running by itself. With VoiceOver on it covers saying `spoken`
    /// (about 14 characters a second at the default rate, plus a beat to start) and a second and a half to
    /// press Escape after hearing it.
    static func window(voiceOver: Bool, spoken: String) -> TimeInterval {
        guard voiceOver else { return 0.7 }
        return max(3, 0.4 + Double(spoken.count) / 14 + 1.5)
    }

    /// Read when each voice result arrives, so turning VoiceOver on mid-session counts.
    static var voiceOverIsOn: () -> Bool = { NSWorkspace.shared.isVoiceOverEnabled }

    private static let leadIns = ["open", "launch", "start", "show", "go to", "switch to", "bring up", "show me", "turn on"]

    static func pick(_ results: [Item], spoken: String) -> Item? {
        let said = Usage.normalise(spoken.trimmingCharacters(in: .punctuationCharacters))
        guard !said.isEmpty, let top = results.first, isSafe(top), !top.isGuess else { return nil }
        if top.isAlias || top.isLearned { return top }
        guard names(said, top) else { return nil }
        if results.dropFirst().contains(where: { names(said, $0) }) { return nil }
        return top
    }

    static func isSafe(_ item: Item) -> Bool {
        guard !item.needsConfirm else { return false }
        switch item.kind {
        case .app, .setting: return true
        // A move that names its app ("move Safari to the left half") is undoable; "this window" depends on focus.
        case .window: return item.id.hasPrefix("window:") || item.id.hasPrefix("tile-app:")
        case .action: return safeActions.contains(item.id)
        default: return false
        }
    }

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
        // The recognizer can hear "TextEdit" as "text edit".
        return core == title || core.replacingOccurrences(of: " ", with: "") == title.replacingOccurrences(of: " ", with: "")
    }
}
