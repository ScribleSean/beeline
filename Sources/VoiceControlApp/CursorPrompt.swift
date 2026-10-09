import AppKit

@MainActor
final class CursorPrompt {
    private let panel: NSPanel
    private let label = NSTextField(wrappingLabelWithString: "")

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 330, height: 84),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let effect = NSVisualEffectView()
        effect.material = .popover; effect.blendingMode = .behindWindow; effect.state = .active
        effect.wantsLayer = true; effect.layer?.cornerRadius = 12
        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.textColor = .labelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 14),
            label.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -14),
            label.topAnchor.constraint(equalTo: effect.topAnchor, constant: 12),
            label.bottomAnchor.constraint(lessThanOrEqualTo: effect.bottomAnchor, constant: -12)
        ])
        panel.contentView = effect
    }

    func show(_ text: String) {
        label.stringValue = text
        let cursor = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(cursor) }?.visibleFrame ?? NSScreen.main!.visibleFrame
        let x = min(max(cursor.x + 18, screen.minX), screen.maxX - panel.frame.width)
        let y = min(max(cursor.y - panel.frame.height - 18, screen.minY), screen.maxY - panel.frame.height)
        panel.setFrameOrigin(NSPoint(x: x, y: y))
        panel.orderFrontRegardless()
    }

    func hide() { panel.orderOut(nil) }
}
