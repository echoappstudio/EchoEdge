import Foundation

/// One app pinned in Apple's Dock.
public struct DockTile: Equatable, Sendable {
    public let bundleIdentifier: String?
    /// The app's path, e.g. `/Applications/Safari.app`.
    public let path: String?
    public let label: String?

    public init(bundleIdentifier: String?, path: String?, label: String?) {
        self.bundleIdentifier = bundleIdentifier
        self.path = path
        self.label = label
    }
}

/// Reads Apple's Dock settings (the `com.apple.dock` preferences), which any app may read.
public enum AppleDockPreferences {
    public static let domain = "com.apple.dock"
    public static let pinnedAppsKey = "persistent-apps"
    public static let orientationKey = "orientation"
    public static let autohideKey = "autohide"
    /// Apple's Dock posts this when its settings change.
    public static let changedNotification = "com.apple.dock.prefchanged"

    private static let spacerTypes: Set<String> = ["spacer-tile", "small-spacer-tile", "flex-spacer-tile"]

    /// The pinned apps, in the Dock's order. Spacers and anything unreadable are skipped.
    public static func pinnedApps(from value: Any?) -> [DockTile] {
        guard let entries = value as? [Any] else { return [] }
        var tiles: [DockTile] = []
        for case let entry as [String: Any] in entries {
            if let type = entry["tile-type"] as? String, spacerTypes.contains(type) { continue }
            guard let data = entry["tile-data"] as? [String: Any] else { continue }
            let bundleIdentifier = nonEmpty(data["bundle-identifier"])
            let path = filePath(from: data["file-data"])
            guard bundleIdentifier != nil || path != nil else { continue }
            tiles.append(DockTile(bundleIdentifier: bundleIdentifier, path: path, label: nonEmpty(data["file-label"])))
        }
        return tiles
    }

    /// A tile's file location: a `file://` URL (type 15) or a plain path (type 0, written by scripts).
    public static func filePath(from value: Any?) -> String? {
        guard let fileData = value as? [String: Any], let raw = nonEmpty(fileData["_CFURLString"]) else {
            return nil
        }
        let type = (fileData["_CFURLStringType"] as? Int) ?? (raw.hasPrefix("/") ? 0 : 15)
        var path: String
        if type == 0 || raw.hasPrefix("/") {
            path = raw
        } else {
            guard let url = URL(string: raw), url.isFileURL else { return nil }
            path = url.path
        }
        while path.count > 1 && path.hasSuffix("/") {
            path.removeLast()
        }
        return path.isEmpty ? nil : path
    }

    /// Which edge Apple's Dock is on; it's at the bottom unless set otherwise.
    public static func edge(fromOrientation value: Any?) -> ScreenEdge {
        guard let raw = (value as? String)?.trimmingCharacters(in: .whitespaces).lowercased(),
              let edge = ScreenEdge(rawValue: raw) else { return .bottom }
        return edge
    }

    private static func nonEmpty(_ value: Any?) -> String? {
        guard let string = value as? String, !string.isEmpty else { return nil }
        return string
    }
}

/// An app that's running right now.
public struct RunningAppInfo: Equatable, Sendable {
    public let bundleIdentifier: String?
    public let path: String?
    public let name: String
    public let processID: Int32
    public let isActive: Bool
    public let isHidden: Bool

    public init(bundleIdentifier: String?, path: String?, name: String, processID: Int32, isActive: Bool, isHidden: Bool) {
        self.bundleIdentifier = bundleIdentifier
        self.path = path
        self.name = name
        self.processID = processID
        self.isActive = isActive
        self.isHidden = isHidden
    }
}

/// One thing shown in the launcher.
public struct LauncherItem: Equatable, Sendable, Identifiable {
    public enum Kind: Equatable, Sendable {
        case app
        /// The line between pinned apps and other running apps.
        case divider
    }

    public let id: String
    public let kind: Kind
    public let name: String
    public let bundleIdentifier: String?
    public let path: String?
    public let isPinned: Bool
    /// The running copy, if the app is open.
    public let processID: Int32?
    public let isHidden: Bool

