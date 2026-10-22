import Foundation

/// Remembers what was picked, so frequent choices rank higher and a request that needed the model
/// once is answered instantly the next time. Stored only on this Mac, in Application Support.
final class Usage {
    private struct Entry: Codable {
        var count: Int
        var last: Date
    }

    private struct Store: Codable {
        /// How often and how recently each item was picked.
        var items: [String: Entry] = [:]
        /// For each thing typed, the items picked for it and how many times.
        var queries: [String: [String: Int]] = [:]
        /// When each of those was last picked. Optional, so history saved before it existed still loads;
        /// a pick with no date counts as fresh until it is picked again.
        var queryLast: [String: [String: Date]]?
    }

    /// A pick not repeated for this long stops ranking first for its words, as Alfred's does: habits
    /// change, and an old pick must not hold the top spot for good.
    static let pickLifetime: TimeInterval = 28 * 86_400

    private var store = Store()
    private let file: URL
    private let saveQueue = DispatchQueue(label: "beeline.usage", qos: .userInitiated)

    convenience init() {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Beeline", isDirectory: true)
        // Tests point this at a scratch file so they never touch real history.
        self.init(file: ProcessInfo.processInfo.environment["BEELINE_USAGE_FILE"].map { URL(fileURLWithPath: $0) }
            ?? folder.appendingPathComponent("usage.json"))
    }

    init(file: URL) {
        self.file = file
        if let saved = JSONStore.read(Store.self, from: file, name: "usage") {
            store = saved
        }
    }

    /// A name for the item that survives relaunches. Tabs, windows and menu commands get new ids
    /// every time they are read, so those are keyed by where they live and what they are called.
    static func key(for item: Item) -> String {
        switch item.kind {
        case .app, .setting, .action, .file, .calculation, .clipboard:
            return item.id.hasPrefix("quit:") ? "quit:" + item.title : item.id
        case .tab:
            return "tab:\(item.keywords):\(item.title)"
        case .window:
            return "window:\(item.subtitle):\(item.title)"
        case .menu:
            return "menu:\(item.subtitle):\(item.title)"
        case .control:
            return "control:\(item.keywords):\(item.title)"
        }
    }

    static func normalise(_ query: String) -> String {
        query.lowercased().split(separator: " ").joined(separator: " ")
    }

    func record(_ item: Item, query: String) {
        let key = Self.key(for: item)
        store.items[key] = Entry(count: (store.items[key]?.count ?? 0) + 1, last: Date())
        let typed = Self.normalise(query)
        if !typed.isEmpty {
            store.queries[typed, default: [:]][key, default: 0] += 1
            var dates = store.queryLast ?? [:]
            dates[typed, default: [:]][key] = Date()
            store.queryLast = dates
        }
        // Keep the file small: once it grows, the items not picked for 90 days go, then any phrase whose
        // items have all gone. New phrases can always be learned.
        if store.queries.count > 1000 || store.items.count > 3000 {
            let cutoff = Date().addingTimeInterval(-90 * 86_400)
            store.items = store.items.filter { $0.value.last > cutoff }
            store.queries = store.queries.compactMapValues { picks in
                let kept = picks.filter { store.items[$0.key] != nil }
                return kept.isEmpty ? nil : kept
            }
            store.queryLast = store.queryLast?.filter { store.queries[$0.key] != nil }
        }
        save()
    }

    /// Stops this item ranking first for these words: the "Forget this pick" action, for a pick that was
    /// wrong or is no longer wanted. What was learned for other words stays.
    func forget(_ item: Item, for query: String) {
        let key = Self.key(for: item)
        let typed = Self.normalise(query)
        store.queries[typed]?[key] = nil
        if store.queries[typed]?.isEmpty == true { store.queries[typed] = nil }
        store.queryLast?[typed]?[key] = nil
        save()
    }

    private func save() {
        let snapshot = store
        // Written in the background so choosing a result never waits on the disk.
        saveQueue.async { [file] in
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let data = try? JSONEncoder().encode(snapshot) {
                try? data.write(to: file, options: .atomic)
            }
        }
    }

    func flush() {
        saveQueue.sync {}
    }

    func forgetEverything() {
        store = Store()
        try? FileManager.default.removeItem(at: file)
    }

    /// How many times this item was picked for exactly these words. Zero when never, or when learning is off.
    func timesPicked(_ item: Item, for query: String, now: Date = Date()) -> Int {
        guard Settings.isOn(Settings.learnFromUse) else { return 0 }
        let typed = Self.normalise(query), key = Self.key(for: item)
        if let last = store.queryLast?[typed]?[key], now.timeIntervalSince(last) > Self.pickLifetime { return 0 }
        return store.queries[typed]?[key] ?? 0
    }

    /// Extra score for items picked often and recently, up to 40. Halves every two weeks unused.
    func habitBoost(for item: Item) -> Int {
        guard Settings.isOn(Settings.learnFromUse), let entry = store.items[Self.key(for: item)] else { return 0 }
        // A pick dated in the future (the clock was set back since) counts as fresh, never as a value Int can't hold.
        let days = max(0, Date().timeIntervalSince(entry.last) / 86_400)
        let freshness = pow(0.5, days / 14)
        return Int(min(40, 12 * log2(1 + Double(entry.count))) * freshness)
    }
}
