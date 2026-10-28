import AppKit

final class UndoLog {
    struct Entry {
        let id = UUID()
        let title: String
        let at: Date
        let undo: () -> Void
    }

    static let shared = UndoLog()
    static let lifetime: TimeInterval = 600
    static let offerTime: TimeInterval = 120

    private let lock = NSLock()
    private var entry: Entry?

    func record(_ title: String, now: Date = Date(), undo: @escaping () -> Void) {
        lock.lock()
        entry = Entry(title: title, at: now, undo: undo)
        lock.unlock()
    }

    func latest(within age: TimeInterval = lifetime, now: Date = Date()) -> Entry? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry, now.timeIntervalSince(entry.at) <= age else { return nil }
        return entry
    }

    @discardableResult
    func undoLatest(id: UUID? = nil, now: Date = Date()) -> String? {
        lock.lock()
        guard let entry, now.timeIntervalSince(entry.at) <= Self.lifetime, id == nil || entry.id == id else {
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

    func item(for query: String, now: Date = Date()) -> Item? {
        let asked = ["undo", "undo that", "undo it", "take that back", "put it back", "revert"].contains(Usage.normalise(query))
        guard asked, let entry = latest(now: now) else { return nil }
        let id = entry.id
        return Item(id: "undo", kind: .action, verb: "Undo", title: entry.title, subtitle: "Undo", keywords: "",
                    icon: NSImage(systemSymbolName: "arrow.uturn.backward", accessibilityDescription: nil)) { [weak self] in
            DispatchQueue.global(qos: .userInitiated).async { self?.undoLatest(id: id) }
        }
    }

    /// Bound to the entry Claude was shown, so it can't take back something newer.
    func planStep(now: Date = Date()) -> PlanStep? {
        guard let entry = latest(now: now) else { return nil }
        let id = entry.id
        // Runs in line, not on a background queue like the Undo row, so the plan's next step sees it done.
        var step = PlanStep(text: "Undo the last thing Beeline did: \(ScreenText.quote(entry.title))",
                            icon: NSImage(systemSymbolName: "arrow.uturn.backward", accessibilityDescription: nil)) { [weak self] in
            self?.undoLatest(id: id)
        }
        // Something newer replaced it, so the plan stops here instead of carrying on as if it had.
        step.stillValid = { [weak self] in self?.latest()?.id == id }
        return step
    }

    func hint(now: Date = Date()) -> String? {
        latest(within: Self.offerTime, now: now).map { "“undo” takes back \($0.title)" }
    }
}
