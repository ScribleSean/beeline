import AppKit
import Carbon.HIToolbox

/// Watches over whatever Beeline is doing on your behalf (one action with the bee, or a plan) and stops
/// it the moment you want it stopped. There is one way in and one way out, so nothing is half-cancelled.
///
/// Escape stops from any app. Beeline only *watches* for it and never swallows it, so Escape still does
/// its usual job in the app in front. Your own click or keypress means you have taken over, so steps
/// still to come do not run. Moving the pointer does not count: a hand resting on the trackpad must not
/// cancel anything. Keystrokes Beeline posts itself carry a tag and never count as yours. The watch
/// exists only while something runs.
final class RunGuard {
    enum Reason: Equatable {
        case escape, takeover, sleep, replaced
    }

    /// Marks keystrokes Beeline posts, so they are never mistaken for yours.
    static let eventTag: Int64 = 0x4245_454C_494E_45 // "BEELINE"

    /// Called on the main thread when a run stops for a reason other than finishing.
    var onStop: (Reason) -> Void = { _ in }

    private var token = 0
    private var running = false
    private var monitor: Any?
    private var sleepObserver: NSObjectProtocol?
    /// False in tests, which check the rules without watching real input.
    private let watches: Bool

    init(watches: Bool = true) {
        self.watches = watches
    }

    /// Starts a run and returns its token. A run already going is stopped first.
    func begin() -> Int {
        if running { stop(.replaced) }
        token += 1
        running = true
        install()
        return token
    }

    /// True while this run is the current one and nothing has stopped it.
    func isCurrent(_ run: Int) -> Bool {
        running && run == token
    }

    var isRunning: Bool { running }

    /// The run finished on its own.
    func end(_ run: Int) {
        guard isCurrent(run) else { return }
        running = false
        uninstall()
    }

    /// Stops the current run, if any. Synchronous: once this returns, no step of the old run starts.
    func stop(_ reason: Reason) {
        guard running else { return }
        token += 1
        running = false
        uninstall()
        Log.append("run stopped: \(reason)")
        onStop(reason)
    }

    /// What an event from another app means for a run in progress. Pure, so it can be tested.
    static func reason(for type: NSEvent.EventType, keyCode: UInt16, modifiers: NSEvent.ModifierFlags,
                       isRepeat: Bool, tag: Int64) -> Reason? {
        if tag == eventTag { return nil }
        switch type {
        case .keyDown:
            // A held Return that ran the item keeps repeating into the app behind; that is not a new press.
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
        // Seeing keys in other apps needs Accessibility, which acting on them needs anyway. Keys are only
        // asked for once it is granted, so this never brings up a permission prompt of its own. Without it
        // the watch sees only clicks.
        var mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        if Accessibility.isTrusted { mask.insert(.keyDown) }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            let tag = event.cgEvent?.getIntegerValueField(.eventSourceUserData) ?? 0
            let isRepeat = event.type == .keyDown && event.isARepeat
            let keyCode = event.type == .keyDown ? event.keyCode : 0
            guard let reason = Self.reason(for: event.type, keyCode: keyCode, modifiers: event.modifierFlags,
                                           isRepeat: isRepeat, tag: tag) else { return }
            self?.stop(reason)
        }
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.stop(.sleep)
        }
    }

    private func uninstall() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if let sleepObserver { NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver) }
        sleepObserver = nil
    }
}
