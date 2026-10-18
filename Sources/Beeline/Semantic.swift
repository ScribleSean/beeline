import Foundation
import NaturalLanguage

/// Matches by meaning using the language model that ships with macOS, so "flight" can find
/// "trip details". Free and on-device, but rough: its results are shown as best guesses.
final class Semantic {
    private let sentence = NLEmbedding.sentenceEmbedding(for: .english)
    private let word = NLEmbedding.wordEmbedding(for: .english)
    private var vectors: [String: [Double]] = [:]
    private let lock = NSLock()
    /// The embeddings are not safe to use from two threads at once: overlapping calls corrupt memory and crash.
    /// Every call into them goes through this lock. Each takes a few milliseconds, so waits stay short.
    private let modelLock = NSLock()

    private func sentenceVector(_ text: String) -> [Double]? {
        modelLock.lock()
        defer { modelLock.unlock() }
        return sentence?.vector(for: text)
    }

    /// Similarity below this is treated as unrelated. Set high on purpose: on sample requests,
    /// nonsense input scored up to 0.63 and correct matches from 0.62 to 0.79, so the model
    /// cannot be trusted below the top of its range.
    private let cutoff = 0.75

    static func text(for item: Item) -> String {
        item.keywords.isEmpty ? item.title : item.title + " " + item.keywords
    }

    /// Texts that stay cached for good: apps, settings and actions. Window, tab and menu texts come and go.
    private var permanent = Set<String>()

    /// Computes and stores vectors for new texts. Each takes about 2 ms, so call this off the main thread.
    func prepare(_ items: [Item], permanent keep: Bool = false) {
        guard sentence != nil else { return }
        if keep {
            lock.lock()
            permanent.formUnion(items.map(Self.text(for:)))
            lock.unlock()
        }
        for item in items {
            let text = Self.text(for: item)
            lock.lock()
            let known = vectors[text] != nil
            lock.unlock()
            guard !known, let vector = sentenceVector(text) else { continue }
            let unit = Self.normalised(vector)
            lock.lock()
            vectors[text] = unit
            lock.unlock()
        }
        // Titles of windows and tabs long closed would otherwise pile up for the whole session.
        lock.lock()
        if vectors.count > 3000 { vectors = vectors.filter { permanent.contains($0.key) } }
        lock.unlock()
    }

    /// The items closest in meaning to the query, best first, with their similarity from 0 to 1.
    func rank(_ query: String, in items: [Item], limit: Int, minimum: Double? = nil) -> [(item: Item, similarity: Double)] {
        let cutoff = minimum ?? cutoff
        guard sentence != nil, let raw = sentenceVector(query) else { return [] }
        let queryVector = Self.normalised(raw)
        let queryWords = Self.words(query)

        lock.lock()
        let known = vectors
        lock.unlock()

        let bySentence: [(Item, Double)] = items.compactMap { item in
            guard let vector = known[Self.text(for: item)] else { return nil }
            return (item, zip(queryVector, vector).reduce(0) { $0 + $1.0 * $1.1 })
        }
        // Word-level similarity is checked only for the leading candidates: it is slower per item,
        // but catches single-word links the sentence vector blurs.
        let shortlist = bySentence.sorted { $0.1 > $1.1 }.prefix(40)
        let rescored = shortlist.map { item, similarity -> (item: Item, similarity: Double) in
            let best = bestWordSimilarity(queryWords, Self.words(Self.text(for: item)))
            return (item, max(similarity, 0.5 * similarity + 0.5 * best))
        }
        return rescored.filter { $0.similarity >= cutoff }.sorted { $0.similarity > $1.similarity }.prefix(limit).map { $0 }
    }

    private func bestWordSimilarity(_ a: [String], _ b: [String]) -> Double {
        guard let word else { return 0 }
        var best = 0.0
        modelLock.lock()
        defer { modelLock.unlock() }
        for x in a where x.count >= 3 {
            for y in b where y.count >= 3 {
                let distance = word.distance(between: x, and: y, distanceType: .cosine)
                // Cosine distance runs 0...2; unknown words come back as 2.
                best = max(best, 1 - distance)
            }
        }
        return best
    }

    private static func words(_ text: String) -> [String] {
        text.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
    }

    private static func normalised(_ vector: [Double]) -> [Double] {
        let length = vector.reduce(0) { $0 + $1 * $1 }.squareRoot()
        return length > 0 ? vector.map { $0 / length } : vector
    }
}
