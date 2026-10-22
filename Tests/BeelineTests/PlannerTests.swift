import Foundation
import Testing
@testable import Beeline

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

private func picked(_ reply: String, from count: Int = 5) -> [Int]? {
    if case .success(let plan) = Planner.read(reply, optionCount: count) { return plan.steps }
    return nil
}

@Test func aPlanIsTheOptionNumbersInOrderWithTheNote() throws {
    let reply = #"Here you go: {"steps":[3,1],"note":"Mutes, then locks."} Hope that helps."#
    guard case .success(let plan) = Planner.read(reply, optionCount: 5) else { Issue.record("refused a good plan"); return }
    #expect(plan.steps == [3, 1])
    #expect(plan.note == "Mutes, then locks.")
    #expect(picked(#"{"steps":[],"note":"Beeline can't book flights."}"#) == [])
    #expect(picked("```json\n{\"steps\":[2]}\n```") == [2])
}

@Test func claudeCanOnlyPickFromTheList() {
    #expect(picked(#"{"steps":[6]}"#) == nil)
    #expect(picked(#"{"steps":[0]}"#) == nil)
    #expect(picked(#"{"steps":[-1]}"#) == nil)
    #expect(picked(#"{"steps":[1]}"#, from: 0) == nil)
    #expect(picked(#"{"steps":[2,7,1]}"#) == nil, "one bad number refuses the whole plan, not just that step")
}

@Test func onlyWholeNumbersCountAsSteps() {
    #expect(picked(#"{"steps":["2"]}"#) == nil)
    #expect(picked(#"{"steps":[true]}"#) == nil, "true must not read as option 1")
    #expect(picked(#"{"steps":[2.5]}"#) == nil)
    #expect(picked(#"{"steps":[null]}"#) == nil)
    #expect(picked(#"{"steps":[[1]]}"#) == nil)
    #expect(picked(#"{"steps":[{"option":1}]}"#) == nil)
    #expect(picked(#"{"steps":[99999999999999999999]}"#) == nil)
    #expect(picked(#"{"steps":["Quit Finder"]}"#) == nil)
}

@Test func aStepRunsAtMostOnceAndPlansStayShort() {
    #expect(picked(#"{"steps":[1,1]}"#) == nil)
    #expect(picked(#"{"steps":[1,2,3,4,5,6,7,8]}"#, from: 9) == [1, 2, 3, 4, 5, 6, 7, 8])
    #expect(picked(#"{"steps":[1,2,3,4,5,6,7,8,9]}"#, from: 9) == nil)
}

@Test func aReplyThatIsntAPlanIsRefused() {
    for reply in ["", "I can't help with that.", "{}", #"{"note":"no steps"}"#, #"{"steps":1}"#, #"{"steps":"1,2"}"#,
                  #"{"steps":[1]"#, #"} {"steps":[1]"#, #"{"steps":[1]} and {"steps":[2]}"#,
                  "{\"steps\":[1],\"note\":\"" + String(repeating: "x", count: 20_000) + "\"}"] {
        #expect(picked(reply) == nil, "accepted: \(reply.prefix(60))")
    }
}

@Test func aNoteThatIsntTextIsDropped() {
    guard case .success(let plan) = Planner.read(#"{"steps":[1],"note":{"say":"hi"}}"#, optionCount: 2) else {
        Issue.record("refused a plan over its note"); return
    }
    #expect(plan.steps == [1])
    #expect(plan.note.isEmpty)
}
