import Foundation
import Testing
@testable import Beeline

@Test func anUnlockedSessionWithNoLockKeyIsNotLocked() {
    #expect(Actions.screenLocked(in: ["kCGSSessionOnConsoleKey": true]) == false)
    #expect(Actions.screenLocked(in: ["CGSSessionScreenIsLocked": true]) == true)
    #expect(Actions.screenLocked(in: ["CGSSessionScreenIsLocked": 1]) == true)
    #expect(Actions.screenLocked(in: ["CGSSessionScreenIsLocked": 0]) == false)
    #expect(Actions.screenLocked(in: nil) == nil)
}

@Test @MainActor func runningOnMainFromMainDoesNotDeadlock() {
    #expect(AppDelegate.onMain { 7 } == 7)
}

@Test func runningOnMainFromABackgroundThreadUsesTheMainThread() async {
    let onMain = await Task.detached { AppDelegate.onMain { Thread.isMainThread } }.value
    #expect(onMain)
}
