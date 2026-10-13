import AppKit
import CoreServices

/// Finds files and folders by name through the Spotlight index, which is already built and fast.
/// Only names are searched, not contents, and only inside the home folder.
enum Files {
    /// Folders whose contents are noise in a launcher: app support data, dependencies, build output.
    private static let skipped = ["/Library/", "/node_modules/", "/.build/", "/build/", "/DerivedData/", "/.Trash/"]

    /// Blocking, typically a few tens of milliseconds. Call off the main thread.
    static func search(_ words: [String], limit: Int = 8) -> [Item] {
        // Words are letters and digits only (the matcher splits on everything else), so they are safe to embed.
        let named = words.filter { $0.count >= 2 }
        guard named.contains(where: { $0.count >= 3 }) else { return [] }
        let predicate = named.map { "kMDItemFSName == \"*\($0)*\"cd" }.joined(separator: " && ")

        guard let query = MDQueryCreate(kCFAllocatorDefault, predicate as CFString, nil, nil) else { return [] }
        MDQuerySetSearchScope(query, [NSHomeDirectory()] as CFArray, 0)
        MDQuerySetMaxCount(query, 200)
        guard MDQueryExecute(query, CFOptionFlags(kMDQuerySynchronous.rawValue)) else { return [] }

        var found: [(path: String, used: Date)] = []
        for index in 0..<MDQueryGetResultCount(query) {
            guard let raw = MDQueryGetResultAtIndex(query, index) else { continue }
            let item = Unmanaged<MDItem>.fromOpaque(raw).takeUnretainedValue()
            guard let path = MDItemCopyAttribute(item, kMDItemPath) as? String,
                  !path.hasSuffix(".app"),
                  !skipped.contains(where: path.contains),
                  !path.split(separator: "/").contains(where: { $0.hasPrefix(".") }) else { continue }
            let used = MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
                ?? MDItemCopyAttribute(item, kMDItemContentModificationDate) as? Date
                ?? .distantPast
            found.append((path, used))
        }

        // Most recently used first: the file wanted is usually one touched lately.
        return found.sorted { $0.used > $1.used }.prefix(limit).map { entry in
            let url = URL(fileURLWithPath: entry.path)
            var isFolder: ObjCBool = false
            FileManager.default.fileExists(atPath: entry.path, isDirectory: &isFolder)
            return Item(id: entry.path, kind: .file, verb: isFolder.boolValue ? "Open folder" : "Open",
                        title: url.lastPathComponent, subtitle: url.deletingLastPathComponent().lastPathComponent,
                        keywords: "", icon: NSWorkspace.shared.icon(forFile: entry.path)) {
                NSWorkspace.shared.open(url)
            }
        }
    }
}
