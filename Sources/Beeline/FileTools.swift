import AppKit
import PDFKit

/// Chores on the files selected in Finder: compress, combine PDFs, rename, convert or shrink images, make
/// videos smaller, save a video's audio. Everything uses tools built into macOS. New files are made beside the
/// originals and shown in Finder; only renaming changes files in place, and renaming several asks for Return twice.
enum FileTools {
    /// Finder's selection, read when the bar opens over Finder.
    private(set) static var selection: [URL] = []
    /// The folder shown in the front Finder window, so its items can be named without selecting them.
    private(set) static var frontFolder: URL?

    private static let images: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "tiff", "tif", "gif", "bmp", "webp"]
    private static let videos: Set<String> = ["mov", "mp4", "m4v"]

    /// Reads what is selected in Finder, off the main thread. Called when the bar opens with Finder in front.
    static func refreshSelection() {
        selection = []
        frontFolder = nil
        DispatchQueue.global(qos: .userInitiated).async {
            // The first line is the front window's folder (or "-" when there is none); the rest are selected items.
            let script = """
            tell application "Finder"
                set out to "-"
                try
                    set out to POSIX path of (target of front Finder window as alias)
                end try
                set out to out & linefeed
                repeat with f in (get selection as alias list)
                    set out to out & POSIX path of f & linefeed
                end repeat
                return out
            end tell
            """
            let lines = (run("/usr/bin/osascript", ["-e", script]).output ?? "").split(separator: "\n").map(String.init)
            let folder = lines.first.flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : nil }
            let urls = lines.dropFirst().filter { $0.hasPrefix("/") }.prefix(200).map { URL(fileURLWithPath: $0) }
            DispatchQueue.main.async {
                selection = urls
                frontFolder = folder
            }
        }
    }

    static func clearSelection() {
        selection = []
        frontFolder = nil
    }

    /// Sets the selection and front folder directly. Used by the command-line test mode.
    static func useSelection(_ urls: [URL], folder: URL? = nil) {
        selection = urls
        frontFolder = folder
    }

    // MARK: Matching what was typed

    /// Rows for a file chore on the selection, or nil when nothing is selected or the words aren't one.
    static func results(for query: String) -> [Item]? {
        if let transfer = transferResults(for: query) { return transfer }
        guard !selection.isEmpty else { return nil }
        let text = query.lowercased().trimmingCharacters(in: .whitespaces)
        let words = Set(text.split(separator: " ").map(String.init))
        let files = selection
        let pdfs = files.filter { $0.pathExtension.lowercased() == "pdf" }
        let pictures = files.filter { images.contains($0.pathExtension.lowercased()) }
        let movies = files.filter { videos.contains($0.pathExtension.lowercased()) }
        let count = files.count == 1 ? "“\(files[0].lastPathComponent)”" : "\(files.count) items"
        var rows: [Item] = []

        if !words.isDisjoint(with: ["compress", "zip", "archive"]) {
            let name = files.count == 1 ? files[0].deletingPathExtension().lastPathComponent + ".zip" : "Archive.zip"
            rows.append(row("compress", "Compress \(count)", "Makes \(name) beside them", "doc.zipper") { compress(files) })
        }
        if pdfs.count >= 2, !words.isDisjoint(with: ["combine", "merge", "join"]) {
            rows.append(row("combine", "Combine \(pdfs.count) PDFs into one", "Combined.pdf beside them, in name order",
                            "doc.on.doc") { combine(pdfs) })
        }
        if let match = text.firstMatch(of: try! Regex(#"^rename(?: (?:these|them|this|it|the files|files))? (?:to|as) (.+)$"#)),
           let range = match.output[1].range {
            // The new name keeps the capitals as typed.
            let start = query.index(query.startIndex, offsetBy: text.distance(from: text.startIndex, to: range.lowerBound),
                                    limitedBy: query.endIndex) ?? query.endIndex
            let base = String(query[start...]).trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "/", with: "-")
            if !base.isEmpty {
                let example = renamed(files, base: base).first.map { "“\($0.lastPathComponent)”" } ?? ""
                var item = row("rename", files.count == 1 ? "Rename to \(example)" : "Rename \(files.count) files to \(example), …",
                               "In place, in name order", "pencil") { rename(files, base: base) }
                item.needsConfirm = files.count > 1
                rows.append(item)
            }
        }
        if text.hasPrefix("rename"), !words.isDisjoint(with: ["date", "dated"]) {
            let ext = files[0].pathExtension.isEmpty ? "" : "." + files[0].pathExtension
            var item = row("rename-date", "Rename \(count) by date", "Like “2026-10-15 at 10.41.03\(ext)”, in place",
                           "calendar") { renameByDate(files) }
            item.needsConfirm = files.count > 1
            rows.append(item)
        }
        if !pictures.isEmpty, words.contains("convert") || words.contains("to"),
           let format = ["jpg": "jpeg", "jpeg": "jpeg", "png": "png", "heic": "heic", "tiff": "tiff", "pdf": "pdf"]
               .first(where: { words.contains($0.key) }) {
            rows.append(row("convert-\(format.value)", "Convert \(pictures.count) \(pictures.count == 1 ? "image" : "images") to \(format.key.uppercased())",
                            "Copies beside the originals", "photo.on.rectangle") { convert(pictures, to: format.value) })
        }
        if !pictures.isEmpty, !words.isDisjoint(with: ["resize", "shrink", "smaller"]) {
            let size = words.compactMap { Int($0.replacingOccurrences(of: "px", with: "")) }.first
            let title = size.map { "Resize \(pictures.count == 1 ? "the image" : "\(pictures.count) images") to \($0) pixels" }
                ?? "Make \(pictures.count == 1 ? "the image" : "\(pictures.count) images") half the size"
            rows.append(row("resize", title, "Copies beside the originals", "arrow.down.right.and.arrow.up.left") {
                resize(pictures, to: size)
            })
        }
        if !movies.isEmpty, !words.isDisjoint(with: ["compress", "shrink", "smaller", "720p"]) {
            rows.append(row("video-small", "Make \(movies.count == 1 ? "the video" : "\(movies.count) videos") smaller (720p)",
                            "Copies beside the originals", "film") { exportVideos(movies, preset: "Preset1280x720", suffix: " 720p", ext: "mp4") })
        }
        if !movies.isEmpty, !words.isDisjoint(with: ["audio", "sound", "m4a"]) {
            rows.append(row("video-audio", "Save the audio of \(movies.count == 1 ? "the video" : "\(movies.count) videos")",
                            "As .m4a beside the originals", "waveform") { exportVideos(movies, preset: "PresetAppleM4A", suffix: "", ext: "m4a") })
        }
        return rows.isEmpty ? nil : rows
    }

    // MARK: Copy, move and install

    /// "copy packet logger to applications", "move these to desktop", "install packet logger".
    private static func transferResults(for query: String) -> [Item]? {
        guard !selection.isEmpty || frontFolder != nil else { return nil }
        let text = query.trimmingCharacters(in: .whitespaces)
        let lowered = text.lowercased()
        var copying = true
        var sourceText: String
        var destinationText: String
        // The verb is optional: "packet logger to applications" copies. Without one, only "to" or "into"
        // joins the two halves, and both must resolve, so "100 usd to eur" never lands here.
        if let match = lowered.firstMatch(of: try! Regex(#"^(?:(copy|move|put|send|install)\s+(.+?)\s+(?:to|into|in)|(.+?)\s+(?:to|into))\s+(.+)$"#)),
           let source = match.output[2].range ?? match.output[3].range, let destination = match.output[4].range {
            copying = match.output[1].substring != "move"
            sourceText = String(text[source])
            destinationText = String(text[destination])
        } else if let match = lowered.firstMatch(of: try! Regex(#"^install\s+(.+)$"#)), let source = match.output[1].range {
            sourceText = String(text[source])
            destinationText = "applications"
        } else {
            return nil
        }
        sourceText = sourceText.replacingOccurrences(of: "^the ", with: "", options: [.regularExpression, .caseInsensitive])
        let sources = resolveSources(sourceText)
        guard !sources.isEmpty, let (destination, destinationName) = resolveDestination(destinationText) else { return nil }

        let verb = copying ? "Copy" : "Move"
        let what = sources.count == 1 ? "“\(sources[0].lastPathComponent)”" : "\(sources.count) items"
        let existing = sources.filter { FileManager.default.fileExists(atPath: destination.appendingPathComponent($0.lastPathComponent).path) }
        let from = sources[0].deletingLastPathComponent().lastPathComponent
        var item = row("transfer", existing.isEmpty ? "\(verb) \(what) to \(destinationName)" : "\(verb) \(what) to \(destinationName), replacing what's there",
                       existing.isEmpty ? "From \(from)" : "The old \(existing.count == 1 ? "one goes" : "ones go") to the Trash first",
                       copying ? "doc.on.doc" : "folder") {
            transfer(sources, to: destination, copying: copying)
        }
        // Replacing something needs a second Return: the old copy goes to the Trash.
        item.needsConfirm = !existing.isEmpty
        return [item]
    }

    /// Letters and digits only, lower case: "Packet Logger" and "PacketLogger.app" both become "packetlogger".
    private static func squashed(_ text: String) -> String {
        String(text.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    /// The items a request names: the selection for "this", "these" or "them", otherwise the selected item or
    /// the item in the front Finder window whose name matches best.
    private static func resolveSources(_ text: String) -> [URL] {
        if ["this", "these", "them", "it", "selected", "selection", "the selection", "these files"].contains(text.lowercased()) {
            return selection
        }
        let wanted = squashed(text)
        guard !wanted.isEmpty else { return [] }
        var candidates = selection
        if let frontFolder, let names = try? FileManager.default.contentsOfDirectory(atPath: frontFolder.path) {
            candidates += names.filter { !$0.hasPrefix(".") }.map { frontFolder.appendingPathComponent($0) }
        }
        let named = candidates.map { ($0, squashed($0.deletingPathExtension().lastPathComponent)) }
        if let exact = named.first(where: { $0.1 == wanted }) { return [exact.0] }
        if let start = named.first(where: { $0.1.hasPrefix(wanted) }) { return [start.0] }
        if let inside = named.first(where: { $0.1.contains(wanted) }) { return [inside.0] }
        return []
    }

    /// A destination folder from its everyday name, a folder in the front window, or a path.
    private static func resolveDestination(_ text: String) -> (URL, String)? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let known: [String: (URL, String)] = [
            "applications": (URL(fileURLWithPath: "/Applications"), "Applications"),
            "apps": (URL(fileURLWithPath: "/Applications"), "Applications"),
            "desktop": (home.appendingPathComponent("Desktop"), "Desktop"),
            "documents": (home.appendingPathComponent("Documents"), "Documents"),
            "downloads": (home.appendingPathComponent("Downloads"), "Downloads"),
            "pictures": (home.appendingPathComponent("Pictures"), "Pictures"),
            "music": (home.appendingPathComponent("Music"), "Music"),
            "movies": (home.appendingPathComponent("Movies"), "Movies"),
            "home": (home, "your home folder"),
            "developer": (home.appendingPathComponent("Developer"), "Developer"),
        ]
        let cleaned = text.lowercased().replacingOccurrences(of: "^(the|my) ", with: "", options: .regularExpression)
            .replacingOccurrences(of: " folder$", with: "", options: .regularExpression)
        if let found = known[cleaned] { return found }
        if text.hasPrefix("/") || text.hasPrefix("~") {
            let url = URL(fileURLWithPath: (text as NSString).expandingTildeInPath)
            return isFolder(url) ? (url, url.lastPathComponent) : nil
        }
        // A folder by that name in the front window, then in the home folder.
        for parent in [frontFolder, home].compactMap({ $0 }) {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: parent.path) else { continue }
            if let name = names.first(where: { squashed($0) == squashed(text) }) {
                let url = parent.appendingPathComponent(name)
                if isFolder(url) { return (url, name) }
            }
        }
        return nil
    }

    private static func isFolder(_ url: URL) -> Bool {
        var folder: ObjCBool = false
        // An app is a folder on disk but not somewhere to put things.
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &folder) && folder.boolValue && url.pathExtension != "app"
    }

    private static func transfer(_ sources: [URL], to destination: URL, copying: Bool) {
        let done: [URL] = sources.compactMap { source in
            let target = destination.appendingPathComponent(source.lastPathComponent)
            guard source.standardizedFileURL != target.standardizedFileURL else { return nil }
            if FileManager.default.fileExists(atPath: target.path) {
                // Recoverable: the old copy goes to the Trash, never deleted outright.
                guard (try? FileManager.default.trashItem(at: target, resultingItemURL: nil)) != nil else { return nil }
            }
            do {
                if copying { try FileManager.default.copyItem(at: source, to: target) } else { try FileManager.default.moveItem(at: source, to: target) }
                return target
            } catch {
                Log.append("file tools: \(copying ? "copy" : "move") failed: \(error.localizedDescription)")
                return nil
            }
        }
        finish(done, copying ? "copy" : "move")
    }

    private static func row(_ id: String, _ title: String, _ subtitle: String, _ symbol: String, run: @escaping () -> Void) -> Item {
        Item(id: "file-tool:\(id)", kind: .action, verb: "", title: title, subtitle: subtitle, keywords: "",
             icon: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)) {
            DispatchQueue.global(qos: .userInitiated).async(execute: run)
        }
    }

    // MARK: The chores

    private static func compress(_ files: [URL]) {
        let folder = files[0].deletingLastPathComponent()
        let name = files.count == 1 ? files[0].deletingPathExtension().lastPathComponent : "Archive"
        let output = unique(folder.appendingPathComponent(name + ".zip"))
        let result: Bool
        if files.count == 1 {
            result = run("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", files[0].path, output.path]).ok
        } else {
            // zip stores the names relative to the folder they sit in.
            result = run("/usr/bin/zip", ["-r", "-q", output.path] + files.map(\.lastPathComponent), in: folder).ok
        }
        finish(result ? [output] : [], "compress")
    }

    private static func combine(_ pdfs: [URL]) {
        let combined = PDFDocument()
        for url in pdfs.sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }) {
            guard let document = PDFDocument(url: url) else { continue }
            for index in 0..<document.pageCount {
                if let page = document.page(at: index)?.copy() as? PDFPage {
                    combined.insert(page, at: combined.pageCount)
                }
            }
        }
        let output = unique(pdfs[0].deletingLastPathComponent().appendingPathComponent("Combined.pdf"))
        finish(combined.pageCount > 0 && combined.write(to: output) ? [output] : [], "combine")
    }

    /// The new names for a rename: "Trip.jpg" for one file, "Trip 1.jpg", "Trip 2.jpg" … in name order for several.
    private static func renamed(_ files: [URL], base: String) -> [URL] {
        let ordered = files.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        return ordered.enumerated().map { index, url in
            let name = files.count == 1 ? base : "\(base) \(index + 1)"
            let ext = url.pathExtension
            return url.deletingLastPathComponent().appendingPathComponent(ext.isEmpty ? name : "\(name).\(ext)")
        }
    }

    private static func rename(_ files: [URL], base: String) {
        let ordered = files.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        finish(zip(ordered, renamed(files, base: base)).compactMap(move), "rename")
    }

    private static func renameByDate(_ files: [URL]) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let moved: [URL] = files.compactMap { url in
            let values = try? url.resourceValues(forKeys: [.creationDateKey])
            guard let date = values?.creationDate else { return nil }
            let ext = url.pathExtension
            let name = formatter.string(from: date)
            return move(url, unique(url.deletingLastPathComponent().appendingPathComponent(ext.isEmpty ? name : "\(name).\(ext)")))
        }
        finish(moved, "rename by date")
    }

    /// Renames one file. A name already taken is skipped rather than overwritten.
    private static func move(_ from: URL, _ to: URL) -> URL? {
        guard from != to, !FileManager.default.fileExists(atPath: to.path) else { return nil }
        return (try? FileManager.default.moveItem(at: from, to: to)) == nil ? nil : to
    }

    private static func convert(_ pictures: [URL], to format: String) {
        let ext = format == "jpeg" ? "jpg" : format
        let made: [URL] = pictures.compactMap { url in
            let output = unique(url.deletingPathExtension().appendingPathExtension(ext))
            return run("/usr/bin/sips", ["-s", "format", format, url.path, "--out", output.path]).ok ? output : nil
        }
        finish(made, "convert")
    }

    private static func resize(_ pictures: [URL], to size: Int?) {
        let made: [URL] = pictures.compactMap { url in
            guard let image = NSImageRep(contentsOf: url) else { return nil }
            let longest = size ?? max(image.pixelsWide, image.pixelsHigh) / 2
            guard longest > 0 else { return nil }
            let label = size.map { " \($0)px" } ?? " small"
            let output = unique(url.deletingLastPathComponent()
                .appendingPathComponent(url.deletingPathExtension().lastPathComponent + label + "." + url.pathExtension))
            return run("/usr/bin/sips", ["-Z", String(longest), url.path, "--out", output.path]).ok ? output : nil
        }
        finish(made, "resize")
    }

    private static func exportVideos(_ movies: [URL], preset: String, suffix: String, ext: String) {
        let made: [URL] = movies.compactMap { url in
            let output = unique(url.deletingLastPathComponent()
                .appendingPathComponent(url.deletingPathExtension().lastPathComponent + suffix + "." + ext))
            guard run("/usr/bin/avconvert", ["--source", url.path, "--preset", preset, "--output", output.path]).ok else { return nil }
            // The presets encode at a fixed quality, so a video that was already well compressed can come out
            // bigger. A "smaller" copy that isn't is no use: it is removed and the chore counts as failed.
            if suffix == " 720p", let before = size(of: url), let after = size(of: output), after >= before {
                try? FileManager.default.removeItem(at: output)
                Log.append("file tools: 720p copy was not smaller, removed")
                return nil
            }
            return output
        }
        finish(made, "video export")
    }

    // MARK: Helpers

    /// Shows what was made in Finder, or beeps when nothing could be.
    private static func finish(_ made: [URL], _ what: String) {
        Log.append("file tools: \(what) made \(made.count)")
        // The command-line test mode prints instead of opening Finder windows.
        if ProcessInfo.processInfo.environment["BEELINE_FILES_TEST"] != nil {
            print("made: " + made.map(\.lastPathComponent).joined(separator: ", "))
            exit(0)
        }
        DispatchQueue.main.async {
            if made.isEmpty { NSSound.beep() } else { NSWorkspace.shared.activateFileViewerSelecting(made) }
        }
    }

    private static func size(of url: URL) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int
    }

    /// The same name with " 2", " 3" … added when a file of that name already exists.
    private static func unique(_ url: URL) -> URL {
        guard FileManager.default.fileExists(atPath: url.path) else { return url }
        let folder = url.deletingLastPathComponent(), name = url.deletingPathExtension().lastPathComponent, ext = url.pathExtension
        for number in 2... {
            let candidate = folder.appendingPathComponent(ext.isEmpty ? "\(name) \(number)" : "\(name) \(number).\(ext)")
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return url
    }

    @discardableResult
    private static func run(_ tool: String, _ arguments: [String], in folder: URL? = nil) -> (ok: Bool, output: String?) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        if let folder { process.currentDirectoryURL = folder }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return (false, nil) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus == 0, String(data: data, encoding: .utf8))
    }
}
