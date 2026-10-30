import AppKit

/// True inside `swift test`: the process is a test runner (xctest, or swiftpm-testing-helper for Swift Testing)
/// that loaded an .xctest bundle. The shipped app, a process named Beeline, is never this.
enum TestRun {
    static let isActive: Bool = {
        let process = ProcessInfo.processInfo
        if ["xctest", "swiftpm-testing-helper"].contains(process.processName) { return true }
        if process.environment["XCTestConfigurationFilePath"] != nil { return true }
        return process.arguments.contains { $0.contains(".xctest") }
            || Bundle.allBundles.contains { $0.bundlePath.hasSuffix(".xctest") }
    }()

    /// Where Beeline keeps its files. Under test it's a fresh temp folder, so a store made before a test sets
    /// its own file still never reads or writes the real one.
    static let supportFolder: URL = isActive
        ? FileManager.default.temporaryDirectory.appendingPathComponent("beeline-tests-support-" + UUID().uuidString, isDirectory: true)
        : FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Beeline", isDirectory: true)

    /// Brings a window front, except under test, where it's built but never put on screen.
    static func orderFront(_ window: NSWindow?, key: Bool = true, activating: Bool = false) {
        guard let window, !isActive else { return }
        if activating { NSApp.activate(ignoringOtherApps: true) }
        key ? window.makeKeyAndOrderFront(nil) : window.orderFrontRegardless()
    }
}

enum Log {
    static let path = TestRun.isActive
        ? NSTemporaryDirectory() + "Beeline-tests.log"
        : NSHomeDirectory() + "/Library/Logs/Beeline.log"

    static func start(_ line: String) {
        try? (line + "\n").write(toFile: path, atomically: true, encoding: .utf8)
    }

    private static let queue = DispatchQueue(label: "beeline.log")

    private static let maximumBytes: UInt64 = 5_000_000

    static func append(_ line: String) {
        queue.async {
            guard let handle = FileHandle(forWritingAtPath: path) else { return start(line) }
            defer { try? handle.close() }
            guard let end = try? handle.seekToEnd(), end < maximumBytes else { return start(line) }
            try? handle.write(contentsOf: Data((line + "\n").utf8))
        }
    }

    /// Waits for queued lines to land; tests use it to read what was written.
    static func flush() { queue.sync {} }
}
