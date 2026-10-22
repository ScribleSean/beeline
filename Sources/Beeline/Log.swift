import Foundation

enum Log {
    private static let path = NSHomeDirectory() + "/Library/Logs/Beeline.log"

    static func start(_ line: String) {
        try? (line + "\n").write(toFile: path, atomically: true, encoding: .utf8)
    }

    private static let queue = DispatchQueue(label: "beeline.log")

    private static let maximumBytes: UInt64 = 5_000_000

    static func append(_ line: String) {
        queue.async {
            guard let handle = FileHandle(forWritingAtPath: path) else { return start(line) }
            defer { try? handle.close() }
            guard let end = try? handle.seekToEnd(), end < maximumBytes else { return start(line) }
            try? handle.write(contentsOf: Data((line + "\n").utf8))
        }
    }
}
