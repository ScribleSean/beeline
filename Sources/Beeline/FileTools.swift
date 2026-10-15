import AppKit
import PDFKit

/// Chores on the files selected in Finder: compress, combine PDFs, rename, convert or shrink images, make
/// videos smaller, save a video's audio. Everything uses tools built into macOS. New files are made beside the
/// originals and shown in Finder; only renaming changes files in place, and renaming several asks for Return twice.
enum FileTools {
    /// Finder's selection, read when the bar opens over Finder.
    private(set) static var selection: [URL] = []

    private static let images: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "tiff", "tif", "gif", "bmp", "webp"]
    private static let videos: Set<String> = ["mov", "mp4", "m4v"]

    /// Reads what is selected in Finder, off the main thread. Called when the bar opens with Finder in front.
    static func refreshSelection() {
        selection = []
        DispatchQueue.global(qos: .userInitiated).async {
            let script = """
            tell application "Finder"
                set out to ""
                repeat with f in (get selection as alias list)
                    set out to out & POSIX path of f & linefeed
                end repeat
                return out
            end tell
            """
            let paths = (run("/usr/bin/osascript", ["-e", script]).output ?? "")
                .split(separator: "\n").map(String.init).filter { $0.hasPrefix("/") }
            let urls = paths.prefix(200).map { URL(fileURLWithPath: $0) }
            DispatchQueue.main.async { selection = urls }
        }
    }

    static func clearSelection() {
        selection = []
    }

    /// Sets the selection directly. Used by the command-line test mode.
    static func useSelection(_ urls: [URL]) {
        selection = urls
    }

    // MARK: Matching what was typed

    /// Rows for a file chore on the selection, or nil when nothing is selected or the words aren't one.
    static func results(for query: String) -> [Item]? {
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
            return run("/usr/bin/avconvert", ["--source", url.path, "--preset", preset, "--output", output.path]).ok ? output : nil
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
            return
        }
        DispatchQueue.main.async {
            if made.isEmpty { NSSound.beep() } else { NSWorkspace.shared.activateFileViewerSelecting(made) }
        }
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
