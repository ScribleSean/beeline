import Foundation

enum Matcher {
    struct Parsed {
        var tokens: [String]
        var hint: Kind?
        var direction: String?
        var text = ""
    }

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

    static func isQuestion(_ query: String) -> Bool {
        let words = query.lowercased().split(separator: " ")
        guard words.count >= 3 || query.hasSuffix("?") else { return false }
        let openers: Set<Substring> = ["how", "what", "what's", "whats", "why", "who", "who's", "when", "where", "which",
                                       "is", "are", "can", "does", "do", "did", "will", "should", "define", "explain"]
        return query.hasSuffix("?") || openers.contains(words[0])
    }

    static let quitWords: Set<String> = ["quit", "close", "exit", "kill", "stop"]

    static func fold(_ text: String) -> String {
        text.utf8.allSatisfy { $0 < 128 } ? text.lowercased() : text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    static func parse(_ query: String) -> Parsed {
        let words = fold(query)
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
        var parsed = Parsed(tokens: [], hint: nil)
        parsed.text = words.joined(separator: " ")
        for word in words {
            if word == "on" || word == "off" { parsed.direction = word }
            if let kind = hints[word] {
                parsed.hint = kind
            } else if !filler.contains(word) {
                parsed.tokens.append(word)
            }
        }
        if parsed.tokens.isEmpty { parsed.tokens = words }
        return parsed
    }

    struct Score {
        var value: Int
        var isComplete: Bool
        var timesLearned = 0
        var isAlias = false
    }

    static func score(_ item: Item, _ parsed: Parsed, anyWord: Bool = false) -> Score? {
        let title = fold(item.title)
        let titleWords = words(title)
        let keywordWords = words(fold(item.keywords))
        let subtitle = fold(item.subtitle)

        var total = 0
        var solid = 0
        var missed = 0
        var inTitle = 0
        var wordInTitle = false
        let keywordMatches: (String) -> Bool = item.needsConfirm
            ? { token in keywordWords.contains(token) }
            : { token in keywordWords.contains(where: { $0.hasPrefix(token) }) }
        for token in parsed.tokens {
            if title.hasPrefix(token) {
                total += 100
                solid += 1
                inTitle += 1
                wordInTitle = wordInTitle || token.count >= 3
            } else if titleWords.contains(where: { $0.hasPrefix(token) }) {
                total += 60
                solid += 1
                inTitle += 1
                wordInTitle = wordInTitle || token.count >= 3
            } else if title.contains(token) {
                total += 40
                solid += 1
                inTitle += 1
                wordInTitle = wordInTitle || token.count >= 3
            } else if keywordMatches(token) {
                total += 30
                solid += 1
            } else if subtitle.contains(token) {
                total += 15
            } else if token.count >= 3, title.count <= 24, [Kind.app, .setting, .action].contains(item.kind),
                      !item.needsConfirm, isSubsequence(token, of: title) {
                total += 8
            } else {
                missed += 1
                if !anyWord { total -= 30 }
            }
        }
        if !parsed.text.isEmpty, item.phrases.contains(where: { parsed.text == fold($0) || parsed.text.hasPrefix(fold($0) + " ") }) {
            total += 200
            solid = parsed.tokens.count
            missed = 0
        }
        if anyWord {
            guard solid > 0 else { return nil }
        } else if missed > 0 {
            guard solid > 0, solid * 2 >= parsed.tokens.count else { return nil }
        }
        if title == parsed.tokens.joined(separator: " ") { total += 40 }
        if let direction = parsed.direction {
            if titleWords.contains(direction) { total += 40 } else if titleWords.contains(direction == "on" ? "off" : "on") { total -= 50 }
        }
        if let hint = parsed.hint, hint == item.kind { total += 50 }
        if item.kind == .action, wordInTitle, item.id != "action:Beeline Settings" { total += 15 }
        if item.kind == .app { total += 10 }
        if item.kind == .menu { total -= 5 }
        if item.kind == .control { total -= 10 }
        total -= min(title.count, 40) / 4
        return Score(value: total, isComplete: missed == 0)
    }

    static func matchesForClose(_ item: Item, _ typed: [String]) -> Bool {
        let haystack = words(fold(item.title)) + words(fold(item.keywords))
        return typed.allSatisfy { word in
            haystack.contains { word.count >= 3 ? $0.hasPrefix(word) : $0 == word }
        }
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
