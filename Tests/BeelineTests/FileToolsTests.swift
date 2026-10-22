import Foundation
import Testing
@testable import Beeline

/// A throwaway folder for one test, removed afterwards.
struct Scratch {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("beeline-tests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    @discardableResult
    func file(_ name: String, _ contents: String = "x", in folder: String? = nil) throws -> URL {
        var parent = url
        if let folder {
            parent = url.appendingPathComponent(folder, isDirectory: true)
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        }
        let file = parent.appendingPathComponent(name)
        try contents.write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: url.appendingPathComponent(path).path)
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}

/// The entry names inside a zip archive.
private func entries(of archive: URL) -> [String] {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
    process.arguments = ["-Z1", archive.path]
    let pipe = Pipe()
    process.standardOutput = pipe
    try? process.run()
    let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    process.waitUntilExit()
    return output.split(separator: "\n").map(String.init)
}

// H1: file names must never be read as zip options.
@Test func compressTreatsDashNamesAsFiles() throws {
    let scratch = try Scratch()
    defer { scratch.remove() }
    let report = try scratch.file("report.txt", "keep me")
    let dash = try scratch.file("-m")
    let command = try scratch.file("-TT")

    let archive = try #require(FileTools.archive([report, dash, command]))
    #expect(archive.lastPathComponent == "Archive.zip")
    #expect(scratch.exists("report.txt"), "zip -m would have deleted the original")
    #expect(scratch.exists("-m"))
    #expect(Set(entries(of: archive)) == ["report.txt", "-m", "-TT"])
}

// H1: a selection spanning folders includes every file, not only the ones beside the first.
@Test func compressIncludesFilesFromSeveralFolders() throws {
    let scratch = try Scratch()
    defer { scratch.remove() }
    let a = try scratch.file("a.txt", in: "one")
    let b = try scratch.file("b.txt", in: "two")

    let archive = try #require(FileTools.archive([a, b]))
    #expect(archive.deletingLastPathComponent().lastPathComponent == "one")
    #expect(Set(entries(of: archive)) == ["a.txt", "b.txt"])
}

// H1 / M19: a name that cannot be read fails the whole chore and leaves no half-written archive.
@Test func compressLeavesNothingBehindOnFailure() throws {
    let scratch = try Scratch()
    defer { scratch.remove() }
    let a = try scratch.file("a.txt")
    let missing = scratch.url.appendingPathComponent("missing.txt")

    #expect(FileTools.archive([a, missing]) == nil)
    #expect(!scratch.exists("Archive.zip"))
}

// Codex 5: a link inside a selected folder is stored as a link, never as what it points to.
@Test func compressKeepsLinksAsLinks() throws {
    let scratch = try Scratch()
    defer { scratch.remove() }
    let secret = try scratch.file("secret.txt", "private", in: "elsewhere")
    let note = try scratch.file("note.txt", "hello", in: "project")
    let other = try scratch.file("other.txt")
    try FileManager.default.createSymbolicLink(at: note.deletingLastPathComponent().appendingPathComponent("link"),
                                               withDestinationURL: secret.deletingLastPathComponent())
    let archive = try #require(FileTools.archive([note.deletingLastPathComponent(), other]))
    let listed = entries(of: archive)
    #expect(listed.contains("project/link"))
    #expect(!listed.contains { $0.contains("secret.txt") })
}

// Codex 6: same-named items from two folders are refused, not merged into one entry.
@Test func compressRefusesTwoItemsWithOneName() throws {
    let scratch = try Scratch()
    defer { scratch.remove() }
    let a = try scratch.file("report.txt", "first", in: "one")
    let b = try scratch.file("Report.txt", "second", in: "two")
    #expect(FileTools.sharedName([a, b]) == "Report.txt")
    #expect(FileTools.archive([a, b]) == nil)
    #expect(!scratch.exists("one/Archive.zip"))
}

// M19: a second archive beside the first gets its own name, never the first one's.
@Test func compressNeverReplacesAnExistingArchive() throws {
    let scratch = try Scratch()
    defer { scratch.remove() }
    let a = try scratch.file("a.txt")
    let b = try scratch.file("b.txt")
    let first = try #require(FileTools.archive([a, b]))
    let second = try #require(FileTools.archive([a, b]))
    #expect(first.lastPathComponent == "Archive.zip")
    #expect(second.lastPathComponent == "Archive 2.zip")
}

// MARK: Copy, move and install (H2)

/// These share the `FileTools.trash` hook, so they run one at a time.
@Suite(.serialized) struct TransferTests {

/// Routes "trash" into a folder inside the scratch so tests never touch the real Trash.
    private func useScratchTrash(_ scratch: Scratch) throws -> URL {
    let bin = scratch.url.appendingPathComponent("trash-bin", isDirectory: true)
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    FileTools.trash = { url in
        let landed = bin.appendingPathComponent(url.lastPathComponent + "-" + UUID().uuidString.prefix(4))
        try FileManager.default.moveItem(at: url, to: landed)
        return landed
    }
    return bin
}

