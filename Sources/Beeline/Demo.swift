import AppKit
import ApplicationServices

enum Demo {
    static let scenarios = ["press", "plan", "escape", "click", "welcome", "release"]

    static var requested: String? {
        guard let name = ProcessInfo.processInfo.environment["BEELINE_DEMO"], scenarios.contains(name) else { return nil }
        return name
    }

    static func rulerMoved(from before: CGFloat, to after: CGFloat) -> Bool {
        abs(after - before) >= 12
    }

    static func start(_ scenario: String, bar: BarController, welcome: WelcomeWindowController) {
        let path = ProcessInfo.processInfo.environment["BEELINE_DEMO_LOG"]
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("beeline-live-check.jsonl").path
        DemoLog.shared = DemoLog(path: path)
        Bee.pace = 3
        Bee.forceOn = true
        DemoLog.note("start", ["scenario": scenario])
        Task { @MainActor in
            let runner = Runner(bar: bar)
            var (pass, why) = await runner.run(scenario, welcome: welcome)
            if await !runner.cleanUp() {
                pass = false
                why += "; the TextEdit document was left open (close it without saving)"
            }
            DemoLog.note("result", ["scenario": scenario, "pass": pass, "why": why])
            try? await Task.sleep(nanoseconds: 300_000_000)
            NSApp.terminate(nil)
        }
    }

    @MainActor
    private final class Runner {
        let bar: BarController
        var textTopAtStart: CGFloat?
        var textEdit: NSRunningApplication?
        var document: URL?
        var name = ""
        var window: AXUIElement?

        init(bar: BarController) {
            self.bar = bar
        }

        func run(_ scenario: String, welcome: WelcomeWindowController) async -> (Bool, String) {
            if scenario == "welcome" {
                Settings.forceSpotlightCard = true
                welcome.show()
                await shot("welcome-card")
                let shown = welcome.isShowing, card = welcome.showsSpotlightCard
                welcome.close()
                return shown && card ? (true, "the welcome window opened with the Spotlight card")
                    : (false, shown ? "the welcome window opened without the Spotlight card" : "the welcome window didn't open")
            }
            guard Accessibility.isTrusted else { return (false, "Accessibility is off for this copy of Beeline") }
            guard await openDocument() else { return (false, "couldn't open a TextEdit document to work in") }
            switch scenario {
            case "press": return await press()
            case "release": return await release()
            case "plan": return await plan(interrupt: nil)
            case "escape": return await plan(interrupt: .escape)
            default: return await plan(interrupt: .takeover)
            }
        }

