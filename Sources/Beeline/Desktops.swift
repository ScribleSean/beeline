import AppKit
import ApplicationServices

/// "save desktop as tax work" remembers the open apps, their windows' places, the documents they show and
/// the browser tabs; "open tax work" brings them back. Names ignore case, and saving under a name that
/// exists replaces it. Restoring only opens and arranges: it never closes or quits anything.
enum Desktops {
    struct Window: Codable {
        var title: String
        var frame: CGRect
        /// The file a document window shows, when the app reports one.
        var document: String?
    }

    struct App: Codable {
        var name: String
        var path: String
        var bundleID: String?
        var windows: [Window]
        /// For browsers: each window's tab addresses, in order.
        var tabs: [[String]]?
        /// True when the app was hidden (⌘H) at the time, so it is hidden again on restore.
        var hidden: Bool?
    }

    struct Desktop: Codable {
        var name: String
        var saved: Date
        var apps: [App]
    }

    // Tests point this at a scratch file so they never touch real saved desktops.
    private static let file = ProcessInfo.processInfo.environment["BEELINE_DESKTOPS_FILE"].map { URL(fileURLWithPath: $0) }
        ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Beeline/desktops.json")

    /// Read from disk once, then kept: every keystroke checks saved desktops.
    private static var cache: [Desktop]?

    static func load() -> [Desktop] {
        if let cache { return cache }
        let read = JSONStore.read([Desktop].self, from: file, name: "desktops") ?? []
        cache = read
        return read
    }

    /// Forgets what was read, so the file is read again. Used by tests.
    static func reload() {
        cache = nil
    }

    private static func store(_ desktops: [Desktop]) {
        cache = desktops
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(desktops).write(to: file, options: .atomic)
    }

