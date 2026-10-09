import AppKit

/// A dedicated event-tap thread keeps Escape independent of model and UI work.
final class HotKeyMonitor: @unchecked Sendable {
    static let eventTag: Int64 = 0x56434F4E54524F4C
    private let lock = NSLock()
    private var tap: CFMachPort?
    private var runLoop: CFRunLoop?
    private var held = false
    private var consumingEnter = false
    private var stopped = false
    private let onHold: @Sendable () -> Void
    private let onRelease: @Sendable () -> Void
    private let onEscape: @Sendable () -> Void
    private let onPhysicalEnter: @Sendable () -> Bool
    private let onInteraction: @Sendable () -> Void
    private let onFailure: @Sendable () -> Void

    init(onHold: @escaping @Sendable () -> Void,
         onRelease: @escaping @Sendable () -> Void,
         onEscape: @escaping @Sendable () -> Void,
         onPhysicalEnter: @escaping @Sendable () -> Bool,
         onInteraction: @escaping @Sendable () -> Void,
         onFailure: @escaping @Sendable () -> Void) {
        self.onHold = onHold; self.onRelease = onRelease; self.onEscape = onEscape
        self.onPhysicalEnter = onPhysicalEnter; self.onInteraction = onInteraction; self.onFailure = onFailure
    }

    var isRightOptionHeld: Bool { lock.withLock { held } }

    func start() {
        Thread.detachNewThread { [self] in
            let types: [CGEventType] = [.flagsChanged, .keyDown, .keyUp, .leftMouseDown,
                .rightMouseDown, .otherMouseDown, .scrollWheel, .mouseMoved, .leftMouseDragged]
            let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
            guard let newTap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                options: .defaultTap, eventsOfInterest: mask, callback: { _, type, event, info in
                    guard let info else { return Unmanaged.passUnretained(event) }
                    return Unmanaged<HotKeyMonitor>.fromOpaque(info).takeUnretainedValue().receive(type, event)
                }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
                onFailure(); return
            }
            let loop = CFRunLoopGetCurrent()
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, newTap, 0)
            let shouldStop = lock.withLock { () -> Bool in
                tap = newTap; runLoop = loop; return stopped
            }
            guard !shouldStop else { CFMachPortInvalidate(newTap); return }
            CFRunLoopAddSource(loop, source, .commonModes)
            CGEvent.tapEnable(tap: newTap, enable: true)
            CFRunLoopRun()
            CGEvent.tapEnable(tap: newTap, enable: false)
            CFMachPortInvalidate(newTap)
            lock.withLock { tap = nil; runLoop = nil; held = false }
        }
    }

    func stop() {
        let loop = lock.withLock { () -> CFRunLoop? in stopped = true; held = false; return runLoop }
        if let loop { CFRunLoopStop(loop) }
    }

    private func receive(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // A disabled emergency-stop channel invalidates the request. Require explicit re-enable.
            onEscape(); onFailure(); stop(); return Unmanaged.passUnretained(event)
        }
        if event.getIntegerValueField(.eventSourceUserData) == Self.eventTag {
            return Unmanaged.passUnretained(event)
        }
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        if type == .flagsChanged && code == 61 {
            // NX_DEVICERALTKEYMASK differentiates Right Option even when Left Option is also down.
            let down = event.flags.rawValue & 0x40 != 0
            let changed = lock.withLock { () -> Bool in
                guard down != held else { return false }; held = down; return true
            }
            if changed { if down { onHold() } else { onRelease() } }
            return nil
        }
        if (type == .keyDown || type == .keyUp) && code == 53 {
            if type == .keyDown { onEscape() }
            return nil
        }
        if code == 36 || code == 76 {
            if type == .keyUp && consumingEnter { consumingEnter = false; return nil }
            if type == .keyDown && consumingEnter { return nil }
            if type == .keyDown && event.getIntegerValueField(.keyboardEventAutorepeat) == 0
                && event.getIntegerValueField(.eventSourceUnixProcessID) == 0 && onPhysicalEnter() {
                consumingEnter = true; return nil
            }
        }
        if type != .keyUp { onInteraction() }
        return Unmanaged.passUnretained(event)
    }
}
