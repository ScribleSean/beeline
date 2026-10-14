import AppKit
import ApplicationServices

/// Reads the controls inside the front window (buttons, links, checkboxes, fields) so one can be
/// pressed by typing its name. Pruned the way typesafe-computer-use measured to be necessary:
/// off-window frames, slivers and closed menus are skipped, and the walk stops at 4000 nodes or 0.6 s.
extension Accessibility {
    private static let roles: [String: (verb: String, noun: String)] = [
        "AXButton": ("Press", "button"),
        "AXCheckBox": ("Toggle", "checkbox"),
        "AXRadioButton": ("Choose", "option"),
        "AXPopUpButton": ("Open", "pop-up menu"),
        "AXMenuButton": ("Open", "menu button"),
        "AXLink": ("Open link", "link"),
        "AXTextField": ("Go to", "field"),
        "AXSearchField": ("Go to", "search field"),
        "AXTextArea": ("Go to", "text area"),
        "AXComboBox": ("Go to", "field"),
        "AXDisclosureTriangle": ("Toggle", "disclosure"),
    ]

    /// Labels that mean the press cannot be taken back. These need Return twice.
    private static let irreversible = [
        "delete", "remove", "discard", "erase", "trash", "send", "buy", "pay", "purchase", "order", "submit",
        "unsubscribe", "sign out", "log out", "reset", "clear", "uninstall", "erase disk", "publish", "post", "confirm",
    ]

    private static let fieldRoles: Set<String> = ["AXTextField", "AXSearchField", "AXTextArea", "AXComboBox"]

    /// Apps already asked to build their accessibility tree. Asked once per process.
    private static var askedForTree = Set<pid_t>()
    private static let askedLock = NSLock()

    static func controls(of app: NSRunningApplication) -> [Item] {
        guard isTrusted else { return [] }
        let started = Date()
        let element = applicationElement(app)
        let windows: [AXUIElement] = attribute(element, kAXWindowsAttribute) ?? []
        guard let window: AXUIElement = attribute(element, kAXFocusedWindowAttribute) ?? windows.first,
              let windowFrame = frame(of: window) else { return [] }

        var found: [(element: AXUIElement, role: String, subrole: String, label: String, frame: CGRect)] = []
        var visited = 0
        var deadline = started.addingTimeInterval(0.6)

        func walk(_ node: AXUIElement, depth: Int) {
            guard visited < 4000, depth < 40, Date() < deadline else { return }
            visited += 1
            let role: String = attribute(node, kAXRoleAttribute) ?? ""
            // A closed menu hides thousands of zero-sized items.
            if role == kAXMenuRole || role == kAXMenuBarRole { return }
            let box = frame(of: node)
            // Containers often report an empty frame while their children are real, so only a container with
            // a genuine size that lies wholly outside the window is skipped with everything inside it.
            if let box, box.width > 0, box.height > 0, !box.intersects(windowFrame) { return }
            // A control must be visible in the window and big enough to be a real target; Chromium leaves
            // scrolled-out nodes behind as slivers.
            if roles[role] != nil, let box, box.width >= 4, box.height >= 4, box.intersects(windowFrame),
               let label = label(of: node, role: role) {
                found.append((node, role, attribute(node, kAXSubroleAttribute) ?? "", label, box))
                // A control's insides (its icon, its text) are part of it, not separate controls.
                return
            }
            let children: [AXUIElement] = attribute(node, kAXChildrenAttribute) ?? []
            for child in children { walk(child, depth: depth + 1) }
        }
        walk(window, depth: 0)

        // Electron and Chromium apps (Claude, Slack, VS Code) expose almost nothing until a screen reader
        // asks for the full tree through this flag. Ask once, give the app a moment, and look again.
        askedLock.lock()
        let firstAsk = askedForTree.insert(app.processIdentifier).inserted
        askedLock.unlock()
        if visited < 60, firstAsk,
           AXUIElementSetAttributeValue(element, "AXManualAccessibility" as CFString, kCFBooleanTrue) == .success {
            Thread.sleep(forTimeInterval: 0.35)
            deadline = Date().addingTimeInterval(0.6)
            found.removeAll()
            visited = 0
            walk(window, depth: 0)
        }

        // A label that appears more than once gets where it sits, so the two can be told apart.
        var counts: [String: Int] = [:]
        for control in found { counts[control.role + control.label, default: 0] += 1 }
        var seen = Set<String>()
        let appName = app.localizedName ?? ""

        let items: [Item] = found.enumerated().compactMap { index, control in
            let repeated = (counts[control.role + control.label] ?? 0) > 1
            let place = repeated ? " · " + region(of: control.frame, in: windowFrame) : ""
            guard seen.insert(control.role + control.label + place).inserted else { return nil }
            var (verb, noun) = roles[control.role]!
            if control.subrole == "AXTabButton" { (verb, noun) = ("Switch to", "section") }
            let node = control.element
            let isField = fieldRoles.contains(control.role)
            var item = Item(id: "control:\(app.processIdentifier):\(index)", kind: .control, verb: verb, title: control.label,
                            subtitle: noun + place, keywords: noun + " " + appName, icon: app.icon) {
                if isField {
                    AXUIElementSetAttributeValue(node, kAXFocusedAttribute as CFString, kCFBooleanTrue)
                } else {
                    AXUIElementPerformAction(node, kAXPressAction as CFString)
                }
            }
            // Whole words only: "Reorder" is not "order", and "Paint format" is not "format a disk".
            let words = " " + control.label.lowercased().split(whereSeparator: { !$0.isLetter }).joined(separator: " ") + " "
            item.needsConfirm = !isField && irreversible.contains { words.contains(" \($0) ") }
            return item
        }
        Log.append(String(format: "controls: %d in %@ from %d nodes in %.0f ms", items.count, appName, visited,
                          Date().timeIntervalSince(started) * 1000))
        return items
    }

