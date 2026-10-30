import AppKit
import Testing
@testable import Beeline

private let calculatorPath = "/System/Applications/Calculator.app"

private func app(_ path: String = calculatorPath, source: Source = .words) -> Item {
    var item = Item(id: path, kind: .app, verb: "Open", title: "Calculator", subtitle: "App", keywords: "", icon: nil, run: {})
    item.source = source
    return item
}

private func tab() -> Item {
    var item = Item(id: "tab:com.apple.Safari:1:1", kind: .tab, verb: "Switch to tab", title: "Flights",
                    subtitle: "Safari", keywords: "", icon: nil, run: {})
    item.link = URL(string: "https://example.com/flights")
    return item
}

/// The shared model with hand-set rows, no panel, nothing armed and a private pasteboard.
@MainActor private func ready(_ query: String, _ rows: [Item]) -> BarModel {
    let model = sharedModel
    model.closeActions(refreshing: false)
    model.armedID = nil
    model.clearPlan()
    model.query = query
    model.results = rows
    model.selected = 0
    model.pasteboard = NSPasteboard(name: NSPasteboard.Name("beeline-tests-\(UUID().uuidString)"))
    return model
}

@Test @MainActor func anAppOffersOpenCopyPathFinderAndAlias() {
    let model = ready("calc", [app()])
    #expect(model.actions(for: app()).map(\.id) == [.open, .copy, .reveal, .alias])
    #expect(model.actions(for: app()).map(\.title) == ["Open", "Copy path", "Show in Finder", "Make “calc” its alias"])
}

@Test @MainActor func aTabCopiesItsLinkAndHasNoFinder() {
    let model = ready("fl", [tab()])
    let actions = model.actions(for: tab())
    #expect(actions.map(\.id) == [.open, .copy, .copyMarkdown])
    #expect(BarModel.copyable(tab())?.text == "https://example.com/flights")
    #expect(actions[1].title == "Copy link")
    #expect(actions[2].title == "Copy as Markdown link")
}

@Test @MainActor func aTabCopiesAsAMarkdownLinkFromThePanelOrItsKey() {
    var ran: [String] = []
    let model = ready("fl", [tab()])
    model.onRun = { ran.append($0.id) }
    #expect(model.perform(.copyMarkdown))
    #expect(model.pasteboard.string(forType: .string) == "[Flights](https://example.com/flights)")
    #expect(ran == ["copied"])
    #expect(!model.actions(for: app()).contains { $0.id == .copyMarkdown })
}

