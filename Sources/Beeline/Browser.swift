import AppKit

/// A scriptable browser whose open tabs Beeline can list and switch to.
/// The first read of each browser triggers the macOS Automation permission prompt.
struct Browser {
    let name: String
    let bundleID: String
    /// Safari calls a tab's title `name` and switches tabs differently from the Chromium browsers.
    let isSafari: Bool

    /// Tab commands for this browser run one at a time, in the order given. One queue per browser, so a
    /// browser that hangs does not hold up the others.
    private let commandQueue: DispatchQueue

    init(name: String, bundleID: String, isSafari: Bool) {
        self.name = name
        self.bundleID = bundleID
        self.isSafari = isSafari
        commandQueue = DispatchQueue(label: "beeline.browser." + bundleID, qos: .userInitiated)
    }

    static let all = [
        Browser(name: "Google Chrome", bundleID: "com.google.Chrome", isSafari: false),
        Browser(name: "Safari", bundleID: "com.apple.Safari", isSafari: true),
        Browser(name: "Brave Browser", bundleID: "com.brave.Browser", isSafari: false),
        Browser(name: "Microsoft Edge", bundleID: "com.microsoft.edgemac", isSafari: false),
    ]

    /// The name shown beside a tab: "Chrome", "Safari", "Brave Browser", "Microsoft Edge".
    var shortName: String { name.replacingOccurrences(of: "Google ", with: "") }

    func tabs() -> [Item] {
        // Chromium browsers give each tab a stable id, which is how a tab is closed or switched to later;
        // Safari has none, so its tabs are found again by address and name when the time comes.
        let script = """
        set sep to (ASCII character 9)
        set out to ""
        tell application "\(name)"
            repeat with w in windows
                try
                    set wid to id of w
                    repeat with t in tabs of w
                        set out to out & wid & sep & (\(isSafari ? "0" : "id of t")) & sep & (\(isSafari ? "name" : "title") of t) & sep & (URL of t) & linefeed
                    end repeat
                end try
            end repeat
        end tell
        return out
        """
        guard let output = Self.osascript(script) else { return [] }
        let icon = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            .map { NSWorkspace.shared.icon(forFile: $0.path) }

        var seen = 0
        return output.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 4, let window = Int(fields[0]), let tabID = Int(fields[1]) else { return nil }
            seen += 1
            let host = URL(string: fields[3])?.host ?? ""
            let title = fields[2]
            let address = fields[3]
            var item = Item(id: "tab:\(bundleID):\(window):\(isSafari ? seen : tabID)", kind: .tab, verb: "Switch to tab",
                            title: title.isEmpty ? host : title, subtitle: shortName, keywords: host, icon: icon) {
                activate(window: window, tabID: tabID, address: address, title: title)
            }
            // Exactly one tab is closed: by id in Chromium browsers, and in Safari the first tab in that
            // window with both this address and this name, so a second tab on the same address stays open.
            item.close = {
                let script = isSafari
                    ? "tell application \"Safari\" to close (first tab of window id \(window) whose URL is \(Self.quoted(address)) and name is \(Self.quoted(title)))"
                    : "tell application \"\(name)\" to close tab id \(tabID) of window id \(window)"
                commandQueue.async { _ = Self.osascript(script) }
            }
            return item
        }
    }

    /// Text as an AppleScript string literal. Only quotes and backslashes have meaning inside one.
    private static func quoted(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
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
            commandQueue.async { _ = Self.osascript(script) }
        }
    }

    /// Brings a tab to the front. The tab is found again when this runs, not by the position it had when
    /// the bar opened: tabs may have opened, closed or moved since, including by an earlier plan step.
    private func activate(window: Int, tabID: Int, address: String, title: String) {
        let select: String
        if isSafari {
            select = """
                tell window id \(window)
                    try
                        set current tab to (first tab whose URL is \(Self.quoted(address)) and name is \(Self.quoted(title)))
                    on error
                        set current tab to (first tab whose URL is \(Self.quoted(address)))
                    end try
                end tell
                """
        } else {
            select = """
                set w to window id \(window)
                repeat with i from 1 to count of tabs of w
                    if id of tab i of w is \(tabID) then
                        set active tab index of w to i
                        exit repeat
                    end if
                end repeat
                """
        }
        let script = """
        tell application "\(name)"
            \(select)
            set index of window id \(window) to 1
            activate
        end tell
        """
        commandQueue.async { _ = Self.osascript(script) }
    }

    /// Runs AppleScript in a child process so it is safe off the main thread. A browser that does not
    /// answer (hung, or waiting on an Automation prompt) is given up on after a few seconds rather than
    /// AppleScript's two minutes, so tab commands never fire long after they were asked for.
    private static func osascript(_ source: String, timeout: TimeInterval = 5) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "with timeout of \(Int(timeout)) seconds\n" + source + "\nend timeout"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout + 1) {
            if process.isRunning { process.terminate() }
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
