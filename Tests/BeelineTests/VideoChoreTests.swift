import AVFoundation
import Foundation
import Testing
@testable import Beeline

/// A one-second movie written by AVAssetWriter, with silent audio if asked. The picture is one flat colour per frame,
/// or noise, which cannot be compressed away, so the bitrate asked for is the bitrate used.
private func movie(_ name: String, audio: Bool, width: Int = 320, height: Int = 240, bitrate: Int? = nil, noise: Bool = false, in scratch: Scratch) async throws -> URL {
    let url = scratch.url.appendingPathComponent(name)
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let fps = 10
    var settings: [String: Any] = [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height]
    if let bitrate { settings[AVVideoCompressionPropertiesKey] = [AVVideoAverageBitRateKey: bitrate] }
    let video = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height])
    writer.add(video)
    var sound: AVAssetWriterInput?
    if audio {
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 1])
        writer.add(input)
        sound = input
    }
    try #require(writer.startWriting())
    writer.startSession(atSourceTime: .zero)

    for frame in 0..<fps {
        while !video.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 5_000_000) }
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &buffer)
        let pixels = try #require(buffer)
        CVPixelBufferLockBaseAddress(pixels, [])
        let count = CVPixelBufferGetBytesPerRow(pixels) * height
        if noise { arc4random_buf(CVPixelBufferGetBaseAddress(pixels), count) } else { memset(CVPixelBufferGetBaseAddress(pixels), Int32(frame * 20), count) }
        CVPixelBufferUnlockBaseAddress(pixels, [])
        #expect(adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps))))
    }
    video.markAsFinished()

    if let sound {
        var description = AudioStreamBasicDescription(mSampleRate: 44_100, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked, mBytesPerPacket: 2, mFramesPerPacket: 1,
            mBytesPerFrame: 2, mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0)
        var format: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &description, layoutSize: 0, layout: nil, magicCookieSize: 0,
                                       magicCookie: nil, extensions: nil, formatDescriptionOut: &format)
        let samples = 44_100
        let silence = [Int16](repeating: 0, count: samples)
        var block: CMBlockBuffer?
        silence.withUnsafeBytes { raw in
            CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: raw.count, blockAllocator: nil,
                customBlockSource: nil, offsetToData: 0, dataLength: raw.count, flags: 0, blockBufferOut: &block)
            CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block!, offsetIntoDestination: 0, dataLength: raw.count)
        }
        var buffer: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block!, formatDescription: format!,
            sampleCount: samples, presentationTimeStamp: .zero, packetDescriptions: nil, sampleBufferOut: &buffer)
        while !sound.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 5_000_000) }
        #expect(sound.append(try #require(buffer)))
        sound.markAsFinished()
    }
    await writer.finishWriting()
    try #require(writer.status == .completed, "the fixture movie was not written: \(String(describing: writer.error))")
    return url
}

@Test func saveTheAudioMakesAnM4aBesideTheMovie() async throws {
    let scratch = try Scratch()
    defer { scratch.remove() }
    let clip = try await movie("clip.mov", audio: true, in: scratch)

    let made = FileTools.exportedVideos([clip], preset: "PresetAppleM4A", suffix: "", ext: "m4a")
    #expect(made.map(\.lastPathComponent) == ["clip.m4a"])
    let track = try await AVURLAsset(url: try #require(made.first)).loadTracks(withMediaType: .audio)
    #expect(!track.isEmpty, "the m4a holds an audio track")
    #expect(scratch.exists("clip.mov"), "the movie stays as it was")

    let again = FileTools.exportedVideos([clip], preset: "PresetAppleM4A", suffix: "", ext: "m4a")
    #expect(again.map(\.lastPathComponent) == ["clip 2.m4a"], "a second export never overwrites the first")
}

@Test func aMovieWithNoSoundGivesNoAudioFile() async throws {
    let scratch = try Scratch()
    defer { scratch.remove() }
    let silent = try await movie("mute.mov", audio: false, in: scratch)
    #expect(FileTools.exportedVideos([silent], preset: "PresetAppleM4A", suffix: "", ext: "m4a").isEmpty)
    #expect(!scratch.exists("mute.m4a"))
}

private func bytes(_ url: URL) throws -> Int {
    try #require(FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
}

@Test func aBigHighBitrateMovieGetsASmaller720pCopy() async throws {
    let scratch = try Scratch()
    defer { scratch.remove() }
    let clip = try await movie("big.mov", audio: false, width: 1920, height: 1080, bitrate: 40_000_000, noise: true, in: scratch)

    let made = FileTools.exportedVideos([clip], preset: "Preset1280x720", suffix: " 720p", ext: "mp4")
    #expect(made.map(\.lastPathComponent) == ["big 720p.mp4"])
    #expect(try made.first.map(bytes) ?? .max < bytes(clip))
    #expect(scratch.exists("big.mov"), "the movie stays as it was")
}

@Test func aCopyThatComesOutBiggerIsRemoved() async throws {
    let scratch = try Scratch()
    defer { scratch.remove() }
    // Noise squeezed into very few bits: small as a file, costly to encode again at 720p.
    let clip = try await movie("tiny.mov", audio: false, bitrate: 50_000, noise: true, in: scratch)

    // The same export under another suffix is kept whatever its size: it shows the copy really is made, and is bigger.
    let kept = try #require(FileTools.exportedVideos([clip], preset: "Preset1280x720", suffix: " copy", ext: "mp4").first)
    try #require(try bytes(kept) >= bytes(clip), "the fixture must be a movie whose 720p copy is not smaller")

    #expect(FileTools.exportedVideos([clip], preset: "Preset1280x720", suffix: " 720p", ext: "mp4").isEmpty)
    #expect(!scratch.exists("tiny 720p.mp4"), "the bigger copy is deleted, not left beside the movie")
    #expect(scratch.exists("tiny.mov"))
}

@Test func somethingThatIsNotAMovieGivesNothing() throws {
    let scratch = try Scratch()
    defer { scratch.remove() }
    let fake = try scratch.file("fake.mov", "not a movie")
    #expect(FileTools.exportedVideos([fake], preset: "Preset1280x720", suffix: " 720p", ext: "mp4").isEmpty)
    #expect(!scratch.exists("fake 720p.mp4"))
}
