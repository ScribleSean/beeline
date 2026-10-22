import Foundation
@testable import Beeline

/// Points every on-disk store at scratch files before anything reads them. Call first in any test
/// that touches the catalogue, saved desktops or pick history.
enum TestEnvironment {
    static let scratch: URL = {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("beeline-tests-env-" + UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        setenv("BEELINE_DESKTOPS_FILE", folder.appendingPathComponent("desktops.json").path, 1)
        setenv("BEELINE_USAGE_FILE", folder.appendingPathComponent("usage.json").path, 1)
        setenv("BEELINE_ALIASES_FILE", folder.appendingPathComponent("aliases.json").path, 1)
        return folder
    }()

    static func prepare() {
        _ = scratch
    }
}
