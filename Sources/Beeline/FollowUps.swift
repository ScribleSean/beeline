import Foundation

/// Short spoken follow-ups Beeline answers on its own, without asking Claude.
enum FollowUpCommand: Equatable {
    case undo, otherWindow

    private static let leadIns = ["now", "and", "ok", "okay", "then"]
    private static let undoPhrases: Set<String> = ["undo", "undo that", "undo it", "take that back", "put it back", "revert"]
    private static let windowLeadIns = ["switch back to", "switch to", "go back to", "go to", "back to"]
    private static let windowPhrases: Set<String> = ["the other window", "other window", "the previous window", "previous window"]

    static func parse(_ spoken: String) -> FollowUpCommand? {
        // Speech adds punctuation and capitals: "Undo that." or "Now, the other window."
        let words = spoken.lowercased().components(separatedBy: CharacterSet.letters.inverted.subtracting(.whitespaces))
            .joined().split(separator: " ").map(String.init)
        var said = words.drop { leadIns.contains($0) }.joined(separator: " ")
        if undoPhrases.contains(said) { return .undo }
        for lead in windowLeadIns where said.hasPrefix(lead + " ") {
            said = String(said.dropFirst(lead.count + 1))
            break
        }
        return windowPhrases.contains(said) ? .otherWindow : nil
    }
}

/// Remembers the focused window from each screen scan, so "the other window" can go back to the one before.
final class WindowHistory {
    private struct Key: Equatable {
        let app: String
        let title: String
        init(_ window: Item) { app = window.subtitle; title = window.title }
    }

    private let lock = NSLock()
    private var current: Key?
    private var previous: Key?

    func saw(_ windows: [Item]) {
        guard let focused = windows.first(where: \.isCurrentWindow).map(Key.init) else { return }
        lock.lock()
        if focused != current {
            previous = current
            current = focused
        }
        lock.unlock()
    }

    func other(in windows: [Item]) -> Item? {
        lock.lock()
        let wanted = previous
        lock.unlock()
        guard let wanted else { return nil }
        return windows.first { Key($0) == wanted }
    }
}
