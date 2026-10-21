import Foundation
import Testing
@testable import Beeline

private func item(_ id: String, confirm: Bool = false) -> Item {
    var item = Item(id: id, kind: .action, verb: "", title: id, subtitle: "Action", keywords: "", icon: nil, run: {})
    item.needsConfirm = confirm
    return item
}

/// One model for these tests; building one scans the installed apps.
@MainActor let sharedModel: BarModel = {
    TestEnvironment.prepare()
    return BarModel()
}()

// M1: the second Return runs the item on the card, not whatever row the selection moved to.
@Test @MainActor func secondReturnRunsTheArmedItem() {
    let model = sharedModel
    var ran: [String] = []
    model.onRun = { ran.append($0.id) }
    model.results = [item("Work", confirm: true), item("Weekend", confirm: true)]
    model.selected = 0
    model.runSelected()
    #expect(model.armedID == "Work")
    #expect(ran.isEmpty)
    // The selection drifts (a hover, a late refresh) before the second Return.
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

// M1: a double-click must not land its second click on the card's red button.
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
