import Foundation
import XCTest
@testable import EchoEdgeCore

final class RevealMachineTests: XCTestCase {
    private let timing = RevealTiming(showDelay: 0.1, sharedEdgeShowDelay: 0.3, hideDelay: 0.5)

    func testShowsAfterAPauseAtAWall() {
        var machine = RevealMachine()
        XCTAssertFalse(machine.update(contact: .exposedEdge, inKeepAliveArea: false, isHeld: false, now: 10, timing: timing))
        XCTAssertEqual(machine.nextDeadline(timing: timing), 10.1)
        XCTAssertFalse(machine.update(contact: .exposedEdge, inKeepAliveArea: false, isHeld: false, now: 10.05, timing: timing))
        XCTAssertTrue(machine.update(contact: .exposedEdge, inKeepAliveArea: false, isHeld: false, now: 10.1, timing: timing))
        XCTAssertNil(machine.nextDeadline(timing: timing))
    }

    func testPassingThroughASharedEdgeDoesNotShow() {
        var machine = RevealMachine()
        machine.update(contact: .sharedEdge, inKeepAliveArea: false, isHeld: false, now: 0, timing: timing)
        XCTAssertEqual(machine.nextDeadline(timing: timing), 0.3)
        // The pointer crossed onto the next display before the pause was up.
        XCTAssertFalse(machine.update(contact: .away, inKeepAliveArea: false, isHeld: false, now: 0.2, timing: timing))
        XCTAssertEqual(machine.phase, .hidden)
    }

    func testPausingAtASharedEdgeShows() {
        var machine = RevealMachine()
        machine.update(contact: .sharedEdge, inKeepAliveArea: false, isHeld: false, now: 0, timing: timing)
        XCTAssertFalse(machine.update(contact: .sharedEdge, inKeepAliveArea: false, isHeld: false, now: 0.29, timing: timing))
        XCTAssertTrue(machine.update(contact: .sharedEdge, inKeepAliveArea: false, isHeld: false, now: 0.3, timing: timing))
    }

    func testSlidingFromSharedOntoAWallUsesTheShorterPause() {
        var machine = RevealMachine()
        machine.update(contact: .sharedEdge, inKeepAliveArea: false, isHeld: false, now: 0, timing: timing)
        XCTAssertTrue(machine.update(contact: .exposedEdge, inKeepAliveArea: false, isHeld: false, now: 0.12, timing: timing))
    }

    func testZeroDelayShowsAtOnce() {
        var machine = RevealMachine()
        let instant = RevealTiming(showDelay: 0, sharedEdgeShowDelay: 0.3, hideDelay: 0)
        XCTAssertTrue(machine.update(contact: .exposedEdge, inKeepAliveArea: false, isHeld: false, now: 0, timing: instant))
        XCTAssertFalse(machine.update(contact: .away, inKeepAliveArea: false, isHeld: false, now: 0.01, timing: instant))
    }

    func testStaysWhileNearAndHidesAfterLeaving() {
        var machine = RevealMachine()
        machine.show()
        XCTAssertTrue(machine.update(contact: .away, inKeepAliveArea: true, isHeld: false, now: 1, timing: timing))
        XCTAssertTrue(machine.update(contact: .away, inKeepAliveArea: false, isHeld: false, now: 2, timing: timing))
        XCTAssertEqual(machine.phase, .leaving(since: 2))
        XCTAssertEqual(machine.nextDeadline(timing: timing), 2.5)
        XCTAssertTrue(machine.update(contact: .away, inKeepAliveArea: false, isHeld: false, now: 2.4, timing: timing))
        XCTAssertFalse(machine.update(contact: .away, inKeepAliveArea: false, isHeld: false, now: 2.5, timing: timing))
    }

    func testComingBackCancelsHiding() {
        var machine = RevealMachine()
        machine.show()
        machine.update(contact: .away, inKeepAliveArea: false, isHeld: false, now: 2, timing: timing)
        XCTAssertTrue(machine.update(contact: .away, inKeepAliveArea: true, isHeld: false, now: 2.3, timing: timing))
        XCTAssertEqual(machine.phase, .shown)
        XCTAssertTrue(machine.update(contact: .away, inKeepAliveArea: false, isHeld: false, now: 2.7, timing: timing))
        XCTAssertEqual(machine.phase, .leaving(since: 2.7))
    }

    func testAnOpenMenuKeepsItShown() {
        var machine = RevealMachine()
        machine.show()
        XCTAssertTrue(machine.update(contact: .away, inKeepAliveArea: false, isHeld: true, now: 5, timing: timing))
        XCTAssertTrue(machine.update(contact: .away, inKeepAliveArea: false, isHeld: true, now: 50, timing: timing))
        XCTAssertEqual(machine.phase, .shown)
    }

    func testTimingFromSettingsNeverMakesSharedEdgesQuicker() {
        var settings = EdgeSettings()
        settings.showDelay = 0
        XCTAssertEqual(RevealTiming(settings: settings).sharedEdgeShowDelay, RevealTiming.minimumSharedEdgeDelay)
        settings.showDelay = 0.8
        XCTAssertEqual(RevealTiming(settings: settings).sharedEdgeShowDelay, 0.8)
    }

    func testUpdatesWaitWhileTheLauncherIsOpen() {
        XCTAssertTrue(UpdateInstallPolicy.canInstallNow(isLauncherShown: false, waitedSeconds: 0))
        XCTAssertFalse(UpdateInstallPolicy.canInstallNow(isLauncherShown: true, waitedSeconds: 599))
        XCTAssertTrue(UpdateInstallPolicy.canInstallNow(isLauncherShown: true, waitedSeconds: 600))
    }
}
