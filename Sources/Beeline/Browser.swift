import AppKit

/// The first read of each browser triggers the macOS Automation permission prompt.
struct Browser {
    let name: String
    let bundleID: String
    /// Safari calls a tab's title `name` and switches tabs differently from the Chromium browsers.
    let isSafari: Bool

    private let commandQueue: DispatchQueue
    private let execute: (String) -> String?
    private let report: (String) -> Void

    init(name: String, bundleID: String, isSafari: Bool,
         execute: @escaping (String) -> String? = { Browser.osascript($0) },
         report: @escaping (String) -> Void = { Actions.report($0) }) {
        self.name = name
        self.bundleID = bundleID
        self.isSafari = isSafari
        self.execute = execute
        self.report = report
        commandQueue = DispatchQueue(label: "beeline.browser." + bundleID, qos: .userInitiated)
    }

    static let all = [
        Browser(name: "Google Chrome", bundleID: "com.google.Chrome", isSafari: false),
        Browser(name: "Safari", bundleID: "com.apple.Safari", isSafari: true),
        Browser(name: "Brave Browser", bundleID: "com.brave.Browser", isSafari: false),
        Browser(name: "Microsoft Edge", bundleID: "com.microsoft.edgemac", isSafari: false),
    ]

    var shortName: String { name.replacingOccurrences(of: "Google ", with: "") }

    func tabs() -> [Item] {
        // Chromium browsers give each tab a stable id; Safari has none, so its tabs are found again by
        // address and name.
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
        guard let output = Self.osascript(script, timeout: 60) else { return [] }
        let icon = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            .map { NSWorkspace.shared.icon(forFile: $0.path) }
        return items(from: output, icon: icon)
    }

    /// One tab per line: window id, tab id, title and address, split by tabs.
    func items(from output: String, icon: NSImage?) -> [Item] {
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
            item.link = URL(string: address)
            item.close = {
                let script: String
                if isSafari {
                    script = Self.safariCommand(window: window, address: address, title: title, closing: true)
                } else {
                    script = "tell application \"\(name)\" to close tab id \(tabID) of window id \(window)"
                }
                commandQueue.async { runCommand(script) }
            }
            return item
        }
    }

    /// Only quotes and backslashes have meaning inside an AppleScript string literal.
    static func quoted(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    func tabAddresses() -> [[String]]? {
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
        guard let output = Self.osascript(script, timeout: 60) else { return nil }
        return output.split(separator: "\n").map { line in
            line.split(separator: "\t").map(String.init).filter { $0.hasPrefix("http://") || $0.hasPrefix("https://") }
        }.filter { !$0.isEmpty }
    }

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
            commandQueue.async { _ = Self.osascript(script, timeout: 120) }
        }
    }

    private func activate(window: Int, tabID: Int, address: String, title: String) {
        let select: String
        if isSafari {
            let script = Self.safariCommand(window: window, address: address, title: title, closing: false)
            commandQueue.async { runCommand(script) }
            return
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
        commandQueue.async { runCommand(script) }
    }

    private func runCommand(_ script: String) {
        if execute(script)?.trimmingCharacters(in: .whitespacesAndNewlines) == "ambiguous" {
            report("Several Safari tabs match this page. Make the tab you mean unique, then try again, or select it in Safari.")
        }
    }

    // This handler is also exercised with plain lists, without contacting Safari.
    static let safariMatchHandler = """
    script safariResolver
    on uniqueSafariMatch(exactMatches, addressMatches)
        if (count of exactMatches) > 1 then return {"ambiguous"}
        if (count of exactMatches) is 1 then return {"ok", item 1 of exactMatches}
        if (count of addressMatches) > 1 then return {"ambiguous"}
        if (count of addressMatches) is 1 then return {"ok", item 1 of addressMatches}
        return {"missing"}
    end uniqueSafariMatch
    end script
    """

    static func safariCommand(window: Int, address: String, title: String, closing: Bool) -> String {
        """
        \(safariMatchHandler)
        tell application "Safari"
            tell window id \(window)
                set exactMatches to (get tabs whose URL is \(quoted(address)) and name is \(quoted(title)))
                set addressMatches to (get tabs whose URL is \(quoted(address)))
                set choice to safariResolver's uniqueSafariMatch(exactMatches, addressMatches)
                if item 1 of choice is not "ok" then return item 1 of choice
                \(closing ? "close (item 2 of choice)" : "set current tab to (item 2 of choice)")
            end tell
            \(closing ? "" : "set index of window id \(window) to 1\nactivate")
        end tell
        return "ok"
        """
    }

    /// Runs AppleScript in a child process so it is safe off the main thread. AppleScript's own Apple
    /// event timeout is two minutes, so a shorter one is set.
    static func osascript(_ source: String, timeout: TimeInterval = 5) -> String? {
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
