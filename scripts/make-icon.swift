// Draws the Beeline app icon and writes Resources/AppIcon.icns.
// Run from the repo root:  swift scripts/make-icon.swift
import AppKit

let honey50 = NSColor(red: 0.980, green: 0.933, blue: 0.855, alpha: 1)
let honey100 = NSColor(red: 0.980, green: 0.780, blue: 0.459, alpha: 1)
let amber400 = NSColor(red: 0.729, green: 0.459, blue: 0.090, alpha: 1)
let bark800 = NSColor(red: 0.388, green: 0.220, blue: 0.024, alpha: 1)

/// The mark is designed on a 40-unit grid: a wandering dashed path that straightens into a line and lands on a dot.
func drawIcon(size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let context = NSGraphicsContext.current!.cgContext

    // macOS icons sit in an 824-point rounded square inside a 1024-point canvas.
    let inset = size * 100 / 1024
    let side = size - inset * 2
    let tile = CGRect(x: inset, y: inset, width: side, height: side)
    let shape = CGPath(roundedRect: tile, cornerWidth: side * 0.225, cornerHeight: side * 0.225, transform: nil)

    context.saveGState()
    context.addPath(shape)
    context.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                              colors: [honey50.cgColor, honey100.cgColor] as CFArray, locations: [0.35, 1])!
    context.drawLinearGradient(gradient, start: CGPoint(x: tile.midX, y: tile.maxY),
                               end: CGPoint(x: tile.midX, y: tile.minY), options: [])
    context.restoreGState()

    // Map the 40-unit design grid, which has y pointing down, onto the tile.
    let unit = side / 40
    // The mark is enlarged about its own centre so it fills the tile.
    func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        let grown = CGPoint(x: 20 + (x - 20.5) * 1.3, y: 20 + (y - 19.5) * 1.3)
        return CGPoint(x: tile.minX + grown.x * unit, y: tile.maxY - grown.y * unit)
    }
    context.setLineCap(.round)

    context.setStrokeColor(amber400.cgColor)
    context.setLineWidth(unit * 2.9)
    context.setLineDash(phase: 0, lengths: [unit * 0.1, unit * 5.2])
    context.move(to: point(9, 28.5))
    context.addCurve(to: point(20.5, 21.5), control1: point(11, 13), control2: point(17, 30))
    context.strokePath()

    context.setStrokeColor(bark800.cgColor)
    context.setLineWidth(unit * 3.6)
    context.setLineDash(phase: 0, lengths: [])
    context.move(to: point(22.6, 19.4))
    context.addLine(to: point(30, 12))
    context.strokePath()

    context.setFillColor(bark800.cgColor)
    let dot = point(30, 12)
    context.fillEllipse(in: CGRect(x: dot.x - unit * 4.1, y: dot.y - unit * 4.1, width: unit * 8.2, height: unit * 8.2))

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("Beeline.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        let png = drawIcon(size: CGFloat(base * scale)).representation(using: .png, properties: [:])!
        try png.write(to: iconset.appendingPathComponent(name))
    }
}

let convert = Process()
convert.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
convert.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
try convert.run()
convert.waitUntilExit()
print(convert.terminationStatus == 0 ? "Wrote Resources/AppIcon.icns" : "iconutil failed")
