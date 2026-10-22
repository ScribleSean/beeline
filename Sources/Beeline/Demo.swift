import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Network

enum Demo {
    static let scenarios = ["press", "plan", "escape", "click", "welcome", "release", "open", "rewrite", "tab"]

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
            case "open": return await openWithShortcut()
            case "rewrite": return await rewrite()
            case "tab": return await switchTabs()
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

        private func tapShortcut(_ name: String) {
            let keys: [String: (CGEventFlags, Int)] = ["command": (.maskCommand, kVK_Command), "option": (.maskAlternate, kVK_Option),
                                                       "control": (.maskControl, kVK_Control)]
            guard let (flag, modifier) = keys[name] else { return }
            let source = CGEventSource(stateID: .hidSystemState)
            let events = [(modifier, true, flag), (kVK_Space, true, flag), (kVK_Space, false, flag), (modifier, false, CGEventFlags())]
            for (key, down, flags) in events {
                let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(key), keyDown: down)
                event?.flags = flags
                event?.post(tap: .cghidEventTap)
                usleep(30_000)
            }
        }

        private func openWithShortcut() async -> (Bool, String) {
            guard let active = Settings.activeShortcut else { return (false, "no shortcut could be registered") }
            guard isOurs(), !bar.isOpen else { return (false, "the TextEdit document wasn't in front with the bar closed") }
            let label = Settings.label(for: active)
            tapShortcut(active)
            await waitFor(seconds: 3) { self.bar.isOpen }
            try? await Task.sleep(nanoseconds: 600_000_000)
            await shot("opened")
            let opened = bar.isOpen
            tapShortcut(active)
            await waitFor(seconds: 3) { !self.bar.isOpen }
            let closed = !bar.isOpen
            DemoLog.note("verified", ["shortcut": active, "opened": opened, "closedAgain": closed])
            return opened && closed ? (true, "\(label) opened the bar, it stayed open, and \(label) again closed it")
                : (false, "\(label): opened \(opened), closed again \(closed)")
        }

        private func rewrite() async -> (Bool, String) {
            guard Settings.isOn(Settings.offerClaude) else { return (false, "“Offer Claude” is off in Settings") }
            guard let area = textArea(), let before: String = Accessibility.attribute(area, kAXValueAttribute),
                  let word = before.range(of: "temporary") else { return (false, "couldn't read the TextEdit document's text") }
            var range = CFRange(location: before.distance(from: before.startIndex, to: word.lowerBound), length: 9)
            guard let value = AXValueCreate(.cfRange, &range),
                  AXUIElementSetAttributeValue(area, kAXSelectedTextRangeAttribute as CFString, value) == .success else {
                return (false, "couldn't select a word in the TextEdit document")
            }
            let board = NSPasteboard.general
            let yours = board.pasteboardItems?.map { item in item.types.compactMap { type in item.data(forType: type).map { (type, $0) } } } ?? []
            defer {
                board.clearContents()
                board.writeObjects(yours.map { pairs in
                    let item = NSPasteboardItem()
                    for (type, data) in pairs { item.setData(data, forType: type) }
                    return item
                })
            }
            let sentinel = "Beeline live check clipboard \(UUID().uuidString.prefix(6))"
            board.clearContents()
            board.setString(sentinel, forType: .string)

            bar.show()
            await waitFor(seconds: 3) { Rewrite.selection?.text == "temporary" }
            guard Rewrite.selection?.text == "temporary" else { return (false, "the bar didn't pick up the selected word") }
            bar.model.query = "make this all capitals"
            await waitFor(seconds: 3) { self.bar.model.results.first?.id == BarModel.rewriteRowID }
            guard let row = bar.model.results.first, row.id == BarModel.rewriteRowID else {
                return (false, "the bar didn't offer “Rewrite the selected text” first")
            }
            await shot("rewrite-offered")
            bar.model.run(row)
            await waitFor(seconds: 40) { self.bar.model.rewritten != nil || self.bar.model.planProblem != nil }
            guard let rewritten = bar.model.rewritten else {
                return (false, "Claude didn't rewrite it: \(bar.model.planProblem ?? "no answer in 40 seconds")")
            }
            await shot("rewrite-preview")
            guard isOurs() else { return (false, "the TextEdit document wasn't in front, so nothing was pasted") }
            bar.model.runSelected()
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await shot("rewritten")
            let after: String = Accessibility.attribute(area, kAXValueAttribute) ?? ""
            let replaced = after.contains("This document is \(rewritten);") && !after.contains("temporary")
            let restored = board.string(forType: .string) == sentinel
            DemoLog.note("verified", ["rewritten": rewritten, "replaced": replaced, "clipboardRestored": restored])
            return replaced && restored ? (true, "Claude's “\(rewritten)” replaced the selected word and the clipboard came back")
                : (false, "got “\(rewritten.prefix(40))”, replaced in place \(replaced), clipboard restored \(restored)")
        }

        private var safariWindow: Int?

        private func safari(_ script: String) -> String? {
            Browser.osascript("tell application \"Safari\"\n\(script)\nend tell", timeout: 20)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        private func switchTabs() async -> (Bool, String) {
            guard NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == "com.apple.Safari" }) else {
                return (false, "Safari isn't open; the check only adds a window to a running Safari")
            }
            let titles = ["A", "B"].map { "Beeline live check tab \($0) \(name.suffix(6))" }
            // Served over loopback http: Safari refuses file:// pages opened by AppleScript while its
            // local file restrictions are on, which is the default.
            let server = PageServer(pages: ["/a": titles[0], "/b": titles[1]].mapValues {
                "<!doctype html><title>\($0)</title><p>Temporary page for Beeline's live check.</p>"
            })
            guard let port = await server.start() else { return (false, "couldn't start the local server for the test pages") }
            defer { server.stop() }
            let pages = ["/a", "/b"].map { "http://127.0.0.1:\(port)\($0)" }
            guard let id = safari("""
                make new document with properties {URL:\(Browser.quoted(pages[0]))}
                set w to front window
                tell w to set current tab to (make new tab with properties {URL:\(Browser.quoted(pages[1]))})
                return id of w
                """).flatMap(Int.init) else {
                return (false, "couldn't open a Safari window (is Automation for Safari allowed for Beeline?)")
            }
            safariWindow = id
            let current = { self.safari("return name of current tab of window id \(id)") ?? "" }
            await waitFor(seconds: 8) { current() == titles[1] && self.safari("return name of tab 1 of window id \(id)") == titles[0] }
            guard current() == titles[1] else { return (false, "the test pages didn't load in Safari") }

            bar.show()
            bar.model.query = titles[0]
            await waitFor(seconds: 10) { self.bar.model.results.contains { $0.kind == .tab && $0.title == titles[0] } }
            guard let row = bar.model.results.first(where: { $0.kind == .tab && $0.title == titles[0] }) else {
                return (false, "the tab “\(titles[0])” didn't come up in the bar")
            }
            await shot("tab-found")
            bar.model.run(row)
            await waitFor(seconds: 5) { current() == titles[0] }
            let switched = current() == titles[0]
            await shot("switched")

            let other = bar.model.catalogue.search(titles[1]).first { $0.kind == .tab && $0.title == titles[1] }
            other?.close?()
            await waitFor(seconds: 5) { self.safari("return count of tabs of window id \(id)") == "1" }
            let closed = safari("return count of tabs of window id \(id)") == "1" && current() == titles[0]
            DemoLog.note("verified", ["switched": switched, "closedOne": closed])
            return switched && closed ? (true, "typing a tab's title switched to it, and closing the other tab closed only that one")
                : (false, "switched \(switched), closed only the other tab \(closed)")
        }

        private func textArea() -> AXUIElement? {
            guard let window else { return nil }
            var queue: [(AXUIElement, Int)] = [(window, 0)]
            var visited = 0
            while !queue.isEmpty, visited < 400 {
                let (node, depth) = queue.removeFirst()
                visited += 1
                if (Accessibility.attribute(node, kAXRoleAttribute) as String?) == kAXTextAreaRole { return node }
                if depth < 8 {
                    let children: [AXUIElement] = Accessibility.attribute(node, kAXChildrenAttribute) ?? []
                    queue += children.map { ($0, depth + 1) }
                }
            }
            return nil
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
            guard let window, let windowFrame = Accessibility.frame(of: window), let area = textArea(),
                  let frame = Accessibility.frame(of: area) else { return nil }
            return frame.minY - windowFrame.minY
        }

        private func rulerToggled(since before: CGFloat?) -> Bool {
            guard let before, let now = textTop() else { return false }
            return Demo.rulerMoved(from: before, to: now)
        }

        func cleanUp() async -> Bool {
            bar.runGuard.stop(.replaced)
            if let safariWindow {
                _ = safari("close window id \(safariWindow)")
                DemoLog.note("cleanup", ["safariWindowClosed": safari("return exists window id \(safariWindow)") == "false"])
            }
            for _ in 0..<5 {
                guard let textEdit, isOurs(), let undo = Accessibility.menuCommands(of: textEdit).first(where: { $0.title.hasPrefix("Undo") }),
                      undo.stillValid?() ?? true else { break }
                undo.run()
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
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

/// A tiny http server on 127.0.0.1 for the live check's test pages. It answers each GET with the page for
/// its path (or 404) and closes the connection.
private final class PageServer: @unchecked Sendable {
    private let pages: [String: String]
    private let queue = DispatchQueue(label: "beeline.live-check.pages")
    private var listener: NWListener?
    private var answered = false  // touched only on `queue`

    init(pages: [String: String]) { self.pages = pages }

    func start() async -> UInt16? {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        guard let listener = try? NWListener(using: parameters) else { return nil }
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
        return await withCheckedContinuation { continuation in
            listener.stateUpdateHandler = { [self] state in
                guard !answered else { return }
                switch state {
                case .ready: answered = true; continuation.resume(returning: listener.port?.rawValue)
                case .failed, .cancelled: answered = true; continuation.resume(returning: nil)
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() { listener?.cancel() }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [pages] data, _, _, _ in
            let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let parts = request.split(separator: "\r\n", maxSplits: 1).first?.split(separator: " ") ?? []
            let path = parts.count > 1 ? String(parts[1]) : ""
            let page = pages[path]
            let body = Data((page ?? "Not found").utf8)
            let head = "HTTP/1.1 \(page == nil ? "404 Not Found" : "200 OK")\r\nContent-Type: text/html; charset=utf-8\r\n"
                + "Content-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
            connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}
