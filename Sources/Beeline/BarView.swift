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

final class BarModel: ObservableObject {
    @Published var query = "" {
        didSet { refresh() }
    }
    @Published var results: [Item] = []
    @Published var selected = 0
    @Published var focusTick = 0

    @Published var needsAccess = false

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
            }
        }
    }

    func refreshInBackground() {
        guard !isShowingPlan else { return }
        if let armedID {
            if let armed = results.first(where: { $0.id == armedID }), armed.stillValid?() == false { self.armedID = nil }
            return
        }
        let selectedID = results.indices.contains(selected) ? results[selected].id : nil
        refresh()
        if let selectedID, let index = results.firstIndex(where: { $0.id == selectedID }) { selected = index }
    }

    private func merged(_ picks: [Item], _ found: [Item]) -> [Item] {
        let picked = Set(picks.map(\.id))
        return Array((picks + found.filter { !picked.contains($0.id) && $0.id != Self.claudeRowID && $0.id != Self.rewriteRowID }).prefix(6))
    }

    /// How a single result reads to Claude in the next request's context; its names are screen text.
    static func stepText(_ item: Item) -> String {
        if let history = item.historyText { return history }
        let name = ScreenText.quote(String(item.title.prefix(120)))
        let what = item.verb.isEmpty ? name : "\(ScreenText.sanitize(item.verb)) \(name)"
        return item.subtitle.isEmpty ? what : "\(what) (\(ScreenText.quote(String(item.subtitle.prefix(120)))))"
    }

    static let claudeRowID = "ask-claude"
    static let rewriteRowID = "rewrite-selection"

    @Published var plan: Plan?
    @Published var isAskingClaude = false
    @Published var planProblem: String?
    var onRunPlan: (Plan) -> Void = { _ in }
    private var planning: Task<Void, Never>?

    @Published var claudeAnswer: String?

    @Published var rewritten: String?
    private var rewriteTarget: Rewrite.Selection?

    var isShowingPlan: Bool { plan != nil || isAskingClaude || planProblem != nil || claudeAnswer != nil || rewritten != nil }

    @Published var voiceNote: String?
    @Published var voiceLevel: Double?

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
        guard words >= 2 || LastRun.shared.isFollowUp(query), Settings.isOn(Settings.offerClaude), items.first?.kind != .calculation else { return items }
        let question = Self.isPlainQuestion(query, catalogue.isQuestion(query))
        let row = Item(id: Self.claudeRowID, kind: .action, verb: "", title: question ? "Ask Claude" : "Ask Claude to work it out",
                       subtitle: question ? "answers here in a few seconds" : "takes a few seconds", keywords: "",
                       icon: NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil), run: {})
        let leads = Self.claudeLeads(question: question, words: words, top: items.first, followUp: LastRun.shared.isFollowUp(query))
        return leads ? [row] + items : items + [row]
    }

    /// The exact Undo row is the answer to "undo that" and keeps Return; any other follow-up goes to Claude first.
    static func claudeLeads(question: Bool, words: Int, top: Item?, followUp: Bool) -> Bool {
        question || (words >= 5 && (top?.isGuess ?? true)) || (followUp && top?.id != "undo")
    }

    /// "Again?" or "now the other window?" right after a run is a request to act, so it goes to the planner.
    static func isPlainQuestion(_ query: String, _ isQuestion: Bool, last: LastRun = .shared) -> Bool {
        isQuestion && !last.isFollowUp(query, strong: true)
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
        let options = catalogue.planOptions(for: asked)
        planning = Task { @MainActor [weak self] in
            let result = await Planner.plan(for: asked, options: options, previous: LastRun.shared.latest())
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
    }

    @Published var armedID: String? {
        didSet { if armedID != nil, armedID != oldValue { armedAt = Date() } }
    }
    private(set) var armedAt = Date.distantPast

    func run(_ item: Item) {
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
        catalogue.recordUse(of: item, query: query)
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
        guard !results.isEmpty, !isShowingPlan else { return }
        selected = (selected + delta + results.count) % results.count
    }

    @discardableResult
    func forgetSelectedPick() -> Bool {
        guard results.indices.contains(selected) else { return false }
        let item = results[selected]
        if item.isAlias {
            catalogue.aliases.remove(query)
        } else if item.isLearned {
            catalogue.forgetPick(of: item, query: query)
        } else {
            return false
        }
        refresh()
        return true
    }

    var canAliasSelected: Bool {
        guard results.indices.contains(selected), !isShowingPlan, armedID == nil,
              let alias = Aliases.normalise(query), alias.count <= 12 else { return false }
        return Catalogue.canHaveAlias(results[selected])
    }

    @discardableResult
    func aliasSelected() -> Bool {
        guard canAliasSelected else { return false }
        catalogue.aliases.set(query, for: results[selected])
        refresh()
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

struct BarView: View {
    @ObservedObject var model: BarModel
    @FocusState private var focused: Bool
    @AppStorage(Settings.showDetails) private var showDetails = false

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
            } else if model.results.count == 1, let answer = model.results.first, answer.kind == .calculation {
                AnswerCard(item: answer).padding(.top, 8)
                    .contentShape(Rectangle())
                    .onTapGesture { model.run(answer) }
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
                        }
                        ResultRow(item: item, isSelected: index == model.selected, isArmed: false)
                            .contentShape(Rectangle())
                            .onHover { inside in if inside { model.selected = index } }
                            .onTapGesture {
                                model.selected = index
                                model.run(item)
                            }
                    }
                }
                .padding(.top, 6)
            }

            if showDetails, !model.isShowingPlan, model.results.indices.contains(model.selected),
               model.results[model.selected].id != BarModel.claudeRowID {
                DetailStrip(item: model.results[model.selected], searchMilliseconds: model.searchMilliseconds,
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
                    Text("on your Mac").foregroundStyle(.secondary)
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
                HStack(spacing: 16) {
                    if model.results.count == 1, model.results.first?.kind == .calculation {
                        Text("↩ copy")
                    } else if !model.results.isEmpty {
                        Text("↑↓ move")
                        Text("↩ open")
                        if model.results.indices.contains(model.selected) {
                            let item = model.results[model.selected]
                            if item.isAlias {
                                Text("⇧⌘⌫ remove alias")
                            } else if item.isLearned {
                                Text("⇧⌘⌫ forget pick")
                            } else if model.canAliasSelected {
                                Text("⇧⌘A make “\(Usage.normalise(model.query))” its alias")
                                    .lineLimit(1)
                            }
                        }
                    } else {
                        Text("\(Settings.activeShortcutLabel) opens Beeline anywhere")
                    }
                    Spacer()
                    Text("esc close")
                }
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 12)
                .padding(.top, 8)
            }
        }
        .padding(10)
        .background {
            ZStack {
                Glass()
                Theme.warmth
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Theme.panelEdge, lineWidth: 1))
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

