import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Everything the user can set, saved as JSON in EchoEdge's preferences.
///
/// Every field is decoded with a default, so settings saved by an older version always load.
public struct EdgeSettings: Codable, Equatable, Sendable {
    /// The chosen display's UUID; nil until the first launch picks one.
    public var displayID: String?
    /// The chosen display's name, shown while it isn't connected.
    public var displayName: String?
    public var edge: ScreenEdge
    public var iconSize: Double
    public var showDelay: TimeInterval
    public var hideDelay: TimeInterval
    public var showRunningApps: Bool
    public var minimizeFrontAppOnClick: Bool
    public var showOverFullScreenApps: Bool
    public var keepAppleDockAway: Bool
    /// Turns the launcher off without quitting.
    public var isEnabled: Bool

    public static let iconSizeRange: ClosedRange<Double> = 32...96
    public static let showDelayRange: ClosedRange<TimeInterval> = 0...1
    public static let hideDelayRange: ClosedRange<TimeInterval> = 0...3

    public init(
        displayID: String? = nil,
        displayName: String? = nil,
        edge: ScreenEdge = .bottom,
        iconSize: Double = 48,
        showDelay: TimeInterval = 0.05,
        hideDelay: TimeInterval = 0.5,
        showRunningApps: Bool = true,
        minimizeFrontAppOnClick: Bool = true,
        showOverFullScreenApps: Bool = true,
        keepAppleDockAway: Bool = true,
        isEnabled: Bool = true
    ) {
        self.displayID = displayID
        self.displayName = displayName
        self.edge = edge
        self.iconSize = iconSize
        self.showDelay = showDelay
        self.hideDelay = hideDelay
        self.showRunningApps = showRunningApps
        self.minimizeFrontAppOnClick = minimizeFrontAppOnClick
        self.showOverFullScreenApps = showOverFullScreenApps
        self.keepAppleDockAway = keepAppleDockAway
        self.isEnabled = isEnabled
    }

    private enum CodingKeys: String, CodingKey {
        case displayID, displayName, edge, iconSize, showDelay, hideDelay, showRunningApps
        case minimizeFrontAppOnClick, showOverFullScreenApps, keepAppleDockAway, isEnabled
    }

    public init(from decoder: Decoder) throws {
        let defaults = EdgeSettings()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        displayID = try container.decodeIfPresent(String.self, forKey: .displayID)
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
        // An edge from a newer version that this one doesn't know falls back to the default.
        let rawEdge = try container.decodeIfPresent(String.self, forKey: .edge)
        edge = rawEdge.flatMap(ScreenEdge.init(rawValue:)) ?? defaults.edge
        iconSize = try container.decodeIfPresent(Double.self, forKey: .iconSize) ?? defaults.iconSize
        showDelay = try container.decodeIfPresent(TimeInterval.self, forKey: .showDelay) ?? defaults.showDelay
        hideDelay = try container.decodeIfPresent(TimeInterval.self, forKey: .hideDelay) ?? defaults.hideDelay
        showRunningApps = try container.decodeIfPresent(Bool.self, forKey: .showRunningApps) ?? defaults.showRunningApps
        minimizeFrontAppOnClick = try container.decodeIfPresent(Bool.self, forKey: .minimizeFrontAppOnClick) ?? defaults.minimizeFrontAppOnClick
        showOverFullScreenApps = try container.decodeIfPresent(Bool.self, forKey: .showOverFullScreenApps) ?? defaults.showOverFullScreenApps
        keepAppleDockAway = try container.decodeIfPresent(Bool.self, forKey: .keepAppleDockAway) ?? defaults.keepAppleDockAway
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? defaults.isEnabled
        self = clamped()
    }

    /// The same settings with every number inside its allowed range.
    public func clamped() -> EdgeSettings {
        var copy = self
        copy.iconSize = Self.clamp(iconSize, to: Self.iconSizeRange, fallback: 48)
        copy.showDelay = Self.clamp(showDelay, to: Self.showDelayRange, fallback: 0.05)
        copy.hideDelay = Self.clamp(hideDelay, to: Self.hideDelayRange, fallback: 0.5)
        return copy
    }

