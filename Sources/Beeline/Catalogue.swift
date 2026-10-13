import AppKit

enum Kind {
    case app, setting, tab, window, menu, action, file, calculation
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
    /// For windows: moves and resizes the window to a side of the screen, or to fill it.
    var tile: ((Accessibility.Side) -> Void)?
    /// For windows: true when this is the window the user was working in.
    var isCurrentWindow = false
    /// For tabs: closes the tab, and its position in its window.
    var close: (() -> Void)?
    var tabIndex: Int?
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
    /// Files found for `filesQuery`. They arrive a moment after the words are typed.
    private var files: [Item] = []
    private var filesQuery = ""
    private let fileQueue = DispatchQueue(label: "beeline.files", qos: .userInitiated)
    private let actions = Actions.items() + [
        Item(id: "action:Beeline Settings", kind: .action, verb: "", title: "Beeline Settings", subtitle: "Action",
             keywords: "preferences options configure details", icon: NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)) {
            NotificationCenter.default.post(name: Settings.open, object: nil)
        },
    ]
    private var quits: [Item] = []
    private var runningAppPaths: Set<String> = []

    /// The app the user is working in. Its menu commands are the ones offered.
    private var frontApp: NSRunningApplication?
    private let scanQueue = DispatchQueue(label: "beeline.screen-map", qos: .userInitiated)
    private var activationObserver: NSObjectProtocol?
    private let semantic = Semantic()
    private let usage = Usage()

    init() {
        apps = Self.scanApps()
        settings = SettingsPanes.items()
        refreshRunning()
    }

    /// Blocks until apps and settings can be matched by meaning. The app does this in the background instead.
    func prepareMeaningNow() {
        semantic.prepare(actions + apps + settings)
    }

    /// Keeps the screen map current in the background, so it is ready before the bar opens.
    func startWatching() {
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.refreshScreen {}
        }
        let fixed = actions + apps + settings
        scanQueue.async { self.semantic.prepare(fixed) }
        NotificationCenter.default.addObserver(forName: Settings.forgetHistory, object: nil, queue: .main) { [weak self] _ in
            self?.usage.forgetEverything()
        }
        refreshScreen {
            Log.append("screen map: \(self.windows.count + self.planOnlyWindows.count) windows, \(self.menus.count) menu commands in \(self.frontApp?.localizedName ?? "no app")")
        }
    }

    /// Called when an item is run, so the same words find it faster next time.
    func recordUse(of item: Item, query: String) {
        guard item.kind != .calculation, Settings.isOn(Settings.learnFromUse) else { return }
        usage.record(item, query: query)
    }

    func refreshRunning() {
        runningAppPaths = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleURL?.path })
        quits = Actions.quitItems()
    }

    /// Re-reads open windows and the front app's menu commands, then calls `done` on the main thread.
    func refreshScreen(done: @escaping () -> Void) {
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
            let isPlanOnly = { (window: Item) in browserNames.contains(window.subtitle) || window.title == window.subtitle }
            let searchable = found.filter { !isPlanOnly($0) }
            let tiles = found.first(where: \.isCurrentWindow).map(Self.tileItems) ?? []
            DispatchQueue.main.async {
                self.windows = searchable
                self.planOnlyWindows = found.filter(isPlanOnly)
                self.tiles = tiles
                self.menus = menus
                done()
            }
            self.semantic.prepare(searchable + menus)
        }
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

    /// Looks up files named like the query, then calls `done` on the main thread if the query still stands.
    func refreshFiles(for query: String, done: @escaping () -> Void) {
        guard query != filesQuery else { return }
        let words = Matcher.parse(query).tokens
        fileQueue.async {
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
        if let value = Calculator.evaluate(query) {
            let answer = Calculator.format(value)
            return [Item(id: "calculation", kind: .calculation, verb: "", title: "= " + answer, subtitle: "Return copies it",
                         keywords: "", icon: NSImage(systemSymbolName: "equal.circle", accessibilityDescription: nil)) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(answer, forType: .string)
            }]
        }
        let parsed = Matcher.parse(query)
        guard !parsed.tokens.isEmpty else { return [] }
        let wantsClose = !Matcher.quitWords.isDisjoint(with: parsed.tokens)
        let target = parsed.tokens.filter { !Matcher.quitWords.contains($0) }
        // "close every tab about hltv" is about tabs, not about quitting an app.
        if wantsClose, parsed.hint == .tab {
            return closeTabResults(matching: target, limit: limit)
        }
        let all = actions + apps + settings + tabs + windows + tiles + menus + (wantsClose ? quitResults(for: target) : [])
            + (filesQuery == query ? files : [])
        let scored: [(Item, Matcher.Score)] = all.compactMap { item in
            // Something picked before for exactly these words goes to the top, and is no longer a guess,
            // even when the words do not appear in its name. This is how a model guess becomes instant.
            let picked = usage.timesPicked(item, for: query)
            if picked > 0 {
                return (item, Matcher.Score(value: 300 + min(picked, 20) * 5, isComplete: true, timesLearned: picked))
            }
            guard var score = Matcher.score(item, parsed) else { return nil }
            // A menu command acts on the app in front the moment Return is pressed, and can be something
            // like Close All. It is only offered when every typed word matches it, never as a guess.
            if item.kind == .menu, !score.isComplete { return nil }
            // Files are plentiful and loosely named, so they need every word and sit below apps and settings
            // unless a word like "file" or "folder" asked for them.
            if item.kind == .file {
                guard score.isComplete else { return nil }
                score.value -= 45
            }
            score.value += usage.habitBoost(for: item)
            return (item, score)
        }
        // Items matching every typed word come first; partial matches follow, marked as guesses.
        var results: [Item] = scored
            .sorted { ($0.1.isComplete ? 1 : 0, $0.1.value) > ($1.1.isComplete ? 1 : 0, $1.1.value) }
            .prefix(limit)
            .map { item, score in
                var item = item
                item.isGuess = !score.isComplete
                item.source = score.timesLearned > 0 ? .learned(score.timesLearned) : score.isComplete ? .words : .partial
                return item
            }

        // Meaning is the last resort, used only when the words typed matched nothing at all.
        if results.isEmpty, parsed.tokens.contains(where: { $0.count >= 3 }) {
            let pool = parsed.hint.map { hint in all.filter { $0.kind == hint } } ?? all
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

    /// One row to close every matching tab, then a row for each of them.
    private func closeTabResults(matching target: [String], limit: Int) -> [Item] {
        // "close all tabs" with nothing to narrow it is too sweeping to offer as one keypress.
        guard !target.isEmpty else { return [] }
        let wanted = Matcher.Parsed(tokens: target, hint: nil)
        let matches = tabs.filter { Matcher.score($0, wanted)?.isComplete == true && $0.close != nil }
        var rows: [Item] = []
        if matches.count > 1 {
            let closeAll = {
                // Highest position first: closing a tab renumbers the ones after it.
                for tab in matches.sorted(by: { ($0.tabIndex ?? 0) > ($1.tabIndex ?? 0) }) { tab.close?() }
            }
            let browsers = Set(matches.map(\.subtitle)).sorted().joined(separator: ", ")
            rows.append(Item(id: "close-tabs:" + target.joined(separator: " "), kind: .tab, verb: "",
                             title: "Close \(matches.count) Tabs Matching “\(target.joined(separator: " "))”",
                             subtitle: browsers, keywords: "", icon: matches[0].icon, run: closeAll))
        }
        rows += matches.map { tab in
            Item(id: "close:" + tab.id, kind: .tab, verb: "Close tab", title: tab.title, subtitle: tab.subtitle,
                 keywords: tab.keywords, icon: tab.icon, run: tab.close ?? {})
        }
        return Array(rows.prefix(limit))
    }

    /// True when word matching did not settle the request, so the model should be asked.
    func needsChooser(_ query: String, _ results: [Item]) -> Bool {
        guard Settings.isOn(Settings.useOnDeviceModel) else { return false }
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
    func choose(_ query: String) async -> [Item] {
        let parsed = Matcher.parse(query)
        let extra = await Chooser.keywords(for: query)
        var words: [String] = []
        for word in parsed.tokens + extra where word.count >= 3 && !Self.vagueWords.contains(word) && !words.contains(word) {
            words.append(word)
        }
        guard !words.isEmpty else { return [] }
        let expanded = Matcher.Parsed(tokens: words, hint: parsed.hint)

        // Menu commands are left out: a guess must never be one keypress from Close All.
        return (actions + settings + tabs + windows + tiles + apps)
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
                options.append(PlanStep(text: "Close \(name)", icon: tab.icon, run: close, closingTabIndex: tab.tabIndex))
            }
        }
        for item in actions + quits where !item.needsConfirm && !["Restart", "Shut Down", "Log Out"].contains(item.title) {
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
            options.append(PlanStep(text: "Open the app \(item.title) and put it on the left half of the screen", icon: item.icon) {
                Accessibility.openAndPlace(url, .left)
            })
            options.append(PlanStep(text: "Open the app \(item.title) and put it on the right half of the screen", icon: item.icon) {
                Accessibility.openAndPlace(url, .right)
            })
        }
        for item in menus.prefix(150) {
            options.append(PlanStep(text: "In the current app only, run its menu command \(item.subtitle) › \(item.title)", icon: item.icon, run: item.run))
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
