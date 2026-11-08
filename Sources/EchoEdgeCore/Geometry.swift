import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// The edge of a display that EchoEdge (or Apple's Dock) sits on.
public enum ScreenEdge: String, Codable, CaseIterable, Sendable {
    case left
    case bottom
    case right

    public var title: String {
        switch self {
        case .left: "Left"
        case .bottom: "Bottom"
        case .right: "Right"
        }
    }

    /// Left and right launchers run top to bottom; a bottom launcher runs left to right.
    public var runsVertically: Bool { self != .bottom }
}

/// One connected display, in AppKit's global coordinates (origin at the bottom left of the
/// main display, y going up).
public struct DisplayInfo: Equatable, Sendable {
    /// A stable identifier that survives unplugging and restarting (the display's UUID).
    public let id: String
    public let name: String
    public let frame: CGRect
    /// The frame without the menu bar and Apple's Dock.
    public let visibleFrame: CGRect
    /// The display with the menu bar.
    public let isMain: Bool

    public init(id: String, name: String, frame: CGRect, visibleFrame: CGRect, isMain: Bool) {
        self.id = id
        self.name = name
        self.frame = frame
        self.visibleFrame = visibleFrame
        self.isMain = isMain
    }
}

/// Pure geometry for a launcher on one edge of one display.
public enum EdgeGeometry {
    /// Displays closer than this are treated as touching.
    public static let touchTolerance: CGFloat = 1.5
    /// How close to an edge the pointer must be when the edge is a real wall.
    public static let exposedDepth: CGFloat = 2
    /// On an edge another display touches, the pointer passes through instead of stopping, so the
    /// zone is a little deeper there (and needs a short pause, see `RevealMachine`).
    public static let sharedDepth: CGFloat = 8
    /// The very corners are left alone for hot corners.
    public static let cornerInset: CGFloat = 8

    /// The edge's extent, as an interval along the edge (x for the bottom edge, y for the sides).
    public static func span(of display: DisplayInfo, edge: ScreenEdge) -> ClosedRange<CGFloat> {
        switch edge {
        case .bottom: return display.frame.minX...display.frame.maxX
        case .left, .right: return display.frame.minY...display.frame.maxY
        }
    }

    /// The position of `point` along `edge`.
    public static func along(_ point: CGPoint, edge: ScreenEdge) -> CGFloat {
        edge == .bottom ? point.x : point.y
    }

    /// How far `point` is from `edge` of `display`, inwards.
    public static func distance(from point: CGPoint, to edge: ScreenEdge, of display: DisplayInfo) -> CGFloat {
        switch edge {
        case .bottom: return point.y - display.frame.minY
        case .left: return point.x - display.frame.minX
        case .right: return display.frame.maxX - point.x
        }
    }

    /// Whether `point` is on `display`. AppKit puts a display's pointer positions at
    /// minX ≤ x < maxX and minY < y ≤ maxY (the bottom row reads minY + 1), so a point on the very
    /// first row or column of a neighbouring display never counts as this display's edge.
    public static func isOnDisplay(_ point: CGPoint, _ display: DisplayInfo) -> Bool {
        let frame = display.frame
        return frame.width > 0 && frame.height > 0
            && point.x >= frame.minX && point.x < frame.maxX
            && point.y > frame.minY && point.y <= frame.maxY
    }

    /// Whether `position` along the edge is clear of the corners (kept free for hot corners).
    public static func isClearOfCorners(_ position: CGFloat, span: ClosedRange<CGFloat>) -> Bool {
        position >= span.lowerBound + cornerInset && position <= span.upperBound - cornerInset
    }

    /// The parts of `edge` that another display touches, where the pointer can cross over.
    public static func sharedIntervals(
        of display: DisplayInfo,
        edge: ScreenEdge,
        among displays: [DisplayInfo]
    ) -> [ClosedRange<CGFloat>] {
        var intervals: [ClosedRange<CGFloat>] = []
        for other in displays where other.id != display.id {
            let touches: Bool
            let lower: CGFloat
            let upper: CGFloat
            switch edge {
            case .bottom:
                touches = abs(other.frame.maxY - display.frame.minY) <= touchTolerance
                lower = max(other.frame.minX, display.frame.minX)
                upper = min(other.frame.maxX, display.frame.maxX)
            case .left:
                touches = abs(other.frame.maxX - display.frame.minX) <= touchTolerance
                lower = max(other.frame.minY, display.frame.minY)
                upper = min(other.frame.maxY, display.frame.maxY)
            case .right:
                touches = abs(other.frame.minX - display.frame.maxX) <= touchTolerance
                lower = max(other.frame.minY, display.frame.minY)
                upper = min(other.frame.maxY, display.frame.maxY)
            }
            if touches && upper > lower {
                intervals.append(lower...upper)
            }
        }
        return intervals.sorted { $0.lowerBound < $1.lowerBound }
    }

