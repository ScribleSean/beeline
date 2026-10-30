import AppKit
import SwiftUI

final class Bee {
    private let model = BeeModel()
    private var panel: NSPanel?
    private var position: CGPoint?
    private var hideWork: DispatchWorkItem?

    static var isEnabled: Bool { forceOn || Settings.isOn(Settings.showBee) }
    static var forceOn = false
    static var pace: Double = 1

    /// One plan step: the bee flies to it when it's on and the step has a place on screen. Otherwise nothing
    /// moves, so VoiceOver hears the step here instead. Nil when the bee didn't fly.
    @MainActor
    func guide(to target: (() -> CGRect?)?, saying text: String, speaking: String, from origin: CGPoint?,
               enabled: Bool = Bee.isEnabled) async -> Bool? {
        guard enabled, let rect = target?(), rect.width > 0, rect.height > 0 else {
            Announce.say(speaking)
            return nil
        }
        return await fly(to: rect, saying: text, speaking: speaking, from: origin)
    }

    @MainActor
    /// `text` is the short label beside the bee; VoiceOver hears `speaking`, the untruncated action, when given.
    func fly(to axTarget: CGRect, saying text: String, speaking: String? = nil, from origin: CGPoint?) async -> Bool {
        hideWork?.cancel()
        let frames = NSScreen.screens.map(\.frame)
        guard let primary = NSScreen.screens.first?.frame,
              axTarget.width > 0, axTarget.height > 0 else { return false }
        let target = BeeFlight.appKitRect(fromAX: axTarget, primaryHeight: primary.height)
        guard let screen = BeeFlight.screen(for: target, among: frames) else { return false }

        let perch = BeeFlight.perch(beside: target, in: screen)
        var start = position ?? origin ?? perch
        if BeeFlight.screen(containing: start, among: [screen]) == nil {
            start = CGPoint(x: min(max(start.x, screen.minX + 15), screen.maxX - 15),
                            y: min(max(start.y, screen.minY + 15), screen.maxY - 15))
        }
        let still = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let duration = still ? 0 : BeeFlight.duration(from: start, to: perch) * Self.pace

        let panel = overlay(on: screen)
        model.screen = screen
        model.ring = nil
        model.show(text, speaking: speaking)
        model.flight = BeeFlight.Path(from: still ? perch : start, to: perch)
        model.flightStart = Date()
        model.duration = duration
        model.faceLeftWhenLanded = target.midX < perch.x
        model.isShown = true
        position = perch
        panel.orderFrontRegardless()
        DemoLog.note("bee-takeoff", ["from": DemoLog.numbers(start), "to": DemoLog.numbers(perch),
                                     "target": DemoLog.numbers(target), "seconds": duration, "label": text])

        try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
        if Task.isCancelled { return false }
        model.ring = target
        model.ringStart = Date()
        DemoLog.note("bee-landed", ["at": DemoLog.numbers(perch)])
        try? await Task.sleep(nanoseconds: UInt64(180_000_000 * Self.pace))
        return !Task.isCancelled
    }

    @discardableResult
    func say(_ text: String) -> Bool {
        guard model.isShown else { return false }
        model.show(text)
        model.ring = nil
        return true
    }

    func leave(after delay: TimeInterval = 0.6) {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func hide() {
        hideWork?.cancel()
        model.isShown = false
        model.ring = nil
        position = nil
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
    @Published var faceLeftWhenLanded = false

    /// Spoken every time: the bee's panel ignores the mouse, so VoiceOver never lands on it.
    func show(_ label: String, speaking: String? = nil) {
        self.label = label
        Announce.say(speaking ?? label)  // medium: a step label shouldn't cut off what the target app says
    }

    /// AppKit screen coordinates start at the bottom left; the SwiftUI overlay's start at the top left.
    func local(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x - screen.minX, y: screen.maxY - point.y)
    }

    func local(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX - screen.minX, y: screen.maxY - rect.maxY, width: rect.width, height: rect.height)
    }
}

