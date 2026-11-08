import AppKit
import ApplicationServices
import EchoEdgeCore
import Observation

/// Pointer moves anywhere on screen. Watching the pointer needs no permission (only watching
/// keystrokes would).
@MainActor
final class PointerMonitor {
    var onMove: ((CGPoint, Int) -> Void)?
    private var globalMonitor: Any?
    private var localMonitor: Any?

    private static let events: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]

    func start() {
        guard globalMonitor == nil else { return }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: Self.events) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.sample()
            }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: Self.events) { [weak self] event in
            MainActor.assumeIsolated {
                self?.sample()
            }
            return event
        }
    }

    func stop() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
    }

    private func sample() {
        onMove?(NSEvent.mouseLocation, NSEvent.pressedMouseButtons)
    }
}

/// The connected displays, kept up to date as displays come and go or are rearranged.
@MainActor
final class DisplayMonitor {
    var onChange: (() -> Void)?
    private(set) var displays: [DisplayInfo] = []
    private var observers: [NSObjectProtocol] = []
    private var settleTimer: Timer?

    func start() {
        displays = Self.read()
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleRead() }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleRead() }
        })
    }

    /// Plugging in a display sends a burst of changes; read once they settle.
    private func scheduleRead() {
        settleTimer?.invalidate()
        settleTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.readNow()
            }
        }
    }

    private func readNow() {
        let current = Self.read()
        guard current != displays else { return }
        displays = current
        onChange?()
    }

    static func read() -> [DisplayInfo] {
        let screens = NSScreen.screens
        let mainScreen = screens.first
        return screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return nil
            }
            let displayID = CGDirectDisplayID(number.uint32Value)
            // A display mirroring another isn't a place of its own.
            if CGDisplayMirrorsDisplay(displayID) != 0 { return nil }
            return DisplayInfo(
                id: stableID(for: displayID),
                name: screen.localizedName,
                frame: screen.frame,
                visibleFrame: screen.visibleFrame,
                isMain: screen == mainScreen
            )
        }
    }

    /// The display's UUID survives restarts and replugging, unlike its number.
    private static func stableID(for displayID: CGDirectDisplayID) -> String {
        if let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue(),
           let string = CFUUIDCreateString(nil, uuid) as String? {
            return string
        }
        return "display-\(displayID)"
    }
}

/// Apple's Dock: its pinned apps and which edge it's on. Reading another app's settings needs no
/// permission. Apple's Dock announces changes; a slow check catches any it doesn't.
@MainActor
final class AppleDockReader {
    var onChange: (() -> Void)?
    private(set) var pinned: [DockTile] = []
    private(set) var edge: ScreenEdge = .bottom
    private(set) var autohides = false
    private var observer: NSObjectProtocol?
    private var timer: Timer?

    func start() {
        reload(notify: false)
        observer = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(AppleDockPreferences.changedNotification),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.reload(notify: true)
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.reload(notify: true)
            }
        }
        timer?.tolerance = 1
    }

    private func reload(notify: Bool) {
        let domain = AppleDockPreferences.domain as CFString
        CFPreferencesAppSynchronize(domain)
        let newPinned = AppleDockPreferences.pinnedApps(
            from: CFPreferencesCopyAppValue(AppleDockPreferences.pinnedAppsKey as CFString, domain)
        )
        let newEdge = AppleDockPreferences.edge(
            fromOrientation: CFPreferencesCopyAppValue(AppleDockPreferences.orientationKey as CFString, domain)
        )
        let newAutohides = (CFPreferencesCopyAppValue(AppleDockPreferences.autohideKey as CFString, domain) as? Bool) ?? false
        guard newPinned != pinned || newEdge != edge || newAutohides != autohides else { return }
        pinned = newPinned
        edge = newEdge
        autohides = newAutohides
        if notify { onChange?() }
    }
}

/// The apps that are open, as Apple's Dock shows them (ordinary apps, not background helpers).
@MainActor
final class RunningAppsMonitor {
    var onChange: (() -> Void)?
    private(set) var running: [RunningAppInfo] = []
    private var observers: [NSObjectProtocol] = []

    func start() {
        refresh()
        let center = NSWorkspace.shared.notificationCenter
        let names: [Notification.Name] = [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
            NSWorkspace.didActivateApplicationNotification,
            NSWorkspace.didHideApplicationNotification,
            NSWorkspace.didUnhideApplicationNotification
        ]
        for name in names {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.refresh()
                    self?.onChange?()
                }
            })
        }
    }

    private func refresh() {
        running = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && !$0.isTerminated }
            .map { app in
                RunningAppInfo(
                    bundleIdentifier: app.bundleIdentifier,
                    path: app.bundleURL?.path,
                    name: app.localizedName ?? app.bundleURL?.deletingPathExtension().lastPathComponent ?? "App",
                    processID: app.processIdentifier,
                    isActive: app.isActive,
                    isHidden: app.isHidden
                )
            }
    }
}

/// Whether macOS lets EchoEdge use Accessibility (for the window list, minimizing and keeping
/// Apple's Dock away).
@MainActor
@Observable
final class AccessibilityAccess {
    private(set) var isTrusted = AXIsProcessTrusted()
    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private var timer: Timer?

    private static let askedKey = "EchoEdge.askedForAccessibility"

    /// Checks every 2 seconds until allowed (so turning it on takes effect at once), then rarely.
    func startWatching() {
        scheduleCheck()
    }

