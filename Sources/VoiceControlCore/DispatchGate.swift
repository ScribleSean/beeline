import Foundation

/// A local, exact approval. It deliberately contains no printable preview or telemetry.
public struct ConfirmationToken: Equatable, Sendable {
    public let id: UUID
    public let proposal: ActionProposal
    public let stateRevision: UInt64
}

/// The lock is the linearization point for both cancellation and every OS effect.
/// Driver callbacks must be bounded, synchronous and must not call back into this gate.
public final class DispatchGate: @unchecked Sendable {
    private let lock = NSLock()
    private var request: RequestToken
    private var stateRevision: UInt64 = 0
    private var pending: ConfirmationToken?
    private var approved: ConfirmationToken?
    private let releaseHeldInputs: @Sendable () -> Void

    public init(request: RequestToken = RequestToken(), releaseHeldInputs: @escaping @Sendable () -> Void) {
        self.request = request
        self.releaseHeldInputs = releaseHeldInputs
    }

    public var currentRequest: RequestToken { lock.withLock { request } }
    public func isCurrent(_ token: RequestToken) -> Bool { lock.withLock { request == token } }

    /// Correction/stop is synchronous even while an actor awaits a model or AX call.
    @discardableResult public func invalidate() -> RequestToken {
        lock.withLock {
            request = RequestToken(sessionID: request.sessionID, generation: request.generation &+ 1)
            stateRevision &+= 1
            pending = nil; approved = nil
            releaseHeldInputs()
            return request
        }
    }

    public func beginSession(_ token: RequestToken) {
        lock.withLock {
            request = token; stateRevision &+= 1
            pending = nil; approved = nil
            releaseHeldInputs()
        }
    }

    /// A manual input or changed observation invalidates approval and queued coordinates.
    @discardableResult public func manualStateChanged() -> RequestToken { invalidate() }

    public func makeConfirmation(for proposal: ActionProposal) -> ConfirmationToken? {
        lock.withLock {
            guard request == proposal.request, proposal.action.requiresConfirmation else { return nil }
            let token = ConfirmationToken(id: UUID(), proposal: proposal, stateRevision: stateRevision)
            pending = token; approved = nil
            return token
        }
    }

    /// Call only from the physical keyboard handler. Spoken/model Enter has no approval API.
    @discardableResult public func approvePhysicalEnter(_ token: ConfirmationToken) -> Bool {
        lock.withLock {
            guard pending == token, token.proposal.request == request,
                  token.stateRevision == stateRevision else { return false }
            pending = nil; approved = token
            return true
        }
    }

    public func permits(_ proposal: ActionProposal, confirmation: ConfirmationToken? = nil) -> Bool {
        lock.withLock { permitsLocked(proposal, confirmation: confirmation) }
    }

    /// No event can start after invalidate wins this lock. Already posted effects cannot be recalled.
    @discardableResult public func perform(_ step: PreparedStep, for proposal: ActionProposal,
                                           confirmation: ConfirmationToken? = nil,
                                           using driver: any ActionDriver) throws -> Bool {
        try lock.withLock {
            guard permitsLocked(proposal, confirmation: confirmation) else { return false }
            try driver.perform(step)
            return true
        }
    }

    public func finish(_ confirmation: ConfirmationToken?) {
        lock.withLock {
            if let confirmation, approved == confirmation { approved = nil }
        }
    }

    public func releaseInputs() { lock.withLock { releaseHeldInputs() } }

    private func permitsLocked(_ proposal: ActionProposal, confirmation: ConfirmationToken?) -> Bool {
        guard proposal.request == request else { return false }
        guard proposal.action.requiresConfirmation else { return true }
        guard let confirmation else { return false }
        return confirmation.proposal == proposal && confirmation.stateRevision == stateRevision
            && approved == confirmation
    }
}
