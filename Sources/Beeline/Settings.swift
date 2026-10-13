import AppKit
import SwiftUI

/// User preferences, kept in the standard macOS defaults for the app.
enum Settings {
    static let showDetails = "showDetails"
    static let useOnDeviceModel = "useOnDeviceModel"
    static let offerClaude = "offerClaude"
    static let learnFromUse = "learnFromUse"

    static let forgetHistory = Notification.Name("BeelineForgetHistory")
    static let open = Notification.Name("BeelineOpenSettings")

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            showDetails: false, useOnDeviceModel: true, offerClaude: true, learnFromUse: true,
        ])
    }

    static func isOn(_ key: String) -> Bool {
        UserDefaults.standard.bool(forKey: key)
    }
}

/// The settings window's only transient state. A plain observable object, because the `@State` macro
/// needs a compiler plugin that the Command Line Tools do not ship.
private final class SettingsState: ObservableObject {
    @Published var didForget = false
}

final class SettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let state = SettingsState()

    func show() {
        if window == nil {
            let created = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 420),
                                   styleMask: [.titled, .closable], backing: .buffered, defer: false)
            created.title = "Beeline Settings"
            created.contentView = NSHostingView(rootView: SettingsView(state: state))
            created.isReleasedWhenClosed = false
            created.center()
            window = created
        }
        state.didForget = false
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

private struct SettingsView: View {
    @AppStorage(Settings.showDetails) private var showDetails = false
    @AppStorage(Settings.useOnDeviceModel) private var useOnDeviceModel = true
    @AppStorage(Settings.offerClaude) private var offerClaude = true
    @AppStorage(Settings.learnFromUse) private var learnFromUse = true
    @ObservedObject var state: SettingsState

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            option("Show details", "Under the selected result, show what Beeline understood, why it chose it, and how long it took.",
                   $showDetails)
            option("Use the on-device model",
                   "When nothing matches your words exactly, the language model built into macOS rewrites the request as search words. Nothing leaves your Mac.",
                   $useOnDeviceModel)
            option("Offer “Ask Claude”",
                   "For multi-step requests, send the request and the names of your open windows and tabs to Claude through your Claude Code sign-in. Its plan is always previewed first.",
                   $offerClaude)
            option("Learn from what I pick", "Remember choices on this Mac so frequent ones rank higher.", $learnFromUse)

            HStack {
                Button(state.didForget ? "History forgotten" : "Forget history") {
                    NotificationCenter.default.post(name: Settings.forgetHistory, object: nil)
                    state.didForget = true
                }
                .disabled(state.didForget)
                Spacer()
                Text("Version \(String((Bundle.main.object(forInfoDictionaryKey: "BeelineCommit") as? String ?? "unknown").prefix(7)))")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(22)
        .frame(width: 460, alignment: .leading)
    }

    private func option(_ title: String, _ detail: String, _ value: Binding<Bool>) -> some View {
        Toggle(isOn: value) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .toggleStyle(.switch)
        .tint(Theme.amber400)
    }
}
