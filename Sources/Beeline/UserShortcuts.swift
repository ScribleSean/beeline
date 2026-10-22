import AppKit

/// The shortcuts you made in the Shortcuts app, as results: "Run Shortcut Morning routine". Read with the
/// system's own `shortcuts` command, which needs no permission. What a shortcut does is up to you, so
/// Beeline never runs one by itself: not on release of ⌘Space, and never as a step of Claude's plans.
enum UserShortcuts {
    static let tool = "/usr/bin/shortcuts"

    /// Names from `shortcuts list`, one per line: trimmed, without blanks or repeats, at most 300.
    static func parse(_ output: String) -> [String] {
        var seen = Set<String>()
        return output.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
            .prefix(300)
            .map { $0 }
    }

    static func items(_ names: [String]) -> [Item] {
        let icon = NSWorkspace.shared.icon(forFile: "/System/Applications/Shortcuts.app")
        return names.map { name in
            Item(id: "shortcut:" + name, kind: .action, verb: "Run Shortcut", title: name, subtitle: "Shortcut",
                 keywords: "shortcut automation", icon: icon) { run(name) }
        }
    }

    /// Reads the list off the main thread and hands the items back on it. A missing tool or a slow one
    /// (it is given five seconds) gives no items, never a stall.
    static func load(done: @escaping ([Item]) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let output = call(["list"], timeout: 5)
            let found = items(parse(output ?? ""))
            DispatchQueue.main.async { done(found) }
        }
    }

    private static func run(_ name: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            // The name is one argument, never parsed by a shell.
            if call(["run", name], timeout: 600) == nil {
                Actions.report("The shortcut “\(name)” didn't finish. Open it in Shortcuts to see why.")
            }
        }
    }

    /// Runs the tool and returns what it printed, or nil when it failed or ran out of time.
    private static func call(_ arguments: [String], timeout: TimeInterval) -> String? {
        guard FileManager.default.isExecutableFile(atPath: tool) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        do { try process.run() } catch { return nil }
        let timer = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timer.cancel()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
