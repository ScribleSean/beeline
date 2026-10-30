import AppKit

/// What VoiceOver hears. Focus stays in the search field and the bee's panel ignores the mouse,
/// so changes are spoken as they happen rather than waiting to be found.
enum Announce {
    static var post: (String, NSAccessibilityPriorityLevel) -> Void = { text, priority in
        DemoLog.note("announcement", ["text": text, "priority": priority.rawValue])
        NSAccessibility.post(element: NSApplication.shared, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: priority.rawValue])
    }

    /// High is for what needs an answer (a confirm question, a plan, a problem); rows and bee steps use medium.
    static func say(_ text: String, priority: NSAccessibilityPriorityLevel = .medium) {
        guard !text.isEmpty else { return }
        post(text, priority)
    }

    /// Spoken without being asked, so it never reads out copied or selected text; the row's own label still does.
    static func spoken(_ item: Item, number: Int = 1) -> String {
        if item.kind == .clipboard {
            return ["Paste clipboard item \(number)", item.subtitle].filter { !$0.isEmpty }.joined(separator: ", ")
        }
        if item.id == BarModel.rewriteRowID { return item.title }
        return row(item)
    }

    static func row(_ item: Item) -> String {
        var parts = [item.verb.isEmpty ? item.title : "\(item.verb) \(item.title)"]
        if !item.subtitle.isEmpty { parts.append(item.subtitle) }
        if item.isGuess {
            parts.append("best guess")
        } else if item.isAlias {
            parts.append("your alias")
        } else if item.isLearned {
            parts.append("learned")
        }
        return parts.joined(separator: ", ")
    }

    /// What the bee says as it acts: the full action, but never copied text.
    static func action(_ item: Item) -> String {
        if item.kind == .clipboard { return "Paste clipboard item" }
        return item.verb.isEmpty ? item.title : "\(item.verb) \(item.title)"
    }

    static func confirm(_ item: Item) -> String {
        "\(item.confirmQuestion) \(item.confirmSummary)"
    }

    static func plan(_ plan: Plan) -> String {
        let count = plan.steps.count == 1 ? "1 step" : "\(plan.steps.count) steps"
        let steps = plan.steps.map { step in
            let text = step.displayText
            return text.hasSuffix(".") ? text : text + "."
        }
        return "\(count): \(steps.joined(separator: " "))"
    }
}

enum BarSurface {
    /// Frosted glass loses its edge against busy backgrounds; these settings ask for a solid panel.
    static func isSolid(increaseContrast: Bool, reduceTransparency: Bool) -> Bool {
        increaseContrast || reduceTransparency
    }
}

extension Item {
    var confirmQuestion: String { "\(verb.isEmpty ? "" : verb + " ")\(title)?" }

    var confirmSummary: String {
        if id == "action:Empty Trash",
           let names = try? FileManager.default.contentsOfDirectory(atPath: NSHomeDirectory() + "/.Trash") {
            let count = names.filter { !$0.hasPrefix(".") }.count
            return count == 1 ? "1 item will be deleted permanently." : "\(count) items will be deleted permanently."
        }
        if id == "action:Eject All Disks" { return Actions.ejectSummary(Actions.ejectableDisks().map(\.name)) }
        return confirmNote ?? "This can't be undone."
    }
}
