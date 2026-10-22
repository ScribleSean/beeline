import AppKit
import ApplicationServices

enum Accessibility {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func requestAccess() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    enum Side {
        case left, right, full
    }

    static func windows(of apps: [NSRunningApplication], front: NSRunningApplication?) -> [Item] {
        guard isTrusted else { return [] }
        var items: [Item] = []
        for app in apps {
            let name = app.localizedName ?? ""
            let element = applicationElement(app)
            let windows: [AXUIElement] = attribute(element, kAXWindowsAttribute) ?? []
            let focused: AXUIElement? = app == front ? attribute(element, kAXFocusedWindowAttribute) : nil
            for (index, window) in windows.enumerated() {
                guard let title: String = attribute(window, kAXTitleAttribute), !title.isEmpty else { continue }
                let raise = {
                    AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
                    AXUIElementPerformAction(window, kAXRaiseAction as CFString)
                    // Both ways: macOS may ignore activate() from an app that is not itself active.
                    AXUIElementSetAttributeValue(element, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
                    app.activate()
                }
                var item = Item(id: "window:\(app.processIdentifier):\(index)", kind: .window, verb: "Switch to window",
                                title: title, subtitle: name, keywords: name, icon: app.icon, run: raise)
                item.isCurrentWindow = focused.map { CFEqual($0, window) } ?? false
                item.target = { frame(of: window) }
                item.tile = { side in
                    raise()
                    place(window, side)
                }
                items.append(item)
            }
        }
        return items
    }

    static func openAndPlace(_ url: URL, _ side: Side) {
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { app, _ in
            guard let app else { return }
            DispatchQueue.global(qos: .userInitiated).async {
                let element = applicationElement(app)
                for _ in 0..<25 {
                    let windows: [AXUIElement] = attribute(element, kAXWindowsAttribute) ?? []
                    if let window = windows.first {
                        DispatchQueue.main.async {
                            app.activate()
                            place(window, side)
                        }
                        return
                    }
                    Thread.sleep(forTimeInterval: 0.2)
                }
            }
        }
    }

    private static func place(_ window: AXUIElement, _ side: Side) {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main,
              let primary = NSScreen.screens.first else { return }
        let usable = screen.visibleFrame
        // Accessibility measures from the top left of the primary screen; AppKit from its bottom left.
        var origin = CGPoint(x: usable.minX, y: primary.frame.height - usable.maxY)
        var size = usable.size
        if side != .full { size.width /= 2 }
        if side == .right { origin.x += size.width }

        guard let position = AXValueCreate(.cgPoint, &origin), let extent = AXValueCreate(.cgSize, &size) else { return }
        let before = frame(of: window)
        setFrame(window, position, extent)
        if let before {
            let title: String = attribute(window, kAXTitleAttribute) ?? ""
            let name = title.isEmpty ? "the window" : "“\(title.prefix(40))”"
            let place = side == .full ? "fill the screen" : "the \(side == .left ? "left" : "right") half"
            UndoLog.shared.record(side == .full ? "Make \(name) \(place)" : "Move \(name) to \(place)") {
                var oldOrigin = before.origin, oldSize = before.size
                guard let position = AXValueCreate(.cgPoint, &oldOrigin), let extent = AXValueCreate(.cgSize, &oldSize) else { return }
                setFrame(window, position, extent)
            }
        }
    }

    private static func setFrame(_ window: AXUIElement, _ position: AXValue, _ extent: AXValue) {
        AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, position)
        AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, extent)
        // Some apps clamp the first move to their old size, so the position is set again after resizing.
        AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, position)
    }

    static func menuCommands(of app: NSRunningApplication) -> [Item] {
        guard isTrusted else { return [] }
        let name = app.localizedName ?? ""
        let appElement = applicationElement(app)
        guard let menuBar: AXUIElement = attribute(appElement, kAXMenuBarAttribute) else { return [] }
        let scannedWindow: AXUIElement? = attribute(appElement, kAXFocusedWindowAttribute)

        var items: [Item] = []
        let deadline = Date().addingTimeInterval(0.8)

        func walk(_ element: AXUIElement, path: [String], depth: Int) {
            let children: [AXUIElement] = attribute(element, kAXChildrenAttribute) ?? []
            for (position, child) in children.enumerated() {
                guard items.count < 1500, Date() < deadline else { return }
                let role: String = attribute(child, kAXRoleAttribute) ?? ""
                if role == (kAXMenuRole as String) {
                    walk(child, path: path, depth: depth)
                    continue
                }
                guard let title: String = attribute(child, kAXTitleAttribute), !title.isEmpty else { continue }
                let submenu: [AXUIElement] = attribute(child, kAXChildrenAttribute) ?? []
                if !submenu.isEmpty {
                    if depth < 3 { walk(child, path: path + [title], depth: depth + 1) }
                } else if attribute(child, kAXEnabledAttribute) ?? true {
                    let location = ([name] + path).joined(separator: " › ")
                    // Two Finder windows on Downloads give the Window menu two items with one title.
                    var item = Item(id: "menu:\(app.processIdentifier):\(location):\(position):\(title)", kind: .menu, verb: "Run",
                                    title: title, subtitle: location, keywords: path.joined(separator: " "), icon: app.icon) {
                        AXUIElementPerformAction(child, kAXPressAction as CFString)
                    }
                    item.needsConfirm = isIrreversible(title)
                    let pid = app.processIdentifier
                    item.stillValid = {
                        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return false }
                        let element = AXUIElementCreateApplication(pid)
                        AXUIElementSetMessagingTimeout(element, 0.25)
                        guard sameWindow(scannedWindow, attribute(element, kAXFocusedWindowAttribute)) else { return false }
                        let current: String? = attribute(child, kAXTitleAttribute)
                        let enabled: Bool = attribute(child, kAXEnabledAttribute) ?? true
                        return current == title && enabled
                    }
                    items.append(item)
                }
            }
        }
        let menus: [AXUIElement] = attribute(menuBar, kAXChildrenAttribute) ?? []
        for menu in menus.dropFirst() {
            guard let title: String = attribute(menu, kAXTitleAttribute), !title.isEmpty else { continue }
            let first = items.count
            walk(menu, path: [title], depth: 1)
            for index in first..<items.count { items[index].target = { frame(of: menu) } }
        }
        return items
    }

    static func sameWindow(_ a: AXUIElement?, _ b: AXUIElement?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (a?, b?): return CFEqual(a, b)
        default: return false
        }
    }

    static func isFrontWindow(_ window: AXUIElement, of pid: pid_t) -> Bool {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return false }
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, 0.25)
        guard let focused: AXUIElement = attribute(element, kAXFocusedWindowAttribute) else { return false }
        return CFEqual(focused, window)
    }

    static func applicationElement(_ app: NSRunningApplication) -> AXUIElement {
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.25)
        return element
    }

    static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? T
    }
}
