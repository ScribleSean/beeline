import SwiftUI

enum Theme {
    static let yellow = Color(red: 1.0, green: 0.761, blue: 0.102)
    static let ink = Color(red: 0.102, green: 0.078, blue: 0.027)

    private static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }

    static let accent = adaptive(light: NSColor(red: 0.69, green: 0.52, blue: 0.0, alpha: 1),
                                 dark: NSColor(red: 1.0, green: 0.761, blue: 0.102, alpha: 1))
    static let warmth = adaptive(light: NSColor(red: 0.984, green: 0.953, blue: 0.863, alpha: 0.55),
                                 dark: NSColor(red: 0.16, green: 0.13, blue: 0.06, alpha: 0.35))
    static let capsule = adaptive(light: .white, dark: NSColor(white: 1, alpha: 0.08))
    static let capsuleEdge = adaptive(light: NSColor(red: 0.925, green: 0.902, blue: 0.84, alpha: 1),
                                      dark: NSColor(white: 1, alpha: 0.09))
    static let raised = adaptive(light: .white, dark: NSColor(white: 1, alpha: 0.1))
    static let honeyTile = adaptive(light: NSColor(red: 1.0, green: 0.953, blue: 0.80, alpha: 1),
                                    dark: NSColor(red: 1.0, green: 0.761, blue: 0.102, alpha: 0.16))
    static let panelEdge = adaptive(light: NSColor(white: 1, alpha: 0.7), dark: NSColor(white: 1, alpha: 0.1))
}

struct BarAction: Identifiable, Equatable {
    enum ID { case open, copy, copyMarkdown, reveal, forget, alias }
    let id: ID
    let title: String
    let symbol: String

    var keys: String {
        switch id {
        case .open: return "↩"
        case .copy: return "⇧⌘C"
        case .copyMarkdown: return "⌥⇧⌘C"
        case .reveal: return "⌘↩"
        case .forget: return "⇧⌘⌫"
        case .alias: return "⇧⌘A"
        }
    }

    var spokenKeys: String {
        switch id {
        case .open: return "Return"
        case .copy: return "Shift Command C"
        case .copyMarkdown: return "Option Shift Command C"
        case .reveal: return "Command Return"
        case .forget: return "Shift Command Delete"
        case .alias: return "Shift Command A"
        }
    }
}

final class BarModel: ObservableObject {
    @Published var query = "" {
        didSet {
            // The text field writes the same text back on focus, which must not close the panel.
            if query != oldValue { actionTarget = nil }
            refresh()
        }
    }
    @Published var results: [Item] = []
    @Published var selected = 0
    @Published var focusTick = 0

    @Published var needsAccess = false
    @Published var showsShortcutHint = true

    static let shortcutHintOpens = 5

    func countOpen(_ defaults: UserDefaults = .standard) {
        let opens = defaults.integer(forKey: Settings.barOpens) + 1
        defaults.set(opens, forKey: Settings.barOpens)
        showsShortcutHint = opens <= Self.shortcutHintOpens || Settings.activeShortcut == nil
    }

    let catalogue = Catalogue()
    var onRun: (Item) -> Void = { _ in }
    var onRequestAccess: () -> Void = {}

    @Published var searchMilliseconds = 0.0
    @Published var modelMilliseconds: Double?

    @Published var isThinking = false
    private var thinking: Task<Void, Never>?
    private var askedQuery: String?
    private var modelPicks: [Item] = []

