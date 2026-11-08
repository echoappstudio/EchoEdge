import Foundation

/// How quickly the launcher shows and hides.
public struct RevealTiming: Equatable, Sendable {
    /// Pause at a real screen edge before showing.
    public var showDelay: TimeInterval
    /// Pause at an edge another display touches; longer, so crossing between displays doesn't
    /// pop the launcher open.
    public var sharedEdgeShowDelay: TimeInterval
    /// Wait after the pointer leaves before hiding.
    public var hideDelay: TimeInterval

    public init(showDelay: TimeInterval, sharedEdgeShowDelay: TimeInterval, hideDelay: TimeInterval) {
        self.showDelay = max(0, showDelay)
        self.sharedEdgeShowDelay = max(0, sharedEdgeShowDelay)
        self.hideDelay = max(0, hideDelay)
    }

    /// The shortest pause used on an edge another display touches.
    public static let minimumSharedEdgeDelay: TimeInterval = 0.3

    public init(settings: EdgeSettings) {
        self.init(
            showDelay: settings.showDelay,
            sharedEdgeShowDelay: max(settings.showDelay, Self.minimumSharedEdgeDelay),
            hideDelay: settings.hideDelay
        )
    }
}

/// Decides when the launcher shows and hides, from where the pointer is and when.
///
/// Feed it every pointer sample with `update`; when `nextDeadline` isn't nil, call `update`
/// again at that time even if the pointer hasn't moved.
public struct RevealMachine: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case hidden
        /// The pointer reached the edge at `since` and must stay for the show delay.
        case arming(since: TimeInterval, shared: Bool)
        case shown
        /// The pointer left at `since`; hide after the hide delay unless it comes back.
        case leaving(since: TimeInterval)
    }

    public private(set) var phase: Phase = .hidden

    public init() {}

    public var isShown: Bool {
        switch phase {
        case .shown, .leaving: true
        case .hidden, .arming: false
        }
    }

    /// - Parameters:
    ///   - contact: whether the pointer is at the launcher's edge.
    ///   - inKeepAliveArea: whether the pointer is over the launcher or close to it.
    ///   - isHeld: something needs the launcher to stay (a menu is open, a drag is over it).
    /// - Returns: whether the launcher should be visible now.
    @discardableResult
    public mutating func update(
        contact: EdgeGeometry.Contact,
        inKeepAliveArea: Bool,
        isHeld: Bool,
        now: TimeInterval,
        timing: RevealTiming
    ) -> Bool {
        let atEdge = contact != .away
        switch phase {
        case .hidden:
            if isHeld {
                phase = .shown
            } else if atEdge {
                let shared = contact == .sharedEdge
                phase = .arming(since: now, shared: shared)
                if delay(shared: shared, timing) <= 0 { phase = .shown }
            }
        case let .arming(since, shared):
            if isHeld {
                phase = .shown
            } else if !atEdge {
                phase = .hidden
            } else {
                // Sliding from a shared part of the edge onto a wall keeps the time already waited.
                let nowShared = shared && contact == .sharedEdge
                if hasElapsed(since: since, delay: delay(shared: nowShared, timing), now: now) {
                    phase = .shown
                } else {
                    phase = .arming(since: since, shared: nowShared)
                }
            }
        case .shown:
            if !(isHeld || inKeepAliveArea || atEdge) {
                phase = timing.hideDelay <= 0 ? .hidden : .leaving(since: now)
            }
        case let .leaving(since):
            if isHeld || inKeepAliveArea || atEdge {
                phase = .shown
            } else if hasElapsed(since: since, delay: timing.hideDelay, now: now) {
                phase = .hidden
            }
        }
        return isShown
    }

    /// When the decision may change without the pointer moving.
    public func nextDeadline(timing: RevealTiming) -> TimeInterval? {
        switch phase {
        case let .arming(since, shared): since + delay(shared: shared, timing)
        case let .leaving(since): since + timing.hideDelay
        case .hidden, .shown: nil
        }
    }

    /// Shows the launcher straight away (for "Show Now" in Settings).
    public mutating func show() {
        phase = .shown
    }

    /// Hides the launcher straight away (it's turned off, or its display went away).
    public mutating func hide() {
        phase = .hidden
    }

    /// A timer set for a deadline can fire a hair early in floating point; that still counts.
    private func hasElapsed(since: TimeInterval, delay: TimeInterval, now: TimeInterval) -> Bool {
        now + 0.001 >= since + delay
    }

    private func delay(shared: Bool, _ timing: RevealTiming) -> TimeInterval {
        shared ? timing.sharedEdgeShowDelay : timing.showDelay
    }
}
