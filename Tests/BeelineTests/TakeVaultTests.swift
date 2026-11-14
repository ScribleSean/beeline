import AVFoundation
import Foundation
import Testing
@testable import Beeline

/// Speech made by `say`, so no person's voice is ever in a test. Nil when this host can't synthesise.
private func spoken(_ words: String = "open TextEdit") -> URL? {
    guard FileManager.default.isExecutableFile(atPath: "/usr/bin/say") else { return nil }
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("beeline-take-\(UUID().uuidString).aiff")
    let say = Process()
    say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
    say.arguments = ["-o", url.path, words]
    guard (try? say.run()) != nil else { return nil }
    let timeout = DispatchWorkItem { if say.isRunning { say.terminate() } }
    DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: timeout)
    say.waitUntilExit()
    timeout.cancel()
    guard say.terminationStatus == 0, let file = try? AVAudioFile(forReading: url), file.length > 0 else {
        try? FileManager.default.removeItem(at: url)
        return nil
    }
    return url
}

private func buffers(of url: URL) throws -> [AVAudioPCMBuffer] {
    let file = try AVAudioFile(forReading: url)
    var out: [AVAudioPCMBuffer] = []
    while file.framePosition < file.length {
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 1024))
        try file.read(into: buffer, frameCount: 1024)
        if buffer.frameLength == 0 { break }
        out.append(buffer)
    }
    return out
}

private func vault() -> TakeVault {
    TakeVault(folder: FileManager.default.temporaryDirectory.appendingPathComponent("beeline-vault-\(UUID().uuidString)", isDirectory: true))
}

private func record(_ vault: TakeVault, _ audio: [AVAudioPCMBuffer], at date: Date) -> URL? {
    guard let recording = vault.begin(now: date) else { return nil }
    audio.forEach(recording.append)
    guard let url = vault.finish(recording, now: date) else { return nil }
    try? FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    return url
}

@Test func savedTakeHoldsEveryFrameAndIsPrivate() throws {
    guard let source = spoken() else { return }
    defer { try? FileManager.default.removeItem(at: source) }
    let vault = vault()
    defer { try? FileManager.default.removeItem(at: vault.folder) }
    let audio = try buffers(of: source)
    let url = try #require(record(vault, audio, at: Date()))
    #expect(try AVAudioFile(forReading: url).length == (try AVAudioFile(forReading: source)).length)
    let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
    #expect(mode == 0o600)
    let folder = try FileManager.default.attributesOfItem(atPath: vault.folder.path)[.posixPermissions] as? Int
    #expect(folder == 0o700)
}

private func isExcludedFromBackup(_ url: URL) -> Bool {
    (try? URL(fileURLWithPath: url.path).resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup) ?? false
}

