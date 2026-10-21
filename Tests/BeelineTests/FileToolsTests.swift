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
    FileTools.trash = { url in try FileManager.default.moveItem(at: url, to: bin.appendingPathComponent(url.lastPathComponent)) }
    return bin
}

    @Test func moveNeverTrashesTheFolderHoldingTheSource() throws {
    let scratch = try Scratch()
    defer { scratch.remove() }
    let bin = try useScratchTrash(scratch)
    // ~/Downloads/Foo/Foo moved "to downloads": the target is the folder the source sits in.
    let source = try scratch.file("Foo", "inside", in: "Downloads/Foo")
    let downloads = scratch.url.appendingPathComponent("Downloads")

    let moved = FileTools.transfer([source], to: downloads, copying: false, replacing: ["Foo"])
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

    let moved = FileTools.transfer([first, second], to: desktop, copying: false, replacing: [])
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
    let copied = FileTools.transfer([source], to: spelled, copying: true, replacing: ["Notes.txt"])
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
    #expect(FileTools.transfer([source], to: desktop, copying: true, replacing: []).isEmpty)
    #expect(try String(contentsOf: old, encoding: .utf8) == "old")

    let copied = FileTools.transfer([source], to: desktop, copying: true, replacing: ["report.pdf"])
    #expect(copied == [old])
    #expect(try String(contentsOf: old, encoding: .utf8) == "new")
    #expect(try FileManager.default.contentsOfDirectory(atPath: bin.path) == ["report.pdf"])
    #expect(scratch.exists("Downloads/report.pdf"), "a copy leaves the source")
}

    @Test func replaceThatCannotTrashLeavesEverythingInPlace() throws {
    let scratch = try Scratch()
    defer { scratch.remove() }
    FileTools.trash = { _ in throw CocoaError(.fileWriteNoPermission) }
    let source = try scratch.file("app.txt", "new", in: "Downloads")
    let old = try scratch.file("app.txt", "old", in: "Applications")

    let moved = FileTools.transfer([source], to: old.deletingLastPathComponent(), copying: false, replacing: ["app.txt"])
    #expect(moved.isEmpty)
    #expect(try String(contentsOf: old, encoding: .utf8) == "old")
    #expect(try String(contentsOf: source, encoding: .utf8) == "new", "a move that fails puts the source back")
    #expect(try FileManager.default.contentsOfDirectory(atPath: scratch.url.appendingPathComponent("Applications").path) == ["app.txt"])
}
}
