import AppKit
import ApplicationServices

/// The hands-free live check. Started only when Beeline is launched with BEELINE_DEMO set to a scenario
/// name, which nothing does in normal use; scripts/live-check.sh is what sets it. Each scenario works in a
/// throwaway TextEdit document it opens itself, presses only harmless TextEdit menu commands (the ruler and
/// zoom), checks before every action that its own document is still the front window, and gives up
/// otherwise. What happened goes to the JSON log (see DemoLog), ending with a "result" line.
enum Demo {
    static let scenarios = ["press", "plan", "escape", "click", "welcome"]

    /// The scenario asked for, or nil in normal use.
    static var requested: String? {
        guard let name = ProcessInfo.processInfo.environment["BEELINE_DEMO"], scenarios.contains(name) else { return nil }
        return name
    }

    static func start(_ scenario: String, bar: BarController, welcome: WelcomeWindowController) {
        let path = ProcessInfo.processInfo.environment["BEELINE_DEMO_LOG"]
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("beeline-live-check.jsonl").path
        DemoLog.shared = DemoLog(path: path)
        // Slow enough that a screenshot taken a moment after takeoff still finds the bee in the air.
        Bee.pace = 3
        UserDefaults.standard.set(true, forKey: Settings.showBee)
        DemoLog.note("start", ["scenario": scenario])
        Task { @MainActor in
            let runner = Runner(bar: bar)
            let (pass, why) = await runner.run(scenario, welcome: welcome)
            await runner.cleanUp()
            DemoLog.note("result", ["scenario": scenario, "pass": pass, "why": why])
            try? await Task.sleep(nanoseconds: 300_000_000)
            NSApp.terminate(nil)
        }
    }

    @MainActor
    private final class Runner {
        let bar: BarController
        var textEdit: NSRunningApplication?
        var document: URL?
        var window: AXUIElement?

        init(bar: BarController) {
            self.bar = bar
        }

        func run(_ scenario: String, welcome: WelcomeWindowController) async -> (Bool, String) {
            if scenario == "welcome" {
                Settings.forceSpotlightCard = true
                welcome.show()
                await shot("welcome-card")
                let shown = welcome.isShowing
                welcome.close()
                return shown ? (true, "the welcome window opened with the Spotlight card") : (false, "the welcome window didn't open")
            }
            guard Accessibility.isTrusted else { return (false, "Accessibility is off for this copy of Beeline") }
            guard await openDocument() else { return (false, "couldn't open a TextEdit document to work in") }
            switch scenario {
            case "press": return await press()
            case "plan": return await plan(interrupt: nil)
            case "escape": return await plan(interrupt: .escape)
            default: return await plan(interrupt: .takeover)
            }
        }

        // MARK: Scenarios

