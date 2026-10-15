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

    func start() {
        cancelledBeforeStart = false
        authorise { [weak self] problem in
            guard let self else { return }
            if let problem { return self.onState(.unavailable(problem)) }
            guard !self.cancelledBeforeStart else { return }
            self.begin()
        }
    }

    /// Ends listening. The last words still arrive through `onText` a moment later.
    func stop() {
        cancelledBeforeStart = true
        guard engine.isRunning else { return }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        onState(.stopped)
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

    private func begin() {
        guard let recognizer, recognizer.isAvailable else {
            return onState(.unavailable("Speech recognition isn't available right now."))
        }
        task?.cancel()
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        // Keep the audio on this Mac whenever the language supports it.
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        self.request = request

        let input = engine.inputNode
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buffer, _ in
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
                if let text { self?.onText(text) }
                if finished { self?.task = nil; self?.request = nil }
            }
        }
    }
}
