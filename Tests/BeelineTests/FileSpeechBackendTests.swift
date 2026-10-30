import AVFoundation
import Foundation
import Speech
import Testing
@testable import Beeline

@Test func fileSpeechRequiresBothDemoVoiceAndAPath() {
    #expect(FileSpeechBackend.path(in: [:]) == nil)
    #expect(FileSpeechBackend.path(in: ["BEELINE_VOICE_FILE": "/tmp/test.aiff"]) == nil)
    #expect(FileSpeechBackend.path(in: ["BEELINE_DEMO": "voice"]) == nil)
    #expect(FileSpeechBackend.path(in: ["BEELINE_DEMO": "press", "BEELINE_VOICE_FILE": "/tmp/test.aiff"]) == nil)
    #expect(FileSpeechBackend.path(in: ["BEELINE_DEMO": "voice", "BEELINE_VOICE_FILE": ""]) == nil)
    #expect(FileSpeechBackend.path(in: ["BEELINE_DEMO": "voice", "BEELINE_VOICE_FILE": "/tmp/test.aiff"]) == "/tmp/test.aiff")
}

@Test func voiceActionsRequireAnExplicitRunFlagAndFileDemo() {
    let demo = ["BEELINE_DEMO": "voice", "BEELINE_VOICE_FILE": "/tmp/test.aiff"]
    #expect(!FileSpeechBackend.shouldRun(in: demo))
    #expect(!FileSpeechBackend.shouldRun(in: ["BEELINE_VOICE_RUN": "1"]))
    for value in ["0", "true", "yes", ""] {
        #expect(!FileSpeechBackend.shouldRun(in: demo.merging(["BEELINE_VOICE_RUN": value]) { _, new in new }))
    }
    #expect(FileSpeechBackend.shouldRun(in: demo.merging(["BEELINE_VOICE_RUN": "1"]) { _, new in new }))
}

/// Exercises the file backend's audio contract without speech permissions, UI, or a model download.
private final class BufferBackend: SpeechBackend {
    let source: FileSpeechBackend.Audio
    var frames: AVAudioFramePosition = 0
    var levels: [Double] = []
    var ended = false
    init(_ source: FileSpeechBackend.Audio) { self.source = source }
    func begin(_ words: [String], update: @escaping (String?, Bool, Bool) -> Void,
               level: @escaping (Double) -> Void, failed: @escaping () -> Void) -> String? {
        do {
            _ = try source.start(consume: { self.frames += AVAudioFramePosition($0.frameLength) }, level: {
                self.levels.append($0)
                level($0)
            })
            return nil
        } catch { return error.localizedDescription }
    }
    func stop() { source.stop() }
    func cancel() { source.stop() }
}

private func recording() throws -> URL? {
    guard FileManager.default.isExecutableFile(atPath: "/usr/bin/say") else { return nil }
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("beeline-file-test-\(UUID().uuidString).aiff")
    let say = Process()
    say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
    say.arguments = ["-o", url.path, "open TextEdit"]
    try say.run()
    // A headless host can have say installed while its synthesis service is unavailable.
    let timeout = DispatchWorkItem { if say.isRunning { say.terminate() } }
    DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: timeout)
    say.waitUntilExit()
    timeout.cancel()
    guard say.terminationStatus == 0, let audio = try? AVAudioFile(forReading: url), audio.length > 0 else {
        try? FileManager.default.removeItem(at: url)
        return nil // say may be present without a usable installed voice.
    }
    return url
}

@Test @MainActor func fileBackendFeedsAllPCMFramesAndLevelsThenReleases() async throws {
    guard let url = try recording() else { return }
    defer { try? FileManager.default.removeItem(at: url) }
    try await checkFrames(url)
}

@MainActor private func checkFrames(_ url: URL) async throws {
    let source = FileSpeechBackend.Audio(url: url)
    let sink = BufferBackend(source)
    let backend = FileSpeechBackend(source: source, backend: sink)
    source.onEnd = { [weak sink, weak backend] in sink?.ended = true; backend?.stop() }
    #expect(backend.begin([], update: { _, _, _ in }, level: { _ in }, failed: {}) == nil)
    for _ in 0..<100 {
        if sink.ended { break }
        try await Task.sleep(nanoseconds: 100_000_000)
    }
    #expect(sink.ended)
    #expect(sink.frames == (try AVAudioFile(forReading: url)).length)
    #expect(sink.levels.contains { $0 > 0 })
    #expect(sink.levels.allSatisfy { (0...1).contains($0) })
    #expect(TestRun.isActive)
    #expect(!Log.path.contains("/Library/Logs/"))
}

