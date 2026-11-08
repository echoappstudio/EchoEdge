import Foundation
import XCTest
@testable import EchoEdgeCore

final class SettingsTests: XCTestCase {
    func testRoundTrips() throws {
        var settings = EdgeSettings()
        settings.displayID = "ABC"
        settings.displayName = "LG HDR 4K"
        settings.edge = .right
        settings.iconSize = 60
        settings.keepAppleDockAway = false
        let decoded = try XCTUnwrap(EdgeSettings.decode(settings.encoded()))
        XCTAssertEqual(decoded, settings)
    }

    func testOlderOrPartialSettingsLoadWithDefaults() throws {
        let decoded = try XCTUnwrap(EdgeSettings.decode(Data(#"{"displayID":"ABC","edge":"left"}"#.utf8)))
        var expected = EdgeSettings()
        expected.displayID = "ABC"
        expected.edge = .left
        XCTAssertEqual(decoded, expected)
        XCTAssertEqual(EdgeSettings.decode(Data("{}".utf8)), EdgeSettings())
    }

    func testUnknownEdgeAndOutOfRangeNumbersAreRepaired() throws {
        let decoded = try XCTUnwrap(EdgeSettings.decode(Data(#"{"edge":"top","iconSize":500,"showDelay":-2,"hideDelay":9}"#.utf8)))
        XCTAssertEqual(decoded.edge, .bottom)
        XCTAssertEqual(decoded.iconSize, 96)
        XCTAssertEqual(decoded.showDelay, 0)
        XCTAssertEqual(decoded.hideDelay, 3)
    }

    func testBrokenSettingsGiveNil() {
        XCTAssertNil(EdgeSettings.decode(Data("not json".utf8)))
        XCTAssertNil(EdgeSettings.decode(nil))
    }

    func testFirstLaunchPrefersAnExtraDisplay() {
        let settings = EdgeSettings.firstLaunch(displays: Fixture.all, appleDockEdge: .bottom)
        XCTAssertEqual(settings.displayID, "external")
        XCTAssertEqual(settings.edge, .bottom)
    }

    func testFirstLaunchOnOneDisplayAvoidsAppleDocksEdge() {
        let bottomDock = EdgeSettings.firstLaunch(displays: [Fixture.laptop], appleDockEdge: .bottom)
        XCTAssertEqual(bottomDock.displayID, "laptop")
        XCTAssertEqual(bottomDock.edge, .left)
        let leftDock = EdgeSettings.firstLaunch(displays: [Fixture.laptop], appleDockEdge: .left)
        XCTAssertEqual(leftDock.edge, .bottom)
    }

    func testChosenDisplayIsFoundOrWaitedFor() {
        var settings = EdgeSettings()
        settings.displayID = "upper"
        XCTAssertEqual(DisplayChoice.display(for: settings, in: Fixture.all)?.id, "upper")
        XCTAssertNil(DisplayChoice.display(for: settings, in: [Fixture.laptop]))
        XCTAssertNil(DisplayChoice.display(for: EdgeSettings(), in: Fixture.all))
    }

    func testDisplayLabelsNumberTwins() {
        let labels = DisplayChoice.labels(for: Fixture.all)
        XCTAssertEqual(labels["laptop"], "Built-in Retina Display · menu bar")
        XCTAssertEqual(labels["external"], "LG HDR 4K (1)")
        XCTAssertEqual(labels["upper"], "LG HDR 4K (2)")
    }

    /// The shipped Info.plist turns on hourly checks, automatic installs and signed feeds.
    func testInfoPlistConfiguresUpdates() throws {
        let plistURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/Info.plist")
        let data = try Data(contentsOf: plistURL)
        let info = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])

        XCTAssertEqual(info["CFBundleIdentifier"] as? String, "com.echoapps.echoedge")
        XCTAssertEqual(info["LSUIElement"] as? Bool, true)
        XCTAssertEqual(info["SUFeedURL"] as? String, "https://github.com/echoappstudio/EchoEdge/releases/latest/download/appcast.xml")
        XCTAssertEqual(info["SUEnableAutomaticChecks"] as? Bool, true)
        XCTAssertEqual(info["SUAutomaticallyUpdate"] as? Bool, true)
        XCTAssertEqual(info["SUScheduledCheckInterval"] as? Int, 3600)
        XCTAssertEqual(info["SURequireSignedFeed"] as? Bool, true)
        XCTAssertEqual(info["SUVerifyUpdateBeforeExtraction"] as? Bool, true)
        XCTAssertNil(info["SUAllowsAutomaticUpdates"])
        let publicKey = try XCTUnwrap(info["SUPublicEDKey"] as? String)
        XCTAssertEqual(Data(base64Encoded: publicKey)?.count, 32, "SUPublicEDKey must be a base64 Ed25519 public key")
        let build = try XCTUnwrap(info["CFBundleVersion"] as? String)
        XCTAssertNotNil(Int(build), "Sparkle compares builds; EchoEdge keeps them whole numbers")
    }
}
