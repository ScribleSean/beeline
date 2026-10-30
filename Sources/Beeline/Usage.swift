import Foundation

final class Usage {
    private struct Entry: Codable, Equatable {
        var count: Int
        var last: Date
    }

    private struct Store: Codable, Equatable {
        var items: [String: Entry] = [:]
        var queries: [String: [String: Int]] = [:]
        /// Optional, so history saved before it existed still loads.
        var queryLast: [String: [String: Date]]?
    }

    /// Set by main for explicit demo/CLI modes, never from the normal launch environment.
    static var fileOverride: URL?

    static let pickLifetime: TimeInterval = 28 * 86_400

    private var store = Store()
    let file: URL
    private let saveQueue: DispatchQueue
    struct IO {
        var read: (URL) -> Data? = { try? Data(contentsOf: $0) }
        var write: (Data, URL) -> Void = { data, file in
            try? JSONStore.createPrivateDirectory(file.deletingLastPathComponent())
            try? data.write(to: file, options: .atomic)
        }
        var remove: (URL) -> Void = { try? FileManager.default.removeItem(at: $0) }
    }
    private let io: IO

    convenience init() {
        self.init(file: Self.historyFile(in: TestRun.supportFolder))
    }

    static func historyFile(in folder: URL, override: URL? = fileOverride) -> URL {
        override ?? folder.appendingPathComponent("usage.json")
    }

    init(file: URL, io: IO? = nil,
         saveQueue: DispatchQueue = DispatchQueue(label: "beeline.usage", qos: .userInitiated)) {
        self.file = file
        self.io = io ?? IO()
        self.saveQueue = saveQueue
        if let io {
            if let data = io.read(file), let saved = try? JSONDecoder().decode(Store.self, from: data) { store = saved }
        } else if let saved = JSONStore.read(Store.self, from: file, name: "usage") {
            store = saved
        }
        let loaded = store
        prune()
        if loaded != store { save() }
    }

    private func prune(now: Date = Date()) {
        let cutoff = now.addingTimeInterval(-90 * 86_400)
        store.items = store.items.filter { $0.value.last > cutoff }
        for (query, picks) in store.queries {
            let kept = picks.filter { key, _ in
                guard store.items[key] != nil else { return false }
                return store.queryLast?[query]?[key].map { $0 > cutoff } ?? true
            }
            store.queries[query] = kept.isEmpty ? nil : kept
        }
        for (query, dates) in store.queryLast ?? [:] {
            let kept = dates.filter { store.queries[query]?[$0.key] != nil }
            store.queryLast?[query] = kept.isEmpty ? nil : kept
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
        prune()
        let snapshot = store
        saveQueue.async { [file, io] in
            if let data = try? JSONEncoder().encode(snapshot) { io.write(data, file) }
        }
    }

    func flush() {
        saveQueue.sync {}
    }

    func forgetEverything() {
        store = Store()
        saveQueue.async { [file, io] in io.remove(file) }
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
