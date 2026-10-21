import AppKit
import SwiftUI

/// The bee: Beeline's own cursor, which shows where Beeline is about to act. When you press Return on
/// something on screen, it flies there from the bar, a ring settles around the target, and then the
/// action runs. Your real pointer never moves.
///
/// It is drawn in a click-through overlay on the target's screen, never takes focus, and rests beside
/// the target rather than on it.
final class Bee {
    private let model = BeeModel()
    private var panel: NSPanel?
    /// Where the bee is now, in AppKit screen coordinates, so the next flight starts from there.
    private var position: CGPoint?
    private var hideWork: DispatchWorkItem?

    static var isEnabled: Bool { Settings.isOn(Settings.showBee) }

    /// Flies to a target and rings it. Returns false when the flight was cancelled or the target is on no
    /// screen. `axTarget` is in Accessibility coordinates; `origin` is where to start if the bee is not
    /// already out, in AppKit coordinates.
    @MainActor
    func fly(to axTarget: CGRect, saying text: String, from origin: CGPoint?) async -> Bool {
        hideWork?.cancel()
        let frames = NSScreen.screens.map(\.frame)
        guard let primary = NSScreen.screens.first?.frame,
              axTarget.width > 0, axTarget.height > 0 else { return false }
        let target = BeeFlight.appKitRect(fromAX: axTarget, primaryHeight: primary.height)
        guard let screen = BeeFlight.screen(for: target, among: frames) else { return false }

        let perch = BeeFlight.perch(beside: target, in: screen)
        // A bee out on another screen starts again from this one's nearest edge point.
        var start = position ?? origin ?? perch
        if BeeFlight.screen(containing: start, among: [screen]) == nil {
            start = CGPoint(x: min(max(start.x, screen.minX + 15), screen.maxX - 15),
                            y: min(max(start.y, screen.minY + 15), screen.maxY - 15))
        }
        let still = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let duration = still ? 0 : BeeFlight.duration(from: start, to: perch)

        let panel = overlay(on: screen)
        model.screen = screen
        model.ring = nil
        model.label = text
        model.flight = BeeFlight.Path(from: still ? perch : start, to: perch)
        model.flightStart = Date()
        model.duration = duration
        model.isShown = true
        position = perch
        panel.orderFrontRegardless()

        // Land, then let the ring settle before the action runs, so you see where it happens first.
        try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
        if Task.isCancelled { return false }
        model.ring = target
        model.ringStart = Date()
        try? await Task.sleep(nanoseconds: 180_000_000)
        return !Task.isCancelled
    }

    /// Says something short beside the bee where it is, such as why it stopped.
    func say(_ text: String) {
        guard model.isShown else { return }
        model.label = text
        model.ring = nil
    }

    /// Fades away after a moment, unless another flight starts first.
    func leave(after delay: TimeInterval = 0.6) {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Gone at once.
    func hide() {
        hideWork?.cancel()
        model.isShown = false
        model.ring = nil
        position = nil
        // The fade is drawn by SwiftUI; the window goes once it has finished.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, !self.model.isShown else { return }
            self.panel?.orderOut(nil)
        }
    }

    private func overlay(on screen: CGRect) -> NSPanel {
        let panel = self.panel ?? {
            let panel = NSPanel(contentRect: screen, styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: false)
            panel.level = .statusBar
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            // Clicks go straight through to whatever is underneath (review #8).
            panel.ignoresMouseEvents = true
            panel.isReleasedWhenClosed = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            panel.contentView = NSHostingView(rootView: BeeOverlay(model: model))
            self.panel = panel
            return panel
        }()
        if panel.frame != screen { panel.setFrame(screen, display: false) }
        return panel
    }
}

final class BeeModel: ObservableObject {
    @Published var screen: CGRect = .zero
    @Published var flight = BeeFlight.Path(from: .zero, to: .zero)
    @Published var flightStart = Date()
    @Published var duration: TimeInterval = 0
    @Published var ring: CGRect?
    @Published var ringStart = Date()
    @Published var label: String?
    @Published var isShown = false

    /// AppKit screen coordinates to the overlay's own, which start at the top left.
    func local(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x - screen.minX, y: screen.maxY - point.y)
    }

    func local(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX - screen.minX, y: screen.maxY - rect.maxY, width: rect.width, height: rect.height)
    }
}

private struct BeeOverlay: View {
    @ObservedObject var model: BeeModel

