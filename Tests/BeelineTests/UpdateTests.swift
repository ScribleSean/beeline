import Foundation
import Testing
@testable import Beeline

/// Every repo here lives in a temp folder; nothing touches Beeline's own checkout or install.
private struct Repos {
    let scratch: Scratch
    var origin: String { scratch.url.appendingPathComponent("origin").path }
    var clone: String { scratch.url.appendingPathComponent("clone").path }

    init() throws {
        scratch = try Scratch()
        try git("init -q -b main origin", in: scratch.url.path)
        try commit("first", in: origin)
        try git("clone -q origin clone", in: scratch.url.path)
    }

    @discardableResult
    func git(_ arguments: String, in directory: String) throws -> String {
        let result = Update.shell("git -c user.name=Test -c user.email=test@example.com \(arguments)", in: directory)
        guard result.ok else { throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: result.errors]) }
        return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func commit(_ message: String, in directory: String) throws {
        try (message + "\n").write(toFile: directory + "/notes.txt", atomically: true, encoding: .utf8)
        try git("add notes.txt", in: directory)
        try git("commit -q -m \(message)", in: directory)
    }

    func head(of directory: String) throws -> String { try git("rev-parse HEAD", in: directory) }
}

@Test func anInstallBuiltFromTheNewestCommitIsUpToDate() throws {
    let repos = try Repos()
    defer { repos.scratch.remove() }
    let head = try repos.head(of: repos.clone)
    #expect(Update.check(root: repos.clone, built: head) == .upToDate(head: head, reachedGitHub: true))
}

@Test func newCommitsOnTheRemoteAreListedAndOnlyFetched() throws {
    let repos = try Repos()
    defer { repos.scratch.remove() }
    let built = try repos.head(of: repos.clone)
    try repos.commit("second", in: repos.origin)
    try repos.commit("third", in: repos.origin)

    guard case .offer(let incoming, let edits, _) = Update.check(root: repos.clone, built: built) else {
        Issue.record("new commits weren't offered"); return
    }
    #expect(incoming.map { $0.split(separator: " ").last.map(String.init) } == ["third", "second"])
    #expect(!edits)
    #expect(try repos.head(of: repos.clone) == built, "checking must not move the source folder")

    #expect(Update.fastForward(root: repos.clone) == nil)
    #expect(try repos.head(of: repos.clone) == repos.head(of: repos.origin))
}

@Test func onlyMainIsEverUpdated() throws {
    let repos = try Repos()
    defer { repos.scratch.remove() }
    try repos.git("switch -q -c experiment", in: repos.clone)
    guard case .refused(let why) = Update.check(root: repos.clone, built: try repos.head(of: repos.clone)) else {
        Issue.record("a branch other than main was offered an update"); return
    }
    #expect(why.contains("experiment"))
    if case .refused = Update.check(root: repos.scratch.url.path, built: "") {} else { Issue.record("a folder that isn't a checkout was offered an update") }
}

@Test func uncommittedEditsOrAnotherBuildMeanARebuildIsOffered() throws {
    let repos = try Repos()
    defer { repos.scratch.remove() }
    let head = try repos.head(of: repos.clone)
    #expect(Update.check(root: repos.clone, built: "0123abc") == .offer(incoming: [], hasLocalEdits: false, head: head))
    try "edited\n".write(toFile: repos.clone + "/notes.txt", atomically: true, encoding: .utf8)
    #expect(Update.check(root: repos.clone, built: head) == .offer(incoming: [], hasLocalEdits: true, head: head))
}

@Test func aMainThatHasDivergedIsNeverMerged() throws {
    let repos = try Repos()
    defer { repos.scratch.remove() }
    try repos.commit("theirs", in: repos.origin)
    try repos.commit("mine", in: repos.clone)
    let mine = try repos.head(of: repos.clone)
    _ = Update.check(root: repos.clone, built: mine)
    #expect(Update.fastForward(root: repos.clone) != nil)
    #expect(try repos.head(of: repos.clone) == mine)
}

@Test func aFailedBuildKeepsTheWorkingApp() throws {
    let scratch = try Scratch()
    defer { scratch.remove() }
    let checkout = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let copy = scratch.url.appendingPathComponent("beeline")
    try FileManager.default.createDirectory(at: copy.appendingPathComponent("scripts"), withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: checkout.appendingPathComponent("scripts/build-app.sh"), to: copy.appendingPathComponent("scripts/build-app.sh"))
    try "this is not a Swift package".write(to: copy.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
    let app = copy.appendingPathComponent("build/Beeline.app/Contents")
    try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
    try "working".write(to: app.appendingPathComponent("marker"), atomically: true, encoding: .utf8)

    let build = Update.shell("bash scripts/build-app.sh", in: copy.path, timeout: 120)
    #expect(!build.ok)
    #expect(try String(contentsOf: app.appendingPathComponent("marker"), encoding: .utf8) == "working")
    #expect(!FileManager.default.fileExists(atPath: copy.appendingPathComponent("build/.build-lock").path), "a failed build must not leave the lock behind")
}
