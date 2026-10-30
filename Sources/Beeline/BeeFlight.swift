import CoreGraphics
import Foundation

enum BeeFlight {
    static let beeSize = CGSize(width: 30, height: 30)

    static func appKitRect(fromAX rect: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    static func perch(beside target: CGRect, in screen: CGRect, beeSize: CGSize = beeSize) -> CGPoint {
        let half = CGSize(width: beeSize.width / 2, height: beeSize.height / 2)
        let gap: CGFloat = 4
        var x = target.maxX + half.width + gap
        var y = target.maxY + half.height + gap
        if x + half.width > screen.maxX { x = target.minX - half.width - gap }
        if y + half.height > screen.maxY { y = target.minY - half.height - gap }
        x = min(max(x, screen.minX + half.width), screen.maxX - half.width)
        y = min(max(y, screen.minY + half.height), screen.maxY - half.height)
        return CGPoint(x: x, y: y)
    }

    /// A window on another Space can report a frame that no screen shows.
    static func screen(for rect: CGRect, among screens: [CGRect]) -> CGRect? {
        screens.max { area($0.intersection(rect)) < area($1.intersection(rect)) }
            .flatMap { area($0.intersection(rect)) > 0 ? $0 : nil }
    }

    /// Inclusive at every edge: NSRect.contains leaves out points on a screen's top and right edges.
    static func screen(containing point: CGPoint, among screens: [CGRect]) -> CGRect? {
        screens.first { point.x >= $0.minX && point.x <= $0.maxX && point.y >= $0.minY && point.y <= $0.maxY }
    }

    private static func area(_ rect: CGRect) -> CGFloat {
        rect.isNull ? 0 : rect.width * rect.height
    }

    static func duration(from start: CGPoint, to end: CGPoint) -> TimeInterval {
        min(0.62, 0.3 + Double(distance(start, end)) / 2600)
    }

    static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(b.x - a.x, b.y - a.y)
    }

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
            var normal = CGPoint(x: -(end.y - start.y) / length, y: (end.x - start.x) / length)
            if normal.y < 0 { normal = CGPoint(x: -normal.x, y: -normal.y) }
            let bow = min(110, length * 0.2)
            control = CGPoint(x: mid.x + normal.x * bow, y: mid.y + normal.y * bow)
        }

        func point(at t: Double) -> CGPoint {
            let u = CGFloat(BeeFlight.ease(t))
            let a = (1 - u) * (1 - u), b = 2 * (1 - u) * u, c = u * u
            return CGPoint(x: a * start.x + b * control.x + c * end.x, y: a * start.y + b * control.y + c * end.y)
        }

        func heading(at t: Double) -> Double {
            let u = CGFloat(BeeFlight.ease(t))
            let dx = 2 * (1 - u) * (control.x - start.x) + 2 * u * (end.x - control.x)
            let dy = 2 * (1 - u) * (control.y - start.y) + 2 * u * (end.y - control.y)
            return dx == 0 && dy == 0 ? 0 : Double(atan2(dy, dx))
        }
    }

    static func ease(_ t: Double) -> Double {
        let t = min(max(t, 0), 1)
        return t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
    }
}
