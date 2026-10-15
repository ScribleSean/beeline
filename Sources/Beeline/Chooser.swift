import Foundation
import FoundationModels

/// Uses the language model built into macOS to turn a loose request into search words.
/// It never picks or runs anything itself: the words are matched against the catalogue like typed ones.
enum Chooser {
    static var isAvailable: Bool {
        guard #available(macOS 26.0, *) else { return false }
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    /// Loads the model into memory so the first real request is not the slow one.
    private static var lastPrewarm = Date.distantPast

    static func prewarm() {
        guard Settings.isOn(Settings.useOnDeviceModel), Date().timeIntervalSince(lastPrewarm) > 60 else { return }
        lastPrewarm = Date()
        guard #available(macOS 26.0, *), isAvailable else { return }
        LanguageModelSession(instructions: keywordInstructions).prewarm()
    }

    private static let keywordInstructions = """
        Rewrite the user's request as 4 to 6 plain search keywords naming the Mac setting, feature \
        or kind of app they need. Reply with only the keywords, separated by spaces.
        """

    /// Turns a loose request into search words: "make my mac quieter" becomes "sound volume audio mute".
    /// Small models do this far more reliably than picking from a long list.
    static func keywords(for request: String) async -> [String] {
        guard #available(macOS 26.0, *), isAvailable else { return [] }
        let session = LanguageModelSession(instructions: keywordInstructions)
        let options = GenerationOptions(sampling: .greedy, maximumResponseTokens: 12)
        guard let reply = try? await session.respond(to: "Request: \(request)\nKeywords:", options: options) else { return [] }
        return reply.content.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }
}