private struct BeeOverlay: View {
    @ObservedObject var model: BeeModel
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        TimelineView(.animation(minimumInterval: nil, paused: !model.isShown)) { context in
            let now = context.date
            let elapsed = now.timeIntervalSince(model.flightStart)
            let progress = model.duration > 0 ? min(1, elapsed / model.duration) : 1
            let flying = progress < 1
            let bob = flying ? 0 : sin(now.timeIntervalSinceReferenceDate * 2 * .pi * 0.7) * 1.5
            let spot = model.local(model.flight.point(at: progress))
            // Screen angles point up; SwiftUI's rotationEffect turns clockwise, hence the minus on the tilt.
            let heading = model.flight.heading(at: progress)
            let faceLeft = flying ? cos(heading) < 0 : model.faceLeftWhenLanded
            let climb = atan2(sin(heading), abs(cos(heading))) * 180 / .pi
            let tilt = flying ? max(-14, min(14, -climb * 0.25)) : 0
            let onRight = spot.x + 22 + 260 + 8 < model.screen.width

            ZStack(alignment: .topLeading) {
                if let ring = model.ring {
                    TargetRing(rect: model.local(ring), age: now.timeIntervalSince(model.ringStart))
                }
                BeeGlyph(time: now.timeIntervalSinceReferenceDate, flying: flying)
                    .rotationEffect(.degrees(tilt))
                    .scaleEffect(x: faceLeft ? -1 : 1, y: 1)
                    .position(x: spot.x, y: spot.y + bob)
                if let label = model.label, !flying {
                    Text(label)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .padding(.horizontal, 10)
                        .frame(height: 24)
                        .background(labelBackground, in: Capsule())
                        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))
                        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
                        .frame(maxWidth: 260, alignment: onRight ? .leading : .trailing)
                        .position(x: onRight ? spot.x + 22 + 130 : spot.x - 22 - 130, y: spot.y + bob)
                        .transition(.opacity)
                }
            }
            .frame(width: model.screen.width, height: model.screen.height, alignment: .topLeading)
        }
        // On a notched display, the safe area would push the whole-screen overlay down.
        .ignoresSafeArea()
        .opacity(model.isShown ? 1 : 0)
        .animation(.easeOut(duration: 0.2), value: model.isShown)
        .animation(.easeOut(duration: 0.15), value: model.label)
        .allowsHitTesting(false)
        // Kept out of the tree so hit tests at a target never land on this full-screen panel; the bee speaks instead.
        .accessibilityHidden(true)
    }

    private var labelBackground: AnyShapeStyle {
        BarSurface.isSolid(increaseContrast: contrast == .increased, reduceTransparency: reduceTransparency)
            ? AnyShapeStyle(Color(nsColor: .windowBackgroundColor)) : AnyShapeStyle(.regularMaterial)
    }
}

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

private struct BeeGlyph: View {
    let time: TimeInterval
    let flying: Bool

    var body: some View {
        let beat = flying ? sin(time * 2 * .pi * 11) : sin(time * 2 * .pi * 1.4) * 0.4
        let wing = 0.75 + 0.25 * beat
        ZStack {
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

            Circle()
                .fill(Theme.ink)
                .frame(width: 9, height: 9)
                .offset(x: 8.5, y: 0.5)
            Capsule()
                .fill(LinearGradient(colors: [Color(red: 1, green: 0.85, blue: 0.4), Theme.yellow],
                                     startPoint: .top, endPoint: .bottom))
                .frame(width: 19, height: 14)
                .overlay(
                    HStack(spacing: 3.5) {
                        Rectangle().frame(width: 2.5)
                        Rectangle().frame(width: 2.5)
                    }
                    .foregroundStyle(Theme.ink)
                    .offset(x: 1.5)
                )
                .clipShape(Capsule())
                .overlay(Capsule().strokeBorder(Theme.ink.opacity(0.85), lineWidth: 1))
                .offset(x: -2.5, y: 1)
        }
        .frame(width: BeeFlight.beeSize.width, height: BeeFlight.beeSize.height)
        .shadow(color: .black.opacity(0.22), radius: 3, y: 1.5)
    }
}
