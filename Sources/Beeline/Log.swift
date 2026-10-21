import Foundation

/// A small local log at ~/Library/Logs/Beeline.log, for checking what the app saw and did
/// when something goes wrong. It stays on this Mac.
enum Log {
    private static let path = NSHomeDirectory() + "/Library/Logs/Beeline.log"

    /// Starts the log afresh at launch so it never grows without bound.
    static func start(_ line: String) {
        try? (line + "\n").write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// Lines come from several threads; one queue writes them in turn so they never interleave.
    private static let queue = DispatchQueue(label: "beeline.log")

    /// Past this size the log starts over, so a long session never fills the disk.
    private static let maximumBytes: UInt64 = 5_000_000

    static func append(_ line: String) {
        queue.async {
            // The throwing calls: a full disk or a vanished file must not stop the app.
            guard let handle = FileHandle(forWritingAtPath: path) else { return start(line) }
            defer { try? handle.close() }
            guard let end = try? handle.seekToEnd(), end < maximumBytes else { return start(line) }
            try? handle.write(contentsOf: Data((line + "\n").utf8))
        }
    }
}
