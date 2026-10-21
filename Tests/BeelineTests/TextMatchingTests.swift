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

    // M5: with Finder in front, "go to downloads" must not become a copy of a file that has "go" in its name.
    @Test func navigationPhrasesAreNotCopies() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let logo = try scratch.file("logo.png")
        FileTools.useSelection([], folder: scratch.url)
        defer { FileTools.clearSelection() }
        #expect(FileTools.results(for: "go to downloads") == nil)
        #expect(FileTools.results(for: "lo to downloads") == nil)
        #expect(FileTools.results(for: "logo to downloads")?.first?.title == "Copy “logo.png” to Downloads")
        #expect(FileTools.results(for: "copy lo to downloads")?.first?.title == "Copy “logo.png” to Downloads")
        _ = logo
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

// M6: a time with no day that has already passed today means tomorrow.
@Test func aPastTimeWithNoDayMeansTomorrow() throws {
    let calendar = Calendar.current
    let now = calendar.date(bySettingHour: 15, minute: 0, second: 0, of: Date())!
    let (title, due) = Reminders.splitDate("call Sam at 9am", now: now)
    #expect(title == "call Sam")
    let date = try #require(due)
    #expect(date > now)
    #expect(calendar.component(.hour, from: date) == 9)
    #expect(calendar.isDate(date, inSameDayAs: calendar.date(byAdding: .day, value: 1, to: now)!))
    // A time still to come today stays today.
    let (_, later) = Reminders.splitDate("call Sam at 5pm", now: now)
    #expect(calendar.isDate(try #require(later), inSameDayAs: now))
}
