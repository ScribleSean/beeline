import AppKit
import Carbon.HIToolbox

/// Things Beeline does itself, as opposed to opening something. Every action is a fixed command
/// with fixed arguments: nothing typed in the bar is ever passed to a shell.
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
        // Generic words like "mac" or "computer" are left out of keywords on purpose: "comp" must not put
        // the Mac to sleep.
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
            script("set volume output muted true", what: "mute")
        },
        Definition(title: "Unmute", symbol: "speaker.wave.2", keywords: "sound volume audio on") {
            script("set volume output muted false", what: "unmute")
        },
        Definition(title: "Volume Up", symbol: "speaker.plus", keywords: "sound louder increase raise audio") {
            script("set volume output volume ((output volume of (get volume settings)) + 10)", what: "turn the volume up")
        },
        Definition(title: "Volume Down", symbol: "speaker.minus", keywords: "sound quieter decrease lower audio") {
            script("set volume output volume ((output volume of (get volume settings)) - 10)", what: "turn the volume down")
        },
        Definition(title: "Toggle Dark Mode", symbol: "circle.lefthalf.filled", keywords: "light mode appearance theme night switch turn") {
            script("tell application \"System Events\" to tell appearance preferences to set dark mode to not dark mode",
                   what: "switch dark mode", app: "System Events")
        },
        Definition(title: "Turn Wi-Fi Off", symbol: "wifi.slash", keywords: "wifi wireless internet disable disconnect") {
            setWiFi("off")
        },
        Definition(title: "Turn Wi-Fi On", symbol: "wifi", keywords: "wifi wireless internet enable connect") {
            setWiFi("on")
        },
        Definition(title: "Keep Mac Awake for 1 Hour", symbol: "cup.and.saucer", keywords: "caffeinate no sleep stay awake prevent") {
            run("/usr/bin/caffeinate", "-d", "-t", "3600")
        },
        Definition(title: "Mission Control", symbol: "rectangle.3.group", keywords: "show all windows spaces overview expose") {
            run("/usr/bin/open", "-a", "Mission Control")
        },
        Definition(title: "Hide Other Apps", symbol: "eye.slash", keywords: "hide others focus declutter clear windows") {
            let front = NSWorkspace.shared.frontmostApplication
            for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular && app != front {
                app.hide()
            }
        },
        // Twice: a disk still being written to can lose what was on its way (Codex 7). The card names them.
        Definition(title: "Eject All Disks", symbol: "eject", keywords: "unmount drives usb external remove", needsConfirm: true) {
            ejectAll()
        },
        Definition(title: "Empty Trash", symbol: "trash", keywords: "bin delete rubbish clear", needsConfirm: true) {
            script("tell application \"Finder\" to empty trash", what: "empty the Trash", app: "Finder")
        },
        // These three need Return twice. macOS shows its own dialog too, but that one goes ahead by itself
        // after 60 seconds, so it is no safety net for a Return pressed by mistake. Keywords are matched
        // whole for anything that needs confirming: "logo" or "sign" must never surface Log Out.
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

    /// "Quit Safari" for every app with a window presence. Apps still ask about unsaved work themselves.
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

    /// Runs AppleScript and waits for it in the background. A failure says so: with Automation denied for
    /// the app the script talks to (error -1743), nothing would happen and the bar would already be closed.
    private static func script(_ source: String, what: String, app: String? = nil) {
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", source]
            process.standardOutput = FileHandle.nullDevice
            let errors = Pipe()
            process.standardError = errors
            do { try process.run() } catch { return report("Couldn't \(what): osascript didn't start.") }
            DispatchQueue.global().asyncAfter(deadline: .now() + 15) { if process.isRunning { process.terminate() } }
            let text = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            process.waitUntilExit()
            guard process.terminationStatus != 0 else { return }
            Log.append("action failed: \(what) (\(process.terminationStatus))")
            if text.contains("-1743"), let app {
                report("Couldn't \(what): allow Beeline to control \(app) in Privacy & Security › Automation.")
            } else {
                let last = text.split(whereSeparator: \.isNewline).last.map { ": " + $0.prefix(100) } ?? "."
                report("Couldn't \(what)" + last)
            }
        }
    }

    /// Ejects every ejectable volume through the system, which reports what could not be ejected and needs
    /// no Automation permission.
    /// The disks Eject All Disks would eject, by name.
    static func ejectableDisks() -> [(url: URL, name: String)] {
        let keys: [URLResourceKey] = [.volumeIsEjectableKey, .volumeIsRootFileSystemKey, .volumeLocalizedNameKey]
        let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return volumes.compactMap { volume in
            guard let values = try? volume.resourceValues(forKeys: Set(keys)), values.volumeIsEjectable == true,
                  values.volumeIsRootFileSystem != true else { return nil }
            return (volume, values.volumeLocalizedName ?? volume.lastPathComponent)
        }
    }

    /// What the confirm card says for Eject All Disks: which disks go.
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

    /// Posted when an action could not do what it said, with the reason under "message". The bar reopens
    /// and shows it, so a failure never looks like success.
    static let failed = Notification.Name("BeelineActionFailed")

    static func report(_ message: String) {
        DispatchQueue.main.async {
            NSSound.beep()
            NotificationCenter.default.post(name: failed, object: nil, userInfo: ["message": message])
        }
    }

    /// Locks with the ⌃⌘Q keystroke, then checks that it took. macOS drops posted keystrokes from an app
    /// without Accessibility, so without the check the bar would close as if the Mac were locked.
    private static func lockScreen() {
        guard Keyboard.canPostKeys else {
            CGRequestPostEventAccess()
            report("Allow Accessibility for Beeline in Privacy & Security to lock the screen.")
            return
        }
        // The bar is still closing; a keystroke posted that instant can land in it instead of macOS.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            Keyboard.press("q", flags: [.maskCommand, .maskControl])
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                if isScreenLocked == false { report("The Mac didn't lock. Check that ⌃⌘Q still locks the screen in Keyboard settings.") }
            }
        }
    }

    /// Whether the login window is up. Nil when macOS does not say.
    static var isScreenLocked: Bool? {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return nil }
        return (session["CGSSessionScreenIsLocked"] as? Bool) ?? (session["CGSSessionScreenIsLocked"] as? Int).map { $0 != 0 }
    }

    private static func setWiFi(_ state: String) {
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
            run("/usr/sbin/networksetup", "-setairportpower", device, state)
        }
    }
}
