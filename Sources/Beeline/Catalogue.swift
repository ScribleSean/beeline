import AppKit

enum Kind {
    case app, setting, tab, window, menu, action, file, calculation, control, clipboard
}

/// One thing Beeline can do: open an app or settings pane, switch to a tab or window, run a menu command, or perform an action.
/// Why an item is in the results. Shown in the optional details strip.
enum Source {
    case words, partial, learned(Int), model([String]), meaning
}

struct Item: Identifiable {
    let id: String
    let kind: Kind
    var verb: String
    let title: String
    /// Shown as the chip on the right, and searched at low weight.
    let subtitle: String
    /// Extra words that should find this item but are not shown.
    let keywords: String
    let icon: NSImage?
    let run: () -> Void
    /// True when the item was found by meaning, not by the words typed.
    var isGuess = false
    var source = Source.words
    /// True for actions that cannot be undone. The bar asks for Return twice.
    var needsConfirm = false
    /// What the confirm card says under the title, when "This can't be undone" is not the whole story.
    var confirmNote: String?
    /// For windows: moves and resizes the window to a side of the screen, or to fill it.
    var tile: ((Accessibility.Side) -> Void)?
    /// For windows: true when this is the window the user was working in.
    var isCurrentWindow = false
    /// For tabs: closes the tab.
    var close: (() -> Void)?
    /// For buttons and menu commands: whether the target is still there and still the same, checked
    /// right before acting, because the window may have changed since it was read.
    var stillValid: (() -> Bool)?

    /// Runs the item if its target is still valid. False when it was not run.
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
    /// Windows left out of search because something else already stands for them (a browser's tabs,
    /// or the app itself when the window carries only the app's name). A plan can still tile them.
    private var planOnlyWindows: [Item] = []
    /// "Move this window to the left half" and its siblings, for the window in front.
    private var tiles: [Item] = []
    /// Buttons, links, checkboxes and fields inside the front window.
    private var controls: [Item] = []
    /// Files found for `filesQuery`. They arrive a moment after the words are typed.
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

    /// The app the user is working in. Its menu commands are the ones offered.
    private var frontApp: NSRunningApplication?
    private let scanQueue = DispatchQueue(label: "beeline.screen-map", qos: .userInitiated)
    private var activationObserver: NSObjectProtocol?
    private let semantic = Semantic()
    let clipboard = Clipboard()
    private let usage = Usage()

    init() {
        apps = Self.scanApps()
        settings = SettingsPanes.items()
        refreshRunning()
    }

    /// Blocks until apps and settings can be matched by meaning. The app does this in the background instead.
    func prepareMeaningNow() {
        semantic.prepare(actions + apps + settings, permanent: true)
    }

    /// Keeps the screen map current in the background, so it is ready before the bar opens.
    func startWatching() {
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.refreshScreen {}
        }
        let fixed = actions + apps + settings
        scanQueue.async { self.semantic.prepare(fixed, permanent: true) }
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

    /// Called when an item is run, so the same words find it faster next time.
    func recordUse(of item: Item, query: String) {
        guard item.kind != .calculation, item.kind != .clipboard, Settings.isOn(Settings.learnFromUse) else { return }
        usage.record(item, query: query)
    }