private struct ResultRow: View {
    let item: Item
    let isSelected: Bool
    let isArmed: Bool

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
                    .accessibilityLabel("your alias")
            } else if item.isLearned {
                Text("learned").foregroundStyle(.tertiary)
                    .accessibilityLabel("ranked first because you picked it before")
            }
            Text(item.subtitle)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)
                .frame(maxWidth: 180, alignment: .trailing)
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
                        .strokeBorder(isArmed ? Color.red : Theme.yellow, lineWidth: 1.5))
            }
        }
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

private struct PlanSection: View {
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
                    Text(model.rewritten == nil ? "↩ copy" : "↩ replace the selection").foregroundStyle(.secondary)
                    Spacer()
                    Text("esc back").foregroundStyle(.secondary)
                }
                .font(.system(size: 11))
                .padding(.horizontal, 12)
                .padding(.top, 8)
            } else if let plan = model.plan {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Ready when you are")
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
            Text(key).foregroundStyle(.secondary)
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
    }
}

private struct ConfirmCard: View {
    let item: Item
    let confirm: () -> Void
    let cancel: () -> Void

    private var trashSummary: String? {
        guard item.id == "action:Empty Trash",
              let names = try? FileManager.default.contentsOfDirectory(atPath: NSHomeDirectory() + "/.Trash") else { return nil }
        let count = names.filter { !$0.hasPrefix(".") }.count
        return count == 1 ? "1 item will be deleted permanently." : "\(count) items will be deleted permanently."
    }

    private var ejectSummary: String? {
        guard item.id == "action:Eject All Disks" else { return nil }
        return Actions.ejectSummary(Actions.ejectableDisks().map(\.name))
    }

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
                VStack(alignment: .leading, spacing: 3) {
                    Text("\((item.verb.isEmpty ? "" : item.verb + " ") + item.title)?")
                        .font(.system(size: 16, weight: .semibold))
                    Text(trashSummary ?? ejectSummary ?? item.confirmNote ?? "This can't be undone.")
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
                Button(action: confirm) {
                    HStack(spacing: 6) { Text(item.verb.isEmpty ? item.title : item.verb); Text("↩").opacity(0.8) }
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .frame(height: 30)
                        .background(Color.red, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
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
        case .model(let keywords): return "on-device model read your request as: " + keywords.joined(separator: " ")
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
