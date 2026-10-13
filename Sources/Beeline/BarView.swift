import SwiftUI

/// Every animation is short enough that the bar never feels like it is waiting.
enum Motion {
    static let fadeIn = 0.12
    static let fadeOut = 0.09
    static let results = Animation.easeOut(duration: 0.14)
    static let selection = Animation.easeOut(duration: 0.08)
}

enum Theme {
    static let honey50 = Color(red: 0.980, green: 0.933, blue: 0.855)
    static let honey100 = Color(red: 0.980, green: 0.780, blue: 0.459)
    static let amber400 = Color(red: 0.729, green: 0.459, blue: 0.090)
    static let bark800 = Color(red: 0.388, green: 0.220, blue: 0.024)
    static let bark900 = Color(red: 0.255, green: 0.141, blue: 0.008)
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
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(Theme.amber400)
                TextField("What do you want to do?", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 20))
                    .focused($focused)
            }
            .padding(.horizontal, 16)
            .frame(height: 54)

            if model.isShowingPlan {
                Divider().opacity(0.5)
                PlanSection(model: model).transition(.opacity)
            } else {
                ForEach(Array(model.results.enumerated()), id: \.element.id) { index, item in
                    Divider().opacity(0.5)
                    ResultRow(item: item, isSelected: index == model.selected, isArmed: model.armedID == item.id)
                        .contentShape(Rectangle())
                        .onTapGesture { model.run(item) }
                        .transition(.opacity)
                }
            }

            if showDetails, !model.isShowingPlan, model.results.indices.contains(model.selected),
               model.results[model.selected].id != BarModel.claudeRowID {
                Divider().opacity(0.5)
                DetailStrip(item: model.results[model.selected], searchMilliseconds: model.searchMilliseconds,
                            modelMilliseconds: model.modelMilliseconds)
            }

            if model.isThinking {
                Divider().opacity(0.5)
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Thinking…")
                    Spacer()
                }
                .font(.system(size: 12))
                .foregroundStyle(Theme.amber400)
                .padding(.horizontal, 16)
                .frame(height: 32)
                .transition(.opacity)
            }

            if model.needsAccess {
                Divider().opacity(0.5)
                HStack(spacing: 8) {
                    Image(systemName: "lock.open")
                    Text("Allow Accessibility to search windows and menu commands")
                    Spacer(minLength: 8)
                    Text("Allow")
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Theme.amber400, lineWidth: 0.5))
                }
                .font(.system(size: 12))
                .foregroundStyle(Theme.amber400)
                .padding(.horizontal, 16)
                .frame(height: 32)
                .contentShape(Rectangle())
                .onTapGesture { model.onRequestAccess() }
            }
        }
        .animation(Motion.results, value: model.results.map(\.id))
        .animation(Motion.selection, value: model.selected)
        .animation(Motion.results, value: model.isThinking)
        .animation(Motion.selection, value: model.armedID)
        .animation(Motion.results, value: model.isShowingPlan)
        .animation(Motion.results, value: model.plan?.steps.map(\.id))
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.primary.opacity(0.12), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.25), radius: 24, y: 10)
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onChange(of: model.focusTick) { focused = true }
        .onAppear { focused = true }
    }
}

private struct ResultRow: View {
    let item: Item
    let isSelected: Bool
    /// True when an irreversible action has had its first Return and is waiting for the second.
    let isArmed: Bool
    @Environment(\.colorScheme) private var scheme

    private var foreground: Color {
        if isArmed { return .red }
        guard isSelected else { return .secondary }
        return scheme == .dark ? Theme.honey100 : Theme.bark800
    }

    var body: some View {
        HStack(spacing: 10) {
            if let icon = item.icon {
                Image(nsImage: icon).resizable().frame(width: 22, height: 22)
            }
            (Text(item.verb.isEmpty ? "" : item.verb + " ") + Text(item.title).fontWeight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)
            Text(item.subtitle)
                .font(.system(size: 11))
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(isSelected ? Theme.honey100.opacity(scheme == .dark ? 0.25 : 1) : Color.primary.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            if isArmed {
                Text("This can't be undone")
                    .font(.system(size: 11))
            } else if item.isGuess {
                Text("best guess")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if isSelected {
                Text(isArmed ? "Return again" : "Return")
                    .font(.system(size: 11))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(isArmed ? Color.red : Theme.amber400, lineWidth: 0.5))
            }
        }
        .font(.system(size: 14))
        .foregroundStyle(foreground)
        .padding(.horizontal, 16)
        .frame(height: 40)
        .background(isArmed ? Color.red.opacity(0.12) : isSelected ? (scheme == .dark ? Theme.bark900 : Theme.honey50) : Color.clear)
    }
}

/// Claude's proposed steps, shown for approval. Return runs them all; Escape goes back.
private struct PlanSection: View {
    @ObservedObject var model: BarModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.isAskingClaude {
                footer(leading: { ProgressView().controlSize(.small) }, text: "Asking Claude…", key: "Esc to cancel")
            } else if let problem = model.planProblem {
                footer(leading: { Image(systemName: "exclamationmark.circle") }, text: problem, key: "Esc to go back")
            } else if let plan = model.plan {
                if !plan.note.isEmpty {
                    Text(plan.note)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 16)
                        .padding(.top, 10)
                        .padding(.bottom, 6)
                }
                ForEach(Array(plan.steps.enumerated()), id: \.element.id) { index, step in
                    HStack(spacing: 10) {
                        Text("\(index + 1)")
                            .font(.system(size: 11, weight: .medium))
                            .frame(width: 18, height: 18)
                            .background(Theme.honey100.opacity(scheme == .dark ? 0.25 : 1))
                            .clipShape(Circle())
                        if let icon = step.icon {
                            Image(nsImage: icon).resizable().frame(width: 18, height: 18)
                        }
                        Text(step.text).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 0)
                    }
                    .font(.system(size: 14))
                    .foregroundStyle(scheme == .dark ? Theme.honey100 : Theme.bark800)
                    .padding(.horizontal, 16)
                    .frame(height: 32)
                }
                Divider().opacity(0.5).padding(.top, 4)
                footer(leading: { Image(systemName: "sparkles") },
                       text: "Claude's plan. Nothing has run yet.", key: "Return to run · Esc to go back")
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
        .foregroundStyle(Theme.amber400)
        .padding(.horizontal, 16)
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
            Text(value).foregroundStyle(Theme.amber400).lineLimit(1).truncationMode(.tail)
        }
    }
}
