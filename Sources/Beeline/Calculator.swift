import Foundation

/// Evaluates arithmetic typed into the bar: "12 * (8 + 2)", "2^10", "15% of 234".
/// A small hand-written parser, so malformed input returns nil instead of crashing.
enum Calculator {
    /// Nil unless the text is a complete expression with at least one operator.
    /// Dates and phone numbers: digits joined by "-" or "/" in date shapes, or with brackets or a leading "+".
    private static let notASum = try! Regex(#"^\s*(\d{4}[-/]\d{1,2}[-/]\d{1,2}|\d{1,2}[-/]\d{1,2}[-/]\d{2,4}|\+[\d\s()-]+|\(\d+\)[\d\s-]+)\s*$"#)

    static func evaluate(_ text: String) -> Double? {
        // "2024-01-15" is a day, not 2,008, and a phone number is not a subtraction.
        if text.firstMatch(of: notASum) != nil { return nil }
        let cleaned = text.lowercased()
            .replacingOccurrences(of: "×", with: "*")
            .replacingOccurrences(of: "÷", with: "/")
            .replacingOccurrences(of: " of ", with: "*")
        let numbers = Self.decimalPoints(cleaned).replacingOccurrences(of: ",", with: "").filter { !$0.isWhitespace }
        // Long or deeply nested input is refused rather than risk running out of stack.
        guard numbers.count <= 200, numbers.contains(where: \.isNumber),
              numbers.contains(where: { "+-*/^%x".contains($0) }),
              numbers.allSatisfy({ $0.isNumber || "+-*/^%x().".contains($0) }) else { return nil }

        var parser = Parser(characters: Array(numbers))
        guard let value = parser.expression(), parser.isAtEnd, value.isFinite else { return nil }
        return value
    }

    /// The result as an answer for the bar, with the sum written out underneath.
    static func answer(_ text: String) -> Answer? {
        guard let value = evaluate(text) else { return nil }
        let sum = text.replacingOccurrences(of: "*", with: " × ").replacingOccurrences(of: "/", with: " ÷ ")
            .split(separator: " ").joined(separator: " ")
        return Answer(label: "Calculation", value: format(value), detail: "\(sum) =")
    }

    /// Commas as people type them: "1,500" and "1,234,567" group thousands, while "2,5" and "2,50" are
    /// decimal commas, as most of Europe writes them (L7). A comma followed by exactly three digits groups;
    /// any other comma between digits is a decimal point.
    static func decimalPoints(_ text: String) -> String {
        var text = text
        // Repeated, because "1,234,567" groups twice and each pass sees one comma at a time.
        while true {
            let next = text.replacingOccurrences(of: #"(\d),(\d{3})(?!\d)"#, with: "$1$2", options: .regularExpression)
            if next == text { break }
            text = next
        }
        return text.replacingOccurrences(of: #"(\d),(\d)"#, with: "$1.$2", options: .regularExpression)
    }

    static func format(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        if value != 0, abs(value) < 0.0001 {
            // A tiny answer keeps its meaningful digits instead of showing, and copying, as 0 (L7).
            formatter.numberStyle = .scientific
            formatter.maximumSignificantDigits = 6
            formatter.usesSignificantDigits = true
        } else {
            formatter.maximumFractionDigits = 8
        }
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    private struct Parser {
        let characters: [Character]
        var position = 0

        var isAtEnd: Bool { position == characters.count }
        /// Nesting so far. Parentheses, minus signs and powers each add one, and past 40 the input is refused.
        private var depth = 0

        private mutating func take(_ options: String) -> Character? {
            guard position < characters.count, options.contains(characters[position]) else { return nil }
            position += 1
            return characters[position - 1]
        }

        mutating func expression() -> Double? {
            guard var value = term() else { return nil }
            while let sign = take("+-") {
                guard let next = term() else { return nil }
                value = sign == "+" ? value + next : value - next
            }
            return value
        }

        private mutating func term() -> Double? {
            guard var value = unary() else { return nil }
            while let sign = take("*/x") {
                guard let next = unary() else { return nil }
                value = sign == "/" ? value / next : value * next
            }
            return value
        }

        /// Minus applies after the power, as in written maths: -2^2 is -4.
        private mutating func unary() -> Double? {
            depth += 1
            defer { depth -= 1 }
            guard depth <= 40 else { return nil }
            if take("-") != nil { return unary().map { -$0 } }
            return power()
        }

        private mutating func power() -> Double? {
            guard let base = primary() else { return nil }
            guard take("^") != nil else { return base }
            // Right-associative, and the exponent may be negative: 2^-1 is 0.5, 2^3^2 is 2^(3^2).
            guard let exponent = unary() else { return nil }
            return pow(base, exponent)
        }

        private mutating func primary() -> Double? {
            var value: Double
            if take("(") != nil {
                depth += 1
                defer { depth -= 1 }
                guard depth <= 40, let inner = expression(), take(")") != nil else { return nil }
                value = inner
            } else {
                let start = position
                while position < characters.count, characters[position].isNumber || characters[position] == "." { position += 1 }
                guard let number = Double(String(characters[start..<position])) else { return nil }
                value = number
            }
            if take("%") != nil { value /= 100 }
            return value
        }
    }
}
