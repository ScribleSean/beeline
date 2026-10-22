import Foundation
import Testing
@testable import Beeline

@Test func unreadableUsageFileIsKeptAside() throws {
    let scratch = try Scratch()
    defer { scratch.remove() }
    let file = try scratch.file("usage.json", "{ this is not json")
    let usage = Usage(file: file)
    #expect(!FileManager.default.fileExists(atPath: file.path), "the bad file moves out of the way")
    let kept = try FileManager.default.contentsOfDirectory(atPath: scratch.url.path).filter { $0.hasPrefix("usage.json.unreadable-") }
    #expect(kept.count == 1)
    #expect(try String(contentsOf: scratch.url.appendingPathComponent(kept[0]), encoding: .utf8) == "{ this is not json")
    usage.record(Item(id: "a", kind: .app, verb: "", title: "A", subtitle: "", keywords: "", icon: nil, run: {}), query: "a")
    usage.flush()
    #expect(FileManager.default.fileExists(atPath: file.path))
}

@Test func jsonStoreReadsAGoodFile() throws {
    let scratch = try Scratch()
    defer { scratch.remove() }
    let file = try scratch.file("list.json", "[1, 2, 3]")
    #expect(JSONStore.read([Int].self, from: file, name: "test") == [1, 2, 3])
    #expect(JSONStore.read([Int].self, from: scratch.url.appendingPathComponent("none.json"), name: "test") == nil)
}