    /// Whether any part of `edge` touches another display.
    public static func hasSharedPart(
        _ display: DisplayInfo,
        edge: ScreenEdge,
        among displays: [DisplayInfo]
    ) -> Bool {
        !sharedIntervals(of: display, edge: edge, among: displays).isEmpty
    }

    /// Where the pointer is relative to a launcher's edge.
    public enum Contact: Equatable, Sendable {
        case away
        /// At a real wall: the pointer stops here.
        case exposedEdge
        /// At a part another display touches: the pointer may just be passing through.
        case sharedEdge
    }

    public static func contact(
        of point: CGPoint,
        display: DisplayInfo,
        edge: ScreenEdge,
        among displays: [DisplayInfo]
    ) -> Contact {
        guard isOnDisplay(point, display) else { return .away }
        let position = along(point, edge: edge)
        guard isClearOfCorners(position, span: span(of: display, edge: edge)) else { return .away }
        let shared = sharedIntervals(of: display, edge: edge, among: displays)
            .contains { $0.contains(position) }
        let depth = shared ? sharedDepth : exposedDepth
        guard distance(from: point, to: edge, of: display) <= depth else { return .away }
        return shared ? .sharedEdge : .exposedEdge
    }
}

/// The launcher's size and place on its display.
public struct LauncherLayout: Equatable, Sendable {
    public let iconSize: CGFloat
    public let frame: CGRect
    /// All items fit at `iconSize`; false only when even the smallest icons are too many.
    public let fits: Bool

    public init(iconSize: CGFloat, frame: CGRect, fits: Bool) {
        self.iconSize = iconSize
        self.frame = frame
        self.fits = fits
    }

    /// Margin around icons inside the launcher; the running dot sits in it on the edge side.
    public static let padding: CGFloat = 8
    /// Space between icons.
    public static let spacing: CGFloat = 6
    /// Length of the divider before running apps.
    public static let dividerLength: CGFloat = 9
    /// Gap between the launcher and the screen edge.
    public static let edgeGap: CGFloat = 4
    /// Space kept free at both ends of the edge.
    public static let endMargin: CGFloat = 8
    public static let minimumIconSize: CGFloat = 24

    /// The launcher's length along its edge for these items.
    public static func length(iconSize: CGFloat, items: Int, dividers: Int) -> CGFloat {
        let slots = items + dividers
        let gaps = CGFloat(max(0, slots - 1)) * spacing
        return 2 * padding + CGFloat(items) * iconSize + CGFloat(dividers) * dividerLength + gaps
    }

    public static func thickness(iconSize: CGFloat) -> CGFloat {
        iconSize + 2 * padding
    }

    /// Lays the launcher out centred on `edge` of `display`, shrinking icons when they don't fit.
    public static func make(
        display: DisplayInfo,
        edge: ScreenEdge,
        preferredIconSize: CGFloat,
        items: Int,
        dividers: Int
    ) -> LauncherLayout {
        let available: CGFloat
        switch edge {
        case .bottom: available = display.frame.width - 2 * endMargin
        case .left, .right: available = display.visibleFrame.height - 2 * endMargin
        }
        var iconSize = max(minimumIconSize, preferredIconSize)
        var fits = true
        if items > 0, length(iconSize: iconSize, items: items, dividers: dividers) > available {
            let fixed = length(iconSize: 0, items: items, dividers: dividers)
            let shrunk = ((available - fixed) / CGFloat(items)).rounded(.down)
            iconSize = max(minimumIconSize, shrunk)
            fits = length(iconSize: iconSize, items: items, dividers: dividers) <= available
        }
        let along = min(length(iconSize: iconSize, items: items, dividers: dividers), max(available, 0))
        let across = thickness(iconSize: iconSize)
        let frame: CGRect
        switch edge {
        case .bottom:
            frame = CGRect(
                x: (display.frame.midX - along / 2).rounded(),
                y: display.frame.minY + edgeGap,
                width: along,
                height: across
            )
        case .left:
            frame = CGRect(
                x: display.frame.minX + edgeGap,
                y: (display.visibleFrame.midY - along / 2).rounded(),
                width: across,
                height: along
            )
        case .right:
            frame = CGRect(
                x: display.frame.maxX - edgeGap - across,
                y: (display.visibleFrame.midY - along / 2).rounded(),
                width: across,
                height: along
            )
        }
        return LauncherLayout(iconSize: iconSize, frame: frame, fits: fits)
    }

    /// The area the pointer can wander in without the launcher hiding: the launcher plus a margin,
    /// stretched to the screen edge so the gap between them counts too.
    public static func keepAliveArea(for frame: CGRect, edge: ScreenEdge, margin: CGFloat = 24) -> CGRect {
        var area = frame.insetBy(dx: -margin, dy: -margin)
        switch edge {
        case .bottom:
            area.origin.y -= edgeGap
            area.size.height += edgeGap
        case .left:
            area.origin.x -= edgeGap
            area.size.width += edgeGap
        case .right:
            area.size.width += edgeGap
        }
        return area
    }
}
