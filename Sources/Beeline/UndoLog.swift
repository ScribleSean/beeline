import AppKit

final class UndoLog {
    struct Entry {
        let id = UUID()
        let title: String
        let at: Date
        let undo: () -> Void
    }

    static let shared = UndoLog { LastRun.shared.adopt(undo: $0.id, at: $0.at) }
    static let lifetime: TimeInterval = 600
    static let offerTime: TimeInterval = 120

    private let lock = NSLock()
    private var entry: Entry?
    private let onRecord: ((Entry) -> Void)?

    init(onRecord: ((Entry) -> Void)? = nil) {
        self.onRecord = onRecord
    }

    func record(_ title: String, now: Date = Date(), undo: @escaping () -> Void) {
        let made = Entry(title: title, at: now, undo: undo)
        lock.lock()
        entry = made
        lock.unlock()
        onRecord?(made)
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

    func planStep(for last: LastRun.Entry?, now: Date = Date()) -> PlanStep? {
        guard let undoID = last?.undoID, let entry = latest(now: now), entry.id == undoID else { return nil }
        let id = entry.id
        let outcome = UndoOutcome()
        var step = PlanStep(text: "Undo \(ScreenText.quote(entry.title))",
                            icon: NSImage(systemSymbolName: "arrow.uturn.backward", accessibilityDescription: nil)) { [weak self] in
            // Off the main thread, as the Undo row does: moving windows or files back can block.
            DispatchQueue.global(qos: .userInitiated).async { outcome.set(self?.undoLatest(id: id) != nil) }
        }
        step.succeeded = { outcome.value == true }
        step.stillRunning = { outcome.value == nil }
        step.stillValid = { [weak self] in self?.latest()?.id == id }
        step.settleTime = 0
        step.grace = 3
        return step
    }

    func latestID(since start: Date) -> UUID? {
        latest().flatMap { $0.at >= start ? $0.id : nil }
    }

    func hint(now: Date = Date()) -> String? {
        latest(within: Self.offerTime, now: now).map { "“undo” takes back \($0.title)" }
    }
}

final class UndoOutcome {
    private let lock = NSLock()
    private var result: Bool?
    var value: Bool? { lock.lock(); defer { lock.unlock() }; return result }
    func set(_ done: Bool) { lock.lock(); result = done; lock.unlock() }
}