    func refresh() {
        defer { speakSelectionSoon() }
        let typed = query
        catalogue.refreshFiles(for: typed) { [weak self] in
            if let self, self.query == typed { self.refreshInBackground() }
        }
        let started = Date()
        let found = catalogue.search(query)
        searchMilliseconds = Date().timeIntervalSince(started) * 1000
        if query != askedQuery { armedID = nil }

        if query == askedQuery {
            results = decorated(merged(modelPicks, found))
            return
        }

        clearPlan()
        results = decorated(found)
        selected = 0
        thinking?.cancel()
        isThinking = false
        askedQuery = nil
        modelPicks = []
        modelMilliseconds = nil
        let isRewrite = Rewrite.selection != nil && Rewrite.isRequest(query)
        guard !isRewrite, catalogue.needsChooser(query, found) else { return }

        let asked = query
        askedQuery = asked
        thinking = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard let self, !Task.isCancelled else { return }
            self.isThinking = true
            let asking = Date()
            let picks = await self.catalogue.choose(asked)
            guard !Task.isCancelled, asked == self.query else { return }
            self.modelMilliseconds = Date().timeIntervalSince(asking) * 1000
            self.isThinking = false
            self.modelPicks = picks
            if !picks.isEmpty, self.armedID == nil {
                let selectedID = self.results.indices.contains(self.selected) ? self.results[self.selected].id : nil
                self.results = self.decorated(self.merged(picks, self.results))
                self.selected = selectedID.flatMap { id in self.results.firstIndex { $0.id == id } } ?? 0
                self.speakSelectionSoon()
            }
        }
    }

    func refreshInBackground() {
        guard !isShowingPlan, !showsActions else { return }
        if let armedID {
            if let armed = results.first(where: { $0.id == armedID }), armed.stillValid?() == false { self.armedID = nil }
            return
        }
        let selectedID = results.indices.contains(selected) ? results[selected].id : nil
        refresh()
        if let selectedID, let index = results.firstIndex(where: { $0.id == selectedID }) { selected = index }
        speakSelectionSoon()
    }

    var isOpen = true {
        didSet {
            spokenRow = nil
            pendingSpeech?.invalidate()
            pendingSpeech = nil
        }
    }
    private var spokenRow: String?
    private var pendingSpeech: Timer?

    func say(_ text: String) {
        if isOpen { Announce.say(text, priority: .high) }
    }

    private func speakSelectionSoon() {
        pendingSpeech?.invalidate()
        let timer = Timer(timeInterval: 0.4, repeats: false) { [weak self] _ in self?.speakSelection() }
        RunLoop.main.add(timer, forMode: .common)
        pendingSpeech = timer
    }

    func speakSelection() {
        pendingSpeech?.invalidate()
        pendingSpeech = nil
        guard isOpen, voiceLevel == nil, !showsActions else { return }
        let text: String
        if isShowingPlan || armedID != nil || query.isEmpty {
            spokenRow = nil
            return
        }
        let key: String
        if results.indices.contains(selected) {
            let item = results[selected]
            let number = results[...selected].filter { $0.kind == .clipboard }.count
            text = Announce.spoken(item, number: number)
            key = item.id + "\n" + text
        } else if !query.isEmpty {
            text = "No results"
            key = text
        } else {
            spokenRow = nil
            return
        }
        guard key != spokenRow else { return }
        spokenRow = key
        Announce.say(text)
    }

    private func merged(_ picks: [Item], _ found: [Item]) -> [Item] {
        let picked = Set(picks.map(\.id))
        return Array((picks + found.filter { !picked.contains($0.id) && $0.id != Self.claudeRowID && $0.id != Self.rewriteRowID }).prefix(6))
    }

    static let claudeRowID = "ask-claude"
    static let rewriteRowID = "rewrite-selection"

    @Published var plan: Plan? {
        didSet { if let plan { say(Announce.plan(plan)) } }
    }
    @Published var isAskingClaude = false {
        didSet { if isAskingClaude, !oldValue { say("Asking Claude") } }
    }
    @Published var planProblem: String? {
        didSet { if let planProblem { say(planProblem) } }
    }
    var onRunPlan: (Plan) -> Void = { _ in }
    private var planning: Task<Void, Never>?

    @Published var claudeAnswer: String? {
        didSet { if let claudeAnswer { say(claudeAnswer) } }
    }

    @Published var rewritten: String? {
        didSet { if let rewritten { say(rewritten) } }
    }
    private var rewriteTarget: Rewrite.Selection?

    var isShowingPlan: Bool { plan != nil || isAskingClaude || planProblem != nil || claudeAnswer != nil || rewritten != nil }

    @Published var voiceNote: String?
    /// Set while the microphone listens; rows wait until it stops so the mic never hears VoiceOver.
    @Published var voiceLevel: Double? {
        didSet { if voiceLevel == nil, oldValue != nil { speakSelectionSoon() } }
    }

    @Published var tip = BarModel.tips[0]
    static let tips = [
        "night shift", "20c in f", "remind me to call Sam at 5", "close every tab about flights", "clip",
        "100 usd in eur", "time in tokyo", "dark mode", "quit safari", "window left", "how far is the moon",
        "15% of 240", "beeline settings",
    ]

    func newTip() {
        tip = Self.tips.filter { $0 != tip }.randomElement() ?? tip
    }

    private func decorated(_ items: [Item]) -> [Item] {
        if Settings.isOn(Settings.offerClaude), let selection = Rewrite.selection, Rewrite.isRequest(query) {
            let preview = selection.text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            let row = Item(id: Self.rewriteRowID, kind: .action, verb: "", title: "Rewrite the selected text",
                           subtitle: "“\(preview.prefix(60))\(preview.count > 60 || selection.text.contains("\n") ? "…" : "")”",
                           keywords: "", icon: NSImage(systemSymbolName: "text.cursor", accessibilityDescription: nil), run: {})
            return [row] + items.filter { $0.id != Self.claudeRowID }
        }
        let words = query.split(separator: " ").count
        guard Self.offersClaude(for: query), Settings.isOn(Settings.offerClaude), items.first?.kind != .calculation else { return items }
        let question = Self.isPlainQuestion(query, catalogue.isQuestion(query))
        let row = Item(id: Self.claudeRowID, kind: .action, verb: "", title: question ? "Ask Claude" : "Ask Claude to work it out",
                       subtitle: "", keywords: "",
                       icon: NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil), run: {})
        let leads = Self.claudeLeads(question: question, words: words, top: items.first, followUp: LastRun.shared.isFollowUp(query),
                                     strong: LastRun.shared.isFollowUp(query, strong: true))
        return leads ? [row] + items : items + [row]
    }

    static func offersClaude(for query: String, last: LastRun = .shared) -> Bool {
        query.split(separator: " ").count >= 2 || (Usage.normalise(query.trimmingCharacters(in: .punctuationCharacters)) == "again" && last.isFollowUp(query))
    }

    static func claudeLeads(question: Bool, words: Int, top: Item?, followUp: Bool, strong: Bool = false) -> Bool {
        question || (words >= 5 && (top?.isGuess ?? true))
            || (followUp && words >= 2 && top?.id != "undo" && (strong || (top?.isGuess ?? true)))
    }

    static func isPlainQuestion(_ query: String, _ isQuestion: Bool, last: LastRun = .shared) -> Bool {
        guard isQuestion else { return false }
        let asked = query.trimmingCharacters(in: CharacterSet(charactersIn: "?"))
        let words = Usage.normalise(asked).split(separator: " ")
        let opener = words.prefix(2).joined(separator: " ")
        let polite = ["can you", "could you", "would you", "will you", "what about", "how about"].contains(opener)
        let orders = (words.first == "do" && !["i", "you", "we", "they"].contains(words.dropFirst().first ?? ""))
            || (polite && last.isFollowUp(query, strong: true))
        if Matcher.isQuestion(asked), !orders { return true }
        return !last.isFollowUp(query)
    }

    private func askClaudeQuestion() {
        clearPlan()
        isAskingClaude = true
        let asked = query
        planning = Task { @MainActor [weak self] in
            let result = await Planner.answer(asked)
            guard let self, !Task.isCancelled, asked == self.query else { return }
            self.isAskingClaude = false
            switch result {
            case .success(let text): self.claudeAnswer = text
            case .failure(.message(let message)): self.planProblem = message
            }
        }
    }

    private func askRewrite() {
        guard let selection = Rewrite.selection else { return }
        clearPlan()
        isAskingClaude = true
        let asked = query
        rewriteTarget = selection
        planning = Task { @MainActor [weak self] in
            let result = await Rewrite.ask(asked, text: selection.text)
            guard let self, !Task.isCancelled, asked == self.query else { return }
            self.isAskingClaude = false
            switch result {
            case .success(let text): self.rewritten = text
            case .failure(.message(let message)): self.planProblem = message
            }
        }
    }

    private func askClaude() {
        if Self.isPlainQuestion(query, catalogue.isQuestion(query)) { return askClaudeQuestion() }
        clearPlan()
        isAskingClaude = true
        let asked = query
        let previous = LastRun.shared.latest()
        let options = catalogue.planOptions(for: asked, previous: previous)
        planning = Task { @MainActor [weak self] in
            let result = await Planner.plan(for: asked, options: options, previous: previous)
            guard let self, !Task.isCancelled, asked == self.query else { return }
            self.isAskingClaude = false
            switch result {
            case .success(let plan):
                Log.append("plan: \(plan.steps.count) steps from \(options.count) options")
            case .failure(.message(let message)):
                Log.append("plan failed: \(message)")
            }
            switch result {
            case .success(let plan) where plan.steps.isEmpty:
                self.planProblem = plan.note.isEmpty ? "Claude found no way to do that with what's open." : plan.note
            case .success(let plan):
                self.plan = plan
            case .failure(.message(let message)):
                self.planProblem = message
            }
        }
    }

    func clearPlan() {
        planning?.cancel()
        planning = nil
        plan = nil
        isAskingClaude = false
        planProblem = nil
        claudeAnswer = nil
        rewritten = nil
        speakSelectionSoon()
    }

    @Published var armedID: String? {
        didSet {
            if armedID == nil, oldValue != nil { speakSelectionSoon() }
            guard let armedID, armedID != oldValue else { return }
            armedAt = Date()
            spokenRow = nil
            if let armed = results.first(where: { $0.id == armedID }) { say(Announce.confirm(armed)) }
        }
    }
    private(set) var armedAt = Date.distantPast

    func run(_ item: Item) {
        actionTarget = nil
        if item.id == Self.claudeRowID {
            askClaude()
            return
        }
        if item.id == Self.rewriteRowID {
            askRewrite()
            return
        }
        if item.needsConfirm, armedID != item.id {
            armedID = item.id
            return
        }
        armedID = nil
        if !Demo.isVoice { catalogue.recordUse(of: item, query: query) }
        onRun(item)
    }

    func confirmByClick() {
        guard Date().timeIntervalSince(armedAt) > 0.4 else { return }
        confirmArmed()
    }

    private func confirmArmed() {
        guard let armedID else { return }
        guard let armed = results.first(where: { $0.id == armedID }) else {
            self.armedID = nil
            return
        }
        run(armed)
    }

    func move(_ delta: Int) {
        armedID = nil
        actionTarget = nil
        guard !results.isEmpty, !isShowingPlan else { return }
        selected = (selected + delta + results.count) % results.count
        speakSelection()
    }

    @Published private(set) var actionTarget: Item?
    @Published var actionSelected = 0
    @Published private(set) var panelActions: [BarAction] = []
    @Published private(set) var actionFilter = ""
    var visibleActions: [BarAction] {
        let words = Self.words(actionFilter)
        guard !words.isEmpty else { return panelActions }
        return panelActions.filter { action in
            let title = Self.words(action.title)
            return words.allSatisfy { word in title.contains { $0.hasPrefix(word) } }
        }
    }
    var showsActions: Bool { actionTarget != nil && !isShowingPlan && armedID == nil }
    var pasteboard = NSPasteboard.general
    var revealInFinder: (URL) -> Void = { NSWorkspace.shared.activateFileViewerSelecting([$0]) }

    var focusedItem: Item? {
        if showsActions, let actionTarget { return actionTarget }
        guard !isShowingPlan, armedID == nil, results.indices.contains(selected) else { return nil }
        return results[selected]
    }

    func actions(for item: Item) -> [BarAction] {
        guard item.id != Self.claudeRowID, item.id != Self.rewriteRowID, item.kind != .calculation else { return [] }
        var list = [BarAction(id: .open, title: item.verb.isEmpty ? "Run" : item.verb, symbol: "return")]
        if let copy = Self.copyable(item) { list.append(BarAction(id: .copy, title: copy.title, symbol: "doc.on.doc")) }
        if Self.markdownLink(item) != nil {
            list.append(BarAction(id: .copyMarkdown, title: "Copy as Markdown link", symbol: "link"))
        }
        if Self.path(of: item) != nil { list.append(BarAction(id: .reveal, title: "Show in Finder", symbol: "folder")) }
        if item.isAlias {
            list.append(BarAction(id: .forget, title: "Remove alias", symbol: "minus.circle"))
        } else {
            if item.isLearned { list.append(BarAction(id: .forget, title: "Forget pick", symbol: "arrow.uturn.backward")) }
            if let alias = Aliases.normalise(query), alias.count <= 12, Catalogue.canHaveAlias(item) {
                list.append(BarAction(id: .alias, title: "Make “\(alias)” its alias", symbol: "character.cursor.ibeam"))
            }
        }
        return list.count > 1 ? list : []
    }

    var focusedActions: [BarAction] { focusedItem.map(actions(for:)) ?? [] }

    static func path(of item: Item) -> String? {
        guard [.app, .file].contains(item.kind), item.id.hasPrefix("/"), FileManager.default.fileExists(atPath: item.id) else { return nil }
        return item.id
    }

    static func copyable(_ item: Item) -> (title: String, text: String)? {
        if [.app, .file].contains(item.kind), item.id.hasPrefix("/") { return ("Copy path", item.id) }
        if let link = item.link { return ("Copy link", link.absoluteString) }
        guard item.kind != .clipboard, !item.title.isEmpty else { return nil }
        return ("Copy name", item.title)
    }

    static func markdownLink(_ item: Item) -> String? {
        guard item.kind == .tab, let link = item.link?.absoluteString else { return nil }
        // A blank line in a title would end the link, so whitespace runs become one space.
        let title = item.title.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        var text = title.isEmpty ? link : title
        for mark in ["\\", "[", "]", "`", "<"] { text = text.replacingOccurrences(of: mark, with: "\\" + mark) }
        let target = link.replacingOccurrences(of: "(", with: "%28").replacingOccurrences(of: ")", with: "%29")
        return "[\(text)](\(target))"
    }

    private static func words(_ text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    }

    @discardableResult
    func typeInActions(_ characters: String) -> Bool {
        guard showsActions, !characters.isEmpty,
              characters.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) && !(0xF700...0xF8FF).contains($0.value) })
        else { return false }
        setActionFilter(actionFilter + characters)
        return true
    }

    func escapeInActions() {
        if actionFilter.isEmpty { closeActions() } else { setActionFilter("") }
    }

    func deleteActionFilter(all: Bool = false) {
        guard showsActions, !actionFilter.isEmpty else { return }
        setActionFilter(all ? "" : String(actionFilter.dropLast()))
    }

    @discardableResult
    func pasteIntoActionFilter() -> Bool {
        guard showsActions else { return false }
        let line = pasteboard.string(forType: .string)?.split(whereSeparator: \.isNewline).first ?? ""
        let words = line.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let clean = String(String.UnicodeScalarView(words.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) && !(0xF700...0xF8FF).contains($0.value)
        }).prefix(64))
        typeInActions(clean)
        return true
    }

    private func setActionFilter(_ text: String) {
        actionFilter = String(text.prefix(64))
        actionSelected = 0
        if let first = visibleActions.first { say("\(first.title), \(first.spokenKeys)") } else { say("No match") }
    }

    @discardableResult
    func toggleActions() -> Bool {
        if showsActions {
            closeActions()
            return true
        }
        guard let item = focusedItem, !actions(for: item).isEmpty else { return false }
        actionSelected = 0
        actionFilter = ""
        panelActions = actions(for: item)
        actionTarget = item
        pendingSpeech?.invalidate()
        pendingSpeech = nil
        // Never names the row, so a clipboard row's text isn't read out.
        if let first = panelActions.first { say("Actions. \(first.title), \(first.spokenKeys)") }
        return true
    }

    func closeActions(refreshing: Bool = true) {
        guard actionTarget != nil else { return }
        actionTarget = nil
        spokenRow = nil
        if refreshing { refreshInBackground() }
    }

    func moveAction(_ delta: Int) {
        let visible = visibleActions
        guard !visible.isEmpty else { return }
        actionSelected = (actionSelected + delta + visible.count) % visible.count
        let action = visible[actionSelected]
        say("\(action.title), \(action.spokenKeys)")
    }

    func performSelectedAction() {
        let visible = visibleActions
        guard showsActions, visible.indices.contains(actionSelected) else { return }
        perform(visible[actionSelected].id)
    }

    @discardableResult
    func perform(_ action: BarAction.ID) -> Bool {
        guard let item = focusedItem, actions(for: item).contains(where: { $0.id == action }) else { return false }
        let text = action == .copyMarkdown ? Self.markdownLink(item) : Self.copyable(item)?.text
        let path = Self.path(of: item)
        if [.copy, .copyMarkdown].contains(action), text == nil { return false }
        if action == .reveal, path == nil { return false }
        actionTarget = nil
        switch action {
        case .open:
            run(item)
        case .copy, .copyMarkdown:
            guard let text else { return false }
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            onRun(Item(id: "copied", kind: .calculation, verb: "", title: "", subtitle: "", keywords: "", icon: nil, run: {}))
        case .reveal:
            guard let path else { return false }
            let reveal = revealInFinder
            onRun(Item(id: "revealed", kind: .calculation, verb: "", title: "", subtitle: "", keywords: "", icon: nil) {
                reveal(URL(fileURLWithPath: path))
            })
        case .forget:
            if item.isAlias {
                catalogue.aliases.remove(query)
            } else {
                catalogue.forgetPick(of: item, query: query)
            }
            refresh()
        case .alias:
            catalogue.aliases.set(query, for: item)
            refresh()
        }
        return true
    }

    func runSelected() {
        if let plan {
            onRunPlan(plan)
            return
        }
        if let rewritten, let target = rewriteTarget {
            onRun(Item(id: "rewrite", kind: .calculation, verb: "", title: "", subtitle: "", keywords: "", icon: nil) {
                Rewrite.replace(with: rewritten, in: target)
            })
            return
        }
        if let claudeAnswer {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(claudeAnswer, forType: .string)
            onRun(Item(id: "copied", kind: .calculation, verb: "", title: "", subtitle: "", keywords: "", icon: nil, run: {}))
            return
        }
        guard !isShowingPlan else { return }
        if armedID != nil { return confirmArmed() }
        guard results.indices.contains(selected) else { return }
        run(results[selected])
    }
}

