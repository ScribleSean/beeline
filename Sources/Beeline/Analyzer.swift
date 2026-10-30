import AVFoundation
import Speech

/// One way of turning microphone audio into words. `failed` reports a session that broke after `begin`
/// returned, so the router can hand the press to the other engine.
protocol SpeechBackend: AnyObject {
    func begin(_ words: [String], update: @escaping (String?, Bool, Bool) -> Void,
               level: @escaping (Double) -> Void, failed: @escaping () -> Void) -> String?
    func stop()
    func cancel()
}

enum SpeechEngine: Equatable {
    case analyzer
    case recognizer

    /// `defaults write <bundle id> voiceEngine classic` keeps the macOS 14/15 recognizer on newer systems.
    static let preferenceKey = "voiceEngine"

    static func pick(analyzerReady: Bool, analyzerFailed: Bool, preference: String?) -> SpeechEngine {
        preference != "classic" && analyzerReady && !analyzerFailed ? .analyzer : .recognizer
    }
}

/// Sends each press to SpeechAnalyzer when it is ready and to SFSpeechRecognizer otherwise. A failed
/// analyzer is not used again until Beeline restarts; if it failed before any words, the same press
/// carries on with the recognizer.
final class SpeechRouter {
    /// Set once the dictation model is known to be on this Mac (macOS 26 and later only).
    var analyzer: SpeechBackend?
    private let recognizer: SpeechBackend
    var preference: () -> String?
    private(set) var analyzerFailed = false
    private var current: SpeechBackend?
    private var generation = 0
    private var released = false

    init(analyzer: SpeechBackend? = nil, recognizer: SpeechBackend,
         preference: @escaping () -> String? = { UserDefaults.standard.string(forKey: SpeechEngine.preferenceKey) }) {
        self.analyzer = analyzer
        self.recognizer = recognizer
        self.preference = preference
    }

    var engine: SpeechEngine {
        SpeechEngine.pick(analyzerReady: analyzer != nil, analyzerFailed: analyzerFailed, preference: preference())
    }

    func begin(_ words: [String], update: @escaping (String?, Bool, Bool) -> Void,
               level: @escaping (Double) -> Void) -> String? {
        generation += 1
        released = false
        let session = generation
        DemoLog.note("voice-engine", ["engine": engine == .analyzer ? "analyzer" : "recognizer"])
        guard engine == .analyzer, let analyzer else {
            current = recognizer
            return recognizer.begin(words, update: update, level: level, failed: {})
        }
        current = analyzer
        var heardWords = false
        return analyzer.begin(words, update: { text, final, finished in
            if let text, !text.trimmingCharacters(in: .whitespaces).isEmpty { heardWords = true }
            update(text, final, finished)
        }, level: level, failed: { [weak self] in
            guard let self, session == self.generation else { return }
            self.analyzerFailed = true
            DemoLog.note("voice-engine-failed", ["heard": heardWords])
            // After release the press is over: never reopen the microphone for it.
            guard !heardWords, !self.released else {
                // Logged so the voice test mode reports the failure instead of waiting for a final transcript.
                DemoLog.note("voice-error", ["why": heardWords ? "The speech analyzer failed after hearing words."
                                                              : "The speech analyzer failed after the press ended."])
                return update(nil, false, true)
            }
            // The recognizer owns the press before it starts, so a failed start is still cleaned up by stop.
            DemoLog.note("voice-engine", ["engine": "recognizer", "fallback": true])
            self.current = self.recognizer
            if let problem = self.recognizer.begin(words, update: update, level: level, failed: {}) {
                DemoLog.note("voice-error", ["why": problem])
                update(nil, false, true)
            }
        })
    }

    func stop() {
        released = true
        current?.stop()
    }

    func cancel() {
        generation += 1
        current?.cancel()
    }
}

/// Finished segments plus the latest guess. DictationTranscriber keeps revising one guess and may never
/// mark it final, so the end of the results stream is what makes the text final.
struct Transcript {
    private(set) var settled = ""
    private(set) var guess = ""

    mutating func add(_ text: String, isFinal: Bool) {
        if isFinal {
            settled += text
            guess = ""
        } else {
            guess = text
        }
    }

