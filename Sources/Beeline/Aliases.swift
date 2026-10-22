import Foundation

/// Your own short words for things: type "t", select Music, press ⇧⌘A, and "t" opens Music from then on,
/// ranked above everything. Unlike a learned pick, an alias never fades. Stored on this Mac only.
final class Aliases {
    struct Entry: Codable, Equatable {
        /// The item it stands for, as `Usage.key(for:)` names it, so it survives relaunches.
        let key: String
        /// What the item was called when the alias was made, for the Settings list.
        let title: String
    }

    /// The app's one store. Tests make their own with `init(file:)`.
    static let shared = Aliases()

    private(set) var entries: [String: Entry] = [:]
    private let file: URL
    private let saveQueue = DispatchQueue(label: "beeline.aliases", qos: .userInitiated)

    convenience init() {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Beeline", isDirectory: true)
        self.init(file: ProcessInfo.processInfo.environment["BEELINE_ALIASES_FILE"].map { URL(fileURLWithPath: $0) }
            ?? folder.appendingPathComponent("aliases.json"))
    }

    init(file: URL) {
        self.file = file
        entries = JSONStore.read([String: Entry].self, from: file, name: "aliases") ?? [:]
    }

    /// The words an alias is stored under: lower case, single spaces. Nil for nothing usable.
    static func normalise(_ text: String) -> String? {
        let words = Usage.normalise(text)
        return words.isEmpty || words.count > 30 ? nil : words
    }

    /// Makes the typed words an alias for the item, replacing whatever they stood for before.
    @discardableResult
    func set(_ text: String, for item: Item) -> Bool {
        guard let alias = Self.normalise(text) else { return false }
        entries[alias] = Entry(key: Usage.key(for: item), title: item.title)
        save()
        return true
    }

    func remove(_ alias: String) {
        guard let alias = Self.normalise(alias) else { return }
        entries[alias] = nil
        save()
    }

    /// True when exactly these words are an alias for this item.
    func matches(_ text: String, _ item: Item) -> Bool {
        guard let alias = Self.normalise(text), let entry = entries[alias] else { return false }
        return entry.key == Usage.key(for: item)
    }

    /// The alias pointing at this item for these words, if any.
    func alias(for text: String, item: Item) -> String? {
        matches(text, item) ? Self.normalise(text) : nil
    }

    func flush() {
        saveQueue.sync {}
    }

    private func save() {
        let snapshot = entries
        saveQueue.async { [file] in
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let data = try? JSONEncoder().encode(snapshot) { try? data.write(to: file, options: .atomic) }
        }
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }

    static let changed = Notification.Name("BeelineAliasesChanged")
}
