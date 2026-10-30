import AppKit
import Foundation
import Testing
@testable import Beeline

// Tests must leave the screen and ~/Library/Logs/Beeline.log of whoever runs them alone.

@Test func theTestRunIsDetected() {
    #expect(TestRun.isActive)
}

@Test func logUnderTestWritesToATempFileNotTheRealLog() throws {
    let real = NSHomeDirectory() + "/Library/Logs/Beeline.log"
    #expect(Log.path != real)
    #expect(!Log.path.hasPrefix(NSHomeDirectory() + "/Library/Logs"))
    #expect(Log.path.hasPrefix(NSTemporaryDirectory()))
    let marker = "quiet-tests-" + UUID().uuidString
    Log.append(marker)
    Log.flush()
    let written = try String(contentsOfFile: Log.path, encoding: .utf8)
    #expect(written.contains(marker))
    let realText = (try? String(contentsOfFile: real, encoding: .utf8)) ?? ""
    #expect(!realText.contains(marker))
}

@Test @MainActor func aWindowAskedToComeFrontStaysOffScreen() {
    let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.isReleasedWhenClosed = false
    TestRun.orderFront(panel)
    TestRun.orderFront(panel, key: false)
    TestRun.orderFront(panel, activating: true)
    #expect(!panel.isVisible)
    #expect(!panel.isKeyWindow)
}

@Test @MainActor func theBeeAndSettingsAreBuiltButNeverShown() async {
    let bee = Bee()
    let pace = Bee.pace
    Bee.pace = 0
    defer { Bee.pace = pace }
    let target = NSScreen.screens.first.map { CGRect(x: $0.frame.midX, y: 200, width: 60, height: 20) }
        ?? CGRect(x: 100, y: 200, width: 60, height: 20)
    _ = await bee.fly(to: target, saying: "Wi-Fi", from: nil)
    let settings = SettingsWindowController()
    settings.show()
    let shown = NSApplication.shared.windows.filter { $0.isVisible && $0.alphaValue > 0 }
    #expect(shown.isEmpty, "on screen: \(shown.map { $0.title.isEmpty ? String(describing: type(of: $0)) : $0.title })")
    bee.hide()
}
