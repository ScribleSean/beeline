import Carbon.HIToolbox
import Foundation
import Testing
@testable import Beeline

@Test func invalidStoredShortcutFallsBackToCommand() throws {
    let suite = "beeline-test-shortcut-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set("invalid", forKey: Settings.shortcut)
    let candidates = AppDelegate.shortcutCandidates(defaults: defaults)
    #expect(candidates.map(\.name) == ["command", "option", "control"])
    #expect(candidates.first?.modifiers == UInt32(cmdKey))
}

@Test(arguments: ["command", "option", "control"])
func validStoredShortcutKeepsItsPriority(_ preferred: String) throws {
    let suite = "beeline-test-shortcut-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(preferred, forKey: Settings.shortcut)
    let candidates = AppDelegate.shortcutCandidates(defaults: defaults)
    #expect(candidates.map(\.name) == [preferred] + ["command", "option", "control"].filter { $0 != preferred })
    let modifiers = ["command": cmdKey, "option": optionKey, "control": controlKey]
    for candidate in candidates {
        #expect(candidate.modifiers == modifiers[candidate.name].map(UInt32.init))
    }
}

@Test func scriptDrainsLargeStandardErrorWithoutWaitingForTimeout() {
    let source = """
        set payload to "x"
        repeat 17 times
            set payload to payload & payload
        end repeat
        log payload
        return "done"
        """
    let started = Date()
    #expect(Actions.runScript(source, what: "test") == "done")
    #expect(Date().timeIntervalSince(started) < 5)
}
