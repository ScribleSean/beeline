import AVFoundation
import Foundation
import Testing
@testable import Beeline

/// A bar whose voice has stand-in recognizers: one for the microphone, one for the replay of a saved take.
@MainActor private final class Rig {
    let vault = TakeVault(folder: FileManager.default.temporaryDirectory.appendingPathComponent("beeline-retry-\(UUID().uuidString)", isDirectory: true))
    let tap = TakeTap()
    var liveBegins = 0
    var replayBegins = 0
    var replayCancels = 0
    var liveUpdate: ((String?, Bool, Bool) -> Void)?
    var replayUpdate: ((String?, Bool, Bool) -> Void)?
    private(set) var bar: BarController!

    init() {
        TestEnvironment.prepare()
        let voice = Voice(io: Voice.IO(authorise: { $0(nil) }, begin: { [unowned self] _, update, _ in
            self.liveBegins += 1
            self.liveUpdate = update
            return nil
        }, stop: {}, cancel: {}), vault: vault, tap: tap)
        voice.makeReplay = { [unowned self] _ in
            Voice.IO(authorise: { $0(nil) }, begin: { _, update, _ in self.replayBegins += 1; self.replayUpdate = update; return nil },
                     stop: {}, cancel: { self.replayCancels += 1 })
        }
        bar = BarController(environment: [:], watching: false, voice: voice)
        bar.isShown = true
    }

    /// One hold: half a second of quiet audio reaches the take, then the user lets go.
    func hold() throws {
        bar.startListening()
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8_000))
        buffer.frameLength = 8_000
        tap.write(buffer)
        bar.shortcutReleased()
    }

    /// A hold the recognizer hears nothing in.
    func holdAndMiss() throws {
        try hold()
        liveUpdate?(nil, false, true)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: vault.folder) }
}

@Test @MainActor func aMissedTakeOffersTryAgainOnlyWhileTheBarIsOpen() throws {
    let rig = Rig()
    defer { rig.cleanUp() }
    try rig.holdAndMiss()
    #expect(rig.bar.model.voiceNote == BarController.missedNote)

    let hidden = Rig()
    defer { hidden.cleanUp() }
    try hidden.hold()
    hidden.bar.isShown = false
    #expect(hidden.vault.takes().count == 1) // a take was saved, so the recognizer's answer is a miss
    hidden.liveUpdate?(nil, false, true)
    #expect(hidden.bar.model.voiceNote != BarController.missedNote)
}

@Test @MainActor func aReplayThatHearsNothingOffersTryAgainAgain() throws {
    let rig = Rig()
    defer { rig.cleanUp() }
    try rig.holdAndMiss()
    rig.bar.model.retryTake()
    #expect(rig.bar.model.voiceNote == "Trying again…")
    rig.replayUpdate?(nil, false, true) // the recognizer gives up before the saved audio has played out
    #expect(rig.bar.model.voiceNote == BarController.missedNote)
    rig.bar.model.retryTake()
    #expect(rig.replayBegins == 2)
}

@Test @MainActor func tryAgainReplaysTheTakeAndAHoldEndsTheReplay() throws {
    let rig = Rig()
    defer { rig.cleanUp() }
    try rig.holdAndMiss()
    rig.bar.model.retryTake()
    #expect(rig.replayBegins == 1)
    #expect(rig.bar.model.voiceNote == "Trying again…")
    #expect(rig.liveBegins == 1)

    rig.bar.startListening() // the user holds the shortcut while the replay runs
    #expect(rig.replayCancels == 1)
    #expect(rig.liveBegins == 2)
    #expect(rig.bar.model.voiceNote == "Listening… let go to stop")
}

@Test @MainActor func tryAgainOnATakeThatIsGoneSaysSo() throws {
    let rig = Rig()
    defer { rig.cleanUp() }
    try rig.holdAndMiss()
    rig.vault.clear()
    rig.bar.model.retryTake()
    #expect(rig.replayBegins == 0)
    #expect(rig.bar.model.voiceNote == "That take has expired")
}

@Test @MainActor func closingTheBarDeletesTheTakeItOffered() throws {
    let rig = Rig()
    defer { rig.cleanUp() }
    try rig.holdAndMiss()
    #expect(rig.vault.takes().count == 1)
    rig.bar.toggle() // closes the bar
    #expect(rig.bar.model.voiceNote == nil)
    #expect(rig.vault.takes().isEmpty)
}
