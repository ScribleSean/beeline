import Foundation
import Testing
@testable import Beeline

private func file(_ name: String) -> Item {
    Item(id: name, kind: .file, verb: "Open", title: name, subtitle: "Documents", keywords: "", icon: nil, run: {})
}

// M21: accents and case do not matter either way round.
@Test func accentsDoNotMatter() {
    #expect(Matcher.score(file("Résumé 2026.pdf"), Matcher.parse("resume"))?.isComplete == true)
    #expect(Matcher.score(file("Resume.pdf"), Matcher.parse("résumé"))?.isComplete == true)
    #expect(Matcher.score(file("Café plans"), Matcher.parse("cafe"))?.isComplete == true)
    #expect(Matcher.fold("Ångström") == "angstrom")
    #expect(Matcher.fold("Plain") == "plain")
}
