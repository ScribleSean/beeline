import SwiftUI

/// Honey glass: frosted glass with a faint honey warmth, a white search capsule, and a calm list where
/// the chosen row is raised and outlined in bee yellow. Every colour adapts to light and dark mode.
enum Theme {
    /// The brand yellow, #FFC21A, used for the selection outline and small marks.
    static let yellow = Color(red: 1.0, green: 0.761, blue: 0.102)
    /// Near-black, #1A1407.
    static let ink = Color(red: 0.102, green: 0.078, blue: 0.027)

    private static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }

    /// Icons and hints: a readable gold in light mode, bee yellow in dark mode.
    static let accent = adaptive(light: NSColor(red: 0.69, green: 0.52, blue: 0.0, alpha: 1),
                                 dark: NSColor(red: 1.0, green: 0.761, blue: 0.102, alpha: 1))
    /// Laid over the glass to warm it slightly.
    static let warmth = adaptive(light: NSColor(red: 0.984, green: 0.953, blue: 0.863, alpha: 0.55),
                                 dark: NSColor(red: 0.16, green: 0.13, blue: 0.06, alpha: 0.35))
    static let capsule = adaptive(light: .white, dark: NSColor(white: 1, alpha: 0.08))
    static let capsuleEdge = adaptive(light: NSColor(red: 0.925, green: 0.902, blue: 0.84, alpha: 1),
                                      dark: NSColor(white: 1, alpha: 0.09))
    static let raised = adaptive(light: .white, dark: NSColor(white: 1, alpha: 0.1))
    /// The small tile behind symbol icons, and the Return keycap.
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
    /// Bumped each time the bar opens so the text field takes focus again.
    @Published var focusTick = 0

    /// True until the user allows Accessibility; windows and menu commands are missing until then.
    @Published var needsAccess = false

    let catalogue = Catalogue()
    var onRun: (Item) -> Void = { _ in }
    var onRequestAccess: () -> Void = {}

    /// How long the last search took, and the last on-device model call if there was one. For the details strip.
    @Published var searchMilliseconds = 0.0
    @Published var modelMilliseconds: Double?

    /// True while the on-device model is deciding.
    @Published var isThinking = false
    private var thinking: Task<Void, Never>?
    /// The exact words the model was last asked about, and what it picked.
    private var askedQuery: String?
    private var modelPicks: [Item] = []

    func refresh() {
        // Files come from the Spotlight index a moment later, then the list is rebuilt with them in it.
        let typed = query
        catalogue.refreshFiles(for: typed) { [weak self] in
            // A plan being asked for or previewed must not be wiped by late file results.
            if let self, self.query == typed, !self.isShowingPlan { self.refresh() }
        }
        let started = Date()
        let found = catalogue.search(query)
        searchMilliseconds = Date().timeIntervalSince(started) * 1000
        if query != askedQuery { armedID = nil }

        // Called again for the same words when the screen map refreshes in the background:
        // keep the model's pick on top and do not ask it twice.
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
        guard catalogue.needsChooser(query, found) else { return }

        let asked = query
        askedQuery = asked
        thinking = Task { @MainActor [weak self] in
            // Wait for a pause in typing, so the model is not asked about half a sentence.
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard let self, !Task.isCancelled else { return }
            self.isThinking = true
            let asking = Date()
            let picks = await self.catalogue.choose(asked)
            guard !Task.isCancelled, asked == self.query else { return }
            self.modelMilliseconds = Date().timeIntervalSince(asking) * 1000
            self.isThinking = false
            self.modelPicks = picks
            if !picks.isEmpty {
                self.results = self.decorated(self.merged(picks, self.results))
                self.selected = 0
            }
        }
    }

    /// The model's picks first, then whatever word matching found that it did not.
    private func merged(_ picks: [Item], _ found: [Item]) -> [Item] {
        let picked = Set(picks.map(\.id))
        return Array((picks + found.filter { !picked.contains($0.id) && $0.id != Self.claudeRowID }).prefix(6))
    }

    // MARK: Claude plans

    static let claudeRowID = "ask-claude"

    /// The steps Claude proposed, waiting for Return. Nothing in a plan runs before that.
    @Published var plan: Plan?
    @Published var isAskingClaude = false
    /// Shown when Claude could not be reached or found no way to do the request.
    @Published var planProblem: String?
    var onRunPlan: (Plan) -> Void = { _ in }
    private var planning: Task<Void, Never>?

    var isShowingPlan: Bool { plan != nil || isAskingClaude || planProblem != nil }

    /// Adds the "Ask Claude" row under the results once the request is more than a single word.
    private func decorated(_ items: [Item]) -> [Item] {
        let words = query.split(separator: " ").count
        guard words >= 2, Settings.isOn(Settings.offerClaude) else { return items }
        let row = Item(id: Self.claudeRowID, kind: .action, verb: "", title: "Ask Claude to work it out",
                       subtitle: "takes a few seconds", keywords: "",
                       icon: NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil), run: {})
        // A long request that nothing matched outright is most likely a job for Claude, so that row leads.
        // Either way it only asks; nothing runs before the preview.
        let leads = words >= 5 && (items.first?.isGuess ?? true)
        return leads ? [row] + items : items + [row]
    }

    private func askClaude() {
        clearPlan()
        isAskingClaude = true
        let asked = query
        let options = catalogue.planOptions()
        planning = Task { @MainActor [weak self] in
            let result = await Planner.plan(for: asked, options: options)
            guard let self, !Task.isCancelled, asked == self.query else { return }
            self.isAskingClaude = false
            switch result {
            case .success(let plan):
                Log.append("plan for \"\(asked)\" from \(options.count) options: \(plan.steps.map(\.text).joined(separator: " | ")) // \(plan.note)")
            case .failure(.message(let message)):
                Log.append("plan for \"\(asked)\" failed: \(message)")
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
    }

    /// The irreversible action waiting for a second Return, if any.
    @Published var armedID: String?

    /// Runs the item, unless it cannot be undone and has not been confirmed yet.
    func run(_ item: Item) {
        if item.id == Self.claudeRowID {
            askClaude()
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

    func move(_ delta: Int) {
        armedID = nil
        guard !results.isEmpty, !isShowingPlan else { return }
        selected = (selected + delta + results.count) % results.count
    }

    func runSelected() {
        if let plan {
            onRunPlan(plan)
            return
        }
        guard !isShowingPlan, results.indices.contains(selected) else { return }
        run(results[selected])
    }
}

struct BarView: View {
    @ObservedObject var model: BarModel
    @FocusState private var focused: Bool
    @AppStorage(Settings.showDetails) private var showDetails = false

    var body: some View {
        VStack(spacing: 0) {
            // The search capsule.
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(Theme.accent)
                TextField("What do you want to do?", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 20))
                    .focused($focused)
            }
            .padding(.horizontal, 16)
            .frame(height: 50)
            .background(Theme.capsule, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.capsuleEdge, lineWidth: 1))

            if model.isShowingPlan {
                PlanSection(model: model).padding(.top, 6)
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
                        ResultRow(item: item, isSelected: index == model.selected, isArmed: model.armedID == item.id)
                            .contentShape(Rectangle())
                            .onTapGesture { model.run(item) }
                    }
                }
                .padding(.top, 6)
            }

            if showDetails, !model.isShowingPlan, model.results.indices.contains(model.selected),
               model.results[model.selected].id != BarModel.claudeRowID {
                DetailStrip(item: model.results[model.selected], searchMilliseconds: model.searchMilliseconds,
                            modelMilliseconds: model.modelMilliseconds)
            }

            if model.isThinking {
                hint(icon: AnyView(ProgressView().controlSize(.small)), text: "Thinking…")
            }

            if model.needsAccess {
                hint(icon: AnyView(Image(systemName: "lock.open")), text: "Allow Accessibility to search windows and menu commands",
                     trailing: "Allow")
                    .contentShape(Rectangle())
                    .onTapGesture { model.onRequestAccess() }
            }

            if !model.results.isEmpty, !model.isShowingPlan {
                HStack(spacing: 16) {
                    Text("↑↓ move")
                    Text("↩ open")
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

    /// A small heading above a result: "Top hit" for the first, then one each time the kind changes.
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

/// The frosted glass behind the bar. Always drawn as active, so it stays bright even though
/// Beeline itself never becomes the active app.
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
    /// True when an irreversible action has had its first Return and is waiting for the second.
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

    /// App icons are shown as they are; symbol icons sit on a small honey tile.
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

/// Claude's proposed steps, shown for approval. Return runs them all; Escape goes back.
private struct PlanSection: View {
    @ObservedObject var model: BarModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.isAskingClaude {
                footer(leading: { ProgressView().controlSize(.small) }, text: "Asking Claude…", key: "esc to cancel")
            } else if let problem = model.planProblem {
                footer(leading: { Image(systemName: "exclamationmark.circle") }, text: problem, key: "esc to go back")
            } else if let plan = model.plan {
                if !plan.note.isEmpty {
                    Text(plan.note)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.top, 6)
                        .padding(.bottom, 6)
                }
                VStack(spacing: 2) {
                    ForEach(Array(plan.steps.enumerated()), id: \.element.id) { index, step in
                        HStack(spacing: 12) {
                            Text("\(index + 1)")
                                .font(.system(size: 11, weight: .semibold))
                                .frame(width: 20, height: 20)
                                .foregroundStyle(Theme.ink)
                                .background(Theme.yellow, in: Circle())
                            if let icon = step.icon {
                                Image(nsImage: icon).resizable().frame(width: 20, height: 20)
                            }
                            Text(step.text).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 0)
                        }
                        .font(.system(size: 14))
                        .padding(.horizontal, 10)
                        .frame(height: 36)
                        .background(Theme.raised.opacity(0.6), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    }
                }
                footer(leading: { Image(systemName: "sparkles") },
                       text: "Claude's plan. Nothing has run yet.", key: "↩ run · esc back")
            }
        }
    }

    private func footer<Leading: View>(@ViewBuilder leading: () -> Leading, text: String, key: String) -> some View {
        HStack(spacing: 8) {
            leading()
            Text(text).lineLimit(2)
            Spacer(minLength: 8)
            Text(key).foregroundStyle(.secondary)
        }
        .font(.system(size: 12))
        .foregroundStyle(Theme.accent)
        .padding(.horizontal, 12)
        .frame(minHeight: 34)
    }
}

/// The optional "what did Beeline understand" readout for the selected result.
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
