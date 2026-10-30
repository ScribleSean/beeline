import Foundation
import Testing
@testable import Beeline

// The voice test mode (BEELINE_DEMO=voice) plays a file through the real recognizer and planner. Without
// BEELINE_VOICE_RUN=1 it must only report what it would do: nothing runs, and nothing says it is about to.

private let planOnly = ["BEELINE_DEMO": "voice", "BEELINE_VOICE_FILE": "/tmp/beeline-test-phrase.aiff"]

@MainActor private func bar() -> BarController {
    TestEnvironment.prepare()
    return BarController(environment: planOnly, watching: false)
}

private func safari(_ ran: @escaping () -> Void) -> Item {
    Item(id: "/Applications/Safari.app", kind: .app, verb: "Open", title: "Safari", subtitle: "", keywords: "",
         icon: nil, run: ran)
}

@Test @MainActor func planOnlyVoiceRunsNoItem() {
    let bar = bar()
    var ran = false
    bar.model.onRun(safari { ran = true })
    #expect(!ran)
}

@Test @MainActor func planOnlyVoiceRunsNoPlan() async {
    let bar = bar()
    var ran = false
    bar.model.onRunPlan(Plan(steps: [PlanStep(text: "Open Safari", icon: nil, run: { ran = true }, settleTime: 0)],
                             note: "Opens Safari"))
    // A plan starts its first step after a short pause.
    try? await Task.sleep(nanoseconds: 600_000_000)
    #expect(!ran)
    #expect(!bar.runGuard.isRunning)
}

@Test @MainActor func planOnlyVoiceNeitherActsNorSaysEscapeToCancel() async {
    let bar = bar()
    var ran = false
    let item = safari { ran = true }
    bar.isShown = true
    bar.model.catalogue.includeFiles = false
    bar.model.query = "Safari"
    bar.model.results = [item]
    bar.model.selected = 0
    // Reopening drops the row announcement the query scheduled, so only heard() speaks here.
    bar.model.isOpen = false
    bar.model.isOpen = true
    var heard: [String] = []
    let real = Announce.post
    Announce.post = { text, _ in heard.append(text) }
    bar.heard("Safari")
    bar.model.isOpen = false
    Announce.post = real
    #expect(!bar.cancelPendingAct(), "a plan-only voice result must not wait to run")
    #expect(heard.contains("Open Safari"))
    #expect(!heard.contains { $0.localizedCaseInsensitiveContains("escape") }, "\(heard)")
    #expect(!(bar.model.voiceNote ?? "").localizedCaseInsensitiveContains("esc"), "\(bar.model.voiceNote ?? "")")
    // Longer than the auto-act wait, in case a timer was scheduled anyway.
    try? await Task.sleep(nanoseconds: 1_000_000_000)
    #expect(!ran)
}
