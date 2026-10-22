// Builds the app icon and the menu bar glyph from Resources/AppIcon-source.png.
// Run from the repo root:  swift scripts/make-icon.swift
import AppKit

let source = NSImage(contentsOfFile: "Resources/AppIcon-source.png")!
let sourceImage = source.cgImage(forProposedRect: nil, context: nil, hints: nil)!

func bitmap(_ size: Int, draw: (CGContext) -> Void) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let context = NSGraphicsContext.current!.cgContext
    context.interpolationQuality = .high
    draw(context)
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

/// The standard macOS icon tile is an 824-point rounded square in a 1024-point canvas.
func drawIcon(size: Int) -> NSBitmapImageRep {
    bitmap(size) { context in
        let side = CGFloat(size)
        let inset = side * 100 / 1024
        let tile = CGRect(x: inset, y: inset, width: side - inset * 2, height: side - inset * 2)
        context.addPath(CGPath(roundedRect: tile, cornerWidth: tile.width * 0.225, cornerHeight: tile.width * 0.225, transform: nil))
        context.clip()
        context.draw(sourceImage, in: tile.insetBy(dx: -tile.width * 0.035, dy: -tile.width * 0.035))
    }
}

/// macOS tints a black shape on transparent for light and dark menu bars. 36 pixels, shown at 18 points.
func drawGlyph() -> NSBitmapImageRep {
    let width = CGFloat(sourceImage.width), margin = width * 0.07
    let crop = sourceImage.cropping(to: CGRect(x: margin, y: margin, width: width - margin * 2, height: width - margin * 2))!
    let size = 36
    let gray = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size,
                         space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
    gray.interpolationQuality = .high
    gray.draw(crop, in: CGRect(x: 0, y: 0, width: size, height: size))
    let lightness = gray.data!.bindMemory(to: UInt8.self, capacity: size * size)

    let rep = bitmap(size) { _ in }
    for y in 0..<size {
        for x in 0..<size {
            let level = Double(lightness[y * size + x]) / 255
            let alpha = max(0, min(1, (0.55 - level) / 0.3))
            rep.setColor(NSColor(deviceRed: 0, green: 0, blue: 0, alpha: alpha), atX: x, y: y)
        }
    }
    return rep
}

let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("Beeline-\(UUID().uuidString).iconset")
defer { try? FileManager.default.removeItem(at: iconset) }
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try drawIcon(size: base * scale).representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
    }
}
let convert = Process()
convert.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
convert.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
try convert.run()
convert.waitUntilExit()
try drawGlyph().representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "Resources/MenuBarGlyph.png"))

if let preview = ProcessInfo.processInfo.environment["ICON_PREVIEW"] {
    try drawIcon(size: 512).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: preview))
}
guard convert.terminationStatus == 0 else {
    print("iconutil failed")
    exit(1)
}
print("Wrote Resources/AppIcon.icns and Resources/MenuBarGlyph.png")
