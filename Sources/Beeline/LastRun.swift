import Foundation

final class LastRun {
    struct Entry {
        let request: String
        let steps: [String]
        let finished: Bool
        let at: Date
        var undoID: UUID? = nil
    }

    static let shared = LastRun()
    static let lifetime: TimeInterval = 300
    /// How long after a plan's last step an undo it set off may still arrive (scripts time out at 15 s).
    static let lateUndo: TimeInterval = 20

    private let lock = NSLock()
    private var entry: Entry?
    private var owner: Int?

    func begin(run: Int) {
        lock.lock()
        entry = nil
        owner = run
        lock.unlock()
    }

    func record(run: Int, request: String, steps: [String], finished: Bool = true, undoID: UUID? = nil, now: Date = Date()) {
        let request = request.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !request.isEmpty, !steps.isEmpty else { return }
        lock.lock()
        if owner == run { entry = Entry(request: request, steps: steps, finished: finished, at: now, undoID: undoID) }
        lock.unlock()
    }

    func adopt(undo id: UUID, at: Date) {
        lock.lock()
        if owner != nil, var current = entry, at >= current.at, at <= current.at.addingTimeInterval(Self.lateUndo) {
            current.undoID = id
            entry = current
        }
        lock.unlock()
    }

    func latest(now: Date = Date()) -> Entry? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry, now.timeIntervalSince(entry.at) <= Self.lifetime else { return nil }
        return entry
    }

    func clear() {
        lock.lock()
        entry = nil
        owner = nil
        lock.unlock()
    }

    private static let leadWords: Set<String> = ["now", "also", "then", "and"]
    private static let phrases = ["the other", "the same", "again", "instead"]
    private static let pronouns = ["it", "that", "them"]

    func isFollowUp(_ query: String, strong: Bool = false, now: Date = Date()) -> Bool {
        guard latest(now: now) != nil else { return false }
        let words = Usage.normalise(query.trimmingCharacters(in: .punctuationCharacters)).split(separator: " ").map(String.init)
        guard let first = words.first else { return false }
        if Self.leadWords.contains(first) { return true }
        let joined = " " + words.joined(separator: " ") + " "
        return (strong ? Self.phrases : Self.phrases + Self.pronouns).contains { joined.contains(" \($0) ") }
    }
}
