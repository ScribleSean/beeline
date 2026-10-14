import AppKit

Settings.registerDefaults()

// `Beeline --query "wifi"` prints the ranked matches and exits, for checking the matcher without the UI.
if let flag = CommandLine.arguments.firstIndex(of: "--query"), CommandLine.arguments.count > flag + 1 {
    let catalogue = Catalogue()
    catalogue.prepareMeaningNow()
    catalogue.loadFilesNow(for: CommandLine.arguments[flag + 1])
    for item in catalogue.search(CommandLine.arguments[flag + 1]) {
        print("\(item.isGuess ? "~ " : "  ")\(item.verb) \(item.title)  [\(item.subtitle)]")
    }
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

// `Beeline --pick "tunes" "Music"` records that Music was chosen for "tunes", as pressing Return would.
if let flag = CommandLine.arguments.firstIndex(of: "--pick"), CommandLine.arguments.count > flag + 2 {
    let catalogue = Catalogue()
    if let item = catalogue.search(CommandLine.arguments[flag + 2], limit: 1).first {
        catalogue.recordUse(of: item, query: CommandLine.arguments[flag + 1])
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
