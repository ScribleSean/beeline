import AppKit

/// The last thing Beeline did that can be taken back: a toggle, a window move, a file copied or moved
/// (with anything it replaced brought back from the Trash). Type "undo" to take it back; for a couple of
/// minutes it is also the one row an empty bar shows. Only the latest is kept, and only for ten minutes:
/// an undo for something long forgotten would surprise more than help.
final class UndoLog {
    struct Entry {
        /// What was done, as its row said it: "Turn Wi-Fi Off", "Move “report.pdf” to Desktop".
        let title: String
        let at: Date
        let undo: () -> Void
    }

    static let shared = UndoLog()
    /// How long "undo" can take something back.
    static let lifetime: TimeInterval = 600
    /// How long an empty bar offers it unasked.
    static let offerTime: TimeInterval = 120

    private let lock = NSLock()
    private var entry: Entry?

    /// Records what can be taken back, replacing the one before. Safe from any thread.
    func record(_ title: String, now: Date = Date(), undo: @escaping () -> Void) {
        lock.lock()
        entry = Entry(title: title, at: now, undo: undo)
        lock.unlock()
    }

    /// The latest entry, if it is recent enough.
    func latest(within age: TimeInterval = lifetime, now: Date = Date()) -> Entry? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry, now.timeIntervalSince(entry.at) <= age else { return nil }
        return entry
    }

    /// Takes the latest back once. Returns its title, or nil when there was nothing to undo.
    @discardableResult
    func undoLatest(now: Date = Date()) -> String? {
        lock.lock()
        guard let entry, now.timeIntervalSince(entry.at) <= Self.lifetime else {
            lock.unlock()
            return nil
        }
        self.entry = nil
        lock.unlock()
        Log.append("undo: \(entry.title)")
        entry.undo()
        return entry.title
    }

    func clear() {
        lock.lock()
        entry = nil
        lock.unlock()
    }

    /// The row that offers it: in reply to "undo", or on an empty bar shortly after.
    func item(for query: String, now: Date = Date()) -> Item? {
        let words = Usage.normalise(query)
        let asked = ["undo", "undo that", "undo it", "take that back", "put it back", "revert"].contains(words)
        guard asked || (words.isEmpty && latest(within: Self.offerTime, now: now) != nil),
              let entry = latest(now: now) else { return nil }
        return Item(id: "undo", kind: .action, verb: "Undo", title: entry.title, subtitle: "Undo", keywords: "",
                    icon: NSImage(systemSymbolName: "arrow.uturn.backward", accessibilityDescription: nil)) { [weak self] in
            self?.undoLatest()
        }
    }
}