    /// The words a person would use for the control: its title, description, placeholder, or the text inside it.
    private static func label(of node: AXUIElement, role: String) -> String? {
        var candidates: [String?] = [attribute(node, kAXTitleAttribute), attribute(node, kAXDescriptionAttribute)]
        if fieldRoles.contains(role) {
            candidates.append(attribute(node, kAXPlaceholderValueAttribute))
        } else if let value: String = attribute(node, kAXValueAttribute), value.count <= 60 {
            candidates.append(value)
        }
        // An icon button often carries its name on the image or text inside it.
        let children: [AXUIElement] = attribute(node, kAXChildrenAttribute) ?? []
        for child in children.prefix(4) {
            candidates.append(attribute(child, kAXValueAttribute) as String?)
            candidates.append(attribute(child, kAXDescriptionAttribute) as String?)
            candidates.append(attribute(child, kAXTitleAttribute) as String?)
        }
        candidates.append(attribute(node, kAXHelpAttribute))
        for case let text? in candidates {
            let cleaned = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            if cleaned.contains(where: \.isLetter) { return String(cleaned.prefix(80)) }
        }
        return nil
    }

    private static func frame(of node: AXUIElement) -> CGRect? {
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard let position: AXValue = attribute(node, kAXPositionAttribute),
              let extent: AXValue = attribute(node, kAXSizeAttribute),
              AXValueGetValue(position, .cgPoint, &origin), AXValueGetValue(extent, .cgSize, &size) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    private static func region(of box: CGRect, in window: CGRect) -> String {
        let x = (box.midX - window.minX) / max(window.width, 1)
        let y = (box.midY - window.minY) / max(window.height, 1)
        let row = y < 0.33 ? "top" : y < 0.67 ? "middle" : "bottom"
        let column = x < 0.33 ? "left" : x < 0.67 ? "centre" : "right"
        return row == "middle" && column == "centre" ? "centre" : "\(row) \(column)"
    }
}