        /// Types a request in the bar and presses Return on TextEdit's ruler command: the bee flies to the
        /// Format menu, rings it, and the ruler shows (or hides).
        private func press() async -> (Bool, String) {
            guard let ruler = rulerCommand() else { return (false, "TextEdit has no Show Ruler or Hide Ruler command") }
            let before = ruler.title
            bar.show()
            bar.model.query = before.lowercased()
            // The bar reads the front app's menus a moment after it opens.
            var row: Int?
            for _ in 0..<40 {
                row = bar.model.results.firstIndex { $0.kind == .menu && $0.title == before && $0.id.hasPrefix("menu:\(textEdit!.processIdentifier):") }
                if row != nil { break }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            guard let row else { return (false, "“\(before)” didn't come up in the bar") }
            DemoLog.note("target-found", ["title": before, "row": row])
            bar.model.selected = row
            await shot("bar-result")
            guard isOurs() else { return (false, "the TextEdit document wasn't in front, so nothing was pressed") }
            bar.model.runSelected()
            await waitFor { (DemoLog.shared?.count("pressed") ?? 0) > 0 || (DemoLog.shared?.count("stopped") ?? 0) > 0 }
            try? await Task.sleep(nanoseconds: 800_000_000)
            await shot("after-press")
            let after = rulerCommand()?.title
            let flew = DemoLog.shared?.count("bee-landed") == 1
            let pressed = DemoLog.shared?.count("pressed") == 1
            let flipped = after != nil && after != before
            DemoLog.note("verified", ["before": before, "after": after ?? "missing", "flew": flew, "pressed": pressed])
            return flew && pressed && flipped ? (true, "the bee flew to the menu, then “\(before)” was pressed")
                : (false, "flew \(flew), pressed \(pressed), menu now “\(after ?? "missing")”")
        }

        /// A two-step plan: toggle the ruler, then zoom in. With `interrupt`, a stop arrives while the bee is
        /// on its way to the first step, and nothing may be pressed.
        private func plan(interrupt: RunGuard.Reason?) async -> (Bool, String) {
            guard let ruler = rulerCommand() else { return (false, "TextEdit's ruler command wasn't found") }
            // The stop checks need only the first step; the plan check needs both.
            let zoom = menuCommand("Zoom In")
            if interrupt == nil, zoom == nil { return (false, "TextEdit's Zoom In command wasn't found") }
            let before = ruler.title
            let steps = ([ruler] + (zoom.map { [$0] } ?? [])).map { item -> PlanStep in
                var step = PlanStep(text: "In the current app only, run its menu command \(item.subtitle) › \(item.title)", icon: item.icon, run: item.run)
                step.stillValid = item.stillValid
                step.target = item.target
                return step
            }
            bar.show()
            bar.model.plan = Plan(steps: steps, note: "Live check: two harmless TextEdit commands.")
            await shot("plan-preview")
            guard isOurs() else { return (false, "the TextEdit document wasn't in front, so nothing was run") }
            bar.model.runSelected()

            if let interrupt {
                await waitFor { (DemoLog.shared?.count("bee-takeoff") ?? 0) > 0 }
                let seconds = DemoLog.shared?.last("bee-takeoff")?["seconds"] as? Double ?? 1
                try? await Task.sleep(nanoseconds: UInt64(seconds * 0.4 * 1_000_000_000))
                // The same event the watch would see from another app, handed to the same code.
                let event: NSEvent?
                if interrupt == .escape {
                    event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                             context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                                             isARepeat: false, keyCode: 53)
                } else {
                    event = NSEvent.mouseEvent(with: .leftMouseDown, location: NSEvent.mouseLocation, modifierFlags: [], timestamp: 0,
                                               windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
                }
                DemoLog.note("interrupt", ["as": interrupt == .escape ? "escape" : "click"])
                if let event { bar.runGuard.handle(event) }
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                await shot("after-stop")
                let reason = DemoLog.shared?.last("stopped")?["reason"] as? String
                let pressed = DemoLog.shared?.count("pressed") ?? 0
                let unchanged = rulerCommand()?.title == before
                let expected = interrupt == .escape ? "escape" : "takeover"
                DemoLog.note("verified", ["stoppedBy": reason ?? "nothing", "pressed": pressed, "rulerUnchanged": unchanged])
                return reason == expected && pressed == 0 && unchanged
                    ? (true, "stopped by \(expected) in flight; nothing was pressed")
                    : (false, "stopped by \(reason ?? "nothing"), \(pressed) pressed, ruler unchanged \(unchanged)")
            }

            await waitFor(seconds: 20) {
                (DemoLog.shared?.count("plan-finished") ?? 0) > 0 || (DemoLog.shared?.count("plan-stopped") ?? 0) > 0
                    || (DemoLog.shared?.count("stopped") ?? 0) > 0
            }
            try? await Task.sleep(nanoseconds: 800_000_000)
            await shot("after-plan")
            let landed = DemoLog.shared?.count("bee-landed") ?? 0
            let pressed = DemoLog.shared?.count("pressed") ?? 0
            let finished = DemoLog.shared?.count("plan-finished") == 1
            let flipped = rulerCommand()?.title != before
            DemoLog.note("verified", ["landed": landed, "pressed": pressed, "finished": finished, "rulerFlipped": flipped])
            return finished && landed == 2 && pressed == 2 && flipped
                ? (true, "the bee flew to both steps and both ran") : (false, "landed \(landed), pressed \(pressed), finished \(finished)")
        }

        // MARK: The throwaway document

        /// Opens a new rich-text document in TextEdit and waits until it is the front window.
        private func openDocument() async -> Bool {
            let name = "Beeline live check \(UUID().uuidString.prefix(6))"
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(name + ".rtf")
            let text = NSAttributedString(string: "Beeline live check. This document is temporary; Beeline closes it when the check ends.\n")
            guard let data = try? text.data(from: NSRange(location: 0, length: text.length),
                                            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]),
                  (try? data.write(to: url)) != nil else { return false }
            document = url
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            let app = try? await NSWorkspace.shared.open([url], withApplicationAt: URL(fileURLWithPath: "/System/Applications/TextEdit.app"),
                                                         configuration: configuration)
            guard let app else { return false }
            textEdit = app
            for _ in 0..<80 {
                let element = Accessibility.applicationElement(app)
                if NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier,
                   let focused: AXUIElement = Accessibility.attribute(element, kAXFocusedWindowAttribute),
                   let title: String = Accessibility.attribute(focused, kAXTitleAttribute), title.hasPrefix(name) {
                    window = focused
                    DemoLog.note("textedit-ready", ["window": title])
                    return true
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            return false
        }

        /// True only while TextEdit is in front with this check's own document focused.
        private func isOurs() -> Bool {
            guard let textEdit, let window else { return false }
            return Accessibility.isFrontWindow(window, of: textEdit.processIdentifier)
        }

        private func menuCommand(_ title: String) -> Item? {
            guard let textEdit, isOurs() else { return nil }
            return Accessibility.menuCommands(of: textEdit).first { $0.title == title }
        }

        private func rulerCommand() -> Item? {
            menuCommand("Show Ruler") ?? menuCommand("Hide Ruler")
        }

        /// Puts the ruler and zoom back, closes the document and deletes its file. Leaves alone anything it
        /// can't be sure is its own.
        func cleanUp() async {
            bar.runGuard.stop(.replaced)
            if let actual = menuCommand("Actual Size"), actual.stillValid?() ?? true { actual.run() }
            if let textEdit, let window, isOurs(),
               let close: AXUIElement = Accessibility.attribute(window, kAXCloseButtonAttribute) {
                AXUIElementPerformAction(close, kAXPressAction as CFString)
                try? await Task.sleep(nanoseconds: 600_000_000)
                let still = (Accessibility.attribute(Accessibility.applicationElement(textEdit), kAXWindowsAttribute) as [AXUIElement]?)?
                    .contains { CFEqual($0, window) } ?? false
                DemoLog.note("cleanup", ["documentClosed": !still])
            }
            if let document { try? FileManager.default.removeItem(at: document) }
        }

        // MARK: Helpers

        /// Marks a moment for a screenshot and holds still long enough for the script to take it.
        private func shot(_ name: String) async {
            DemoLog.note("shot", ["name": name])
            try? await Task.sleep(nanoseconds: 900_000_000)
        }

        private func waitFor(seconds: Double = 8, _ done: () -> Bool) async {
            let deadline = Date().addingTimeInterval(seconds)
            while !done(), Date() < deadline {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
    }
}