        private func press() async -> (Bool, String) {
            guard let ruler = rulerCommand() else { return (false, "TextEdit has no Show Ruler or Hide Ruler command") }
            let before = ruler.title
            let topBefore = textTop()
            bar.show()
            bar.model.query = before.lowercased()
            var row: Int?
            for _ in 0..<40 {
                row = bar.model.results.firstIndex { $0.kind == .menu && $0.title == before && $0.id.hasPrefix("menu:\(textEdit!.processIdentifier):") }
                if row != nil { break }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            guard let row else { return (false, "“\(before)” didn't come up in the bar") }
            let found = bar.model.results[row]
            DemoLog.note("target-found", ["title": before, "row": row])
            bar.model.selected = row
            await shot("bar-result")
            guard isOurs() else { return (false, "the TextEdit document wasn't in front, so nothing was pressed") }
            guard let current = bar.model.results.first(where: { $0.id == found.id }) else {
                return (false, "“\(before)” left the bar before it could be pressed")
            }
            bar.model.run(current)
            await waitFor { (DemoLog.shared?.count("pressed") ?? 0) > 0 || (DemoLog.shared?.count("stopped") ?? 0) > 0 }
            try? await Task.sleep(nanoseconds: 800_000_000)
            await shot("after-press")
            let flew = DemoLog.shared?.count("bee-landed") == 1
            let pressed = DemoLog.shared?.count("pressed") == 1
            let flipped = rulerToggled(since: topBefore)
            DemoLog.note("verified", ["command": before, "textTopBefore": topBefore.map(Double.init) ?? -1,
                                      "textTopAfter": textTop().map(Double.init) ?? -1, "flew": flew, "pressed": pressed, "rulerToggled": flipped])
            return flew && pressed && flipped ? (true, "the bee flew to the menu, then “\(before)” was pressed and the ruler toggled")
                : (false, "flew \(flew), pressed \(pressed), ruler toggled \(flipped)")
        }

        private func release() async -> (Bool, String) {
            guard Settings.isOn(Settings.actOnRelease), Settings.isOn(Settings.holdToTalk) else {
                return (false, "“Act when you let go” or hold-to-talk is off in Settings")
            }
            bar.show()
            try? await Task.sleep(nanoseconds: 500_000_000)
            bar.model.query = "TextEdit"
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard isOurs() else { return (false, "the TextEdit document wasn't in front, so nothing was tried") }

            bar.heard("TextEdit")
            guard DemoLog.shared?.count("auto-act") == 1 else {
                let top = bar.model.results.first.map { "\($0.verb) \($0.title)" } ?? "nothing"
                return (false, "letting go announced nothing; the top result was \(top)")
            }
            DemoLog.note("shot", ["name": "announced"])
            try? await Task.sleep(nanoseconds: 300_000_000)
            bar.cancelPendingAct()
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            let stopped = DemoLog.shared?.count("pressed") == 0 && DemoLog.shared?.count("auto-act-cancelled") == 1

            bar.heard("TextEdit")
            await waitFor(seconds: 3) { (DemoLog.shared?.count("pressed") ?? 0) > 0 }
            let ran = DemoLog.shared?.last("pressed")?["title"] as? String == "TextEdit"
            DemoLog.note("verified", ["escStopped": stopped, "ranAfterBeat": ran])
            return stopped && ran ? (true, "esc stopped it in the beat; left alone, it opened TextEdit")
                : (false, "esc stopped it \(stopped), ran after the beat \(ran)")
        }

        private func plan(interrupt: RunGuard.Reason?) async -> (Bool, String) {
            guard let ruler = rulerCommand() else { return (false, "TextEdit's ruler command wasn't found") }
            let zoom = menuCommand("Zoom In")
            if interrupt == nil, zoom == nil { return (false, "TextEdit's Zoom In command wasn't found") }
            let topBefore = textTop()
            let steps = ([ruler] + (zoom.map { [$0] } ?? [])).map { item -> PlanStep in
                var step = PlanStep(text: "In the current app only, run its menu command \(item.subtitle) › \(item.title)", icon: item.icon, run: item.run)
                step.stillValid = item.stillValid
                step.target = item.target
                return step
            }
            bar.show()
            try? await Task.sleep(nanoseconds: 500_000_000)
            bar.model.query = "show the ruler and zoom in"
            try? await Task.sleep(nanoseconds: 300_000_000)
            bar.model.plan = Plan(steps: steps, note: "Live check: two harmless TextEdit commands.")
            try? await Task.sleep(nanoseconds: 300_000_000)
            await shot("plan-preview")
            guard bar.model.plan != nil else { return (false, "the plan didn't stay in the bar long enough to run") }
            guard isOurs() else { return (false, "the TextEdit document wasn't in front, so nothing was run") }
            bar.model.runSelected()

            if let interrupt {
                await waitFor { (DemoLog.shared?.count("bee-takeoff") ?? 0) > 0 }
                let seconds = DemoLog.shared?.last("bee-takeoff")?["seconds"] as? Double ?? 1
                try? await Task.sleep(nanoseconds: UInt64(seconds * 0.4 * 1_000_000_000))
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
                let unchanged = !rulerToggled(since: topBefore)
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
            let flipped = rulerToggled(since: topBefore)
            DemoLog.note("verified", ["landed": landed, "pressed": pressed, "finished": finished, "rulerFlipped": flipped])
            return finished && landed == 2 && pressed == 2 && flipped
                ? (true, "the bee flew to both steps and both ran") : (false, "landed \(landed), pressed \(pressed), finished \(finished)")
        }

        private func openDocument() async -> Bool {
            name = "Beeline live check \(UUID().uuidString.prefix(6))"
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
                    textTopAtStart = textTop()
                    DemoLog.note("textedit-ready", ["window": title])
                    return true
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            return false
        }

        private func isOurs() -> Bool {
            guard let textEdit, let window else { return false }
            return Accessibility.isFrontWindow(window, of: textEdit.processIdentifier)
        }

        private func menuCommand(_ title: String) -> Item? {
            guard let textEdit, isOurs() else { return nil }
            return Accessibility.menuCommands(of: textEdit).first { $0.title == title }
        }

        /// TextEdit updates this command's title only when the menu is opened, so it can say Show Ruler with
        /// the ruler showing. Either way it toggles.
        private func rulerCommand() -> Item? {
            menuCommand("Show Ruler") ?? menuCommand("Hide Ruler")
        }

        private func textTop() -> CGFloat? {
            guard let window, let windowFrame = Accessibility.frame(of: window) else { return nil }
            var queue: [(AXUIElement, Int)] = [(window, 0)]
            var visited = 0
            while !queue.isEmpty, visited < 400 {
                let (node, depth) = queue.removeFirst()
                visited += 1
                if (Accessibility.attribute(node, kAXRoleAttribute) as String?) == kAXTextAreaRole,
                   let frame = Accessibility.frame(of: node) {
                    return frame.minY - windowFrame.minY
                }
                if depth < 8 {
                    let children: [AXUIElement] = Accessibility.attribute(node, kAXChildrenAttribute) ?? []
                    queue += children.map { ($0, depth + 1) }
                }
            }
            return nil
        }

        private func rulerToggled(since before: CGFloat?) -> Bool {
            guard let before, let now = textTop() else { return false }
            return Demo.rulerMoved(from: before, to: now)
        }

        func cleanUp() async -> Bool {
            bar.runGuard.stop(.replaced)
            guard let textEdit else {
                if let document { try? FileManager.default.removeItem(at: document) }
                return true
            }
            if window == nil {
                let windows: [AXUIElement] = Accessibility.attribute(Accessibility.applicationElement(textEdit), kAXWindowsAttribute) ?? []
                window = windows.first { (Accessibility.attribute($0, kAXTitleAttribute) as String?)?.hasPrefix(name) == true }
            }
            guard let window else {
                if let document { try? FileManager.default.removeItem(at: document) }
                return true
            }
            if let actual = menuCommand("Actual Size"), actual.stillValid?() ?? true { actual.run() }
            if rulerToggled(since: textTopAtStart), let ruler = rulerCommand(), ruler.stillValid?() ?? true { ruler.run() }
            if let close: AXUIElement = Accessibility.attribute(window, kAXCloseButtonAttribute) {
                AXUIElementPerformAction(close, kAXPressAction as CFString)
                try? await Task.sleep(nanoseconds: 600_000_000)
            }
            let open = (Accessibility.attribute(Accessibility.applicationElement(textEdit), kAXWindowsAttribute) as [AXUIElement]?)?
                .contains { CFEqual($0, window) } ?? false
            DemoLog.note("cleanup", ["documentClosed": !open])
            if !open, let document { try? FileManager.default.removeItem(at: document) }
            return !open
        }

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