    @Test func moveNeverTrashesTheFolderHoldingTheSource() throws {
    let scratch = try Scratch()
    defer { scratch.remove() }
    let bin = try useScratchTrash(scratch)
    // ~/Downloads/Foo/Foo moved "to downloads": the target is the folder the source sits in.
    let source = try scratch.file("Foo", "inside", in: "Downloads/Foo")
    let downloads = scratch.url.appendingPathComponent("Downloads")

    let moved = FileTools.transfer([source], to: downloads, copying: false, replacing: FileTools.replacements(["Foo"], in: downloads))
    #expect(moved.isEmpty)
    #expect(scratch.exists("Downloads/Foo/Foo"))
    #expect(try FileManager.default.contentsOfDirectory(atPath: bin.path).isEmpty)
}

    @Test func moveSkipsTwoItemsWithTheSameName() throws {
    let scratch = try Scratch()
    defer { scratch.remove() }
    let bin = try useScratchTrash(scratch)
    let first = try scratch.file("notes.txt", "first", in: "a")
    let second = try scratch.file("notes.txt", "second", in: "b")
    let desktop = scratch.url.appendingPathComponent("Desktop")
    try FileManager.default.createDirectory(at: desktop, withIntermediateDirectories: true)

    let moved = FileTools.transfer([first, second], to: desktop, copying: false, replacing: [:])
    #expect(moved.isEmpty)
    #expect(scratch.exists("a/notes.txt") && scratch.exists("b/notes.txt"))
    #expect(try FileManager.default.contentsOfDirectory(atPath: bin.path).isEmpty)
}

    @Test func copyOntoItselfByAnotherSpellingDoesNothing() throws {
    let scratch = try Scratch()
    defer { scratch.remove() }
    let bin = try useScratchTrash(scratch)
    let source = try scratch.file("Notes.txt", "keep", in: "Desktop")
    // Only meaningful on a case-insensitive volume, which the default macOS disk is.
    let spelled = scratch.url.appendingPathComponent("desktop")
    guard FileManager.default.fileExists(atPath: spelled.appendingPathComponent("Notes.txt").path) else { return }

    #expect(FileTools.overlaps(source, spelled.appendingPathComponent("notes.txt")))
    let copied = FileTools.transfer([source], to: spelled, copying: true, replacing: FileTools.replacements(["Notes.txt"], in: spelled))
    #expect(copied.isEmpty)
    #expect(try String(contentsOf: source, encoding: .utf8) == "keep")
    #expect(try FileManager.default.contentsOfDirectory(atPath: bin.path).isEmpty)
}

    @Test func replaceTrashesOnlyWhatWasOnTheCard() throws {
    let scratch = try Scratch()
    defer { scratch.remove() }
    let bin = try useScratchTrash(scratch)
    let source = try scratch.file("report.pdf", "new", in: "Downloads")
    let old = try scratch.file("report.pdf", "old", in: "Desktop")
    let desktop = old.deletingLastPathComponent()

    // Nothing was confirmed, so the old file stays and nothing is copied over it.
    #expect(FileTools.transfer([source], to: desktop, copying: true, replacing: [:]).isEmpty)
    #expect(try String(contentsOf: old, encoding: .utf8) == "old")

    let copied = FileTools.transfer([source], to: desktop, copying: true, replacing: FileTools.replacements(["report.pdf"], in: desktop))
    #expect(copied == [old])
    #expect(try String(contentsOf: old, encoding: .utf8) == "new")
    #expect(try FileManager.default.contentsOfDirectory(atPath: bin.path).map { $0.hasPrefix("report.pdf") } == [true])
    #expect(scratch.exists("Downloads/report.pdf"), "a copy leaves the source")
}

    @Test func replaceThatCannotTrashLeavesEverythingInPlace() throws {
    let scratch = try Scratch()
    defer { scratch.remove() }
    FileTools.trash = { _ in throw CocoaError(.fileWriteNoPermission) }
    let source = try scratch.file("app.txt", "new", in: "Downloads")
    let old = try scratch.file("app.txt", "old", in: "Applications")

    let moved = FileTools.transfer([source], to: old.deletingLastPathComponent(), copying: false, replacing: FileTools.replacements(["app.txt"], in: old.deletingLastPathComponent()))
    #expect(moved.isEmpty)
    #expect(try String(contentsOf: old, encoding: .utf8) == "old")
    #expect(try String(contentsOf: source, encoding: .utf8) == "new", "a move that fails puts the source back")
    #expect(try FileManager.default.contentsOfDirectory(atPath: scratch.url.appendingPathComponent("Applications").path) == ["app.txt"])
}

