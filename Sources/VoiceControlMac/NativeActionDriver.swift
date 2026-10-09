import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import VoiceControlCore

/// Only the serial executor may call perform/releaseHeldInputs. Preparation and
/// verification never post input. Every prepared step posts at most one event.
public final class NativeActionDriver: ActionDriver, @unchecked Sendable {
    public static let eventTag: Int64 = 0x5643_4F4E_5452_4F4C
    private let observations: NativeObservationProvider
    private let lock = NSLock()
    private var prepared: NativePlan?
    private var heldKeys = Set<CGKeyCode>()
    private var heldMouse: CGPoint?

    public init(observations: NativeObservationProvider) { self.observations = observations }

    public func validate(_ action: BoundedAction) async -> Bool {
        guard AXIsProcessTrusted() else { return false }
        switch action {
        case let .activateApplication(bundleID):
            return !bundleID.isEmpty && NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .contains { !$0.isTerminated }
        case .deleteText, .sendMessage, .spend:
            // Exact effect adapters and approvals are required before these exist.
            return false
        default:
            guard let reference = action.target,
                  let target = try? await observations.checkedTarget(reference) else { return false }
            switch action {
            case .focus, .click:
                return reference.isEditable && target.focusSettable
            case let .insertText(_, text):
                // Never silently replace a selection. Fail closed when unavailable.
                return reference.isEditable && target.focused && target.selection?.length == 0
                    && Self.allowedText(text)
            case let .scroll(_, vertical):
                return vertical != 0 && vertical >= -600 && vertical <= 600
            case .movePointer: return true
            default: return false
            }
        }
    }

    public func prepare(_ action: BoundedAction) async throws -> [PreparedStep] {
        guard AXIsProcessTrusted() else { throw ControlError.permissionDenied }
        // Clear the prior operation before doing AX work; stale preparations cannot run.
        lock.withLock { prepared = nil }
        let epoch = observations.currentEpoch()
        var target: NativeCheckedTarget?
        if let reference = action.target { target = try await observations.checkedTarget(reference) }
        var steps: [PreparedStep] = []
        var application: NSRunningApplication?
        var expectedValue: String?
        switch action {
        case let .activateApplication(bundleID):
            guard !bundleID.isEmpty,
                  let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                    .first(where: { !$0.isTerminated }) else { throw ControlError.unsupportedAction }
            application = app
            steps = [.activateApplication(bundleID)]
        case let .focus(reference), let .click(reference):
            // Generic clicks have unclassified effects and are refused. An editable
            // field click is implemented as AX focus, so it cannot activate a button.
            guard reference.isEditable, let target, target.focusSettable else {
                throw ControlError.unsupportedAction
            }
            steps = [.focus(reference)]
        case let .movePointer(reference):
            steps = [.event(.move(reference.bounds.center))]
        case let .scroll(reference, vertical):
            guard vertical != 0, vertical >= -600, vertical <= 600 else { throw ControlError.invalidInput }
            steps.append(.event(.move(reference.bounds.center)))
            var remaining = vertical
            while remaining != 0 {
                let chunk = min(20, max(-20, remaining))
                steps.append(.event(.scroll(chunk)))
                remaining -= chunk
            }
        case let .insertText(reference, text):
            guard reference.isEditable, let target, target.focused,
                  let selection = target.selection, selection.length == 0,
                  selection.location >= 0, Self.allowedText(text) else { throw ControlError.invalidInput }
            if let before = target.value, selection.location <= (before as NSString).length {
                expectedValue = (before as NSString).replacingCharacters(
                    in: NSRange(location: selection.location, length: 0), with: text)
            }
            // A scalar preserves surrogate pairs; down and up are separate dispatch
            // boundaries. Grapheme clusters may be partially typed when cancelled.
            for scalar in text.unicodeScalars {
                let piece = String(scalar)
                steps.append(.event(.unicodeDown(piece)))
                steps.append(.event(.unicodeUp))
            }
        case .deleteText, .sendMessage, .spend:
            throw ControlError.unsupportedAction
        }
        guard observations.currentEpoch() == epoch else { throw ControlError.staleTarget }
        let source = CGEventSource(stateID: .privateState)
        guard let source else { throw ControlError.dispatchFailed }
        source.userData = Self.eventTag
        let native = try steps.map { step -> NativeStep in
            if case let .event(event) = step {
                return NativeStep(step: step, event: try Self.makeEvent(event, source: source))
            }
            return NativeStep(step: step, event: nil)
        }
        lock.withLock {
            prepared = NativePlan(action: action, epoch: epoch, steps: native,
                target: target, application: application, expectedValue: expectedValue)
        }
        return steps
    }

