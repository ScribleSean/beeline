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

    /// True while the on-device model is deciding.
    @Published var isThinking = false
    private var thinking: Task<Void, Never>?
    /// The exact words the model was last asked about, and what it picked.
    private var askedQuery: String?
    private var modelPicks: [Item] = []

    func refresh() {
        let found = catalogue.search(query)
        if query != askedQuery { armedID = nil }

        // Called again for the same words when the screen map refreshes in the background:
        // keep the model's pick on top and do not ask it twice.
        if query == askedQuery {
            results = merged(modelPicks, found)
            return
        }

        results = found
        selected = 0
        thinking?.cancel()
        isThinking = false
        askedQuery = nil
        modelPicks = []
        guard catalogue.needsChooser(query, found) else { return }

        let asked = query
        askedQuery = asked
        thinking = Task { @MainActor [weak self] in
            // Wait for a pause in typing, so the model is not asked about half a sentence.
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard let self, !Task.isCancelled else { return }
            self.isThinking = true
            let picks = await self.catalogue.choose(asked)
            guard !Task.isCancelled, asked == self.query else { return }
            self.isThinking = false
            self.modelPicks = picks
            if !picks.isEmpty {
                self.results = self.merged(picks, self.results)
                self.selected = 0
            }
        }
    }

    /// The model's picks first, then whatever word matching found that it did not.
    private func merged(_ picks: [Item], _ found: [Item]) -> [Item] {
        let picked = Set(picks.map(\.id))
        return Array((picks + found.filter { !picked.contains($0.id) }).prefix(6))
    }

    /// The irreversible action waiting for a second Return, if any.
    @Published var armedID: String?

    /// Runs the item, unless it cannot be undone and has not been confirmed yet.
    func run(_ item: Item) {
        if item.needsConfirm, armedID != item.id {
            armedID = item.id
            return
        }
        armedID = nil
        onRun(item)
    }

    func move(_ delta: Int) {
        armedID = nil
        guard !results.isEmpty else { return }
        selected = (selected + delta + results.count) % results.count
    }

    func runSelected() {
        guard results.indices.contains(selected) else { return }
        run(results[selected])
    }
}

struct BarView: View {
    @ObservedObject var model: BarModel
    @FocusState private var focused: Bool

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

            ForEach(Array(model.results.enumerated()), id: \.element.id) { index, item in
                Divider().opacity(0.5)
                ResultRow(item: item, isSelected: index == model.selected, isArmed: model.armedID == item.id)
                    .contentShape(Rectangle())
                    .onTapGesture { model.run(item) }
                    .transition(.opacity)
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
