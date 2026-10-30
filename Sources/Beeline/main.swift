import AppKit
import SwiftUI

Settings.registerDefaults()
Planner.ignoreBrokenPipes()

if Demo.requested != nil {
    Usage.fileOverride = ProcessInfo.processInfo.environment["BEELINE_USAGE_FILE"].map { URL(fileURLWithPath: $0) }
        ?? FileManager.default.temporaryDirectory.appendingPathComponent("beeline-live-check-usage.json")
    if ProcessInfo.processInfo.environment["BEELINE_USAGE_FILE"] == nil {
        Aliases.fileOverride = FileManager.default.temporaryDirectory.appendingPathComponent("beeline-live-check-aliases.json")
    }
}

let knownFlags: [String: Int] = ["--query": 1, "--rewrite": 2, "--controls": 1, "--preview": 2, "--preview-welcome": 1, "--preview-settings": 1,
                                 "--files": 2, "--pick": 2, "--ai": 1, "--plan": 1]
// Single-dash arguments are macOS's and Xcode's own (-NSDocumentRevisionsDebugMode and the like).
if let flag = CommandLine.arguments.dropFirst().first(where: { $0.hasPrefix("--") }) {
    let position = CommandLine.arguments.firstIndex(of: flag)!
    if let needed = knownFlags[flag], CommandLine.arguments.count > position + needed {
        if Usage.fileOverride == nil {
            Usage.fileOverride = ProcessInfo.processInfo.environment["BEELINE_USAGE_FILE"].map { URL(fileURLWithPath: $0) }
                ?? FileManager.default.temporaryDirectory.appendingPathComponent("beeline-cli-usage.json")
        }
    } else {
        print("Unknown or incomplete flag \(flag). Flags: " + knownFlags.keys.sorted().joined(separator: ", "))
        exit(2)
    }
}

if let flag = CommandLine.arguments.firstIndex(of: "--query"), CommandLine.arguments.count > flag + 1 {
    let catalogue = Catalogue()
    catalogue.prepareMeaningNow()
    catalogue.loadFilesNow(for: CommandLine.arguments[flag + 1])
    Rates.shared.refreshIfStale(wait: true)
    for item in catalogue.search(CommandLine.arguments[flag + 1]) {
        print("\(item.isGuess ? "~ " : "  ")\(item.verb) \(item.title)  [\(item.subtitle)]")
    }
    exit(0)
}

if let flag = CommandLine.arguments.firstIndex(of: "--rewrite"), CommandLine.arguments.count > flag + 2 {
    let instruction = CommandLine.arguments[flag + 1]
    print(Rewrite.isRequest(instruction) ? "offered: Rewrite the selected text" : "not offered")
    let done = DispatchSemaphore(value: 0)
    Task {
        switch await Rewrite.ask(instruction, text: CommandLine.arguments[flag + 2]) {
        case .success(let text): print("---\n\(text)")
        case .failure(.message(let message)): print("failed: \(message)")
        }
        done.signal()
    }
    done.wait()
    exit(0)
}

if let flag = CommandLine.arguments.firstIndex(of: "--controls"), CommandLine.arguments.count > flag + 1 {
    let name = CommandLine.arguments[flag + 1]
    if let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == name }) {
        for item in Accessibility.controls(of: app) {
            print("\(item.needsConfirm ? "!" : " ") \(item.verb) \(item.title)  [\(item.subtitle)]")
        }
    } else {
        print("\(name) is not running")
    }
    exit(0)
}

// The frosted glass cannot be captured offscreen, so a backdrop stands in.
if let flag = CommandLine.arguments.firstIndex(of: "--preview"), CommandLine.arguments.count > flag + 2 {
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    let dark = CommandLine.arguments.contains("dark")
    app.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    let model = BarModel()
    model.catalogue.prepareMeaningNow()
    model.catalogue.includeFiles = false
    model.query = CommandLine.arguments[flag + 1]
    if CommandLine.arguments.contains("arm") { model.runSelected() }
    model.showsShortcutHint = CommandLine.arguments.contains("first-open")
    if CommandLine.arguments.contains("actions") {
        if let index = CommandLine.arguments.firstIndex(of: "actions"), CommandLine.arguments.count > index + 1,
           let row = Int(CommandLine.arguments[index + 1]) { model.actionSelected = row }
        let row = model.actionSelected
        model.toggleActions()
        model.actionSelected = row
        if let index = CommandLine.arguments.firstIndex(of: "filter"), CommandLine.arguments.count > index + 1 {
            model.typeInActions(CommandLine.arguments[index + 1])
        }
    }
    if CommandLine.arguments.contains("plan") {
        let icon = { (name: String) in NSWorkspace.shared.icon(forFile: "/System/Applications/\(name).app") }
        model.plan = Plan(steps: [
            PlanStep(text: "Open the app Notes and put it on the left half of the screen", icon: icon("Notes"), run: {}),
            PlanStep(text: "Turn Wi-Fi Off", icon: NSImage(systemSymbolName: "wifi.slash", accessibilityDescription: nil), run: {}),
            PlanStep(text: "Keep Mac Awake for 1 Hour", icon: NSImage(systemSymbolName: "cup.and.saucer", accessibilityDescription: nil), run: {}),
        ], note: "Notes on the left, Wi-Fi off, and the Mac kept awake for an hour.")
    }
    let size = NSSize(width: 720, height: 460)
    let backdrop = NSView(frame: NSRect(origin: .zero, size: size))
    backdrop.wantsLayer = true
    backdrop.layer?.backgroundColor = (dark ? NSColor(white: 0.18, alpha: 1) : NSColor(red: 0.86, green: 0.85, blue: 0.82, alpha: 1)).cgColor
    let host = NSHostingView(rootView: BarView(model: model, solidOverride: CommandLine.arguments.contains("solid") ? true : nil))
    host.frame = backdrop.bounds
    backdrop.addSubview(host)
    let window = NSWindow(contentRect: backdrop.frame, styleMask: .borderless, backing: .buffered, defer: false)
    window.appearance = app.appearance
    window.contentView = backdrop
    backdrop.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.4))
    // Focusing an NSTextField selects all its text.
    if let editor = window.firstResponder as? NSTextView {
        editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    }
    let rep = backdrop.bitmapImageRepForCachingDisplay(in: backdrop.bounds)!
    backdrop.cacheDisplay(in: backdrop.bounds, to: rep)
    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: CommandLine.arguments[flag + 2]))
    exit(0)
}