    public func perform(_ step: PreparedStep) throws {
        do {
            try lock.withLock {
                guard var plan = prepared, plan.next < plan.steps.count,
                      plan.steps[plan.next].step == step,
                      observations.currentEpoch() == plan.epoch else { throw ControlError.staleTarget }
                guard AXIsProcessTrusted() else { throw ControlError.permissionDenied }
                let native = plan.steps[plan.next]
                switch step {
                case .activateApplication:
                    guard let application = plan.application,
                          application.activate(options: []) else { throw ControlError.dispatchFailed }
                case .focus:
                    guard let target = plan.target,
                          AXUIElementSetAttributeValue(target.element, kAXFocusedAttribute as CFString,
                              kCFBooleanTrue) == .success else { throw ControlError.dispatchFailed }
                case let .event(input):
                    guard let event = native.event else { throw ControlError.dispatchFailed }
                    // The root cancellation gate surrounds this single post.
                    event.post(tap: .cghidEventTap)
                    switch input {
                    case .unicodeDown: heldKeys.insert(0)
                    case .unicodeUp: heldKeys.remove(0)
                    case let .keyDown(code): heldKeys.insert(code)
                    case let .keyUp(code): heldKeys.remove(code)
                    case let .mouseDown(point): heldMouse = CGPoint(x: point.x, y: point.y)
                    case .mouseUp: heldMouse = nil
                    default: break
                    }
                }
                plan.next += 1
                prepared = plan
            }
        } catch {
            releaseHeldInputs()
            throw error
        }
    }

    public func verify(_ action: BoundedAction) async -> Verification {
        guard let plan = lock.withLock({ prepared }), plan.action == action,
              plan.next == plan.steps.count else { return .unknown }
        switch action {
        case let .activateApplication(bundleID):
            let verified = (try? await observations.frontmostBundleID()) == bundleID
            observations.invalidate()
            return verified ? .verified : .unknown
        case let .focus(reference), let .click(reference):
            guard let target = try? await observations.checkedTarget(reference) else { return .unknown }
            return target.focused ? .verified : .failed
        case let .movePointer(reference):
            guard let location = CGEvent(source: nil)?.location else { return .unknown }
            let center = reference.bounds.center
            return abs(location.x - center.x) <= 2 && abs(location.y - center.y) <= 2 ? .verified : .failed
        case let .insertText(reference, _):
            guard let expected = plan.expectedValue,
                  let value = try? await observations.readValue(reference) else { return .unknown }
            // A mismatch is unknown: the app may still be processing queued events.
            return value == expected ? .verified : .unknown
        case .scroll:
            observations.invalidate()
            // Posting is not proof of scrolling. No adapter-specific result yet.
            return .unknown
        case .deleteText, .sendMessage, .spend: return .failed
        }
    }

    public func releaseHeldInputs() {
        lock.withLock {
            let source = CGEventSource(stateID: .privateState)
            for key in heldKeys {
                let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
                Self.tag(event)?.post(tap: .cghidEventTap)
            }
            if let point = heldMouse {
                let event = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp,
                                    mouseCursorPosition: point, mouseButton: .left)
                Self.tag(event)?.post(tap: .cghidEventTap)
            }
            heldKeys.removeAll(); heldMouse = nil; prepared = nil
        }
    }

    private static func allowedText(_ text: String) -> Bool {
        // Newline/tab/control characters can submit a form or move focus.
        !text.isEmpty && text.utf16.count <= 4096
            && !text.unicodeScalars.contains {
                CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0)
            }
    }
    private static func tag(_ event: CGEvent?) -> CGEvent? {
        event?.flags = []
        event?.setIntegerValueField(.eventSourceUserData, value: eventTag)
        return event
    }
    private static func makeEvent(_ input: InputEvent, source: CGEventSource) throws -> CGEvent {
        let event: CGEvent?
        switch input {
        case let .move(point), let .mouseDown(point), let .mouseUp(point):
            let type: CGEventType
            switch input { case .move: type = .mouseMoved; case .mouseDown: type = .leftMouseDown; default: type = .leftMouseUp }
            event = CGEvent(mouseEventSource: source, mouseType: type,
                            mouseCursorPosition: CGPoint(x: point.x, y: point.y), mouseButton: .left)
            event?.setIntegerValueField(.mouseEventClickState, value: 1)
        case let .unicodeDown(text):
            event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
            let units = Array(text.utf16)
            units.withUnsafeBufferPointer {
                event?.keyboardSetUnicodeString(stringLength: $0.count, unicodeString: $0.baseAddress)
            }
        case .unicodeUp:
            event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
        case let .keyDown(key): event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true)
        case let .keyUp(key): event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        case let .scroll(amount):
            event = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 1,
                            wheel1: Int32(amount), wheel2: 0, wheel3: 0)
        }
        guard let result = tag(event) else { throw ControlError.dispatchFailed }
        return result
    }
}

private struct NativeStep { let step: PreparedStep; let event: CGEvent? }
private struct NativePlan: @unchecked Sendable {
    let action: BoundedAction
    let epoch: UInt64
    let steps: [NativeStep]
    let target: NativeCheckedTarget?
    let application: NSRunningApplication?
    let expectedValue: String?
    var next = 0
}
