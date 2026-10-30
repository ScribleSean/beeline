import Foundation

final class DemoLog {
    static var shared: DemoLog?

    private let handle: FileHandle
    private let started = Date()
    private let lock = NSLock()
    private(set) var events: [(name: String, details: [String: Any])] = []

    init?(path: String) {
        guard FileManager.default.createFile(atPath: path, contents: nil),
              let handle = FileHandle(forWritingAtPath: path) else { return nil }
        self.handle = handle
    }

    static func note(_ name: String, _ details: [String: Any] = [:]) {
        shared?.write(name, details)
    }

    func write(_ name: String, _ details: [String: Any]) {
        lock.lock()
        defer { lock.unlock() }
        events.append((name, details))
        var object = details
        object["event"] = name
        object["t"] = (Date().timeIntervalSince(started) * 1000).rounded() / 1000
        guard JSONSerialization.isValidJSONObject(object),
              var line = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return }
        line.append(0x0A)
        handle.write(line)
    }

    func count(_ name: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return events.filter { $0.name == name }.count
    }

    /// Position of the latest event with this name, for checking what happened after what.
    func lastIndex(_ name: String) -> Int? {
        lock.lock()
        defer { lock.unlock() }
        return events.lastIndex { $0.name == name }
    }

    func last(_ name: String) -> [String: Any]? {
        lock.lock()
        defer { lock.unlock() }
        return events.last { $0.name == name }?.details
    }

    static func numbers(_ point: CGPoint) -> [Double] {
        [Double(point.x), Double(point.y)].map { ($0 * 10).rounded() / 10 }
    }

    static func numbers(_ rect: CGRect) -> [Double] {
        [rect.minX, rect.minY, rect.width, rect.height].map { (Double($0) * 10).rounded() / 10 }
    }
}
