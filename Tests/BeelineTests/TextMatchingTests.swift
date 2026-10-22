import Foundation
import Testing
@testable import Beeline

// "İ" lower-cases to a longer string, so positions in a lowered copy don't line up with the original.
@Test func savingADesktopNamedWithDottedCapitalIDoesNotCrash() throws {
    TestEnvironment.prepare()
    let rows = try #require(Desktops.results(for: "save desktop as İstanbul"))
    #expect(rows.first?.title == "Save this desktop as “İstanbul”")
    _ = Desktops.results(for: "Delete desktop İ")
    #expect(Desktops.results(for: "save desktop as STRAẞE")?.first?.title == "Save this desktop as “STRAẞE”")
}

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

    @Test func convertAndResizeReadTheWordsInOrder() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        FileTools.useSelection([try scratch.file("a.heic"), try scratch.file("b.heic")], folder: nil)
        defer { FileTools.clearSelection() }
        #expect(FileTools.results(for: "convert heic to jpg")?.first?.title == "Convert 2 images to JPG")
        #expect(FileTools.results(for: "convert to png")?.first?.title == "Convert 2 images to PNG")
        #expect(FileTools.results(for: "resize 2 images to 800px")?.first?.title == "Resize 2 images to 800 pixels")
        #expect(FileTools.results(for: "resize to 640")?.first?.title == "Resize 2 images to 640 pixels")
    }

    @Test func hiddenFoldersAndBundlesAreNotDestinations() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let file = try scratch.file("note.txt")
        try FileManager.default.createDirectory(at: scratch.url.appendingPathComponent(".secret"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: scratch.url.appendingPathComponent("Plain"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: scratch.url.appendingPathComponent("Doc.rtfd"), withIntermediateDirectories: true)
        FileTools.useSelection([file], folder: scratch.url)
        defer { FileTools.clearSelection() }
        #expect(FileTools.results(for: "move this to secret") == nil)
        #expect(FileTools.results(for: "move this to \(scratch.url.path)/.secret") == nil)
        #expect(FileTools.results(for: "move this to doc") == nil)
        #expect(FileTools.results(for: "move this to plain")?.first?.title == "Move “note.txt” to Plain")
    }

    @Test func leadingSpacesDoNotCutLettersOffNames() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        FileTools.useSelection([try scratch.file("a.jpg")], folder: nil)
        defer { FileTools.clearSelection() }
        #expect(FileTools.results(for: "  rename to Trip")?.first?.title == "Rename to “Trip.jpg”")
        #expect(Reminders.results(for: "  remind me to call mom")?.first?.title == "call mom")
    }
}

@Test func aPastTimeWithNoDayMeansTomorrow() throws {
    let calendar = Calendar.current
    let now = calendar.date(bySettingHour: 15, minute: 0, second: 0, of: Date())!
    let (title, due) = Reminders.splitDate("call Sam at 9am", now: now)
    #expect(title == "call Sam")
    let date = try #require(due)
    #expect(date > now)
    #expect(calendar.component(.hour, from: date) == 9)
    #expect(calendar.isDate(date, inSameDayAs: calendar.date(byAdding: .day, value: 1, to: now)!))
    let (_, later) = Reminders.splitDate("call Sam at 5pm", now: now)
    #expect(calendar.isDate(try #require(later), inSameDayAs: now))
}

@Test func rewritingIsOfferedOnlyForRequestsAboutTheText() {
    for query in ["make this more formal", "fix the typos", "shorter please", "Translate to French", "make it friendlier", "proofread"] {
        #expect(Rewrite.isRequest(query), "\(query)")
    }
    for query in ["open safari", "make a new folder", "fix wifi", "", "dark mode", "show ruler"] {
        #expect(!Rewrite.isRequest(query), "\(query)")
    }
}
