import Testing
@testable import Beeline

private func step(_ text: String) -> PlanStep {
    PlanStep(text: text, icon: nil, run: {})
}

@Test func theBeeSaysPlanStepsTheShortWay() {
    #expect(BeeLabel.text(for: step("In the current window only, press the button \"Send\"")) == "Press Send")
    #expect(BeeLabel.text(for: step("In the current window only, go to the search field \"Search mail\"")) == "Go to Search mail")
    #expect(BeeLabel.text(for: step("In the current app only, run its menu command Safari › File › Export as PDF…")) == "Run Export as PDF…")
    #expect(BeeLabel.text(for: step("Switch to window \"Inbox\" (Mail)")) == "Switch to window \"Inbox\" (Mail)")
}

@Test func longLabelsAreCut() {
    let long = BeeLabel.shorten(String(repeating: "word ", count: 30))
    #expect(long.count == BeeLabel.maxLength)
    #expect(long.hasSuffix("…"))
    #expect(BeeLabel.shorten("Press   Send\n") == "Press Send")
}
