import Testing
@testable import VoiceControlCore

@Test func activationMayRunEarly() {
    #expect(BoundedAction.activateApplication(bundleID: "com.apple.Safari").isEarlyEligible)
}
