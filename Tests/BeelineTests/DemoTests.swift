import Foundation
import Testing
@testable import Beeline

// The live check only starts when asked for by name.
@Test func theLiveCheckIsOffUnlessAskedFor() {
    #expect(ProcessInfo.processInfo.environment["BEELINE_DEMO"] == nil)
    #expect(Demo.requested == nil)
    #expect(Demo.scenarios == ["press", "plan", "escape", "click", "welcome"])
}

// Each line of the log is one JSON object a script can read, in the order things happened.
@Test func theLiveCheckLogIsOneJSONObjectPerLine() throws {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent("beeline-demo-\(UUID().uuidString).jsonl").path
    defer { try? FileManager.default.removeItem(atPath: path) }
    let log = try #require(DemoLog(path: path))
    log.write("bee-takeoff", ["seconds": 1.2, "to": DemoLog.numbers(CGPoint(x: 10.04, y: 20))])
    log.write("result", ["pass": true, "why": "a line\nbreak"])
    #expect(log.count("bee-takeoff") == 1)
    #expect(log.last("result")?["pass"] as? Bool == true)

    let lines = try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n")
    #expect(lines.count == 2)
    let first = try #require(JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any])
    #expect(first["event"] as? String == "bee-takeoff")
    #expect(first["to"] as? [Double] == [10, 20])
    #expect(first["t"] is Double)
    // The script finds the result with a plain text search.
    #expect(lines[1].contains("\"event\":\"result\""))
}

@Test func noLogMeansNotesDoNothing() {
    DemoLog.shared = nil
    DemoLog.note("pressed", ["title": "Send"])
    #expect(DemoLog.shared == nil)
}
