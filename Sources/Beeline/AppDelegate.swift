import AppKit
import Carbon.HIToolbox

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let bar = BarController()
    private var hotKey: HotKey?
    private var updateItem: NSMenuItem!
    private var openItem: NSMenuItem!
    private let settingsWindow = SettingsWindowController()
    private let welcomeWindow = WelcomeWindowController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Set on the system-wide element, the timeout applies to every accessibility element, not only app elements.
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.25)
        Settings.applyAppearance()
        NotificationCenter.default.addObserver(forName: Settings.openWelcome, object: nil, queue: .main) { [weak self] _ in
            self?.retryShortcutIfNeeded()
            self?.welcomeWindow.show()
        }
        NotificationCenter.default.addObserver(forName: Settings.open, object: nil, queue: .main) { [weak self] _ in
            self?.retryShortcutIfNeeded()
            self?.settingsWindow.show()
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = Self.menuBarGlyph()

        let menu = NSMenu()
        // Otherwise NSMenu re-enables items with a valid target itself, ignoring isEnabled.
        menu.autoenablesItems = false
        openItem = menu.addItem(withTitle: "Open Beeline", action: #selector(toggleBar), keyEquivalent: "")
        openItem.target = self
        let settings = menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        updateItem = menu.addItem(withTitle: "Update Beeline", action: #selector(update), keyEquivalent: "")
        updateItem.target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Beeline", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu

        if let scenario = Demo.requested {
            Log.append("live check \(scenario) \(Date())")
            if scenario == "open" { registerShortcut() }
            Demo.start(scenario, bar: bar, welcome: welcomeWindow)
            return
        }
        Log.start("launched \(Date()) accessibility=\(Accessibility.isTrusted)")
        if Accessibility.isTrusted { UserDefaults.standard.set(true, forKey: Settings.wasTrusted) }
        registerShortcut()
        NotificationCenter.default.addObserver(forName: Settings.shortcutChanged, object: nil, queue: .main) { [weak self] _ in
            self?.registerShortcut()
        }
        NotificationCenter.default.addObserver(forName: Settings.retryShortcut, object: nil, queue: .main) { [weak self] _ in
            self?.retryShortcutIfNeeded()
        }
        Rates.shared.refreshIfStale()
        if !UserDefaults.standard.bool(forKey: Settings.welcomed) || !Accessibility.isTrusted {
            welcomeWindow.show()
        }
    }

    private func registerShortcut() {
        hotKey = nil
        let preferred = UserDefaults.standard.string(forKey: Settings.shortcut) ?? "command"
        let modifiers = ["command": cmdKey, "option": optionKey, "control": controlKey]
        let pressed: () -> Void = { [weak self] in self?.bar.shortcutPressed() }
        let released: () -> Void = { [weak self] in self?.bar.shortcutReleased() }
        var active: String?
        for name in [preferred] + ["command", "option", "control"].filter({ $0 != preferred }) {
            hotKey = HotKey(keyCode: UInt32(kVK_Space), modifiers: UInt32(modifiers[name]!), pressed: pressed, released: released)
            if hotKey != nil {
                active = name
                break
            }
        }
        Settings.activeShortcut = active
        let label = active == nil ? Settings.activeShortcutLabel
            : active == preferred ? Settings.shortcutLabel : "\(Settings.label(for: active!)), since \(Settings.shortcutLabel) is taken"
        openItem.title = "Open Beeline (\(label))"
        Log.append("shortcut: \(label)")
    }

    private func retryShortcutIfNeeded() {
        let preferred = UserDefaults.standard.string(forKey: Settings.shortcut) ?? "command"
        guard Settings.activeShortcut != preferred else { return }
        let modifiers = ["command": cmdKey, "option": optionKey, "control": controlKey]
        guard let modifier = modifiers[preferred],
              let chosen = HotKey(keyCode: UInt32(kVK_Space), modifiers: UInt32(modifier),
                                  pressed: { [weak self] in self?.bar.shortcutPressed() },
                                  released: { [weak self] in self?.bar.shortcutReleased() }) else { return }
        hotKey = chosen
        Settings.activeShortcut = preferred
        openItem.title = "Open Beeline (\(Settings.shortcutLabel))"
        Log.append("shortcut: \(Settings.shortcutLabel)")
    }

    @objc private func openSettings() {
        retryShortcutIfNeeded()
        settingsWindow.show()
    }

    @objc private func toggleBar() {
        bar.toggle()
    }

    private var isUpdating = false

    @objc private func update() {
        guard !isUpdating else { return }
        guard let root = Bundle.main.object(forInfoDictionaryKey: "BeelineSourceRoot") as? String,
              FileManager.default.fileExists(atPath: root + "/scripts/build-app.sh") else {
            alert("Can't find Beeline's source folder", "This copy doesn't know where it was built from.")
            return
        }
        let built = Bundle.main.object(forInfoDictionaryKey: "BeelineCommit") as? String ?? ""
        isUpdating = true
        updateItem.title = "Checking for updates…"
        updateItem.isEnabled = false

        DispatchQueue.global(qos: .userInitiated).async {
            let finish = { (title: String, detail: String) in
                DispatchQueue.main.async {
                    self.resetUpdateItem()
                    self.alert(title, detail)
                }
            }
            let what: String
            let incoming: [String]
            switch Update.check(root: root, built: built) {
            case .refused(let why):
                return finish("Can't update", why)
            case .upToDate(let head, let reachedGitHub):
                let note = reachedGitHub ? "" : "\n\nCouldn't reach GitHub, so Beeline checked only the copy on this Mac."
                return finish("Beeline is up to date", "You're on the newest version (\(head.prefix(7))).\(note)")
            case .offer(let commits, let hasLocalEdits, let head):
                incoming = commits
                if incoming.isEmpty {
                    what = hasLocalEdits ? "The source folder has edits that aren't committed. Rebuild Beeline from them?"
                        : "This copy was built from a different commit than the source folder has. Rebuild from \(head.prefix(7))?"
                } else {
                    let listed = incoming.prefix(8).joined(separator: "\n")
                    let more = incoming.count > 8 ? "\n…and \(incoming.count - 8) more" : ""
                    what = "\(incoming.count) new \(incoming.count == 1 ? "commit" : "commits") on GitHub:\n\n\(listed)\(more)"
                        + (hasLocalEdits ? "\n\nThe build also includes the source folder's uncommitted edits." : "")
                }
            }
            guard self.confirm("Update Beeline?", what, action: "Update") else {
                return DispatchQueue.main.async { self.resetUpdateItem() }
            }

            if !incoming.isEmpty, let reason = Update.fastForward(root: root) {
                return finish("Couldn't update", "The copy on this Mac couldn't move straight to the newest version: \(reason)")
            }

            DispatchQueue.main.async { self.updateItem.title = "Updating…" }
            let build = Update.shell("bash scripts/build-app.sh", in: root, timeout: 900)
            DispatchQueue.main.async {
                guard build.ok else {
                    self.resetUpdateItem()
                    let tail = (build.output + "\n" + build.errors).split(whereSeparator: \.isNewline).suffix(8).joined(separator: "\n")
                    self.alert("Update failed", tail.isEmpty ? "The build didn't run." : tail)
                    return
                }
                self.relaunch(root + "/build/Beeline.app")
            }
        }
    }

    private func resetUpdateItem() {
        isUpdating = false
        updateItem.title = "Update Beeline"
        updateItem.isEnabled = true
    }

    private func confirm(_ title: String, _ detail: String, action: String) -> Bool {
        Self.onMain {
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = detail
            alert.addButton(withTitle: action)
            alert.addButton(withTitle: "Not Now")
            NSApp.activate(ignoringOtherApps: true)
            return alert.runModal() == .alertFirstButtonReturn
        }
    }

    static func onMain<T>(_ body: () -> T) -> T {
        if Thread.isMainThread { return body() }
        return DispatchQueue.main.sync(execute: body)
    }

    private func relaunch(_ appPath: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 1; open \"$0\"", appPath]
        try? process.run()
        NSApp.terminate(nil)
    }

    private func alert(_ title: String, _ detail: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private static func menuBarGlyph() -> NSImage {
        let image = Bundle.main.url(forResource: "MenuBarGlyph", withExtension: "png").flatMap(NSImage.init(contentsOf:))
            ?? NSImage(systemSymbolName: "hexagon", accessibilityDescription: nil)!
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = true
        image.accessibilityDescription = "Beeline"
        return image
    }
}
