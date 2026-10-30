import Foundation
import Testing
@testable import Beeline

private func item(_ id: String, confirm: Bool = false) -> Item {
    var item = Item(id: id, kind: .action, verb: "", title: id, subtitle: "Action", keywords: "", icon: nil, run: {})
    item.needsConfirm = confirm
    return item
}

@MainActor let sharedModel: BarModel = {
    TestEnvironment.prepare()
    return BarModel()
}()

@Test @MainActor func secondReturnRunsTheArmedItem() {
    let model = sharedModel
    var ran: [String] = []
    model.onRun = { ran.append($0.id) }
    model.results = [item("Work", confirm: true), item("Weekend", confirm: true)]
    model.selected = 0
    model.runSelected()
    #expect(model.armedID == "Work")
    #expect(ran.isEmpty)
    model.selected = 1
    model.runSelected()
    #expect(ran == ["Work"])
    #expect(model.armedID == nil)
}

@Test @MainActor func returnWithAVanishedArmedItemRunsNothing() {
    let model = sharedModel
    var ran: [String] = []
    model.onRun = { ran.append($0.id) }
    model.results = [item("Empty Trash", confirm: true), item("Other")]
    model.run(model.results[0])
    model.results = [item("Other")]
    model.runSelected()
    #expect(ran.isEmpty)
    #expect(model.armedID == nil)
}

@Test @MainActor func aClickRightAfterArmingDoesNotConfirm() {
    let model = sharedModel
    var ran: [String] = []
    model.onRun = { ran.append($0.id) }
    model.results = [item("Empty Trash", confirm: true)]
    model.run(model.results[0])
    model.confirmByClick()
    #expect(ran.isEmpty)
    #expect(model.armedID == "Empty Trash")
    model.armedID = nil
}

@Test @MainActor func theShortcutHintShowsOnlyOnTheFirstOpens() throws {
    let model = sharedModel
    let defaults = try #require(UserDefaults(suiteName: "beeline-test-bar-opens-\(UUID().uuidString)"))
    let active = Settings.activeShortcut
    defer {
        Settings.activeShortcut = active
        model.showsShortcutHint = true
    }
    Settings.activeShortcut = "command"
    for _ in 1...BarModel.shortcutHintOpens {
        model.countOpen(defaults)
        #expect(model.showsShortcutHint)
    }
    model.countOpen(defaults)
    #expect(!model.showsShortcutHint)

    Settings.activeShortcut = nil
    model.countOpen(defaults)
    #expect(model.showsShortcutHint)
}
