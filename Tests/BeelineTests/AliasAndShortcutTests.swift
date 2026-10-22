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
    // A catalogue of its own: changing the shared one would race the tests reading it.
    TestEnvironment.prepare()
    let catalogue = Catalogue(aliases: scratchAliases())
    let finder = try! #require(catalogue.search("finder").first { $0.title == "Finder" })
    catalogue.aliases.set("zq", for: finder)
    defer { catalogue.aliases.remove("zq") }
    let top = catalogue.search("zq").first
    #expect(top?.title == "Finder")
    #expect(top?.isAlias == true)
}

@Test func onlyLastingThingsCanHaveAnAlias() {
    #expect(Catalogue.canHaveAlias(music))
    let fleeting: [Item] = [
        Item(id: "reminder:call", kind: .action, verb: "", title: "Remind me", subtitle: "", keywords: "", icon: nil, run: {}),
        Item(id: "calc", kind: .calculation, verb: "", title: "4", subtitle: "", keywords: "", icon: nil, run: {}),
        Item(id: "undo", kind: .action, verb: "Undo", title: "Mute", subtitle: "Undo", keywords: "", icon: nil, run: {}),
    ]
    for item in fleeting {
        #expect(!Catalogue.canHaveAlias(item), Comment(rawValue: item.id))
    }
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
    let catalogue = Catalogue()
    catalogue.shortcuts = UserShortcuts.items(["Log water intake"])
    #expect(catalogue.search("log water").first?.id == "shortcut:Log water intake")
    #expect(!catalogue.planOptions().contains { $0.text.contains("Log water") })
}
