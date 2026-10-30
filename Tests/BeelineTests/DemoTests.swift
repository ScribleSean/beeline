import Foundation
import Testing
@testable import Beeline

@Test func theLiveCheckScriptRunsEveryScenarioTheAppKnows() throws {
    let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("scripts/live-check.sh")
    let text = try String(contentsOf: script, encoding: .utf8)
    let known = try #require(text.split(separator: "\n").first { $0.hasPrefix("known=") })
    let scenarios = Demo.scenarios.filter { $0 != "voice" }
    #expect(known.dropFirst(6).trimmingCharacters(in: CharacterSet(charactersIn: "\" ")).split(separator: " ").map(String.init) == scenarios)
    #expect(text.contains("scenarios=(\(scenarios.joined(separator: " ")))"), "running with no names must run them all")
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
