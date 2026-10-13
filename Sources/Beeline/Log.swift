import Foundation

/// A small local log at ~/Library/Logs/Beeline.log, for checking what the app saw and did
/// when something goes wrong. It stays on this Mac.
enum Log {
    private static let path = NSHomeDirectory() + "/Library/Logs/Beeline.log"

    /// Starts the log afresh at launch so it never grows without bound.
    static func start(_ line: String) {
        try? (line + "\n").write(toFile: path, atomically: true, encoding: .utf8)
    }

    static func append(_ line: String) {
        guard let handle = FileHandle(forWritingAtPath: path) else { return start(line) }
        handle.seekToEndOfFile()
        handle.write(Data((line + "\n").utf8))
        handle.closeFile()
    }
}
