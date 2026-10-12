import AppKit

enum Kind {
    case app, setting, tab, window, menu, action
}

/// One thing Beeline can do: open an app or settings pane, switch to a tab or window, run a menu command, or perform an action.
struct Item: Identifiable {
    let id: String
    let kind: Kind
    let verb: String
    let title: String
    /// Shown as the chip on the right, and searched at low weight.
    let subtitle: String
    /// Extra words that should find this item but are not shown.
    let keywords: String
    let icon: NSImage?
    let run: () -> Void
    /// True when the item was found by meaning, not by the words typed.
    var isGuess = false
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
    /// Browser windows are not searched, since their tabs are, but a plan can still tile them.
    private var browserWindows: [Item] = []
    private let actions = Actions.items()
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
        refreshScreen {
            // Appended to the launch log so the screen map can be checked without seeing the screen.
            let line = "screen map: \(self.windows.count) windows, \(self.menus.count) menu commands in \(self.frontApp?.localizedName ?? "no app")\n"
            if let handle = FileHandle(forWritingAtPath: NSHomeDirectory() + "/Library/Logs/Beeline.log") {
                handle.seekToEndOfFile()
                handle.write(line.data(using: .utf8)!)
                handle.closeFile()
            }
        }
    }

    /// Called when an item is run, so the same words find it faster next time.
    func recordUse(of item: Item, query: String) {
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
            // Browser windows are left out of search: their tabs are listed instead.
            let searchable = found.filter { !browserNames.contains($0.subtitle) }
            DispatchQueue.main.async {
                self.windows = searchable
                self.browserWindows = found.filter { browserNames.contains($0.subtitle) }
                self.menus = menus
                done()
            }
            self.semantic.prepare(searchable + menus)
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

    func search(_ query: String, limit: Int = 6) -> [Item] {
        let parsed = Matcher.parse(query)
        guard !parsed.tokens.isEmpty else { return [] }
        // Quit rows stay out of the way unless quitting is what was asked for.
        let wantsQuit = !Matcher.quitWords.isDisjoint(with: parsed.tokens)
        let all = actions + (wantsQuit ? quits : []) + apps + settings + tabs + windows + menus
        let scored: [(Item, Matcher.Score)] = all.compactMap { item in
            // Something picked before for exactly these words goes to the top, and is no longer a guess,
            // even when the words do not appear in its name. This is how a model guess becomes instant.
            let picked = usage.timesPicked(item, for: query)
            if picked > 0 {
                return (item, Matcher.Score(value: 300 + min(picked, 20) * 5, isComplete: true))
            }
            guard var score = Matcher.score(item, parsed) else { return nil }
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
                return item
            }

        // Meaning is the last resort, used only when the words typed matched nothing at all.
        if results.isEmpty, parsed.tokens.contains(where: { $0.count >= 3 }) {
            let pool = parsed.hint.map { hint in all.filter { $0.kind == hint } } ?? all
            results = semantic.rank(parsed.tokens.joined(separator: " "), in: pool, limit: 2).map { guess in
                var item = guess.item
                item.isGuess = true
                return item
            }
        }

        return results.map { item in
            guard item.kind == .app, runningAppPaths.contains(item.id) else { return item }
            var running = Item(id: item.id, kind: .app, verb: "Switch to", title: item.title, subtitle: item.subtitle,
                               keywords: item.keywords, icon: item.icon, run: item.run)
            running.isGuess = item.isGuess
            return running
        }
    }

    /// True when word matching did not settle the request, so the model should be asked.
    func needsChooser(_ query: String, _ results: [Item]) -> Bool {
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

        return (actions + settings + tabs + windows + apps + menus)
            .compactMap { item in Matcher.score(item, expanded, anyWord: true).map { (item, $0.value) } }
            .sorted { $0.1 > $1.1 }
            .prefix(3)
            .map { item, _ in
                var pick = item
                if pick.kind == .app, runningAppPaths.contains(pick.id) {
                    pick = Item(id: pick.id, kind: .app, verb: "Switch to", title: pick.title, subtitle: pick.subtitle,
                                keywords: pick.keywords, icon: pick.icon, run: pick.run)
                }
                pick.isGuess = true
                return pick
            }
    }

    /// Everything a plan may be built from. Irreversible actions are left out on purpose:
    /// a plan is written by a model reading window and tab titles, which other apps control.
    func planOptions() -> [PlanStep] {
        var options: [PlanStep] = []
        for window in (windows + browserWindows).prefix(16) {
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
        for item in apps where !item.keywords.isEmpty || runningAppPaths.contains(item.id) {
            options.append(PlanStep(text: "Open the app \(item.title)", icon: item.icon, run: item.run))
        }
        for item in menus.prefix(150) {
            options.append(PlanStep(text: "Run the menu command \(item.subtitle) › \(item.title)", icon: item.icon, run: item.run))
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
