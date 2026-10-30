import Foundation
import Testing
@testable import Beeline

private final class FakeSpeech {
    var running = false
    var tap = false
    var updates: [(String?, Bool, Bool) -> Void] = []
    var starts = 0
    var stops = 0
    var io: Voice.IO {
        Voice.IO(authorise: { $0(nil) }, begin: { _, update, _ in
            self.starts += 1
            self.running = true
            self.tap = true
            self.updates.append(update)
            return nil
        }, stop: {
            self.running = false
            self.tap = false
            self.stops += 1
        }, cancel: {})
    }
}

@Test func recognitionCompletionStopsCaptureAndAllowsRestart() {
    for final in [true, false] {
        let speech = FakeSpeech()
        let voice = Voice(io: speech.io)
        var states: [String] = []
        var finals: [String] = []
        voice.onState = { state in
            switch state {
            case .listening: states.append("listening")
            case .stopped: states.append("stopped")
            case .unavailable: states.append("unavailable")
            }
        }
        voice.onFinal = { finals.append($0) }
        voice.start()
        #expect(speech.running && speech.tap)
        speech.updates[0](final ? "hello" : nil, final, true)
        #expect(!speech.running && !speech.tap)
        #expect(states == ["listening", "stopped"])
        #expect(speech.stops == 1)
        #expect(finals == (final ? ["hello"] : []))
        voice.start()
        #expect(speech.starts == 2)
        speech.updates[0](nil, false, true) // Late completion from the old task.
        #expect(speech.running && speech.tap)
        voice.cancel()
    }
}

@Test func stoppingDuringSpeechAuthorisationPreventsCapture() {
    let speech = FakeSpeech()
    var authorisation: ((String?) -> Void)?
    var io = speech.io
    io.authorise = { authorisation = $0 }
    let voice = Voice(io: io)
    voice.start()
    voice.stop()
    authorisation?(nil)
    #expect(speech.starts == 0)
}

private let cleanupItem = Item(id: "cleanup", kind: .app, verb: "", title: "Cleanup", subtitle: "", keywords: "", icon: nil, run: {})

@Test func forgetEverythingDeletesAfterPendingSave() {
    let queue = DispatchQueue(label: "test.usage.pending")
    queue.suspend()
    var disk: Data?
    var operations: [String] = []
    let io = Usage.IO(read: { _ in nil }, write: { data, _ in
        disk = data
        operations.append("save")
    }, remove: { _ in
        disk = nil
        operations.append("delete")
    })
    let usage = Usage(file: URL(fileURLWithPath: "/fake/usage.json"), io: io, saveQueue: queue)
    usage.record(cleanupItem, query: "cleanup")
    usage.forgetEverything()
    queue.resume()
    usage.flush()
    #expect(operations == ["save", "delete"])
    #expect(disk == nil)
    #expect(usage.habitBoost(for: cleanupItem) == 0)
    usage.record(cleanupItem, query: "new")
    usage.flush()
    #expect(disk != nil, "new activity can be saved after forgetting")
}

@Test func cancelledPlacementNeverActivatesOrMovesWindow() {
    let cancel = CancelToken()
    var delivered: (() -> Void)?
    var placed = false
    Accessibility.waitToPlace(cancel: cancel, find: { 42 }, place: { _ in placed = true },
                              deliver: { delivered = $0 }, pause: {})
    cancel.cancel()
    delivered?()
    #expect(!placed)

    var looked = false
    Accessibility.waitToPlace(cancel: cancel, find: { looked = true; return 42 },
                              place: { _ in placed = true }, deliver: { $0() }, pause: {})
    #expect(!looked && !placed)
}

@Test func placementStopsPollingAfterCancelAndPlacesNormallyOtherwise() {
    let cancel = CancelToken()
    var polls = 0
    Accessibility.waitToPlace(cancel: cancel, find: { () -> Int? in polls += 1; return nil },
                              place: { _ in Issue.record("placed after cancellation") },
                              deliver: { $0() }, pause: { cancel.cancel() })
    #expect(polls == 1)
    var placed: Int?
    Accessibility.waitToPlace(cancel: CancelToken(), find: { 42 }, place: { placed = $0 },
                              deliver: { $0() }, pause: {})
    #expect(placed == 42)
}

private final class FakeClaudeProcess: PlannerProcess {
    var isRunning = false
    var starts = 0
    var terminations = 0
    func run() throws { starts += 1; isRunning = true }
    func terminate() { terminations += 1; isRunning = false }
}

@Test func processCancellationBeforeLaunchIsRemembered() throws {
    let registry = PlannerProcesses()
    let process = FakeClaudeProcess()
    let early = registry.reserve()
    registry.cancel(early)
    #expect(!registry.register(process, for: early))
    #expect(try !registry.start(early))
    let registered = registry.reserve()
    #expect(registry.register(process, for: registered))
    registry.cancel(registered)
    #expect(try !registry.start(registered))
    #expect(process.starts == 0)
}

