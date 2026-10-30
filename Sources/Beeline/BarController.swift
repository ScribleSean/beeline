import AppKit
import Carbon.HIToolbox
import SwiftUI

/// A borderless window can't become key (so can't take typing) unless canBecomeKey is overridden.
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
            if Demo.isVoice && !Demo.voiceRun {
                DemoLog.note("voice-plan", ["id": item.id, "action": Announce.action(item), "query": self.model.resultsQuery])
                return
            }
            self.voice.cancel()
            let origin = self.beeOrigin
            let asked = self.model.query
            self.hide()
            self.perform(item, from: origin, asked: asked)
        }
        model.onRunPlan = { [weak self] plan in
            guard let self else { return }
            if Demo.isVoice && !Demo.voiceRun {
                DemoLog.note("voice-plan", ["action": Announce.plan(plan), "steps": plan.steps.count])
                return
            }
            let origin = self.beeOrigin
            let asked = self.model.query
            self.hide()
            self.execute(plan, from: origin, asked: asked)
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
        NotificationCenter.default.addObserver(forName: Actions.failed, object: nil, queue: .main) { [weak self] note in
            guard let self, let message = note.userInfo?["message"] as? String else { return }
            if !self.isShown { self.show() }
            self.model.closeActions(refreshing: false)
            self.model.clearPlan()
            self.model.planProblem = message
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.panel.isKeyWindow else { return event }
            // While an input method is composing (Japanese, Chinese, Korean), Return and Escape belong to it.
            if let editor = self.panel.firstResponder as? NSTextView, editor.hasMarkedText() { return event }
            // Like any other key, these stop a voice result that is about to run on its own.
            if self.handleActionShortcut(event) { self.cancelPendingAct(); return nil }
            if self.model.showsActions {
                self.cancelPendingAct()
                switch Int(event.keyCode) {
                case kVK_Escape:
                    if !event.isARepeat { self.model.escapeInActions() }
                    return nil
                case kVK_DownArrow: self.model.moveAction(1); return nil
                case kVK_UpArrow: self.model.moveAction(-1); return nil
                case kVK_Return, kVK_ANSI_KeypadEnter:
                    if !event.isARepeat { self.model.performSelectedAction() }
                    return nil
                default:
                    // Typing narrows the panel instead of changing the search, which would close it.
                    let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
                    if Int(event.keyCode) == kVK_Delete, modifiers.isSubset(of: [.command, .option, .shift]) {
                        self.model.deleteActionFilter(all: !modifiers.isSubset(of: .shift))
                        return nil
                    }
                    // Forward Delete has nothing after the filter to remove, and in the search it closes the panel.
                    if Int(event.keyCode) == kVK_ForwardDelete { return nil }
                    if modifiers == .command, event.charactersIgnoringModifiers?.lowercased() == "v" {
                        self.model.pasteIntoActionFilter()
                        return nil
                    }
                    // Cut and undo would change the search under the panel and close it.
                    if modifiers.contains(.command), modifiers.isSubset(of: [.command, .shift]),
                       ["x", "z"].contains(event.charactersIgnoringModifiers?.lowercased()) { return nil }
                    // ⌃H, ⌃D, ⌃K and the rest edit the search field the same way.
                    if modifiers.contains(.control) { return nil }
                    if modifiers.isDisjoint(with: [.command, .control]) {
                        if self.model.typeInActions(event.characters ?? "") { return nil }
                        // A dead key (´ then e) would start composing in the search field and close the panel.
                        if event.characters?.isEmpty == true { return nil }
                    }
                }
            }
            if self.handleEditShortcut(event) { return nil }
            switch Int(event.keyCode) {
            case kVK_Escape:
                // A held Esc acts once, so the repeat after closing the ⌘K panel doesn't also hide the bar.
                if event.isARepeat { return nil }
                if self.isListening {
                    self.cancelListening()
                } else if self.cancelPendingAct() {
                    // Empty on purpose: Escape in the beat after letting go keeps the words but runs nothing.
                } else if self.runGuard.isRunning {
                    self.runGuard.stop(.escape)
                } else if self.model.isShowingPlan {
                    self.model.clearPlan()
                } else if self.model.armedID != nil {
                    self.model.armedID = nil
                } else {
                    self.hide()
                }
            case kVK_DownArrow: self.cancelPendingAct(); self.model.move(1)
            case kVK_UpArrow: self.cancelPendingAct(); self.model.move(-1)
            case kVK_Return, kVK_ANSI_KeypadEnter: if !event.isARepeat { self.model.runSelected() }
            default:
                self.cancelPendingAct()
                return event
            }
            return nil
        }
    }

    private var isShown = false
    var isOpen: Bool { isShown }
    private let bee = Bee()
    let runGuard = RunGuard()
    private var runTask: Task<Void, Never>?
    private var runIsPlan = false
    private var placementCancel: CancelToken?

    private var beeOrigin: CGPoint? {
        guard isShown else { return nil }
        return CGPoint(x: panel.frame.minX + 34, y: panel.frame.maxY - 41)
    }

    private func perform(_ item: Item, from origin: CGPoint?, asked: String) {
        // Handled here without Claude, so it stays here: no follow-up reads it, and the plan before it is gone.
        LastRun.shared.clear()
        guard Bee.isEnabled, let find = item.target, item.stillValid?() ?? true, let target = find() else {
            runGuard.stop(.replaced)
            runNow(item, asked: asked)
            return
        }
        let run = runGuard.begin()
        runIsPlan = false
        runTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let landed = await self.bee.fly(to: target, saying: BeeLabel.text(for: item),
                                               speaking: Announce.action(item), from: origin)
            guard self.runGuard.isCurrent(run) else { return }
            self.runGuard.end(run)
            self.runTask = nil
            if self.runNow(item, asked: asked) {
                if landed { self.bee.leave() }
            } else {
                self.bee.say("It changed, so I left it")
                self.bee.leave(after: 1.6)
            }
        }
    }

    @discardableResult
    private func runNow(_ item: Item, asked: String) -> Bool {
        guard item.runIfValid() else {
            NSSound.beep()
            Log.append("skipped a \(item.kind) whose target changed")
            DemoLog.note("skipped", ["title": item.title])
            return false
        }
        DemoLog.note("pressed", ["title": item.title])
        return true
    }

    private func execute(_ plan: Plan, from origin: CGPoint?, asked: String) {
        let run = runGuard.begin()
        LastRun.shared.begin(run: run)
        // Only an undo entry made from here on is this plan's own.
        let began = Date()
        let cancel = CancelToken()
        placementCancel = cancel
        runIsPlan = true
        runTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            for (index, step) in plan.steps.enumerated() {
                guard let self, self.runGuard.isCurrent(run) else { return }
                if let stillValid = step.stillValid, !stillValid() {
                    return self.reportStop(run, at: index, of: plan, reason: "it's no longer on screen")
                }
                if await self.bee.guide(to: step.target, saying: BeeLabel.text(for: step), speaking: step.displayText,
                                        from: origin) != nil {
                    guard self.runGuard.isCurrent(run) else { return }
                    if let stillValid = step.stillValid, !stillValid() {
                        return self.reportStop(run, at: index, of: plan, reason: "it changed while I got there")
                    }
                }
                step.run(cancel: cancel)
                DemoLog.note("pressed", ["title": step.text, "step": index + 1])
                try? await Task.sleep(nanoseconds: UInt64(step.settleTime * 1_000_000_000))
                // Same grace after a stop, so an undo that lands late is still recorded.
                let outcome = await step.outcome(within: step.grace)
                let tookEffect = outcome == .tookEffect
                // A stop during the wait still keeps a step that landed. Only this run may write, and a
                // stopped one never reads as finished.
                let current = self.runGuard.isCurrent(run)
                if tookEffect {
                    LastRun.shared.record(run: run, request: asked, steps: plan.steps.prefix(index + 1).map(\.text),
                                          finished: current && index + 1 == plan.steps.count,
                                          undoID: UndoLog.shared.latestID(since: began))
                }
                guard current else { return }
                if !tookEffect {
                    return self.reportStop(run, at: index, of: plan,
                                           reason: outcome.stopReason(after: step.settleTime + step.grace))
                }
            }
            guard let self, self.runGuard.isCurrent(run) else { return }
            self.runGuard.end(run, pending: plan.steps.contains { $0.cancellableRun != nil } ? cancel : nil)
            self.runIsPlan = false
            self.runTask = nil
            self.bee.leave()
            DemoLog.note("plan-finished", ["steps": plan.steps.count])
        }
    }

    private func runStopped(_ reason: RunGuard.Reason) {
        placementCancel?.cancel()
        placementCancel = nil
        DemoLog.note("stopped", ["reason": "\(reason)"])
        runTask?.cancel()
        runTask = nil
        switch reason {
        case .replaced:
            return
        case .takeover:
            bee.hide()
        case .escape, .sleep:
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

    private func reportStop(_ run: Int, at index: Int, of plan: Plan, reason: String) {
        placementCancel?.cancel()
        placementCancel = nil
        Log.append("plan stopped at step \(index + 1) of \(plan.steps.count)")
        // The record was emptied when this plan began and lists only steps that took effect, each marked
        // unfinished until the last, so it is empty when step 1 failed and nothing older looks current.
        DemoLog.note("plan-stopped", ["step": index + 1, "reason": reason])
        runGuard.end(run)
        runTask = nil
        bee.hide()
        if !isShown { show() }
        model.clearPlan()
        model.planProblem = "Stopped at step \(index + 1), “\(plan.steps[index].text)”, because \(reason). Later steps didn't run."
    }

    /// ⌘K and the panel's own keys. A key the focused row doesn't offer goes on as usual (⌘↩ then opens).
    private func handleActionShortcut(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        // Letters by what they type, like handleEditShortcut, so ⌘K is K on Dvorak; a layout that types no
        // Latin letter (Russian, Greek) falls back to the key's QWERTY position.
        let typed = event.charactersIgnoringModifiers?.lowercased()
        let letter = typed.map { $0.allSatisfy(\.isASCII) } == true ? typed
            : [kVK_ANSI_K: "k", kVK_ANSI_C: "c", kVK_ANSI_A: "a"][Int(event.keyCode)]
        let isReturn = [kVK_Return, kVK_ANSI_KeypadEnter].contains(Int(event.keyCode))
        // A held key acts once: a repeat of ⇧⌘⌫ would forget the next pick too. A key the row doesn't
        // offer goes on to the text field.
        func act(_ action: BarAction.ID) -> Bool {
            guard model.focusedActions.contains(where: { $0.id == action }) else { return false }
            return event.isARepeat || model.perform(action)
        }
        if modifiers == .command, letter == "k" {
            if !event.isARepeat { model.toggleActions() }
            return true
        }
        // Inside the panel ⌘↩ is only Show in Finder; on the list it falls back to open.
        if modifiers == .command, isReturn { return act(.reveal) || model.showsActions }
        if modifiers == [.command, .shift, .option], letter == "c" { return act(.copyMarkdown) }
        guard modifiers == [.command, .shift] else { return false }
        if letter == "c" { return act(.copy) }
        if letter == "a" { return act(.alias) }
        if Int(event.keyCode) == kVK_Delete { return act(.forget) }
        return false
    }

    /// AppKit routes ⌘C, ⌘V and the rest to a text field through the Edit menu, which Beeline doesn't have.
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
    private var openedByPress = false

    func shortcutPressed() {
        cancelPendingAct()
        openedByPress = !isShown
        if !isShown { show() }
        holdTimer?.invalidate()
        guard Demo.isVoice || Settings.isOn(Settings.holdToTalk) else { return }
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
        // A completed recognition session still counts as a hold when the shortcut is released.
        openedByPress = true
        model.query = ""
        model.voiceNote = "Listening…"
        var lastTranscript = ""
        voice.onText = { [weak self] text in
            guard let self else { return }
            guard self.model.query == lastTranscript else { return }
            lastTranscript = text
            self.model.query = text
        }
        voice.vocabulary = model.catalogue.vocabulary()
        voice.onLevel = { [weak self] level in
            guard let self, self.isListening else { return }
            let last = self.model.voiceLevel ?? 0
            self.model.voiceLevel = level > last ? level : last * 0.7 + level * 0.3
        }
        voice.onAudioEnd = { [weak self] in self?.shortcutReleased() }
        voice.onFinal = { [weak self] text in self?.heard(text) }
        voice.onState = { [weak self] state in
            guard let self else { return }
            switch state {
            case .listening: self.model.voiceNote = "Listening… let go to stop"
            case .stopped:
                self.isListening = false
                self.model.voiceLevel = nil
                self.model.voiceNote = nil
            case .unavailable(let reason):
                self.isListening = false
                self.model.voiceLevel = nil
                self.model.voiceNote = reason
                self.model.say(reason)
            }
        }
        voice.start()
    }

    private var pendingAct: (item: Item, timer: Timer)?

    func heard(_ text: String) {
        cancelPendingAct()
        guard !isListening, isShown, (Demo.isVoice || Settings.isOn(Settings.actOnRelease)), (Demo.isVoice || Settings.isOn(Settings.holdToTalk)),
              model.query == text, model.armedID == nil, !model.isShowingPlan,
              model.prepareVoiceResults(for: text),
              let item = AutoAct.pick(model.results, spoken: text) else { return }
        model.selected = model.results.firstIndex { $0.id == item.id } ?? 0
        let verb = item.verb.isEmpty ? "Running" : item.verb == "Open" ? "Opening" : item.verb
        model.voiceNote = "\(verb) \(item.title) · esc to cancel"
        let spoken = "\(Announce.action(item)). Escape to cancel."
        model.say(spoken)
        DemoLog.note("auto-act", ["title": item.title])
        if Demo.isVoice {
            DemoLog.note("voice-plan", ["id": item.id, "action": Announce.action(item), "query": self.model.resultsQuery])
            if !Demo.voiceRun { return }
        }
        let wait = AutoAct.window(voiceOver: AutoAct.voiceOverIsOn(), spoken: spoken)
        let timer = Timer.scheduledTimer(withTimeInterval: wait, repeats: false) { [weak self] _ in
            guard let self, let pending = self.pendingAct, pending.item.id == item.id else { return }
            self.pendingAct = nil
            self.model.voiceNote = nil
            guard self.model.query == text, self.model.resultsQuery == text, let current = self.model.results.first(where: { $0.id == item.id }) else { return }
            self.model.run(current)
        }
        pendingAct = (item, timer)
    }

    @discardableResult
    func cancelPendingAct() -> Bool {
        guard let pending = pendingAct else { return false }
        pending.timer.invalidate()
        pendingAct = nil
        model.voiceNote = nil
        DemoLog.note("auto-act-cancelled")
        return true
    }

    private func cancelListening() {
        isListening = false
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
        model.isOpen = true
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
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.finder" {
            FileTools.refreshSelection { [weak self] in self?.model.refreshInBackground() }
        } else {
            FileTools.clearSelection()
        }
        Rewrite.refreshSelection { [weak self] in self?.model.refreshInBackground() }
        Rates.shared.refreshIfStale()
        model.needsAccess = !Accessibility.isTrusted
        Chooser.prewarm()

        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            let top = visible.maxY - visible.height * 0.2 + 40
            panel.setFrame(NSRect(x: visible.midX - size.width / 2, y: top - size.height,
                                  width: size.width, height: size.height), display: true)
        }
        TestRun.orderFront(panel)
        if runGuard.isRunning { runGuard.stop(.takeover) }
    }

    private func hide() {
        holdTimer?.invalidate()
        holdTimer = nil
        cancelPendingAct()
        if isListening { stopListening() }
        voice.cancel()
        model.voiceNote = nil
        guard isShown else { return }
        isShown = false
        model.isOpen = false
        model.closeActions(refreshing: false)
        model.clearPlan()
        panel.orderOut(nil)
    }

    func windowDidResignKey(_ notification: Notification) {
        hide()
    }
}
