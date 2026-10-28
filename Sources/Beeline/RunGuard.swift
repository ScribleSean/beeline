import AppKit
import Carbon.HIToolbox

final class RunGuard {
    enum Reason: Equatable {
        case escape, takeover, sleep, replaced
    }

    static let eventTag: Int64 = 0x4245_454C_494E_45

    var onStop: (Reason) -> Void = { _ in }

    private var token = 0
    private var running = false
    private var monitor: Any?
    private var sleepObserver: NSObjectProtocol?
    private let watches: Bool

    init(watches: Bool = true) {
        self.watches = watches
    }

    func begin() -> Int {
        if running { stop(.replaced) }
        token += 1
        running = true
        install()
        return token
    }

    func isCurrent(_ run: Int) -> Bool {
        running && run == token
    }

    var isRunning: Bool { running }

    func end(_ run: Int) {
        guard isCurrent(run) else { return }
        running = false
        uninstall()
    }

    func stop(_ reason: Reason) {
        guard running else { return }
        token += 1
        running = false
        uninstall()
        Log.append("run stopped: \(reason)")
        onStop(reason)
    }

    static func reason(for type: NSEvent.EventType, keyCode: UInt16, modifiers: NSEvent.ModifierFlags,
                       isRepeat: Bool, tag: Int64) -> Reason? {
        if tag == eventTag { return nil }
        switch type {
        case .keyDown:
            // A Return held when the bar closes keeps auto-repeating into the app behind.
            if isRepeat { return nil }
            let held = modifiers.intersection([.command, .option, .control, .shift])
            return Int(keyCode) == kVK_Escape && held.isEmpty ? .escape : .takeover
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            return .takeover
        default:
            return nil
        }
    }

    private func install() {
        guard watches, monitor == nil else { return }
        // A global monitor sees other apps' keys only with Accessibility. Clicks need nothing.
        var mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        if Accessibility.isTrusted { mask.insert(.keyDown) }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handle(event)
        }
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.stop(.sleep)
        }
    }

    func handle(_ event: NSEvent) {
        let tag = event.cgEvent?.getIntegerValueField(.eventSourceUserData) ?? 0
        let isRepeat = event.type == .keyDown && event.isARepeat
        let keyCode = event.type == .keyDown ? event.keyCode : 0
        guard let reason = Self.reason(for: event.type, keyCode: keyCode, modifiers: event.modifierFlags,
                                       isRepeat: isRepeat, tag: tag) else { return }
        stop(reason)
    }

    private func uninstall() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if let sleepObserver { NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver) }
        sleepObserver = nil
    }
}

final class CancelToken {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
}
