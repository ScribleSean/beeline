import Foundation

/// Turns what was typed into search words plus a hint about the kind of thing wanted,
/// then scores items against it. No model involved: this is the instant layer.
enum Matcher {
    struct Parsed {
        var tokens: [String]
        var hint: Kind?
    }

    /// Words that carry intent but should not have to appear in a title.
    private static let filler: Set<String> = [
        "go", "to", "the", "a", "an", "my", "with", "open", "show", "me", "switch", "find", "please",
        "for", "in", "on", "of", "that", "this", "take", "jump", "launch", "start", "change", "turn",
        "every", "all", "each", "about", "matching", "any", "move",
        "i", "need", "want", "do", "let", "is", "are", "it", "too", "so", "some", "something", "can",
        "you", "get", "make", "be", "set", "put", "mac", "computer", "laptop", "am", "im", "would", "like", "and", "or", "at", "from", "up", "how",
    ]
    private static let hints: [String: Kind] = [
        "tab": .tab, "tabs": .tab, "page": .tab, "website": .tab, "site": .tab,
        "setting": .setting, "settings": .setting, "preferences": .setting, "prefs": .setting,
        "app": .app, "application": .app,
        "window": .window, "windows": .window,
        "menu": .menu, "command": .menu,
        "button": .control, "buttons": .control, "checkbox": .control, "field": .control, "textbox": .control,
        "file": .file, "files": .file, "folder": .file, "folders": .file, "document": .file, "documents": .file,
    ]

    /// Typing one of these is what makes the "Quit Safari" rows appear.
    static let quitWords: Set<String> = ["quit", "close", "exit", "kill", "stop"]

    static func parse(_ query: String) -> Parsed {
        let words = query.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
        var parsed = Parsed(tokens: [], hint: nil)
        for word in words {
            if let kind = hints[word] {
                parsed.hint = kind
            } else if !filler.contains(word) {
                parsed.tokens.append(word)
            }
        }
        // "settings" or "open" on its own should still find something.
        if parsed.tokens.isEmpty { parsed.tokens = words }
        return parsed
    }

    struct Score {
        var value: Int
        /// False when some typed words matched nothing, which makes the item a guess.
        var isComplete: Bool
        /// How many times this item was picked before for exactly these words. Zero when never.
        var timesLearned = 0
    }

    /// Nil when the item is unrelated. An item can still match with some words unaccounted for,
    /// as long as most of them landed solidly: "save battery" finds Battery.
    /// With `anyWord`, one solid word is enough and misses cost nothing. Used for the model's keywords,
    /// which describe the target loosely and are never all expected to appear.
    static func score(_ item: Item, _ parsed: Parsed, anyWord: Bool = false) -> Score? {
        let title = item.title.lowercased()
        let titleWords = words(title)
        let keywordWords = words(item.keywords.lowercased())
        let subtitle = item.subtitle.lowercased()

        var total = 0
        var solid = 0
        var missed = 0
        var inTitle = 0
        for token in parsed.tokens {
            if title.hasPrefix(token) {
                total += 100
                solid += 1
                inTitle += 1
            } else if titleWords.contains(where: { $0.hasPrefix(token) }) {
                total += 60
                solid += 1
                inTitle += 1
            } else if title.contains(token) {
                total += 40
                solid += 1
                inTitle += 1
            } else if keywordWords.contains(where: { $0.hasPrefix(token) }) {
                total += 30
                solid += 1
            } else if subtitle.contains(token) {
                total += 15
            // Letters typed out of order or with gaps ("sfri" for Safari) only count against short names.
            // In a long tab or file title they turn up by chance and bring in unrelated results.
            } else if token.count >= 3, title.count <= 24, isSubsequence(token, of: title) {
                total += 8
            } else {
                missed += 1
                if !anyWord { total -= 30 }
            }
        }
        if anyWord {
            guard solid > 0 else { return nil }
        } else if missed > 0 {
            // A partial match needs real words behind it, and at least half of what was typed.
            guard solid > 0, solid * 2 >= parsed.tokens.count else { return nil }
        }
        // Typing a name in full beats longer names that merely start with it.
        if title == parsed.tokens.joined(separator: " ") { total += 40 }
        if let hint = parsed.hint, hint == item.kind { total += 50 }
        // On a tie, an app beats a menu command with the same name.
        // "sleep" and "lock" mean the action, not the settings pane of the same name. An action found
        // only through its keywords gets no lift: plain "wifi" should open Wi-Fi settings, not turn it off.
        if item.kind == .action, inTitle > 0, item.id != "action:Beeline Settings" { total += 15 }
        if item.kind == .app { total += 10 }
        if item.kind == .menu { total -= 5 }
        // A button sharing a name with an app or setting is the less likely meaning.
        if item.kind == .control { total -= 10 }
        // Prefer the tighter match: "Notes" over "Notes Helper Tool".
        total -= min(title.count, 40) / 4
        return Score(value: total, isComplete: missed == 0)
    }

    private static func words(_ text: String) -> [String] {
        text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }

    private static func isSubsequence(_ needle: String, of haystack: String) -> Bool {
        var remaining = needle[...]
        for character in haystack where character == remaining.first {
            remaining = remaining.dropFirst()
            if remaining.isEmpty { return true }
        }
        return remaining.isEmpty
    }
}
