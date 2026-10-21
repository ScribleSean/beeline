import CoreGraphics
import Foundation

/// The geometry of the bee's flight: where it rests beside a target, the arc it flies, and how long that
/// takes. Pure functions, so they can be tested without a screen.
///
/// Rects in AppKit screen coordinates (origin bottom left of the primary screen) unless named `ax`:
/// Accessibility measures from the top left of the primary screen instead.
enum BeeFlight {
    /// The bee's drawn size.
    static let beeSize = CGSize(width: 30, height: 30)

    /// An Accessibility rect in AppKit coordinates.
    static func appKitRect(fromAX rect: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    /// Where the bee's center rests beside a target: just off its top-right corner, so it points at the
    /// target without covering it. Moves to the other side or below when that corner is off screen, and
    /// always stays wholly on screen.
    static func perch(beside target: CGRect, in screen: CGRect, beeSize: CGSize = beeSize) -> CGPoint {
        let half = CGSize(width: beeSize.width / 2, height: beeSize.height / 2)
        let gap: CGFloat = 4
        var x = target.maxX + half.width + gap
        var y = target.maxY + half.height + gap
        if x + half.width > screen.maxX { x = target.minX - half.width - gap }
        if y + half.height > screen.maxY { y = target.minY - half.height - gap }
        // A target as big as the screen (a full-screen window) leaves no outside: rest in its corner.
        x = min(max(x, screen.minX + half.width), screen.maxX - half.width)
        y = min(max(y, screen.minY + half.height), screen.maxY - half.height)
        return CGPoint(x: x, y: y)
    }

    /// The screen that holds most of a rect, or nil when it is on none (a window on another Space can
    /// report a place no screen shows); the bee then stays home rather than fly somewhere unrelated.
    static func screen(for rect: CGRect, among screens: [CGRect]) -> CGRect? {
        screens.max { area($0.intersection(rect)) < area($1.intersection(rect)) }
            .flatMap { area($0.intersection(rect)) > 0 ? $0 : nil }
    }

    /// The screen holding a point. Inclusive at every edge, so a point on a screen's top or right edge
    /// still counts as on it (NSRect.contains leaves those out).
    static func screen(containing point: CGPoint, among screens: [CGRect]) -> CGRect? {
        screens.first { point.x >= $0.minX && point.x <= $0.maxX && point.y >= $0.minY && point.y <= $0.maxY }
    }

    private static func area(_ rect: CGRect) -> CGFloat {
        rect.isNull ? 0 : rect.width * rect.height
    }

    /// Short hops are quick and long ones take a little longer, but never so long the wait shows.
    static func duration(from start: CGPoint, to end: CGPoint) -> TimeInterval {
        min(0.62, 0.3 + Double(distance(start, end)) / 2600)
    }

    static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(b.x - a.x, b.y - a.y)
    }

    /// A gentle arc from one point to another, the way a bee drifts rather than a pointer snaps.
    struct Path: Equatable {
        let start: CGPoint
        let end: CGPoint
        let control: CGPoint

        init(from start: CGPoint, to end: CGPoint) {
            self.start = start
            self.end = end
            let mid = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
            let length = BeeFlight.distance(start, end)
            guard length > 0.5 else {
                control = mid
                return
            }
            // Bow sideways by a fifth of the distance, at most 110 points, always toward the top of the screen.
            var normal = CGPoint(x: -(end.y - start.y) / length, y: (end.x - start.x) / length)
            if normal.y < 0 { normal = CGPoint(x: -normal.x, y: -normal.y) }
            let bow = min(110, length * 0.2)
            control = CGPoint(x: mid.x + normal.x * bow, y: mid.y + normal.y * bow)
        }

        /// The point at progress `t`, from 0 to 1, after easing.
        func point(at t: Double) -> CGPoint {
            let u = CGFloat(BeeFlight.ease(t))
            let a = (1 - u) * (1 - u), b = 2 * (1 - u) * u, c = u * u
            return CGPoint(x: a * start.x + b * control.x + c * end.x, y: a * start.y + b * control.y + c * end.y)
        }

        /// The direction of travel at `t`, in radians, for tilting the bee into the turn.
        func heading(at t: Double) -> Double {
            let u = CGFloat(BeeFlight.ease(t))
            let dx = 2 * (1 - u) * (control.x - start.x) + 2 * u * (end.x - control.x)
            let dy = 2 * (1 - u) * (control.y - start.y) + 2 * u * (end.y - control.y)
            return dx == 0 && dy == 0 ? 0 : Double(atan2(dy, dx))
        }
    }

    /// Ease in and out: slow to lift off, quick across, soft to land.
    static func ease(_ t: Double) -> Double {
        let t = min(max(t, 0), 1)
        return t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
    }
}
