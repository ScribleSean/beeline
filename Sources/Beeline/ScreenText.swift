import Foundation

enum ScreenText {
    /// External app text must not hide characters or introduce prompt structure.
    static func sanitize(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.filter {
            switch $0.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator: return false
            default: return true
            }
        }))
    }

    /// A quoted string literal: escape backslashes before escaping its delimiters.
    static func quote(_ text: String) -> String {
        "\"" + sanitize(text)
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
