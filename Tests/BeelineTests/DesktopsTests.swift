import Foundation
import Testing
@testable import Beeline

/// Saved desktops live in one file under the test support folder, so these run one at a time
/// and start each case from a known file. Other suites may read the cache meanwhile; it is lock-protected.
@Suite(.serialized) struct DesktopsTests {
    private func stored(_ desktops: [Desktops.Desktop]) throws {
        try FileManager.default.createDirectory(at: Desktops.file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(desktops).write(to: Desktops.file, options: .atomic)
        Desktops.reload()
    }

    private func onDisk() -> [String] {
        Desktops.reload()
        return Desktops.load().map(\.name)
    }

    private let editor = Desktops.App(name: "TextEdit", path: "/System/Applications/TextEdit.app", bundleID: "com.apple.TextEdit",
                                      windows: [.init(title: "notes", frame: CGRect(x: 0, y: 0, width: 600, height: 400), document: nil)])

    @Test func savingUnderAnExistingNameOffersToReplaceItWhateverTheCaseOrSpacing() throws {
        try stored([Desktops.Desktop(name: "Deep Work", saved: Date(), apps: [editor])])
        #expect(Desktops.results(for: "save desktop as deep   WORK")?.first?.title == "Replace saved desktop “Deep Work”")
        #expect(Desktops.results(for: "remember my desktop as Morning")?.first?.title == "Save this desktop as “Morning”")
    }

    @Test func deletingMatchesWordPrefixesAsksFirstAndRemovesOnlyThatOne() throws {
        try stored([Desktops.Desktop(name: "Deep Work", saved: Date(), apps: [editor]),
                    Desktops.Desktop(name: "Design Review", saved: Date(), apps: [])])
        let rows = try #require(Desktops.results(for: "delete desktop de wo"))
        #expect(rows.map(\.title) == ["Deep Work"])
        #expect(rows.allSatisfy { $0.needsConfirm }, "deleting a saved desktop can't be undone, so it must ask first")
        rows[0].run()
        #expect(onDisk() == ["Design Review"])
        #expect(Desktops.results(for: "delete desktop nothing like it") == nil)
    }

    @Test func theListShowsNewestFirstWithAppCounts() throws {
        try stored([Desktops.Desktop(name: "Old", saved: Date(timeIntervalSinceNow: -86_400), apps: [editor]),
                    Desktops.Desktop(name: "New", saved: Date(), apps: [editor, editor])])
        let rows = try #require(Desktops.results(for: "Saved Desktops"))
        #expect(rows.map(\.title) == ["New", "Old"])
        #expect(rows[0].subtitle.hasPrefix("2 apps"))
        #expect(rows[1].subtitle.hasPrefix("1 app ·"))
    }

    /// Desktops saved before tabs and hidden apps were recorded must still open.
    @Test func aFileFromBeforeTabsAndHiddenAppsStillLoads() throws {
        let old = #"[{"name":"Before","saved":700000000,"apps":[{"name":"TextEdit","path":"/System/Applications/TextEdit.app","windows":[]}]}]"#
        try FileManager.default.createDirectory(at: Desktops.file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(old.utf8).write(to: Desktops.file)
        #expect(onDisk() == ["Before"])
        #expect(Desktops.items().map(\.title) == ["Before"])
    }

    @Test func aDamagedFileReadsAsNoDesktopsInsteadOfFailing() throws {
        try FileManager.default.createDirectory(at: Desktops.file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: Desktops.file)
        #expect(onDisk().isEmpty)
        #expect(Desktops.results(for: "desktops")?.isEmpty == true)
        let kept = try FileManager.default.contentsOfDirectory(atPath: Desktops.file.deletingLastPathComponent().path)
        #expect(kept.contains { $0.hasPrefix("desktops.json.unreadable-") }, "the damaged file should be set aside, not deleted")
    }

    /// Moved from TextMatchingTests so it runs with the other desktops tests, one at a time.
    @Test func savingADesktopNamedWithDottedCapitalIDoesNotCrash() throws {
        TestEnvironment.prepare()
        try stored([])
        let rows = try #require(Desktops.results(for: "save desktop as İstanbul"))
        #expect(rows.first?.title == "Save this desktop as “İstanbul”")
        _ = Desktops.results(for: "Delete desktop İ")
        #expect(Desktops.results(for: "save desktop as STRAẞE")?.first?.title == "Save this desktop as “STRAẞE”")
    }
}
