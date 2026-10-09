import AppKit
import ApplicationServices
import Foundation
import VoiceControlCore

/// AX handles and literal field contents never leave this local module.
/// AX reads run on one queue; the small state lock protects invalidation only.
public final class NativeObservationProvider: ObservationProvider, @unchecked Sendable {
    private let queue = DispatchQueue(label: "VoiceControl.accessibility", qos: .userInitiated)
    private let stateLock = NSLock()
    private var epoch: UInt64 = 0
    private var snapshot: NativeSnapshot?
    private var identitySnapshot: NativeSnapshot?
    private var changeMonitor: NativeAXMonitor?
    private var activationMonitor: NSObjectProtocol?
    public init() {}

    deinit {
        if let changeMonitor {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(changeMonitor.observer), .commonModes)
        }
        if let activationMonitor { NSWorkspace.shared.notificationCenter.removeObserver(activationMonitor) }
    }

    public func invalidate() {
        stateLock.withLock { epoch &+= 1; snapshot = nil }
    }

    /// Call from the shell's event tap for physical interactions. Consumed hold,
    /// Escape and confirmation events are handled by the shell before this call.
    public func noteManualInteraction() { invalidate() }

    func currentEpoch() -> UInt64 { stateLock.withLock { epoch } }

    public func observe() async throws -> Observation {
        await installChangeMonitoring()
        return try await onQueue {
            guard AXIsProcessTrusted() else { throw ControlError.permissionDenied }
            let startEpoch = self.currentEpoch()
            let context = try AXRead.frontmost()
            let id = UUID()
            let previous = self.stateLock.withLock { self.identitySnapshot }
            let sameWindow = previous.map { $0.pid == context.pid && CFEqual($0.window, context.window) } ?? false
            let windowID = sameWindow ? previous!.observation.windowID : UUID().uuidString
            let windowBounds = try AXRead.bounds(context.window)
            var records: [UUID: NativeTarget] = [:]
            var references: [TargetReference] = []
            var visited = Set<CFHashCode>()
            var remaining = 800
            let deadline = ProcessInfo.processInfo.systemUptime + 0.8
            func walk(_ element: AXUIElement, depth: Int) {
                guard depth <= 18, remaining > 0,
                      ProcessInfo.processInfo.systemUptime < deadline else { return }
                remaining -= 1
                // Hash collisions only omit a target; they cannot select the wrong one.
                guard visited.insert(CFHash(element)).inserted else { return }
                AXUIElementSetMessagingTimeout(element, 0.03)
                let role = AXRead.string(element, kAXRoleAttribute)
                if AXRead.interestingRoles.contains(role),
                   AXRead.bool(element, kAXEnabledAttribute) == true,
                   AXRead.bool(element, "AXHidden") != true,
                   let bounds = try? AXRead.bounds(element),
                   AXRead.visible(element, bounds: bounds, windowBounds: windowBounds) {
                    let label = AXRead.label(element, role: role)
                    let editable = AXRead.editableRoles.contains(role)
                        && AXRead.string(element, kAXSubroleAttribute) != "AXSecureTextField"
                    let oldIdentity = sameWindow ? previous?.records.values.first {
                        CFEqual($0.element, element) && $0.reference.role == role
                    }?.reference.targetID : nil
                    let ref = TargetReference(observationID: id, targetID: oldIdentity ?? UUID(),
                        applicationID: context.bundleID, windowID: windowID,
                        role: role, label: label, bounds: bounds, isEditable: editable)
                    references.append(ref)
                    records[ref.targetID] = NativeTarget(reference: ref, element: element)
                }
                // Bound the child array before crossing the application boundary.
                var children: CFArray?
                if AXUIElementCopyAttributeValues(element, kAXChildrenAttribute as CFString,
                    0, min(remaining, 120), &children) == .success,
                   let nodes = children as? [AXUIElement] {
                    for child in nodes { walk(child, depth: depth + 1) }
                }
            }
            walk(context.window, depth: 0)
            let result = Observation(id: id, applicationID: context.bundleID,
                                     windowID: windowID, targets: references)
            let stored = NativeSnapshot(observation: result, epoch: startEpoch,
                pid: context.pid, window: context.window, windowBounds: windowBounds,
                records: records)
            let accepted = self.stateLock.withLock {
                guard self.epoch == startEpoch else { return false }
                self.snapshot = stored
                self.identitySnapshot = stored
                return true
            }
            guard accepted else { throw ControlError.staleTarget }
            return result
        }
    }

    /// AX notifications supply invalidation for window movement/navigation that
    /// is not caused by a physical event. Unsupported notifications fail closed
    /// at the subsequent fresh validation, rather than enabling a coordinate fallback.
    @MainActor private func installChangeMonitoring() {
        if activationMonitor == nil {
            activationMonitor = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
            ) { [weak self] _ in self?.invalidate() }
        }
        guard let context = try? AXRead.frontmost() else { return }
        if let monitor = changeMonitor, monitor.pid == context.pid, CFEqual(monitor.window, context.window) { return }
        if let old = changeMonitor {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(old.observer), .commonModes)
        }
        changeMonitor = nil
        var observer: AXObserver?
        let result = AXObserverCreate(context.pid, { _, _, _, refcon in
            guard let refcon else { return }
            Unmanaged<NativeObservationProvider>.fromOpaque(refcon).takeUnretainedValue().invalidate()
        }, &observer)
        guard result == .success, let observer else { return }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let app = AXUIElementCreateApplication(context.pid)
        AXUIElementSetMessagingTimeout(app, 0.03)
        AXObserverAddNotification(observer, app, kAXFocusedWindowChangedNotification as CFString, refcon)
        for name in [kAXMovedNotification, kAXResizedNotification, kAXUIElementDestroyedNotification, "AXLayoutChanged"] {
            AXObserverAddNotification(observer, context.window, name as CFString, refcon)
        }
        changeMonitor = NativeAXMonitor(pid: context.pid, window: context.window, observer: observer)
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
    }

    public func resolve(_ description: String, in observation: Observation) async -> TargetResolution {
        let query = Self.normalized(description)
        guard !query.isEmpty else { return .unavailable("Describe the target.") }
        guard stateLock.withLock({ snapshot?.observation.id == observation.id }) else {
            return .unavailable("The screen changed. Observe again.")
        }
        let wantsField = ["box", "field", "input", "area"].contains { query.contains($0) }
        let pool = observation.targets.filter { !wantsField || $0.isEditable }
        let exact = pool.filter { Self.normalized($0.label) == query }
        let filler: Set<String> = ["the", "a", "an", "box", "field", "input", "area", "button", "click", "focus"]
        let words = query.split(separator: " ").map(String.init).filter { !filler.contains($0) }
        let matches = !exact.isEmpty ? exact : pool.filter {
            let label = Self.normalized($0.label + " " + Self.roleLabel($0.role))
            return !words.isEmpty && words.allSatisfy { label.contains($0) }
        }
        guard !matches.isEmpty else { return .unavailable("No visible target matches that description.") }
        guard matches.count == 1, let target = matches.first else { return .ambiguous(matches) }
        // Freshness is checked again during validation, not assumed from matching.
        return .resolved(target)
    }

    static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }.joined(separator: " ")
    }
    static func roleLabel(_ role: String) -> String {
        switch role {
        case "AXSearchField": "search"
        case "AXTextField": "text"
        case "AXTextArea": "text"
        case "AXButton": "button"
        case "AXScrollArea": "scroll"
        default: ""
        }
    }

    func checkedTarget(_ reference: TargetReference) async throws -> NativeCheckedTarget {
        try await onQueue {
            guard AXIsProcessTrusted() else { throw ControlError.permissionDenied }
            guard let state = self.stateLock.withLock({ self.snapshot }),
                  state.observation.id == reference.observationID,
                  let record = state.records[reference.targetID],
                  record.reference == reference else { throw ControlError.staleTarget }
            let now = try AXRead.frontmost()
            guard now.pid == state.pid, now.bundleID == reference.applicationID,
                  CFEqual(now.window, state.window),
                  try AXRead.bounds(now.window) == state.windowBounds,
                  AXRead.string(record.element, kAXRoleAttribute) == reference.role,
                  AXRead.label(record.element, role: reference.role) == reference.label,
                  AXRead.bool(record.element, kAXEnabledAttribute) == true,
                  AXRead.bool(record.element, "AXHidden") != true,
                  try AXRead.bounds(record.element) == reference.bounds,
                  AXRead.visible(record.element, bounds: reference.bounds, windowBounds: state.windowBounds),
                  self.currentEpoch() == state.epoch else { throw ControlError.staleTarget }
            return NativeCheckedTarget(element: record.element, epoch: state.epoch,
                focused: AXRead.bool(record.element, kAXFocusedAttribute) == true,
                focusSettable: AXRead.focusSettable(record.element),
                selection: AXRead.selection(record.element),
                value: AXRead.attribute(record.element, kAXValueAttribute) as? String)
        }
    }

    func readValue(_ reference: TargetReference) async throws -> String? {
        try await checkedTarget(reference).value
    }

    func frontmostBundleID() async throws -> String {
        try await onQueue { try AXRead.frontmost().bundleID }
    }

    private func onQueue<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try body() }) }
        }
    }
}

