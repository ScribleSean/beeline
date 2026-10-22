import Foundation
import Testing
@testable import Beeline

/// No browser is touched here: the tab list is the text the browser's AppleScript would return.
@Test func everyTabInTheListBecomesOneRow() {
    let chrome = Browser.all[0], safari = Browser.all[1]
    let listed = "11\t501\tInbox - Gmail\thttps://mail.google.com/mail/u/0/\n11\t502\t\thttps://news.ycombinator.com/\nnot a tab line\n"
    let rows = chrome.items(from: listed, icon: nil)
    #expect(rows.map(\.title) == ["Inbox - Gmail", "news.ycombinator.com"], "a tab with no title shows its site")
    #expect(rows.allSatisfy { $0.kind == .tab && $0.close != nil && $0.subtitle == "Chrome" })

    // Safari reports no tab ids, so two tabs with the same page must still be two rows.
    let same = "7\t0\tWeather\thttps://weather.com/\n7\t0\tWeather\thttps://weather.com/\n"
    #expect(Set(safari.items(from: same, icon: nil).map(\.id)).count == 2)
    #expect(Set(chrome.items(from: listed, icon: nil).map(\.id)).count == 2)
}

@Test func aPageTitleStaysTextInsideAppleScript() throws {
    // Titles and addresses come from web pages, and the Safari close script puts them inside AppleScript.
    for title in [#"Say "hi""#, #"C:\Users\"#, #"x" & (do shell script "touch /tmp/beeline-pwned") & ""#,
                  "two\nlines", "ünïcødé 🐝", #"\""#, ""] {
        let echoed = try #require(Browser.osascript("return " + Browser.quoted(title)), "AppleScript didn't parse \(title)")
        #expect(echoed.dropLast() == title[...])
    }
    #expect(!FileManager.default.fileExists(atPath: "/tmp/beeline-pwned"))
}
