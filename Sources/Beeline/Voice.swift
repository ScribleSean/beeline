import AppKit
import AVFoundation
import Speech

final class Voice {
    enum State {
        case listening
        case stopped
        case unavailable(String)
    }

    var onAudioEnd: () -> Void = {}
    var onText: (String) -> Void = { _ in }
    var onFinal: (String) -> Void = { _ in }
    var onState: (State) -> Void = { _ in }
    var onLevel: (Double) -> Void = { _ in }
    /// A live take ended without any words. The saved audio can be run again with `retry`.
    var onMissed: () -> Void = {}

    struct IO {
        var authorise: (@escaping (String?) -> Void) -> Void
        var begin: ([String], @escaping (String?, Bool, Bool) -> Void, @escaping (Double) -> Void) -> String?
        var stop: () -> Void
        var cancel: () -> Void
    }

    private var io: IO
    private let liveIO: IO
    private let vault: TakeVault?
    private let tap: TakeTap
    var makeReplay: ((FileSpeechBackend.Audio) -> IO)?
    private(set) var lastTake: URL?
    private var replaying = false
    var vocabulary: [String] = []
    private var finishesWithAudio = false
    private var active = false
    private var cancelledBeforeStart = false
    private var generation = 0

    convenience init() {
        let engine = AVAudioEngine()
        let file = FileSpeechBackend.path().map { FileSpeechBackend.Audio(url: URL(fileURLWithPath: $0)) }
        let tap = TakeTap()
        let speech = SpeechSession(engine: engine, file: file)
        speech.tee = tap.write
        let router = SpeechRouter(recognizer: file.map { FileSpeechBackend(source: $0, backend: speech) } ?? speech,
                                  preference: { file == nil ? UserDefaults.standard.string(forKey: SpeechEngine.preferenceKey) : nil })
        self.init(io: Voice.IO(authorise: { done in
            guard let file else { return speech.authorise(done) }
            Task { @MainActor in
                if #available(macOS 26, *), let locale = await AnalyzerSession.readyLocale() {
                    router.analyzer = FileSpeechBackend(source: file, backend: AnalyzerSession(engine: engine, locale: locale, file: file))
                    done(nil)
                } else { speech.authorise(done) }
            }
        },
                               begin: { router.begin($0, update: $1, level: $2) },
                               stop: router.stop, cancel: router.cancel), finishesWithAudio: file != nil,
                  vault: file == nil ? TakeVault() : nil, tap: tap)
        self.router = router
        makeReplay = { Voice.fileIO($0, engine: AVAudioEngine()) }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            self?.forgetTakes()
        }
        file?.onEnd = { [weak self] in
            self?.onAudioEnd()
            self?.stop()
        }
        if #available(macOS 26, *), file == nil {
            Task { @MainActor in
                guard let locale = await AnalyzerSession.readyLocale() else { return }
                let session = AnalyzerSession(engine: engine, locale: locale)
                session.tee = tap.write
                router.analyzer = session
            }
        }
        NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
                                               object: engine, queue: .main) { [weak self] _ in
            self?.stop()
        }
    }

    private(set) var router: SpeechRouter?

    init(io: IO, finishesWithAudio: Bool = false, vault: TakeVault? = nil, tap: TakeTap = TakeTap()) {
        self.io = io
        self.liveIO = io
        self.finishesWithAudio = finishesWithAudio
        self.vault = vault
        self.tap = tap
        vault?.clear() // a take from an earlier run can no longer be retried
    }

    /// Deletes every saved take, for when Beeline quits.
    func forgetTakes() {
        cancel()
        vault?.clear()
    }

    /// Reads a saved take back through the recognizer instead of the microphone.
    static func fileIO(_ audio: FileSpeechBackend.Audio, engine: AVAudioEngine) -> IO {
        let speech = SpeechSession(engine: engine, file: audio)
        let router = SpeechRouter(recognizer: FileSpeechBackend(source: audio, backend: speech), preference: { nil })
        return IO(authorise: { done in
            Task { @MainActor in
                if #available(macOS 26, *), let locale = await AnalyzerSession.readyLocale() {
                    router.analyzer = FileSpeechBackend(source: audio, backend: AnalyzerSession(engine: engine, locale: locale, file: audio))
                    done(nil)
                } else { speech.authorise(done) }
            }
        }, begin: { router.begin($0, update: $1, level: $2) }, stop: router.stop, cancel: router.cancel)
    }

    /// Runs the newest saved take again. False when there is none or a take is already running.
    @discardableResult
    func retry() -> Bool {
        guard !active, let makeReplay, let vault, let name = lastTake?.lastPathComponent,
              let url = vault.takes().first(where: { $0.lastPathComponent == name }) else { return false }
        let audio = FileSpeechBackend.Audio(url: url)
        audio.onEnd = { [weak self] in self?.stop() }
        io = makeReplay(audio)
        replaying = true
        finishesWithAudio = true
        lastTake = url
        start()
        return true
    }

    func start() {
        guard !active else { return }
        cancelledBeforeStart = false
        generation += 1
        let session = generation
        io.authorise { [weak self] problem in
            guard let self, session == self.generation, !self.cancelledBeforeStart else { return }
            if let problem {
                DemoLog.note("voice-error", ["why": problem])
                self.endReplay()
                return self.onState(.unavailable(problem))
            }
            self.active = true
            let replay = self.replaying
            // Fixed for this take: stop() switches both back to the microphone before a replay's last callback.
            let finishesWithAudio = self.finishesWithAudio
            var gotFinal = false
            if !replay {
                self.dropTake() // a new hold replaces a take that was never retried
                self.tap.start(self.vault?.begin())
            }
            let problem = self.io.begin(Self.contextualStrings(self.vocabulary), { [weak self] text, final, finished in
                guard let self, session == self.generation else { return }
                if let text {
                    DemoLog.note(final ? "voice-final" : "voice-partial", ["text": text])
                    self.onText(text)
                }
                if final, let text, !text.isEmpty { gotFinal = true }
                if final, let text { self.onFinal(text) }
                if finished, session == self.generation {
                    // A replay whose recognizer is done has no use for the rest of the file.
                    if !finishesWithAudio || replay { self.stop() }
                    if gotFinal { self.dropTake() } else if self.lastTake != nil { self.onMissed() }
                }
            }, { [weak self] level in
                guard let self, session == self.generation else { return }
                self.onLevel(level)
            })
            if let problem {
                DemoLog.note("voice-error", ["why": problem])
                self.stop()
                self.onState(.unavailable(problem))
            } else if self.active {
                self.onState(.listening)
            }
        }
    }

    func stop() {
        cancelledBeforeStart = true
        io.stop()
        if let recording = tap.end(), let vault {
            lastTake = vault.finish(recording)
            if lastTake != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + TakeVault.lifetime + 1) { [weak vault] in vault?.sweep() }
            }
        }
        endReplay()
        guard active else { return }
        active = false
        onState(.stopped)
    }

    /// The take was heard, so its audio has no more use.
    private func dropTake() {
        guard let take = lastTake else { return }
        lastTake = nil
        vault?.discard(take)
    }

    private func endReplay() {
        guard replaying else { return }
        replaying = false
        finishesWithAudio = false
        io = liveIO
    }

    func cancel() {
        generation += 1
        io.cancel()
        if let recording = tap.end() { vault?.abandon(recording) }
        stop()
        dropTake() // its answer can no longer arrive, and Try again is no longer offered
    }

    static func contextualStrings(_ words: [String]) -> [String] {
        var seen = Set<String>()
        return words.map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { (2...40).contains($0.count) && seen.insert($0.lowercased()).inserted }
            .prefix(100)
            .map { $0 }
    }

    static func level(of buffer: AVAudioPCMBuffer) -> Double {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var sum: Float = 0
        for index in 0..<Int(buffer.frameLength) { sum += samples[index] * samples[index] }
        return level(rms: Double((sum / Float(buffer.frameLength)).squareRoot()))
    }

    static func level(rms: Double) -> Double {
        guard rms > 0 else { return 0 }
        return min(1, max(0, (20 * log10(rms) + 50) / 50))
    }

}