struct NativeTarget { let reference: TargetReference; let element: AXUIElement }
struct NativeAXMonitor { let pid: pid_t; let window: AXUIElement; let observer: AXObserver }
struct NativeSnapshot: @unchecked Sendable {
    let observation: Observation
    let epoch: UInt64
    let pid: pid_t
    let window: AXUIElement
    let windowBounds: ScreenRect
    let records: [UUID: NativeTarget]
}
struct NativeCheckedTarget: @unchecked Sendable {
    let element: AXUIElement
    let epoch: UInt64
    let focused: Bool
    let focusSettable: Bool
    let selection: CFRange?
    let value: String?
}

enum AXRead {
    static let editableRoles: Set<String> = ["AXTextField", "AXTextArea", "AXSearchField"]
    static let interestingRoles = editableRoles.union(["AXButton", "AXLink", "AXScrollArea", "AXCheckBox", "AXRadioButton"])
    static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }
    static func string(_ element: AXUIElement, _ name: String) -> String { attribute(element, name) as? String ?? "" }
    static func bool(_ element: AXUIElement, _ name: String) -> Bool? { (attribute(element, name) as? NSNumber)?.boolValue }
    static func focusSettable(_ element: AXUIElement) -> Bool {
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, kAXFocusedAttribute as CFString, &settable) == .success
            && settable.boolValue
    }
    static func element(_ value: CFTypeRef?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }
    static func label(_ element: AXUIElement, role: String) -> String {
        // Do not turn text values, passwords or window titles into target labels.
        for name in [kAXTitleAttribute, kAXDescriptionAttribute, "AXPlaceholderValue"] {
            let value = string(element, name)
            if !value.isEmpty { return value }
        }
        return NativeObservationProvider.roleLabel(role)
    }
    static func frontmost() throws -> (pid: pid_t, bundleID: String, window: AXUIElement) {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.03)
        guard let app = element(attribute(system, kAXFocusedApplicationAttribute)) else { throw ControlError.staleTarget }
        AXUIElementSetMessagingTimeout(app, 0.03)
        var pid: pid_t = 0
        guard AXUIElementGetPid(app, &pid) == .success,
              let bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier,
              let window = element(attribute(app, kAXFocusedWindowAttribute)) else { throw ControlError.staleTarget }
        AXUIElementSetMessagingTimeout(window, 0.03)
        return (pid, bundleID, window)
    }
    static func bounds(_ element: AXUIElement) throws -> ScreenRect {
        guard let p = attribute(element, kAXPositionAttribute), let s = attribute(element, kAXSizeAttribute),
              CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { throw ControlError.staleTarget }
        var point = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(p as! AXValue, .cgPoint, &point),
              AXValueGetValue(s as! AXValue, .cgSize, &size),
              point.x.isFinite, point.y.isFinite, size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0 else { throw ControlError.staleTarget }
        return ScreenRect(x: point.x, y: point.y, width: size.width, height: size.height)
    }
    static func selection(_ element: AXUIElement) -> CFRange? {
        guard let value = attribute(element, kAXSelectedTextRangeAttribute),
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        return AXValueGetValue(value as! AXValue, .cfRange, &range) ? range : nil
    }
    static func visible(_ target: AXUIElement, bounds: ScreenRect, windowBounds: ScreenRect) -> Bool {
        let center = CGPoint(x: bounds.center.x, y: bounds.center.y)
        guard CGRect(x: windowBounds.x, y: windowBounds.y, width: windowBounds.width,
                     height: windowBounds.height).contains(center) else { return false }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.03)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(center.x), Float(center.y), &hit) == .success else { return false }
        // The hit may be a child of an editable/scroll target.
        for _ in 0..<16 {
            guard let node = hit else { return false }
            if CFEqual(node, target) { return true }
            AXUIElementSetMessagingTimeout(node, 0.03)
            hit = element(attribute(node, kAXParentAttribute))
        }
        return false
    }
}
