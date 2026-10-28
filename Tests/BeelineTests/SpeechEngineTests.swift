import AVFoundation
import Foundation
import Testing
@testable import Beeline

private final class FakeBackend: SpeechBackend {
    var problem: String?
    var begins = 0, stops = 0, cancels = 0
    var update: ((String?, Bool, Bool) -> Void)?
    var failed: (() -> Void)?

    func begin(_ words: [String], update: @escaping (String?, Bool, Bool) -> Void,
               level: @escaping (Double) -> Void, failed: @escaping () -> Void) -> String? {
        begins += 1
        self.update = update
        self.failed = failed
        return problem
    }
    func stop() { stops += 1 }
    func cancel() { cancels += 1 }
}

private func voice(_ router: SpeechRouter) -> Voice {
    Voice(io: Voice.IO(authorise: { $0(nil) }, begin: { router.begin($0, update: $1, level: $2) },
                       stop: router.stop, cancel: router.cancel))
}

@Test func enginePickPrefersAnalyzerOnlyWhenReadyAndNotForcedClassic() {
    #expect(SpeechEngine.pick(analyzerReady: true, analyzerFailed: false, preference: nil) == .analyzer)
    #expect(SpeechEngine.pick(analyzerReady: false, analyzerFailed: false, preference: nil) == .recognizer)
    #expect(SpeechEngine.pick(analyzerReady: true, analyzerFailed: true, preference: nil) == .recognizer)
    #expect(SpeechEngine.pick(analyzerReady: true, analyzerFailed: false, preference: "classic") == .recognizer)
}

@Test func withoutAnAnalyzerEveryPressUsesTheRecognizer() {
    let old = FakeBackend()
    let router = SpeechRouter(recognizer: old, preference: { nil })
    let voice = voice(router)
    var finals: [String] = []
    voice.onFinal = { finals.append($0) }
    voice.start()
    voice.stop()
    old.update?("open safari", true, true)
    #expect(old.begins == 1 && old.stops >= 1)
    #expect(finals == ["open safari"])
}

@Test func forcedClassicKeepsTheRecognizerEvenWhenTheAnalyzerIsReady() {
    let new = FakeBackend(), old = FakeBackend()
    let router = SpeechRouter(analyzer: new, recognizer: old, preference: { "classic" })
    voice(router).start()
    #expect(new.begins == 0 && old.begins == 1)
}

@Test func analyzerFailingBeforeWordsHandsThePressToTheRecognizer() {
    let new = FakeBackend(), old = FakeBackend()
    let router = SpeechRouter(analyzer: new, recognizer: old, preference: { nil })
    let voice = voice(router)
    var states: [String] = []
    var finals: [String] = []
    voice.onState = { states.append("\($0)") }
    voice.onFinal = { finals.append($0) }
    voice.start()
    #expect(new.begins == 1 && old.begins == 0)
    new.failed?()
    #expect(old.begins == 1)
    voice.stop()
    #expect(old.stops == 1 && new.stops == 0)
    old.update?("open xcode", true, true)
    #expect(finals == ["open xcode"])
    #expect(states == ["listening", "stopped"])
    voice.start()
    #expect(new.begins == 1 && old.begins == 2) // A failed analyzer isn't tried again.
}

@Test func analyzerFailingAfterWordsEndsThePressWithoutSwitching() {
    let new = FakeBackend(), old = FakeBackend()
    let router = SpeechRouter(analyzer: new, recognizer: old, preference: { nil })
    let voice = voice(router)
    var texts: [String] = []
    var states: [String] = []
    voice.onText = { texts.append($0) }
    voice.onState = { states.append("\($0)") }
    voice.start()
    new.update?("open", false, false)
    new.failed?()
    #expect(old.begins == 0)
    #expect(texts == ["open"])
    #expect(states == ["listening", "stopped"])
}

@Test func lateFailureFromACancelledPressIsIgnored() {
    let new = FakeBackend(), old = FakeBackend()
    let router = SpeechRouter(analyzer: new, recognizer: old, preference: { nil })
    let voice = voice(router)
    voice.start()
    let stale = new.failed
    voice.cancel()
    #expect(new.cancels == 1)
    stale?()
    #expect(old.begins == 0 && !router.analyzerFailed)
}

@Test func recognizerProblemDuringFallbackEndsThePress() {
    let new = FakeBackend(), old = FakeBackend()
    old.problem = "No microphone found."
    let router = SpeechRouter(analyzer: new, recognizer: old, preference: { nil })
    let voice = voice(router)
    var states: [String] = []
    voice.onState = { states.append("\($0)") }
    voice.start()
    new.failed?()
    #expect(states == ["listening", "stopped"])
}

@Test func transcriptKeepsFinishedSegmentsAndTheLatestGuess() {
    var transcript = Transcript()
    transcript.add(" Open", isFinal: false)
    transcript.add(" Open Safari.", isFinal: false)
    #expect(transcript.text == "Open Safari.")
    transcript.add(" Open Safari.", isFinal: true)
    transcript.add(" Then move", isFinal: false)
    #expect(transcript.text == "Open Safari. Then move")
    transcript.add(" Then move the window", isFinal: false)
    #expect(transcript.text == "Open Safari. Then move the window")
    transcript.add(" Then move the window left", isFinal: true)
    #expect(transcript.text == "Open Safari. Then move the window left")
}

/// Feeds a `say` recording through the app's real SpeechAnalyzer pipeline. Needs macOS 26 with the
/// dictation model installed, so it only runs with BEELINE_LIVE_SPEECH=1.
@Test(.enabled(if: ProcessInfo.processInfo.environment["BEELINE_LIVE_SPEECH"] == "1"))
func analyzerTranscribesARecordedRequest() async throws {
    guard #available(macOS 26, *) else { return }
    let locale = try #require(await AnalyzerSession.readyLocale())
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("beeline-speech-\(UUID().uuidString).aiff")
    defer { try? FileManager.default.removeItem(at: url) }
    let say = Process()
    say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
    say.arguments = ["-o", url.path, "open Xcode and move the window to the left"]
    try say.run()
    say.waitUntilExit()
    let file = try AVAudioFile(forReading: url)
    let format = file.processingFormat
    let (audio, input) = AsyncStream.makeStream(of: AVAudioPCMBuffer.self)
    while let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024),
          (try? file.read(into: buffer, frameCount: 1024)) != nil, buffer.frameLength > 0 {
        input.yield(buffer)
    }
    input.finish()
    var partials: [String] = []
    let text = try await AnalyzerSession.Pipeline(locale: locale, words: ["Xcode"])
        .run(audio, format: format) { partials.append($0) }
    #expect(text.lowercased().contains("open xcode"))
    #expect(text.lowercased().contains("window to the left"))
    #expect(partials.count > 1)
}
