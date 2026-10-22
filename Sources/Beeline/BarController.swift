import AppKit
import Carbon.HIToolbox
import SwiftUI

/// A borderless panel that can take typing without making Beeline the active app,
/// so the app you were in stays in front behind the bar.
private final class BarPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

final class BarController: NSObject, NSWindowDelegate {
    let model = BarModel()
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
            guard let self else { return }
            // Words still arriving from a hold must not land in a bar that has moved on.
            self.voice.cancel()
            let origin = self.beeOrigin
            self.hide()
            self.perform(item, from: origin)
        }
        model.onRunPlan = { [weak self] plan in
            guard let self else { return }
            let origin = self.beeOrigin
            self.hide()
            self.execute(plan, from: origin)
        }
        runGuard.onStop = { [weak self] reason in self?.runStopped(reason) }
        model.onRequestAccess = { [weak self] in
            self?.hide()
            Accessibility.requestAccess()
            // The system prompt shows nothing once Beeline is listed, which is the case after an unsigned
            // rebuild. The pane itself is where the fix (remove and re-add) happens.
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
        }
        model.catalogue.startWatching()
        Chooser.prewarm()
        // An action that found it could not do its job says so here, instead of failing in silence.
        NotificationCenter.default.addObserver(forName: Actions.failed, object: nil, queue: .main) { [weak self] note in
            guard let self, let message = note.userInfo?["message"] as? String else { return }
            if !self.isShown { self.show() }
            self.model.clearPlan()
            self.model.planProblem = message
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.panel.isKeyWindow else { return event }
            // While an input method is composing (Japanese, Chinese, Korean), Return and Escape belong to it.
            if let editor = self.panel.firstResponder as? NSTextView, editor.hasMarkedText() { return event }
            // ⇧⌘⌫ forgets a learned pick. Only then: otherwise the keys belong to the search field.
            if Int(event.keyCode) == kVK_Delete,
               event.modifierFlags.intersection([.command, .shift, .option, .control]) == [.command, .shift],
               self.model.forgetSelectedPick() { return nil }
            // ⇧⌘A makes the typed words an alias for the selected result.
            if Int(event.keyCode) == kVK_ANSI_A,
               event.modifierFlags.intersection([.command, .shift, .option, .control]) == [.command, .shift],
               self.model.aliasSelected() { return nil }
            if self.handleEditShortcut(event) { return nil }
            switch Int(event.keyCode) {
            case kVK_Escape:
                // The first Escape backs out of a plan; the second closes the bar. A plan still running stops.
                if self.isListening {
                    // Escape while holding ⌘Space throws the words away.
                    self.cancelListening()
                } else if self.cancelPendingAct() {
                    // Escape in the beat after letting go keeps the words but runs nothing.
                } else if self.runGuard.isRunning {
                    self.runGuard.stop(.escape)
                } else if self.model.isShowingPlan {
                    self.model.clearPlan()
                } else if self.model.armedID != nil {
                    self.model.armedID = nil
                } else {
                    self.hide()
                }
            // Choosing another row means the one announced on release is no longer wanted.
            case kVK_DownArrow: self.cancelPendingAct(); self.model.move(1)
            case kVK_UpArrow: self.cancelPendingAct(); self.model.move(-1)
            // A held Return repeats; only a fresh press counts, so "Return twice" really takes two presses.
            case kVK_Return, kVK_ANSI_KeypadEnter: if !event.isARepeat { self.model.runSelected() }
            default:
                // Typing over the words cancels a run announced on release.
                self.cancelPendingAct()
                return event
            }
            return nil
        }
    }

    private var isShown = false
    private let bee = Bee()
    /// Watches whatever is running on your behalf, so Escape or your own click stops it from any app.
    let runGuard = RunGuard()
    /// The action or plan being run. Two never run at once.
    private var runTask: Task<Void, Never>?
    /// True while the run is a plan, whose stop is reported in the bar if it is open.
    private var runIsPlan = false

    /// Where the bee sets off from: the search field's icon, while the bar is still on screen.
    private var beeOrigin: CGPoint? {
        guard isShown else { return nil }
        return CGPoint(x: panel.frame.minX + 34, y: panel.frame.maxY - 41)
    }

    /// Runs one item. Something with a place on screen gets the bee first: it flies there, rings it, and
    /// then the item runs, so you see where Beeline acts before it does. Everything else runs at once.
    private func perform(_ item: Item, from origin: CGPoint?) {
        guard Bee.isEnabled, let find = item.target, item.stillValid?() ?? true, let target = find() else {
            // A plan still going would act alongside this; it stops first.
            runGuard.stop(.replaced)
            runNow(item)
            return
        }
        let run = runGuard.begin()
        runIsPlan = false
        runTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let landed = await self.bee.fly(to: target, saying: BeeLabel.text(for: item), from: origin)
            // Stopped on the way: nothing runs. Not stopped but the bee couldn't fly (the target is on no
            // screen): the item still runs, as it would without the bee.
            guard self.runGuard.isCurrent(run) else { return }
            self.runGuard.end(run)
            self.runTask = nil
            if self.runNow(item) {
                if landed { self.bee.leave() }
            } else {
                self.bee.say("It changed, so I left it")
                self.bee.leave(after: 1.6)
            }
        }
    }

    /// Runs an item now, if what it acts on is still there and still the same. False when it was not run.
    @discardableResult
    private func runNow(_ item: Item) -> Bool {
        guard item.runIfValid() else {
            NSSound.beep()
            Log.append("skipped a \(item.kind) whose target changed")
            DemoLog.note("skipped", ["title": item.title])
            return false
        }
        DemoLog.note("pressed", ["title": item.title])
        return true
    }

    /// Runs a plan one step at a time, in the order previewed. Each step is checked before it runs and,
    /// where it can be, after it settles. A step with a place on screen gets the bee first, and is checked
    /// again once the bee lands. On the first step that can't run or didn't work, the plan stops and the
    /// bar reopens to say which one.
    private func execute(_ plan: Plan, from origin: CGPoint?) {
        let run = runGuard.begin()
        runIsPlan = true
        runTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            for (index, step) in plan.steps.enumerated() {
                // The guard, not Task cancellation alone, decides: it is the one place every stop goes through.
                guard let self, self.runGuard.isCurrent(run) else { return }
                if let stillValid = step.stillValid, !stillValid() {
                    return self.reportStop(run, at: index, of: plan, reason: "it's no longer on screen")
                }
                if Bee.isEnabled, let target = step.target?() {
                    _ = await self.bee.fly(to: target, saying: BeeLabel.text(for: step), from: origin)
                    // A bee that couldn't fly is no reason to stop; only a stop is.
                    guard self.runGuard.isCurrent(run) else { return }
                    if let stillValid = step.stillValid, !stillValid() {
                        return self.reportStop(run, at: index, of: plan, reason: "it changed while I got there")
                    }
                }
                step.run()
                DemoLog.note("pressed", ["title": step.text, "step": index + 1])
                try? await Task.sleep(nanoseconds: UInt64(step.settleTime * 1_000_000_000))
                guard self.runGuard.isCurrent(run) else { return }
                if let succeeded = step.succeeded, !succeeded() {
                    // Give a slow app a little longer before calling it a failure.
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    guard self.runGuard.isCurrent(run) else { return }
                    if !succeeded() {
                        return self.reportStop(run, at: index, of: plan, reason: "it didn't take effect")
                    }
                }
            }
            guard let self, self.runGuard.isCurrent(run) else { return }
            self.runGuard.end(run)
            self.runTask = nil
            self.bee.leave()
            DemoLog.note("plan-finished", ["steps": plan.steps.count])
        }
    }

    /// Every stop comes here: Escape in any app, your own click or key, sleep, or a new run replacing this one.
    private func runStopped(_ reason: RunGuard.Reason) {
        DemoLog.note("stopped", ["reason": "\(reason)"])
        runTask?.cancel()
        runTask = nil
        switch reason {
        case .replaced:
            // The new run takes the bee from here.
            return
        case .takeover:
            // You are in charge now; the bee gets out of the way.
            bee.hide()
        case .escape, .sleep:
            // With the bee out, it says so. Without it, and with the bar closed, a beep is the only sign.
            if bee.say("Stopped") {
                bee.leave(after: 0.9)
            } else if reason == .escape, !isShown {
                NSSound.beep()
            }
        }
        if runIsPlan, isShown {
            model.planProblem = "Stopped. Steps still to come didn't run."
        }
    }

    /// Says which step failed. A bar already open keeps what is in it; only a closed one is reopened.
    private func reportStop(_ run: Int, at index: Int, of plan: Plan, reason: String) {
        Log.append("plan stopped at step \(index + 1) of \(plan.steps.count)")
        DemoLog.note("plan-stopped", ["step": index + 1, "reason": reason])
        runGuard.end(run)
        runTask = nil
        bee.hide()
        if !isShown { show() }
        model.clearPlan()
        model.planProblem = "Stopped at step \(index + 1), “\(plan.steps[index].text)”, because \(reason). Later steps didn't run."
    }

    /// Beeline has no Edit menu, which is what normally routes ⌘C, ⌘V and the rest to a text field.
    /// This sends the same commands to the search field directly.
    private func handleEditShortcut(_ event: NSEvent) -> Bool {
        // Caps Lock is not a modifier here: ⌘V must paste with it on.
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
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
        cancelPendingAct()
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
        cancelPendingAct()
        isListening = true
        model.query = ""
        model.voiceNote = "Listening…"
        var lastTranscript = ""
        voice.onText = { [weak self] text in
            guard let self else { return }
            // The final transcript lands a moment after the key comes up. If you have typed over the
            // words by then, what you typed stays.
            guard self.model.query == lastTranscript else { return }
            lastTranscript = text
            self.model.query = text
        }
        voice.vocabulary = model.catalogue.vocabulary()
        voice.onLevel = { [weak self] level in
            guard let self, self.isListening else { return }
            // Rise at once, fall gently, so the meter breathes rather than flickers.
            let last = self.model.voiceLevel ?? 0
            self.model.voiceLevel = level > last ? level : last * 0.7 + level * 0.3
        }
        voice.onFinal = { [weak self] text in self?.heard(text) }
        voice.onState = { [weak self] state in
            guard let self else { return }
            switch state {
            case .listening: self.model.voiceNote = "Listening… let go to stop"
            case .stopped: self.model.voiceNote = nil
            case .unavailable(let reason):
                self.isListening = false
                self.model.voiceLevel = nil
                self.model.voiceNote = reason
            }
        }
        voice.start()
    }

    /// What was going to run by itself after a hold, and the moment it runs. Escape, typing or closing the bar
    /// cancels it.
    private var pendingAct: (item: Item, timer: Timer)?

    /// The final words of a hold. When they plainly name one safe thing, it runs after a short beat;
    /// otherwise the words wait in the bar for Return, as typing does.
    func heard(_ text: String) {
        cancelPendingAct()
        guard !isListening, isShown, Settings.isOn(Settings.actOnRelease), Settings.isOn(Settings.holdToTalk),
              model.query == text, model.armedID == nil, !model.isShowingPlan,
              let item = AutoAct.pick(model.results, spoken: text) else { return }
        model.selected = model.results.firstIndex { $0.id == item.id } ?? 0
        let verb = item.verb.isEmpty ? "Running" : item.verb == "Open" ? "Opening" : item.verb
        model.voiceNote = "\(verb) \(item.title) · esc to cancel"
        DemoLog.note("auto-act", ["title": item.title])
        let timer = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: false) { [weak self] _ in
            guard let self, let pending = self.pendingAct, pending.item.id == item.id else { return }
            self.pendingAct = nil
            self.model.voiceNote = nil
            // The list may have changed in the beat: only the very item announced runs.
            guard self.model.query == text, let current = self.model.results.first(where: { $0.id == item.id }) else { return }
            self.model.run(current)
        }
        pendingAct = (item, timer)
    }

    /// Stops a run that was about to happen on release. True when there was one.
    @discardableResult
    func cancelPendingAct() -> Bool {
        guard let pending = pendingAct else { return false }
        pending.timer.invalidate()
        pendingAct = nil
        model.voiceNote = nil
        DemoLog.note("auto-act-cancelled")
        return true
    }

    /// Stops listening and drops what was heard, so letting go of ⌘Space afterwards does nothing.
    private func cancelListening() {
        isListening = false
        // Letting go of the shortcut after this must leave the bar open, words gone.
        openedByPress = true
        voice.cancel()
        model.voiceLevel = nil
        model.voiceNote = nil
        model.query = ""
    }

    private func stopListening() {
        isListening = false
        model.voiceLevel = nil
        voice.stop()
        if case .some(let note) = model.voiceNote, note.hasPrefix("Listening") { model.voiceNote = nil }
    }

    func toggle() {
        isShown ? hide() : show()
    }

    func show() {
        isShown = true
        voice.cancel()
        model.clearPlan()
        model.newTip()
        model.query = ""
        model.focusTick += 1
        model.catalogue.refreshRunning()
        model.catalogue.refreshTabs { [weak self] in self?.model.refreshInBackground() }
        model.catalogue.refreshScreen { [weak self] in self?.model.refreshInBackground() }
        model.catalogue.refreshAppsIfChanged()
        model.catalogue.refreshShortcuts()
        // File chores act on Finder's selection, so it is read only when the bar opens over Finder.
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.finder" {
            FileTools.refreshSelection { [weak self] in self?.model.refreshInBackground() }
        } else {
            FileTools.clearSelection()
        }
        // Rewrites act on the text selected in the app in front, read before the bar takes focus.
        Rewrite.refreshSelection { [weak self] in self?.model.refreshInBackground() }
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
        // Opening the bar is taking over: a run still going stops, and a plan's stop is said in the bar.
        if runGuard.isRunning { runGuard.stop(.takeover) }
    }

    private func hide() {
        // Closing the bar also cancels a hold that has not started listening yet, and drops any words
        // still to come: a transcript landing in the next bar would overwrite what is typed there.
        holdTimer?.invalidate()
        holdTimer = nil
        // A result about to run on release never runs once the bar is gone, or after another one ran.
        cancelPendingAct()
        if isListening { stopListening() }
        voice.cancel()
        // A banner about the microphone is about the last hold, not the next bar (L12).
        model.voiceNote = nil
        guard isShown else { return }
        isShown = false
        // A Claude request left running after the bar closes has nowhere to deliver its answer (L13).
        model.clearPlan()
        panel.orderOut(nil)
    }

    func windowDidResignKey(_ notification: Notification) {
        hide()
    }
}
