import AppKit
import ApplicationServices
import SwiftUI
import Testing
@testable import Beeline

private func row(_ id: String, verb: String = "Open", subtitle: String = "Apps", confirm: Bool = false) -> Item {
    var item = Item(id: id, kind: .app, verb: verb, title: id, subtitle: subtitle, keywords: "", icon: nil, run: {})
    item.needsConfirm = confirm
    return item
}

/// Swaps the announcer for a recorder while `body` runs.
@MainActor private func spoken(_ body: () -> Void) -> [String] {
    var heard: [String] = []
    let real = Announce.post
    Announce.post = { text, _ in heard.append(text) }
    defer { Announce.post = real }
    body()
    return heard
}

@Test func rowLabelReadsLikeTheRow() {
    var alias = row("Safari")
    alias.source = .alias
    #expect(Announce.row(alias) == "Open Safari, Apps, your alias")
    var guess = row("Notes", verb: "", subtitle: "")
    guess.isGuess = true
    #expect(Announce.row(guess) == "Notes, best guess")
}

@Test @MainActor func movingTheSelectionSpeaksTheNewRow() {
    let model = sharedModel
    let heard = spoken {
        model.armedID = nil
        model.results = [row("Safari"), row("Notes")]
        model.selected = 0
        model.move(1)
    }
    #expect(heard.last == "Open Notes, Apps")
}

@Test @MainActor func armingSpeaksTheQuestion() {
    let model = sharedModel
    var trash = row("Close Tabs", verb: "", subtitle: "Action", confirm: true)
    trash.confirmNote = "3 tabs will close."
    let heard = spoken {
        model.results = [trash]
        model.selected = 0
        model.runSelected()
    }
    model.armedID = nil
    #expect(heard.last == "Close Tabs? 3 tabs will close.")
}

@Test @MainActor func aReadyPlanIsSpoken() {
    let model = sharedModel
    let plan = Plan(steps: [PlanStep(text: "Turn Wi-Fi Off", icon: nil, run: {}),
                            PlanStep(text: "Open \\\"Notes\\\"", icon: nil, run: {})], note: "")
    let heard = spoken { model.plan = plan }
    model.clearPlan()
    #expect(heard.last == "2 steps: Turn Wi-Fi Off. Open \"Notes\".")
}

@Test @MainActor func claudesAnswerAndProblemsAreSpoken() {
    let model = sharedModel
    let heard = spoken {
        model.claudeAnswer = "About 384,400 km."
        model.planProblem = "Claude is not signed in."
    }
    model.clearPlan()
    #expect(heard == ["About 384,400 km.", "Claude is not signed in."])
}

@Test @MainActor func theBeeSaysWhatItIsDoing() {
    let bee = BeeModel()
    let heard = spoken {
        bee.show("Close Flights to Lisbon – Goo…", speaking: "Close Flights to Lisbon – Google Flights")
        bee.show("Stopped")
        bee.show("Stopped")
    }
    #expect(bee.label == "Stopped")
    #expect(heard == ["Close Flights to Lisbon – Google Flights", "Stopped", "Stopped"])
}

@Test func barIsSolidWithIncreaseContrastOrReduceTransparency() {
    #expect(BarSurface.isSolid(increaseContrast: false, reduceTransparency: false) == false)
    #expect(BarSurface.isSolid(increaseContrast: true, reduceTransparency: false))
    #expect(BarSurface.isSolid(increaseContrast: false, reduceTransparency: true))
}

/// What an assistive app reads: SwiftUI builds its accessibility tree only for a real AX client, so this asks
/// through the AX API from another thread while the main run loop answers, as VoiceOver would.
@MainActor private func labels(in view: some View) -> [String] {
    NSApplication.shared.setActivationPolicy(.accessory)
    NSApplication.shared.finishLaunching()
    let host = NSHostingView(rootView: view)
    host.frame = NSRect(x: 0, y: 0, width: 720, height: 460)
    let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
    let title = UUID().uuidString
    window.title = title
    window.contentView = host
    window.orderFrontRegardless()
    defer { window.orderOut(nil) }
    // Let SwiftUI draw the window before asking for its tree.
    host.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.15))
    let box = Box()
    Thread.detachNewThread {
        var found: [String] = []
        func value(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
            var value: CFTypeRef?
            AXUIElementCopyAttributeValue(element, name as CFString, &value)
            return value
        }
        func walk(_ element: AXUIElement, depth: Int) {
            guard depth < 30 else { return }
            AXUIElementSetMessagingTimeout(element, 2)
            if let label = value(element, kAXDescriptionAttribute) as? String, !label.isEmpty { found.append(label) }
            for child in (value(element, kAXChildrenAttribute) as? [AXUIElement]) ?? [] { walk(child, depth: depth + 1) }
        }
        let app = AXUIElementCreateApplication(getpid())
        AXUIElementSetMessagingTimeout(app, 2)
        for window in (value(app, kAXChildrenAttribute) as? [AXUIElement]) ?? []
        where value(window, kAXTitleAttribute) as? String == title { walk(window, depth: 0) }
        box.finish(found)
    }
    let end = Date().addingTimeInterval(8)
    while box.result == nil, Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    return box.result ?? []
}

