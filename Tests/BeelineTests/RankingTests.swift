import Foundation
import Testing
@testable import Beeline

/// One catalogue for all ranking tests: scanning installed apps takes a moment.
let sharedCatalogue: Catalogue = {
    TestEnvironment.prepare()
    return Catalogue()
}()

private func titles(_ query: String) -> [String] {
    sharedCatalogue.search(query).map(\.title)
}

// H3: drastic actions need Return twice, and never surface for a keyword typed in part.
@Test func restartShutDownAndLogOutNeedConfirming() {
    for title in ["Restart", "Shut Down", "Log Out"] {
        let item = sharedCatalogue.search(title.lowercased()).first { $0.title == title }
        #expect(item?.needsConfirm == true, Comment(rawValue: title))
    }
}

@Test func partOfAKeywordDoesNotSurfaceLogOut() {
    #expect(!titles("logo").contains("Log Out"))
    #expect(!titles("sign").contains("Log Out"))
    #expect(!titles("reb").contains("Restart"))
    #expect(titles("logout").first == "Log Out")
    #expect(titles("log out").first == "Log Out")
}

@Test func drasticActionsAreNeverPartialMatches() {
    #expect(!titles("restart chrome").contains("Restart"))
    #expect(!titles("log out of slack").contains("Log Out"))
    #expect(!titles("sign out of chrome").contains("Log Out"))
}

@Test func genericWordsDoNotPutTheMacToSleep() {
    #expect(!titles("comp").contains("Sleep"))
    #expect(!titles("computer").contains("Sleep"))
    #expect(titles("sleep").first == "Sleep")
}

@Test func oneLetterPrefersAnAppOverAnAction() {
    // Safari ships with macOS, so "s" has an app to prefer over Sleep.
    #expect(titles("s").first != "Sleep")
    #expect(titles("t").first != "Turn Wi-Fi Off")
}

@Test func plansNeverIncludeActionsThatNeedConfirming() {
    let texts = sharedCatalogue.planOptions().map(\.text)
    for title in ["Restart", "Shut Down", "Log Out", "Empty Trash"] {
        #expect(!texts.contains(title))
    }
}
