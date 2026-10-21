import Foundation
import Testing
@testable import Beeline

/// Fake tabs in a catalogue of their own, with a record of which ones were closed.
@Suite(.serialized) struct CloseTabTests {
    final class Closed { var titles: [String] = [] }
    let closed = Closed()
    let catalogue: Catalogue

    init() {
        TestEnvironment.prepare()
        catalogue = Catalogue()
        let tabs: [(String, String, String)] = [
            ("Chrome", "Inbox - Gmail", "mail.google.com"),
            ("Chrome", "Rome travel guide", "wikivoyage.org"),
            ("Chrome", "Claude", "claude.ai"),
            ("Chrome", "New chat", "claude.ai"),
            ("Chrome", "Flights to Lisbon", "skyscanner.net"),
            ("Safari", "Weather", "weather.com"),
            ("Safari", "Cheap flights", "kayak.com"),
        ]
        catalogue.useTabs(tabs.enumerated().map { index, tab in
            var item = Item(id: "tab:\(index)", kind: .tab, verb: "Switch to tab", title: tab.1, subtitle: tab.0,
                            keywords: tab.2, icon: nil, run: {})
            item.close = { [closed] in closed.titles.append(tab.1) }
            return item
        })
    }

    private func closeAllRow(_ query: String) -> Item? {
        catalogue.search(query).first { $0.id.hasPrefix("close-tabs:") }
    }

    // H4: the browser's name means every tab in that browser, never a text match, and needs confirming.
    @Test func browserNameClosesOnlyThatBrowsersTabsAfterConfirming() throws {
        let row = try #require(closeAllRow("close chrome tabs"))
        #expect(row.title == "Close 5 Tabs in Chrome")
        #expect(row.needsConfirm)
        row.run()
        #expect(closed.titles.count == 5)
        #expect(!closed.titles.contains("Weather"))
    }

    // H4: a word inside the browser's name is not a match.
    @Test func wordInsideABrowserNameMatchesNothing() {
        #expect(closeAllRow("close tabs about rome")?.title == nil)
        let rows = catalogue.search("close tabs about rome").filter { $0.id.hasPrefix("close:") }
        #expect(rows.map(\.title) == ["Rome travel guide"])
        #expect(catalogue.search("close far tabs").filter { $0.id.hasPrefix("close") }.isEmpty)
    }

    // H4: short words must be whole words, so "ai" is claude.ai and not Gmail.
    @Test func shortWordsMustBeWholeWords() throws {
        let row = try #require(closeAllRow("close ai tabs"))
        #expect(row.title == "Close 2 Tabs Matching “ai”")
        row.run()
        #expect(Set(closed.titles) == ["Claude", "New chat"])
        #expect(catalogue.search("close tabs about e").filter { $0.id.hasPrefix("close") }.isEmpty)
    }

    @Test func wordsMatchAcrossBrowsers() throws {
        let row = try #require(closeAllRow("close every tab about flights"))
        #expect(row.title == "Close 2 Tabs Matching “flights”")
        #expect(row.subtitle == "Chrome, Safari")
    }

    // L28: "close tab" with nothing to match falls through to the normal search instead of showing nothing.
    @Test func closeTabWithNoTargetOffersNoCloseRows() {
        #expect(catalogue.search("close tab").filter { $0.id.hasPrefix("close") }.isEmpty)
        #expect(catalogue.search("close other tabs").filter { $0.id.hasPrefix("close") }.isEmpty)
    }
}

@Test func closeMatchingNeedsWholeWordPrefixes() {
    let tab = Item(id: "t", kind: .tab, verb: "", title: "Inbox - Gmail", subtitle: "Chrome", keywords: "mail.google.com", icon: nil, run: {})
    #expect(Matcher.matchesForClose(tab, ["gmail"]))
    #expect(Matcher.matchesForClose(tab, ["mail", "goo"]))
    #expect(!Matcher.matchesForClose(tab, ["ai"]))
    #expect(!Matcher.matchesForClose(tab, ["chrome"]))
    #expect(!Matcher.matchesForClose(tab, ["box"]))
}