    public var isRunning: Bool { processID != nil }

    public init(
        id: String,
        kind: Kind,
        name: String,
        bundleIdentifier: String?,
        path: String?,
        isPinned: Bool,
        processID: Int32?,
        isHidden: Bool
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.path = path
        self.isPinned = isPinned
        self.processID = processID
        self.isHidden = isHidden
    }

    public static let divider = LauncherItem(
        id: "divider", kind: .divider, name: "", bundleIdentifier: nil, path: nil,
        isPinned: false, processID: nil, isHidden: false
    )
}

/// Builds the launcher's list the way Apple's Dock shows it: Finder, the pinned apps in order, then
/// the other running apps after a divider.
public enum LauncherItemBuilder {
    public static let finderBundleIdentifier = "com.apple.finder"
    public static let finderPath = "/System/Library/CoreServices/Finder.app"

    public static func build(
        pinned: [DockTile],
        running: [RunningAppInfo],
        showRunningApps: Bool,
        ownBundleIdentifier: String?
    ) -> [LauncherItem] {
        var items: [LauncherItem] = []
        var usedKeys: Set<String> = []
        var matchedProcesses: Set<Int32> = []

        func add(bundleIdentifier: String?, path: String?, fallbackName: String?, pinned: Bool) {
            let keys = matchKeys(bundleIdentifier: bundleIdentifier, path: path)
            guard !keys.isEmpty, usedKeys.isDisjoint(with: keys) else { return }
            if let own = ownBundleIdentifier, keys.contains(bundleKey(own)) { return }
            let process = running.first { app in
                !matchKeys(bundleIdentifier: app.bundleIdentifier, path: app.path).isDisjoint(with: keys)
            }
            usedKeys.formUnion(keys)
            if let process { matchedProcesses.insert(process.processID) }
            let name = fallbackName ?? process?.name ?? displayName(path: path) ?? bundleIdentifier ?? "App"
            items.append(LauncherItem(
                id: keys.sorted().first ?? name,
                kind: .app,
                name: name,
                bundleIdentifier: bundleIdentifier ?? process?.bundleIdentifier,
                path: path ?? process?.path,
                isPinned: pinned,
                processID: process?.processID,
                isHidden: process?.isHidden ?? false
            ))
        }

        add(bundleIdentifier: finderBundleIdentifier, path: finderPath, fallbackName: "Finder", pinned: true)
        for tile in pinned {
            add(bundleIdentifier: tile.bundleIdentifier, path: tile.path, fallbackName: tile.label, pinned: true)
        }

        guard showRunningApps else { return items }
        let pinnedCount = items.count
        for app in running where !matchedProcesses.contains(app.processID) {
            add(bundleIdentifier: app.bundleIdentifier, path: app.path, fallbackName: app.name, pinned: false)
        }
        if items.count > pinnedCount {
            items.insert(.divider, at: pinnedCount)
        }
        return items
    }

    /// "Safari" from "/Applications/Safari.app".
    public static func displayName(path: String?) -> String? {
        guard let path, !path.isEmpty else { return nil }
        var name = (path as NSString).lastPathComponent
        if name.lowercased().hasSuffix(".app") {
            name = String(name.dropLast(4))
        }
        return name.isEmpty ? nil : name
    }

    static func matchKeys(bundleIdentifier: String?, path: String?) -> Set<String> {
        var keys: Set<String> = []
        if let bundleIdentifier, !bundleIdentifier.isEmpty {
            keys.insert(bundleKey(bundleIdentifier))
        }
        if let path, !path.isEmpty {
            var normalized = (path as NSString).standardizingPath
            while normalized.count > 1 && normalized.hasSuffix("/") {
                normalized.removeLast()
            }
            keys.insert("path:" + normalized.lowercased())
        }
        return keys
    }

    static func bundleKey(_ identifier: String) -> String {
        "id:" + identifier.lowercased()
    }
}