/// Handed over once, under a lock, when the reading thread is done.
private final class Box: @unchecked Sendable {
    private let lock = NSLock()
    private var found: [String]?
    func finish(_ labels: [String]) { lock.withLock { found = labels } }
    var result: [String]? { lock.withLock { found } }
}

// Reading the tree needs this process to be trusted for Accessibility, as Beeline itself is.
@Test(.enabled(if: AXIsProcessTrusted())) @MainActor func hostedRowsAndConfirmCardCarryLabels() {
    var alias = row("Safari")
    alias.source = .alias
    let rows = labels(in: VStack {
        ResultRow(item: alias, isSelected: true, isArmed: false)
        ResultRow(item: row("Notes"), isSelected: false, isArmed: false)
    })
    #expect(rows == ["Open Safari, Apps, your alias", "Open Notes, Apps"])

    var close = row("Close Tabs", verb: "", subtitle: "Action", confirm: true)
    close.confirmNote = "3 tabs will close."
    let card = labels(in: ConfirmCard(item: close, confirm: {}, cancel: {}))
    #expect(card == ["Cancel", "Close Tabs"])
}

@Test @MainActor func aClosedBarStaysQuiet() {
    let model = sharedModel
    model.armedID = nil
    model.results = [row("Mail"), row("Maps")]
    model.selected = 0
    model.isOpen = false
    let heard = spoken {
        model.move(1)
        model.planProblem = "Stopped."
    }
    model.isOpen = true
    model.clearPlan()
    #expect(heard.isEmpty)
}

@Test @MainActor func typingSpeaksTheTopHitOnceItPauses() {
    let model = BarModel()
    model.catalogue.includeFiles = false
    sharedModel.isOpen = false
    defer { sharedModel.isOpen = true }
    var heard: [String] = []
    let real = Announce.post
    Announce.post = { text, _ in heard.append(text) }
    defer { Announce.post = real }
    model.query = "s"
    model.query = "sa"
    model.query = "saf"
    #expect(heard.isEmpty)
    RunLoop.main.run(until: Date().addingTimeInterval(0.6))
    #expect(heard == model.results.prefix(1).map { Announce.spoken($0) })
    model.isOpen = false
}

@Test func copiedAndSelectedTextIsNotReadOutUnasked() {
    let clip = Item(id: "clip:0:1", kind: .clipboard, verb: "Paste", title: "hunter2", subtitle: "Passwords · now",
                    keywords: "", icon: nil, run: {})
    #expect(Announce.spoken(clip) == "Paste clipboard item 1, Passwords · now")
    #expect(Announce.row(clip).contains("hunter2"))
    let rewrite = Item(id: BarModel.rewriteRowID, kind: .action, verb: "", title: "Rewrite the selected text",
                       subtitle: "“my private note”", keywords: "", icon: nil, run: {})
    #expect(Announce.spoken(rewrite) == "Rewrite the selected text")
}

@Test @MainActor func cancellingTheConfirmCardSpeaksTheRowAgain() {
    let model = sharedModel
    var close = row("Close Tabs", verb: "", subtitle: "Action", confirm: true)
    close.confirmNote = "3 tabs will close."
    var heard: [String] = []
    let real = Announce.post
    Announce.post = { text, _ in heard.append(text) }
    defer { Announce.post = real }
    model.isOpen = true
    model.results = [close]
    model.selected = 0
    model.speakSelection()
    model.runSelected()
    model.armedID = nil
    RunLoop.main.run(until: Date().addingTimeInterval(0.6))
    #expect(heard == ["Close Tabs, Action", "Close Tabs? 3 tabs will close.", "Close Tabs, Action"])
}

@Test @MainActor func twoClipboardRowsFromOneAppSoundDifferent() {
    let model = sharedModel
    let clip = { (id: String, text: String) in
        Item(id: id, kind: .clipboard, verb: "Paste", title: text, subtitle: "Notes · now", keywords: "", icon: nil, run: {})
    }
    let heard = spoken {
        model.isOpen = true
        model.armedID = nil
        model.results = [clip("clip:0", "first secret"), clip("clip:1", "second secret")]
        model.selected = 0
        model.speakSelection()
        model.move(1)
    }
    #expect(heard == ["Paste clipboard item 1, Notes · now", "Paste clipboard item 2, Notes · now"])
}
