import AppKit

/// The system's `shortcuts` command needs no permission.
enum UserShortcuts {
    static let tool = "/usr/bin/shortcuts"

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

    static func load(done: @escaping ([Item]) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let output = call(["list"], timeout: 5)
            let found = items(parse(output ?? ""))
            DispatchQueue.main.async { done(found) }
        }
    }

    private static func run(_ name: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            if call(["run", name], timeout: 600) == nil {
                Actions.report("The shortcut “\(name)” didn't finish. Open it in Shortcuts to see why.")
            }
        }
    }

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
