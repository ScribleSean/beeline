import Foundation

public struct SessionSnapshot: Equatable, Sendable {
    public let request: RequestToken
    public let isListening: Bool
    public let holdIsDown: Bool
    public let releaseSampleFence: Int64?
    public let pendingWork: Int
    public let hasPendingPrompt: Bool
    public let quietDeadline: TimeInterval?
}

/// Audio sample fences and monotonic times come from the capture owner, never wall clock.
public final class SessionArbiter: @unchecked Sendable {
    private let lock = NSLock()
    public let gate: DispatchGate
    public let quietWindow: TimeInterval
    private var listening = false
    private var held = false
    private var releaseFence: Int64?
    private var work = 0
    private var prompt = false
    private var deadline: TimeInterval?

    public init(gate: DispatchGate, quietWindow: TimeInterval = 5) {
        precondition(quietWindow > 0)
        self.gate = gate; self.quietWindow = quietWindow
    }

    @discardableResult public func begin(now: TimeInterval) -> RequestToken {
        lock.withLock {
            let token = RequestToken()
            gate.beginSession(token)
            listening = true; held = true; releaseFence = nil
            work = 0; prompt = false; deadline = nil
            return token
        }
    }

    /// Release finalizes through this captured sample. It does not invalidate generation.
    public func release(sampleFence: Int64, now: TimeInterval) {
        lock.withLock {
            guard listening else { return }
            held = false; releaseFence = sampleFence
            updateDeadline(now: now)
        }
    }

    public func speechReceived(now: TimeInterval) {
        lock.withLock {
            guard listening else { return }
            updateDeadline(now: now)
        }
    }

    /// Pending audio finalization, interpretation and execution all count as work.
    public func setPending(work: Int, prompt: Bool, now: TimeInterval) {
        precondition(work >= 0)
        lock.withLock {
            guard listening else { return }
            let wasPending = self.work > 0 || self.prompt
            self.work = work; self.prompt = prompt
            if work > 0 || prompt { deadline = nil }
            else if wasPending || deadline == nil { updateDeadline(now: now) }
        }
    }

    /// Spoken stop keeps the correction microphone open. Escape/stop-listening closes it.
    @discardableResult public func stop(now: TimeInterval, closeListening: Bool = false) -> RequestToken {
        lock.withLock {
            let token = gate.invalidate()
            work = 0; prompt = false
            if closeListening { listening = false; held = false; deadline = nil }
            else { updateDeadline(now: now) }
            return token
        }
    }

    @discardableResult public func correction(now: TimeInterval) -> RequestToken {
        lock.withLock {
            let token = gate.invalidate()
            work = 1; prompt = false; deadline = nil
            return token
        }
    }

    /// Returns true only for the transition to closed. The audio owner then stops capture.
    @discardableResult public func tick(now: TimeInterval) -> Bool {
        lock.withLock {
            guard listening, !held, work == 0, !prompt, let deadline, now >= deadline else { return false }
            listening = false; self.deadline = nil
            gate.invalidate()
            return true
        }
    }

    public var snapshot: SessionSnapshot {
        lock.withLock {
            SessionSnapshot(request: gate.currentRequest, isListening: listening, holdIsDown: held,
                            releaseSampleFence: releaseFence, pendingWork: work,
                            hasPendingPrompt: prompt, quietDeadline: deadline)
        }
    }

    private func updateDeadline(now: TimeInterval) {
        deadline = listening && !held && work == 0 && !prompt ? now + quietWindow : nil
    }
}