    private static func clamp(_ value: Double, to range: ClosedRange<Double>, fallback: Double) -> Double {
        guard value.isFinite else { return fallback }
        return min(max(value, range.lowerBound), range.upperBound)
    }

    /// The first launch's choice: an extra display if there is one (Apple's Dock usually stays on
    /// the main one), on the bottom edge, unless that's where Apple's Dock is on the only display.
    public static func firstLaunch(displays: [DisplayInfo], appleDockEdge: ScreenEdge) -> EdgeSettings {
        var settings = EdgeSettings()
        let display = displays.first { !$0.isMain } ?? displays.first
        settings.displayID = display?.id
        settings.displayName = display?.name
        if displays.count <= 1 && appleDockEdge == .bottom {
            settings.edge = .left
        }
        return settings
    }

    /// Reads saved settings, falling back to nil (not a crash) when they can't be read.
    public static func decode(_ data: Data?) -> EdgeSettings? {
        guard let data else { return nil }
        return try? JSONDecoder().decode(EdgeSettings.self, from: data)
    }

    public func encoded() -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(self)
    }
}

/// Keeps Apple's Dock from moving onto EchoEdge's display.
///
/// Apple's Dock moves to whichever display the pointer pushes against at the Dock's edge. When
/// EchoEdge uses that same edge, EchoEdge holds back pointer moves right at that edge of its own
/// display from the rest of the system (it still sees them itself), so Apple's Dock stays where it
/// is. The parts of the edge another display touches stay untouched, so the pointer still crosses.
public enum AppleDockGuard {
    /// How close to the edge pointer moves are held back.
    public static let depth: CGFloat = 3

    /// Whether the guard has anything to do: the two docks share an edge, and there's another
    /// display for Apple's Dock to live on.
    public static func isNeeded(
        launcherEdge: ScreenEdge,
        appleDockEdge: ScreenEdge,
        displayCount: Int
    ) -> Bool {
        displayCount > 1 && launcherEdge == appleDockEdge
    }

    public static func shouldHoldBack(
        _ point: CGPoint,
        launcherDisplay: DisplayInfo,
        edge: ScreenEdge,
        among displays: [DisplayInfo]
    ) -> Bool {
        guard EdgeGeometry.isOnDisplay(point, launcherDisplay),
              EdgeGeometry.distance(from: point, to: edge, of: launcherDisplay) <= depth else {
            return false
        }
        let position = EdgeGeometry.along(point, edge: edge)
        // Hot corners belong to Apple's Dock; leave them working.
        guard EdgeGeometry.isClearOfCorners(position, span: EdgeGeometry.span(of: launcherDisplay, edge: edge)) else {
            return false
        }
        return !EdgeGeometry.sharedIntervals(of: launcherDisplay, edge: edge, among: displays)
            .contains { $0.contains(position) }
    }
}

/// Picks the display the launcher goes on.
public enum DisplayChoice {
    /// The saved display if it's connected; nil while it isn't (the launcher waits for it rather
    /// than jumping onto a display the user didn't choose).
    public static func display(for settings: EdgeSettings, in displays: [DisplayInfo]) -> DisplayInfo? {
        guard let id = settings.displayID else { return nil }
        return displays.first { $0.id == id }
    }

    /// Names for a list of displays, numbering identical names ("LG HDR 4K (2)").
    public static func labels(for displays: [DisplayInfo]) -> [String: String] {
        var counts: [String: Int] = [:]
        for display in displays { counts[display.name, default: 0] += 1 }
        var seen: [String: Int] = [:]
        var labels: [String: String] = [:]
        for display in displays {
            var label = display.name
            if counts[display.name, default: 0] > 1 {
                seen[display.name, default: 0] += 1
                label += " (\(seen[display.name, default: 0]))"
            }
            if display.isMain {
                label += " · menu bar"
            }
            labels[display.id] = label
        }
        return labels
    }
}
