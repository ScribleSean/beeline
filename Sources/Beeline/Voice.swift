import AVFoundation
import Speech

/// Turns speech into text while the shortcut is held, on this Mac. The first use asks for the
/// microphone and speech recognition through the standard macOS prompts.
final class Voice {
    enum State {
        case listening
        case stopped
        case unavailable(String)
    }

    var onText: (String) -> Void = { _ in }
    var onState: (State) -> Void = { _ in }

    private let engine = AVAudioEngine()
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    /// Set when the key comes up before the permission prompts are answered, so listening never starts late.
    private var cancelledBeforeStart = false
    /// Counts listening sessions. A callback from an earlier session is ignored, so an old transcript or a
    /// slow permission answer can never act on a newer one.
    private var generation = 0

    init() {
        // The engine stops itself when the audio hardware changes (AirPods connecting, a mic unplugged).
        // Its tap would otherwise be left behind, and a second tap on the same bus stops the whole app.
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

    /// Ends listening. The last words still arrive through `onText` a moment later.
    func stop() {
        cancelledBeforeStart = true
        if engine.isRunning { engine.stop() }
        // Always, whatever the engine says: removing a tap that is not there is harmless, and leaving one
        // behind after the engine stopped itself is what crashed the next hold.
        engine.inputNode.removeTap(onBus: 0)
        guard let request else { return }
        request.endAudio()
        self.request = nil
        onState(.stopped)
    }

    /// Ends listening and drops anything still to come from it: a transcript that arrives after the bar
    /// has closed, or after the request was sent on, must not act on a newer bar.
    func cancel() {
        generation += 1
        task?.cancel()
        task = nil
        stop()
    }

    private func authorise(_ done: @escaping (String?) -> Void) {
        SFSpeechRecognizer.requestAuthorization { status in
            guard status == .authorized else {
                return DispatchQueue.main.async { done("Allow Speech Recognition for Beeline in Privacy & Security.") }
            }
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async { done(granted ? nil : "Allow the Microphone for Beeline in Privacy & Security.") }
            }
        }
    }

    private func begin(_ session: Int) {
        guard let recognizer, recognizer.isAvailable else {
            return onState(.unavailable("Speech recognition isn't available right now."))
        }
        // Audio never leaves the Mac: without on-device recognition, Beeline does not listen at all.
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
        self.request = request

        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
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
            let finished = result?.isFinal == true || error != nil
            DispatchQueue.main.async {
                guard let self, session == self.generation else { return }
                if let text { self.onText(text) }
                if finished { self.task = nil; self.request = nil }
            }
        }
    }
}
