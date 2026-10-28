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
    Announce.post = { heard.append($0) }
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
    #expect(heard.last == "Close Tabs? 3 tabs will close. Return to confirm, Escape to cancel.")
}

@Test @MainActor func aReadyPlanIsSpoken() {
    let model = sharedModel
    let plan = Plan(steps: [PlanStep(text: "Turn Wi-Fi Off", icon: nil, run: {}),
                            PlanStep(text: "Open \\\"Notes\\\"", icon: nil, run: {})], note: "")
    let heard = spoken { model.plan = plan }
    model.clearPlan()
    #expect(heard.last == "2 steps: Turn Wi-Fi Off. Open \"Notes\". Return to run.")
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
        bee.label = "Click Send"
        bee.label = "Click Send"
    }
    #expect(heard == ["Click Send", "Click Send"])
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
    window.contentView = host
    window.orderFrontRegardless()
    defer { window.orderOut(nil) }
    let box = Box()
    Thread.detachNewThread {
        func value(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
            var value: CFTypeRef?
            AXUIElementCopyAttributeValue(element, name as CFString, &value)
            return value
        }
        func walk(_ element: AXUIElement, depth: Int) {
            guard depth < 30 else { return }
            if let label = value(element, kAXDescriptionAttribute) as? String, !label.isEmpty { box.found.append(label) }
            for child in (value(element, kAXChildrenAttribute) as? [AXUIElement]) ?? [] { walk(child, depth: depth + 1) }
        }
        let app = AXUIElementCreateApplication(getpid())
        AXUIElementSetMessagingTimeout(app, 2)
        for window in (value(app, kAXChildrenAttribute) as? [AXUIElement]) ?? [] { walk(window, depth: 0) }
        box.done = true
    }
    let end = Date().addingTimeInterval(8)
    while !box.done, Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    return box.found
}

private final class Box: @unchecked Sendable {
    var found: [String] = []
    var done = false
}

// Reading the tree needs this process to be trusted for Accessibility, as Beeline itself is.
@Test(.enabled(if: AXIsProcessTrusted())) @MainActor func hostedRowsAndConfirmCardCarryLabels() {
    let model = BarModel()
    model.query = "sa"
    model.results = [row("Safari"), row("Notes")]
    model.selected = 0
    #expect(labels(in: BarView(model: model)).contains("Open Safari, Apps"))

    var close = row("Close Tabs", verb: "", subtitle: "Action", confirm: true)
    close.confirmNote = "3 tabs will close."
    model.results = [close]
    model.armedID = close.id
    let card = labels(in: BarView(model: model))
    #expect(card.contains("Cancel"))
    #expect(card.contains("Close Tabs"))
    #expect(!card.contains(where: { $0.contains("esc") || $0.contains("↩") }))
}