final class SpeechSession: SpeechBackend {
    let engine: AVAudioEngine
    let file: FileSpeechBackend.Audio?
    private let recognizer: SFSpeechRecognizer? = {
        if let own = SFSpeechRecognizer(locale: .current), own.supportsOnDeviceRecognition { return own }
        return SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    }()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var generation = 0
    var tee: ((AVAudioPCMBuffer) -> Void)?

    init(engine: AVAudioEngine, file: FileSpeechBackend.Audio? = nil) { self.engine = engine; self.file = file }

    func cancel() {
        generation += 1
        task?.cancel()
        task = nil
        if file != nil { stop() }
    }

    func authorise(_ done: @escaping (String?) -> Void) {
        if file != nil {
            done(SFSpeechRecognizer.authorizationStatus() == .authorized ? nil : "The file recognizer needs Speech Recognition permission.")
            return
        }
        if SFSpeechRecognizer.authorizationStatus() == .authorized,
           AVCaptureDevice.authorizationStatus(for: .audio) == .authorized { return done(nil) }
        SFSpeechRecognizer.requestAuthorization { status in
            guard status == .authorized else {
                return DispatchQueue.main.async { done("Allow Speech Recognition for Beeline in Privacy & Security.") }
            }
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async { done(granted ? nil : "Allow the Microphone for Beeline in Privacy & Security.") }
            }
        }
    }

    func stop() {
        if let file { file.stop() } else {
            if engine.isRunning { engine.stop() }
            engine.inputNode.removeTap(onBus: 0)
        }
        request?.endAudio()
        request = nil
    }

    func begin(_ vocabulary: [String], update: @escaping (String?, Bool, Bool) -> Void,
               level: @escaping (Double) -> Void, failed: @escaping () -> Void) -> String? {
        guard let recognizer, recognizer.isAvailable else { return "Speech recognition isn't available right now." }
        guard recognizer.supportsOnDeviceRecognition else { return "On-device speech recognition isn't available for English on this Mac." }
        generation += 1
        let session = generation
        task?.cancel()
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        request.contextualStrings = vocabulary
        self.request = request
        if let file {
            do { _ = try file.start(consume: request.append, level: level) }
            catch { return "Couldn't read voice file: \(error.localizedDescription)" }
        } else {
            let input = engine.inputNode
            input.removeTap(onBus: 0)
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else { return "No microphone found." }
            let tee = self.tee
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
                tee?(buffer)
                request.append(buffer)
                let value = Voice.level(of: buffer)
                DispatchQueue.main.async { level(value) }
            }
            engine.prepare()
            do { try engine.start() } catch { return "The microphone couldn't start." }
        }
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let final = result?.isFinal == true
            let finished = final || error != nil
            DispatchQueue.main.async {
                guard let self, session == self.generation else { return }
                if let error, self.file != nil, !final {
                    DemoLog.note("voice-error", ["why": error.localizedDescription])
                }
                if finished { self.task = nil }
                update(text, final, finished)
            }
        }
        return nil
    }
}
