import Foundation

/// Interpretation supplies a canonical meaning and exact literal arguments locally.
public struct SemanticClause: Equatable, Sendable {
    public let meaning: String
    public let action: BoundedAction
    public let isComplete: Bool
    public init(meaning: String, action: BoundedAction, isComplete: Bool = true) {
        self.meaning = meaning; self.action = action; self.isComplete = isComplete
    }
}

public struct TranscriptRevision: Sendable {
    public let request: RequestToken
    public let utteranceID: UUID
    public let revision: UInt64
    public let clauses: [SemanticClause]
    public let isFinal: Bool
    public let observedAt: TimeInterval
    public init(request: RequestToken, utteranceID: UUID, revision: UInt64,
                clauses: [SemanticClause], isFinal: Bool, observedAt: TimeInterval) {
        self.request = request; self.utteranceID = utteranceID; self.revision = revision
        self.clauses = clauses; self.isFinal = isFinal; self.observedAt = observedAt
    }
}

public struct LedgerUpdate: Sendable {
    public let proposals: [ActionProposal]
    public let invalidatedOperationIDs: [UUID]
    /// The UI can retrieve local action details by ID and accurately report what already occurred.
    public let changedExecutedOperationIDs: [UUID]
    public var mustInvalidateSuffix: Bool { !invalidatedOperationIDs.isEmpty }
}

/// Keeps occurrence identity, rather than matching clauses globally (which loses intentional repeats).
public final class TranscriptLedger: @unchecked Sendable {
    private struct Entry {
        let id: UUID
        var clause: SemanticClause
        let firstSeen: TimeInterval
        var unchangedUpdates: Int
        var admitted: Bool
        var executed: Bool
    }
    private struct Utterance {
        var latestRevision: UInt64
        var entries: [Entry]
        var blockedGeneration: UInt64?
    }
    private let lock = NSLock()
    private var sessionID: UUID?
    private var utterances: [UUID: Utterance] = [:]
    private var occurred: [UUID: SemanticClause] = [:]
    public let stabilityWindow: TimeInterval

    public init(stabilityWindow: TimeInterval = 0.2) {
        precondition(stabilityWindow >= 0)
        self.stabilityWindow = stabilityWindow
    }

    public func update(_ update: TranscriptRevision) -> LedgerUpdate {
        lock.withLock {
            if sessionID != update.request.sessionID {
                sessionID = update.request.sessionID; utterances.removeAll(); occurred.removeAll()
            }
            var utterance = utterances[update.utteranceID]
                ?? Utterance(latestRevision: 0, entries: [], blockedGeneration: nil)
            if utterances[update.utteranceID] != nil && update.revision <= utterance.latestRevision {
                return LedgerUpdate(proposals: [], invalidatedOperationIDs: [], changedExecutedOperationIDs: [])
            }
            var sharedPrefix = 0
            while sharedPrefix < min(utterance.entries.count, update.clauses.count),
                  sameMeaning(utterance.entries[sharedPrefix].clause, update.clauses[sharedPrefix]) {
                sharedPrefix += 1
            }
            let changed = Array(utterance.entries.dropFirst(sharedPrefix))
            let invalidated = changed.filter { $0.admitted || $0.executed }.map(\.id)
            let executed = changed.filter(\.executed).map(\.id)
            utterance.entries = Array(utterance.entries.prefix(sharedPrefix))
            for index in 0..<sharedPrefix {
                utterance.entries[index].unchangedUpdates += 1
                // Keep fresh geometry for an unissued clause without replaying its consumed identity.
                utterance.entries[index].clause = update.clauses[index]
            }
            for clause in update.clauses.dropFirst(sharedPrefix) {
                utterance.entries.append(Entry(id: UUID(), clause: clause, firstSeen: update.observedAt,
                                              unchangedUpdates: 1, admitted: false, executed: false))
            }
            var proposals: [ActionProposal] = []
            if !invalidated.isEmpty { utterance.blockedGeneration = update.request.generation }
            if let blocked = utterance.blockedGeneration, update.request.generation != blocked {
                utterance.blockedGeneration = nil
            }
            // A changed admitted prefix requires a new generation before any replacement suffix is issued.
            if invalidated.isEmpty && utterance.blockedGeneration == nil {
                for index in utterance.entries.indices {
                    let entry = utterance.entries[index]
                    guard entry.clause.isComplete else { break }
                    if entry.admitted { continue }
                    let stable = entry.unchangedUpdates >= 2
                        && update.observedAt - entry.firstSeen >= stabilityWindow
                    guard update.isFinal || (stable && entry.clause.action.isEarlyEligible) else { break }
                    proposals.append(ActionProposal(request: update.request, operationID: entry.id,
                                                    action: entry.clause.action, finalized: update.isFinal))
                    utterance.entries[index].admitted = true
                }
            }
            utterance.latestRevision = update.revision
            utterances[update.utteranceID] = utterance
            return LedgerUpdate(proposals: proposals, invalidatedOperationIDs: invalidated,
                                changedExecutedOperationIDs: executed)
        }
    }

    public func markExecuted(_ operationID: UUID) {
        lock.withLock {
            for utteranceID in Array(utterances.keys) {
                guard var utterance = utterances[utteranceID],
                      let index = utterance.entries.firstIndex(where: { $0.id == operationID }) else { continue }
                utterance.entries[index].executed = true
                occurred[operationID] = utterance.entries[index].clause
                utterances[utteranceID] = utterance
                return
            }
        }
    }

    public func occurredAction(for operationID: UUID) -> BoundedAction? {
        lock.withLock { occurred[operationID]?.action }
    }

    public func reset() { lock.withLock { sessionID = nil; utterances.removeAll(); occurred.removeAll() } }

    private func sameMeaning(_ lhs: SemanticClause, _ rhs: SemanticClause) -> Bool {
        guard lhs.meaning == rhs.meaning, lhs.isComplete == rhs.isComplete else { return false }
        switch (lhs.action, rhs.action) {
        case let (.activateApplication(a), .activateApplication(b)): return a == b
        case let (.focus(a), .focus(b)), let (.movePointer(a), .movePointer(b)), let (.click(a), .click(b)):
            return sameTarget(a, b)
        case let (.scroll(a, av), .scroll(b, bv)): return sameTarget(a, b) && av == bv
        case let (.insertText(a, av), .insertText(b, bv)): return sameTarget(a, b) && av == bv
        case let (.deleteText(a, ar, av), .deleteText(b, br, bv)):
            return sameTarget(a, b) && ar == br && av == bv
        case let (.sendMessage(a, ar, ac), .sendMessage(b, br, bc)):
            return sameTarget(a, b) && ar == br && ac == bc
        case let (.spend(a, am, ai, aa, ac, at), .spend(b, bm, bi, ba, bc, bt)):
            return sameTarget(a, b) && am == bm && ai == bi && aa == ba && ac == bc && at == bt
        default: return false
        }
    }

    private func sameTarget(_ lhs: TargetReference, _ rhs: TargetReference) -> Bool {
        lhs.targetID == rhs.targetID && lhs.applicationID == rhs.applicationID
            && lhs.windowID == rhs.windowID && lhs.role == rhs.role
            && lhs.label == rhs.label && lhs.isEditable == rhs.isEditable
    }
}