    var text: String {
        (settled + guess).split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

/// SpeechAnalyzer with DictationTranscriber (macOS 26 and later), fed from the shared audio engine.
@available(macOS 26, *)
final class AnalyzerSession: SpeechBackend {
    let engine: AVAudioEngine
    let locale: Locale
    let file: FileSpeechBackend.Audio?
    private var generation = 0
    private var input: AsyncStream<AVAudioPCMBuffer>.Continuation?
    private var work: Task<Void, Never>?
    private var analyzer: SpeechAnalyzer?

    init(engine: AVAudioEngine, locale: Locale, file: FileSpeechBackend.Audio? = nil) {
        self.engine = engine
        self.locale = locale
        self.file = file
    }

    /// The installed locale to use, or nil when the model isn't on this Mac. Never starts a download.
    static func readyLocale(for wanted: Locale = .current) async -> Locale? {
        let installed = await DictationTranscriber.installedLocales.map { $0.identifier(.bcp47) }
        for candidate in [wanted, Locale(identifier: "en-US")] {
            if let locale = await DictationTranscriber.supportedLocale(equivalentTo: candidate),
               installed.contains(locale.identifier(.bcp47)) { return locale }
        }
        return nil
    }

    func begin(_ words: [String], update: @escaping (String?, Bool, Bool) -> Void,
               level: @escaping (Double) -> Void, failed: @escaping () -> Void) -> String? {
        cancel()
        let session = generation
        let (audio, input) = AsyncStream.makeStream(of: AVAudioPCMBuffer.self)
        self.input = input
        let format: AVAudioFormat
        if let file {
            do { format = try file.start(consume: { input.yield($0) }, level: level) }
            catch { finishAudio(); return "Couldn't read voice file: \(error.localizedDescription)" }
        } else {
            let mic = engine.inputNode
            mic.removeTap(onBus: 0)
            format = mic.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else { finishAudio(); return "No microphone found." }
            mic.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
                input.yield(buffer)
                let value = Voice.level(of: buffer)
                DispatchQueue.main.async { level(value) }
            }
            engine.prepare()
            do { try engine.start() } catch {
                finishAudio()
                return "The microphone couldn't start."
            }
        }
        let pipeline = Self.Pipeline(locale: locale, words: words)
        analyzer = pipeline.analyzer
        work = Task { @MainActor [weak self] in
            do {
                let text = try await pipeline.run(audio, format: format) { text in
                    guard let self, session == self.generation else { return }
                    update(text, false, false)
                }
                guard let self, session == self.generation else { return }
                self.finishAudio()
                update(text.isEmpty ? nil : text, !text.isEmpty, true)
            } catch {
                guard let self, session == self.generation else { return }
                self.finishAudio()
                failed()
            }
        }
        return nil
    }

    func stop() { finishAudio() }

    func cancel() {
        generation += 1
        finishAudio()
        work?.cancel()
        work = nil
        if let analyzer { Task { await analyzer.cancelAndFinishNow() } }
        analyzer = nil
    }

    /// Releases the engine only while this session still holds it: after `stop`, a late completion must
    /// not tear down a tap the recognizer installed for a newer press.
    private func finishAudio() {
        guard let input else { return }
        if let file { file.stop() } else {
            if engine.isRunning { engine.stop() }
            engine.inputNode.removeTap(onBus: 0)
        }
        input.finish()
        self.input = nil
    }

    /// Everything after the microphone: conversion, custom words, analysis and the running transcript.
    /// Tests feed it a recorded file instead of the microphone.
    struct Pipeline {
        let transcriber: DictationTranscriber
        let analyzer: SpeechAnalyzer
        let words: [String]

        init(locale: Locale, words: [String]) {
            transcriber = DictationTranscriber(locale: locale, contentHints: [.shortForm], transcriptionOptions: [],
                                               reportingOptions: [.volatileResults], attributeOptions: [])
            analyzer = SpeechAnalyzer(modules: [transcriber])
            self.words = words
        }

        /// Returns the final text once `audio` ends; `partial` gets the running text on the main actor.
        @MainActor
        func run(_ audio: AsyncStream<AVAudioPCMBuffer>, format: AVAudioFormat,
                 partial: @escaping (String) -> Void) async throws -> String {
            guard let target = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber],
                                                                              considering: format) else {
                throw CocoaError(.featureUnsupported)
            }
            if !words.isEmpty {
                let context = AnalysisContext()
                context.contextualStrings[.general] = words
                try await analyzer.setContext(context)
            }
            try await analyzer.prepareToAnalyze(in: target)
            guard let converter = Converter(from: format, to: target) else { throw CocoaError(.featureUnsupported) }
            let inputs = audio.map { try converter.convert($0) }.compactMap { $0 }.map { AnalyzerInput(buffer: $0) }
            let transcriber = transcriber, analyzer = analyzer
            let reading = Task { @MainActor in
                var transcript = Transcript()
                for try await result in transcriber.results {
                    transcript.add(String(result.text.characters), isFinal: result.isFinal)
                    if !transcript.text.isEmpty { partial(transcript.text) }
                }
                return transcript.text
            }
            do {
                if let end = try await analyzer.analyzeSequence(inputs) {
                    try await analyzer.finalizeAndFinish(through: end)
                } else {
                    await analyzer.cancelAndFinishNow()
                }
            } catch {
                reading.cancel()
                throw error
            }
            return try await withTaskCancellationHandler {
                try await reading.value
            } onCancel: { reading.cancel() }
        }
    }

    /// Resamples microphone buffers to the analyzer's format; passes them through when they already match.
    final class Converter: @unchecked Sendable {
        private let target: AVAudioFormat
        private let converter: AVAudioConverter?

        /// Nil when the formats differ and no converter can be made between them.
        init?(from source: AVAudioFormat, to target: AVAudioFormat) {
            self.target = target
            if source == target {
                converter = nil
            } else {
                guard let converter = AVAudioConverter(from: source, to: target) else { return nil }
                converter.primeMethod = .none
                self.converter = converter
            }
        }

        /// Nil when a buffer yields no frames yet; throws when conversion fails, so the press can fall back.
        func convert(_ buffer: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer? {
            guard let converter else { return buffer }
            let ratio = target.sampleRate / buffer.format.sampleRate
            let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 1
            guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
                throw CocoaError(.featureUnsupported)
            }
            var given = false
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, outStatus in
                if given {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                given = true
                outStatus.pointee = .haveData
                return buffer
            }
            if status == .error { throw error ?? CocoaError(.featureUnsupported) }
            return output.frameLength == 0 ? nil : output
        }
    }
}