private struct LevelMeter: View {
    let level: Double

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(0..<5, id: \.self) { index in
                let weight = [0.45, 0.75, 1.0, 0.75, 0.45][index]
                Capsule()
                    .fill(Theme.yellow.opacity(0.55 + 0.45 * weight))
                    .frame(width: 3, height: 5 + 15 * level * weight)
            }
        }
        .frame(height: 22)
        .animation(.easeOut(duration: 0.09), value: level)
        .accessibilityLabel("Listening")
    }
}

struct KeyHints: View {
    @ObservedObject var model: BarModel

    var body: some View {
        HStack(spacing: 16) {
            Group {
                if model.showsActions {
                    Text("↑↓ move")
                    Text("↩ choose")
                } else if model.results.count == 1, model.results.first?.kind == .calculation {
                    Text("↩ copy")
                } else if !model.results.isEmpty {
                    Text("↑↓ move")
                    Text("↩ open")
                    if !model.focusedActions.isEmpty {
                        Text("⌘K actions")
                    }
                }
            }
            .accessibilityHidden(true)
            if !model.showsActions, model.results.isEmpty, model.showsShortcutHint {
                Text("\(Settings.activeShortcutLabel) opens Beeline anywhere")
            }
            Spacer()
            Text(model.showsActions ? "esc back" : "esc close").accessibilityHidden(true)
        }
        .font(.system(size: 11))
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }
}

