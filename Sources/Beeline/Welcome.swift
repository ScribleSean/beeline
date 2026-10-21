import AppKit
import SwiftUI

/// The first-run screen: what Beeline is, its shortcut, and why it asks for Accessibility.
/// Shown once; type "beeline welcome" to see it again.
final class WelcomeWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let state = WelcomeState()

    func show() {
        if window == nil {
            let host = NSHostingController(rootView: WelcomeView(state: state) { [weak self] in self?.window?.close() })
            let created = NSWindow(contentViewController: host)
            created.title = ""
            created.styleMask = [.titled, .closable, .fullSizeContentView]
            created.titlebarAppearsTransparent = true
            created.isReleasedWhenClosed = false
            created.delegate = self
            window = created
        }
        state.refresh()
        window?.center()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        UserDefaults.standard.set(true, forKey: Settings.welcomed)
    }

    func windowWillClose(_ notification: Notification) {
        state.stop()
    }
}

extension WelcomeWindowController {
    /// Renders the welcome screen to a PNG, for checking its design without opening it.
    static func renderPreview(to path: String) {
        let host = NSHostingView(rootView: WelcomeView(state: WelcomeState()) {})
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

/// Whether Accessibility is on, rechecked whenever the window comes forward and every second while
/// it is open, so the card turns green as soon as the switch is flipped in System Settings.
private final class WelcomeState: ObservableObject {
    @Published var trusted = Accessibility.isTrusted
    /// True while Spotlight still holds ⌘Space and Beeline had to take another shortcut.
    @Published var spotlightHasShortcut = Settings.spotlightHasShortcut
    /// True when an earlier build was trusted, so a grant that no longer matches is the likely cause.
    var wasTrustedBefore: Bool { UserDefaults.standard.bool(forKey: Settings.wasTrusted) }
    private var timer: Timer?

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        trusted = Accessibility.isTrusted
        spotlightHasShortcut = Settings.spotlightHasShortcut
        timer?.invalidate()
        var ticks = 0
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
            guard let self else { return timer.invalidate() }
            self.trusted = Accessibility.isTrusted
            ticks += 1
            // Every few seconds, try ⌘Space again, so the card clears soon after Spotlight lets go of it.
            if self.spotlightHasShortcut, ticks.isMultiple(of: 3) {
                NotificationCenter.default.post(name: Settings.shortcutChanged, object: nil)
                self.spotlightHasShortcut = Settings.spotlightHasShortcut
            }
            if self.trusted, !self.spotlightHasShortcut { timer.invalidate() }
        }
    }
}

private struct WelcomeView: View {
    @ObservedObject var state: WelcomeState
    let close: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 84, height: 84)
                .padding(.top, 10)
            VStack(spacing: 6) {
                Text("Welcome to Beeline").font(.system(size: 26, weight: .semibold))
                Text("Your Mac, a few words away.").font(.system(size: 14)).foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                ForEach(Array((Settings.activeShortcut.map { Settings.label(for: $0) } ?? "⌘Space").replacingOccurrences(of: "Space", with: "").map(String.init)) + ["Space"], id: \.self) { key in
                    Text(key)
                        .font(.system(size: 13, weight: .medium))
                        .padding(.horizontal, 10)
                        .frame(height: 26)
                        .background(Theme.capsule, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Theme.capsuleEdge, lineWidth: 1))
                }
                Text(Settings.activeShortcut == nil ? "would open it, but ⌘, ⌥ and ⌃Space are all taken by other apps."
                     : "opens it. Hold it to talk.").font(.system(size: 13)).foregroundStyle(.secondary)
            }

            if state.spotlightHasShortcut {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(Theme.accent)
                        .frame(width: 36, height: 36)
                        .background(Theme.honeyTile, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Spotlight has ⌘Space").font(.system(size: 14, weight: .semibold))
                        Text("Beeline uses \(Settings.activeShortcutLabel) for now. In Keyboard Shortcuts › Spotlight, turn off Show Spotlight search, and ⌘Space is Beeline's.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Open Keyboard Settings") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .buttonStyle(.link)
                        .font(.system(size: 12, weight: .medium))
                        .padding(.top, 2)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.raised, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.capsuleEdge, lineWidth: 1))
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    Image(systemName: state.trusted ? "checkmark.circle.fill" : "hand.raised")
                        .font(.system(size: 20))
                        .foregroundStyle(state.trusted ? Color.green : Theme.accent)
                        .frame(width: 36, height: 36)
                        .background(Theme.honeyTile, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(state.trusted ? "Accessibility is on" : "Allow Accessibility").font(.system(size: 14, weight: .semibold))
                        Text("Lets Beeline switch windows, run menu commands, and press buttons for you. What it reads stays on your Mac unless you ask Claude for a plan.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if !state.trusted {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("1.  Click Open System Settings").font(.system(size: 12))
                        Text("2.  Switch on Beeline in the list").font(.system(size: 12))
                        if state.wasTrustedBefore {
                            // An ad hoc rebuild is a new app to macOS: the old grant shows as on but no longer counts.
                            Text("If Beeline is already listed and on, this build isn't the one that was allowed: select it, remove it with −, then add it again with +.")
                                .font(.system(size: 12))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .foregroundStyle(.secondary)
                    .padding(.leading, 48)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.raised, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.capsuleEdge, lineWidth: 1))

            Button {
                if state.trusted {
                    close()
                } else {
                    Accessibility.requestAccess()
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                        NSWorkspace.shared.open(url)
                    }
                }
            } label: {
                Text(state.trusted ? "Start using Beeline" : "Open System Settings")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                    .frame(maxWidth: .infinity)
                    .frame(height: 38)
                    .background(Theme.yellow, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)
            if !state.trusted {
                Button("Set up later", action: close).buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 30)
        .padding(.vertical, 22)
        .frame(width: 440)
        .background {
            ZStack {
                Color(nsColor: .windowBackgroundColor)
                Theme.warmth
            }
            .ignoresSafeArea()
        }
    }
}