    /// The comparison key for a name: case and spacing do not matter.
    private static func key(_ name: String) -> String {
        name.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func cleaned(_ name: String) -> String {
        name.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    // MARK: Results

    /// Save, open and delete rows for what was typed, or nil when it is not about desktops.
    static func results(for query: String) -> [Item]? {
        let text = query.trimmingCharacters(in: .whitespaces)
        let lowered = text.lowercased()
        let saved = load()

        // Matched on the text itself, case-insensitively: lower-casing can change a string's length ("İ"
        // grows), so a range found in the lowered copy could run past the end of the original.
        if let match = text.firstMatch(of: try! Regex(#"^(?:save|store|remember)(?: this| my)? desktop(?: as)?\s+(.+)$"#).ignoresCase()),
           let range = match.output[1].range {
            let name = cleaned(String(text[range]))
            let existing = saved.first { key($0.name) == key(name) }
            let title = existing.map { "Replace saved desktop “\($0.name)”" } ?? "Save this desktop as “\(name)”"
            return [Item(id: "desktop-save", kind: .action, verb: "", title: title,
                         subtitle: existing == nil ? "Apps, windows, documents and tabs" : "Saved \(age(existing!.saved))",
                         keywords: "", icon: NSImage(systemSymbolName: "square.and.arrow.down", accessibilityDescription: nil)) {
                save(as: name)
            }]
        }

        if let match = text.firstMatch(of: try! Regex(#"^(?:delete|remove|forget) (?:saved )?desktop\s+(.+)$"#).ignoresCase()),
           let range = match.output[1].range {
            // Any word of the name will do, as for opening: "delete desktop work" finds "Tax work". With no
            // saved desktop matching ("remove desktop icons"), the words go on to the normal search.
            let words = key(String(text[range])).split(separator: " ")
            let matching = saved.filter { desktop in
                let nameWords = key(desktop.name).split(separator: " ")
                return words.allSatisfy { word in nameWords.contains { $0.hasPrefix(word) } }
            }
            guard !matching.isEmpty else { return nil }
            return matching.map { desktop in
                var item = Item(id: "desktop-delete:\(key(desktop.name))", kind: .action, verb: "Delete saved desktop",
                                title: desktop.name, subtitle: "Saved \(age(desktop.saved))", keywords: "",
                                icon: NSImage(systemSymbolName: "trash", accessibilityDescription: nil)) {
                    store(load().filter { key($0.name) != key(desktop.name) })
                }
                item.needsConfirm = true
                return item
            }
        }

        if lowered == "desktops" || lowered == "saved desktops" {
            return saved.sorted { $0.saved > $1.saved }.map(openItem)
        }
        return nil
    }

    /// One "Open desktop" row per saved desktop, searched like any other item ("tax" finds "Tax work").
    static func items() -> [Item] {
        load().map(openItem)
    }

    private static func openItem(_ desktop: Desktop) -> Item {
        let count = desktop.apps.count
        return Item(id: "desktop-open:\(key(desktop.name))", kind: .action, verb: "Open desktop", title: desktop.name,
                    subtitle: "\(count) \(count == 1 ? "app" : "apps") · saved \(age(desktop.saved))",
                    keywords: "saved desktop restore workspace", icon: NSImage(systemSymbolName: "macwindow.on.rectangle", accessibilityDescription: nil)) {
            restore(desktop)
        }
    }

    private static func age(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    // MARK: Saving

    private static func save(as name: String) {
        let own = NSRunningApplication.current
        // Hidden apps count too: a browser hidden with ⌘H still has the tabs you want back.
        let running = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && $0 != own }
        let previous = load().first { key($0.name) == key(name) }
        let trusted = Accessibility.isTrusted
        DispatchQueue.global(qos: .userInitiated).async {
            var apps: [App] = []
            var tabCount = 0
            var problems: [String] = []
            for app in running {
                guard let url = app.bundleURL else { continue }
                let element = Accessibility.applicationElement(app)
                let windows: [AXUIElement] = Accessibility.attribute(element, kAXWindowsAttribute) ?? []
                let saved: [Window] = windows.compactMap { window in
                    let minimized: Bool = Accessibility.attribute(window, kAXMinimizedAttribute) ?? false
                    guard !minimized, let frame = frame(of: window) else { return nil }
                    let document: String? = Accessibility.attribute(window, kAXDocumentAttribute)
                    return Window(title: Accessibility.attribute(window, kAXTitleAttribute) ?? "", frame: frame,
                                  document: document.flatMap { URL(string: $0)?.path })
                }
                let browser = Browser.all.first { $0.bundleID == app.bundleIdentifier }
                var tabs = browser?.tabAddresses()
                if let browser, tabs == nil {
                    // The browser could not be read. An earlier save of this desktop keeps its tabs; otherwise
                    // saving "no tabs" would look like success and only show at restore.
                    if let kept = previous?.apps.first(where: { $0.bundleID == browser.bundleID })?.tabs {
                        tabs = kept
                        Log.append("desktops: kept earlier tabs for \(browser.shortName)")
                    } else {
                        problems.append(browser.shortName)
                    }
                }
                tabCount += tabs?.reduce(0) { $0 + $1.count } ?? 0
                apps.append(App(name: app.localizedName ?? url.lastPathComponent, path: url.path, bundleID: app.bundleIdentifier,
                                windows: saved, tabs: tabs, hidden: app.isHidden ? true : nil))
            }
            DispatchQueue.main.async {
                guard problems.isEmpty else {
                    Actions.report("Couldn't read \(problems.joined(separator: " or "))'s tabs, so the desktop wasn't saved. "
                        + "Allow Beeline to control it in Privacy & Security › Automation, then try again.")
                    return
                }
                var desktops = load().filter { key($0.name) != key(name) }
                desktops.append(Desktop(name: name, saved: Date(), apps: apps))
                store(desktops)
                let windowCount = apps.reduce(0) { $0 + $1.windows.count }
                Log.append("desktops: saved \(apps.count) apps, \(windowCount) windows, \(tabCount) tabs")
                if !trusted {
                    Actions.report("Saved \(apps.count) apps and \(tabCount) tabs, but no window positions: allow Accessibility for Beeline to save those too.")
                }
            }
        }
    }

    private static func frame(of window: AXUIElement) -> CGRect? {
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard let position: AXValue = Accessibility.attribute(window, kAXPositionAttribute),
              let extent: AXValue = Accessibility.attribute(window, kAXSizeAttribute),
              AXValueGetValue(position, .cgPoint, &origin), AXValueGetValue(extent, .cgSize, &size) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    // MARK: Restoring

    private static func restore(_ desktop: Desktop) {
        for saved in desktop.apps {
            let url = URL(fileURLWithPath: saved.path)
            guard FileManager.default.fileExists(atPath: saved.path) else { continue }
            let documents = saved.windows.compactMap(\.document).map { URL(fileURLWithPath: $0) }
                .filter { FileManager.default.fileExists(atPath: $0.path) }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            let opened: (NSRunningApplication?, Error?) -> Void = { app, _ in
                guard let app else { return }
                if let tabs = saved.tabs, let browser = Browser.all.first(where: { $0.bundleID == saved.bundleID }) {
                    browser.openWindows(tabs)
                }
                arrange(app, saved.windows) {
                    // An app that was hidden when the desktop was saved goes back out of sight.
                    if saved.hidden == true { DispatchQueue.main.async { app.hide() } }
                }
            }
            if documents.isEmpty {
                NSWorkspace.shared.openApplication(at: url, configuration: configuration, completionHandler: opened)
            } else {
                NSWorkspace.shared.open(documents, withApplicationAt: url, configuration: configuration, completionHandler: opened)
            }
        }
    }

    /// Moves each saved window back into place, matching by title, once the app has shown its windows.
    private static func arrange(_ app: NSRunningApplication, _ saved: [Window], then done: @escaping () -> Void = {}) {
        guard !saved.isEmpty else { return done() }
        DispatchQueue.global(qos: .userInitiated).async {
            defer { done() }
            let element = Accessibility.applicationElement(app)
            // Apps take a moment to bring windows back after launch; keep looking for up to eight seconds.
            // Only a window whose title matches is moved: a window that happens to be open is never taken instead.
            var remaining = saved.filter { !$0.title.isEmpty }
            for _ in 0..<16 where !remaining.isEmpty {
                Thread.sleep(forTimeInterval: 0.5)
                var windows: [AXUIElement] = Accessibility.attribute(element, kAXWindowsAttribute) ?? []
                remaining = remaining.filter { target in
                    guard let index = windows.firstIndex(where: { window in
                        let title: String = Accessibility.attribute(window, kAXTitleAttribute) ?? ""
                        return title.caseInsensitiveCompare(target.title) == .orderedSame
                    }) else { return true }
                    place(windows.remove(at: index), target.frame)
                    return false
                }
            }
        }
    }

    private static func place(_ window: AXUIElement, _ frame: CGRect) {
        var origin = frame.origin
        var size = frame.size
        guard let position = AXValueCreate(.cgPoint, &origin), let extent = AXValueCreate(.cgSize, &size) else { return }
        AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, position)
        AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, extent)
        AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, position)
    }
}
