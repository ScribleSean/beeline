import AppKit
import Foundation
import Vision
import Testing
@testable import Beeline

@MainActor @Test func theSettingsWindowDrawsItsControls() throws {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent("beeline-settings-\(UUID().uuidString).png").path
    defer { try? FileManager.default.removeItem(atPath: path) }
    SettingsWindowController.renderPreview(to: path)
    let rep = try #require(NSBitmapImageRep(data: try Data(contentsOf: URL(fileURLWithPath: path))))
    #expect(rep.pixelsWide >= 300 && rep.pixelsHigh >= 300, "got \(rep.pixelsWide)×\(rep.pixelsHigh)")
    var colors = Set<UInt32>()
    for y in stride(from: 0, to: rep.pixelsHigh, by: 7) {
        for x in stride(from: 0, to: rep.pixelsWide, by: 7) {
            guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
            colors.insert(UInt32(color.redComponent * 255) << 16 | UInt32(color.greenComponent * 255) << 8 | UInt32(color.blueComponent * 255))
        }
    }
    #expect(colors.count > 8, "a blank render has one or two colors; drawn controls and text have many")

    let image = try #require(rep.cgImage)
    var lines: [String] = []
    let request = VNRecognizeTextRequest { request, _ in
        lines = (request.results as? [VNRecognizedTextObservation] ?? []).compactMap { $0.topCandidates(1).first?.string }
    }
    request.recognitionLevel = .accurate
    try VNImageRequestHandler(cgImage: image).perform([request])
    #expect(lines.contains { $0.localizedCaseInsensitiveContains("Hold the shortcut to talk") }, "read from the render: \(lines)")
}
