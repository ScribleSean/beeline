import CoreGraphics
import Testing
@testable import Beeline

private let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)

@Test func accessibilityRectsFlipToAppKit() {
    // 100 points from the top of a 900-point screen, 40 tall: its bottom is 760 from the bottom.
    let rect = BeeFlight.appKitRect(fromAX: CGRect(x: 20, y: 100, width: 80, height: 40), primaryHeight: 900)
    #expect(rect == CGRect(x: 20, y: 760, width: 80, height: 40))
}

@Test func theBeeRestsBesideATargetNotOnIt() {
    let target = CGRect(x: 600, y: 400, width: 80, height: 24)
    let perch = BeeFlight.perch(beside: target, in: screen)
    let bee = CGRect(x: perch.x - 15, y: perch.y - 15, width: 30, height: 30)
    #expect(!bee.intersects(target))
    #expect(perch.x > target.maxX && perch.y > target.maxY)
}

@Test func theBeeStaysOnScreenAtTheEdges() {
    // A button in the top-right corner: the bee moves to its left and below it.
    let corner = CGRect(x: 1400, y: 880, width: 40, height: 20)
    let perch = BeeFlight.perch(beside: corner, in: screen)
    #expect(perch.x + 15 <= screen.maxX && perch.y + 15 <= screen.maxY)
    #expect(perch.x < corner.minX && perch.y < corner.minY)
    // A full-screen window leaves no outside; the bee still fits on screen.
    let whole = BeeFlight.perch(beside: screen, in: screen)
    #expect(screen.insetBy(dx: 15, dy: 15).contains(whole) || whole.x == screen.maxX - 15)
}

@Test func aPointOnTheTopOrRightEdgeIsOnThatScreen() {
    let left = CGRect(x: 0, y: 0, width: 1440, height: 900)
    let right = CGRect(x: 1440, y: 0, width: 1920, height: 1080)
    // NSRect.contains would say no to both of these (review #32).
    #expect(BeeFlight.screen(containing: CGPoint(x: 1440, y: 500), among: [left, right]) != nil)
    #expect(BeeFlight.screen(containing: CGPoint(x: 100, y: 900), among: [left, right]) == left)
    #expect(BeeFlight.screen(containing: CGPoint(x: -5, y: 5), among: [left, right]) == nil)
}

@Test func aTargetBelongsToTheScreenHoldingMostOfIt() {
    let left = CGRect(x: 0, y: 0, width: 1440, height: 900)
    let right = CGRect(x: 1440, y: 0, width: 1920, height: 1080)
    #expect(BeeFlight.screen(for: CGRect(x: 1400, y: 100, width: 200, height: 50), among: [left, right]) == right)
    #expect(BeeFlight.screen(for: CGRect(x: 9000, y: 9000, width: 10, height: 10), among: [left, right]) == left)
}

@Test func theFlightStartsAndEndsWhereItShould() {
    let path = BeeFlight.Path(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 900, y: 300))
    #expect(path.point(at: 0) == CGPoint(x: 100, y: 100))
    #expect(path.point(at: 1) == CGPoint(x: 900, y: 300))
    // It bows upward, not in a straight line.
    let middle = path.point(at: 0.5)
    #expect(middle.y > 200)
    // Progress outside 0...1 is held at the ends.
    #expect(path.point(at: 1.5) == path.point(at: 1))
}

@Test func aFlightToWhereTheBeeAlreadyIsStaysPut() {
    let spot = CGPoint(x: 300, y: 300)
    let path = BeeFlight.Path(from: spot, to: spot)
    #expect(path.point(at: 0.5) == spot)
    #expect(path.heading(at: 0.5) == 0)
}

@Test func flightsAreQuickAndNeverDrag() {
    let short = BeeFlight.duration(from: .zero, to: CGPoint(x: 10, y: 0))
    let long = BeeFlight.duration(from: .zero, to: CGPoint(x: 5000, y: 3000))
    #expect(short >= 0.3 && short < 0.32)
    #expect(long == 0.62)
}

@Test func easingIsSmoothAndBounded() {
    #expect(BeeFlight.ease(0) == 0)
    #expect(BeeFlight.ease(1) == 1)
    #expect(BeeFlight.ease(0.5) == 0.5)
    var last = 0.0
    for step in 1...20 {
        let value = BeeFlight.ease(Double(step) / 20)
        #expect(value >= last)
        last = value
    }
}
