import AVFoundation
import Speech

/// A demo-only audio source. Recognition stays in the same sessions used by the microphone.
final class FileSpeechBackend: SpeechBackend {
    let source: Audio
    private let backend: SpeechBackend

    init(source: Audio, backend: SpeechBackend) {
        self.source = source
        self.backend = backend
    }

    static func path(in environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        guard environment["BEELINE_DEMO"] == "voice",
              let path = environment["BEELINE_VOICE_FILE"], !path.isEmpty else { return nil }
        return path
    }

    static func shouldRun(in environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        path(in: environment) != nil && environment["BEELINE_VOICE_RUN"] == "1"
    }

    func begin(_ words: [String], update: @escaping (String?, Bool, Bool) -> Void,
               level: @escaping (Double) -> Void, failed: @escaping () -> Void) -> String? {
        backend.begin(words, update: update, level: level, failed: failed)
    }
    func stop() { backend.stop() }
    func cancel() { backend.cancel() }

    final class Audio {
        let url: URL
        var onEnd: () -> Void = {}
        var onError: (String) -> Void = { DemoLog.note("voice-error", ["why": $0]) }
        private var work: Task<Void, Never>?

        init(url: URL) { self.url = url }

        /// Each buffer owns its storage, just like a microphone tap. Pace at real time to avoid an
        /// unbounded stream and give recognition time to publish partial results before release.
        func start(consume: @escaping (AVAudioPCMBuffer) -> Void,
                   level: @escaping (Double) -> Void) throws -> AVAudioFormat {
            stop()
            let file = try AVAudioFile(forReading: url)
            let format = file.processingFormat
            guard file.length > 0, format.sampleRate > 0, format.channelCount > 0 else {
                throw CocoaError(.fileReadCorruptFile)
            }
            work = Task { @MainActor in
                do {
                    while !Task.isCancelled, file.framePosition < file.length {
                        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024) else {
                            throw CocoaError(.fileReadCorruptFile)
                        }
                        try file.read(into: buffer, frameCount: 1024)
                        guard buffer.frameLength > 0 else { break }
                        consume(buffer)
                        level(Voice.level(of: buffer))
                        try await Task.sleep(nanoseconds: UInt64(Double(buffer.frameLength) / format.sampleRate * 1_000_000_000))
                    }
                    guard !Task.isCancelled else { return }
                    DemoLog.note("voice-eof")
                    self.onEnd()
                } catch is CancellationError {
                } catch {
                    self.onError("Couldn't read voice file: \(error.localizedDescription)")
                    self.onEnd()
                }
            }
            return format
        }

        func stop() { work?.cancel(); work = nil }
    }
}
