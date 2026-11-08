import AppKit
import EchoEdgeCore

/// The launcher's content: a Liquid Glass bar holding the icons, which slides in from its edge.
/// The slide happens inside the window, so the launcher never crosses onto a neighbouring display.
final class LauncherView: NSView {
    weak var controller: LauncherController?

    private let slideHost = NSView()
    private let glass = NSGlassEffectView()
    private let itemsHost = NSView()
    private var itemViews: [NSView] = []
    private var lastEdge: ScreenEdge?
    private var lastIconSize: CGFloat?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        slideHost.wantsLayer = true
        addSubview(slideHost)
        glass.style = .regular
        glass.contentView = itemsHost
        slideHost.addSubview(glass)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("EchoEdge")
    }

    convenience init() {
        self.init(frame: NSRect(x: 0, y: 0, width: 200, height: 64))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func update(items: [LauncherItem], layout: LauncherLayout, edge: ScreenEdge) {
        let size = layout.frame.size
        setFrameSize(size)
        slideHost.frame = NSRect(origin: .zero, size: size)
        glass.frame = slideHost.bounds
        glass.cornerRadius = (layout.iconSize * 0.3 + 8).rounded()
        itemsHost.frame = glass.bounds

        // Views for unchanged apps are kept, so the one under the pointer keeps its highlight.
        var reusable: [String: ItemView] = [:]
        if lastEdge == edge && lastIconSize == layout.iconSize {
            for case let view as ItemView in itemViews {
                reusable[view.item.id] = view
            }
        }
        lastEdge = edge
        lastIconSize = layout.iconSize
        var kept: Set<ObjectIdentifier> = []
        var newViews: [NSView] = []

        let icon = layout.iconSize
        let thickness = LauncherLayout.thickness(iconSize: icon)
        let padding = LauncherLayout.padding
        let spacing = LauncherLayout.spacing
        var offset = padding
        for item in items {
            let slot = item.kind == .app ? icon : LauncherLayout.dividerLength
            let slotRect: NSRect
            switch edge {
            case .bottom:
                slotRect = NSRect(x: offset, y: 0, width: slot, height: thickness)
            case .left, .right:
                slotRect = NSRect(x: 0, y: size.height - offset - slot, width: thickness, height: slot)
            }
            offset += slot + spacing
            // Stop at the end of a launcher too short for everything (only with very many apps).
            guard slotRect.minX >= 0, slotRect.maxX <= size.width + 0.5,
                  slotRect.minY >= -0.5, slotRect.maxY <= size.height + 0.5 else { break }

            let view: NSView
            if item.kind == .app {
                let half = spacing / 2
                let frame = edge == .bottom
                    ? slotRect.insetBy(dx: -half, dy: 0)
                    : slotRect.insetBy(dx: 0, dy: -half)
                if let existing = reusable[item.id], existing.item == item {
                    existing.frame = frame
                    view = existing
                } else {
                    let itemView = ItemView(item: item, edge: edge, iconSize: icon, frame: frame)
                    itemView.controller = controller
                    view = itemView
                }
            } else {
                view = DividerView(edge: edge, frame: slotRect)
            }
            if view.superview == nil {
                itemsHost.addSubview(view)
            }
            kept.insert(ObjectIdentifier(view))
            newViews.append(view)
        }
        for view in itemViews where !kept.contains(ObjectIdentifier(view)) {
            view.removeFromSuperview()
        }
        itemViews = newViews
    }

    // MARK: Sliding

    private func hiddenFrame(edge: ScreenEdge, slides: Bool) -> NSRect {
        guard slides else { return bounds }
        switch edge {
        case .bottom: return bounds.offsetBy(dx: 0, dy: -bounds.height * 0.6)
        case .left: return bounds.offsetBy(dx: -bounds.width * 0.6, dy: 0)
        case .right: return bounds.offsetBy(dx: bounds.width * 0.6, dy: 0)
        }
    }

    func prepareSlideIn(edge: ScreenEdge, slides: Bool) {
        slideHost.frame = hiddenFrame(edge: edge, slides: slides)
    }

    func slideIn(animated: Bool) {
        if animated {
            slideHost.animator().frame = bounds
        } else {
            slideHost.frame = bounds
        }
    }

    func slideOut(edge: ScreenEdge, slides: Bool) {
        slideHost.animator().frame = hiddenFrame(edge: edge, slides: slides)
    }

    // MARK: Empty space

    override func rightMouseDown(with event: NSEvent) {
        controller?.showMenu(for: nil, event: event, in: self)
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) {
            controller?.showMenu(for: nil, event: event, in: self)
        }
    }
}

