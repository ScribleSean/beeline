import Foundation
import Testing
@testable import Beeline

@Test @MainActor func finalVoiceSelectionDoesNotUsePartialResults() {
    TestEnvironment.prepare()
    let model = BarModel()
    model.catalogue.includeFiles = false
    var partial = Item(id: "voice-test:partial", kind: .app, verb: "Open", title: "Partial Target",
                       subtitle: "App", keywords: "", icon: nil, run: {})
    // Learned/aliased rows bypass AutoAct's exact-name check, so a stale row can be actionable.
    partial.source = .learned(1)
    let final = Item(id: "voice-test:final", kind: .app, verb: "Open", title: "Final Voice Target",
                     subtitle: "App", keywords: "", icon: nil, run: {})
    model.catalogue.useTabs([final])
    model.query = "Open"
    model.results = [partial]
    let partialResults = model.results
    model.query = "Open Final Voice Target"
    // Simulate a late partial result replacing the list after the final transcript.
    model.results = partialResults
    model.selected = 0
    // This is the old heard() selection: it accepts the learned partial row for the final words.
    #expect(AutoAct.pick(model.results, spoken: model.query)?.id == partial.id)

    var ran: [String] = []
    var announced: [String] = []
    model.onRun = { ran.append($0.id) }
    let post = Announce.post
    Announce.post = { text, _ in announced.append(text) }
    defer { Announce.post = post; model.isOpen = false }

    #expect(model.prepareVoiceResults(for: model.query))
    #expect(model.resultsQuery == "Open Final Voice Target")
    let picked = AutoAct.pick(model.results, spoken: model.query)
    #expect(picked?.id == final.id)
    model.speakSelection()
    model.runSelected()
    #expect(ran == [final.id])
    #expect(announced.contains("Open Final Voice Target, App"))
    #expect(!announced.contains { $0.contains(partial.title) })
}

@Test @MainActor func finalVoiceSelectionPreservesAnEditedQuery() {
    TestEnvironment.prepare()
    let model = BarModel()
    model.catalogue.includeFiles = false
    model.query = "a deliberate edit"
    #expect(!model.prepareVoiceResults(for: "Open TextEdit"))
    #expect(model.query == "a deliberate edit")
    model.isOpen = false
}
