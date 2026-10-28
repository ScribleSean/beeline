import AppKit

enum Kind {
    case app, setting, tab, window, menu, action, file, calculation, control, clipboard
}

enum Source {
    case words, partial, learned(Int), model([String]), meaning, alias
}

struct Item: Identifiable {
    let id: String
    let kind: Kind
    var verb: String
    let title: String
    let subtitle: String
    let keywords: String
    var phrases: [String] = []
    let icon: NSImage?
    let run: () -> Void
    var isGuess = false
    var source = Source.words
    var needsConfirm = false
    var confirmNote: String?
    var tile: ((Accessibility.Side) -> Void)?
    var isCurrentWindow = false
    var close: (() -> Void)?
    var stillValid: (() -> Bool)?
    var target: (() -> CGRect?)?

    var isLearned: Bool {
        if case .learned = source { return true }
        return false
    }

    var isAlias: Bool {
        if case .alias = source { return true }
        return false
    }

    func runIfValid() -> Bool {
        if let stillValid, !stillValid() { return false }
        run()
        return true
    }
}

final class Catalogue {
    private var apps: [Item] = []
    private var settings: [Item] = []
    private var tabs: [Item] = []
    private var windows: [Item] = []
    private var menus: [Item] = []
    private var planOnlyWindows: [Item] = []
    private var tiles: [Item] = []
    private var controls: [Item] = []
    private var files: [Item] = []
    private var filesQuery = ""
    private let fileQueue = DispatchQueue(label: "beeline.files", qos: .userInitiated)
    private let actions = Actions.items() + [
        Item(id: "action:Beeline Settings", kind: .action, verb: "", title: "Beeline Settings", subtitle: "Action",
             keywords: "preferences options configure details", icon: NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)) {
            NotificationCenter.default.post(name: Settings.open, object: nil)
        },
        Item(id: "action:Beeline Welcome", kind: .action, verb: "", title: "Beeline Welcome", subtitle: "Action",
             keywords: "intro start tour setup help", icon: NSImage(systemSymbolName: "hand.wave", accessibilityDescription: nil)) {
            NotificationCenter.default.post(name: Settings.openWelcome, object: nil)
        },
    ]
    private var quits: [Item] = []
    private var runningAppPaths: Set<String> = []

    private var frontApp: NSRunningApplication?
    private let scanQueue = DispatchQueue(label: "beeline.screen-map", qos: .userInitiated)
    private var activationObserver: NSObjectProtocol?
    private let semantic = Semantic()
    let clipboard = Clipboard()
    private let usage = Usage()
    let aliases: Aliases
    var shortcuts: [Item] = []
    private var shortcutsRead = Date.distantPast

    init(aliases: Aliases = .shared) {
        self.aliases = aliases
        apps = Self.scanApps()
        settings = SettingsPanes.items()
        refreshRunning()
        refreshAppsIfChanged()
    }

    /// Construct a catalogue from a supplied snapshot without scanning other apps.
    init(apps: [Item], windows: [Item], quits: [Item], controls: [Item]) {
        self.aliases = .shared
        self.apps = apps
        self.windows = windows
        self.quits = quits
        self.controls = controls
    }

    func prepareMeaningNow() {
        semantic.prepare(actions + apps + settings, permanent: true)
    }

    func startWatching() {
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.refreshScreen(full: false) {}
        }
        let fixed = actions + apps + settings
        scanQueue.async { self.semantic.prepare(fixed, permanent: true) }
        refreshShortcuts()
        NotificationCenter.default.addObserver(forName: Settings.forgetHistory, object: nil, queue: .main) { [weak self] _ in
            self?.usage.forgetEverything()
        }
        NotificationCenter.default.addObserver(forName: Settings.clearClipboard, object: nil, queue: .main) { [weak self] _ in
            self?.clipboard.clear()
        }
        clipboard.start()
        refreshScreen {
            Log.append("screen map: \(self.windows.count + self.planOnlyWindows.count) windows, \(self.menus.count) menu commands in \(self.frontApp?.localizedName ?? "no app")")
        }
    }

    func recordUse(of item: Item, query: String) {
        guard item.kind != .calculation, item.kind != .clipboard, Settings.isOn(Settings.learnFromUse) else { return }
        let oneOff = ["reminder:", "web-search", "desktop-", "file-tool:", "close-tabs:", "close:", "undo"]
        guard !oneOff.contains(where: { item.id.hasPrefix($0) }) else { return }
        usage.record(item, query: query)
    }

    func vocabulary() -> [String] {
        let running = apps.filter { runningAppPaths.contains($0.id) }.map(\.title)
        return aliases.entries.keys.sorted() + ["undo", "dark mode", "Wi-Fi", "night shift"] + actions.map(\.title)
            + running + apps.map(\.title)
    }

    func refreshShortcuts() {
        guard Date().timeIntervalSince(shortcutsRead) > 120 else { return }
        shortcutsRead = Date()
        UserShortcuts.load { [weak self] found in self?.shortcuts = found }
    }

    static func canHaveAlias(_ item: Item) -> Bool {
        guard [.app, .setting, .action, .file, .menu].contains(item.kind) else { return false }
        let oneOff = ["reminder:", "web-search", "desktop-", "file-tool:", "close-tabs:", "close:", "rewrite", "copied", "undo"]
        return !oneOff.contains { item.id.hasPrefix($0) }
    }

    func forgetPick(of item: Item, query: String) {
        usage.forget(item, for: query)
    }

    func refreshRunning() {
        runningAppPaths = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleURL?.path })
        quits = Actions.quitItems()
    }

    private var scanning = false
    private(set) var scansCompleted = 0
    private var scanWaiters: [() -> Void] = []
    private var nextScanWaiters: [() -> Void] = []

    private var scannedApp: pid_t?

    func refreshScreen(full: Bool = true, done: @escaping () -> Void) {
        guard !scanning else {
            nextScanWaiters.append(done)
            return
        }
        scanWaiters.append(done)
        scanning = true
        let own = NSRunningApplication.current
        if let front = NSWorkspace.shared.frontmostApplication, front != own {
            frontApp = front
        }
        let front = frontApp
        let sameApp = front?.processIdentifier == scannedApp
        let browserNames = Set(Browser.all.map(\.name))
        let windowed = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && $0 != own }
        scanQueue.async {
            let found = Accessibility.windows(of: windowed, front: front)
            let menus = full ? front.map { Accessibility.menuCommands(of: $0) } ?? [] : nil
            let controls = full ? front.map { Accessibility.controls(of: $0) } ?? [] : nil
            let isPlanOnly = { (window: Item) in browserNames.contains(window.subtitle) || window.title == window.subtitle }
            let searchable = found.filter { !isPlanOnly($0) }
            let tiles = found.first(where: \.isCurrentWindow).map(Self.tileItems) ?? []
            DispatchQueue.main.async {
                self.windows = searchable
                self.planOnlyWindows = found.filter(isPlanOnly)
                self.tiles = tiles
                if let menus, let controls {
                    self.menus = menus
                    self.controls = controls
                    self.scannedApp = front?.processIdentifier
                } else if !sameApp {
                    self.menus = []
                    self.controls = []
                    self.scannedApp = nil
                }
                self.scansCompleted += 1
                let waiting = self.scanWaiters
                self.scanWaiters = []
                waiting.forEach { $0() }
                self.scanning = false
                if !self.nextScanWaiters.isEmpty {
                    let next = self.nextScanWaiters
                    self.nextScanWaiters = []
                    self.refreshScreen { next.forEach { $0() } }
                }
            }
            self.semantic.prepare(searchable)
        }
    }

    private var appFolderDates: [Date] = []

    func refreshAppsIfChanged() {
        let dates = Self.appFolders.map { (try? FileManager.default.attributesOfItem(atPath: $0)[.modificationDate] as? Date) ?? .distantPast }
        guard dates != appFolderDates else { return }
        let first = appFolderDates.isEmpty
        appFolderDates = dates
        guard !first else { return }
        scanQueue.async {
            let fresh = Self.scanApps()
            DispatchQueue.main.async { self.apps = fresh }
            self.semantic.prepare(fresh, permanent: true)
        }
    }

    func flushHistory() {
        usage.flush()
    }

    private static func tileItems(for window: Item) -> [Item] {
        guard let tile = window.tile else { return [] }
        let choices: [(String, Accessibility.Side, String)] = [
            ("Move This Window to the Left Half", .left, "side snap tile put current"),
            ("Move This Window to the Right Half", .right, "side snap tile put current"),
            ("Make This Window Fill the Screen", .full, "maximise maximize full big enlarge whole current"),
        ]
        return choices.map { title, side, keywords in
            var item = Item(id: "tile:\(title)", kind: .window, verb: "", title: title, subtitle: window.subtitle,
                            keywords: keywords, icon: window.icon) { tile(side) }
            item.target = window.target
            return item
        }
    }

    func refreshTabs(done: @escaping () -> Void) {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier })
        DispatchQueue.global(qos: .userInitiated).async {
            let found = Browser.all.filter { running.contains($0.bundleID) }.flatMap { $0.tabs() }
            DispatchQueue.main.async {
                self.tabs = found
                done()
            }
            self.semantic.prepare(found)
        }
    }

    var includeFiles = true

    private var newestFileQuery = ""
    private let fileQueryLock = NSLock()

    func refreshFiles(for query: String, done: @escaping () -> Void) {
        guard includeFiles, query != filesQuery else { return }
        let words = Matcher.parse(query).tokens
        fileQueryLock.lock()
        newestFileQuery = query
        fileQueryLock.unlock()
        fileQueue.async {
            self.fileQueryLock.lock()
            let current = self.newestFileQuery == query
            self.fileQueryLock.unlock()
            guard current else { return }
            let found = Files.search(words)
            DispatchQueue.main.async {
                self.files = found
                self.filesQuery = query
                done()
            }
        }
    }

    func loadFilesNow(for query: String) {
        files = Files.search(Matcher.parse(query).tokens)
        filesQuery = query
    }

    func search(_ query: String, limit: Int = 6) -> [Item] {
        if let undo = UndoLog.shared.item(for: query) {
            return [undo]
        }
        if query.trimmingCharacters(in: .whitespaces).isEmpty { return [] }
        if let clips = clipboard.results(for: query, limit: limit) {
            return clips
        }
        if let reminder = Reminders.results(for: query) {
            return reminder
        }
        if let desktops = Desktops.results(for: query) {
            return desktops
        }
        if let chores = FileTools.results(for: query) {
            let ids = Set(chores.map(\.id))
            return Array((chores + search(words: query, limit: limit).filter { !ids.contains($0.id) }).prefix(limit))
        }
        if let answer = Calculator.answer(query) ?? Converter.answer(query) {
            return [Item(id: "calculation", kind: .calculation, verb: "Copy", title: answer.value, subtitle: answer.label,
                         keywords: answer.detail, icon: NSImage(systemSymbolName: "equal.circle", accessibilityDescription: nil)) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(answer.value, forType: .string)
            }]
        }
        let found = search(words: query, limit: limit)
        if isQuestion(query, found) {
            return [webSearch(query)] + found.prefix(limit - 1).filter { !$0.isGuess }
        }
        return found
    }

    func isQuestion(_ query: String) -> Bool {
        isQuestion(query, search(words: query, limit: 1))
    }

    private func isQuestion(_ query: String, _ found: [Item]) -> Bool {
        guard Matcher.isQuestion(query) else { return false }
        if query.hasSuffix("?") { return true }
        return !(found.first.map { !$0.isGuess } ?? false)
    }

    static func webSearchURL(for query: String) -> URL {
        var address = URLComponents(string: "https://www.google.com/search")!
        address.queryItems = [URLQueryItem(name: "q", value: query)]
        // URLQueryItem leaves "+" as it is, which a search engine reads as a space: "c++" would reach it as "c  ".
        address.percentEncodedQuery = address.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return address.url!
    }

    private func webSearch(_ query: String) -> Item {
        let url = Self.webSearchURL(for: query)
        return Item(id: "web-search", kind: .action, verb: "Search the web for", title: "“\(query)”", subtitle: "Browser",
                    keywords: "", icon: NSImage(systemSymbolName: "globe", accessibilityDescription: nil)) {
            NSWorkspace.shared.open(url)
        }
    }

    private func search(words query: String, limit: Int) -> [Item] {
        let parsed = Matcher.parse(query)
        guard !parsed.tokens.isEmpty else { return [] }
        let wantsClose = !Matcher.quitWords.isDisjoint(with: parsed.tokens)
        let target = parsed.tokens.filter { !Matcher.quitWords.contains($0) }
        if wantsClose, parsed.hint == .tab {
            let closes = closeTabResults(matching: target, limit: limit)
            if !closes.isEmpty { return closes }
        }
        let all = actions + Desktops.items() + apps + settings + shortcuts + tabs + windows + tiles + menus + controls + (wantsClose ? quitResults(for: target) : [])
            + (filesQuery == query ? files : [])
        let scored: [(Item, Matcher.Score)] = all.compactMap { item in
            if aliases.matches(query, item) {
                return (item, Matcher.Score(value: 1000, isComplete: true, isAlias: true))
            }
            let picked = usage.timesPicked(item, for: query)
            if picked > 0 {
                return (item, Matcher.Score(value: 300 + min(picked, 20) * 5, isComplete: true, timesLearned: picked))
            }
            guard var score = Matcher.score(item, parsed) else { return nil }
            if item.kind == .menu || item.kind == .control || item.needsConfirm, !score.isComplete { return nil }
            if item.kind == .file, !score.isComplete { return nil }
            score.value += usage.habitBoost(for: item)
            return (item, score)
        }
        let filesLead = parsed.hint == .file
        func tier(_ entry: (Item, Matcher.Score)) -> Int {
            if entry.1.isAlias { return 4 }
            if entry.1.timesLearned > 0 { return 3 }
            guard entry.1.isComplete else { return 0 }
            return entry.0.kind == .file && !filesLead ? 1 : 2
        }
        var controlsShown = 0
        var results: [Item] = scored
            .sorted { (tier($0), $0.1.value) > (tier($1), $1.1.value) }
            .filter { entry in
                guard entry.0.kind == .control else { return true }
                controlsShown += 1
                return controlsShown <= 2
            }
            .prefix(limit)
            .map { item, score in
                var item = item
                item.isGuess = !score.isComplete
                item.source = score.isAlias ? .alias : score.timesLearned > 0 ? .learned(score.timesLearned) : score.isComplete ? .words : .partial
                return item
            }

        if results.isEmpty, parsed.tokens.contains(where: { $0.count >= 3 }) {
            let guessable = all.filter { $0.kind != .menu && $0.kind != .control && !$0.needsConfirm }
            let pool = parsed.hint.map { hint in guessable.filter { $0.kind == hint } } ?? guessable
            results = semantic.rank(parsed.tokens.joined(separator: " "), in: pool, limit: 2).map { guess in
                var item = guess.item
                item.isGuess = true
                item.source = .meaning
                return item
            }
        }

        return results.map(markedIfRunning)
    }

    private func markedIfRunning(_ item: Item) -> Item {
        guard item.kind == .app, runningAppPaths.contains(item.id) else { return item }
        var running = item
        running.verb = "Switch to"
        return running
    }

    private func quitResults(for target: [String]) -> [Item] {
        guard !target.isEmpty else { return [] }
        return quits.filter { quit in
            let nameWords = quit.title.lowercased().split(separator: " ").dropFirst()
            return target.allSatisfy { word in nameWords.contains { $0.hasPrefix(word) } }
        }
    }

    func useTabs(_ items: [Item]) {
        tabs = items
    }

    private func closeTabResults(matching target: [String], limit: Int) -> [Item] {
        var words = target.filter { !["browser", "browsers", "web"].contains($0) }
        var pool = tabs.filter { $0.close != nil }
        var browserNamed: String?
        let browserWords = ["chrome": "Chrome", "safari": "Safari", "brave": "Brave Browser", "edge": "Microsoft Edge"]
        if let hit = words.first(where: { browserWords[$0] != nil }), let shortName = browserWords[hit] {
            words.removeAll { $0 == hit }
            pool = pool.filter { $0.subtitle == shortName }
            browserNamed = shortName
        }
        guard !words.isEmpty || browserNamed != nil else { return [] }
        let matches = pool.filter { Matcher.matchesForClose($0, words) }
        var rows: [Item] = []
        if matches.count > 1 {
            let closeAll = { for tab in matches { tab.close?() } }
            let browsers = Set(matches.map(\.subtitle)).sorted().joined(separator: ", ")
            let about = words.isEmpty ? "in \(browserNamed ?? "")" : "Matching “\(words.joined(separator: " "))”"
            var row = Item(id: "close-tabs:" + target.joined(separator: " "), kind: .tab, verb: "",
                           title: "Close \(matches.count) Tabs \(about)", subtitle: browsers, keywords: "",
                           icon: matches[0].icon, run: closeAll)
            row.needsConfirm = true
            row.confirmNote = "\(matches.count) tabs in \(browsers) close. Anything unsaved in them is lost."
            rows.append(row)
        }
        rows += matches.map { tab in
            Item(id: "close:" + tab.id, kind: .tab, verb: "Close tab", title: tab.title, subtitle: tab.subtitle,
                 keywords: tab.keywords, icon: tab.icon, run: tab.close ?? {})
        }
        return Array(rows.prefix(limit))
    }

    func needsChooser(_ query: String, _ results: [Item]) -> Bool {
        if Matcher.isQuestion(query) { return false }
        guard Settings.isOn(Settings.useOnDeviceModel), Chooser.isAvailable else { return false }
        guard Matcher.parse(query).tokens.contains(where: { $0.count >= 3 }) else { return false }
        return results.first?.isGuess ?? true
    }

    private static let vagueWords: Set<String> = [
        "app", "apps", "application", "mac", "macos", "settings", "setting", "system", "tool", "tools", "feature",
        "preferences", "software", "control", "mode", "adjustment", "management", "access", "option", "options",
    ]

    @MainActor
    func choose(_ query: String) async -> [Item] {
        let parsed = Matcher.parse(query)
        let extra = await Chooser.keywords(for: query)
        var words: [String] = []
        for word in parsed.tokens + extra where word.count >= 3 && !Self.vagueWords.contains(word) && !words.contains(word) {
            words.append(word)
        }
        guard !words.isEmpty else { return [] }
        let expanded = Matcher.Parsed(tokens: words, hint: parsed.hint)

        let candidates = (actions.filter { !$0.needsConfirm && !extra.isEmpty } + settings + tabs + windows + tiles + apps)
        return candidates
            .compactMap { item in Matcher.score(item, expanded, anyWord: true).map { (item, $0.value) } }
            .sorted { $0.1 > $1.1 }
            .prefix(3)
            .map { item, _ in
                var pick = markedIfRunning(item)
                pick.isGuess = true
                pick.source = .model(extra)
                return pick
            }
    }

    func planOptions(for request: String = "") -> [PlanStep] {
        var options: [PlanStep] = []
        func clean(_ title: String) -> String {
            ScreenText.quote(String(ScreenText.sanitize(title).split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(120)))
        }
        let frontName = frontApp?.localizedName
        let ordered = (windows + planOnlyWindows).sorted { a, b in
            (a.isCurrentWindow ? 0 : a.subtitle == frontName ? 1 : 2) < (b.isCurrentWindow ? 0 : b.subtitle == frontName ? 1 : 2)
        }
        for window in ordered.prefix(16) {
            let name = "window \(clean(window.title)) (\(clean(window.subtitle)))" + (window.isCurrentWindow ? " [the current window]" : "")
            var switchTo = PlanStep(text: "Switch to \(name)", icon: window.icon, run: window.run)
            switchTo.target = window.target
            options.append(switchTo)
            if let tile = window.tile {
                for (text, side) in [("Move \(name) to the left half of the screen", Accessibility.Side.left),
                                     ("Move \(name) to the right half of the screen", .right),
                                     ("Make \(name) fill the screen", .full)] {
                    var step = PlanStep(text: text, icon: window.icon) { tile(side) }
                    step.target = window.target
                    options.append(step)
                }
            }
        }
        for tab in tabs.prefix(40) {
            let name = "tab \(clean(tab.title)) (\(ScreenText.quote(tab.subtitle)), \(clean(tab.keywords)))"
            options.append(PlanStep(text: "Switch to \(name)", icon: tab.icon, run: tab.run))
            if let close = tab.close {
                options.append(PlanStep(text: "Close \(name)", icon: tab.icon, run: close))
            }
        }
        let requestWords = Matcher.parse(request).tokens
        let namedQuits = quits.filter { quit in
            let nameWords = Matcher.parse(String(quit.title.dropFirst(5))).tokens
            return nameWords.contains { word in requestWords.contains { $0.hasPrefix(word) || word.hasPrefix($0) } }
        }
        for item in actions where !item.needsConfirm {
            options.append(PlanStep(text: item.title, icon: item.icon, run: item.run))
        }
        for item in namedQuits where !item.needsConfirm {
            options.append(PlanStep(text: "Quit \(ScreenText.quote(String(item.title.dropFirst(5))))", icon: item.icon, run: item.run))
        }
        for item in settings {
            options.append(PlanStep(text: "Open \(item.title) settings", icon: item.icon, run: item.run))
        }
        let appsWithWindows = Set((windows + planOnlyWindows).map(\.subtitle))
        for item in apps where !item.keywords.isEmpty || runningAppPaths.contains(item.id) {
            options.append(PlanStep(text: "Open the app \(ScreenText.quote(item.title))", icon: item.icon, run: item.run))
            guard !appsWithWindows.contains(item.title) else { continue }
            let url = URL(fileURLWithPath: item.id)
            // Compared by bundle id, because an app's path can be a link into a system cryptex.
            let bundleID = Bundle(url: url)?.bundleIdentifier
            let launched = {
                NSWorkspace.shared.runningApplications.contains {
                    (bundleID != nil && $0.bundleIdentifier == bundleID) || $0.bundleURL?.standardizedFileURL == url.standardizedFileURL
                }
            }
            var left = PlanStep(text: "Open the app \(ScreenText.quote(item.title)) and put it on the left half of the screen", icon: item.icon) {
                Accessibility.openAndPlace(url, .left)
            }
            left.settleTime = 3
            left.succeeded = launched
            var right = PlanStep(text: "Open the app \(ScreenText.quote(item.title)) and put it on the right half of the screen", icon: item.icon) {
                Accessibility.openAndPlace(url, .right)
            }
            right.settleTime = 3
            right.succeeded = launched
            options += [left, right]
        }
        for item in controls.prefix(60) where !item.needsConfirm {
            var step = PlanStep(text: "In the current window only, \(ScreenText.sanitize(item.verb.lowercased())) the \(ScreenText.sanitize(item.subtitle)) \(clean(item.title))",
                                icon: item.icon, run: item.run)
            step.stillValid = item.stillValid
            step.target = item.target
            options.append(step)
        }
        let dynamicMenus = ["Open Recent", "History", "Bookmarks", "Recent Items", "Reading List", "Recently Closed"]
        let plannable = menus.filter { menu in !dynamicMenus.contains { menu.subtitle.contains($0) } }
        for item in plannable.prefix(150) where !item.needsConfirm {
            var step = PlanStep(text: "In the current app only, run its menu command \(clean(item.subtitle)) › \(clean(item.title))", icon: item.icon, run: item.run)
            step.stillValid = item.stillValid
            step.target = item.target
            options.append(step)
        }
        return options
    }

    static let appFolders = ["/Applications", "/System/Applications", "/System/Applications/Utilities",
                             "/Applications/Utilities", NSHomeDirectory() + "/Applications"]

    private static func scanApps() -> [Item] {
        var seen = Set<String>()
        var items: [Item] = []
        var paths: [String] = ["/System/Library/CoreServices/Finder.app"]
        for root in appFolders {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: root) else { continue }
            for name in names where !name.hasPrefix(".") {
                if name.hasSuffix(".app") {
                    paths.append(root + "/" + name)
                } else if let inside = try? FileManager.default.contentsOfDirectory(atPath: root + "/" + name) {
                    paths += inside.filter { $0.hasSuffix(".app") && !$0.hasPrefix(".") }.map { root + "/" + name + "/" + $0 }
                }
            }
        }
        for path in paths {
            do {
                let name = (path as NSString).lastPathComponent
                guard FileManager.default.fileExists(atPath: path) else { continue }
                let title = String(name.dropLast(4))
                guard seen.insert(title).inserted else { continue }
                let url = URL(fileURLWithPath: path)
                let category = (Bundle(url: url)?.object(forInfoDictionaryKey: "LSApplicationCategoryType") as? String ?? "")
                    .replacingOccurrences(of: "public.app-category.", with: "")
                    .replacingOccurrences(of: "-", with: " ")
                let keywords = [category, AppAliases.words[title] ?? ""].filter { !$0.isEmpty }.joined(separator: " ")
                items.append(Item(id: path, kind: .app, verb: "Open", title: title, subtitle: "App", keywords: keywords,
                                  icon: NSWorkspace.shared.icon(forFile: path)) {
                    NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
                })
            }
        }
        return items
    }
}
