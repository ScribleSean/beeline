import Foundation

final class Usage {
    private struct Entry: Codable {
        var count: Int
        var last: Date
    }

    private struct Store: Codable {
        var items: [String: Entry] = [:]
        var queries: [String: [String: Int]] = [:]
        /// Optional, so history saved before it existed still loads.
        var queryLast: [String: [String: Date]]?
    }

    static let pickLifetime: TimeInterval = 28 * 86_400

    private var store = Store()
    private let file: URL
    private let saveQueue = DispatchQueue(label: "beeline.usage", qos: .userInitiated)

    convenience init() {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Beeline", isDirectory: true)
        self.init(file: ProcessInfo.processInfo.environment["BEELINE_USAGE_FILE"].map { URL(fileURLWithPath: $0) }
            ?? folder.appendingPathComponent("usage.json"))
    }

    init(file: URL) {
        self.file = file
        if let saved = JSONStore.read(Store.self, from: file, name: "usage") {
            store = saved
        }
    }

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

    func timesPicked(_ item: Item, for query: String, now: Date = Date()) -> Int {
        guard Settings.isOn(Settings.learnFromUse) else { return 0 }
        let typed = Self.normalise(query), key = Self.key(for: item)
        if let last = store.queryLast?[typed]?[key], now.timeIntervalSince(last) > Self.pickLifetime { return 0 }
        return store.queries[typed]?[key] ?? 0
    }

    func habitBoost(for item: Item) -> Int {
        guard Settings.isOn(Settings.learnFromUse), let entry = store.items[Self.key(for: item)] else { return 0 }
        // A pick dated in the future (the clock was set back since) counts as fresh, never as a value Int can't hold.
        let days = max(0, Date().timeIntervalSince(entry.last) / 86_400)
        let freshness = pow(0.5, days / 14)
        return Int(min(40, 12 * log2(1 + Double(entry.count))) * freshness)
    }
}
