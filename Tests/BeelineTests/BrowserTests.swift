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

@Test func safariResolutionRefusesDuplicateExactAndFallbackMatches() throws {
    // Run the production AppleScript resolver against fake tab lists, without opening Safari.
    let cases = [("{1, 2}", "{1, 2}", "ambiguous"), ("{}", "{1, 2}", "ambiguous"),
                 ("{2}", "{1, 2}", "ok, 2"), ("{}", "{3}", "ok, 3"), ("{}", "{}", "missing")]
    for (exact, addresses, expected) in cases {
        let script = Browser.safariMatchHandler + "\nreturn safariResolver's uniqueSafariMatch(\(exact), \(addresses))"
        let result = try #require(Browser.osascript(script))
        #expect(result.trimmingCharacters(in: .whitespacesAndNewlines) == expected)
    }
}

@Test(.timeLimit(.minutes(1))) func ambiguousSafariCloseAndSwitchAskForASpecificTab() async {
    // Both row actions must execute the guarded script and surface the refusal.
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        let lock = NSLock()
        var reports = 0
        let safari = Browser(name: "Safari", bundleID: "com.apple.Safari", isSafari: true, execute: { script in
            #expect(script.contains(Browser.safariMatchHandler))
            let guardPosition = script.range(of: "if item 1 of choice is not")!.lowerBound
            let actionPosition = script.range(of: script.contains("close (item 2") ? "close (item 2" : "set current tab to")!.lowerBound
            #expect(guardPosition < actionPosition)
            #expect(!script.contains("first tab"))
            return "ambiguous\n"
        }, report: { message in
            #expect(message.contains("Several Safari tabs"))
            lock.lock()
            reports += 1
            let finished = reports == 2
            lock.unlock()
            if finished { continuation.resume() }
        })
        let rows = safari.items(from: "7\t0\tWeather\thttps://weather.com/\n7\t0\tWeather\thttps://weather.com/\n", icon: nil)
        rows[1].run()
        rows[0].close?()
    }
}