struct BarView: View {
    @ObservedObject var model: BarModel
    var solidOverride: Bool?
    @FocusState private var focused: Bool
    @AppStorage(Settings.showDetails) private var showDetails = false
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var solid: Bool {
        solidOverride ?? BarSurface.isSolid(increaseContrast: contrast == .increased, reduceTransparency: reduceTransparency)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: model.voiceLevel == nil ? "magnifyingglass" : "mic.fill")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 22)
                    .contentTransition(.symbolEffect(.replace))
                TextField(model.voiceLevel == nil ? "Beeline to…" : "Listening…", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 20))
                    .focused($focused)
                if let level = model.voiceLevel {
                    LevelMeter(level: level)
                        .transition(.opacity.combined(with: .scale(scale: 0.8)))
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 50)
            .background(Theme.capsule, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.capsuleEdge, lineWidth: 1))

            if model.isShowingPlan {
                PlanSection(model: model).padding(.top, 8)
            } else if let armed = model.results.first(where: { $0.id == model.armedID }) {
                ConfirmCard(item: armed, confirm: { model.confirmByClick() }, cancel: { model.armedID = nil })
                    .padding(.top, 8)
            } else if model.showsActions, let target = model.actionTarget {
                ActionPanel(item: target, actions: model.visibleActions, filter: model.actionFilter,
                            selected: model.actionSelected,
                            hover: { model.actionSelected = $0 }, choose: { model.perform($0) })
                    .padding(.top, 8)
            } else if model.results.count == 1, let answer = model.results.first, answer.kind == .calculation {
                AnswerCard(item: answer).padding(.top, 8)
                    .contentShape(Rectangle())
                    .onTapGesture { model.run(answer) }
                    .accessibilityAction { model.run(answer) }
            } else if model.query.isEmpty, let undo = UndoLog.shared.hint() {
                Text(undo)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 12)
                    .padding(.bottom, 2)
            } else if model.query.isEmpty {
                (Text("Try ") + Text("“\(model.tip)”").foregroundStyle(.primary))
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 12)
                    .padding(.bottom, 2)
            } else if !model.results.isEmpty {
                VStack(spacing: 2) {
                    ForEach(Array(model.results.enumerated()), id: \.element.id) { index, item in
                        if let title = sectionTitle(at: index) {
                            Text(title)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 12)
                                .padding(.top, index == 0 ? 4 : 8)
                                .padding(.bottom, 2)
                                .accessibilityAddTraits(.isHeader)
                        }
                        ResultRow(item: item, isSelected: index == model.selected, isArmed: false)
                            .contentShape(Rectangle())
                            .onHover { inside in if inside { model.selected = index } }
                            .onTapGesture {
                                model.selected = index
                                model.run(item)
                            }
                            .accessibilityAction {
                                model.selected = index
                                model.run(item)
                            }
                    }
                }
                .padding(.top, 6)
            }

            if showDetails, let item = model.focusedItem, item.id != BarModel.claudeRowID {
                DetailStrip(item: item, searchMilliseconds: model.searchMilliseconds,
                            modelMilliseconds: model.modelMilliseconds)
            }

            if let note = model.voiceNote {
                HStack(spacing: 8) {
                    Image(systemName: note.hasPrefix("Listening") ? "mic.fill" : note.hasSuffix("esc to cancel") ? "arrow.forward" : "mic.slash")
                        .foregroundStyle(note.hasPrefix("Listening") ? Theme.ink : Color.secondary)
                        .frame(width: 22, height: 22)
                        .background(note.hasPrefix("Listening") ? Theme.yellow : Theme.honeyTile, in: Circle())
                    Text(note).foregroundStyle(.primary)
                }
                .font(.system(size: 12))
                .frame(maxWidth: .infinity)
                .frame(height: 32)
                .padding(.top, 4)
            }

            if model.isThinking, !model.isShowingPlan {
                HStack(spacing: 8) {
                    HStack(spacing: 3) {
                        ForEach(0..<3, id: \.self) { step in
                            Circle().fill(Theme.yellow.opacity(1 - Double(step) * 0.25)).frame(width: 5, height: 5)
                        }
                    }
                    Text("Thinking…").foregroundStyle(.primary)
                }
                .font(.system(size: 12))
                .frame(maxWidth: .infinity)
                .frame(height: 30)
                .padding(.top, 4)
            }

            if model.needsAccess {
                hint(icon: AnyView(Image(systemName: "lock.open")), text: "Allow Accessibility to search windows and menu commands",
                     trailing: "Allow")
                    .contentShape(Rectangle())
                    .onTapGesture { model.onRequestAccess() }
            }

            if !model.isShowingPlan, model.armedID == nil {
                KeyHints(model: model)
            }
        }
        .padding(10)
        .background {
            if solid {
                Color(nsColor: .windowBackgroundColor)
            } else {
                ZStack {
                    Glass()
                    Theme.warmth
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
            .strokeBorder(solid ? Color.primary.opacity(0.5) : Theme.panelEdge, lineWidth: 1))
        .shadow(color: .black.opacity(0.2), radius: 28, y: 12)
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onChange(of: model.focusTick) { focused = true }
        .onAppear { focused = true }
    }

    private func sectionTitle(at index: Int) -> String? {
        let results = model.results
        let item = results[index]
        let single: Set<Kind> = [.calculation, .clipboard]
        if index == 0 {
            if single.contains(item.kind) { return title(for: item) }
            return results.count > 1 ? "Top hit" : nil
        }
        if index == 1 || title(for: results[index - 1]) != title(for: item) { return title(for: item) }
        return nil
    }

    private func title(for item: Item) -> String {
        if item.id == BarModel.claudeRowID { return "Claude" }
        switch item.kind {
        case .app: return "Apps"
        case .setting: return "Settings"
        case .action: return "Actions"
        case .tab: return "Tabs"
        case .window: return "Windows"
        case .menu: return "Menu commands"
        case .file: return "Files"
        case .calculation: return "Answer"
        case .control: return "In this window"
        case .clipboard: return "Clipboard"
        }
    }

    private func hint(icon: AnyView, text: String, trailing: String? = nil) -> some View {
        HStack(spacing: 8) {
            icon
            Text(text)
            Spacer(minLength: 8)
            if let trailing {
                Text(trailing)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Theme.honeyTile, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(Theme.accent)
        .padding(.horizontal, 12)
        .frame(height: 32)
        .padding(.top, 4)
    }
}

/// Always drawn as active: Beeline never becomes the active app, and an inactive NSVisualEffectView draws dull.
private struct Glass: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

struct ResultRow: View {
    let item: Item
    let isSelected: Bool
    let isArmed: Bool
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        HStack(spacing: 12) {
            icon
            (Text(item.verb.isEmpty ? "" : item.verb + " ").foregroundStyle(.secondary)
                + Text(item.title).fontWeight(isSelected ? .medium : .regular))
                .font(.system(size: 14))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            if isArmed {
                Text("This can't be undone").foregroundStyle(.red)
            } else if item.isGuess {
                Text("best guess").foregroundStyle(.tertiary)
            } else if item.isAlias {
                Text("alias").foregroundStyle(.tertiary)
            } else if item.isLearned {
                Text("learned").foregroundStyle(.tertiary)
            }
            if !item.subtitle.isEmpty {
                Text(item.subtitle)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .frame(maxWidth: 180, alignment: .trailing)
            }
            if isSelected {
                Text(isArmed ? "↩ again" : "↩")
                    .foregroundStyle(isArmed ? Color.red : Theme.accent)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 1)
                    .background(isArmed ? Color.red.opacity(0.12) : Theme.honeyTile,
                                in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
        }
        .font(.system(size: 12))
        .padding(.horizontal, 10)
        .frame(height: 40)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(Theme.raised)
                    .shadow(color: .black.opacity(0.08), radius: 2, y: 1)
                    .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(isArmed ? Color.red : contrast == .increased ? Theme.accent : Theme.yellow,
                                      lineWidth: contrast == .increased ? 2 : 1.5))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Announce.row(item))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    @ViewBuilder private var icon: some View {
        if let image = item.icon {
            if image.isTemplate {
                Image(nsImage: image)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 15, height: 15)
                    .foregroundStyle(Theme.accent)
                    .frame(width: 26, height: 26)
                    .background(Theme.honeyTile, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            } else {
                Image(nsImage: image).resizable().frame(width: 26, height: 26)
            }
        } else {
            Color.clear.frame(width: 26, height: 26)
        }
    }
}

struct PlanSection: View {
    @ObservedObject var model: BarModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.isAskingClaude {
                status(icon: AnyView(ProgressView().controlSize(.small)), text: "Asking Claude…", key: "esc to cancel")
            } else if let problem = model.planProblem {
                status(icon: AnyView(Image(systemName: "exclamationmark.circle")), text: problem, key: "esc to go back")
            } else if let answer = model.claudeAnswer ?? model.rewritten {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "sparkles").foregroundStyle(Theme.accent)
                        Text(model.rewritten == nil ? "Claude" : "Rewritten by Claude · nothing replaced yet")
                            .font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                    }
                    Text(answer)
                        .font(.system(size: 15))
                        .lineLimit(10)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.raised, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.yellow, lineWidth: 1.5))
                HStack {
                    if model.rewritten == nil {
                        Text("↩ copy").foregroundStyle(.secondary)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("Copy the answer")
                            .accessibilityAddTraits(.isButton)
                            .accessibilityAction { model.runSelected() }
                    } else {
                        Text("↩ replace the selection").foregroundStyle(.secondary)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("Replace the selection")
                            .accessibilityAddTraits(.isButton)
                            .accessibilityAction { model.runSelected() }
                    }
                    Spacer()
                    Text("esc back").foregroundStyle(.secondary).accessibilityHidden(true)
                }
                .font(.system(size: 11))
                .padding(.horizontal, 12)
                .padding(.top, 8)
            } else if let plan = model.plan {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Claude's plan")
                        .font(.system(size: 15, weight: .semibold))
                    if !plan.note.isEmpty {
                        Text(plan.note).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 10)

                VStack(spacing: 6) {
                    ForEach(Array(plan.steps.enumerated()), id: \.element.id) { index, step in
                        HStack(spacing: 12) {
                            Text("\(index + 1)")
                                .font(.system(size: 11, weight: .semibold))
                                .frame(width: 22, height: 22)
                                .foregroundStyle(Theme.ink)
                                .background(Theme.yellow, in: Circle())
                            if let icon = step.icon {
                                Image(nsImage: icon).resizable().frame(width: 22, height: 22)
                            }
                            Text(step.displayText).font(.system(size: 14)).lineLimit(3).truncationMode(.middle)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .frame(minHeight: 42)
                        .background(Theme.raised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(index == 0 ? Theme.yellow : Theme.capsuleEdge, lineWidth: index == 0 ? 1.5 : 1))
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Step \(index + 1), \(step.displayText)")
                    }
                }

                HStack(spacing: 10) {
                    Image(systemName: "sparkles").foregroundStyle(Theme.accent)
                    Text("\(plan.steps.count) \(plan.steps.count == 1 ? "step" : "steps") · nothing has run yet")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button { model.clearPlan() } label: {
                        Text("Cancel")
                            .padding(.horizontal, 14).frame(height: 28)
                            .background(Theme.capsule, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.capsuleEdge, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    Button { model.runSelected() } label: {
                        HStack(spacing: 6) { Text("Run"); Text("↩").opacity(0.7) }
                            .fontWeight(.semibold)
                            .foregroundStyle(Theme.ink)
                            .padding(.horizontal, 14).frame(height: 28)
                            .background(Theme.yellow, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Run")
                }
                .font(.system(size: 12))
                .padding(.horizontal, 4)
                .padding(.top, 10)
            }
        }
    }

    private func status(icon: AnyView, text: String, key: String) -> some View {
        HStack(spacing: 8) {
            icon
            Text(text).lineLimit(2)
            Spacer(minLength: 8)
            Text(key).foregroundStyle(.secondary).accessibilityHidden(true)
        }
        .font(.system(size: 12))
        .foregroundStyle(Theme.accent)
        .padding(.horizontal, 12)
        .frame(minHeight: 36)
    }
}

private struct AnswerCard: View {
    let item: Item

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(item.subtitle)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(item.title)
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                Text(item.keywords)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Image(systemName: "doc.on.doc")
                .font(.system(size: 14))
                .foregroundStyle(Theme.accent)
                .frame(width: 32, height: 32)
                .background(Theme.honeyTile, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(Theme.raised, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.yellow, lineWidth: 1.5))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([item.title, item.subtitle, item.keywords].filter { !$0.isEmpty }.joined(separator: ", "))
        .accessibilityAddTraits(.isButton)
    }
}

private struct ActionPanel: View {
    let item: Item
    let actions: [BarAction]
    let filter: String
    let selected: Int
    let hover: (Int) -> Void
    let choose: (BarAction.ID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 10) {
                if let icon = item.icon {
                    Image(nsImage: icon).resizable().scaledToFit().frame(width: 18, height: 18)
                }
                Text(item.title).fontWeight(.medium).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 8)
                if filter.isEmpty {
                    Text(item.subtitle).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                } else {
                    Label(filter, systemImage: "magnifyingglass").foregroundStyle(.primary).lineLimit(1)
                        .truncationMode(.head)
                }
            }
            .font(.system(size: 12))
            .padding(.horizontal, 12)
            .padding(.top, 4)
            .padding(.bottom, 6)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(filter.isEmpty ? "Actions for \(item.title)" : "Actions for \(item.title), filtered by \(filter)")
            .accessibilityAddTraits(.isHeader)

            ForEach(Array(actions.enumerated()), id: \.element.id) { index, action in
                let isSelected = index == selected
                HStack(spacing: 12) {
                    Image(systemName: action.symbol)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.accent)
                        .frame(width: 26, height: 26)
                        .background(Theme.honeyTile, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    Text(action.title)
                        .font(.system(size: 14))
                        .fontWeight(isSelected ? .medium : .regular)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(action.keys)
                        .font(.system(size: 12))
                        .foregroundStyle(isSelected ? Theme.accent : Color.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 1)
                        .background(isSelected ? Theme.honeyTile : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .padding(.horizontal, 10)
                .frame(height: 38)
                .background {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .fill(Theme.raised)
                            .shadow(color: .black.opacity(0.08), radius: 2, y: 1)
                            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Theme.yellow, lineWidth: 1.5))
                    }
                }
                .contentShape(Rectangle())
                .onHover { inside in if inside { hover(index) } }
                .onTapGesture { choose(action.id) }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(action.title), \(action.spokenKeys)")
                .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
                .accessibilityAction { choose(action.id) }
            }
            if actions.isEmpty {
                Text("No match")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 38)
            }
        }
    }
}

