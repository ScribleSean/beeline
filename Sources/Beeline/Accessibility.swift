import AppKit
import ApplicationServices

/// Reads what is on screen through the macOS Accessibility API: open windows and the
/// menu commands of an app. Needs the Accessibility permission; returns nothing without it.
enum Accessibility {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt that sends the user to Privacy & Security to allow Beeline.
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
                    app.activate()
                }
                var item = Item(id: "window:\(app.processIdentifier):\(index)", kind: .window, verb: "Switch to window",
                                title: title, subtitle: name, keywords: name, icon: app.icon, run: raise)
                item.isCurrentWindow = focused.map { CFEqual($0, window) } ?? false
                item.tile = { side in
                    raise()
                    place(window, side)
                }
                items.append(item)
            }
        }
        return items
    }

    /// Opens an app, waits for its window to appear, and places it. For apps with no window open yet.
    static func openAndPlace(_ url: URL, _ side: Side) {
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { app, _ in
            guard let app else { return }
            DispatchQueue.global(qos: .userInitiated).async {
                let element = applicationElement(app)
                // A cold launch can take a few seconds to show its first window.
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

    /// Moves and resizes a window to half of, or all of, the usable area of the screen the pointer is on.
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
        AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, position)
        AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, extent)
        // Some apps clamp the first move to their old size, so the position is set again after resizing.
        AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, position)
    }

    /// Every enabled command in the app's menu bar, as "Run Export as PDF…  [Safari › File]".
    static func menuCommands(of app: NSRunningApplication) -> [Item] {
        guard isTrusted else { return [] }
        let name = app.localizedName ?? ""
        guard let menuBar: AXUIElement = attribute(applicationElement(app), kAXMenuBarAttribute) else { return [] }

        var items: [Item] = []
        let deadline = Date().addingTimeInterval(0.8)

        func walk(_ element: AXUIElement, path: [String], depth: Int) {
            let children: [AXUIElement] = attribute(element, kAXChildrenAttribute) ?? []
            for child in children {
                // Big dynamic menus (History, Bookmarks) can hold thousands of entries.
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
                    var item = Item(id: "menu:\(app.processIdentifier):\(location):\(title)", kind: .menu, verb: "Run",
                                    title: title, subtitle: location, keywords: path.joined(separator: " "), icon: app.icon) {
                        AXUIElementPerformAction(child, kAXPressAction as CFString)
                    }
                    // Menu commands like Delete or Send ask for Return twice, as buttons do.
                    item.needsConfirm = isIrreversible(title)
                    item.stillValid = {
                        let current: String? = attribute(child, kAXTitleAttribute)
                        let enabled: Bool = attribute(child, kAXEnabledAttribute) ?? false
                        return current == title && enabled
                    }
                    items.append(item)
                }
            }
        }
        // The Apple menu is skipped: Beeline's own actions cover sleep, restart and the rest, and its
        // Recent Items list only repeats apps and files as noise ("Run Stremio").
        let menus: [AXUIElement] = attribute(menuBar, kAXChildrenAttribute) ?? []
        for menu in menus.dropFirst() {
            guard let title: String = attribute(menu, kAXTitleAttribute), !title.isEmpty else { continue }
            walk(menu, path: [title], depth: 1)
        }
        return items
    }

    static func applicationElement(_ app: NSRunningApplication) -> AXUIElement {
        let element = AXUIElementCreateApplication(app.processIdentifier)
        // A hung app must not stall the whole scan.
        AXUIElementSetMessagingTimeout(element, 0.25)
        return element
    }

    static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? T
    }
}
