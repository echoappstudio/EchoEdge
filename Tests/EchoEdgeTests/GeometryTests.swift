import Foundation
import XCTest
@testable import EchoEdgeCore

/// A laptop (main, menu bar) with an external display to its right, bottoms aligned, and a
/// third display stacked on top of the external one.
enum Fixture {
    static let laptop = DisplayInfo(
        id: "laptop", name: "Built-in Retina Display",
        frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
        visibleFrame: CGRect(x: 0, y: 70, width: 1512, height: 879),
        isMain: true
    )
    static let external = DisplayInfo(
        id: "external", name: "LG HDR 4K",
        frame: CGRect(x: 1512, y: 0, width: 2560, height: 1440),
        visibleFrame: CGRect(x: 1512, y: 0, width: 2560, height: 1415),
        isMain: false
    )
    static let upper = DisplayInfo(
        id: "upper", name: "LG HDR 4K",
        frame: CGRect(x: 1512, y: 1440, width: 2560, height: 1440),
        visibleFrame: CGRect(x: 1512, y: 1440, width: 2560, height: 1415),
        isMain: false
    )
    static let all = [laptop, external, upper]
}

final class GeometryTests: XCTestCase {
    func testSharedIntervalsFollowTheArrangement() {
        // The laptop's right edge touches the external display along the laptop's full height.
        XCTAssertEqual(
            EdgeGeometry.sharedIntervals(of: Fixture.laptop, edge: .right, among: Fixture.all),
            [0...982]
        )
        // The external display's left edge touches the laptop only along the laptop's height.
        XCTAssertEqual(
            EdgeGeometry.sharedIntervals(of: Fixture.external, edge: .left, among: Fixture.all),
            [0...982]
        )
        // The upper display sits on the external one: its bottom is shared all the way.
        XCTAssertEqual(
            EdgeGeometry.sharedIntervals(of: Fixture.upper, edge: .bottom, among: Fixture.all),
            [1512...4072]
        )
        XCTAssertTrue(EdgeGeometry.sharedIntervals(of: Fixture.external, edge: .bottom, among: Fixture.all).isEmpty)
        XCTAssertTrue(EdgeGeometry.sharedIntervals(of: Fixture.external, edge: .right, among: Fixture.all).isEmpty)
        XCTAssertTrue(EdgeGeometry.sharedIntervals(of: Fixture.laptop, edge: .left, among: Fixture.all).isEmpty)
    }

    func testContactAtARealWall() {
        let display = Fixture.external
        // AppKit reads the bottom row as minY + 1.
        XCTAssertEqual(EdgeGeometry.contact(of: CGPoint(x: 2800, y: 1), display: display, edge: .bottom, among: Fixture.all), .exposedEdge)
        XCTAssertEqual(EdgeGeometry.contact(of: CGPoint(x: 2800, y: 2), display: display, edge: .bottom, among: Fixture.all), .exposedEdge)
        XCTAssertEqual(EdgeGeometry.contact(of: CGPoint(x: 2800, y: 3), display: display, edge: .bottom, among: Fixture.all), .away)
        XCTAssertEqual(EdgeGeometry.contact(of: CGPoint(x: 4071, y: 700), display: display, edge: .right, among: Fixture.all), .exposedEdge)
        XCTAssertEqual(EdgeGeometry.contact(of: CGPoint(x: 4060, y: 700), display: display, edge: .right, among: Fixture.all), .away)
    }

    func testContactWhereAnotherDisplayTouches() {
        let display = Fixture.external
        // Below the laptop's top, the external display's left edge is shared: a deeper zone.
        XCTAssertEqual(EdgeGeometry.contact(of: CGPoint(x: 1519, y: 500), display: display, edge: .left, among: Fixture.all), .sharedEdge)
        XCTAssertEqual(EdgeGeometry.contact(of: CGPoint(x: 1521, y: 500), display: display, edge: .left, among: Fixture.all), .away)
        // Above it, the same edge is a real wall again.
        XCTAssertEqual(EdgeGeometry.contact(of: CGPoint(x: 1512, y: 1200), display: display, edge: .left, among: Fixture.all), .exposedEdge)
        XCTAssertEqual(EdgeGeometry.contact(of: CGPoint(x: 1519, y: 1200), display: display, edge: .left, among: Fixture.all), .away)
    }

    func testCornersAndOtherDisplaysAreIgnored() {
        let display = Fixture.external
        XCTAssertEqual(EdgeGeometry.contact(of: CGPoint(x: 1515, y: 1), display: display, edge: .bottom, among: Fixture.all), .away)
        XCTAssertEqual(EdgeGeometry.contact(of: CGPoint(x: 4070, y: 1), display: display, edge: .bottom, among: Fixture.all), .away)
        // A point on the laptop is never the external display's edge.
        XCTAssertEqual(EdgeGeometry.contact(of: CGPoint(x: 800, y: 1), display: display, edge: .bottom, among: Fixture.all), .away)
    }

    func testANeighboursFirstRowOrColumnIsNotThisEdge() {
        // x = 1512 is the external display's first column, not the laptop's right edge.
        XCTAssertEqual(EdgeGeometry.contact(of: CGPoint(x: 1512, y: 500), display: Fixture.laptop, edge: .right, among: Fixture.all), .away)
        XCTAssertEqual(EdgeGeometry.contact(of: CGPoint(x: 1511, y: 500), display: Fixture.laptop, edge: .right, among: Fixture.all), .sharedEdge)
        // y = 1440 is the external display's top row, not the upper display's bottom edge.
        XCTAssertEqual(EdgeGeometry.contact(of: CGPoint(x: 2800, y: 1440), display: Fixture.upper, edge: .bottom, among: Fixture.all), .away)
        XCTAssertEqual(EdgeGeometry.contact(of: CGPoint(x: 2800, y: 1441), display: Fixture.upper, edge: .bottom, among: Fixture.all), .sharedEdge)
        XCTAssertFalse(EdgeGeometry.isOnDisplay(CGPoint(x: 1512, y: 500), Fixture.laptop))
        XCTAssertTrue(EdgeGeometry.isOnDisplay(CGPoint(x: 1512, y: 500), Fixture.external))
    }

