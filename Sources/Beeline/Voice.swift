import AVFoundation
import Speech

final class Voice {
    enum State {
        case listening
        case stopped
        case unavailable(String)
    }

    var onText: (String) -> Void = { _ in }
    var onFinal: (String) -> Void = { _ in }
    var onState: (State) -> Void = { _ in }
    var onLevel: (Double) -> Void = { _ in }

    struct IO {
        var authorise: (@escaping (String?) -> Void) -> Void
        var begin: ([String], @escaping (String?, Bool, Bool) -> Void, @escaping (Double) -> Void) -> String?
        var stop: () -> Void
        var cancel: () -> Void
    }

    private let io: IO
    var vocabulary: [String] = []
    private var active = false
    private var cancelledBeforeStart = false
    private var generation = 0

    convenience init() {
        let speech = SpeechSession()
        self.init(io: speech.io)
        NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
                                               object: speech.engine, queue: .main) { [weak self] _ in
            self?.stop()
        }
    }

    init(io: IO) { self.io = io }

    func start() {
        guard !active else { return }
        cancelledBeforeStart = false
        generation += 1
        let session = generation
        io.authorise { [weak self] problem in
            guard let self, session == self.generation, !self.cancelledBeforeStart else { return }
            if let problem { return self.onState(.unavailable(problem)) }
            self.active = true
            let problem = self.io.begin(Self.contextualStrings(self.vocabulary), { [weak self] text, final, finished in
                guard let self, session == self.generation else { return }
                if let text { self.onText(text) }
                if final, let text { self.onFinal(text) }
                if finished, session == self.generation { self.stop() }
            }, { [weak self] level in
                guard let self, session == self.generation else { return }
                self.onLevel(level)
            })
            if let problem {
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
        guard active else { return }
        active = false
        onState(.stopped)
    }

    func cancel() {
        generation += 1
        io.cancel()
        stop()
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

/// Owns the real microphone and recognition task; tests inject a session without hardware.
private final class SpeechSession {
    let engine = AVAudioEngine()
    private let recognizer: SFSpeechRecognizer? = {
        if let own = SFSpeechRecognizer(locale: .current), own.supportsOnDeviceRecognition { return own }
        return SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    }()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var generation = 0

    var io: Voice.IO {
        Voice.IO(authorise: authorise, begin: begin, stop: stop, cancel: { self.generation += 1; self.task?.cancel(); self.task = nil })
    }

    private func authorise(_ done: @escaping (String?) -> Void) {
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

    private func stop() {
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        request = nil
    }

    private func begin(_ vocabulary: [String], update: @escaping (String?, Bool, Bool) -> Void,
                       level: @escaping (Double) -> Void) -> String? {
        guard let recognizer, recognizer.isAvailable else { return "Speech recognition isn't available right now." }
        guard recognizer.supportsOnDeviceRecognition else { return "On-device speech recognition isn't available for English on this Mac." }
        generation += 1
        let session = generation
        task?.cancel()
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { return "No microphone found." }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        request.contextualStrings = vocabulary
        self.request = request
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
            let value = Voice.level(of: buffer)
            DispatchQueue.main.async { level(value) }
        }
        engine.prepare()
        do { try engine.start() } catch { return "The microphone couldn't start." }
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let final = result?.isFinal == true
            let finished = final || error != nil
            DispatchQueue.main.async {
                guard let self, session == self.generation else { return }
                if finished { self.task = nil }
                update(text, final, finished)
            }
        }
        return nil
    }
}
