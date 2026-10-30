import Foundation
@testable import Beeline

enum TestEnvironment {
    static let scratch: URL = {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("beeline-tests-env-" + UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        setenv("BEELINE_DESKTOPS_FILE", folder.appendingPathComponent("desktops.json").path, 1)
        Usage.fileOverride = folder.appendingPathComponent("usage.json")
        setenv("BEELINE_ALIASES_FILE", folder.appendingPathComponent("aliases.json").path, 1)
        // A scan would otherwise read every window, menu and control of whatever runs on this Mac.
        Catalogue.screenReader = Catalogue.ScreenReader(windows: { _, _ in screenReads.add(); return [] },
                                                        menus: { _ in [] }, controls: { _ in [] })
        return folder
    }()

    /// How many screen scans went through the offline reader.
    static let screenReads = Counter()

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var value: Int { lock.lock(); defer { lock.unlock() }; return count }
        func add() { lock.lock(); count += 1; lock.unlock() }
    }

    static func prepare() {
        _ = scratch
    }
}
