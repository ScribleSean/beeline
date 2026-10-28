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
        var item = Item(id: "undo", kind: .action, verb: "Undo", title: entry.title, subtitle: "Undo", keywords: "",
                        icon: NSImage(systemSymbolName: "arrow.uturn.backward", accessibilityDescription: nil)) { [weak self] in
            DispatchQueue.global(qos: .userInitiated).async { self?.undoLatest(id: id) }
        }
        item.stillValid = { [weak self] in self?.latest()?.id == id }
        return item
    }

    /// Bound to the entry Claude was shown, so it can't take back something newer. Offered only while
    /// the last run is still remembered, so an old undo isn't read as "that".
    func planStep(within age: TimeInterval = LastRun.lifetime, now: Date = Date()) -> PlanStep? {
        guard let entry = latest(within: age, now: now) else { return nil }
        let id = entry.id
        let outcome = UndoOutcome()
        // Off the main thread, as the Undo row does: moving windows or files back can block.
        var step = PlanStep(text: "Undo \(ScreenText.quote(entry.title))",
                            icon: NSImage(systemSymbolName: "arrow.uturn.backward", accessibilityDescription: nil)) { [weak self] in
            DispatchQueue.global(qos: .userInitiated).async { outcome.set(self?.undoLatest(id: id) != nil) }
        }
        // The plan waits for it, and stops if something newer replaced the entry.
        step.succeeded = { outcome.value == true }
        step.stillValid = { [weak self] in self?.latest()?.id == id }
        step.settleTime = 1
        return step
    }

    func hint(now: Date = Date()) -> String? {
        latest(within: Self.offerTime, now: now).map { "“undo” takes back \($0.title)" }
    }
}

/// Whether a plan's undo has finished, and whether it took anything back.
final class UndoOutcome {
    private let lock = NSLock()
    private var result: Bool?
    var value: Bool? { lock.lock(); defer { lock.unlock() }; return result }
    func set(_ done: Bool) { lock.lock(); result = done; lock.unlock() }
}
