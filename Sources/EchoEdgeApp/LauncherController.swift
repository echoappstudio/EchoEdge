import AppKit
import EchoEdgeCore

struct LauncherConfiguration: Equatable {
    var display: DisplayInfo?
    var displays: [DisplayInfo]
    var edge: ScreenEdge
    var iconSize: CGFloat
    var timing: RevealTiming
    var showOverFullScreenApps: Bool
    var isEnabled: Bool
}

/// Shows the launcher when the pointer reaches its edge and hides it when the pointer leaves.
@MainActor
final class LauncherController: NSObject, NSMenuDelegate {
    var onOpen: ((LauncherItem, NSEvent.ModifierFlags) -> Void)?
    var onDropFiles: ((LauncherItem, [URL]) -> Void)?
    var makeMenu: ((LauncherItem?) -> NSMenu)?

    /// Whether the launcher is on screen (or sliding in).
    private(set) var isShown = false

    private let panel = LauncherPanel()
    private let launcherView = LauncherView()
    private let nameBubble = NameBubble()
    private var configuration: LauncherConfiguration?
    private var items: [LauncherItem] = []
    private var layout: LauncherLayout?
    private var machine = RevealMachine()
    private var deadlineTimer: Timer?
    private var isMenuOpen = false
    private var isDragOver = false
    private var previewUntil: TimeInterval = 0

    override init() {
        super.init()
        panel.contentView = launcherView
        launcherView.controller = self
    }

    // MARK: Configuration

    func configure(_ configuration: LauncherConfiguration) {
        guard configuration != self.configuration else { return }
        self.configuration = configuration
        panel.setShowsOverFullScreenApps(configuration.showOverFullScreenApps)
        relayout()
        if !configuration.isEnabled || configuration.display == nil {
            machine.hide()
            setVisible(false)
        }
        reevaluate()
    }

    func setItems(_ items: [LauncherItem]) {
        self.items = items
        relayout()
        // The bar may have shrunk away from the pointer.
        if isShown { reevaluate() }
    }

    private func relayout() {
        guard let configuration, let display = configuration.display else {
            layout = nil
            return
        }
        let appCount = items.filter { $0.kind == .app }.count
        let dividerCount = items.count - appCount
        let layout = LauncherLayout.make(
            display: display,
            edge: configuration.edge,
            preferredIconSize: configuration.iconSize,
            items: appCount,
            dividers: dividerCount
        )
        let moved = self.layout?.frame != layout.frame
        self.layout = layout
        if moved {
            panel.setFrame(layout.frame, display: isShown)
            nameBubble.hide()
        }
        launcherView.update(items: items, layout: layout, edge: configuration.edge)
    }

    // MARK: Showing and hiding

    /// Shows the launcher for a few seconds, e.g. while the user changes Settings.
    func preview(seconds: TimeInterval) {
        previewUntil = ProcessInfo.processInfo.systemUptime + seconds
        reevaluate()
    }

    /// Every pointer move, from the event monitors or from the Apple's Dock guard.
    func pointerMoved(to point: CGPoint, pressedButtons: Int) {
        guard let configuration, configuration.isEnabled,
              let display = configuration.display, let layout else {
            if isShown { setVisible(false) }
            machine.hide()
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        let contact = EdgeGeometry.contact(of: point, display: display, edge: configuration.edge, among: configuration.displays)
        let nearby = LauncherLayout.keepAliveArea(for: layout.frame, edge: configuration.edge).contains(point)
        let isHeld = isMenuOpen || isDragOver || now < previewUntil
        let show = machine.update(
            contact: contact,
            inKeepAliveArea: nearby,
            isHeld: isHeld,
            now: now,
            timing: configuration.timing
        )
        setVisible(show)
        scheduleNextCheck(now: now)
    }

    private func reevaluate() {
        pointerMoved(to: NSEvent.mouseLocation, pressedButtons: NSEvent.pressedMouseButtons)
    }

    private func scheduleNextCheck(now: TimeInterval) {
        deadlineTimer?.invalidate()
        deadlineTimer = nil
        var next = configuration.flatMap { machine.nextDeadline(timing: $0.timing) }
        if previewUntil > now {
            next = min(next ?? previewUntil, previewUntil)
        }
        guard let next else { return }
        let timer = Timer(timeInterval: max(0.01, next - now), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.reevaluate()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        deadlineTimer = timer
    }

    private func setVisible(_ visible: Bool) {
        guard visible != isShown else { return }
        isShown = visible
        guard let configuration else { return }
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if visible {
            panel.alphaValue = 0
            launcherView.prepareSlideIn(edge: configuration.edge, slides: !reduceMotion)
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = reduceMotion ? 0.12 : 0.18
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1
                launcherView.slideIn(animated: true)
            }
        } else {
            nameBubble.hide()
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = reduceMotion ? 0.12 : 0.16
                context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                panel.animator().alphaValue = 0
                launcherView.slideOut(edge: configuration.edge, slides: !reduceMotion)
            }, completionHandler: { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, !self.isShown else { return }
                    self.panel.orderOut(nil)
                }
            })
        }
    }

    // MARK: From the launcher's views

    func itemClicked(_ item: LauncherItem, modifiers: NSEvent.ModifierFlags) {
        nameBubble.hide()
        onOpen?(item, modifiers)
    }

    func filesDropped(_ urls: [URL], on item: LauncherItem) {
        onDropFiles?(item, urls)
    }

    func showMenu(for item: LauncherItem?, event: NSEvent, in view: NSView) {
        guard let menu = makeMenu?(item) else { return }
        nameBubble.hide()
        menu.delegate = self
        NSMenu.popUpContextMenu(menu, with: event, for: view)
    }

    func hoverChanged(to view: ItemView?) {
        guard let view, let configuration, isShown, let window = view.window else {
            nameBubble.hide()
            return
        }
        let iconRect = window.convertToScreen(view.convert(view.iconRect, to: nil))
        nameBubble.show(view.item.name, beside: iconRect, edge: configuration.edge, level: panel.level)
    }

    func dragHoverChanged(_ isOver: Bool) {
        isDragOver = isOver
        if !isOver { reevaluate() }
    }

    func menuWillOpen(_ menu: NSMenu) {
        isMenuOpen = true
    }

    func menuDidClose(_ menu: NSMenu) {
        isMenuOpen = false
        reevaluate()
    }
}

/// The launcher's window: never takes focus, on every Space of its display.
final class LauncherPanel: NSPanel {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 64),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        isFloatingPanel = true
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)))
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovable = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        // Hiding EchoEdge (⌘H, or another app's Hide Others) must never hide the launcher.
        canHide = false
        setShowsOverFullScreenApps(true)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func setShowsOverFullScreenApps(_ shows: Bool) {
        var behavior: NSWindow.CollectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        if shows {
            behavior.insert(.fullScreenAuxiliary)
        }
        collectionBehavior = behavior
    }
}
