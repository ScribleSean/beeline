import AppKit
import SwiftUI

Settings.registerDefaults()

// `Beeline --query "wifi"` prints the ranked matches and exits, for checking the matcher without the UI.
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

// `Beeline --rewrite "make this shorter" "some text"` shows whether the bar would offer a rewrite, then
// prints Claude's rewrite. Replaces nothing.
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

// `Beeline --controls Safari` lists the controls Beeline would offer in that app's front window. Presses nothing.
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

// `Beeline --preview "strem" out.png [dark]` renders the bar with real results to an image, for checking
// the design without opening it. The frosted glass cannot be captured offscreen, so a backdrop stands in.
if let flag = CommandLine.arguments.firstIndex(of: "--preview"), CommandLine.arguments.count > flag + 2 {
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    let dark = CommandLine.arguments.contains("dark")
    app.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    let model = BarModel()
    model.catalogue.prepareMeaningNow()
    // File results are left out: previews end up in screenshots, and file names are private.
    model.catalogue.includeFiles = false
    model.query = CommandLine.arguments[flag + 1]
    // "arm" shows the confirm step for the top result; "plan" shows a sample Claude plan.
    if CommandLine.arguments.contains("arm") { model.runSelected() }
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
    let host = NSHostingView(rootView: BarView(model: model))
    host.frame = backdrop.bounds
    backdrop.addSubview(host)
    let window = NSWindow(contentRect: backdrop.frame, styleMask: .borderless, backing: .buffered, defer: false)
    window.appearance = app.appearance
    window.contentView = backdrop
    backdrop.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.4))
    // Focusing the field selects its text; put the cursor at the end, as it is while typing.
    if let editor = window.firstResponder as? NSTextView {
        editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    }
    let rep = backdrop.bitmapImageRepForCachingDisplay(in: backdrop.bounds)!
    backdrop.cacheDisplay(in: backdrop.bounds, to: rep)
    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: CommandLine.arguments[flag + 2]))
    exit(0)
}

// `Beeline --preview-welcome out.png` renders the welcome screen.
if let flag = CommandLine.arguments.firstIndex(of: "--preview-welcome"), CommandLine.arguments.count > flag + 1 {
    NSApplication.shared.setActivationPolicy(.prohibited)
    WelcomeWindowController.renderPreview(to: CommandLine.arguments[flag + 1])
    exit(0)
}

// `Beeline --files "compress" a.pdf b.pdf` shows the file chores offered for those files. Runs nothing.
if let flag = CommandLine.arguments.firstIndex(of: "--files"), CommandLine.arguments.count > flag + 2 {
    // A trailing folder path ending in "/" stands for the front Finder window; the rest are selected items.
    var paths = Array(CommandLine.arguments[(flag + 2)...])
    let folder = paths.last.flatMap { $0.hasSuffix("/") ? URL(fileURLWithPath: $0) : nil }
    if folder != nil { paths.removeLast() }
    FileTools.useSelection(paths.map { URL(fileURLWithPath: $0) }, folder: folder)
    let rows = FileTools.results(for: CommandLine.arguments[flag + 1]) ?? []
    for item in rows {
        print("\(item.needsConfirm ? "!" : " ") \(item.title)  [\(item.subtitle)]")
    }
    // With BEELINE_FILES_TEST set, the first chore is run too, and what it made is printed when it finishes.
    if ProcessInfo.processInfo.environment["BEELINE_FILES_TEST"] != nil, let first = rows.first {
        first.run()
        RunLoop.main.run(until: Date().addingTimeInterval(600))
        print("gave up waiting")
    }
    exit(0)
}

// `Beeline --pick "tunes" "Music"` records that Music was chosen for "tunes", as pressing Return would.
if let flag = CommandLine.arguments.firstIndex(of: "--pick"), CommandLine.arguments.count > flag + 2 {
    let catalogue = Catalogue()
    if let item = catalogue.search(CommandLine.arguments[flag + 2], limit: 1).first {
        catalogue.recordUse(of: item, query: CommandLine.arguments[flag + 1])
        catalogue.flushHistory()
        print("recorded \(item.title) for \"\(CommandLine.arguments[flag + 1])\"")
    }
    exit(0)
}

// `Beeline --ai "make my mac quieter"` asks the on-device model and prints its pick and how long it took.
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

// `Beeline --plan "mute and open sound settings"` asks Claude for a plan and prints it. Nothing is run.
if let flag = CommandLine.arguments.firstIndex(of: "--plan"), CommandLine.arguments.count > flag + 1 {
    let catalogue = Catalogue()
    let request = CommandLine.arguments[flag + 1]
    Task {
        let options = catalogue.planOptions()
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

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