    private func scheduleCheck() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: isTrusted ? 30 : 2, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refresh()
                self?.scheduleCheck()
            }
        }
    }

    func refresh() {
        let trusted = AXIsProcessTrusted()
        guard trusted != isTrusted else { return }
        isTrusted = trusted
        onChange?()
        scheduleCheck()
    }

    /// Shows macOS's own "allow Accessibility" prompt.
    func request() {
        // The option's name as text: the imported constant is a global variable Swift 6 rejects.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        UserDefaults.standard.set(true, forKey: Self.askedKey)
        refresh()
    }

    /// Asks at first launch only; later, Settings has the button.
    func requestOnce() {
        guard !isTrusted, !UserDefaults.standard.bool(forKey: Self.askedKey) else { return }
        request()
    }

    func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// Keeps Apple's Dock from moving onto EchoEdge's display (see `AppleDockGuard`).
///
/// A session event tap (it needs Accessibility) holds back pointer moves right at EchoEdge's edge
/// of its own display, so Apple's Dock never sees the pointer push there. EchoEdge still gets
/// those moves, so its own launcher shows as usual. Clicks and keys are never touched.
@MainActor
final class AppleDockGuardTap {
    var onHeldBackPointer: (@MainActor @Sendable (CGPoint) -> Void)? {
        didSet {
            let forward = onHeldBackPointer
            state.setForward { point in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        forward?(point)
                    }
                }
            }
        }
    }

    private(set) var isRunning = false
    private let state = GuardState()

    func configure(display: DisplayInfo, edge: ScreenEdge, displays: [DisplayInfo]) {
        state.setArea(GuardState.Area(display: display, edge: edge, displays: displays))
    }

    /// The tap runs on its own thread, so a busy main thread can never hold up the pointer.
    func start() {
        guard !isRunning else { return }
        isRunning = true
        let state = self.state
        let generation = state.begin()
        let thread = Thread {
            let mask = (CGEventMask(1) << CGEventType.mouseMoved.rawValue)
                | (CGEventMask(1) << CGEventType.leftMouseDragged.rawValue)
                | (CGEventMask(1) << CGEventType.rightMouseDragged.rawValue)
                | (CGEventMask(1) << CGEventType.otherMouseDragged.rawValue)
            guard let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: mask,
                callback: { _, type, event, userInfo in
                    guard let userInfo else { return Unmanaged.passUnretained(event) }
                    let state = Unmanaged<GuardState>.fromOpaque(userInfo).takeUnretainedValue()
                    return state.handle(type: type, event: event)
                },
                userInfo: Unmanaged.passUnretained(state).toOpaque()
            ) else {
                return
            }
            guard let loop = CFRunLoopGetCurrent() else {
                CFMachPortInvalidate(tap)
                return
            }
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            CFRunLoopAddSource(loop, source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            if state.attach(tap: tap, loop: loop, generation: generation) {
                // Wakes every few seconds only to notice a stop that raced the start.
                while state.isCurrent(generation) {
                    _ = CFRunLoopRunInMode(CFRunLoopMode.defaultMode, 5, false)
                }
            }
            CGEvent.tapEnable(tap: tap, enable: false)
            CFRunLoopRemoveSource(loop, source, .commonModes)
            CFMachPortInvalidate(tap)
        }
        thread.name = "EchoEdge Dock guard"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        state.end()
    }
}

/// What the event tap reads on every pointer move; locked, because the tap's callback isn't
/// known to the compiler to run on the main thread.
final class GuardState: @unchecked Sendable {
    struct Area {
        let display: DisplayInfo
        let edge: ScreenEdge
        let displays: [DisplayInfo]
    }

    private let lock = NSLock()
    private var area: Area?
    private var tap: CFMachPort?
    private var loop: CFRunLoop?
    private var generation = 0
    private var forward: (@Sendable (CGPoint) -> Void)?

    func setArea(_ area: Area?) {
        lock.lock(); defer { lock.unlock() }
        self.area = area
    }

    func setForward(_ forward: (@Sendable (CGPoint) -> Void)?) {
        lock.lock(); defer { lock.unlock() }
        self.forward = forward
    }

    /// Starts a new run of the tap thread; an older thread sees it's no longer current and ends.
    func begin() -> Int {
        lock.lock(); defer { lock.unlock() }
        generation += 1
        return generation
    }

    /// The tap thread reports its tap and run loop; false if it was stopped in the meantime.
    func attach(tap: CFMachPort, loop: CFRunLoop, generation: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard generation == self.generation else { return false }
        self.tap = tap
        self.loop = loop
        return true
    }

    func isCurrent(_ generation: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return generation == self.generation
    }

    func end() {
        lock.lock()
        generation += 1
        let loop = self.loop
        tap = nil
        self.loop = nil
        lock.unlock()
        if let loop { CFRunLoopStop(loop) }
    }

    func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        lock.lock()
        let area = self.area
        let tap = self.tap
        let forward = self.forward
        lock.unlock()

        // macOS turns a slow tap off; turn it straight back on.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        // Same coordinates as AppKit: origin at the bottom left of the main display.
        let point = event.unflippedLocation
        guard let area,
              AppleDockGuard.shouldHoldBack(point, launcherDisplay: area.display, edge: area.edge, among: area.displays) else {
            return Unmanaged.passUnretained(event)
        }
        forward?(point)
        return nil
    }
}