struct ConfirmCard: View {
    let item: Item
    let confirm: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                Group {
                    if let icon = item.icon, !icon.isTemplate {
                        Image(nsImage: icon).resizable()
                    } else {
                        Image(systemName: "exclamationmark.triangle").font(.system(size: 22)).foregroundStyle(.red)
                    }
                }
                .frame(width: 40, height: 40)
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.confirmQuestion)
                        .font(.system(size: 16, weight: .semibold))
                    Text(item.confirmSummary)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 10) {
                Spacer()
                Button(action: cancel) {
                    HStack(spacing: 6) { Text("Cancel"); Text("esc").foregroundStyle(.secondary) }
                        .font(.system(size: 13))
                        .padding(.horizontal, 14)
                        .frame(height: 30)
                        .background(Theme.capsule, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.capsuleEdge, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Cancel")
                Button(action: confirm) {
                    HStack(spacing: 6) { Text(item.verb.isEmpty ? item.title : item.verb); Text("↩").opacity(0.8) }
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .frame(height: 30)
                        .background(Color.red, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(item.verb.isEmpty ? item.title : item.verb)
            }
        }
        .padding(16)
        .background(Theme.raised, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.red.opacity(0.5), lineWidth: 1.5))
    }
}

private struct DetailStrip: View {
    let item: Item
    let searchMilliseconds: Double
    let modelMilliseconds: Double?

    private var why: String {
        switch item.source {
        case .words: return "every word you typed matches"
        case .partial: return "only some of your words match, so this is a guess"
        case .learned(let times): return "you picked this \(times == 1 ? "once" : "\(times) times") before for these words"
        case .model(let keywords): return "the on-device model read your request as: " + keywords.joined(separator: " ")
        case .meaning: return "closest in meaning, a weak guess"
        case .alias: return "your alias for it"
        }
    }

    private var time: String {
        var text = String(format: "%.1f ms search", searchMilliseconds)
        if case .model = item.source, let modelMilliseconds {
            text += String(format: ", %.0f ms on-device model", modelMilliseconds)
        }
        return text + ", on this Mac"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            line("do", item.verb.isEmpty ? "run" : item.verb.lowercased())
            line("target", item.title)
            line("in", item.subtitle)
            line("why", why)
            line("time", time)
        }
        .font(.system(size: 11, design: .monospaced))
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func line(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(label).foregroundStyle(.secondary).frame(width: 56, alignment: .leading)
            Text(value).foregroundStyle(Theme.accent).lineLimit(1).truncationMode(.tail)
        }
    }
}