    var body: some View {
        TimelineView(.animation(minimumInterval: nil, paused: !model.isShown)) { context in
            let now = context.date
            let elapsed = now.timeIntervalSince(model.flightStart)
            let progress = model.duration > 0 ? min(1, elapsed / model.duration) : 1
            let flying = progress < 1
            // A slow hover once landed: a point and a half up and down.
            let bob = flying ? 0 : sin(now.timeIntervalSinceReferenceDate * 2 * .pi * 0.7) * 1.5
            let spot = model.local(model.flight.point(at: progress))
            // Tilt into the direction of travel, a little. Screen angles point up; the overlay's y points down.
            let tilt = flying ? max(-14, min(14, -model.flight.heading(at: progress) * 180 / .pi * 0.12)) : 0
            let onRight = spot.x + 200 < model.screen.width

            ZStack(alignment: .topLeading) {
                if let ring = model.ring {
                    TargetRing(rect: model.local(ring), age: now.timeIntervalSince(model.ringStart))
                }
                BeeGlyph(time: now.timeIntervalSinceReferenceDate, flying: flying)
                    .rotationEffect(.degrees(tilt))
                    .position(x: spot.x, y: spot.y + bob)
                if let label = model.label, !flying {
                    Text(label)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .padding(.horizontal, 10)
                        .frame(height: 24)
                        .background(.regularMaterial, in: Capsule())
                        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))
                        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
                        .fixedSize()
                        .frame(maxWidth: 260, alignment: onRight ? .leading : .trailing)
                        .position(x: onRight ? spot.x + 22 + 130 : spot.x - 22 - 130, y: spot.y + bob)
                        .transition(.opacity)
                }
            }
            .frame(width: model.screen.width, height: model.screen.height, alignment: .topLeading)
        }
        .opacity(model.isShown ? 1 : 0)
        .animation(.easeOut(duration: 0.2), value: model.isShown)
        .animation(.easeOut(duration: 0.15), value: model.label)
        .allowsHitTesting(false)
    }
}

/// A thin yellow ring that settles onto the target, with one soft pulse outward.
private struct TargetRing: View {
    let rect: CGRect
    let age: TimeInterval

    var body: some View {
        let settle = BeeFlight.ease(min(1, age / 0.22))
        let pulse = min(1, age / 0.6)
        let box = rect.insetBy(dx: -4, dy: -4)
        let radius = min(10, min(box.width, box.height) / 2)
        ZStack {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(Theme.yellow.opacity(0.35 * (1 - pulse)), lineWidth: 6)
                .frame(width: box.width + 14 * pulse, height: box.height + 14 * pulse)
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(Theme.yellow, lineWidth: 2)
                .frame(width: box.width * (1.06 - 0.06 * settle), height: box.height * (1.06 - 0.06 * settle))
                .opacity(settle)
        }
        .shadow(color: Theme.yellow.opacity(0.35), radius: 4)
        .position(x: box.midX, y: box.midY)
    }
}

/// The bee, drawn rather than an image so its wings can move: a yellow body with two ink bands, an ink
/// head and two pale wings that beat while it flies and drift slowly once it lands.
private struct BeeGlyph: View {
    let time: TimeInterval
    let flying: Bool

    var body: some View {
        let beat = flying ? sin(time * 2 * .pi * 11) : sin(time * 2 * .pi * 1.4) * 0.4
        let wing = 0.75 + 0.25 * beat
        ZStack {
            // Wings sit behind and above the body.
            Group {
                Ellipse().frame(width: 10, height: 13)
                    .scaleEffect(x: 1, y: wing, anchor: .bottom)
                    .rotationEffect(.degrees(-20), anchor: .bottom)
                    .offset(x: -3, y: -9)
                Ellipse().frame(width: 10, height: 13)
                    .scaleEffect(x: 1, y: wing, anchor: .bottom)
                    .rotationEffect(.degrees(20), anchor: .bottom)
                    .offset(x: 4, y: -9)
            }
            .foregroundStyle(Color.white.opacity(0.92))
            .overlay(Group {
                Ellipse().stroke(Theme.ink.opacity(0.25), lineWidth: 0.75).frame(width: 10, height: 13)
                    .scaleEffect(x: 1, y: wing, anchor: .bottom).rotationEffect(.degrees(-20), anchor: .bottom).offset(x: -3, y: -9)
                Ellipse().stroke(Theme.ink.opacity(0.25), lineWidth: 0.75).frame(width: 10, height: 13)
                    .scaleEffect(x: 1, y: wing, anchor: .bottom).rotationEffect(.degrees(20), anchor: .bottom).offset(x: 4, y: -9)
            })

            Capsule()
                .fill(Theme.yellow)
                .frame(width: 20, height: 14)
                .overlay(
                    HStack(spacing: 3.5) {
                        Rectangle().frame(width: 2.5)
                        Rectangle().frame(width: 2.5)
                    }
                    .foregroundStyle(Theme.ink)
                    .offset(x: -1)
                )
                .clipShape(Capsule())
                .overlay(Capsule().strokeBorder(Theme.ink.opacity(0.85), lineWidth: 1))
                .offset(x: -2, y: 1)
            Circle()
                .fill(Theme.ink)
                .frame(width: 8, height: 8)
                .offset(x: 10, y: 0)
        }
        .frame(width: BeeFlight.beeSize.width, height: BeeFlight.beeSize.height)
        .shadow(color: .black.opacity(0.22), radius: 3, y: 1.5)
    }
}
