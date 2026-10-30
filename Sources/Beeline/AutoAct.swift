import AppKit

enum AutoAct {
    static let safeActions: Set<String> = ["action:Mute", "action:Unmute", "action:Volume Up", "action:Volume Down",
                                           "action:Toggle Dark Mode", "action:Mission Control"]

    /// How long a voice result waits before running by itself. VoiceOver needs time to say what is about to
    /// run and the user time to press Escape after hearing it.
    static func window(voiceOver: Bool) -> TimeInterval { voiceOver ? 3 : 0.7 }

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
        case .window: return item.id.hasPrefix("window:")
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
        return core == title
    }
}
