import Foundation
import Testing
@testable import Beeline

@Test func theLiveCheckIsOffUnlessAskedFor() {
    #expect(ProcessInfo.processInfo.environment["BEELINE_DEMO"] == nil)
    #expect(Demo.requested == nil)
    #expect(Demo.scenarios == ["press", "plan", "escape", "click", "welcome", "release"])
}

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
    #expect(lines[1].contains("\"event\":\"result\""))
}

@Test func aRulerMovesTheTextByItsHeight() {
    #expect(Demo.rulerMoved(from: 52, to: 84))
    #expect(Demo.rulerMoved(from: 84, to: 52))
    #expect(!Demo.rulerMoved(from: 52, to: 55))
}
