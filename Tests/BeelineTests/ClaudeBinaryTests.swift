import Foundation
import Testing
@testable import Beeline

private let apple = "anchor apple"

private func executable(_ scratch: Scratch, _ name: String, _ contents: String = "#!/bin/sh\necho hi\n") throws -> URL {
    let file = try scratch.file(name, contents)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
    return file
}

@Test func aBinarySignedToTheRequirementPasses() {
    #expect(ClaudeBinary.verified(URL(fileURLWithPath: "/bin/ls"), requirement: apple)?.path == "/bin/ls")
}

@Test func aValidlySignedBinaryFromAnotherTeamIsRefused() {
    #expect(ClaudeBinary.verified(URL(fileURLWithPath: "/bin/ls")) == nil)
}

@Test func anUnsignedScriptIsRefused() throws {
    let scratch = try Scratch()
    defer { scratch.remove() }
    let script = try executable(scratch, "claude")
    #expect(ClaudeBinary.verified(script, requirement: apple) == nil)
    #expect(ClaudeBinary.verified(script) == nil)
}

@Test func anAdHocSignedBinaryIsRefused() throws {
    let scratch = try Scratch()
    defer { scratch.remove() }
    let source = try scratch.file("main.c", "int main(void) { return 0; }\n")
    let binary = scratch.url.appendingPathComponent("claude")
    let cc = Process()
    cc.executableURL = URL(fileURLWithPath: "/usr/bin/cc")
    cc.arguments = ["-o", binary.path, source.path]
    try cc.run()
    cc.waitUntilExit()
    try #require(cc.terminationStatus == 0)
    #expect(ClaudeBinary.verified(binary, requirement: "anchor apple generic") == nil)
    #expect(ClaudeBinary.verified(binary) == nil)
}

@Test func aTamperedCopyOfASignedBinaryIsRefused() throws {
    let scratch = try Scratch()
    defer { scratch.remove() }
    let copy = scratch.url.appendingPathComponent("claude")
    var bytes = try Data(contentsOf: URL(fileURLWithPath: "/bin/ls"))
    bytes[bytes.count / 2] ^= 0xFF
    try bytes.write(to: copy)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: copy.path)
    #expect(ClaudeBinary.verified(copy, requirement: apple) == nil)
}

@Test func aSymlinkIsCheckedAndLaunchedAsTheFileItPointsTo() throws {
    let scratch = try Scratch()
    defer { scratch.remove() }
    let toSigned = scratch.url.appendingPathComponent("signed")
    try FileManager.default.createSymbolicLink(at: toSigned, withDestinationURL: URL(fileURLWithPath: "/bin/ls"))
    #expect(ClaudeBinary.verified(toSigned, requirement: apple)?.path == "/bin/ls")

    let script = try executable(scratch, "script")
    let toScript = scratch.url.appendingPathComponent("claude")
    try FileManager.default.createSymbolicLink(at: toScript, withDestinationURL: script)
    #expect(ClaudeBinary.verified(toScript, requirement: apple) == nil)
}

@Test func plannerRefusesAnUnsignedClaudeWithAPlainMessage() throws {
    let scratch = try Scratch()
    defer { scratch.remove() }
    let script = try executable(scratch, "claude")
    guard case .failure(.message(let text)) = Planner.launchable(script) else {
        Issue.record("ran an unsigned claude"); return
    }
    #expect(text.contains(script.path) && text.contains("isn't signed by Anthropic"))
    guard case .failure(.message(let missing)) = Planner.launchable(nil) else { Issue.record("no claude, no failure"); return }
    #expect(missing == Planner.notFoundMessage)
    if case .success(let real) = Planner.launchable(URL(fileURLWithPath: "/bin/ls"), requirement: apple) {
        #expect(real.path == "/bin/ls")
    } else { Issue.record("refused a binary that meets the requirement") }
}

/// Only on a Mac with Claude Code installed the usual way.
@Test func theInstalledClaudeMeetsTheAnthropicRequirement() {
    let installed = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/claude")
    guard FileManager.default.isExecutableFile(atPath: installed.path) else { return }
    #expect(ClaudeBinary.verified(installed) != nil)
}
