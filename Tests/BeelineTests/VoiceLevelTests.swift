import AVFoundation
import Testing
@testable import Beeline

@Test func theMeterReadsLoudnessOnADecibelScale() {
    #expect(Voice.level(rms: 0) == 0)
    #expect(Voice.level(rms: 1) == 1)
    #expect(Voice.level(rms: 2) == 1)
    // -50 dB is the floor; -25 dB is halfway.
    #expect(Voice.level(rms: 0.003) == 0)
    #expect(abs(Voice.level(rms: pow(10, -25.0 / 20)) - 0.5) < 0.001)
}

@Test func aSilentBufferReadsZero() throws {
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 256))
    buffer.frameLength = 256
    #expect(Voice.level(of: buffer) == 0)
    for index in 0..<256 { buffer.floatChannelData![0][index] = index.isMultiple(of: 2) ? 0.5 : -0.5 }
    #expect(Voice.level(of: buffer) > 0.8)
}
