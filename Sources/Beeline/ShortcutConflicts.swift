import Foundation

/// What holds ⌘Space (or the other shortcut chosen) when Beeline can't have it, so the welcome screen can
/// say exactly what to switch off. macOS keeps its own keyboard shortcuts in the
/// com.apple.symbolichotkeys preferences, readable without any permission; another app's shortcut
/// (Alfred, Raycast) isn't listed there, so then the answer is "another app".
enum ShortcutConflicts {
    struct Holder: Equatable {
        /// Where it lives in System Settings › Keyboard › Keyboard Shortcuts.
        let section: String
        /// The shortcut's name there.
        let name: String
    }

    /// The system shortcuts that can use Space, by their number in the preferences.
    private static let known: [Int: Holder] = [
        64: Holder(section: "Spotlight", name: "Show Spotlight search"),
        65: Holder(section: "Spotlight", name: "Show Finder search window"),
        60: Holder(section: "Input Sources", name: "Select the previous input source"),
        61: Holder(section: "Input Sources", name: "Select next source in Input menu"),
    ]

    /// The modifier flags macOS stores for each choice of Beeline's shortcut.
    private static let flags: [String: Int] = ["command": 1 << 20, "option": 1 << 19, "control": 1 << 18]

    /// The switched-on system shortcuts that are Space with exactly this modifier.
    static func holders(of modifier: String, in hotkeys: [String: Any]) -> [Holder] {
        guard let wanted = flags[modifier] else { return [] }
        return known.keys.sorted().compactMap { number in
            guard let entry = hotkeys[String(number)] as? [String: Any],
                  (entry["enabled"] as? Int ?? (entry["enabled"] as? Bool == true ? 1 : 0)) == 1,
                  let value = entry["value"] as? [String: Any],
                  let parameters = value["parameters"] as? [Int], parameters.count == 3,
                  parameters[1] == 49, parameters[2] == wanted else { return nil }
            return known[number]
        }
    }

    /// The holders on this Mac now.
    static func current(for modifier: String) -> [Holder] {
        let hotkeys = UserDefaults(suiteName: "com.apple.symbolichotkeys")?.dictionary(forKey: "AppleSymbolicHotKeys") ?? [:]
        return holders(of: modifier, in: hotkeys)
    }
}