    func refreshRunning() {
        runningAppPaths = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleURL?.path })
        quits = Actions.quitItems()
    }

    private var scanning = false
    /// How many scans have finished. Tests use it to tell which scan answered a request.
    private(set) var scansCompleted = 0
    private var scanWaiters: [() -> Void] = []
    /// Callers that asked while a scan was running. They are answered by the scan that starts next,
    /// never by the one already under way, whose picture may predate their request.
    private var nextScanWaiters: [() -> Void] = []

    /// Re-reads open windows and the front app's menu commands, then calls `done` on the main thread.
    /// Requests that arrive while a scan runs are folded into one more scan, never queued one by one.
    func refreshScreen(done: @escaping () -> Void) {
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
        let browserNames = Set(Browser.all.map(\.name))
        let windowed = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && $0 != own }
        scanQueue.async {
            let found = Accessibility.windows(of: windowed, front: front)
            let menus = front.map { Accessibility.menuCommands(of: $0) } ?? []
            let controls = front.map { Accessibility.controls(of: $0) } ?? []
            let isPlanOnly = { (window: Item) in browserNames.contains(window.subtitle) || window.title == window.subtitle }
            let searchable = found.filter { !isPlanOnly($0) }
            let tiles = found.first(where: \.isCurrentWindow).map(Self.tileItems) ?? []
            DispatchQueue.main.async {
                self.windows = searchable
                self.planOnlyWindows = found.filter(isPlanOnly)
                self.tiles = tiles
                self.menus = menus
                self.controls = controls
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
            self.semantic.prepare(searchable + menus)
        }
    }

    private var appFolderDates: [Date] = []

    /// Rescans installed apps when an Applications folder has changed, so a new app appears without a relaunch.
    func refreshAppsIfChanged() {
        let folders = ["/Applications", NSHomeDirectory() + "/Applications"]
        let dates = folders.map { (try? FileManager.default.attributesOfItem(atPath: $0)[.modificationDate] as? Date) ?? .distantPast }
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

    /// Waits for pick history to reach disk. Used before the command-line modes exit.
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
            Item(id: "tile:\(title)", kind: .window, verb: "", title: title, subtitle: window.subtitle,
                 keywords: keywords, icon: window.icon) { tile(side) }
        }
    }

    /// Reads open tabs from every running browser off the main thread, then calls `done` on it.
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

    /// Off for screenshot previews, whose images should not show the names of real files.
    var includeFiles = true

    /// Looks up files named like the query, then calls `done` on the main thread if the query still stands.
    private var newestFileQuery = ""
    private let fileQueryLock = NSLock()

    func refreshFiles(for query: String, done: @escaping () -> Void) {
        guard includeFiles, query != filesQuery else { return }
        let words = Matcher.parse(query).tokens
        fileQueryLock.lock()
        newestFileQuery = query
        fileQueryLock.unlock()
        fileQueue.async {
            // Typing quickly queues a search per keystroke; only the newest one is worth running.
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

    /// The same lookup, waited for. Used by the command-line test mode.
    func loadFilesNow(for query: String) {
        files = Files.search(Matcher.parse(query).tokens)
        filesQuery = query
    }

    func search(_ query: String, limit: Int = 6) -> [Item] {
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
            return chores
        }
        // Arithmetic and conversions answer in a single row; Return copies the answer.
        // The answer card shows the value large, its kind above it, and the working underneath.
        if let answer = Calculator.answer(query) ?? Converter.answer(query) {
            return [Item(id: "calculation", kind: .calculation, verb: "Copy", title: answer.value, subtitle: answer.label,
                         keywords: answer.detail, icon: NSImage(systemSymbolName: "equal.circle", accessibilityDescription: nil)) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(answer.value, forType: .string)
            }]
        }
        if Matcher.isQuestion(query) {
            return [webSearch(query)] + search(words: query, limit: limit - 1).filter { !$0.isGuess }
        }
        return search(words: query, limit: limit)
    }

    /// Opens the default browser on a web search for the text.
    private func webSearch(_ query: String) -> Item {
        var address = URLComponents(string: "https://www.google.com/search")!
        address.queryItems = [URLQueryItem(name: "q", value: query)]
        let url = address.url!
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
        // "close every tab about hltv" is about tabs, not about quitting an app. When no tab matches, the
        // words fall through to the normal search, where the browser's own Close Tab command lives.
        if wantsClose, parsed.hint == .tab {
            let closes = closeTabResults(matching: target, limit: limit)
            if !closes.isEmpty { return closes }
        }
        let all = actions + Desktops.items() + apps + settings + tabs + windows + tiles + menus + controls + (wantsClose ? quitResults(for: target) : [])
            + (filesQuery == query ? files : [])
        let scored: [(Item, Matcher.Score)] = all.compactMap { item in
            // Something picked before for exactly these words goes to the top, and is no longer a guess,
            // even when the words do not appear in its name. This is how a model guess becomes instant.
            let picked = usage.timesPicked(item, for: query)
            if picked > 0 {
                return (item, Matcher.Score(value: 300 + min(picked, 20) * 5, isComplete: true, timesLearned: picked))
            }
            guard var score = Matcher.score(item, parsed) else { return nil }
            // A menu command or a button acts on the app in front the moment Return is pressed, and can be
            // something like Close All. It is only offered when every typed word matches it, never as a guess.
            // The same goes for anything that needs a second Return: "restart chrome" must not offer Restart.
            if item.kind == .menu || item.kind == .control || item.needsConfirm, !score.isComplete { return nil }
            // Files are plentiful and loosely named, so they need every word.
            if item.kind == .file, !score.isComplete { return nil }
            score.value += usage.habitBoost(for: item)
            return (item, score)
        }
        // Items matching every typed word come first, then files, then partial matches marked as guesses.
        // A file never outranks an app, setting or action on its name alone: "wifi" must give Wi-Fi settings,
        // not a file that happens to start with those letters. Asking for a "file" or "folder" lifts them.
        let filesLead = parsed.hint == .file
        func tier(_ entry: (Item, Matcher.Score)) -> Int {
            if entry.1.timesLearned > 0 { return 3 }
            guard entry.1.isComplete else { return 0 }
            return entry.0.kind == .file && !filesLead ? 1 : 2
        }
        // At most two buttons from the front window: they are often file names and labels that crowd out
        // what was meant ("bee" finding three attachments in a chat).
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
                item.source = score.timesLearned > 0 ? .learned(score.timesLearned) : score.isComplete ? .words : .partial
                return item
            }

        // Meaning is the last resort, used only when the words typed matched nothing at all.
        if results.isEmpty, parsed.tokens.contains(where: { $0.count >= 3 }) {
            // Menu commands and window buttons act at once, so they are never offered as a guess by meaning,
            // and nor is anything drastic enough to need a second Return.
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

    /// An app that is already open is switched to, not opened.
    private func markedIfRunning(_ item: Item) -> Item {
        guard item.kind == .app, runningAppPaths.contains(item.id) else { return item }
        var running = item
        running.verb = "Switch to"
        return running
    }

    /// "Quit Safari" rows, only for apps actually named in the request. A quit word on its own, or beside
    /// words that name something else, must never surface a row that closes an app.
    private func quitResults(for target: [String]) -> [Item] {
        guard !target.isEmpty else { return [] }
        return quits.filter { quit in
            let nameWords = quit.title.lowercased().split(separator: " ").dropFirst()
            return target.allSatisfy { word in nameWords.contains { $0.hasPrefix(word) } }
        }
    }

    /// Replaces the tabs read from the browsers. Used by tests.
    func useTabs(_ items: [Item]) {
        tabs = items
    }

    /// One row to close every matching tab, then a row for each of them. Closing is stricter than finding:
    /// each word must start a whole word of the tab's title or address, the browser's name counts only as
    /// "every tab in that browser", and closing more than one tab needs Return twice.
    private func closeTabResults(matching target: [String], limit: Int) -> [Item] {
        var words = target
        var pool = tabs.filter { $0.close != nil }
        var browserNamed: String?
        for browser in Browser.all {
            let nameWords = browser.name.lowercased().split(separator: " ").map(String.init)
            guard let hit = words.first(where: { word in nameWords.contains { $0 == word } }) else { continue }
            words.removeAll { $0 == hit }
            pool = pool.filter { $0.subtitle == browser.shortName }
            browserNamed = browser.shortName
        }
        // "close all tabs" with nothing to narrow it is too sweeping to offer at all.
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

    /// True when word matching did not settle the request, so the model should be asked.
    func needsChooser(_ query: String, _ results: [Item]) -> Bool {
        // A question wants an answer, not a guessed app: "how far is the moon" must not become Safari.
        if Matcher.isQuestion(query) { return false }
        guard Settings.isOn(Settings.useOnDeviceModel), Chooser.isAvailable else { return false }
        guard Matcher.parse(query).tokens.contains(where: { $0.count >= 3 }) else { return false }
        return results.first?.isGuess ?? true
    }

    /// Words the model adds to almost every answer. They match half the catalogue and say nothing.
    private static let vagueWords: Set<String> = [
        "app", "apps", "application", "mac", "macos", "settings", "setting", "system", "tool", "tools", "feature",
        "preferences", "software", "control", "mode", "adjustment", "management", "access", "option", "options",
    ]

    /// Asks the on-device model what the request is about, then finds the items its words describe.
    /// Returns the best few, marked as guesses.
    /// Runs on the main thread, where the catalogue's lists are changed, so it never reads them mid-update.
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

        // Menu commands are left out: a guess must never be one keypress from Close All. Nor is anything
        // that needs a second Return, or an action at all unless the model added words of its own: a guess
        // scored on the typed words alone ("sleep apnea article") must not bring Sleep back.
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

    /// Everything a plan may be built from. Irreversible actions are left out on purpose:
    /// a plan is written by a model reading window and tab titles, which other apps control.
    func planOptions() -> [PlanStep] {
        var options: [PlanStep] = []
        for window in (windows + planOnlyWindows).prefix(16) {
            let name = "window \"\(window.title)\" (\(window.subtitle))" + (window.isCurrentWindow ? " [the current window]" : "")
            options.append(PlanStep(text: "Switch to \(name)", icon: window.icon, run: window.run))
            if let tile = window.tile {
                options.append(PlanStep(text: "Move \(name) to the left half of the screen", icon: window.icon) { tile(.left) })
                options.append(PlanStep(text: "Move \(name) to the right half of the screen", icon: window.icon) { tile(.right) })
                options.append(PlanStep(text: "Make \(name) fill the screen", icon: window.icon) { tile(.full) })
            }
        }
        for tab in tabs.prefix(40) {
            let name = "tab \"\(tab.title)\" (\(tab.subtitle), \(tab.keywords))"
            options.append(PlanStep(text: "Switch to \(name)", icon: tab.icon, run: tab.run))
            if let close = tab.close {
                options.append(PlanStep(text: "Close \(name)", icon: tab.icon, run: close))
            }
        }
        for item in actions + quits where !item.needsConfirm {
            options.append(PlanStep(text: item.title, icon: item.icon, run: item.run))
        }
        for item in settings {
            options.append(PlanStep(text: "Open \(item.title) settings", icon: item.icon, run: item.run))
        }
        let appsWithWindows = Set((windows + planOnlyWindows).map(\.subtitle))
        for item in apps where !item.keywords.isEmpty || runningAppPaths.contains(item.id) {
            options.append(PlanStep(text: "Open the app \(item.title)", icon: item.icon, run: item.run))
            // An app with no window yet cannot be tiled as a window, so opening and placing is one step.
            guard !appsWithWindows.contains(item.title) else { continue }
            let url = URL(fileURLWithPath: item.id)
            // Checked after it settles: the app must be running before the next step relies on it.
            let launched = { NSWorkspace.shared.runningApplications.contains { $0.bundleURL?.standardizedFileURL == url.standardizedFileURL } }
            var left = PlanStep(text: "Open the app \(item.title) and put it on the left half of the screen", icon: item.icon) {
                Accessibility.openAndPlace(url, .left)
            }
            left.settleTime = 3
            left.succeeded = launched
            var right = PlanStep(text: "Open the app \(item.title) and put it on the right half of the screen", icon: item.icon) {
                Accessibility.openAndPlace(url, .right)
            }
            right.settleTime = 3
            right.succeeded = launched
            options += [left, right]
        }
        for item in controls.prefix(60) where !item.needsConfirm {
            var step = PlanStep(text: "In the current window only, \(item.verb.lowercased()) the \(item.subtitle) \"\(item.title)\"",
                                icon: item.icon, run: item.run)
            step.stillValid = item.stillValid
            options.append(step)
        }
        for item in menus.prefix(150) where !item.needsConfirm {
            var step = PlanStep(text: "In the current app only, run its menu command \(item.subtitle) › \(item.title)", icon: item.icon, run: item.run)
            step.stillValid = item.stillValid
            options.append(step)
        }
        return options
    }

    private static func scanApps() -> [Item] {
        let roots = ["/Applications", "/System/Applications", "/System/Applications/Utilities",
                     "/Applications/Utilities", NSHomeDirectory() + "/Applications"]
        var seen = Set<String>()
        var items: [Item] = []
        for root in roots {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: root) else { continue }
            for name in names where name.hasSuffix(".app") && !name.hasPrefix(".") {
                let path = root + "/" + name
                let title = String(name.dropLast(4))
                guard seen.insert(title).inserted else { continue }
                let url = URL(fileURLWithPath: path)
                // "public.app-category.music" becomes the keyword "music", so "music" finds Spotify.
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
