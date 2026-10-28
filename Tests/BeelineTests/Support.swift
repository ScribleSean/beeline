import Foundation
@testable import Beeline

enum TestEnvironment {
    static let scratch: URL = {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("beeline-tests-env-" + UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        setenv("BEELINE_DESKTOPS_FILE", folder.appendingPathComponent("desktops.json").path, 1)
        Usage.fileOverride = folder.appendingPathComponent("usage.json")
        setenv("BEELINE_ALIASES_FILE", folder.appendingPathComponent("aliases.json").path, 1)
        return folder
    }()

    static func prepare() {
        _ = scratch
    }
}
