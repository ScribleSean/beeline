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

    private let engine = AVAudioEngine()
    private let recognizer: SFSpeechRecognizer? = {
        if let own = SFSpeechRecognizer(locale: .current), own.supportsOnDeviceRecognition { return own }
        return SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    }()
    var vocabulary: [String] = []
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var cancelledBeforeStart = false
    private var generation = 0

    init() {
        // AVAudioEngine stops itself when the audio hardware changes (AirPods connecting, a mic unplugged)
        // and leaves its tap behind; a second tap on the same bus crashes the app.
        NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            self?.stop()
        }
    }

    func start() {
        cancelledBeforeStart = false
        generation += 1
        let session = generation
        authorise { [weak self] problem in
            guard let self, session == self.generation else { return }
            if let problem { return self.onState(.unavailable(problem)) }
            guard !self.cancelledBeforeStart else { return }
            self.begin(session)
        }
    }

    func stop() {
        cancelledBeforeStart = true
        if engine.isRunning { engine.stop() }
        // Removing a tap that is not there is harmless; one left behind after the engine stopped itself
        // crashes the next installTap.
        engine.inputNode.removeTap(onBus: 0)
        guard let request else { return }
        request.endAudio()
        self.request = nil
        onState(.stopped)
    }

    func cancel() {
        generation += 1
        task?.cancel()
        task = nil
        stop()
    }

    private func authorise(_ done: @escaping (String?) -> Void) {
        if SFSpeechRecognizer.authorizationStatus() == .authorized,
           AVCaptureDevice.authorizationStatus(for: .audio) == .authorized {
            return done(nil)
        }
        SFSpeechRecognizer.requestAuthorization { status in
            guard status == .authorized else {
                return DispatchQueue.main.async { done("Allow Speech Recognition for Beeline in Privacy & Security.") }
            }
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async { done(granted ? nil : "Allow the Microphone for Beeline in Privacy & Security.") }
            }
        }
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

    private func begin(_ session: Int) {
        guard let recognizer, recognizer.isAvailable else {
            return onState(.unavailable("Speech recognition isn't available right now."))
        }
        guard recognizer.supportsOnDeviceRecognition else {
            return onState(.unavailable("On-device speech recognition isn't available for English on this Mac."))
        }
        guard !engine.isRunning else { return }
        task?.cancel()
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        // A Mac with no microphone reports a format of 0 Hz and no channels, and installing a tap on it stops the app.
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            return onState(.unavailable("No microphone found."))
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        request.contextualStrings = Self.contextualStrings(vocabulary)
        self.request = request

        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            request.append(buffer)
            let level = Self.level(of: buffer)
            DispatchQueue.main.async {
                guard let self, session == self.generation else { return }
                self.onLevel(level)
            }
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            return onState(.unavailable("The microphone couldn't start."))
        }
        onState(.listening)

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal == true
            let finished = isFinal || error != nil
            DispatchQueue.main.async {
                guard let self, session == self.generation else { return }
                if let text { self.onText(text) }
                if isFinal, let text { self.onFinal(text) }
                if finished { self.task = nil; self.request = nil }
            }
        }
    }
}
