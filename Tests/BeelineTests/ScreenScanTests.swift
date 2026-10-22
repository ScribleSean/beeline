import ApplicationServices
import Foundation
import Testing
@testable import Beeline

@Test func requestsDuringAScanWaitForTheNextOne() {
    TestEnvironment.prepare()
    let catalogue = Catalogue()
    let done = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var firstAnsweredBy = 0
    nonisolated(unsafe) var secondAnsweredBy = 0
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

// Nothing is asked of the other app, so this needs no Accessibility permission.
@Test func aWindowOfAnAppNotInFrontIsNotTheFrontWindow() {
    let launchd: pid_t = 1
    #expect(!Accessibility.isFrontWindow(AXUIElementCreateApplication(launchd), of: launchd))
}

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
