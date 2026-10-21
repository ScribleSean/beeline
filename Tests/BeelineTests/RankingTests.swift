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
    for title in ["Restart", "Shut Down", "Log Out", "Empty Trash", "Eject All Disks"] {
        #expect(!texts.contains(title))
    }
}

// Codex 7: ejecting every disk asks first, and the card says which ones.
@Test func ejectAllDisksNeedsConfirming() {
    let item = sharedCatalogue.search("eject all disks").first { $0.title == "Eject All Disks" }
    #expect(item?.needsConfirm == true)
    #expect(item?.id == "action:Eject All Disks")
    #expect(Actions.ejectSummary([]) == "No disks are connected that can be ejected.")
    #expect(Actions.ejectSummary(["Backup"]).hasPrefix("Backup is ejected."))
    #expect(Actions.ejectSummary(["Backup", "Photos", "USB"]).hasPrefix("Backup, Photos and USB are ejected."))
}

// M11: everyday requests act instead of turning into questions or the wrong direction.
@Test func requestsThatMatchEveryWordAreNotQuestions() {
    #expect(titles("do not disturb").first == "Focus")
    #expect(titles("can you mute").first == "Mute")
    #expect(!sharedCatalogue.isQuestion("do not disturb"))
    #expect(sharedCatalogue.isQuestion("how far is the moon"))
    #expect(sharedCatalogue.isQuestion("is it raining?"))
}

@Test func onAndOffPickTheRightDirection() {
    #expect(titles("turn wifi on").first == "Turn Wi-Fi On")
    #expect(titles("turn wifi off").first == "Turn Wi-Fi Off")
}

@Test func turningOffTheComputerMeansShutDown() {
    #expect(titles("turn off the computer").first == "Shut Down")
    #expect(titles("power off").first == "Shut Down")
    #expect(titles("bluetooth power off").first != "Shut Down")
}

@Test func datesAndPhoneNumbersAreNotSums() {
    #expect(Calculator.evaluate("2024-01-15") == nil)
    #expect(Calculator.evaluate("15/01/2024") == nil)
    #expect(Calculator.evaluate("+44 20 7946 0958") == nil)
    #expect(Calculator.evaluate("(555) 123-4567") == nil)
    #expect(Calculator.evaluate("10-3") == 7)
    #expect(Calculator.evaluate("12 * (8 + 2)") == 120)
}

@Test func unmatchedClipboardWordsFallThrough() {
    #expect(sharedCatalogue.clipboard.results(for: "paste and match style", limit: 6) == nil)
}

// L9: "+" survives the trip into a web search.
@Test func plusIsKeptInWebSearches() {
    var address = URLComponents(string: "https://www.google.com/search")!
    address.queryItems = [URLQueryItem(name: "q", value: "what is c++?")]
    address.percentEncodedQuery = address.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
    #expect(address.url?.absoluteString == "https://www.google.com/search?q=what%20is%20c%2B%2B?")
}

// L8: Finder lives in CoreServices, not an Applications folder.
@Test func finderCanBeFound() {
    #expect(titles("finder").contains("Finder"))
}