@Test func aTakeIsPrivateAndOutOfBackupsWhileItIsStillRecording() throws {
    guard let source = spoken() else { return }
    defer { try? FileManager.default.removeItem(at: source) }
    let vault = vault()
    defer { try? FileManager.default.removeItem(at: vault.folder) }
    let recording = try #require(vault.begin())
    let mode = { try FileManager.default.attributesOfItem(atPath: recording.url.path)[.posixPermissions] as? Int }
    #expect(try mode() == 0o600) // before any audio
    #expect(isExcludedFromBackup(recording.url))
    #expect(isExcludedFromBackup(vault.folder))
    recording.append(try #require(try buffers(of: source).first))
    #expect(try mode() == 0o600) // after the audio file opened it
    #expect(isExcludedFromBackup(recording.url))
    vault.abandon(recording)
}

@Test func aTakeStopsGrowingAtItsLimit() throws {
    guard let source = spoken("one two three four five six seven eight nine ten") else { return }
    defer { try? FileManager.default.removeItem(at: source) }
    let vault = vault()
    defer { try? FileManager.default.removeItem(at: vault.folder) }
    let audio = try buffers(of: source)
    let rate = audio[0].format.sampleRate
    let recording = try #require(vault.begin(limit: 0.25))
    audio.forEach(recording.append)
    let url = try #require(vault.finish(recording))
    let length = try AVAudioFile(forReading: url).length
    #expect(length > 0)
    #expect(Double(length) <= 0.25 * rate)
    #expect(length < (try AVAudioFile(forReading: source)).length)
}

@Test @MainActor func aTakeThatWasHeardIsDeletedAtOnce() throws {
    guard let source = spoken() else { return }
    defer { try? FileManager.default.removeItem(at: source) }
    let vault = vault()
    defer { try? FileManager.default.removeItem(at: vault.folder) }
    let tap = TakeTap()
    var finish: ((String?, Bool, Bool) -> Void)?
    let voice = Voice(io: Voice.IO(authorise: { $0(nil) }, begin: { _, update, _ in finish = update; return nil }, stop: {}, cancel: {}),
                      vault: vault, tap: tap)
    voice.makeReplay = { _ in Voice.IO(authorise: { $0(nil) }, begin: { _, _, _ in nil }, stop: {}, cancel: {}) }
    var missed = 0
    voice.onMissed = { missed += 1 }
    voice.start()
    try buffers(of: source).forEach(tap.write)
    voice.stop()
    #expect(vault.takes().count == 1) // kept until the recognizer answers
    finish?("open TextEdit", true, true)
    #expect(missed == 0)
    #expect(voice.lastTake == nil)
    #expect(((try? FileManager.default.contentsOfDirectory(atPath: vault.folder.path)) ?? []).isEmpty)
    #expect(!voice.retry())
}

@Test @MainActor func takesFromAnEarlierRunAreDeletedAtLaunchAndAtQuit() throws {
    guard let source = spoken() else { return }
    defer { try? FileManager.default.removeItem(at: source) }
    let vault = vault()
    defer { try? FileManager.default.removeItem(at: vault.folder) }
    let audio = try buffers(of: source)
    _ = try #require(record(vault, audio, at: Date()))
    let voice = Voice(io: Voice.IO(authorise: { $0(nil) }, begin: { _, _, _ in nil }, stop: {}, cancel: {}), vault: vault)
    #expect(vault.takes().isEmpty)
    _ = try #require(record(vault, audio, at: Date()))
    voice.forgetTakes()
    #expect(vault.takes().isEmpty)
}

@Test func vaultKeepsOnlyTheNewestThreeTakes() throws {
    guard let source = spoken() else { return }
    defer { try? FileManager.default.removeItem(at: source) }
    let vault = vault()
    defer { try? FileManager.default.removeItem(at: vault.folder) }
    let audio = try buffers(of: source)
    let now = Date()
    let urls = (0..<5).compactMap { record(vault, audio, at: now.addingTimeInterval(Double($0 - 5))) }
    #expect(urls.count == 5)
    let kept = vault.takes(now: now)
    #expect(kept.map(\.lastPathComponent) == [urls[4], urls[3], urls[2]].map(\.lastPathComponent))
    for gone in urls[0..<2] { #expect(!FileManager.default.fileExists(atPath: gone.path)) }
}

@Test func takesExpireAndAreDeletedFromDisk() throws {
    guard let source = spoken() else { return }
    defer { try? FileManager.default.removeItem(at: source) }
    let vault = vault()
    defer { try? FileManager.default.removeItem(at: vault.folder) }
    let audio = try buffers(of: source)
    let then = Date().addingTimeInterval(-TakeVault.lifetime - 60)
    let old = try #require(record(vault, audio, at: then))
    #expect(vault.latest() == nil)
    _ = vault.begin()
    #expect(!FileManager.default.fileExists(atPath: old.path))
}

@Test func emptyAndCancelledTakesLeaveNothingBehind() throws {
    guard let source = spoken() else { return }
    defer { try? FileManager.default.removeItem(at: source) }
    let vault = vault()
    defer { try? FileManager.default.removeItem(at: vault.folder) }
    let silent = try #require(vault.begin())
    #expect(vault.finish(silent) == nil)
    let cancelled = try #require(vault.begin())
    try buffers(of: source).forEach(cancelled.append)
    vault.abandon(cancelled)
    #expect(vault.takes().isEmpty)
    #expect(((try? FileManager.default.contentsOfDirectory(atPath: vault.folder.path)) ?? []).isEmpty)
}

@Test func vaultCodeHasNoNetworkAccess() throws {
    let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Sources/Beeline/TakeVault.swift")
    let text = try String(contentsOf: file, encoding: .utf8)
    for word in ["URLSession", "http://", "https://", "NWConnection", "URLRequest"] { #expect(!text.contains(word)) }
}

@Test @MainActor func failedTakeIsKeptThenRetryReplaysTheSavedAudio() async throws {
    guard let source = spoken() else { return }
    defer { try? FileManager.default.removeItem(at: source) }
    let vault = vault()
    defer { try? FileManager.default.removeItem(at: vault.folder) }
    let audio = try buffers(of: source)
    let tap = TakeTap()
    var finish: ((String?, Bool, Bool) -> Void)?
    let io = Voice.IO(authorise: { $0(nil) },
                      begin: { _, update, _ in finish = update; return nil },
                      stop: {}, cancel: {})
    let voice = Voice(io: io, vault: vault, tap: tap)
    var missed = 0
    var heard: [String] = []
    voice.onMissed = { missed += 1 }
    voice.onFinal = { heard.append($0) }

    // Live take: the microphone buffers arrive, the recognizer then reports nothing.
    voice.start()
    audio.forEach(tap.write)
    voice.stop()
    finish?(nil, false, true)
    #expect(missed == 1)
    let saved = try #require(voice.lastTake)
    #expect(try AVAudioFile(forReading: saved).length == (try AVAudioFile(forReading: source)).length)

    // Retry: the saved file is fed back through a recognizer, which this time hears it.
    var replayed: AVAudioFramePosition = 0
    var replayUpdate: ((String?, Bool, Bool) -> Void)?
    voice.makeReplay = { audio in
        Voice.IO(authorise: { $0(nil) }, begin: { _, update, level in
            replayUpdate = update
            do { _ = try audio.start(consume: { replayed += AVAudioFramePosition($0.frameLength) }, level: level); return nil }
            catch { return error.localizedDescription }
        }, stop: { audio.stop() }, cancel: { audio.stop() })
    }
    #expect(voice.retry())
    for _ in 0..<100 where replayed < (try AVAudioFile(forReading: source)).length {
        try await Task.sleep(nanoseconds: 100_000_000)
    }
    #expect(replayed == (try AVAudioFile(forReading: source)).length)
    replayUpdate?("open TextEdit", true, true)
    #expect(heard == ["open TextEdit"])
    #expect(missed == 1)
    #expect(!FileManager.default.fileExists(atPath: saved.path)) // heard, so no longer kept
}

@Test @MainActor func cancelledTakeIsDeletedAndCannotBeRetried() async throws {
    guard let source = spoken() else { return }
    defer { try? FileManager.default.removeItem(at: source) }
    let vault = vault()
    defer { try? FileManager.default.removeItem(at: vault.folder) }
    let tap = TakeTap()
    let voice = Voice(io: Voice.IO(authorise: { $0(nil) }, begin: { _, _, _ in nil }, stop: {}, cancel: {}), vault: vault, tap: tap)
    voice.makeReplay = { _ in Voice.IO(authorise: { $0(nil) }, begin: { _, _, _ in nil }, stop: {}, cancel: {}) }
    voice.start()
    try buffers(of: source).forEach(tap.write)
    voice.cancel()
    #expect(vault.takes().isEmpty)
    #expect(!voice.retry())
}

@Test @MainActor func aTakeCancelledAfterReleaseOrReplacedByANewHoldIsDeleted() throws {
    guard let source = spoken() else { return }
    defer { try? FileManager.default.removeItem(at: source) }
    let vault = vault()
    defer { try? FileManager.default.removeItem(at: vault.folder) }
    let audio = try buffers(of: source)
    let tap = TakeTap()
    var finish: ((String?, Bool, Bool) -> Void)?
    let voice = Voice(io: Voice.IO(authorise: { $0(nil) }, begin: { _, update, _ in finish = update; return nil }, stop: {}, cancel: {}),
                      vault: vault, tap: tap)
    let files = { ((try? FileManager.default.contentsOfDirectory(atPath: vault.folder.path)) ?? []).count }
    // Let go, then dismiss before the recognizer answers.
    voice.start()
    audio.forEach(tap.write)
    voice.stop()
    #expect(files() == 1)
    voice.cancel()
    #expect(files() == 0)
    #expect(voice.lastTake == nil)
    // A take that missed, then a new hold instead of Try again.
    voice.start()
    audio.forEach(tap.write)
    voice.stop()
    finish?(nil, false, true)
    let missed = try #require(voice.lastTake)
    voice.start()
    #expect(!FileManager.default.fileExists(atPath: missed.path))
    voice.cancel()
    #expect(files() == 0)
}

@Test @MainActor func retryNeedsASavedTake() {
    let voice = Voice(io: Voice.IO(authorise: { $0(nil) }, begin: { _, _, _ in nil }, stop: {}, cancel: {}), vault: vault())
    voice.makeReplay = { _ in Voice.IO(authorise: { $0(nil) }, begin: { _, _, _ in nil }, stop: {}, cancel: {}) }
    #expect(!voice.retry())
}

@Test func aLateBufferCannotReopenOrChangeAFinishedTake() throws {
    guard let source = spoken() else { return }
    defer { try? FileManager.default.removeItem(at: source) }
    let vault = vault()
    defer { try? FileManager.default.removeItem(at: vault.folder) }
    let audio = try buffers(of: source)
    let recording = try #require(vault.begin())
    audio.forEach(recording.append)
    let url = try #require(vault.finish(recording))
    let length = try AVAudioFile(forReading: url).length
    recording.append(audio[0])
    #expect(try AVAudioFile(forReading: url).length == length)
    vault.abandon(recording)
    recording.append(audio[0])
    #expect(!FileManager.default.fileExists(atPath: url.path))
}

@Test @MainActor func aSilentTakeNeverRetriesAnOlderOne() throws {
    guard let source = spoken() else { return }
    defer { try? FileManager.default.removeItem(at: source) }
    let vault = vault()
    defer { try? FileManager.default.removeItem(at: vault.folder) }
    _ = record(vault, try buffers(of: source), at: Date())
    let voice = Voice(io: Voice.IO(authorise: { $0(nil) }, begin: { _, _, _ in nil }, stop: {}, cancel: {}), vault: vault)
    voice.makeReplay = { _ in Voice.IO(authorise: { $0(nil) }, begin: { _, _, _ in nil }, stop: {}, cancel: {}) }
    voice.start()
    voice.stop() // no audio arrived
    #expect(voice.lastTake == nil)
    #expect(!voice.retry())
}

@Test @MainActor func aFailedRetryStartLeavesTheMicrophoneInCharge() async throws {
    guard let source = spoken() else { return }
    defer { try? FileManager.default.removeItem(at: source) }
    let vault = vault()
    defer { try? FileManager.default.removeItem(at: vault.folder) }
    let tap = TakeTap()
    var liveBegins = 0
    let voice = Voice(io: Voice.IO(authorise: { $0(nil) }, begin: { _, _, _ in liveBegins += 1; return nil }, stop: {}, cancel: {}),
                      vault: vault, tap: tap)
    voice.makeReplay = { _ in Voice.IO(authorise: { $0("no permission") }, begin: { _, _, _ in nil }, stop: {}, cancel: {}) }
    voice.start()
    try buffers(of: source).forEach(tap.write)
    voice.stop()
    #expect(voice.retry())
    voice.start()
    #expect(liveBegins == 2)
    voice.stop()
}
