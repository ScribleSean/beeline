import Foundation
import Testing
@testable import VoiceControlCore

private actor Suspension {
    private var entered = false
    private var released = false
    private var blocked: CheckedContinuation<Void, Never>?
    private var observers: [CheckedContinuation<Void, Never>] = []
    func pause() async {
        entered = true
        let waiting = observers; observers.removeAll()
        for observer in waiting { observer.resume() }
        if released { return }
        await withCheckedContinuation { blocked = $0 }
    }
    func waitForEntry() async {
        if entered { return }
        await withCheckedContinuation { observers.append($0) }
    }
    func resume() { released = true; blocked?.resume(); blocked = nil }
}

private final class TestDriver: ActionDriver, @unchecked Sendable {
    enum Stage: Sendable { case firstValidation, preparation, lastValidation, verification, none }
    let suspension = Suspension()
    private let lock = NSLock()
    let stage: Stage
    private var validations = 0
    private var events: [PreparedStep] = []
    private var releases = 0
    private var valid = true
    var verification: Verification = .verified
    init(stage: Stage = .none) { self.stage = stage }
    func validate(_ action: BoundedAction) async -> Bool {
        let count = lock.withLock { validations += 1; return validations }
        if (stage == .firstValidation && count == 1) || (stage == .lastValidation && count == 2) {
            await suspension.pause()
        }
        return lock.withLock { valid }
    }
    func prepare(_ action: BoundedAction) async throws -> [PreparedStep] {
        if stage == .preparation { await suspension.pause() }
        return [.event(.unicodeDown("fixture")), .event(.unicodeUp)]
    }
    func perform(_ step: PreparedStep) throws { lock.withLock { events.append(step) } }
    func verify(_ action: BoundedAction) async -> Verification {
        if stage == .verification { await suspension.pause() }
        return verification
    }
    func releaseHeldInputs() { lock.withLock { releases += 1 } }
    func invalidateTarget() { lock.withLock { valid = false } }
    var posted: [PreparedStep] { lock.withLock { events } }
    var releaseCount: Int { lock.withLock { releases } }
}

private func executorFixture(stage: TestDriver.Stage = .none) -> (TestDriver, DispatchGate, SerialExecutor) {
    let driver = TestDriver(stage: stage)
    let gate = DispatchGate(releaseHeldInputs: { driver.releaseHeldInputs() })
    return (driver, gate, SerialExecutor(driver: driver, gate: gate))
}

private func confirmedAction() -> BoundedAction {
    let target = TargetReference(observationID: UUID(), applicationID: "fixture", windowID: "1",
                                 role: "text", label: "field", bounds: ScreenRect(x: 0, y: 0, width: 10, height: 10),
                                 isEditable: true)
    return .deleteText(target, span: TextSpan(location: 0, length: 3), expectedText: "abc")
}

@Test(arguments: [TestDriver.Stage.firstValidation, .preparation, .lastValidation])
private func cancellationDuringAwaitPreventsEveryPost(stage: TestDriver.Stage) async {
    let (driver, gate, executor) = executorFixture(stage: stage)
    let proposal = ActionProposal(request: gate.currentRequest, action: .activateApplication(bundleID: "fixture"), finalized: true)
    #expect(await executor.submit(proposal))
    await driver.suspension.waitForEntry()
    let next = executor.cancel()
    #expect(next.generation == proposal.request.generation + 1)
    #expect(driver.releaseCount >= 1)
    await driver.suspension.resume()
    await executor.waitUntilSettled()
    #expect(driver.posted.isEmpty)
    #expect(await executor.outcomes.map(\.outcome) == [.aborted])
}

@Test private func cancellationDuringVerificationReportsUnknownAndNeverRetries() async {
    let (driver, gate, executor) = executorFixture(stage: .verification)
    let proposal = ActionProposal(request: gate.currentRequest, action: .activateApplication(bundleID: "fixture"), finalized: true)
    #expect(await executor.submit(proposal))
    await driver.suspension.waitForEntry()
    executor.cancel()
    await driver.suspension.resume()
    await executor.waitUntilSettled()
    #expect(driver.posted.count == 2)
    #expect(await executor.outcomes.map(\.outcome) == [.unknown])
    let duplicate = ActionProposal(request: gate.currentRequest, operationID: proposal.operationID,
                                   action: proposal.action, finalized: true)
    #expect(await executor.submit(duplicate) == false)
}

