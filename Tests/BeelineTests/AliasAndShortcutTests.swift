import Foundation
import Testing
@testable import Beeline

private func scratchAliases() -> Aliases {
    Aliases(file: FileManager.default.temporaryDirectory.appendingPathComponent("beeline-aliases-\(UUID().uuidString).json"))
}

private let music = Item(id: "/Applications/Music.app", kind: .app, verb: "Open", title: "Music", subtitle: "App", keywords: "", icon: nil, run: {})

@Test func anAliasMatchesItsExactWords() {
    let aliases = scratchAliases()
    #expect(aliases.set("  T ", for: music))
    #expect(aliases.matches("t", music))
    #expect(!aliases.matches("tu", music))
    aliases.remove("t")
    #expect(!aliases.matches("t", music))
    #expect(!aliases.set("   ", for: music))
}

@Test func aliasesSurviveARelaunch() {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("beeline-aliases-\(UUID().uuidString).json")
    let first = Aliases(file: file)
    first.set("mu", for: music)
    first.flush()
    #expect(Aliases(file: file).matches("mu", music))
}

// The user's alias ranks first, above learned picks and name matches.
@Test func anAliasRanksFirst() {
    TestEnvironment.prepare()
    let finder = try! #require(sharedCatalogue.search("finder").first { $0.title == "Finder" })
    sharedCatalogue.aliases.set("zq", for: finder)
    defer { sharedCatalogue.aliases.remove("zq") }
    let top = sharedCatalogue.search("zq").first
    #expect(top?.title == "Finder")
    #expect(top?.isAlias == true)
}

@Test func onlyLastingThingsCanHaveAnAlias() {
    #expect(Catalogue.canHaveAlias(music))
    let reminder = Item(id: "reminder:call", kind: .action, verb: "", title: "Remind me", subtitle: "", keywords: "", icon: nil, run: {})
    #expect(!Catalogue.canHaveAlias(reminder))
    let sum = Item(id: "calc", kind: .calculation, verb: "", title: "4", subtitle: "", keywords: "", icon: nil, run: {})
    #expect(!Catalogue.canHaveAlias(sum))
}

@Test func shortcutNamesAreReadOnePerLine() {
    #expect(UserShortcuts.parse("Morning routine\n  Log water \n\nMorning routine\n") == ["Morning routine", "Log water"])
    let items = UserShortcuts.items(["Log water"])
    #expect(items.first?.id == "shortcut:Log water")
    #expect(items.first?.verb == "Run Shortcut")
}

// Your own shortcuts are found by name, but can do anything, so they are never a step in Claude's plans.
@Test func shortcutsAreResultsButNeverPlanSteps() {
    TestEnvironment.prepare()
    let saved = sharedCatalogue.shortcuts
    defer { sharedCatalogue.shortcuts = saved }
    sharedCatalogue.shortcuts = UserShortcuts.items(["Log water intake"])
    #expect(sharedCatalogue.search("log water").first?.id == "shortcut:Log water intake")
    #expect(!sharedCatalogue.planOptions().contains { $0.text.contains("Log water") })
}
