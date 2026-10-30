import ApplicationServices
import Foundation
import Testing
@testable import Beeline

// Both scans hop through the main queue, which other main-actor tests share, so this waits for them in turn
// rather than on a fixed clock.
@Test(.timeLimit(.minutes(1))) func requestsDuringAScanWaitForTheNextOne() async {
    TestEnvironment.prepare()
    let catalogue = Catalogue()
    let answeredBy: (first: Int, second: Int) = await withCheckedContinuation { done in
        DispatchQueue.main.async {
            var first = 0
            catalogue.refreshScreen { first = catalogue.scansCompleted }
            catalogue.refreshScreen { done.resume(returning: (first, catalogue.scansCompleted)) }
        }
    }
    #expect(answeredBy.first == 1)
    #expect(answeredBy.second == 2)
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
