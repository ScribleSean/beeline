import Foundation
import Testing
@testable import Beeline

// H5: a request made while a scan is running is answered by the next scan, not the one under way.
@Test func requestsDuringAScanWaitForTheNextOne() {
    TestEnvironment.prepare()
    let catalogue = Catalogue()
    let done = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var firstAnsweredBy = 0
    nonisolated(unsafe) var secondAnsweredBy = 0
    // The catalogue is driven from the main queue, as the app does.
    DispatchQueue.main.async {
        catalogue.refreshScreen { firstAnsweredBy = catalogue.scansCompleted }
        catalogue.refreshScreen {
            secondAnsweredBy = catalogue.scansCompleted
            done.signal()
        }
    }
    #expect(done.wait(timeout: .now() + 5) == .success)
    #expect(firstAnsweredBy == 1)
    #expect(secondAnsweredBy == 2)
}

// H5: a button whose window is no longer in front is not pressed.
@Test func anItemWhoseTargetChangedIsNotRun() {
    var ran = false
    var item = Item(id: "x", kind: .control, verb: "Press", title: "Send", subtitle: "button", keywords: "", icon: nil) { ran = true }
    item.stillValid = { false }
    #expect(!item.runIfValid())
    #expect(!ran)
    item.stillValid = { true }
    #expect(item.runIfValid())
    #expect(ran)
}
