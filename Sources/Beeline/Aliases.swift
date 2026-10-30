import Foundation

final class Aliases {
    struct Entry: Codable, Equatable {
        let key: String
        let title: String
    }

    static let shared = Aliases()

    private var stored: [String: Entry] = [:]
    private let lock = NSLock()
    let file: URL

    var entries: [String: Entry] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
    private let saveQueue = DispatchQueue(label: "beeline.aliases", qos: .userInitiated)

    convenience init() {
        self.init(file: ProcessInfo.processInfo.environment["BEELINE_ALIASES_FILE"].map { URL(fileURLWithPath: $0) }
            ?? TestRun.supportFolder.appendingPathComponent("aliases.json"))
    }

    init(file: URL) {
        self.file = file
        stored = JSONStore.read([String: Entry].self, from: file, name: "aliases") ?? [:]
    }

    static func normalise(_ text: String) -> String? {
        let words = Usage.normalise(text)
        return words.isEmpty || words.count > 30 ? nil : words
    }

    @discardableResult
    func set(_ text: String, for item: Item) -> Bool {
        guard let alias = Self.normalise(text) else { return false }
        lock.lock()
        stored[alias] = Entry(key: Usage.key(for: item), title: item.title)
        lock.unlock()
        save()
        return true
    }

    func remove(_ alias: String) {
        guard let alias = Self.normalise(alias) else { return }
        lock.lock()
        stored[alias] = nil
        lock.unlock()
        save()
    }

    func matches(_ text: String, _ item: Item) -> Bool {
        guard let alias = Self.normalise(text), let entry = entries[alias] else { return false }
        return entry.key == Usage.key(for: item)
    }

    func alias(for text: String, item: Item) -> String? {
        matches(text, item) ? Self.normalise(text) : nil
    }

    func flush() {
        saveQueue.sync {}
    }

    private func save() {
        let snapshot = entries
        saveQueue.async { [file] in
            try? JSONStore.createPrivateDirectory(file.deletingLastPathComponent())
            if let data = try? JSONEncoder().encode(snapshot) { try? data.write(to: file, options: .atomic) }
        }
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }

    static let changed = Notification.Name("BeelineAliasesChanged")
}
