import Foundation

enum BeeLabel {
    static let maxLength = 44

    static func text(for item: Item) -> String {
        shorten(item.verb.isEmpty ? item.title : "\(item.verb) \(item.title)")
    }

    static func text(for step: PlanStep) -> String {
        var text = step.text
        for prefix in ["In the current window only, ", "In the current app only, run its menu command "] where text.hasPrefix(prefix) {
            text = String(text.dropFirst(prefix.count))
            if prefix.hasSuffix("command ") {
                text = "Run " + (text.components(separatedBy: " › ").last ?? text)
            }
        }
        text = text.replacingOccurrences(of: #" the [a-z -]+ "([^"]*)"$"#, with: " $1", options: .regularExpression)
        return shorten(text.prefix(1).uppercased() + text.dropFirst())
    }

    static func shorten(_ text: String) -> String {
        let flat = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return flat.count <= maxLength ? flat : String(flat.prefix(maxLength - 1)) + "…"
    }
}
