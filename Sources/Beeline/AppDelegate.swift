import AppKit
import Carbon.HIToolbox

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let bar = BarController()
    private var hotKey: HotKey?
    private var updateItem: NSMenuItem!
    private let settingsWindow = SettingsWindowController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        Settings.registerDefaults()
        NotificationCenter.default.addObserver(forName: Settings.open, object: nil, queue: .main) { [weak self] _ in
            self?.settingsWindow.show()
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = Self.menuBarGlyph()

        let menu = NSMenu()
        let open = menu.addItem(withTitle: "Open Beeline (⌥Space)", action: #selector(toggleBar), keyEquivalent: "")
        open.target = self
        let settings = menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        updateItem = menu.addItem(withTitle: "Update Beeline", action: #selector(update), keyEquivalent: "")
        updateItem.target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Beeline", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu

        hotKey = HotKey(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey)) { [weak self] in
            self?.bar.toggle()
        }
        Log.start("launched \(Date()) accessibility=\(Accessibility.isTrusted) hotkey=\(hotKey != nil)")
    }

    @objc private func openSettings() {
        settingsWindow.show()
    }

    @objc private func toggleBar() {
        bar.toggle()
    }

    // MARK: Update

    /// Pulls the newest pushed version, rebuilds and relaunches, or says so when there is nothing new.
    @objc private func update() {
        guard let root = Bundle.main.object(forInfoDictionaryKey: "BeelineSourceRoot") as? String,
              FileManager.default.fileExists(atPath: root + "/scripts/build-app.sh") else {
            alert("Can't find Beeline's source folder", "This copy doesn't know where it was built from.")
            return
        }
        let built = Bundle.main.object(forInfoDictionaryKey: "BeelineCommit") as? String ?? ""
        updateItem.title = "Checking for updates…"
        updateItem.isEnabled = false

        DispatchQueue.global(qos: .userInitiated).async {
            let reachedGitHub = Self.shell("git fetch --quiet origin", in: root).ok
            // Fast-forward only: local work that has not been pushed is never overwritten.
            _ = Self.shell("git merge --ff-only --quiet origin/main", in: root)
            let head = Self.shell("git rev-parse HEAD", in: root).output.trimmingCharacters(in: .whitespacesAndNewlines)
            let hasLocalEdits = !Self.shell("git status --porcelain", in: root).output.isEmpty

            if !head.isEmpty, head == built, !hasLocalEdits {
                DispatchQueue.main.async {
                    self.resetUpdateItem()
                    let note = reachedGitHub ? "" : "\n\nCouldn't reach GitHub, so this was checked against the copy on this Mac only."
                    self.alert("Beeline is up to date", "You're on the newest version (\(head.prefix(7))).\(note)")
                }
                return
            }

            DispatchQueue.main.async { self.updateItem.title = "Updating…" }
            let build = Self.shell("bash scripts/build-app.sh", in: root)
            DispatchQueue.main.async {
                guard build.ok else {
                    self.resetUpdateItem()
                    let tail = build.output.split(separator: "\n").suffix(8).joined(separator: "\n")
                    self.alert("Update failed", tail.isEmpty ? "The build didn't run." : tail)
                    return
                }
                self.relaunch(root + "/build/Beeline.app")
            }
        }
    }

    private func resetUpdateItem() {
        updateItem.title = "Update Beeline"
        updateItem.isEnabled = true
    }

    /// Runs a command in a login shell, so it sees the same PATH and git credentials as a terminal.
    private static func shell(_ command: String, in directory: String) -> (ok: Bool, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-lc", command]
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return (false, error.localizedDescription) }
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        process.waitUntilExit()
        return (process.terminationStatus == 0, output)
    }

    private func relaunch(_ appPath: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Wait for this copy to quit, so the new one doesn't find Option+Space still taken.
        process.arguments = ["-c", "sleep 0.6; open \"$0\"", appPath]
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

    // MARK: Menu bar glyph

    /// The app's mark at menu bar size, made from the icon art by scripts/make-icon.swift. A template image,
    /// so macOS tints it for light and dark menu bars.
    private static func menuBarGlyph() -> NSImage {
        let image = Bundle.main.url(forResource: "MenuBarGlyph", withExtension: "png").flatMap(NSImage.init(contentsOf:))
            ?? NSImage(systemSymbolName: "hexagon", accessibilityDescription: nil)!
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = true
        image.accessibilityDescription = "Beeline"
        return image
    }
}
