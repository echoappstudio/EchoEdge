import Foundation
import XCTest
@testable import EchoEdgeCore

final class AppleDockTests: XCTestCase {
    private func tile(_ id: String?, _ url: String?, type: Int? = 15, label: String? = nil, tileType: String = "file-tile") -> [String: Any] {
        var fileData: [String: Any] = [:]
        if let url { fileData["_CFURLString"] = url }
        if let type { fileData["_CFURLStringType"] = type }
        var data: [String: Any] = ["file-data": fileData]
        if let id { data["bundle-identifier"] = id }
        if let label { data["file-label"] = label }
        return ["tile-type": tileType, "tile-data": data]
    }

    func testReadsPinnedAppsInOrderAndSkipsSpacers() {
        let value: [Any] = [
            tile("com.apple.Safari", "file:///Applications/Safari.app/", label: "Safari"),
            ["tile-type": "spacer-tile", "tile-data": [String: Any]()] as [String: Any],
            tile("com.apple.mail", "file:///System/Applications/Mail.app/"),
            tile(nil, "/Applications/My%20Tool.app", type: 0, label: "My Tool"),
            tile("com.example.space", "file:///Applications/Space%20Cadet.app/"),
            ["tile-type": "file-tile"],
            "not a tile"
        ]
        let tiles = AppleDockPreferences.pinnedApps(from: value)
        XCTAssertEqual(tiles, [
            DockTile(bundleIdentifier: "com.apple.Safari", path: "/Applications/Safari.app", label: "Safari"),
            DockTile(bundleIdentifier: "com.apple.mail", path: "/System/Applications/Mail.app", label: nil),
            // A plain path (type 0) is taken as written.
            DockTile(bundleIdentifier: nil, path: "/Applications/My%20Tool.app", label: "My Tool"),
            DockTile(bundleIdentifier: "com.example.space", path: "/Applications/Space Cadet.app", label: nil)
        ])
    }

    func testMissingOrOddPreferencesGiveNothing() {
        XCTAssertEqual(AppleDockPreferences.pinnedApps(from: nil), [])
        XCTAssertEqual(AppleDockPreferences.pinnedApps(from: "x"), [])
        XCTAssertNil(AppleDockPreferences.filePath(from: ["_CFURLString": "https://example.com/", "_CFURLStringType": 15]))
        XCTAssertNil(AppleDockPreferences.filePath(from: nil))
    }

    func testOrientation() {
        XCTAssertEqual(AppleDockPreferences.edge(fromOrientation: "left"), .left)
        XCTAssertEqual(AppleDockPreferences.edge(fromOrientation: "Right"), .right)
        XCTAssertEqual(AppleDockPreferences.edge(fromOrientation: nil), .bottom)
        XCTAssertEqual(AppleDockPreferences.edge(fromOrientation: "top"), .bottom)
    }

    private func running(_ id: String?, _ path: String?, _ name: String, pid: Int32, active: Bool = false) -> RunningAppInfo {
        RunningAppInfo(bundleIdentifier: id, path: path, name: name, processID: pid, isActive: active, isHidden: false)
    }

    func testBuildsTheListLikeTheDock() {
        let pinned = [
            DockTile(bundleIdentifier: "com.apple.Safari", path: "/Applications/Safari.app", label: "Safari"),
            DockTile(bundleIdentifier: "com.apple.mail", path: "/System/Applications/Mail.app", label: nil),
            // Finder pinned again, and EchoEdge itself, never appear twice or at all.
            DockTile(bundleIdentifier: "com.apple.finder", path: nil, label: "Finder"),
            DockTile(bundleIdentifier: "com.echoapps.echoedge", path: "/Applications/EchoEdge.app", label: "EchoEdge")
        ]
        let apps = [
            running("com.apple.finder", "/System/Library/CoreServices/Finder.app", "Finder", pid: 1),
            running("com.apple.Safari", "/Applications/Safari.app", "Safari", pid: 2, active: true),
            running("com.example.Notes", "/Applications/Notes Plus.app", "Notes Plus", pid: 3),
            running("com.echoapps.echoedge", "/Applications/EchoEdge.app", "EchoEdge", pid: 4),
            // Matched by its path though the bundle ID differs in case.
            running("COM.APPLE.MAIL", "/System/Applications/Mail.app", "Mail", pid: 5)
        ]
        let items = LauncherItemBuilder.build(pinned: pinned, running: apps, showRunningApps: true, ownBundleIdentifier: "com.echoapps.echoedge")
        XCTAssertEqual(items.map(\.name), ["Finder", "Safari", "Mail", "", "Notes Plus"])
        XCTAssertEqual(items.map(\.kind), [.app, .app, .app, .divider, .app])
        XCTAssertEqual(items.map(\.processID), [1, 2, 5, nil, 3])
        XCTAssertEqual(items.map(\.isPinned), [true, true, true, false, false])
        XCTAssertEqual(items[1].processID, 2)
        XCTAssertEqual(items[2].name, "Mail")
    }

    func testRunningAppsCanBeLeftOut() {
        let apps = [running("com.example.Notes", "/Applications/Notes Plus.app", "Notes Plus", pid: 3)]
        let items = LauncherItemBuilder.build(pinned: [], running: apps, showRunningApps: false, ownBundleIdentifier: nil)
        XCTAssertEqual(items.map(\.name), ["Finder"])
        XCTAssertFalse(items[0].isRunning)
    }

    func testNoDividerWithoutExtraApps() {
        let pinned = [DockTile(bundleIdentifier: "com.apple.Safari", path: "/Applications/Safari.app", label: nil)]
        let apps = [running("com.apple.Safari", "/Applications/Safari.app", "Safari", pid: 2)]
        let items = LauncherItemBuilder.build(pinned: pinned, running: apps, showRunningApps: true, ownBundleIdentifier: nil)
        XCTAssertEqual(items.map(\.name), ["Finder", "Safari"])
    }

    func testNamesComeFromTheApp() {
        XCTAssertEqual(LauncherItemBuilder.displayName(path: "/Applications/Safari.app"), "Safari")
        XCTAssertEqual(LauncherItemBuilder.displayName(path: "/Applications/Tool"), "Tool")
        XCTAssertNil(LauncherItemBuilder.displayName(path: nil))
    }
}
