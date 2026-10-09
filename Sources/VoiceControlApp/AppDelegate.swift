import AppKit
import AVFoundation
import VoiceControlCore
import VoiceControlMac

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let observations: NativeObservationProvider
    private let driver: NativeActionDriver
    private let gate: DispatchGate
    private let executor: SerialExecutor
    private let session: SessionArbiter
    private let prompt = CursorPrompt()
    private var hotkey: HotKeyMonitor?
    private var window: NSWindow!
    private var status = NSTextField(wrappingLabelWithString: "")
    private let fixture = FixtureTextView()
    private var fixtureMode = false
    private var timer: Timer?
    private var fixtureRecords: [FixtureEvent] = []
    private var lifecycleObservers: [NSObjectProtocol] = []

    override init() {
        let observations = NativeObservationProvider()
        let driver = NativeActionDriver(observations: observations)
        let gate = DispatchGate(releaseHeldInputs: { driver.releaseHeldInputs() })
        self.observations = observations; self.driver = driver; self.gate = gate
        self.executor = SerialExecutor(driver: driver, gate: gate)
        self.session = SessionArbiter(gate: gate)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildWindow()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        installMenu()
        refreshPermissions()
        let executor = executor
        lifecycleObservers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: nil) { _ in executor.cancel() })
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.session.tick(now: ProcessInfo.processInfo.systemUptime) {
                    self.prompt.hide()
                }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        executor.cancel(); hotkey?.stop(); timer?.invalidate()
        for observer in lifecycleObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }

    private func installMenu() {
        let bar = NSMenu()
        let appItem = NSMenuItem(); bar.addItem(appItem)
        let menu = NSMenu(); appItem.submenu = menu
        menu.addItem(withTitle: "Quit Voice Control", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        NSApp.mainMenu = bar
    }

    private func buildWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 520),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Voice Control • Local prototype"
        window.center(); window.isReleasedWhenClosed = false
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        let heading = NSTextField(labelWithString: "Voice Control")
        heading.font = .systemFont(ofSize: 26, weight: .semibold)
        stack.addArrangedSubview(heading)
        let detail = NSTextField(wrappingLabelWithString:
            "First, verify held-key input on this disposable surface. Speech and cloud inference are not enabled in this build. Escape stops queued work.")
        stack.addArrangedSubview(detail)
        status.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        stack.addArrangedSubview(status)
        let row = NSStackView(); row.orientation = .horizontal; row.spacing = 8
        row.addArrangedSubview(button("Allow Accessibility", #selector(requestAccessibility)))
        row.addArrangedSubview(button("Allow Input Monitoring", #selector(requestInput)))
        row.addArrangedSubview(button("Refresh", #selector(refreshPermissions)))
        stack.addArrangedSubview(row)
        stack.addArrangedSubview(button("Arm disposable input test", #selector(armFixture)))
        stack.addArrangedSubview(NSTextField(wrappingLabelWithString:
            "After arming, hold Right Option until “option-safe” appears below. Release to finalize. The test checks that Option does not modify inserted text. It only runs while this window is active."))
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        fixture.isRichText = false; fixture.font = .monospacedSystemFont(ofSize: 18, weight: .regular)
        fixture.isEditable = true; fixture.isSelectable = true
        fixture.autoresizingMask = [.width]; fixture.minSize = NSSize(width: 0, height: 100)
        fixture.maxSize = NSSize(width: .greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        fixture.isVerticallyResizable = true; fixture.isHorizontallyResizable = false
        fixture.textContainer?.widthTracksTextView = true
        fixture.setAccessibilityLabel("Test input")
        scroll.documentView = fixture
        scroll.heightAnchor.constraint(equalToConstant: 110).isActive = true
        stack.addArrangedSubview(scroll)
        fixture.onInput = { [weak self] event in self?.record(event) }
        let content = NSView(); window.contentView = content; content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
    }

    private func button(_ title: String, _ action: Selector) -> NSButton {
        NSButton(title: title, target: self, action: action)
    }

    @objc private func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        refreshPermissions()
    }
    @objc private func requestInput() { _ = CGRequestListenEventAccess(); refreshPermissions() }
    @objc private func refreshPermissions() {
        status.stringValue = "Accessibility: \(AXIsProcessTrusted() ? "allowed" : "needed")\nInput Monitoring: \(CGPreflightListenEventAccess() ? "allowed" : "needed")"
    }

    @objc private func armFixture() {
        guard AXIsProcessTrusted(), CGPreflightListenEventAccess() else {
            refreshPermissions(); prompt.show("Allow Accessibility and Input Monitoring, then arm this test."); return
        }
        guard fixture.string.isEmpty else {
            prompt.show("Clear the disposable field yourself before rearming."); return
        }
        fixtureMode = true; fixtureRecords.removeAll()
        if hotkey == nil {
            let executor = executor, observations = observations, session = session
            let monitor = HotKeyMonitor(
                onHold: { [weak self] in Task { @MainActor [weak self] in await self?.beginFixture() } },
                onRelease: { [weak self] in Task { @MainActor [weak self] in self?.release() } },
                onEscape: { [weak self] in
                    executor.cancel()
                    session.stop(now: ProcessInfo.processInfo.systemUptime, closeListening: true)
                    Task { @MainActor [weak self] in self?.prompt.hide(); self?.status.stringValue = "Stopped. No queued input remains." }
                },
                onPhysicalEnter: { false },
                onInteraction: { observations.invalidate(); executor.cancel() },
                onFailure: { [weak self] in Task { @MainActor [weak self] in
                    self?.status.stringValue = "Input monitor unavailable. Refresh permissions and rearm."
                    self?.hotkey = nil
                } })
            hotkey = monitor; monitor.start()
        }
        window.makeFirstResponder(fixture)
        prompt.show("Test armed. Hold Right Option until the text appears.")
    }

    private func beginFixture() async {
        guard fixtureMode, NSApp.isActive, window.isKeyWindow, fixture.string.isEmpty else {
            prompt.show("Open the disposable test window and clear its field before holding Right Option."); return
        }
        let token = session.begin(now: ProcessInfo.processInfo.systemUptime)
        session.setPending(work: 1, prompt: false, now: ProcessInfo.processInfo.systemUptime)
        prompt.show("Right Option held. Checking focus and input…")
        do {
            let first = try await observations.observe()
            guard case let .resolved(target) = await observations.resolve("Test input", in: first) else {
                throw ControlError.staleTarget
            }
            await executor.submit(ActionProposal(request: token, action: .focus(target), finalized: false))
            await executor.waitUntilSettled()
            guard gate.isCurrent(token) else { throw ControlError.staleTarget }
            let refreshed = try await observations.observe()
            guard case let .resolved(field) = await observations.resolve("Test input", in: refreshed) else {
                throw ControlError.staleTarget
            }
            await executor.submit(ActionProposal(request: token, action: .insertText(field, text: "option-safe"), finalized: true))
            await executor.waitUntilSettled()
            // Post-event delivery is asynchronous; the fixture records actual received events.
            try await Task.sleep(for: .milliseconds(150))
            summarizeFixture()
        } catch {
            executor.cancel()
            status.stringValue = "The fixture could not validate a fresh editable field. No retry was issued."
            prompt.show("Test did not finish. Check permissions and keep this window active.")
        }
        session.setPending(work: 0, prompt: false, now: ProcessInfo.processInfo.systemUptime)
    }

    private func release() {
        // No microphone yet. The speech slice will supply its captured sample fence.
        session.release(sampleFence: 0, now: ProcessInfo.processInfo.systemUptime)
        prompt.show("Released. Queued work may finish; Escape stops it.")
    }

    private func record(_ event: NSEvent) {
        guard fixtureMode else { return }
        fixtureRecords.append(FixtureEvent(
            tagged: event.cgEvent?.getIntegerValueField(.eventSourceUserData) == HotKeyMonitor.eventTag,
            modifiers: event.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue,
            rightOptionHeld: hotkey?.isRightOptionHeld == true,
            time: ProcessInfo.processInfo.systemUptime))
    }

    private func summarizeFixture() {
        let tagged = fixtureRecords.filter(\.tagged)
        let result = FixtureEvidence(
            expectedTextReceived: fixture.string == "option-safe",
            taggedKeyDowns: tagged.count,
            allModifiersClear: !tagged.isEmpty && tagged.allSatisfy { $0.modifiers == 0 },
            rightOptionHeldThroughout: !tagged.isEmpty && tagged.allSatisfy(\.rightOptionHeld),
            events: tagged)
        let passed = result.expectedTextReceived && result.taggedKeyDowns == 11
            && result.allModifiersClear && result.rightOptionHeldThroughout
        status.stringValue = passed ? "PASS: 11 tagged key-downs arrived with no modifiers while Right Option stayed held."
            : "Not verified: expected text \(result.expectedTextReceived), events \(tagged.count), modifiers clear \(result.allModifiersClear), held throughout \(result.rightOptionHeldThroughout)."
        prompt.show(passed ? "Held-key input passed. Release Right Option." : "Held-key input needs inspection. See the test window.")
        // Only controlled fixture booleans/timings are written. No user text or raw events.
        if let data = try? JSONEncoder().encode(result) {
            let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("VoiceControlPrototype", isDirectory: true)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? data.write(to: directory.appendingPathComponent("held-input-evidence.json"), options: .atomic)
        }
    }
}

@MainActor
private final class FixtureTextView: NSTextView {
    var onInput: ((NSEvent) -> Void)?
    override func keyDown(with event: NSEvent) { onInput?(event); super.keyDown(with: event) }
}
private struct FixtureEvent: Codable {
    let tagged: Bool
    let modifiers: UInt
    let rightOptionHeld: Bool
    let time: TimeInterval
}
private struct FixtureEvidence: Codable {
    let expectedTextReceived: Bool
    let taggedKeyDowns: Int
    let allModifiersClear: Bool
    let rightOptionHeldThroughout: Bool
    let events: [FixtureEvent]
}