@Test func markdownLinksEscapeWhatWouldBreakThem() {
    var item = tab()
    item = Item(id: item.id, kind: .tab, verb: item.verb, title: #"[Draft] a\b"#, subtitle: "", keywords: "", icon: nil, run: {})
    item.link = URL(string: "https://en.wikipedia.org/wiki/Bee_(disambiguation)")
    #expect(BarModel.markdownLink(item) == #"[\[Draft\] a\\b](https://en.wikipedia.org/wiki/Bee_%28disambiguation%29)"#)
    var untitled = Item(id: "tab:x", kind: .tab, verb: "", title: "", subtitle: "", keywords: "", icon: nil, run: {})
    untitled.link = URL(string: "https://example.com/")
    #expect(BarModel.markdownLink(untitled) == "[https://example.com/](https://example.com/)")
}

@Test @MainActor func typingInThePanelNarrowsItsActions() {
    var ran: [String] = []
    let model = ready("calc", [app()])
    model.onRun = { ran.append($0.id) }
    #expect(model.toggleActions())
    model.moveAction(1)
    #expect(model.typeInActions("fi"))
    #expect(model.visibleActions.map(\.id) == [.reveal])
    #expect(model.actionSelected == 0)
    #expect(model.query == "calc")
    #expect(model.showsActions)
    model.deleteActionFilter()
    model.deleteActionFilter()
    #expect(model.visibleActions == model.panelActions)
    // Words match from their start, in any order, ignoring case.
    #expect(model.typeInActions("PATH c"))
    #expect(model.visibleActions.map(\.title) == ["Copy path"])
    model.performSelectedAction()
    #expect(model.pasteboard.string(forType: .string) == calculatorPath)
    #expect(ran == ["copied"])
}

@Test @MainActor func aFilterWithNoMatchRunsNothingAndReopeningClearsIt() {
    var ran: [String] = []
    let model = ready("calc", [app()])
    model.onRun = { ran.append($0.id) }
    #expect(model.toggleActions())
    #expect(model.typeInActions("zz"))
    #expect(model.visibleActions.isEmpty)
    model.moveAction(1)
    model.performSelectedAction()
    #expect(ran.isEmpty)
    #expect(model.showsActions)
    #expect(model.toggleActions())
    #expect(model.toggleActions())
    #expect(model.actionFilter.isEmpty)
    #expect(model.visibleActions == model.panelActions)
    model.closeActions(refreshing: false)
}

@Test @MainActor func keysThatTypeNothingAreNotFiltered() {
    let model = ready("calc", [app()])
    #expect(model.toggleActions())
    for key in ["\t", "\r", "\u{1b}", "\u{F700}", ""] {
        #expect(!model.typeInActions(key), Comment(rawValue: key.debugDescription))
    }
    #expect(model.actionFilter.isEmpty)
    #expect(model.typeInActions("é"))
    model.closeActions(refreshing: false)
    #expect(!model.typeInActions("a"))
}

@Test @MainActor func learnedAndAliasRowsOfferToUndoThatInsteadOfAnAlias() {
    let model = ready("calc", [])
    #expect(model.actions(for: app(source: .learned(2))).map(\.title).suffix(2) == ["Forget pick", "Make “calc” its alias"])
    #expect(model.actions(for: app(source: .alias)).last?.title == "Remove alias")
    #expect(!model.actions(for: app(source: .alias)).contains { $0.id == .alias })
}

@Test @MainActor func rowsWithNothingButOpenHaveNoPanel() {
    let model = ready("4+4", [])
    let answer = Item(id: "calc", kind: .calculation, verb: "", title: "8", subtitle: "", keywords: "", icon: nil, run: {})
    let claude = Item(id: BarModel.claudeRowID, kind: .action, verb: "", title: "Ask Claude", subtitle: "", keywords: "", icon: nil, run: {})
    let clip = Item(id: "clip:0:1", kind: .clipboard, verb: "Paste", title: "secret", subtitle: "", keywords: "", icon: nil, run: {})
    for item in [answer, claude, clip] {
        #expect(model.actions(for: item).isEmpty, Comment(rawValue: item.id))
    }
    model.results = [clip]
    #expect(!model.toggleActions())
    #expect(!model.showsActions)
}

@Test @MainActor func thePanelStaysOnItsRowWhileTheListChanges() {
    var ran: [String] = []
    let model = ready("calc", [app(), tab()])
    model.onRun = { ran.append($0.id) }
    #expect(model.toggleActions())
    model.results = [tab(), app()]
    model.selected = 0
    model.moveAction(1)
    model.performSelectedAction()
    #expect(model.pasteboard.string(forType: .string) == calculatorPath)
    #expect(ran == ["copied"])
    #expect(!model.showsActions)
}

@Test @MainActor func theTextFieldWritingTheSameTextBackKeepsThePanelOpen() {
    let model = ready("calc", [app()])
    #expect(model.toggleActions())
    model.query = "calc"
    #expect(model.showsActions)
    model.query = "calcu"
    #expect(!model.showsActions)
}

@Test @MainActor func showInFinderClosesTheBarThenRevealsThePath() {
    var ran: [Item] = []
    var revealed: [URL] = []
    let model = ready("calc", [app()])
    model.onRun = { ran.append($0) }
    model.revealInFinder = { revealed.append($0) }
    defer { model.revealInFinder = { NSWorkspace.shared.activateFileViewerSelecting([$0]) } }
    #expect(model.perform(.reveal))
    #expect(ran.map(\.id) == ["revealed"])
    #expect(revealed.isEmpty)
    ran.first?.run()
    #expect(revealed == [URL(fileURLWithPath: calculatorPath)])
}

@Test @MainActor func aShortcutTheRowDoesNotOfferIsLeftAlone() {
    var ran: [String] = []
    let model = ready("fl", [tab()])
    model.onRun = { ran.append($0.id) }
    #expect(!model.perform(.reveal))
    #expect(!model.perform(.forget))
    #expect(ran.isEmpty)
}

@Test @MainActor func makingAnAliasFromThePanelSavesIt() {
    let model = ready("zqx", [app()])
    defer { model.catalogue.aliases.remove("zqx") }
    #expect(model.toggleActions())
    model.actionSelected = model.focusedActions.firstIndex { $0.id == .alias } ?? -1
    model.performSelectedAction()
    #expect(model.catalogue.aliases.matches("zqx", app()))
    #expect(!model.showsActions)
}

@Test @MainActor func noPanelWhileAConfirmCardOrPlanIsUp() {
    var risky = app()
    risky.needsConfirm = true
    let model = ready("calc", [risky])
    model.onRun = { _ in }
    model.run(risky)
    #expect(model.armedID == risky.id)
    #expect(!model.toggleActions())
    model.armedID = nil
    model.planProblem = "Claude found no way to do that."
    #expect(!model.toggleActions())
    model.clearPlan()
    #expect(model.toggleActions())
    model.closeActions(refreshing: false)
}

@Test @MainActor func aFileThatVanishesDoesNotShiftTheHighlightedAction() throws {
    let file = TestEnvironment.scratch.appendingPathComponent("vanish-\(UUID().uuidString).txt")
    try "x".write(to: file, atomically: true, encoding: .utf8)
    let row = Item(id: file.path, kind: .file, verb: "Open", title: file.lastPathComponent, subtitle: "", keywords: "", icon: nil, run: {})
    var ran: [String] = []
    let model = ready("vfx", [row])
    model.onRun = { ran.append($0.id) }
    defer { model.catalogue.aliases.remove("vfx") }
    #expect(model.toggleActions())
    let reveal = try #require(model.panelActions.firstIndex { $0.id == .reveal })
    model.actionSelected = reveal
    try FileManager.default.removeItem(at: file)
    model.performSelectedAction()
    #expect(ran.isEmpty)
    #expect(!model.catalogue.aliases.matches("vfx", row))
    #expect(BarModel.copyable(row)?.text == file.path)
}
