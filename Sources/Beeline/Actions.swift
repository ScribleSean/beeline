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
        let run: () -> Void
    }

    private static let definitions: [Definition] = [
        Definition(title: "Sleep", symbol: "moon.zzz", keywords: "mac computer laptop suspend rest") {
            run("/usr/bin/pmset", "sleepnow")
        },
        Definition(title: "Sleep Display", symbol: "display", keywords: "screen off monitor turn off dim") {
            run("/usr/bin/pmset", "displaysleepnow")
        },
        Definition(title: "Lock Screen", symbol: "lock", keywords: "lock mac computer secure away") {
            pressKey(kVK_ANSI_Q, flags: [.maskCommand, .maskControl])
        },
        Definition(title: "Start Screen Saver", symbol: "sparkles.tv", keywords: "screensaver") {
            run("/usr/bin/open", "-a", "ScreenSaverEngine")
        },
        Definition(title: "Mute", symbol: "speaker.slash", keywords: "sound volume silence quiet audio off") {
            script("set volume output muted true")
        },
        Definition(title: "Unmute", symbol: "speaker.wave.2", keywords: "sound volume audio on") {
            script("set volume output muted false")
        },
        Definition(title: "Volume Up", symbol: "speaker.plus", keywords: "sound louder increase raise audio") {
            script("set volume output volume ((output volume of (get volume settings)) + 10)")
        },
        Definition(title: "Volume Down", symbol: "speaker.minus", keywords: "sound quieter decrease lower audio") {
            script("set volume output volume ((output volume of (get volume settings)) - 10)")
        },
        Definition(title: "Toggle Dark Mode", symbol: "circle.lefthalf.filled", keywords: "light mode appearance theme night switch turn") {
            script("tell application \"System Events\" to tell appearance preferences to set dark mode to not dark mode")
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
        Definition(title: "Eject All Disks", symbol: "eject", keywords: "unmount drives usb external remove") {
            script("tell application \"Finder\" to eject (every disk whose ejectable is true)")
        },
        Definition(title: "Empty Trash", symbol: "trash", keywords: "bin delete rubbish clear", needsConfirm: true) {
            script("tell application \"Finder\" to empty trash")
        },
        // These three ask macOS to show its own confirmation dialog, so nothing happens on one keypress.
        Definition(title: "Restart", symbol: "arrow.clockwise", keywords: "reboot mac computer") {
            script("tell application \"loginwindow\" to «event aevtrrst»")
        },
        Definition(title: "Shut Down", symbol: "power", keywords: "power off turn off mac computer shutdown") {
            script("tell application \"loginwindow\" to «event aevtrsdn»")
        },
        Definition(title: "Log Out", symbol: "rectangle.portrait.and.arrow.right", keywords: "sign out logout user") {
            script("tell application \"loginwindow\" to «event aevtlogo»")
        },
    ]

    static func items() -> [Item] {
        definitions.map { definition in
            var item = Item(id: "action:" + definition.title, kind: .action, verb: "", title: definition.title,
                            subtitle: "Action", keywords: definition.keywords,
                            icon: NSImage(systemSymbolName: definition.symbol, accessibilityDescription: nil),
                            run: definition.run)
            item.needsConfirm = definition.needsConfirm
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

    private static func script(_ source: String) {
        run("/usr/bin/osascript", "-e", source)
    }

    private static func pressKey(_ key: Int, flags: CGEventFlags) {
        for isDown in [true, false] {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(key), keyDown: isDown)
            event?.flags = flags
            event?.post(tap: .cghidEventTap)
        }
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
