import Foundation
import Testing

// Source rules for mistakes that have already shipped more than once. Each failure lists the file and line
// and names what to use instead. BEELINE_RULES_SOURCES points the rules at another copy of Sources/Beeline,
// such as a checkout of an older commit.

private let sourceFolder: URL = ProcessInfo.processInfo.environment["BEELINE_RULES_SOURCES"].map { URL(fileURLWithPath: $0) }
    ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/Beeline")

private let sources: [(name: String, lines: [String])] = {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: sourceFolder.path)) ?? []
    return names.filter { $0.hasSuffix(".swift") }.sorted().map { name in
        let text = (try? String(contentsOf: sourceFolder.appendingPathComponent(name), encoding: .utf8)) ?? ""
        return (name, text.components(separatedBy: "\n"))
    }
}()

/// Lines outside `allowed` files that match `pattern`, skipping comment lines.
private func lines(matching pattern: String, outside allowed: Set<String>) -> [String] {
    let regex = try! NSRegularExpression(pattern: pattern)
    var found: [String] = []
    for (name, lines) in sources where !allowed.contains(name) {
        for (index, line) in lines.enumerated() {
            let code = line.trimmingCharacters(in: .whitespaces)
            if code.hasPrefix("//") { continue }
            if regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil {
                found.append("\(name):\(index + 1): \(code)")
            }
        }
    }
    return found
}

private func report(_ found: [String], _ fix: String) -> Comment {
    Comment(rawValue: fix + "\n" + found.joined(separator: "\n"))
}

@Test func theRulesReadTheSources() {
    #expect(sources.count > 20, "no sources at \(sourceFolder.path)")
}

// Tests run in the same process as the app's code, so anything that reaches the screen, the real log or the
// real Application Support folder reaches the Mac of whoever runs `swift test`.

@Test func windowsComeFrontOnlyThroughTestRun() {
    let found = lines(matching: #"makeKeyAndOrderFront|orderFrontRegardless|(?<!TestRun)\.orderFront\("#, outside: ["Log.swift"])
    #expect(found.isEmpty, report(found, "Bring a window front with TestRun.orderFront(_:key:activating:) (Log.swift): under test it builds the window but never shows it."))
}

@Test func filesLiveUnderTestRunSupportFolder() {
    let found = lines(matching: #"applicationSupportDirectory|Library/Logs"#, outside: ["Log.swift"])
    #expect(found.isEmpty, report(found, "Put a store's file under TestRun.supportFolder and log with Log.append (Log.swift): both are temp under test."))
}

// The shipped app once honored BEELINE_USAGE_FILE and BEELINE_FILES_TEST from any launch,
// and BEELINE_ALIASES_FILE and BEELINE_DESKTOPS_FILE stayed after that fix: anything that could set Beeline's
// environment could move its history or run its file chores.

@Test func onlyTheTestModeReadsBeelineSwitches() {
    let found = lines(matching: #"(environment\[|getenv\(|setenv\()"BEELINE_"#,
                      outside: ["Demo.swift", "FileSpeechBackend.swift", "main.swift"])
    #expect(found.isEmpty, report(found, "Read BEELINE_ switches only in Demo.swift, FileSpeechBackend.swift or main.swift's demo and CLI branches. A store's file comes from TestRun.supportFolder (temp under test) or a fileOverride that main.swift sets in those branches, like Usage.fileOverride."))
}
