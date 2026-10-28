import Foundation

enum ScreenText {
    /// External app text must not hide characters or introduce prompt structure.
    static func sanitize(_ text: String) -> String {
        let scalars = Array(text.unicodeScalars.map { scalar -> Unicode.Scalar in
            switch scalar.value {
            case 0x09, 0x0A, 0x0D, 0x2028, 0x2029: return " "
            default: return scalar
            }
        })
        func isVisible(_ scalar: Unicode.Scalar) -> Bool {
            guard !scalar.properties.isWhitespace else { return false }
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator: return false
            default: return true
            }
        }
        var result = String.UnicodeScalarView()
        for (index, scalar) in scalars.enumerated() {
            if scalar == " " {
                if result.last != " " { result.append(scalar) }
            } else if scalar.value == 0x200C || scalar.value == 0x200D {
                // Check original neighbours so stripping hidden text cannot legitimise a joiner.
                if index > 0, index + 1 < scalars.count,
                   isVisible(scalars[index - 1]), isVisible(scalars[index + 1]) {
                    result.append(scalar)
                }
            } else {
                switch scalar.properties.generalCategory {
                case .control, .format, .lineSeparator, .paragraphSeparator: break
                default: result.append(scalar)
                }
            }
        }
        return String(result)
    }

    /// Undo only the planner's quote/backslash escapes for the confirmation card.
    static func display(_ text: String) -> String {
        var result = ""
        var characters = text.makeIterator()
        while let character = characters.next() {
            if character == "\\", let next = characters.next() {
                if next != "\\" && next != "\"" { result.append(character) }
                result.append(next)
            } else {
                result.append(character)
            }
        }
        return result
    }

    /// A quoted string literal: escape backslashes before escaping its delimiters.
    static func quote(_ text: String) -> String {
        "\"" + sanitize(text)
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
