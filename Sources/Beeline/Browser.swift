import AppKit

/// A scriptable browser whose open tabs Beeline can list and switch to.
/// The first read of each browser triggers the macOS Automation permission prompt.
struct Browser {
    let name: String
    let bundleID: String
    /// Safari calls a tab's title `name` and switches tabs differently from the Chromium browsers.
    let isSafari: Bool

    static let all = [
        Browser(name: "Google Chrome", bundleID: "com.google.Chrome", isSafari: false),
        Browser(name: "Safari", bundleID: "com.apple.Safari", isSafari: true),
        Browser(name: "Brave Browser", bundleID: "com.brave.Browser", isSafari: false),
        Browser(name: "Microsoft Edge", bundleID: "com.microsoft.edgemac", isSafari: false),
    ]

    func tabs() -> [Item] {
        let script = """
        set sep to (ASCII character 9)
        set out to ""
        tell application "\(name)"
            repeat with w in windows
                try
                    set wid to id of w
                    set ti to 0
                    repeat with t in tabs of w
                        set ti to ti + 1
                        set out to out & wid & sep & ti & sep & (\(isSafari ? "name" : "title") of t) & sep & (URL of t) & linefeed
                    end repeat
                end try
            end repeat
        end tell
        return out
        """
        guard let output = Self.osascript(script) else { return [] }
        let icon = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            .map { NSWorkspace.shared.icon(forFile: $0.path) }

        return output.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 4, let window = Int(fields[0]), let index = Int(fields[1]) else { return nil }
            let host = URL(string: fields[3])?.host ?? ""
            return Item(id: "tab:\(bundleID):\(window):\(index)", kind: .tab, verb: "Switch to tab",
                        title: fields[2].isEmpty ? host : fields[2],
                        subtitle: name.replacingOccurrences(of: "Google ", with: ""),
                        keywords: host, icon: icon) {
                activate(window: window, index: index)
            }
        }
    }

    private func activate(window: Int, index: Int) {
        let select = isSafari
            ? "tell window id \(window) to set current tab to tab \(index)"
            : "set active tab index of window id \(window) to \(index)"
        let script = """
        tell application "\(name)"
            \(select)
            set index of window id \(window) to 1
            activate
        end tell
        """
        DispatchQueue.global(qos: .userInitiated).async { _ = Self.osascript(script) }
    }

    /// Runs AppleScript in a child process so it is safe off the main thread.
    private static func osascript(_ source: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
