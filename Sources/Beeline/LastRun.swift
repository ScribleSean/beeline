import Foundation

/// What Beeline last ran from the bar, kept a few minutes so Claude can read a follow-up
/// such as "now the other window" against it.
final class LastRun {
    struct Entry {
        let request: String
        let steps: [String]
        let finished: Bool
        let at: Date
    }

    static let shared = LastRun()
    static let lifetime: TimeInterval = 300

    private let lock = NSLock()
    private var entry: Entry?

    /// A plan records again after each step that took effect, so the record never lists one still to come.
    func record(request: String, steps: [String], finished: Bool = true, now: Date = Date()) {
        let request = request.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !request.isEmpty, !steps.isEmpty else { return }
        lock.lock()
        entry = Entry(request: request, steps: steps, finished: finished, at: now)
        lock.unlock()
    }

    /// A plan that stopped after some of its steps ran.
    func markUnfinished() {
        lock.lock()
        defer { lock.unlock() }
        guard let old = entry else { return }
        entry = Entry(request: old.request, steps: old.steps, finished: false, at: old.at)
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
