import AppKit
import Carbon.HIToolbox

enum Actions {
    private struct Definition {
        let title: String
        let symbol: String
        let keywords: String
        var needsConfirm = false
        var confirmNote: String?
        var phrases: [String] = []
        let run: () -> Void
    }

    private static let definitions: [Definition] = [
        Definition(title: "Sleep", symbol: "moon.zzz", keywords: "suspend rest nap") {
            run("/usr/bin/pmset", "sleepnow")
        },
        Definition(title: "Sleep Display", symbol: "display", keywords: "screen off monitor turn off dim") {
            run("/usr/bin/pmset", "displaysleepnow")
        },
        Definition(title: "Lock Screen", symbol: "lock", keywords: "lock secure away") {
            lockScreen()
        },
        Definition(title: "Start Screen Saver", symbol: "sparkles.tv", keywords: "screensaver") {
            run("/usr/bin/open", "-a", "ScreenSaverEngine")
        },
        Definition(title: "Mute", symbol: "speaker.slash", keywords: "sound volume silence quiet audio off") {
            setMuted(true, title: "Mute")
        },
        Definition(title: "Unmute", symbol: "speaker.wave.2", keywords: "sound volume audio on") {
            setMuted(false, title: "Unmute")
        },
        Definition(title: "Volume Up", symbol: "speaker.plus", keywords: "sound louder increase raise audio") {
            changeVolume(by: 10, title: "Volume Up", what: "turn the volume up")
        },
        Definition(title: "Volume Down", symbol: "speaker.minus", keywords: "sound quieter decrease lower audio") {
            changeVolume(by: -10, title: "Volume Down", what: "turn the volume down")
        },
        Definition(title: "Toggle Dark Mode", symbol: "circle.lefthalf.filled", keywords: "light mode appearance theme night switch turn") {
            toggleDarkMode()
        },
        Definition(title: "Turn Wi-Fi Off", symbol: "wifi.slash", keywords: "wifi wireless internet disable disconnect") {
            setWiFi("off", title: "Turn Wi-Fi Off")
        },
        Definition(title: "Turn Wi-Fi On", symbol: "wifi", keywords: "wifi wireless internet enable connect") {
            setWiFi("on", title: "Turn Wi-Fi On")
        },
        Definition(title: "Keep Mac Awake for 1 Hour", symbol: "cup.and.saucer", keywords: "caffeinate no sleep stay awake prevent") {
            run("/usr/bin/caffeinate", "-d", "-t", "3600")
        },
        Definition(title: "Mission Control", symbol: "rectangle.3.group", keywords: "show all windows spaces overview expose") {
            run("/usr/bin/open", "-a", "Mission Control")
        },
        Definition(title: "Hide Other Apps", symbol: "eye.slash", keywords: "hide others focus declutter clear windows") {
            let front = NSWorkspace.shared.frontmostApplication
            var hidden: [NSRunningApplication] = []
            for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular && app != front && !app.isHidden {
                if app.hide() { hidden.append(app) }
            }
            UndoLog.shared.record("Hide Other Apps") { for app in hidden { app.unhide() } }
        },
        Definition(title: "Eject All Disks", symbol: "eject", keywords: "unmount drives usb external remove", needsConfirm: true) {
            ejectAll()
        },
        Definition(title: "Empty Trash", symbol: "trash", keywords: "bin delete rubbish clear", needsConfirm: true) {
            script("tell application \"Finder\" to empty trash", what: "empty the Trash", app: "Finder")
        },
        Definition(title: "Restart", symbol: "arrow.clockwise", keywords: "reboot", needsConfirm: true,
                   confirmNote: "Open apps close. macOS asks once more, then goes ahead on its own after a minute.") {
            script("tell application \"loginwindow\" to «event aevtrrst»", what: "restart", app: "the login window")
        },
        Definition(title: "Shut Down", symbol: "power", keywords: "poweroff shutdown", needsConfirm: true,
                   confirmNote: "Open apps close. macOS asks once more, then goes ahead on its own after a minute.",
                   phrases: ["turn off the computer", "turn off the mac", "turn off my mac", "turn off my computer", "power off",
                             "switch off the computer", "switch off the mac", "switch off my mac"]) {
            script("tell application \"loginwindow\" to «event aevtrsdn»", what: "shut down", app: "the login window")
        },
        Definition(title: "Log Out", symbol: "rectangle.portrait.and.arrow.right", keywords: "signout logout", needsConfirm: true,
                   confirmNote: "Open apps close. macOS asks once more, then goes ahead on its own after a minute.") {
            script("tell application \"loginwindow\" to «event aevtlogo»", what: "log out", app: "the login window")
        },
    ]

