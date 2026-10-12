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
    }

    private var store = Store()
    private let file: URL
    private let saveQueue = DispatchQueue(label: "beeline.usage", qos: .userInitiated)

    init() {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Beeline", isDirectory: true)
        // Tests point this at a scratch file so they never touch real history.
        file = ProcessInfo.processInfo.environment["BEELINE_USAGE_FILE"].map { URL(fileURLWithPath: $0) }
            ?? folder.appendingPathComponent("usage.json")
        if let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode(Store.self, from: data) {
            store = saved
        }
    }

    /// A name for the item that survives relaunches. Tabs, windows and menu commands get new ids
    /// every time they are read, so those are keyed by where they live and what they are called.
    static func key(for item: Item) -> String {
        switch item.kind {
        case .app, .setting, .action:
            return item.id.hasPrefix("quit:") ? "quit:" + item.title : item.id
        case .tab:
            return "tab:\(item.keywords):\(item.title)"
        case .window:
            return "window:\(item.subtitle):\(item.title)"
        case .menu:
            return "menu:\(item.subtitle):\(item.title)"
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
        }
        // Keep the file small: one-off requests are dropped first once it grows.
        if store.queries.count > 1000 {
            store.queries = store.queries.filter { $0.value.values.reduce(0, +) > 1 }
        }
        let snapshot = store
        saveQueue.sync { [file] in
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let data = try? JSONEncoder().encode(snapshot) {
                try? data.write(to: file, options: .atomic)
            }
        }
    }

    /// How many times this item was picked for exactly these words. Zero when never.
    func timesPicked(_ item: Item, for query: String) -> Int {
        store.queries[Self.normalise(query)]?[Self.key(for: item)] ?? 0
    }

    /// Extra score for items picked often and recently, up to 40. Halves every two weeks unused.
    func habitBoost(for item: Item) -> Int {
        guard let entry = store.items[Self.key(for: item)] else { return 0 }
        let days = Date().timeIntervalSince(entry.last) / 86_400
        let freshness = pow(0.5, days / 14)
        return Int(min(40, 12 * log2(1 + Double(entry.count))) * freshness)
    }
}
