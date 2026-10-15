import AppKit
import ServiceManagement
import SwiftUI

/// User preferences, kept in the standard macOS defaults for the app.
enum Settings {
    static let showDetails = "showDetails"
    static let useOnDeviceModel = "useOnDeviceModel"
    static let offerClaude = "offerClaude"
    static let learnFromUse = "learnFromUse"
    static let clipboardHistory = "clipboardHistory"
    static let holdToTalk = "holdToTalk"
    /// Which modifier opens the bar with Space: "command", "option" or "control".
    static let shortcut = "shortcut"
    /// "system", "light" or "dark".
    static let appearance = "appearance"
    /// Set once the welcome screen has been shown.
    static let welcomed = "welcomed"

    static let forgetHistory = Notification.Name("BeelineForgetHistory")
    static let clearClipboard = Notification.Name("BeelineClearClipboard")
    static let shortcutChanged = Notification.Name("BeelineShortcutChanged")
    static let open = Notification.Name("BeelineOpenSettings")
    static let openWelcome = Notification.Name("BeelineOpenWelcome")

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            showDetails: false, useOnDeviceModel: true, offerClaude: true, learnFromUse: true,
            clipboardHistory: true, holdToTalk: true, shortcut: "command", appearance: "system", welcomed: false,
        ])
    }

    static func isOn(_ key: String) -> Bool {
        UserDefaults.standard.bool(forKey: key)
    }

    /// Applies the chosen appearance to every Beeline window, the bar included.
    static func applyAppearance() {
        switch UserDefaults.standard.string(forKey: appearance) {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil
        }
    }

    static var shortcutLabel: String {
        switch UserDefaults.standard.string(forKey: shortcut) {
        case "option": return "⌥Space"
        case "control": return "⌃Space"
        default: return "⌘Space"
        }
    }
}

/// Whether Beeline opens when you log in, through macOS's own login items list.
private final class LoginItem: ObservableObject {
    @Published private(set) var isOn = SMAppService.mainApp.status == .enabled
    /// Shown when macOS needs the user to approve the login item in System Settings.
    @Published private(set) var note: String?

    func set(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            note = nil
        } catch {
            note = "macOS didn't accept that: \(error.localizedDescription)"
        }
        isOn = SMAppService.mainApp.status == .enabled
        if SMAppService.mainApp.status == .requiresApproval {
            note = "Allow Beeline in System Settings › General › Login Items."
        }
    }

    func refresh() {
        isOn = SMAppService.mainApp.status == .enabled
    }
}

/// The settings window's transient state. A plain observable object, because the `@State` macro
/// needs a compiler plugin that the Command Line Tools do not ship.
private final class SettingsState: ObservableObject {
    @Published var didForget = false
    @Published var didClearClipboard = false
}

final class SettingsWindowController: NSObject {
    private var window: NSWindow?
    private let state = SettingsState()
    private let login = LoginItem()

    func show() {
        if window == nil {
            let host = NSHostingController(rootView: SettingsView(state: state, login: login))
            let created = NSWindow(contentViewController: host)
            created.title = "Beeline Settings"
            created.styleMask = [.titled, .closable]
            created.isReleasedWhenClosed = false
            window = created
        }
        state.didForget = false
        state.didClearClipboard = false
        login.refresh()
        window?.center()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

private struct SettingsView: View {
    @ObservedObject var state: SettingsState
    @ObservedObject var login: LoginItem
    @AppStorage(Settings.shortcut) private var shortcut = "command"
    @AppStorage(Settings.appearance) private var appearance = "system"
    @AppStorage(Settings.holdToTalk) private var holdToTalk = true
    @AppStorage(Settings.showDetails) private var showDetails = false
    @AppStorage(Settings.useOnDeviceModel) private var useOnDeviceModel = true
    @AppStorage(Settings.offerClaude) private var offerClaude = true
    @AppStorage(Settings.learnFromUse) private var learnFromUse = true
    @AppStorage(Settings.clipboardHistory) private var clipboardHistory = true

    var body: some View {
        Form {
            Section("General") {
                Toggle(isOn: Binding(get: { login.isOn }, set: { login.set($0) })) {
                    label("Open at login", login.note ?? "Start Beeline when you log in to your Mac.")
                }
                Picker(selection: $shortcut) {
                    Text("⌘ Space").tag("command")
                    Text("⌥ Space").tag("option")
                    Text("⌃ Space").tag("control")
                } label: {
                    label("Shortcut", "For ⌘ Space, Spotlight's shortcut must be off in Keyboard settings.")
                }
                .onChange(of: shortcut) { NotificationCenter.default.post(name: Settings.shortcutChanged, object: nil) }
                Toggle(isOn: $holdToTalk) {
                    label("Hold the shortcut to talk", "Speak instead of typing. Recognised on this Mac.")
                }
                Picker(selection: $appearance) {
                    Text("System").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                } label: {
                    label("Appearance", "Light, dark, or follow your Mac.")
                }
                .pickerStyle(.segmented)
                .onChange(of: appearance) { Settings.applyAppearance() }
            }

            Section("Search") {
                Toggle(isOn: $useOnDeviceModel) {
                    label("Use the on-device model", "Rewrites loose requests as search words. Nothing leaves your Mac.")
                }
                Toggle(isOn: $offerClaude) {
                    label("Offer Ask Claude", "Sends multi-step requests to Claude. Its plan is always shown first.")
                }
                Toggle(isOn: $showDetails) {
                    label("Show details", "Shows why a result was chosen and how long it took.")
                }
            }

            Section("History") {
                Toggle(isOn: $learnFromUse) {
                    label("Learn from what I pick", "Frequent choices rank higher. Stored on this Mac.")
                }
                Toggle(isOn: $clipboardHistory) {
                    label("Clipboard history", "Type “clip” to paste something you copied. Kept in memory only.")
                }
                HStack {
                    Spacer()
                    Button(state.didClearClipboard ? "Clipboard cleared" : "Clear clipboard") {
                        NotificationCenter.default.post(name: Settings.clearClipboard, object: nil)
                        state.didClearClipboard = true
                    }
                    .disabled(state.didClearClipboard)
                    Button(state.didForget ? "Picks forgotten" : "Forget picks") {
                        NotificationCenter.default.post(name: Settings.forgetHistory, object: nil)
                        state.didForget = true
                    }
                    .disabled(state.didForget)
                }
            }

            Section {
                LabeledContent("Version",
                               value: String((Bundle.main.object(forInfoDictionaryKey: "BeelineCommit") as? String ?? "unknown").prefix(7)))
            }
        }
        .formStyle(.grouped)
        .tint(Theme.yellow)
        .frame(width: 500)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func label(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
    }
}
