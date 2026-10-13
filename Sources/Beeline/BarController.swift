import AppKit
import Carbon.HIToolbox
import SwiftUI

/// A borderless panel that can take typing without making Beeline the active app,
/// so the app you were in stays in front behind the bar.
private final class BarPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

final class BarController: NSObject, NSWindowDelegate {
    private let model = BarModel()
    private let size = NSSize(width: 720, height: 560)
    private var keyMonitor: Any?

    private lazy var panel: BarPanel = {
        let panel = BarPanel(contentRect: NSRect(origin: .zero, size: size),
                             styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: BarView(model: model))
        panel.delegate = self
        return panel
    }()

    override init() {
        super.init()
        model.onRun = { [weak self] item in
            self?.hide()
            item.run()
        }
        model.onRunPlan = { [weak self] plan in
            self?.hide()
            Self.execute(plan)
        }
        model.onRequestAccess = { [weak self] in
            self?.hide()
            Accessibility.requestAccess()
        }
        model.catalogue.startWatching()
        Chooser.prewarm()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.panel.isKeyWindow else { return event }
            if self.handleEditShortcut(event) { return nil }
            switch Int(event.keyCode) {
            case kVK_Escape:
                // The first Escape backs out of a plan; the second closes the bar.
                if self.model.isShowingPlan { self.model.clearPlan() } else { self.hide() }
            case kVK_DownArrow: self.model.move(1)
            case kVK_UpArrow: self.model.move(-1)
            case kVK_Return, kVK_ANSI_KeypadEnter: self.model.runSelected()
            default: return event
            }
            return nil
        }
    }

    /// Tracked separately from `panel.isVisible`, which stays true while the bar fades out.
    private var isShown = false

    /// Runs a confirmed plan one step at a time, pausing so each app can catch up before the next.
    private static func execute(_ plan: Plan) {
        var steps = plan.steps
        // Closing a tab renumbers the tabs after it, so all closes run together, highest index first.
        let closes = steps.filter { $0.closingTabIndex != nil }.sorted { ($0.closingTabIndex ?? 0) > ($1.closingTabIndex ?? 0) }
        if let first = steps.firstIndex(where: { $0.closingTabIndex != nil }) {
            steps.removeAll { $0.closingTabIndex != nil }
            steps.insert(contentsOf: closes, at: min(first, steps.count))
        }
        for (index, step) in steps.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15 + Double(index) * 0.35, execute: step.run)
        }
    }

    /// Beeline has no Edit menu, which is what normally routes ⌘C, ⌘V and the rest to a text field.
    /// This sends the same commands to the search field directly.
    private func handleEditShortcut(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers == .command || modifiers == [.command, .shift] else { return false }
        let action: Selector
        switch (event.charactersIgnoringModifiers?.lowercased(), modifiers.contains(.shift)) {
        case ("a", false): action = #selector(NSText.selectAll(_:))
        case ("c", false): action = #selector(NSText.copy(_:))
        case ("v", false): action = #selector(NSText.paste(_:))
        case ("x", false): action = #selector(NSText.cut(_:))
        case ("z", false): action = Selector(("undo:"))
        case ("z", true): action = Selector(("redo:"))
        default: return false
        }
        return NSApp.sendAction(action, to: nil, from: nil)
    }

    func toggle() {
        isShown ? hide() : show()
    }

    private func show() {
        isShown = true
        model.clearPlan()
        model.query = ""
        model.focusTick += 1
        model.catalogue.refreshRunning()
        model.catalogue.refreshTabs { [weak self] in self?.model.refresh() }
        model.catalogue.refreshScreen { [weak self] in self?.model.refresh() }
        model.needsAccess = !Accessibility.isTrusted
        Chooser.prewarm()

        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            // The bar's top edge sits about a fifth of the way down the screen.
            let top = visible.maxY - visible.height * 0.2 + 40
            panel.setFrame(NSRect(x: visible.midX - size.width / 2, y: top - size.height,
                                  width: size.width, height: size.height), display: true)
        }
        // Typing works from the first frame; only the visuals fade.
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Motion.fadeIn
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
    }

    private func hide() {
        guard isShown else { return }
        isShown = false
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Motion.fadeOut
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            // Reopened during the fade: leave it on screen.
            guard let self, !self.isShown else { return }
            self.panel.orderOut(nil)
        })
    }

    func windowDidResignKey(_ notification: Notification) {
        hide()
    }
}
