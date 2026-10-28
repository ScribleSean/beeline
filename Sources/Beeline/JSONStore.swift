import Foundation

enum JSONStore {
    static func createPrivateDirectory(_ folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
    }

    static func read<T: Decodable>(_ type: T.Type, from file: URL, name: String) -> T? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let aside = file.appendingPathExtension("unreadable-\(stamp)")
            try? FileManager.default.moveItem(at: file, to: aside)
            Log.append("\(name): could not read the saved file, moved it to \(aside.lastPathComponent)")
            return nil
        }
    }
}
