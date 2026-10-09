import Foundation

/// Content-free status safe for diagnostics. Action payloads remain local to the queue.
public struct OperationRecord: Equatable, Sendable {
    public let request: RequestToken
    public let operationID: UUID
    public let outcome: OperationOutcome
}

public actor SerialExecutor {
    public nonisolated let gate: DispatchGate
    private let driver: any ActionDriver
    private var queue: [ActionProposal] = []
    private var accepted: Set<UUID> = []
    private var records: [OperationRecord] = []
    private var draining = false
    private var confirmation: ConfirmationToken?
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(driver: any ActionDriver, gate: DispatchGate) { self.driver = driver; self.gate = gate }

    /// IDs are never retried, including unknown outcomes. A deliberate new action needs a new ID.
    @discardableResult public func submit(_ proposal: ActionProposal) -> Bool {
        guard gate.isCurrent(proposal.request), !accepted.contains(proposal.operationID),
              proposal.finalized || proposal.action.isEarlyEligible else { return false }
        accepted.insert(proposal.operationID)
        queue.append(proposal)
        startDrain()
        return true
    }

    public var pendingConfirmation: ConfirmationToken? {
        guard let confirmation, gate.isCurrent(confirmation.proposal.request) else { return nil }
        return confirmation
    }
    public var outcomes: [OperationRecord] { records }

    @discardableResult public func approvePhysicalEnter(_ token: ConfirmationToken) -> Bool {
        guard confirmation == token, gate.approvePhysicalEnter(token) else { return false }
        startDrain()
        return true
    }

    /// Returns immediately after invalidation and input release, independent of actor scheduling.
    @discardableResult public nonisolated func cancel() -> RequestToken {
        let token = gate.invalidate()
        Task { await self.resumeInvalidatedQueue() }
        return token
    }
    @discardableResult public nonisolated func correct() -> RequestToken { cancel() }

    /// Settled means drained or waiting for physical confirmation; it never waits for a prompt.
    public func waitUntilSettled() async {
        if !draining { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func resumeInvalidatedQueue() { startDrain() }
    private func startDrain() {
        guard !draining, !queue.isEmpty else { return }
        draining = true
        Task { await self.drain() }
    }

    private func drain() async {
        while let proposal = queue.first {
            guard gate.isCurrent(proposal.request) else {
                complete(proposal, .aborted); continue
            }
            if proposal.action.requiresConfirmation {
                if confirmation?.proposal != proposal {
                    confirmation = gate.makeConfirmation(for: proposal)
                }
                guard gate.permits(proposal, confirmation: confirmation) else { break }
            }
            let outcome = await execute(proposal, confirmation: confirmation)
            complete(proposal, outcome)
        }
        draining = false
        let settled = waiters; waiters.removeAll()
        for waiter in settled { waiter.resume() }
    }

    private func execute(_ proposal: ActionProposal, confirmation: ConfirmationToken?) async -> OperationOutcome {
        guard gate.permits(proposal, confirmation: confirmation) else { return .aborted }
        let valid = await driver.validate(proposal.action)
        guard gate.permits(proposal, confirmation: confirmation) else { return .aborted }
        guard valid else { gate.releaseInputs(); return .failed }
        let steps: [PreparedStep]
        do { steps = try await driver.prepare(proposal.action) }
        catch {
            guard gate.permits(proposal, confirmation: confirmation) else { return .aborted }
            gate.releaseInputs(); return .failed
        }
        guard gate.permits(proposal, confirmation: confirmation) else { return .aborted }
        // Preparation may await or take time; target validity must be checked again before posting.
        let stillValid = await driver.validate(proposal.action)
        guard gate.permits(proposal, confirmation: confirmation) else { return .aborted }
        guard stillValid else { gate.releaseInputs(); return .failed }
        var posted = false
        for step in steps {
            do {
                guard try gate.perform(step, for: proposal, confirmation: confirmation, using: driver) else {
                    return posted ? .unknown : .aborted
                }
                posted = true
            } catch {
                gate.releaseInputs()
                // A throwing OS call can have partially delivered its effect.
                return .unknown
            }
        }
        guard gate.permits(proposal, confirmation: confirmation) else { return posted ? .unknown : .aborted }
        let verified = await driver.verify(proposal.action)
        // Cancellation during verification cannot erase an already delivered effect.
        guard gate.permits(proposal, confirmation: confirmation) else {
            return posted ? .unknown : .aborted
        }
        switch verified { case .verified: return .completed; case .failed: return .failed; case .unknown: return .unknown }
    }

    private func complete(_ proposal: ActionProposal, _ outcome: OperationOutcome) {
        if outcome != .completed { gate.releaseInputs() }
        records.append(OperationRecord(request: proposal.request, operationID: proposal.operationID, outcome: outcome))
        queue.removeFirst()
        gate.finish(confirmation)
        confirmation = nil
    }
}
