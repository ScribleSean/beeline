import Foundation
import Testing
@testable import VoiceControlCore

private func revision(_ request: RequestToken, _ utterance: UUID, _ number: UInt64,
                      _ time: TimeInterval, _ clauses: [SemanticClause], final: Bool = false) -> TranscriptRevision {
    TranscriptRevision(request: request, utteranceID: utterance, revision: number, clauses: clauses,
                       isFinal: final, observedAt: time)
}
private let safari = SemanticClause(meaning: "activate Safari", action: .activateApplication(bundleID: "com.apple.Safari"))
private let textEdit = SemanticClause(meaning: "activate TextEdit", action: .activateApplication(bundleID: "com.apple.TextEdit"))

@Test func stableSafeClauseEmitsOnceAndIntentionalRepeatGetsNewID() {
    let ledger = TranscriptLedger()
    let request = RequestToken(); let utterance = UUID()
    #expect(ledger.update(revision(request, utterance, 1, 0, [safari])).proposals.isEmpty)
    #expect(ledger.update(revision(request, utterance, 2, 0.1, [safari])).proposals.isEmpty)
    let admitted = ledger.update(revision(request, utterance, 3, 0.21, [safari])).proposals
    #expect(admitted.count == 1)
    #expect(ledger.update(revision(request, utterance, 4, 0.3, [safari])).proposals.isEmpty)
    let repeated = ledger.update(revision(request, utterance, 5, 0.4, [safari, safari], final: true)).proposals
    #expect(repeated.count == 1)
    #expect(repeated.first?.operationID != admitted.first?.operationID)
}

@Test func changedExecutedPrefixInvalidatesDependentSuffixAndPreservesOccurredAction() throws {
    let ledger = TranscriptLedger()
    let request = RequestToken(); let utterance = UUID()
    let first = ledger.update(revision(request, utterance, 1, 0, [safari, textEdit], final: true))
    let executed = try #require(first.proposals.first)
    ledger.markExecuted(executed.operationID)
    let changed = ledger.update(revision(request, utterance, 2, 0.3, [textEdit], final: true))
    #expect(changed.mustInvalidateSuffix)
    #expect(changed.invalidatedOperationIDs.count == 2)
    #expect(changed.changedExecutedOperationIDs == [executed.operationID])
    #expect(changed.proposals.isEmpty)
    #expect(ledger.occurredAction(for: executed.operationID) == safari.action)
    #expect(ledger.update(revision(request, utterance, 3, 0.35, [textEdit], final: true)).proposals.isEmpty)
    let correctedRequest = RequestToken(sessionID: request.sessionID, generation: 1)
    let corrected = ledger.update(revision(correctedRequest, utterance, 4, 0.4, [textEdit], final: true))
    #expect(corrected.proposals.count == 1)
    #expect(corrected.proposals.first?.request == correctedRequest)
}

@Test func freshObservationKeepsConsumedIdentityButDifferentTargetInvalidates() throws {
    let ledger = TranscriptLedger()
    let request = RequestToken(); let utterance = UUID(); let identity = UUID()
    func clause(targetID: UUID, x: Double) -> SemanticClause {
        let target = TargetReference(observationID: UUID(), targetID: targetID, applicationID: "fixture",
                                     windowID: "1", role: "text", label: "same label",
                                     bounds: ScreenRect(x: x, y: 0, width: 10, height: 10), isEditable: true)
        return SemanticClause(meaning: "focus field", action: .focus(target))
    }
    let initial = ledger.update(revision(request, utterance, 1, 0, [clause(targetID: identity, x: 0)], final: true))
    let id = try #require(initial.proposals.first?.operationID)
    ledger.markExecuted(id)
    let fresh = ledger.update(revision(request, utterance, 2, 1, [clause(targetID: identity, x: 100)], final: true))
    #expect(fresh.proposals.isEmpty)
    #expect(fresh.mustInvalidateSuffix == false)
    let different = ledger.update(revision(request, utterance, 3, 2, [clause(targetID: UUID(), x: 100)], final: true))
    #expect(different.changedExecutedOperationIDs == [id])
}

@Test func nonAllowlistedTypingWaitsForFinalAndOldRevisionsCannotReplay() {
    let ledger = TranscriptLedger()
    let request = RequestToken(); let utterance = UUID()
    let target = TargetReference(observationID: UUID(), applicationID: "fixture", windowID: "1", role: "text",
                                 label: "field", bounds: ScreenRect(x: 0, y: 0, width: 1, height: 1), isEditable: true)
    let literal = SemanticClause(meaning: "type literal", action: .insertText(target, text: "hello"))
    #expect(ledger.update(revision(request, utterance, 1, 0, [literal])).proposals.isEmpty)
    #expect(ledger.update(revision(request, utterance, 2, 0.3, [literal])).proposals.isEmpty)
    #expect(ledger.update(revision(request, utterance, 3, 0.4, [literal], final: true)).proposals.count == 1)
    #expect(ledger.update(revision(request, utterance, 2, 0.5, [literal], final: true)).proposals.isEmpty)
}
