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
            let branch = Self.shell("git rev-parse --abbrev-ref HEAD", in: root)
            guard branch.ok else {
                return finish("Can't update", "Beeline's source folder isn't a git checkout, so there is nothing to fetch from.")
            }
            let branchName = branch.output.trimmingCharacters(in: .whitespacesAndNewlines)
            guard branchName == "main" else {
                return finish("Can't update", "The source folder is on the branch “\(branchName)”. Update only installs main; switch branches in Terminal first.")
            }
            let fetch = Self.shell("git fetch --quiet origin", in: root, timeout: 60)
            let reachedGitHub = fetch.ok
            let incoming = Self.shell("git log --oneline HEAD..origin/main", in: root).output
                .split(whereSeparator: \.isNewline).map(String.init)
            let head = Self.shell("git rev-parse HEAD", in: root).output.trimmingCharacters(in: .whitespacesAndNewlines)
            let hasLocalEdits = !Self.shell("git status --porcelain --untracked-files=no", in: root).output.isEmpty

            if incoming.isEmpty, !head.isEmpty, head == built, !hasLocalEdits {
                let note = reachedGitHub ? "" : "\n\nCouldn't reach GitHub, so this was checked against the copy on this Mac only."
                return finish("Beeline is up to date", "You're on the newest version (\(head.prefix(7))).\(note)")
            }

            let what: String
            if incoming.isEmpty {
                what = hasLocalEdits ? "The source folder has edits that aren't committed. Rebuild Beeline from them?"
                    : "This copy was built from a different commit than the source folder has. Rebuild from \(head.prefix(7))?"
            } else {
                let listed = incoming.prefix(8).joined(separator: "\n")
                let more = incoming.count > 8 ? "\n…and \(incoming.count - 8) more" : ""
                what = "\(incoming.count) new \(incoming.count == 1 ? "commit" : "commits") on GitHub:\n\n\(listed)\(more)"
                    + (hasLocalEdits ? "\n\nThe source folder also has uncommitted edits, which will be built in." : "")
            }
            guard self.confirm("Update Beeline?", what, action: "Update") else {
                return DispatchQueue.main.async { self.resetUpdateItem() }
            }

            if !incoming.isEmpty {
                let merged = Self.shell("git merge --ff-only --quiet origin/main", in: root)
                guard merged.ok else {
                    let reason = merged.errors.split(whereSeparator: \.isNewline).first.map(String.init) ?? "git merge failed"
                    return finish("Couldn't update", "The copy on this Mac couldn't simply move to the newest version: \(reason)")
                }
            }

            DispatchQueue.main.async { self.updateItem.title = "Updating…" }
            let build = Self.shell("bash scripts/build-app.sh", in: root, timeout: 900)
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

    /// A login shell, because an app opened from Finder doesn't get the terminal's PATH or git credentials.
    private static func shell(_ command: String, in directory: String, timeout: TimeInterval = 30) -> (ok: Bool, output: String, errors: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-lc", command]
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        process.standardInput = FileHandle.nullDevice
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do { try process.run() } catch { return (false, "", error.localizedDescription) }
        var timedOut = false
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
            if process.isRunning {
                timedOut = true
                process.terminate()
            }
        }
        var errors = ""
        let errorsRead = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            errors = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            errorsRead.signal()
        }
        let output = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        process.waitUntilExit()
        errorsRead.wait()
        if timedOut { errors += "\nGave up after \(Int(timeout)) seconds." }
        return (process.terminationStatus == 0 && !timedOut, output, errors)
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
