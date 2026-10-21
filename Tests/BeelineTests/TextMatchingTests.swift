import Foundation
import Testing
@testable import Beeline

// H7: "İ" lower-cases to a longer string; cutting the original by positions from the lowered copy crashed.
@Test func savingADesktopNamedWithDottedCapitalIDoesNotCrash() throws {
    TestEnvironment.prepare()
    let rows = try #require(Desktops.results(for: "save desktop as İstanbul"))
    #expect(rows.first?.title == "Save this desktop as “İstanbul”")
    #expect(Desktops.results(for: "Delete desktop İ") != nil)
    // Shrinking characters must not cut the name short either.
    #expect(Desktops.results(for: "save desktop as STRAẞE")?.first?.title == "Save this desktop as “STRAẞE”")
}

/// These share Finder's selection, so they run one at a time.
@Suite(.serialized) struct SelectionTests {
    @Test func finderRequestsWithDottedCapitalIDoNotCrash() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let image = try scratch.file("İmage.png")
        FileTools.useSelection([image], folder: nil)
        defer { FileTools.clearSelection() }
        let rows = try #require(FileTools.results(for: "Move İmage to desktop"))
        #expect(rows.first?.title == "Move “İmage.png” to Desktop", "a capital verb must still mean move")
        #expect(FileTools.results(for: "copy İ to desktop")?.first?.title == "Copy “İmage.png” to Desktop")
    }

    // L3: positions from a trimmed copy were applied to the untrimmed text.
    @Test func leadingSpacesDoNotCutLettersOffNames() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        FileTools.useSelection([try scratch.file("a.jpg")], folder: nil)
        defer { FileTools.clearSelection() }
        #expect(FileTools.results(for: "  rename to Trip")?.first?.title == "Rename to “Trip.jpg”")
        #expect(Reminders.results(for: "  remind me to call mom")?.first?.title == "call mom")
    }
}
