import Foundation
import Testing
@testable import Beeline

// H8: writing a big prompt into a pipe whose reader has exited must be an error, not a signal that kills the app.
@Test func writingToAChildThatHasExitedDoesNotKillTheApp() throws {
    Planner.ignoreBrokenPipes()
    let child = Process()
    child.executableURL = URL(fileURLWithPath: "/usr/bin/true")
    let input = Pipe()
    child.standardInput = input
    try child.run()
    child.waitUntilExit()
    // Far more than a pipe holds, so the write cannot be absorbed by the buffer.
    #expect(Planner.feed(Data(count: 1_000_000), to: input) == false)
}

// M9: claude is looked for where installers put it, as an executable file.
@Test func findsClaudeAmongCandidates() throws {
    let scratch = try Scratch()
    defer { scratch.remove() }
    let plain = try scratch.file("claude", "#!/bin/sh\n", in: "notexec")
    let script = try scratch.file("claude", "#!/bin/sh\n", in: "bin")
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    let missing = scratch.url.appendingPathComponent("nowhere/claude")
    #expect(Planner.find(in: [missing, plain, script]) == script)
    #expect(Planner.find(in: [missing, plain]) == nil)
}
