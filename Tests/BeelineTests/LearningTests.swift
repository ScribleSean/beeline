import Foundation
import Testing
@testable import Beeline

private func scratchUsage() -> Usage {
    Usage(file: FileManager.default.temporaryDirectory.appendingPathComponent("beeline-usage-\(UUID().uuidString).json"))
}

private let music = Item(id: "/Applications/Music.app", kind: .app, verb: "Open", title: "Music", subtitle: "App", keywords: "", icon: nil, run: {})

@Test func aPickIsLearnedForItsWords() {
    UserDefaults.standard.set(true, forKey: Settings.learnFromUse)
    let usage = scratchUsage()
    usage.record(music, query: "Tunes")
    #expect(usage.timesPicked(music, for: "tunes") == 1)
    #expect(usage.timesPicked(music, for: "songs") == 0)
}

@Test func anOldPickFades() {
    UserDefaults.standard.set(true, forKey: Settings.learnFromUse)
    let usage = scratchUsage()
    usage.record(music, query: "tunes")
    #expect(usage.timesPicked(music, for: "tunes", now: Date().addingTimeInterval(27 * 86_400)) == 1)
    #expect(usage.timesPicked(music, for: "tunes", now: Date().addingTimeInterval(29 * 86_400)) == 0)
}

@Test func forgettingAPickUndoesIt() {
    UserDefaults.standard.set(true, forKey: Settings.learnFromUse)
    let usage = scratchUsage()
    usage.record(music, query: "tunes")
    usage.record(music, query: "tunes")
    #expect(usage.habitBoost(for: music) > 0)
    usage.record(music, query: "songs")
    usage.forget(music, for: "tunes")
    #expect(usage.timesPicked(music, for: "tunes") == 0)
    #expect(usage.timesPicked(music, for: "songs") == 1)
}

@Test func historyWithoutDatesStillLoads() throws {
    UserDefaults.standard.set(true, forKey: Settings.learnFromUse)
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("beeline-usage-\(UUID().uuidString).json")
    let old = "{\"items\":{\"/Applications/Music.app\":{\"count\":2,\"last\":\(Date().timeIntervalSinceReferenceDate)}},\"queries\":{\"tunes\":{\"/Applications/Music.app\":2}}}"
    defer { try? FileManager.default.removeItem(at: file) }
    try old.write(to: file, atomically: true, encoding: .utf8)
    #expect(Usage(file: file).timesPicked(music, for: "tunes") == 2)
}

@Test func onlyLearnedResultsSayTheyAre() {
    var item = music
    #expect(!item.isLearned)
    item.source = .learned(3)
    #expect(item.isLearned)
}