/// One app in the launcher: its icon, a dot when it's running, a highlight under the pointer.
final class ItemView: NSView {
    let item: LauncherItem
    weak var controller: LauncherController?

    private let edge: ScreenEdge
    private let iconSize: CGFloat
    private let icon: NSImage
    private var isHovered = false
    private var isPressed = false
    private var isDropTarget = false

    init(item: LauncherItem, edge: ScreenEdge, iconSize: CGFloat, frame: NSRect) {
        self.item = item
        self.edge = edge
        self.iconSize = iconSize
        self.icon = IconCache.icon(for: item)
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(item.isRunning ? "\(item.name), open" : item.name)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    /// Where the icon is drawn, in this view's coordinates.
    var iconRect: NSRect {
        let padding = LauncherLayout.padding
        let half = LauncherLayout.spacing / 2
        switch edge {
        case .bottom: return NSRect(x: half, y: padding, width: iconSize, height: iconSize)
        case .left, .right: return NSRect(x: padding, y: half, width: iconSize, height: iconSize)
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = iconRect
        if isHovered || isDropTarget {
            let highlight = NSBezierPath(roundedRect: rect.insetBy(dx: -3, dy: -3), xRadius: iconSize * 0.24, yRadius: iconSize * 0.24)
            NSColor.white.withAlphaComponent(isDropTarget ? 0.32 : 0.16).setFill()
            highlight.fill()
        }
        icon.draw(in: rect, from: .zero, operation: .sourceOver, fraction: isPressed ? 0.6 : 1, respectFlipped: true, hints: nil)

        if item.isRunning {
            let padding = LauncherLayout.padding
            let center: NSPoint
            switch edge {
            case .bottom: center = NSPoint(x: rect.midX, y: padding / 2)
            case .left: center = NSPoint(x: padding / 2, y: rect.midY)
            case .right: center = NSPoint(x: bounds.maxX - padding / 2, y: rect.midY)
            }
            let radius: CGFloat = 2
            NSColor.labelColor.withAlphaComponent(0.85).setFill()
            NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)).fill()
        }
    }

    // MARK: Mouse

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        needsDisplay = true
        controller?.hoverChanged(to: self)
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        isPressed = false
        needsDisplay = true
        controller?.hoverChanged(to: nil)
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) {
            controller?.showMenu(for: item, event: event, in: self)
            return
        }
        isPressed = true
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let wasPressed = isPressed
        isPressed = false
        needsDisplay = true
        guard wasPressed, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        controller?.itemClicked(item, modifiers: event.modifierFlags)
    }

    override func rightMouseDown(with event: NSEvent) {
        controller?.showMenu(for: item, event: event, in: self)
    }

    override func accessibilityPerformPress() -> Bool {
        controller?.itemClicked(item, modifiers: [])
        return true
    }

    // MARK: Dropping files

    private func fileURLs(_ info: any NSDraggingInfo) -> [URL] {
        let objects = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
        return (objects as? [URL]) ?? []
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard !fileURLs(sender).isEmpty else { return [] }
        isDropTarget = true
        needsDisplay = true
        controller?.dragHoverChanged(true)
        controller?.hoverChanged(to: self)
        return .copy
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        isDropTarget ? .copy : []
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        endDrop()
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let urls = fileURLs(sender)
        guard !urls.isEmpty else { return false }
        controller?.filesDropped(urls, on: item)
        return true
    }

    override func concludeDragOperation(_ sender: (any NSDraggingInfo)?) {
        endDrop()
    }

    private func endDrop() {
        guard isDropTarget else { return }
        isDropTarget = false
        needsDisplay = true
        controller?.hoverChanged(to: nil)
        controller?.dragHoverChanged(false)
    }
}

