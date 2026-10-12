import AppKit

// `Beeline --query "wifi"` prints the ranked matches and exits, for checking the matcher without the UI.
if let flag = CommandLine.arguments.firstIndex(of: "--query"), CommandLine.arguments.count > flag + 1 {
    let catalogue = Catalogue()
    catalogue.prepareMeaningNow()
    for item in catalogue.search(CommandLine.arguments[flag + 1]) {
        print("\(item.isGuess ? "~ " : "  ")\(item.verb) \(item.title)  [\(item.subtitle)]")
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

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