    func testBottomLayoutIsCentredAndSized() {
        let layout = LauncherLayout.make(display: Fixture.external, edge: .bottom, preferredIconSize: 48, items: 10, dividers: 1)
        // 2×8 padding + 10×48 icons + 9 divider + 10 gaps × 6 = 565
        XCTAssertEqual(layout.frame.width, 565)
        XCTAssertEqual(layout.frame.height, 64)
        XCTAssertEqual(layout.frame.minY, 4)
        XCTAssertEqual(layout.frame.midX, Fixture.external.frame.midX, accuracy: 1)
        XCTAssertEqual(layout.iconSize, 48)
        XCTAssertTrue(layout.fits)
    }

    func testSideLayoutsHugTheirEdgeBelowTheMenuBar() {
        let left = LauncherLayout.make(display: Fixture.external, edge: .left, preferredIconSize: 48, items: 5, dividers: 0)
        XCTAssertEqual(left.frame.minX, 1516)
        XCTAssertEqual(left.frame.width, 64)
        XCTAssertEqual(left.frame.height, LauncherLayout.length(iconSize: 48, items: 5, dividers: 0))
        XCTAssertEqual(left.frame.midY, Fixture.external.visibleFrame.midY, accuracy: 1)

        let right = LauncherLayout.make(display: Fixture.external, edge: .right, preferredIconSize: 48, items: 5, dividers: 0)
        XCTAssertEqual(right.frame.maxX, 4068)
    }

    func testIconsShrinkToFitAndStopAtTheMinimum() {
        // The laptop's side holds 879 − 16 = 863 points.
        let shrunk = LauncherLayout.make(display: Fixture.laptop, edge: .left, preferredIconSize: 64, items: 20, dividers: 1)
        // Fixed parts: 16 + 9 + 20 gaps × 6 = 145; (863 − 145) / 20 = 35.9 → 35.
        XCTAssertEqual(shrunk.iconSize, 35)
        XCTAssertTrue(shrunk.fits)
        XCTAssertLessThanOrEqual(shrunk.frame.height, 863)

        let tooMany = LauncherLayout.make(display: Fixture.laptop, edge: .left, preferredIconSize: 64, items: 60, dividers: 1)
        XCTAssertEqual(tooMany.iconSize, LauncherLayout.minimumIconSize)
        XCTAssertFalse(tooMany.fits)
        XCTAssertEqual(tooMany.frame.height, 863)
    }

    func testKeepAliveAreaReachesTheScreenEdge() {
        let frame = CGRect(x: 100, y: 4, width: 300, height: 64)
        let area = LauncherLayout.keepAliveArea(for: frame, edge: .bottom, margin: 24)
        XCTAssertEqual(area.minY, -24)
        XCTAssertEqual(area.maxY, 92)
        XCTAssertEqual(area.minX, 76)
        let right = LauncherLayout.keepAliveArea(for: CGRect(x: 1000, y: 100, width: 64, height: 300), edge: .right, margin: 24)
        XCTAssertEqual(right.maxX, 1092)
    }

    func testAppleDockGuardHoldsBackOnlyTheExposedEdge() {
        XCTAssertTrue(AppleDockGuard.isNeeded(launcherEdge: .bottom, appleDockEdge: .bottom, displayCount: 2))
        XCTAssertFalse(AppleDockGuard.isNeeded(launcherEdge: .left, appleDockEdge: .bottom, displayCount: 2))
        XCTAssertFalse(AppleDockGuard.isNeeded(launcherEdge: .bottom, appleDockEdge: .bottom, displayCount: 1))

        XCTAssertTrue(AppleDockGuard.shouldHoldBack(CGPoint(x: 2800, y: 1), launcherDisplay: Fixture.external, edge: .bottom, among: Fixture.all))
        XCTAssertFalse(AppleDockGuard.shouldHoldBack(CGPoint(x: 2800, y: 10), launcherDisplay: Fixture.external, edge: .bottom, among: Fixture.all))
        XCTAssertFalse(AppleDockGuard.shouldHoldBack(CGPoint(x: 800, y: 1), launcherDisplay: Fixture.external, edge: .bottom, among: Fixture.all))
        // The external display's left edge next to the laptop stays crossable.
        XCTAssertFalse(AppleDockGuard.shouldHoldBack(CGPoint(x: 1513, y: 500), launcherDisplay: Fixture.external, edge: .left, among: Fixture.all))
        XCTAssertTrue(AppleDockGuard.shouldHoldBack(CGPoint(x: 1513, y: 1200), launcherDisplay: Fixture.external, edge: .left, among: Fixture.all))
        // Hot corners stay with Apple's Dock.
        XCTAssertFalse(AppleDockGuard.shouldHoldBack(CGPoint(x: 1513, y: 1436), launcherDisplay: Fixture.external, edge: .left, among: Fixture.all))
        XCTAssertFalse(AppleDockGuard.shouldHoldBack(CGPoint(x: 4066, y: 1), launcherDisplay: Fixture.external, edge: .bottom, among: Fixture.all))
    }
}
