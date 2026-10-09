import Foundation
import Testing
@testable import VoiceControlCore

@Test func releaseFinalizesWithoutCancellingAndSpeechAtFourPointNineExtends() {
    let gate = DispatchGate(releaseHeldInputs: {})
    let session = SessionArbiter(gate: gate)
    let original = session.begin(now: 0)
    session.release(sampleFence: 48000, now: 1)
    #expect(session.snapshot.request == original)
    #expect(session.snapshot.releaseSampleFence == 48000)
    session.speechReceived(now: 5.9)
    #expect(session.tick(now: 6) == false)
    #expect(session.tick(now: 10.89) == false)
    #expect(session.tick(now: 10.9))
    #expect(session.snapshot.isListening == false)
}

@Test func pendingWorkAndPromptsNeverQuietTimeout() {
    let gate = DispatchGate(releaseHeldInputs: {})
    let session = SessionArbiter(gate: gate)
    session.begin(now: 0)
    session.release(sampleFence: 100, now: 0)
    session.setPending(work: 1, prompt: false, now: 0)
    #expect(session.tick(now: 100) == false)
    session.setPending(work: 0, prompt: true, now: 100)
    #expect(session.tick(now: 1000) == false)
    session.setPending(work: 0, prompt: false, now: 1000)
    #expect(session.tick(now: 1004.9) == false)
    #expect(session.tick(now: 1005))
}

@Test func correctionInvalidatesSynchronouslyAndEscapeCloses() {
    let gate = DispatchGate(releaseHeldInputs: {})
    let session = SessionArbiter(gate: gate)
    let first = session.begin(now: 0)
    let correction = session.correction(now: 1)
    #expect(correction.generation == first.generation + 1)
    #expect(session.snapshot.pendingWork == 1)
    #expect(session.snapshot.isListening)
    session.stop(now: 2, closeListening: true)
    #expect(session.snapshot.isListening == false)
    #expect(session.snapshot.holdIsDown == false)
}
