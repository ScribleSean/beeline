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
    private let size = NSSize(width: 720, height: 680)
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
                if self.model.isShowingPlan {
                    self.model.clearPlan()
                } else if self.model.armedID != nil {
                    self.model.armedID = nil
                } else {
                    self.hide()
                }
            case kVK_DownArrow: self.model.move(1)
            case kVK_UpArrow: self.model.move(-1)
            // A held Return repeats; only a fresh press counts, so "Return twice" really takes two presses.
            case kVK_Return, kVK_ANSI_KeypadEnter: if !event.isARepeat { self.model.runSelected() }
            default: return event
            }
            return nil
        }
    }

    private var isShown = false

    /// Runs a confirmed plan one step at a time, pausing so each app can catch up before the next.
    private static func execute(_ plan: Plan) {
        // Steps run in exactly the order previewed. Each waits for the one before to settle; opening an app
        // and placing its window is given a few seconds.
        var delay = 0.15
        for step in plan.steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: step.run)
            delay += step.settleTime
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

    private let voice = Voice()
    private var holdTimer: Timer?
    private var isListening = false
    /// True when this press of the shortcut opened the bar, so its release must not close it again.
    private var openedByPress = false

    /// A tap opens or closes the bar. Holding the shortcut opens it and listens until the key comes up.
    func shortcutPressed() {
        openedByPress = !isShown
        if !isShown { show() }
        holdTimer?.invalidate()
        guard Settings.isOn(Settings.holdToTalk) else { return }
        holdTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: false) { [weak self] _ in
            self?.startListening()
        }
    }

    func shortcutReleased() {
        holdTimer?.invalidate()
        holdTimer = nil
        if isListening {
            stopListening()
        } else if !openedByPress {
            hide()
        }
    }

    private func startListening() {
        isListening = true
        model.query = ""
        model.voiceNote = "Listening…"
        voice.onText = { [weak self] text in self?.model.query = text }
        voice.onState = { [weak self] state in
            guard let self else { return }
            switch state {
            case .listening: self.model.voiceNote = "Listening… let go to stop"
            case .stopped: self.model.voiceNote = nil
            case .unavailable(let reason):
                self.isListening = false
                self.model.voiceNote = reason
            }
        }
        voice.start()
    }

    private func stopListening() {
        isListening = false
        voice.stop()
        if case .some(let note) = model.voiceNote, note.hasPrefix("Listening") { model.voiceNote = nil }
    }

    func toggle() {
        isShown ? hide() : show()
    }

    private func show() {
        isShown = true
        model.clearPlan()
        model.newTip()
        model.query = ""
        model.focusTick += 1
        model.catalogue.refreshRunning()
        model.catalogue.refreshTabs { [weak self] in self?.model.refreshInBackground() }
        model.catalogue.refreshScreen { [weak self] in self?.model.refreshInBackground() }
        model.catalogue.refreshAppsIfChanged()
        Rates.shared.refreshIfStale()
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
        // Instant for now: no fade in or out. Smoothing can come back once the basics feel right.
        panel.makeKeyAndOrderFront(nil)
    }

    private func hide() {
        // Closing the bar also cancels a hold that has not started listening yet.
        holdTimer?.invalidate()
        holdTimer = nil
        if isListening { stopListening() } else { voice.stop() }
        guard isShown else { return }
        isShown = false
        panel.orderOut(nil)
    }

    func windowDidResignKey(_ notification: Notification) {
        hide()
    }
}
