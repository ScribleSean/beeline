import AppKit
import PDFKit

enum FileTools {
    private(set) static var selection: [URL] = []
    private(set) static var frontFolder: URL?

    private static let images: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "tiff", "tif", "gif", "bmp", "webp"]
    private static let videos: Set<String> = ["mov", "mp4", "m4v"]

    private static var selectionGeneration = 0

    static func refreshSelection(done: @escaping () -> Void = {}) {
        selection = []
        frontFolder = nil
        selectionGeneration += 1
        let generation = selectionGeneration
        DispatchQueue.global(qos: .userInitiated).async {
            // Each is a file URL, not a path: a URL writes a line break in a name as %0A, so one line is always
            // one item.
            let script = """
            tell application "Finder"
                set out to "-"
                try
                    set out to URL of (target of front Finder window)
                end try
                set out to out & linefeed
                repeat with f in (get selection)
                    set out to out & (URL of f) & linefeed
                end repeat
                return out
            end tell
            """
            let (folder, urls) = parseSelection(run("/usr/bin/osascript", ["-e", script]).output ?? "")
            DispatchQueue.main.async {
                guard generation == selectionGeneration else { return }
                selection = urls
                frontFolder = folder
                done()
            }
        }
    }

    static func parseSelection(_ output: String) -> (folder: URL?, items: [URL]) {
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        func file(_ line: String) -> URL? {
            guard let url = URL(string: line.trimmingCharacters(in: .whitespaces)), url.isFileURL,
                  FileManager.default.fileExists(atPath: url.path) else { return nil }
            return url
        }
        let folder = lines.first.flatMap(file)
        let items = lines.dropFirst().compactMap(file).prefix(200)
        return (folder, Array(items))
    }

    static func clearSelection() {
        selectionGeneration += 1
        selection = []
        frontFolder = nil
    }

    static func useSelection(_ urls: [URL], folder: URL? = nil) {
        selection = urls
        frontFolder = folder
    }

    static func results(for query: String) -> [Item]? {
        if let transfer = transferResults(for: query) { return transfer }
        guard !selection.isEmpty else { return nil }
        // Lower-casing can change a string's length ("İ" grows), so positions found in a lowered copy would
        // run past the end of the original.
        let text = query.trimmingCharacters(in: .whitespaces)
        let words = Set(text.lowercased().split(separator: " ").map(String.init))
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
        if let match = text.firstMatch(of: try! Regex(#"^rename(?: (?:these|them|this|it|the files|files))? (?:to|as) (.+)$"#).ignoresCase()),
           let range = match.output[1].range {
            let base = String(text[range]).trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "/", with: "-")
            if !base.isEmpty {
                let example = renamed(files, base: base).first.map { "“\($0.lastPathComponent)”" } ?? ""
                var item = row("rename", files.count == 1 ? "Rename to \(example)" : "Rename \(files.count) files to \(example), …",
                               "In place, in name order", "pencil") { rename(files, base: base) }
                item.needsConfirm = files.count > 1
                rows.append(item)
            }
        }
        if text.lowercased().hasPrefix("rename"), !words.isDisjoint(with: ["date", "dated"]) {
            let ext = files[0].pathExtension.isEmpty ? "" : "." + files[0].pathExtension
            var item = row("rename-date", "Rename \(count) by date", "Like “2026-10-15 at 10.41.03\(ext)”, in place",
                           "calendar") { renameByDate(files) }
            item.needsConfirm = files.count > 1
            rows.append(item)
        }
        // An ordered list: a dictionary's order changes from launch to launch.
        let formats: [(String, String)] = [("jpg", "jpeg"), ("jpeg", "jpeg"), ("png", "png"), ("heic", "heic"), ("tiff", "tiff"), ("pdf", "pdf")]
        let ordered = text.lowercased().split(separator: " ").map(String.init)
        func format(at index: Int) -> (String, String)? { formats.first { $0.0 == ordered[index] } }
        var chosen: (String, String)?
        for index in ordered.indices.dropFirst() where ["to", "as", "into"].contains(ordered[index - 1]) {
            if let found = format(at: index) { chosen = found; break }
        }
        if chosen == nil, let last = ordered.indices.reversed().first(where: { format(at: $0) != nil }) { chosen = format(at: last) }
        if !pictures.isEmpty, words.contains("convert") || words.contains("to"), let format = chosen {
            rows.append(row("convert-\(format.1)", "Convert \(pictures.count) \(pictures.count == 1 ? "image" : "images") to \(format.0.uppercased())",
                            "Copies beside the originals", "photo.on.rectangle") { convert(pictures, to: format.1) })
        }
        if !pictures.isEmpty, !words.isDisjoint(with: ["resize", "shrink", "smaller"]) {
            let numbers = text.lowercased().split(separator: " ").map(String.init)
            let size = numbers.first { $0.hasSuffix("px") }.flatMap { Int($0.dropLast(2)) }
                ?? numbers.reversed().lazy.compactMap { Int($0) }.first
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

    private static func transferResults(for query: String) -> [Item]? {
        guard !selection.isEmpty || frontFolder != nil else { return nil }
        let text = query.trimmingCharacters(in: .whitespaces)
        var copying = true
        var sourceText: String
        var destinationText: String
        var hasVerb = true
        if let match = text.firstMatch(of: try! Regex(#"^(?:(copy|move|put|send|install)\s+(.+?)\s+(?:to|into|in)|(.+?)\s+(?:to|into))\s+(.+)$"#).ignoresCase()),
           let source = match.output[2].range ?? match.output[3].range, let destination = match.output[4].range {
            copying = match.output[1].substring?.lowercased() != "move"
            hasVerb = match.output[1].range != nil
            sourceText = String(text[source])
            destinationText = String(text[destination])
        } else if let match = text.firstMatch(of: try! Regex(#"^install\s+(.+)$"#).ignoresCase()), let source = match.output[1].range {
            sourceText = String(text[source])
            destinationText = "applications"
        } else {
            return nil
        }
        sourceText = sourceText.replacingOccurrences(of: "^the ", with: "", options: [.regularExpression, .caseInsensitive])
        let sources = resolveSources(sourceText, exactly: !hasVerb)
        guard !sources.isEmpty, let (destination, destinationName) = resolveDestination(destinationText) else { return nil }

        let verb = copying ? "Copy" : "Move"
        let what = sources.count == 1 ? "“\(sources[0].lastPathComponent)”" : "\(sources.count) items"
        let replaced = sources.filter { source in
            let target = destination.appendingPathComponent(source.lastPathComponent)
            return FileManager.default.fileExists(atPath: target.path) && !overlaps(source, target)
        }.map(\.lastPathComponent)
        let shown = replacements(replaced, in: destination)
        let from = sources[0].deletingLastPathComponent().lastPathComponent
        var item = row("transfer", replaced.isEmpty ? "\(verb) \(what) to \(destinationName)" : "\(verb) \(what) to \(destinationName), replacing what's there",
                       replaced.isEmpty ? "From \(from)" : "The old \(replaced.count == 1 ? "one goes" : "ones go") to the Trash first",
                       copying ? "doc.on.doc" : "folder") {
            _ = transfer(sources, to: destination, copying: copying, replacing: shown, report: true)
        }
        item.needsConfirm = !replaced.isEmpty
        if !replaced.isEmpty {
            let names = replaced.prefix(3).map { "“\($0)”" }.joined(separator: ", ")
            item.confirmNote = "\(replaced.count > 3 ? "\(replaced.count) items in \(destinationName), including \(names)," : "The old \(names) in \(destinationName)") "
                + "\(replaced.count == 1 ? "goes" : "go") to the Trash first."
        }
        return [item]
    }

    private static func squashed(_ text: String) -> String {
        String(text.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    private static func resolveSources(_ text: String, exactly: Bool = false) -> [URL] {
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
        guard !exactly else { return [] }
        if let start = named.first(where: { $0.1.hasPrefix(wanted) }) { return [start.0] }
        if let inside = named.first(where: { $0.1.contains(wanted) }) { return [inside.0] }
        return []
    }

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
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &folder) && folder.boolValue
            && !url.lastPathComponent.hasPrefix(".") && !NSWorkspace.shared.isFilePackage(atPath: url.path)
    }

    static var trash: (URL) throws -> URL? = { url in
        var landed: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &landed)
        return landed as URL?
    }

    /// Compared by file identity, not by spelling: on a Mac's usual disk "~/desktop/Notes" and
    /// "~/Desktop/Notes" are one file.
    static func overlaps(_ a: URL, _ b: URL) -> Bool {
        if sameItem(a, b) { return true }
        let pathA = a.standardizedFileURL.resolvingSymlinksInPath().path.lowercased()
        let pathB = b.standardizedFileURL.resolvingSymlinksInPath().path.lowercased()
        return pathA.hasPrefix(pathB + "/") || pathB.hasPrefix(pathA + "/")
    }

    private static func sameItem(_ a: URL, _ b: URL) -> Bool {
        let idA = try? a.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier
        let idB = try? b.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier
        if let idA, let idB { return idA.isEqual(idB) }
        return a.standardizedFileURL.path.lowercased() == b.standardizedFileURL.path.lowercased()
    }

    typealias Replacements = [String: NSObject]

    static func replacements(_ names: [String], in destination: URL) -> Replacements {
        var shown: Replacements = [:]
        for name in names {
            if let id = identity(of: destination.appendingPathComponent(name)) { shown[name] = id }
        }
        return shown
    }

    private static func identity(of url: URL) -> NSObject? {
        (try? url.resourceValues(forKeys: [.fileResourceIdentifierKey]))?.fileResourceIdentifier as? NSObject
    }

    @discardableResult
    static func transfer(_ sources: [URL], to destination: URL, copying: Bool, replacing: Replacements, report: Bool = false) -> [URL] {
        // "Notes.txt" and "notes.txt" from a case-sensitive disk are one name in a Mac's usual folder, and
        // the second would replace the first.
        var counts: [String: Int] = [:]
        for source in sources { counts[source.lastPathComponent.lowercased(), default: 0] += 1 }
        var undos: [() -> Void] = []
        let done: [URL] = sources.compactMap { source in
            let name = source.lastPathComponent
            guard counts[name.lowercased()] == 1 else {
                Log.append("file tools: two items share a name, skipped")
                return nil
            }
            let target = destination.appendingPathComponent(name)
            guard !overlaps(source, target) else { return nil }
            guard FileManager.default.fileExists(atPath: target.path) else {
                guard (try? deliver(source, to: target, copying: copying)) != nil else { return nil }
                let delivered = identity(of: target)
                undos.append { takeBack(target, to: source, copying: copying, ifStill: delivered) }
                return target
            }
            guard let shown = replacing[name], identity(of: target)?.isEqual(shown) == true else {
                Log.append("file tools: the item in the way isn't the one on the card, skipped")
                return nil
            }
            guard let scratch = scratchFolder(near: destination) else {
                Log.append("file tools: no scratch folder beside the destination")
                return nil
            }
            defer {
                if (try? FileManager.default.contentsOfDirectory(atPath: scratch.path))?.isEmpty == true {
                    try? FileManager.default.removeItem(at: scratch)
                }
            }
            let staged = scratch.appendingPathComponent(name)
            guard (try? deliver(source, to: staged, copying: copying)) != nil else { return nil }
            let trashed: URL?
            do {
                trashed = try trash(target)
            } catch {
                Log.append("file tools: could not trash the old item (\((error as NSError).code))")
                if !copying { try? FileManager.default.moveItem(at: staged, to: source) }
                return nil
            }
            guard (try? FileManager.default.moveItem(at: staged, to: target)) != nil else {
                Log.append("file tools: could not put the new item in place")
                if !copying { try? FileManager.default.moveItem(at: staged, to: source) }
                return nil
            }
            let delivered = identity(of: target)
            undos.append {
                takeBack(target, to: source, copying: copying, ifStill: delivered)
                if let trashed, !FileManager.default.fileExists(atPath: target.path) {
                    try? FileManager.default.moveItem(at: trashed, to: target)
                }
            }
            return target
        }
        if !done.isEmpty {
            let what = done.count == 1 ? "“\(done[0].lastPathComponent)”" : "\(done.count) items"
            UndoLog.shared.record("\(copying ? "Copy" : "Move") \(what) to \(destination.lastPathComponent)") {
                for undo in undos.reversed() { undo() }
            }
        }
        if report { finish(done, copying ? "copy" : "move") }
        return done
    }

    private static func takeBack(_ target: URL, to source: URL, copying: Bool, ifStill delivered: NSObject?) {
        guard FileManager.default.fileExists(atPath: target.path), let delivered,
              identity(of: target)?.isEqual(delivered) == true else {
            Log.append("file tools: undo skipped an item that changed since")
            return
        }
        if copying {
            _ = try? trash(target)
        } else if !FileManager.default.fileExists(atPath: source.path) {
            try? FileManager.default.moveItem(at: target, to: source)
        }
    }

    private static func deliver(_ source: URL, to target: URL, copying: Bool) throws {
        do {
            if copying { try FileManager.default.copyItem(at: source, to: target) } else { try FileManager.default.moveItem(at: source, to: target) }
        } catch {
            Log.append("file tools: \(copying ? "copy" : "move") failed (\((error as NSError).code))")
            throw error
        }
    }

    private static let choreQueue = DispatchQueue(label: "beeline.file-chores", qos: .userInitiated)

    private static func row(_ id: String, _ title: String, _ subtitle: String, _ symbol: String, run: @escaping () -> Void) -> Item {
        Item(id: "file-tool:\(id)", kind: .action, verb: "", title: title, subtitle: subtitle, keywords: "",
             icon: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)) {
            choreQueue.async(execute: run)
        }
    }

    private static func compress(_ files: [URL]) {
        if let name = sharedName(files) {
            Actions.report("Two of the selected items are called “\(name)”, and a zip can hold only one. Rename one and try again.")
            return finish([], "compress")
        }
        finish(archive(files).map { [$0] } ?? [], "compress")
    }

    /// Compared without case, as most Mac disks do.
    static func sharedName(_ files: [URL]) -> String? {
        var seen = Set<String>()
        return files.map(\.lastPathComponent).first { !seen.insert($0.lowercased()).inserted }
    }

    static func archive(_ files: [URL]) -> URL? {
        // Two items with one name from different folders would land on one zip entry, the second quietly
        // overwriting the first.
        guard let first = files.first, sharedName(files) == nil else { return nil }
        let folder = first.deletingLastPathComponent()
        let name = files.count == 1 ? first.deletingPathExtension().lastPathComponent : "Archive"
        guard let scratch = scratchFolder(near: folder) else { return nil }
        defer { try? FileManager.default.removeItem(at: scratch) }
        let output = scratch.appendingPathComponent(name + ".zip")
        var ok = true
        if files.count == 1 {
            ok = run("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", first.path, output.path]).ok
        } else {
            // zip stores names relative to the folder it runs in. zip reads options from anywhere on its command
            // line, and "-m" would delete the originals, so names follow "--" and start with "./".
            // -MM makes a name that cannot be read a failure.
            var byFolder: [URL: [URL]] = [:]
            var order: [URL] = []
            for file in files {
                let parent = file.deletingLastPathComponent().standardizedFileURL
                if byFolder[parent] == nil { order.append(parent) }
                byFolder[parent, default: []].append(file)
            }
            for parent in order {
                let names = byFolder[parent]!.map { "./" + $0.lastPathComponent }
                // -y stores a link as a link: without it, a link inside a selected folder pulls in whatever it
                // points to, from anywhere on the disk. ditto keeps links as links already.
                guard run("/usr/bin/zip", ["-r", "-y", "-q", "-MM", output.path, "--"] + names, in: parent).ok else { ok = false; break }
            }
        }
        guard ok, FileManager.default.fileExists(atPath: output.path) else { return nil }
        return place(output, in: folder)
    }

    private static func scratchFolder(near folder: URL) -> URL? {
        let base = (try? FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: folder, create: true))
            ?? FileManager.default.temporaryDirectory
        let scratch = base.appendingPathComponent("beeline-" + UUID().uuidString, isDirectory: true)
        return (try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)) == nil ? nil : scratch
    }

    private static func place(_ file: URL, in folder: URL) -> URL? {
        let name = file.deletingPathExtension().lastPathComponent, ext = file.pathExtension
        for number in 1...999 {
            let stem = number == 1 ? name : "\(name) \(number)"
            let target = folder.appendingPathComponent(ext.isEmpty ? stem : "\(stem).\(ext)")
            // moveItem fails if something is already at the target, so a name taken moments ago is skipped.
            if (try? FileManager.default.moveItem(at: file, to: target)) != nil { return target }
            if !FileManager.default.fileExists(atPath: target.path) { return nil }
        }
        return nil
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
            // The avconvert presets encode at a fixed quality, so a video that was already well compressed can
            // come out bigger.
            if suffix == " 720p", let before = size(of: url), let after = size(of: output), after >= before {
                try? FileManager.default.removeItem(at: output)
                Log.append("file tools: 720p copy was not smaller, removed")
                return nil
            }
            return output
        }
        finish(made, "video export")
    }

    private static func finish(_ made: [URL], _ what: String) {
        Log.append("file tools: \(what) made \(made.count)")
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
