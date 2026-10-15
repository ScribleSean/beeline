import Foundation

/// Evaluates arithmetic typed into the bar: "12 * (8 + 2)", "2^10", "15% of 234".
/// A small hand-written parser, so malformed input returns nil instead of crashing.
enum Calculator {
    /// Nil unless the text is a complete expression with at least one operator.
    static func evaluate(_ text: String) -> Double? {
        let cleaned = text.lowercased()
            .replacingOccurrences(of: "×", with: "*")
            .replacingOccurrences(of: "÷", with: "/")
            .replacingOccurrences(of: " of ", with: "*")
            .replacingOccurrences(of: ",", with: "")
            .filter { !$0.isWhitespace }
        guard cleaned.contains(where: \.isNumber),
              cleaned.contains(where: { "+-*/^%x".contains($0) }),
              cleaned.allSatisfy({ $0.isNumber || "+-*/^%x().".contains($0) }) else { return nil }

        var parser = Parser(characters: Array(cleaned))
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

    static func format(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 8
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    private struct Parser {
        let characters: [Character]
        var position = 0

        var isAtEnd: Bool { position == characters.count }

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
            guard var value = power() else { return nil }
            while let sign = take("*/x") {
                guard let next = power() else { return nil }
                value = sign == "/" ? value / next : value * next
            }
            return value
        }

        private mutating func power() -> Double? {
            guard let base = unary() else { return nil }
            guard take("^") != nil else { return base }
            // Right-associative: 2^3^2 is 2^(3^2).
            guard let exponent = power() else { return nil }
            return pow(base, exponent)
        }

        private mutating func unary() -> Double? {
            if take("-") != nil { return unary().map { -$0 } }
            return primary()
        }

        private mutating func primary() -> Double? {
            var value: Double
            if take("(") != nil {
                guard let inner = expression(), take(")") != nil else { return nil }
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
