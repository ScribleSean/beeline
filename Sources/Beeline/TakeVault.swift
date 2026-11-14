import AVFoundation

/// Keeps the audio of a voice take on this Mac while it is transcribed, so a take that came back empty
/// can be run again. A take is deleted once it is heard, after `lifetime`, once more than `keep` exist,
/// and when Beeline starts or quits. Each file is private to this user and left out of backups from the
/// moment it is created. Nothing here touches the network.
final class TakeVault {
    static let keep = 3
    static let lifetime: TimeInterval = 15 * 60
    /// The longest take that is kept. Audio after this is still transcribed, only not saved.
    static let longest: TimeInterval = 120

    let folder: URL
    private let lock = NSLock()

    init(folder: URL = TestRun.supportFolder.appendingPathComponent("Takes", isDirectory: true)) {
        self.folder = folder
    }

    final class Recording {
        let url: URL
        private var file: AVAudioFile?
        private let lock = NSLock()
        private var frameCount: AVAudioFramePosition = 0
        private var closed = false
        private let limit: TimeInterval
        var frames: AVAudioFramePosition { lock.lock(); defer { lock.unlock() }; return frameCount }

        fileprivate init(url: URL, limit: TimeInterval) { self.url = url; self.limit = limit }

        /// Called from the audio thread; the first buffer's format fixes the file's format.
        func append(_ buffer: AVAudioPCMBuffer) {
            lock.lock()
            defer { lock.unlock() }
            guard !closed else { return }
            if file == nil {
                file = try? AVAudioFile(forWriting: url, settings: buffer.format.settings,
                                        commonFormat: buffer.format.commonFormat, interleaved: buffer.format.isInterleaved)
                // Opening for writing may replace the file `begin` made, so protect it again before any audio is in it.
                guard file != nil, TakeVault.protect(url) else { file = nil; closed = true; return }
            }
            let room = AVAudioFramePosition(limit * buffer.format.sampleRate) - frameCount
            guard room >= AVAudioFramePosition(buffer.frameLength) else { closed = true; file = nil; return }
            guard let file, (try? file.write(from: buffer)) != nil else { return }
            frameCount += AVAudioFramePosition(buffer.frameLength)
        }

        fileprivate func close() {
            lock.lock()
            closed = true
            file = nil
            lock.unlock()
        }
    }

    /// Owner-only and out of Time Machine and iCloud backups. False when either could not be set.
    fileprivate static func protect(_ url: URL) -> Bool {
        var item = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        return (try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)) != nil
            && (try? item.setResourceValues(values)) != nil
    }

    /// Makes the empty, already protected file for a new take. Nil when it can't be made private.
    func begin(now: Date = Date(), limit: TimeInterval = TakeVault.longest) -> Recording? {
        lock.lock()
        defer { lock.unlock() }
        do { try JSONStore.createPrivateDirectory(folder) } catch { return nil }
        var excluded = folder
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? excluded.setResourceValues(values)
        prune(now: now)
        let stamp = String(Int(now.timeIntervalSince1970 * 1000))
        let url = folder.appendingPathComponent("take-\(stamp)-\(UUID().uuidString.prefix(6)).caf")
        guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]),
              Self.protect(url) else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return Recording(url: url, limit: limit)
    }

    /// Closes the file. A take with no audio is removed; returns the saved file otherwise.
    @discardableResult
    func finish(_ recording: Recording, now: Date = Date()) -> URL? {
        recording.close()
        lock.lock()
        defer { lock.unlock() }
        guard recording.frames > 0 else {
            try? FileManager.default.removeItem(at: recording.url)
            return nil
        }
        prune(now: now)
        return recording.url
    }

    /// Saved takes, newest first, none older than `lifetime`.
    func takes(now: Date = Date()) -> [URL] {
        lock.lock()
        defer { lock.unlock() }
        return saved(now: now).map(\.url)
    }

    func latest(now: Date = Date()) -> URL? { takes(now: now).first }

    /// Drops a take the user cancelled.
    func abandon(_ recording: Recording) {
        recording.close()
        discard(recording.url)
    }

    func discard(_ url: URL) {
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.removeItem(at: url)
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        for take in saved(now: .distantPast, expiring: false) { try? FileManager.default.removeItem(at: take.url) }
    }

    /// Deletes expired and surplus takes; run when a take's time is up.
    func sweep(now: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }
        prune(now: now)
    }

    private func prune(now: Date) {
        let live = saved(now: now)
        let keepers = Set(live.prefix(Self.keep).map(\.url))
        for take in saved(now: now, expiring: false) where !keepers.contains(take.url) {
            try? FileManager.default.removeItem(at: take.url)
        }
    }

    private func saved(now: Date, expiring: Bool = true) -> [(url: URL, date: Date)] {
        let names = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return names.filter { $0.pathExtension == "caf" }
            .compactMap { url -> (url: URL, date: Date)? in
                guard let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else { return nil }
                return (url, date)
            }
            .filter { !expiring || now.timeIntervalSince($0.date) <= Self.lifetime }
            .sorted { $0.date > $1.date }
    }
}

/// Hands the microphone buffers from the audio thread to whichever take is being recorded.
final class TakeTap {
    private let lock = NSLock()
    private var recording: TakeVault.Recording?

    func start(_ recording: TakeVault.Recording?) {
        lock.lock(); self.recording = recording; lock.unlock()
    }

    func end() -> TakeVault.Recording? {
        lock.lock(); defer { lock.unlock() }
        let current = recording
        recording = nil
        return current
    }

    func write(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); let current = recording; lock.unlock()
        current?.append(buffer)
    }
}