    static func items() -> [Item] {
        definitions.map { definition in
            var item = Item(id: "action:" + definition.title, kind: .action, verb: "", title: definition.title,
                            subtitle: "Action", keywords: definition.keywords,
                            icon: NSImage(systemSymbolName: definition.symbol, accessibilityDescription: nil),
                            run: definition.run)
            item.needsConfirm = definition.needsConfirm
            item.confirmNote = definition.confirmNote
            item.phrases = definition.phrases
            return item
        }
    }

    static func quitItems() -> [Item] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0 != .current }
            .compactMap { app in
                guard let name = app.localizedName else { return nil }
                return Item(id: "quit:\(app.processIdentifier)", kind: .action, verb: "", title: "Quit " + name,
                            subtitle: "Action", keywords: "close exit kill stop", icon: app.icon) {
                    app.terminate()
                }
            }
    }

    private static func run(_ path: String, _ arguments: String...) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }

    private static func script(_ source: String, what: String, app: String? = nil) {
        DispatchQueue.global(qos: .userInitiated).async { _ = runScript(source, what: what, app: app) }
    }

    @discardableResult
    private static func runScript(_ source: String, what: String, app: String? = nil) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        do { try process.run() } catch { report("Couldn't \(what): osascript didn't start."); return nil }
        DispatchQueue.global().asyncAfter(deadline: .now() + 15) { if process.isRunning { process.terminate() } }
        let printed = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let text = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        process.waitUntilExit()
        guard process.terminationStatus != 0 else { return printed.trimmingCharacters(in: .whitespacesAndNewlines) }
        Log.append("action failed: \(what) (\(process.terminationStatus))")
        if text.contains("-1743"), let app {
            report("Couldn't \(what): allow Beeline to control \(app) in Privacy & Security › Automation.")
        } else {
            let last = text.split(whereSeparator: \.isNewline).last.map { ": " + $0.prefix(100) } ?? "."
            report("Couldn't \(what)" + last)
        }
        return nil
    }

    private static func setMuted(_ muted: Bool, title: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            let before = runScript("output muted of (get volume settings)", what: "read the sound") == "true"
            guard runScript("set volume output muted \(muted)", what: muted ? "mute" : "unmute") != nil, before != muted else { return }
            UndoLog.shared.record(title) {
                _ = runScript("set volume output muted \(before)", what: before ? "mute" : "unmute")
            }
        }
    }

    private static func changeVolume(by step: Int, title: String, what: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            guard let before = runScript("output volume of (get volume settings)", what: "read the volume").flatMap(Int.init),
                  runScript("set volume output volume \(max(0, min(100, before + step)))", what: what) != nil,
                  max(0, min(100, before + step)) != before else { return }
            UndoLog.shared.record(title) { _ = runScript("set volume output volume \(before)", what: "put the volume back") }
        }
    }

    private static func toggleDarkMode() {
        DispatchQueue.global(qos: .userInitiated).async {
            let prefs = "tell application \"System Events\" to tell appearance preferences to"
            guard let before = runScript("\(prefs) get dark mode", what: "read dark mode", app: "System Events"),
                  runScript("\(prefs) set dark mode to \(before == "true" ? "false" : "true")", what: "switch dark mode", app: "System Events") != nil
            else { return }
            UndoLog.shared.record("Toggle Dark Mode") {
                _ = runScript("\(prefs) set dark mode to \(before)", what: "switch dark mode back", app: "System Events")
            }
        }
    }

    static func ejectableDisks() -> [(url: URL, name: String)] {
        let keys: [URLResourceKey] = [.volumeIsEjectableKey, .volumeIsRootFileSystemKey, .volumeLocalizedNameKey]
        let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return volumes.compactMap { volume in
            guard let values = try? volume.resourceValues(forKeys: Set(keys)), values.volumeIsEjectable == true,
                  values.volumeIsRootFileSystem != true else { return nil }
            return (volume, values.volumeLocalizedName ?? volume.lastPathComponent)
        }
    }

    static func ejectSummary(_ names: [String]) -> String {
        switch names.count {
        case 0: return "No disks are connected that can be ejected."
        case 1: return "\(names[0]) is ejected. Anything still copying to it stops."
        default: return "\(names.dropLast().joined(separator: ", ")) and \(names.last!) are ejected. Anything still copying to them stops."
        }
    }

    private static func ejectAll() {
        DispatchQueue.global(qos: .userInitiated).async {
            var ejected = 0
            var stuck: [String] = []
            for disk in ejectableDisks() {
                do {
                    try NSWorkspace.shared.unmountAndEjectDevice(at: disk.url)
                    ejected += 1
                } catch {
                    stuck.append(disk.name)
                }
            }
            Log.append("eject: \(ejected) ejected, \(stuck.count) in use")
            if !stuck.isEmpty {
                report("Couldn't eject \(stuck.joined(separator: ", ")): something is still using it.")
            } else if ejected == 0 {
                report("There was nothing to eject.")
            }
        }
    }

    static let failed = Notification.Name("BeelineActionFailed")

    static func report(_ message: String) {
        DispatchQueue.main.async {
            NSSound.beep()
            NotificationCenter.default.post(name: failed, object: nil, userInfo: ["message": message])
        }
    }

    /// macOS drops posted keystrokes silently, so whether ⌃⌘Q locked the screen is checked afterwards.
    private static func lockScreen() {
        guard Keyboard.canPostKeys else {
            CGRequestPostEventAccess()
            report("Allow Accessibility for Beeline in Privacy & Security to lock the screen.")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            Keyboard.press("q", flags: [.maskCommand, .maskControl])
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                if isScreenLocked == false { report("The Mac didn't lock. Check that ⌃⌘Q still locks the screen in Keyboard settings.") }
            }
        }
    }

    static var isScreenLocked: Bool? {
        screenLocked(in: CGSessionCopyCurrentDictionary() as? [String: Any])
    }

    // macOS leaves the key out entirely while the screen is unlocked.
    static func screenLocked(in session: [String: Any]?) -> Bool? {
        guard let session else { return nil }
        guard let value = session["CGSSessionScreenIsLocked"] else { return false }
        return (value as? Bool) ?? (value as? Int).map { $0 != 0 } ?? false
    }

    private static func setWiFi(_ state: String, title: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            // The Wi-Fi interface is usually en0, but not on every Mac.
            let list = Process()
            list.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
            list.arguments = ["-listallhardwareports"]
            let pipe = Pipe()
            list.standardOutput = pipe
            guard (try? list.run()) != nil else { return }
            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let lines = output.components(separatedBy: "\n")
            guard let port = lines.firstIndex(where: { $0.contains("Wi-Fi") }), lines.indices.contains(port + 1),
                  let device = lines[port + 1].components(separatedBy: ": ").last else { return }
            let before = commandOutput(of: "/usr/sbin/networksetup", "-getairportpower", device).hasSuffix(": On") ? "on" : "off"
            run("/usr/sbin/networksetup", "-setairportpower", device, state)
            guard before != state else { return }
            UndoLog.shared.record(title) { run("/usr/sbin/networksetup", "-setairportpower", device, before) }
        }
    }

    private static func commandOutput(of path: String, _ arguments: String...) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return "" }
        let text = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        process.waitUntilExit()
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
