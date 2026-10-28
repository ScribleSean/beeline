import Foundation

/// The last plan Claude made and ran, kept a few minutes so Claude can read a follow-up such as
/// "now the other window" against it. A request handled locally is never kept: Claude never saw it.
final class LastRun {
    struct Entry {
        let request: String
        let steps: [String]
        let finished: Bool
        let at: Date
        /// The undo entry this plan left, the only one a follow-up's "undo that" may take back.
        var undoID: UUID? = nil
    }

    static let shared = LastRun()
    static let lifetime: TimeInterval = 300

    private let lock = NSLock()
    private var entry: Entry?
    /// The one run allowed to write, so a stopped or replaced plan can't overwrite what came after it.
    private var owner: Int?

    /// A plan starts: the run before it no longer reads as "that", even if this one fails before step 1.
    func begin(run: Int) {
        lock.lock()
        entry = nil
        owner = run
        lock.unlock()
    }

    /// A plan records again after each step that took effect, so the record never lists one still to come.
    func record(run: Int, request: String, steps: [String], finished: Bool = true, undoID: UUID? = nil, now: Date = Date()) {
        let request = request.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !request.isEmpty, !steps.isEmpty else { return }
        lock.lock()
        if owner == run { entry = Entry(request: request, steps: steps, finished: finished, at: now, undoID: undoID) }
        lock.unlock()
    }

    func latest(now: Date = Date()) -> Entry? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry, now.timeIntervalSince(entry.at) <= Self.lifetime else { return nil }
        return entry
    }

    /// Something ran that Claude didn't plan, so nothing is kept and no earlier plan may write.
    func clear() {
        lock.lock()
        entry = nil
        owner = nil
        lock.unlock()
    }

    private static let leadWords: Set<String> = ["now", "also", "then", "and"]
    private static let phrases = ["the other", "the same", "again", "instead"]
    private static let pronouns = ["it", "that", "them"]

    /// Wording that leans on what just ran, so the Claude row should come first. Strong wording also
    /// turns a question ("again?") into a request to act; a pronoun alone doesn't ("is it raining?").
    func isFollowUp(_ query: String, strong: Bool = false, now: Date = Date()) -> Bool {
        guard latest(now: now) != nil else { return false }
        let words = Usage.normalise(query.trimmingCharacters(in: .punctuationCharacters)).split(separator: " ").map(String.init)
        guard let first = words.first else { return false }
        if Self.leadWords.contains(first) { return true }
        let joined = " " + words.joined(separator: " ") + " "
        return (strong ? Self.phrases : Self.phrases + Self.pronouns).contains { joined.contains(" \($0) ") }
    }
}
