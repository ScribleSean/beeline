import AppKit

enum AutoAct {
    static let safeActions: Set<String> = ["action:Mute", "action:Unmute", "action:Volume Up", "action:Volume Down",
                                           "action:Toggle Dark Mode", "action:Mission Control"]

    private static let sightedWait: TimeInterval = 0.7
    private static let shortestVoiceOverWait: TimeInterval = 3
    private static let voiceOverLeadIn: TimeInterval = 0.4
    private static let voiceOverCharactersPerSecond = 14.0
    private static let timeToPressEscape: TimeInterval = 1.5

    static func window(voiceOver: Bool, spoken: String) -> TimeInterval {
        guard voiceOver else { return sightedWait }
        let speaking = voiceOverLeadIn + Double(spoken.count) / voiceOverCharactersPerSecond
        return max(shortestVoiceOverWait, speaking + timeToPressEscape)
    }

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