@Test private func exactPhysicalEnterRequiredAndTargetRevalidated() async throws {
    let (driver, gate, executor) = executorFixture()
    let proposal = ActionProposal(request: gate.currentRequest, action: confirmedAction(), finalized: true)
    #expect(await executor.submit(proposal))
    await executor.waitUntilSettled()
    #expect(driver.posted.isEmpty)
    let token = try #require(await executor.pendingConfirmation)
    driver.invalidateTarget()
    #expect(await executor.approvePhysicalEnter(token))
    await executor.waitUntilSettled()
    #expect(driver.posted.isEmpty)
    #expect(await executor.outcomes.map(\.outcome) == [.failed])
    #expect(await executor.approvePhysicalEnter(token) == false)
}

@Test private func changedManualStateInvalidatesExactApproval() async throws {
    let (driver, gate, executor) = executorFixture()
    let proposal = ActionProposal(request: gate.currentRequest, action: confirmedAction(), finalized: true)
    #expect(await executor.submit(proposal))
    await executor.waitUntilSettled()
    let token = try #require(await executor.pendingConfirmation)
    gate.manualStateChanged()
    #expect(await executor.approvePhysicalEnter(token) == false)
    executor.cancel()
    await executor.waitUntilSettled()
    #expect(driver.posted.isEmpty)
}

@Test private func approvedOperationRunsOnceAndGateRejectsCancelledGeneration() async throws {
    let (driver, gate, executor) = executorFixture()
    let proposal = ActionProposal(request: gate.currentRequest, action: confirmedAction(), finalized: true)
    #expect(await executor.submit(proposal))
    await executor.waitUntilSettled()
    let token = try #require(await executor.pendingConfirmation)
    #expect(await executor.approvePhysicalEnter(token))
    await executor.waitUntilSettled()
    #expect(driver.posted.count == 2)
    #expect(await executor.outcomes.map(\.outcome) == [.completed])
    #expect(await executor.submit(proposal) == false)
    gate.invalidate()
    #expect(try gate.perform(.event(.scroll(1)), for: proposal, using: driver) == false)
    #expect(driver.posted.count == 2)
}

@Test private func externalGateInvalidationDoesNotStrandFreshSubmissionBehindPrompt() async {
    let (driver, gate, executor) = executorFixture()
    let old = ActionProposal(request: gate.currentRequest, action: confirmedAction(), finalized: true)
    #expect(await executor.submit(old))
    await executor.waitUntilSettled()
    let next = gate.invalidate()
    let fresh = ActionProposal(request: next, action: .activateApplication(bundleID: "fixture"), finalized: true)
    #expect(await executor.submit(fresh))
    await executor.waitUntilSettled()
    #expect(await executor.outcomes.map(\.outcome) == [.aborted, .completed])
    #expect(await executor.pendingConfirmation == nil)
    #expect(driver.posted.count == 2)
}

@Test private func confirmationCannotBeReboundToChangedContent() throws {
    let (driver, gate, _) = executorFixture()
    let action = confirmedAction()
    let proposal = ActionProposal(request: gate.currentRequest, action: action, finalized: true)
    let token = try #require(gate.makeConfirmation(for: proposal))
    let target = try #require(action.target)
    let changed = ActionProposal(request: proposal.request, operationID: proposal.operationID,
                                 action: .deleteText(target, span: TextSpan(location: 0, length: 3), expectedText: "xyz"),
                                 finalized: true)
    let rebound = ConfirmationToken(id: token.id, proposal: changed, stateRevision: token.stateRevision)
    #expect(gate.approvePhysicalEnter(rebound) == false)
    #expect(gate.approvePhysicalEnter(token))
    #expect(try gate.perform(.event(.keyDown(51)), for: changed, confirmation: token, using: driver) == false)
    #expect(driver.posted.isEmpty)
}
