import AppKit
import Testing
@testable import Beeline

/// A private defaults suite with the given toggles, so these tests never touch the shared defaults that other tests set.
private func withToggles<T>(_ toggles: [String: Bool], _ body: () throws -> T) throws -> T {
    let name = "beeline-test-settings-\(UUID().uuidString)"
    let suite = try #require(UserDefaults(suiteName: name))
    defer { suite.removePersistentDomain(forName: name) }
    for (key, value) in toggles { suite.set(value, forKey: key) }
    return try Settings.$defaults.withValue(suite, operation: body)
}

private let music = Item(id: "/Applications/Music.app", kind: .app, verb: "Open", title: "Music", subtitle: "App", keywords: "", icon: nil, run: {})

private func scratchFile() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("beeline-usage-\(UUID().uuidString).json")
}

@Test func withLearningOffTheReadsAreZeroAndOnTheyAreNot() throws {
    let file = scratchFile()
    let usage = Usage(file: file)
    defer { usage.flush(); try? FileManager.default.removeItem(at: file) }
    try withToggles([Settings.learnFromUse: true]) { usage.record(music, query: "tunes") }
    #expect(try withToggles([Settings.learnFromUse: true]) { usage.timesPicked(music, for: "tunes") == 1 && usage.habitBoost(for: music) > 0 })
    #expect(try withToggles([Settings.learnFromUse: false]) { usage.timesPicked(music, for: "tunes") == 0 && usage.habitBoost(for: music) == 0 })
}

@MainActor @Test func withLearningOffAPickIsNotRecorded() throws {
    let file = scratchFile()
    let usage = Usage(file: file)
    defer { usage.flush(); try? FileManager.default.removeItem(at: file) }
    let catalogue = Catalogue(apps: [], windows: [], quits: [], controls: [], usage: usage)

    try withToggles([Settings.learnFromUse: false]) { catalogue.recordUse(of: music, query: "tunes") }
    #expect(try withToggles([Settings.learnFromUse: true]) { usage.timesPicked(music, for: "tunes") } == 0)

    try withToggles([Settings.learnFromUse: true]) { catalogue.recordUse(of: music, query: "tunes") }
    #expect(try withToggles([Settings.learnFromUse: true]) { usage.timesPicked(music, for: "tunes") } == 1)
}

@Test func withTheBeeOffItDoesNotGuide() throws {
    #expect(try !withToggles([Settings.showBee: false]) { Bee.isEnabled })
    #expect(try withToggles([Settings.showBee: true]) { Bee.isEnabled })
}

@Test func actOnReleaseNeedsBothTogglesUnlessItIsTheVoiceTest() throws {
    #expect(try withToggles([Settings.actOnRelease: true, Settings.holdToTalk: true]) { AutoAct.isAllowed() })
    #expect(try !withToggles([Settings.actOnRelease: false, Settings.holdToTalk: true]) { AutoAct.isAllowed() })
    #expect(try !withToggles([Settings.actOnRelease: true, Settings.holdToTalk: false]) { AutoAct.isAllowed() })
    #expect(try withToggles([Settings.actOnRelease: false, Settings.holdToTalk: false]) { AutoAct.isAllowed(voiceTest: true) })
}

/// With history off, `check()` must not keep a copy. (ClipboardTests cover history on.)
@MainActor @Test func withClipboardHistoryOffACopyIsNotKept() async throws {
    // The read finishes on the main queue, which sees the shared defaults: keep those on, so only the off toggle can stop it.
    let previous = UserDefaults.standard.object(forKey: Settings.clipboardHistory)
    defer {
        if let previous { UserDefaults.standard.set(previous, forKey: Settings.clipboardHistory) }
        else { UserDefaults.standard.removeObject(forKey: Settings.clipboardHistory) }
    }
    UserDefaults.standard.set(true, forKey: Settings.clipboardHistory)
    let board = NSPasteboard(name: NSPasteboard.Name("beeline-test-" + UUID().uuidString))
    let clipboard = Clipboard(board: board)
    board.clearContents()
    board.setString("invoice 42", forType: .string)
    try withToggles([Settings.clipboardHistory: false]) { clipboard.check() }
    clipboard.readQueue.sync {}
    // Any main-queue block the read queued is ahead of this one, so it has run by the time we resume.
    await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in DispatchQueue.main.async { done.resume() } }
    #expect(clipboard.entries.isEmpty)
}
