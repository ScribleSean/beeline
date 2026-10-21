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