/// The line between pinned apps and other open apps.
final class DividerView: NSView {
    private let edge: ScreenEdge

    init(edge: ScreenEdge, frame: NSRect) {
        self.edge = edge
        super.init(frame: frame)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func draw(_ dirtyRect: NSRect) {
        let inset = LauncherLayout.padding + 4
        let line: NSRect
        switch edge {
        case .bottom:
            line = NSRect(x: bounds.midX - 0.5, y: inset, width: 1, height: bounds.height - 2 * inset)
        case .left, .right:
            line = NSRect(x: inset, y: bounds.midY - 0.5, width: bounds.width - 2 * inset, height: 1)
        }
        NSColor.labelColor.withAlphaComponent(0.3).setFill()
        line.fill()
    }
}

/// App icons, loaded once.
@MainActor
enum IconCache {
    private static var icons: [String: NSImage] = [:]

    static func icon(for item: LauncherItem) -> NSImage {
        if let cached = icons[item.id] { return cached }
        var path = item.path.flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil }
        if path == nil, let bundleIdentifier = item.bundleIdentifier {
            path = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)?.path
        }
        let image: NSImage
        if let path {
            image = NSWorkspace.shared.icon(forFile: path)
        } else {
            image = NSImage(systemSymbolName: "app.dashed", accessibilityDescription: item.name) ?? NSImage()
        }
        icons[item.id] = image
        return image
    }
}

/// The app's name beside the icon under the pointer.
@MainActor
final class NameBubble {
    private let panel: NSPanel
    private let background = NSView()
    private let label = NSTextField(labelWithString: "")

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 24),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.canHide = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]

        background.wantsLayer = true
        background.layer?.backgroundColor = NSColor(white: 0.12, alpha: 0.9).cgColor
        background.layer?.cornerRadius = 7
        background.layer?.borderColor = NSColor(white: 1, alpha: 0.18).cgColor
        background.layer?.borderWidth = 0.5
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .white
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        background.addSubview(label)
        panel.contentView = background
    }

    func show(_ text: String, beside rect: NSRect, edge: ScreenEdge, level: NSWindow.Level) {
        label.stringValue = text
        let textSize = label.fittingSize
        let width = min(textSize.width, 360) + 20
        let height = textSize.height + 8
        label.frame = NSRect(x: 10, y: 4, width: width - 20, height: textSize.height)
        let gap = LauncherLayout.padding + 8
        var origin: NSPoint
        switch edge {
        case .bottom: origin = NSPoint(x: rect.midX - width / 2, y: rect.maxY + gap)
        case .left: origin = NSPoint(x: rect.maxX + gap, y: rect.midY - height / 2)
        case .right: origin = NSPoint(x: rect.minX - gap - width, y: rect.midY - height / 2)
        }
        if let screen = NSScreen.screens.first(where: { $0.frame.intersects(rect) }) {
            let limits = screen.frame.insetBy(dx: 4, dy: 4)
            origin.x = min(max(origin.x, limits.minX), limits.maxX - width)
            origin.y = min(max(origin.y, limits.minY), limits.maxY - height)
        }
        panel.level = NSWindow.Level(rawValue: level.rawValue + 1)
        panel.setFrame(NSRect(origin: origin, size: NSSize(width: width, height: height)), display: true)
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
    }
}
