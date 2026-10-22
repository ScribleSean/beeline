import Foundation

enum Calculator {
    private static let notASum = try! Regex(#"^\s*(\d{4}[-/]\d{1,2}[-/]\d{1,2}|\d{1,2}[-/]\d{1,2}[-/]\d{2,4}|\+[\d\s()-]+|\(\d+\)[\d\s-]+)\s*$"#)

    static func evaluate(_ text: String) -> Double? {
        if text.firstMatch(of: notASum) != nil { return nil }
        let cleaned = text.lowercased()
            .replacingOccurrences(of: "×", with: "*")
            .replacingOccurrences(of: "÷", with: "/")
            .replacingOccurrences(of: " of ", with: "*")
        let numbers = Self.decimalPoints(cleaned).replacingOccurrences(of: ",", with: "").filter { !$0.isWhitespace }
        guard numbers.count <= 200, numbers.contains(where: \.isNumber),
              numbers.contains(where: { "+-*/^%x".contains($0) }),
              numbers.allSatisfy({ $0.isNumber || "+-*/^%x().".contains($0) }) else { return nil }

        var parser = Parser(characters: Array(numbers))
        guard let value = parser.expression(), parser.isAtEnd, value.isFinite else { return nil }
        return value
    }

    static func answer(_ text: String) -> Answer? {
        guard let value = evaluate(text) else { return nil }
        let sum = text.replacingOccurrences(of: "*", with: " × ").replacingOccurrences(of: "/", with: " ÷ ")
            .split(separator: " ").joined(separator: " ")
        return Answer(label: "Calculation", value: format(value), detail: "\(sum) =")
    }

    static func decimalPoints(_ text: String) -> String {
        var text = text
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
