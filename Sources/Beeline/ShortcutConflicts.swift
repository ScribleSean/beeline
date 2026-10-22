import Foundation

/// macOS keeps its own keyboard shortcuts in the com.apple.symbolichotkeys preferences, readable without
/// any permission; another app's shortcut (Alfred, Raycast) isn't listed there.
enum ShortcutConflicts {
    struct Holder: Equatable {
        let section: String
        let name: String
    }

    private static let known: [Int: Holder] = [
        64: Holder(section: "Spotlight", name: "Show Spotlight search"),
        65: Holder(section: "Spotlight", name: "Show Finder search window"),
        60: Holder(section: "Input Sources", name: "Select the previous input source"),
        61: Holder(section: "Input Sources", name: "Select next source in Input menu"),
    ]

    private static let flags: [String: Int] = ["command": 1 << 20, "option": 1 << 19, "control": 1 << 18]

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

    static func current(for modifier: String) -> [Holder] {
        let hotkeys = UserDefaults(suiteName: "com.apple.symbolichotkeys")?.dictionary(forKey: "AppleSymbolicHotKeys") ?? [:]
        return holders(of: modifier, in: withDefaults(hotkeys))
    }

    /// A Mac whose Spotlight shortcut was never changed may have no entry for it: then it is the default,
    /// ⌘Space, switched on.
    static func withDefaults(_ hotkeys: [String: Any]) -> [String: Any] {
        var hotkeys = hotkeys
        if hotkeys["64"] == nil {
            hotkeys["64"] = ["enabled": 1, "value": ["parameters": [32, 49, 1 << 20], "type": "standard"]] as [String: Any]
        }
        return hotkeys
    }
}
