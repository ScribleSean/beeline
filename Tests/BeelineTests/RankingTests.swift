import Foundation
import Testing
@testable import Beeline

let sharedCatalogue: Catalogue = {
    TestEnvironment.prepare()
    return Catalogue()
}()

private func titles(_ query: String) -> [String] {
    sharedCatalogue.search(query).map(\.title)
}

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

@Test func ejectAllDisksNeedsConfirming() {
    let item = sharedCatalogue.search("eject all disks").first { $0.title == "Eject All Disks" }
    #expect(item?.needsConfirm == true)
    #expect(item?.id == "action:Eject All Disks")
    #expect(Actions.ejectSummary([]) == "No disks are connected that can be ejected.")
    #expect(Actions.ejectSummary(["Backup"]).hasPrefix("Backup is ejected."))
    #expect(Actions.ejectSummary(["Backup", "Photos", "USB"]).hasPrefix("Backup, Photos and USB are ejected."))
}

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

@Test func plusIsKeptInWebSearches() {
    #expect(Catalogue.webSearchURL(for: "what is c++?").absoluteString == "https://www.google.com/search?q=what%20is%20c%2B%2B?")
}

// Finder lives in CoreServices, not an Applications folder.
@Test func finderCanBeFound() {
    #expect(titles("finder").contains("Finder"))
}

/// Safari's window is not the current one (voice is used from another app), and browsers' windows are plan-only.
private func catalogueWithSafariWindow(placed: @escaping (Accessibility.Side) -> Void) -> Catalogue {
    TestEnvironment.prepare()
    let app = Item(id: "/Applications/Safari.app", kind: .app, verb: "Open", title: "Safari",
                   subtitle: "App", keywords: "", icon: nil, run: {})
    var window = Item(id: "window:42:0", kind: .window, verb: "Switch to window", title: "Start Page",
                      subtitle: "Safari", keywords: "Safari", icon: nil, run: {})
    window.tile = placed
    return Catalogue(apps: [app], windows: [window], quits: [], controls: [])
}

@Test func namingAnAppAndASideFindsTheDirectWindowMove() {
    var placed: [Accessibility.Side] = []
    let catalogue = catalogueWithSafariWindow { placed.append($0) }
    let spoken = "Move Safari to the left half"
    let top = catalogue.search(spoken).first
    #expect(top?.title == "Move Safari to the Left Half")
    #expect(top?.isGuess == false)
    #expect(!BarModel.claudeLeads(question: false, words: 6, top: top, followUp: false))
    let picked = AutoAct.pick(catalogue.search(spoken), spoken: spoken)
    #expect(picked?.title == "Move Safari to the Left Half")
    picked?.run()
    #expect(placed == [.left])
    #expect(catalogue.search("put safari on the right").first?.title == "Move Safari to the Right Half")
}

@Test func aSideAloneDoesNotOfferEveryAppsWindow() {
    let catalogue = catalogueWithSafariWindow { _ in }
    #expect(!catalogue.search("left half").contains { $0.title.contains("Safari") })
}