private func tone() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("beeline-pcm-test-\(UUID().uuidString).wav")
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1600))
    buffer.frameLength = 1600
    for index in 0..<1600 { buffer.floatChannelData![0][index] = Float(sin(Double(index) * 0.1)) * 0.5 }
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    try file.write(from: buffer)
    return url
}

@Test @MainActor func fileBackendFeedsPCMWithoutSpeechServices() async throws {
    let url = try tone()
    defer { try? FileManager.default.removeItem(at: url) }
    try await checkFrames(url)
}

@Test @MainActor func cancellingFileBackendStopsBuffersAndDoesNotRelease() async throws {
    let url = try tone()
    defer { try? FileManager.default.removeItem(at: url) }
    let source = FileSpeechBackend.Audio(url: url)
    let sink = BufferBackend(source)
    let backend = FileSpeechBackend(source: source, backend: sink)
    source.onEnd = { [weak sink] in sink?.ended = true }
    #expect(backend.begin([], update: { _, _, _ in }, level: { _ in }, failed: {}) == nil)
    backend.cancel()
    try await Task.sleep(nanoseconds: 100_000_000)
    #expect(sink.frames == 0)
    #expect(!sink.ended)
}

@Test @MainActor func missingVoiceFileFailsWithoutStartingAudio() {
    let source = FileSpeechBackend.Audio(url: URL(fileURLWithPath: "/no-such-beeline-file.aiff"))
    let sink = BufferBackend(source)
    let backend = FileSpeechBackend(source: source, backend: sink)
    #expect(backend.begin([], update: { _, _, _ in }, level: { _ in }, failed: {}) != nil)
    #expect(sink.frames == 0)
}

/// Optional device acceptance: the same backend and session used by the demo, with a real model.
@Test(.enabled(if: ProcessInfo.processInfo.environment["BEELINE_LIVE_SPEECH"] == "1"))
@MainActor func fileBackendTranscribesThroughTheInstalledEngine() async throws {
    guard let url = try recording() else { return }
    defer { try? FileManager.default.removeItem(at: url) }
    let source = FileSpeechBackend.Audio(url: url)
    let engine = AVAudioEngine()
    let session: SpeechBackend
    if #available(macOS 26, *), let locale = await AnalyzerSession.readyLocale() {
        session = AnalyzerSession(engine: engine, locale: locale, file: source)
    } else {
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else { return }
        session = SpeechSession(engine: engine, file: source)
    }
    let backend = FileSpeechBackend(source: source, backend: session)
    source.onEnd = { [weak backend] in backend?.stop() }
    defer { backend.cancel() }
    var text = "", finished = false, failed = false
    #expect(backend.begin([], update: { value, final, done in
        if final { text = value ?? "" }
        finished = done
    }, level: { _ in }, failed: { failed = true }) == nil)
    for _ in 0..<300 {
        if finished || failed { break }
        try await Task.sleep(nanoseconds: 100_000_000)
    }
    #expect(!failed && finished)
    #expect(text.lowercased().filter(\.isLetter).contains("opentextedit"))
}

@Test func fileVoiceKeepsFeedingUntilEOFEvenIfRecognitionFinishesEarly() {
    var update: ((String?, Bool, Bool) -> Void)?
    var stops = 0
    let voice = Voice(io: Voice.IO(authorise: { $0(nil) }, begin: { _, callback, _ in
        update = callback
        return nil
    }, stop: { stops += 1 }, cancel: {}), finishesWithAudio: true)
    var states: [String] = [], finals: [String] = []
    voice.onState = { states.append("\($0)") }
    voice.onFinal = { finals.append($0) }
    voice.start()
    update?("open TextEdit", true, true)
    #expect(states == ["listening"])
    #expect(finals == ["open TextEdit"] && stops == 0)
    voice.stop() // EOF releases the held shortcut, which stops Voice.
    #expect(states == ["listening", "stopped"] && stops == 1)
}
