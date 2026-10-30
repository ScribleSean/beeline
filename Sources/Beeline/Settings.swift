import AppKit
import ServiceManagement
import SwiftUI

enum Settings {
    static let showDetails = "showDetails"
    static let useOnDeviceModel = "useOnDeviceModel"
    static let offerClaude = "offerClaude"
    static let learnFromUse = "learnFromUse"
    static let clipboardHistory = "clipboardHistory"
    static let holdToTalk = "holdToTalk"
    static let showBee = "showBee"
    static let actOnRelease = "actOnRelease"
    static let shortcut = "shortcut"
    static let appearance = "appearance"
    static let welcomed = "welcomed"
    static let wasTrusted = "wasTrusted"
    static let barOpens = "barOpens"

    static let forgetHistory = Notification.Name("BeelineForgetHistory")
    static let clearClipboard = Notification.Name("BeelineClearClipboard")
    static let shortcutChanged = Notification.Name("BeelineShortcutChanged")
    static let retryShortcut = Notification.Name("BeelineRetryShortcut")
    static let open = Notification.Name("BeelineOpenSettings")
    static let openWelcome = Notification.Name("BeelineOpenWelcome")

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            showDetails: false, useOnDeviceModel: true, offerClaude: true, learnFromUse: true,
            clipboardHistory: true, holdToTalk: true, showBee: true, actOnRelease: true, shortcut: "command", appearance: "system", welcomed: false,
        ])
    }

    static func isOn(_ key: String) -> Bool {
        UserDefaults.standard.bool(forKey: key)
    }

    static func applyAppearance() {
        switch UserDefaults.standard.string(forKey: appearance) {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil
        }
    }

    static var shortcutLabel: String {
        label(for: UserDefaults.standard.string(forKey: shortcut) ?? "command")
    }

    static func label(for modifier: String) -> String {
        switch modifier {
        case "option": return "⌥Space"
        case "control": return "⌃Space"
        default: return "⌘Space"
        }
    }

    static var spotlightHasShortcut: Bool {
        forceSpotlightCard
            || (UserDefaults.standard.string(forKey: shortcut) ?? "command") == "command" && activeShortcut != "command"
    }

    static var forceSpotlightCard = false

    static var activeShortcutLabel: String {
        if let activeShortcut { return label(for: activeShortcut) }
        return "No shortcut (⌘, ⌥ and ⌃Space are all taken)"
    }

    static var activeShortcut: String? = UserDefaults.standard.string(forKey: shortcut) ?? "command"
}

private final class LoginItem: ObservableObject {
    @Published private(set) var isOn = SMAppService.mainApp.status == .enabled
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

/// A plain observable object, because the `@State` macro needs a compiler plugin that the Command Line Tools do not ship.
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
        TestRun.orderFront(window, activating: true)
    }

    static func renderPreview(to path: String) {
        let host = NSHostingView(rootView: SettingsView(state: SettingsState(), login: LoginItem()))
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}

private struct SettingsView: View {
    @ObservedObject var state: SettingsState
    @ObservedObject var login: LoginItem
    @AppStorage(Settings.shortcut) private var shortcut = "command"
    @AppStorage(Settings.appearance) private var appearance = "system"
    @AppStorage(Settings.holdToTalk) private var holdToTalk = true
    @AppStorage(Settings.showBee) private var showBee = true
    @AppStorage(Settings.actOnRelease) private var actOnRelease = true
    @AppStorage(Settings.showDetails) private var showDetails = false
    @AppStorage(Settings.useOnDeviceModel) private var useOnDeviceModel = true
    @AppStorage(Settings.offerClaude) private var offerClaude = true
    @AppStorage(Settings.learnFromUse) private var learnFromUse = true
    @AppStorage(Settings.clipboardHistory) private var clipboardHistory = true
    @StateObject private var aliasList = AliasList()

    var body: some View {
        Form {
            Section("General") {
                Toggle(isOn: Binding(get: { login.isOn }, set: { login.set($0) })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Open at login")
                        if let note = login.note {
                            Text(note).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Picker(selection: $shortcut) {
                    Text("⌘ Space").tag("command")
                    Text("⌥ Space").tag("option")
                    Text("⌃ Space").tag("control")
                } label: {
                    Text("Shortcut")
                }
                .onChange(of: shortcut) { NotificationCenter.default.post(name: Settings.shortcutChanged, object: nil) }
                Toggle(isOn: $holdToTalk) {
                    Text("Hold the shortcut to talk")
                }
                Toggle(isOn: $actOnRelease) {
                    Text("Act when you let go")
                }
                .disabled(!holdToTalk)
                Toggle(isOn: $showBee) {
                    Text("Show the bee")
                }
                Picker(selection: $appearance) {
                    Text("System").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                } label: {
                    Text("Appearance")
                }
                .pickerStyle(.segmented)
                .onChange(of: appearance) { Settings.applyAppearance() }
            }

            Section("Search") {
                Toggle(isOn: $useOnDeviceModel) {
                    Text("Use the on-device model")
                }
                Toggle(isOn: $offerClaude) {
                    Text("Offer Ask Claude")
                }
                Toggle(isOn: $showDetails) {
                    Text("Show details")
                }
            }

            Section("History") {
                Toggle(isOn: $learnFromUse) {
                    Text("Learn from what I pick")
                }
                Toggle(isOn: $clipboardHistory) {
                    Text("Clipboard history")
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
                if aliasList.entries.isEmpty {
                    Text("Type a few letters, select a result, and press ⇧⌘A. Those letters open it from then on.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(aliasList.entries, id: \.alias) { entry in
                        HStack {
                            Text(entry.alias).font(.system(size: 13, weight: .medium, design: .monospaced))
                            Image(systemName: "arrow.right").font(.system(size: 10)).foregroundStyle(.tertiary)
                            Text(entry.title).foregroundStyle(.secondary).lineLimit(1)
                            Spacer()
                            Button {
                                Aliases.shared.remove(entry.alias)
                            } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Remove the alias \(entry.alias)")
                        }
                    }
                }
            } header: {
                Text("Aliases")
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
}

private final class AliasList: ObservableObject {
    struct Row { let alias: String; let title: String }
    @Published var entries: [Row] = []
    private var observer: NSObjectProtocol?

    init() {
        reload()
        observer = NotificationCenter.default.addObserver(forName: Aliases.changed, object: nil, queue: .main) { [weak self] _ in
            self?.reload()
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    private func reload() {
        entries = Aliases.shared.entries.map { Row(alias: $0.key, title: $0.value.title) }.sorted { $0.alias < $1.alias }
    }
}