@Test func lateCancelCannotTerminateNewerClaudeRequest() throws {
    let registry = PlannerProcesses()
    let a = registry.reserve(), b = registry.reserve()
    let first = FakeClaudeProcess(), second = FakeClaudeProcess()
    #expect(registry.register(first, for: a))
    #expect(try registry.start(a))
    registry.cancel(a)
    #expect(first.terminations == 1)
    #expect(registry.register(second, for: b))
    #expect(try registry.start(b))
    registry.cancel(a)
    registry.finish(a)
    #expect(second.isRunning && second.terminations == 0)
    registry.cancel(b)
    #expect(second.terminations == 1)
}

@Test func usageOverrideWorksInEveryBuildConfiguration() {
    let folder = URL(fileURLWithPath: "/fake/Beeline")
    let temporary = URL(fileURLWithPath: "/fake/temporary-usage.json")
    #expect(Usage.historyFile(in: folder, override: nil) == folder.appendingPathComponent("usage.json"))
    #expect(Usage.historyFile(in: folder, override: temporary) == temporary)
    #expect(!FileTools.exitWhenDone)
}

@Test func completedPlanStillPlacesLateWindowUnlessStopped() {
    for reason in [RunGuard.Reason.escape, .takeover, .replaced] {
        let guarder = RunGuard(watches: false)
        let cancel = CancelToken()
        let run = guarder.begin()
        guarder.end(run, pending: cancel)
        #expect(!guarder.isCurrent(run))
        var polls = 0
        var placed = false
        Accessibility.waitToPlace(cancel: cancel, find: { () -> Int? in
            polls += 1
            return polls == 3 ? 42 : nil
        }, place: { _ in placed = true }, deliver: { $0() }, pause: {})
        #expect(placed, "a window appearing after normal plan completion must still be placed")
        guarder.stop(reason)
        placed = false
        Accessibility.waitToPlace(cancel: cancel, find: { 42 }, place: { _ in placed = true },
                                  deliver: { $0() }, pause: {})
        #expect(!placed)
    }
}

@Test func newRequestCancelsPlacementFromCompletedPlan() {
    let guarder = RunGuard(watches: false)
    let cancel = CancelToken()
    let run = guarder.begin()
    guarder.end(run, pending: cancel)
    _ = guarder.begin()
    #expect(cancel.isCancelled)
}

@Test func existingUsageDirectoryGetsPrivatePermissions() throws {
    let scratch = try Scratch()
    defer { scratch.remove() }
    let folder = scratch.url.appendingPathComponent("Beeline")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
    let usage = Usage(file: folder.appendingPathComponent("usage.json"))
    usage.record(cleanupItem, query: "cleanup")
    usage.flush()
    let attributes = try FileManager.default.attributesOfItem(atPath: folder.path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
}

@Test func usageDirectoryIsCreatedWithPrivatePermissions() throws {
    let scratch = try Scratch()
    defer { scratch.remove() }
    let folder = scratch.url.appendingPathComponent("Beeline")
    let usage = Usage(file: folder.appendingPathComponent("usage.json"))
    usage.record(cleanupItem, query: "cleanup")
    usage.flush()
    let attributes = try FileManager.default.attributesOfItem(atPath: folder.path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
}

@Test func smallHistoryIsPrunedOnLoadAndSavedWithoutOldTitles() throws {
    let old = Date().addingTimeInterval(-91 * 86_400).timeIntervalSinceReferenceDate
    let now = Date().timeIntervalSinceReferenceDate
    let data = Data("""
        {"items":{"old title":{"count":1,"last":\(old)},"cleanup":{"count":1,"last":\(now)}},
         "queries":{"old query":{"old title":1},"old pick":{"cleanup":1},"recent":{"cleanup":1}},
         "queryLast":{"old query":{"old title":\(old)},"old pick":{"cleanup":\(old)},"recent":{"cleanup":\(now)}}}
        """.utf8)
    var disk = data
    let io = Usage.IO(read: { _ in disk }, write: { bytes, _ in disk = bytes }, remove: { _ in })
    let usage = Usage(file: URL(fileURLWithPath: "/fake/usage.json"), io: io)
    usage.flush()
    let text = String(decoding: disk, as: UTF8.self)
    #expect(!text.contains("old title"))
    #expect(!text.contains("old query"))
    #expect(!text.contains("old pick"))
    #expect(text.contains("recent"))
    usage.record(cleanupItem, query: "new")
    usage.flush()
    #expect(!String(decoding: disk, as: UTF8.self).contains("old"))
}