    // Codex 8: if the item on the card is swapped for another before Return, the other one is not trashed.
    @Test func replaceLeavesAnItemThatChangedSinceTheCard() throws {
    let scratch = try Scratch()
    defer { scratch.remove() }
    let bin = try useScratchTrash(scratch)
    let source = try scratch.file("report.pdf", "new", in: "Downloads")
    let old = try scratch.file("report.pdf", "old", in: "Desktop")
    let desktop = old.deletingLastPathComponent()
    let shown = FileTools.replacements(["report.pdf"], in: desktop)
    #expect(shown.count == 1)

    // Something else saves a different report.pdf there after the card was shown.
    try FileManager.default.removeItem(at: old)
    _ = try scratch.file("report.pdf", "someone else's", in: "Desktop")

    #expect(FileTools.transfer([source], to: desktop, copying: true, replacing: shown).isEmpty)
    #expect(try String(contentsOf: old, encoding: .utf8) == "someone else's")
    #expect(try FileManager.default.contentsOfDirectory(atPath: bin.path).isEmpty)
}

    // Codex 9: two names that differ only in case count as one name at the destination.
    @Test func namesThatDifferOnlyInCaseAreOneName() throws {
    let scratch = try Scratch()
    defer { scratch.remove() }
    let bin = try useScratchTrash(scratch)
    let upper = try scratch.file("Notes.txt", "first", in: "a")
    let lower = try scratch.file("notes.txt", "second", in: "b")
    let desktop = scratch.url.appendingPathComponent("Desktop")
    try FileManager.default.createDirectory(at: desktop, withIntermediateDirectories: true)

    #expect(FileTools.transfer([upper, lower], to: desktop, copying: false, replacing: [:]).isEmpty)
    #expect(scratch.exists("a/Notes.txt") && scratch.exists("b/notes.txt"))
    #expect(try FileManager.default.contentsOfDirectory(atPath: desktop.path).isEmpty)
    #expect(try FileManager.default.contentsOfDirectory(atPath: bin.path).isEmpty)
}
    // "undo" after a replacing copy: the copy goes to the Trash and the old file comes back.
    @Test func undoPutsTheReplacedFileBack() throws {
    let scratch = try Scratch()
    defer { scratch.remove() }
    let bin = try useScratchTrash(scratch)
    let source = try scratch.file("report.pdf", "new", in: "Downloads")
    let old = try scratch.file("report.pdf", "old", in: "Desktop")
    let desktop = old.deletingLastPathComponent()
    _ = FileTools.transfer([source], to: desktop, copying: true, replacing: FileTools.replacements(["report.pdf"], in: desktop))
    #expect(try String(contentsOf: old, encoding: .utf8) == "new")
    #expect(UndoLog.shared.latest()?.title == "Copy “report.pdf” to Desktop")
    UndoLog.shared.undoLatest()
    #expect(try String(contentsOf: old, encoding: .utf8) == "old")
    #expect(try String(contentsOf: source, encoding: .utf8) == "new", "the source was never touched")
    #expect(try FileManager.default.contentsOfDirectory(atPath: bin.path).count == 1, "the copy went to the Trash")
}

    // "undo" after a move puts the item back where it came from.
    @Test func undoMovesAnItemBack() throws {
    let scratch = try Scratch()
    defer { scratch.remove() }
    _ = try useScratchTrash(scratch)
    let source = try scratch.file("notes.txt", "mine", in: "Downloads")
    let desktop = scratch.url.appendingPathComponent("Desktop")
    try FileManager.default.createDirectory(at: desktop, withIntermediateDirectories: true)
    _ = FileTools.transfer([source], to: desktop, copying: false, replacing: [:])
    #expect(!scratch.exists("Downloads/notes.txt"))
    UndoLog.shared.undoLatest()
    #expect(scratch.exists("Downloads/notes.txt"))
    #expect(!scratch.exists("Desktop/notes.txt"))
}
}

// Codex 10: Finder's answer is one file URL per line, so a line break inside a name can't split it.
@Test func finderSelectionIsReadAsURLs() throws {
    let scratch = try Scratch()
    defer { scratch.remove() }
    let odd = try scratch.file("line\nbreak.txt", "x")
    let plain = try scratch.file("plain.txt", "x")
    // A real path that the broken-up pieces would have matched before.
    _ = try scratch.file("line", "decoy")
    let output = scratch.url.absoluteString + "\n" + odd.absoluteString + "\n" + plain.absoluteString + "\n"
    #expect(odd.absoluteString.contains("%0A"))

    let (folder, items) = FileTools.parseSelection(output)
    #expect(folder?.standardizedFileURL == scratch.url.standardizedFileURL)
    #expect(items.map(\.lastPathComponent) == ["line\nbreak.txt", "plain.txt"])
}

@Test func finderSelectionSkipsWhatIsNotThere() {
    let (folder, items) = FileTools.parseSelection("-\n/Users/someone/plain path.txt\nfile:///no/such/file\n")
    #expect(folder == nil)
    #expect(items.isEmpty)
}
