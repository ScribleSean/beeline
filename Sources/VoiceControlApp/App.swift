import AppKit
import VoiceControlCore
import VoiceControlMac

@main
enum VoiceControlEntry {
    @MainActor static func main() {
        if CommandLine.arguments.contains("--preflight") {
            Task {
                print(await Preflight.report())
                exit(0)
            }
            CFRunLoopRun()
            return
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { app.run() }
    }
}
