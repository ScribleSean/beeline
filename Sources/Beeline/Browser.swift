import AppKit

/// A scriptable browser whose open tabs Beeline can list and switch to.
/// The first read of each browser triggers the macOS Automation permission prompt.
struct Browser {
    let name: String
    let bundleID: String
    /// Safari calls a tab's title `name` and switches tabs differently from the Chromium browsers.
    let isSafari: Bool

    /// Tab commands run one at a time in the order given, which closing several tabs depends on.
    private static let commandQueue = DispatchQueue(label: "beeline.browser-commands", qos: .userInitiated)

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
            var item = Item(id: "tab:\(bundleID):\(window):\(index)", kind: .tab, verb: "Switch to tab",
                            title: fields[2].isEmpty ? host : fields[2],
                            subtitle: name.replacingOccurrences(of: "Google ", with: ""),
                            keywords: host, icon: icon) {
                activate(window: window, index: index)
            }
            item.tabIndex = index
            item.close = {
                let script = "tell application \"\(name)\" to close tab \(index) of window id \(window)"
                Self.commandQueue.async { _ = Self.osascript(script) }
            }
            return item
        }
    }

    /// Every window's tab addresses, in order, for saving a desktop.
    func tabAddresses() -> [[String]] {
        let script = """
        set sep to (ASCII character 9)
        set out to ""
        tell application "\(name)"
            repeat with w in windows
                try
                    repeat with t in tabs of w
                        set out to out & (URL of t) & sep
                    end repeat
                    set out to out & linefeed
                end try
            end repeat
        end tell
        return out
        """
        guard let output = Self.osascript(script) else { return [] }
        return output.split(separator: "\n").map { line in
            line.split(separator: "\t").map(String.init).filter { $0.hasPrefix("http://") || $0.hasPrefix("https://") }
        }.filter { !$0.isEmpty }
    }

    /// Opens one new browser window per saved window, with its tabs. Only web addresses are opened.
    func openWindows(_ windows: [[String]]) {
        for tabs in windows {
            let addresses = tabs.filter { $0.hasPrefix("http://") || $0.hasPrefix("https://") }
                .map { $0.replacingOccurrences(of: "\\", with: "%5C").replacingOccurrences(of: "\"", with: "%22") }
            guard let first = addresses.first else { continue }
            let rest = addresses.dropFirst()
            let script: String
            if isSafari {
                script = """
                tell application "Safari"
                    make new document with properties {URL:"\(first)"}
                    \(rest.map { "tell window 1 to make new tab with properties {URL:\"\($0)\"}" }.joined(separator: "\n"))
                end tell
                """
            } else {
                script = """
                tell application "\(name)"
                    make new window
                    set URL of active tab of window 1 to "\(first)"
                    \(rest.map { "make new tab at end of tabs of window 1 with properties {URL:\"\($0)\"}" }.joined(separator: "\n"))
                end tell
                """
            }
            Self.commandQueue.async { _ = Self.osascript(script) }
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
        Self.commandQueue.async { _ = Self.osascript(script) }
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
