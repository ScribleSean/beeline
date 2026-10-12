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

    static func windows(of apps: [NSRunningApplication]) -> [Item] {
        guard isTrusted else { return [] }
        var items: [Item] = []
        for app in apps {
            let name = app.localizedName ?? ""
            let element = applicationElement(app)
            let windows: [AXUIElement] = attribute(element, kAXWindowsAttribute) ?? []
            for (index, window) in windows.enumerated() {
                guard let title: String = attribute(window, kAXTitleAttribute), !title.isEmpty, title != name else { continue }
                items.append(Item(id: "window:\(app.processIdentifier):\(index)", kind: .window, verb: "Switch to window",
                                  title: title, subtitle: name, keywords: name, icon: app.icon) {
                    AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
                    AXUIElementPerformAction(window, kAXRaiseAction as CFString)
                    app.activate()
                })
            }
        }
        return items
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
                    items.append(Item(id: "menu:\(app.processIdentifier):\(location):\(title)", kind: .menu, verb: "Run",
                                      title: title, subtitle: location, keywords: path.joined(separator: " "), icon: app.icon) {
                        AXUIElementPerformAction(child, kAXPressAction as CFString)
                    })
                }
            }
        }
        walk(menuBar, path: [], depth: 0)
        return items
    }

    private static func applicationElement(_ app: NSRunningApplication) -> AXUIElement {
        let element = AXUIElementCreateApplication(app.processIdentifier)
        // A hung app must not stall the whole scan.
        AXUIElementSetMessagingTimeout(element, 0.25)
        return element
    }

    private static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? T
    }
}
