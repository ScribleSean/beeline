import Foundation
import Testing
@testable import Beeline

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
    try? await Task.sleep(nanoseconds: UInt64(BarController.planStartPause * 4 * 1_000_000_000))
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
    let autoActWait = AutoAct.window(voiceOver: AutoAct.voiceOverIsOn(), spoken: "Open Safari. Escape to cancel.")
    try? await Task.sleep(nanoseconds: UInt64((autoActWait + 0.3) * 1_000_000_000))
    #expect(!ran)
}