if let flag = CommandLine.arguments.firstIndex(of: "--preview-welcome"), CommandLine.arguments.count > flag + 1 {
    NSApplication.shared.setActivationPolicy(.prohibited)
    WelcomeWindowController.renderPreview(to: CommandLine.arguments[flag + 1])
    exit(0)
}

if let flag = CommandLine.arguments.firstIndex(of: "--preview-settings"), CommandLine.arguments.count > flag + 1 {
    NSApplication.shared.setActivationPolicy(.prohibited)
    SettingsWindowController.renderPreview(to: CommandLine.arguments[flag + 1])
    exit(0)
}

if let flag = CommandLine.arguments.firstIndex(of: "--files"), CommandLine.arguments.count > flag + 2 {
    var paths = Array(CommandLine.arguments[(flag + 2)...])
    let folder = paths.last.flatMap { $0.hasSuffix("/") ? URL(fileURLWithPath: $0) : nil }
    if folder != nil { paths.removeLast() }
    FileTools.useSelection(paths.map { URL(fileURLWithPath: $0) }, folder: folder)
    let rows = FileTools.results(for: CommandLine.arguments[flag + 1]) ?? []
    for item in rows {
        print("\(item.needsConfirm ? "!" : " ") \(item.title)  [\(item.subtitle)]")
    }
    if ProcessInfo.processInfo.environment["BEELINE_FILES_TEST"] != nil, let first = rows.first {
        guard !first.needsConfirm else {
            print("not run: this chore needs confirming in the bar")
            exit(0)
        }
        FileTools.exitWhenDone = true
        first.run()
        RunLoop.main.run(until: Date().addingTimeInterval(600))
        print("gave up waiting")
    }
    exit(0)
}

if let flag = CommandLine.arguments.firstIndex(of: "--pick"), CommandLine.arguments.count > flag + 2 {
    let catalogue = Catalogue()
    if let item = catalogue.search(CommandLine.arguments[flag + 2], limit: 1).first {
        catalogue.recordUse(of: item, query: CommandLine.arguments[flag + 1])
        catalogue.flushHistory()
        print("recorded \(item.title) for \"\(CommandLine.arguments[flag + 1])\"")
    }
    exit(0)
}

if let flag = CommandLine.arguments.firstIndex(of: "--ai"), CommandLine.arguments.count > flag + 1 {
    let catalogue = Catalogue()
    catalogue.prepareMeaningNow()
    let requests = Array(CommandLine.arguments[(flag + 1)...])
    Task {
        Chooser.prewarm()
        for request in requests {
            let start = Date()
            let picks = await catalogue.choose(request)
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            print("\(ms) ms  \(request) -> \(picks.isEmpty ? "none" : picks.map { "\($0.title) [\($0.subtitle)]" }.joined(separator: " | "))")
        }
        exit(0)
    }
    dispatchMain()
}

if let flag = CommandLine.arguments.firstIndex(of: "--plan"), CommandLine.arguments.count > flag + 1 {
    let catalogue = Catalogue()
    let request = CommandLine.arguments[flag + 1]
    Task {
        let options = catalogue.planOptions(for: request)
        let start = Date()
        let result = await Planner.plan(for: request, options: options)
        print("\(options.count) options, \(String(format: "%.1f", Date().timeIntervalSince(start))) s")
        switch result {
        case .success(let plan):
            print("note: \(plan.note)")
            for (index, step) in plan.steps.enumerated() { print("  \(index + 1). \(step.text)") }
        case .failure(.message(let message)):
            print("failed: \(message)")
        }
        exit(0)
    }
    dispatchMain()
}

if !Demo.isVoice, let bundleID = Bundle.main.bundleIdentifier {
    let me = ProcessInfo.processInfo.processIdentifier
    var others: [NSRunningApplication] = []
    for _ in 0..<50 {
        others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).filter { $0.processIdentifier != me && !$0.isTerminated }
        if others.isEmpty { break }
        Thread.sleep(forTimeInterval: 0.1)
    }
    if !others.isEmpty {
        Log.append("another copy is running, quitting")
        exit(0)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
