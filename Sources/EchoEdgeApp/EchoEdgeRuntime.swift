import AppKit
import EchoEdgeCore
import Observation
import ServiceManagement

/// Ties EchoEdge together: the saved settings, the displays, Apple's Dock, running apps, the
/// launcher, the Apple's Dock guard, updates and the Settings window.
@MainActor
@Observable
final class EchoEdgeRuntime: NSObject {
    private(set) var settings: EdgeSettings
    private(set) var displays: [DisplayInfo] = []
    private(set) var appleDockEdge: ScreenEdge = .bottom
    private(set) var appleDockAutohides = false
    private(set) var items: [LauncherItem] = []
    private(set) var opensAtLogin = false
    private(set) var loginItemMessage: String?

    let accessibility = AccessibilityAccess()
    @ObservationIgnored let updates = UpdateController()
    @ObservationIgnored private let launcher = LauncherController()
    @ObservationIgnored private let pointer = PointerMonitor()
    @ObservationIgnored private let dockGuard = AppleDockGuardTap()
    @ObservationIgnored private let displayMonitor = DisplayMonitor()
    @ObservationIgnored private let dockReader = AppleDockReader()
    @ObservationIgnored private let apps = RunningAppsMonitor()
    @ObservationIgnored private let actions = AppActions()
    @ObservationIgnored private var settingsWindow: SettingsWindowController?
    @ObservationIgnored private var isFirstLaunch = false

    private static let settingsKey = "EchoEdge.settings"

    override init() {
        let saved = EdgeSettings.decode(UserDefaults.standard.data(forKey: Self.settingsKey))
        settings = saved ?? EdgeSettings()
        isFirstLaunch = saved == nil
        super.init()
    }

    // MARK: Start and stop

    func start() {
        actions.runtime = self
        WindowAccess.limitWaiting()
        displayMonitor.onChange = { [weak self] in self?.displaysChanged() }
        displayMonitor.start()
        displays = displayMonitor.displays

        dockReader.onChange = { [weak self] in self?.appleDockChanged() }
        dockReader.start()
        appleDockEdge = dockReader.edge
        appleDockAutohides = dockReader.autohides

        apps.onChange = { [weak self] in self?.rebuildItems() }
        apps.start()

        if isFirstLaunch {
            settings = EdgeSettings.firstLaunch(displays: displays, appleDockEdge: appleDockEdge)
            save()
        }

        launcher.onOpen = { [weak self] item, modifiers in self?.actions.open(item, modifiers: modifiers) }
        launcher.onDropFiles = { [weak self] item, urls in self?.actions.open(urls, with: item) }
        launcher.makeMenu = { [weak self] item in self?.actions.menu(for: item) ?? NSMenu() }

        pointer.onMove = { [weak self] point, buttons in self?.launcher.pointerMoved(to: point, pressedButtons: buttons) }
        pointer.start()
        dockGuard.onHeldBackPointer = { [weak self] point in
            self?.launcher.pointerMoved(to: point, pressedButtons: NSEvent.pressedMouseButtons)
        }

        accessibility.onChange = { [weak self] in self?.applyDockGuard() }
        accessibility.startWatching()

        updates.isLauncherShown = { [weak self] in self?.launcher.isShown ?? false }
        updates.start()

        refreshLoginItem()
        rebuildItems()
        applyAll()

        if isFirstLaunch {
            showSettings()
            accessibility.requestOnce()
            launcher.preview(seconds: 4)
        }
    }

    func stop() {
        dockGuard.stop()
        pointer.stop()
    }

    // MARK: Settings

    /// Changes settings, saves them and shows the launcher for a moment so the change is visible.
    func update(_ change: (inout EdgeSettings) -> Void) {
        var changed = settings
        change(&changed)
        changed = changed.clamped()
        guard changed != settings else { return }
        let itemsAffected = changed.showRunningApps != settings.showRunningApps
        settings = changed
        save()
        if itemsAffected { rebuildItems() }
        applyAll()
        if settings.isEnabled { launcher.preview(seconds: 2.5) }
    }

    func chooseDisplay(_ id: String) {
        let name = displays.first { $0.id == id }?.name
        update {
            $0.displayID = id
            $0.displayName = name
        }
    }

    var chosenDisplay: DisplayInfo? {
        DisplayChoice.display(for: settings, in: displays)
    }

    /// Whether another display touches the chosen edge, so the launcher needs a short pause there.
    var chosenEdgeIsShared: Bool {
        guard let display = chosenDisplay else { return false }
        return EdgeGeometry.hasSharedPart(display, edge: settings.edge, among: displays)
    }

    /// Apple's Dock uses the same edge, so it may move onto this display unless the guard runs.
    var sharesEdgeWithAppleDock: Bool {
        AppleDockGuard.isNeeded(launcherEdge: settings.edge, appleDockEdge: appleDockEdge, displayCount: displays.count)
    }

    var isDockGuardActive: Bool { dockGuard.isRunning }

    func showLauncherNow() {
        launcher.preview(seconds: 3)
    }

    func setOpensAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginItemMessage = nil
        } catch {
            loginItemMessage = "macOS didn't allow this change. You can set it in System Settings → General → Login Items."
        }
        refreshLoginItem()
    }

    private func refreshLoginItem() {
        opensAtLogin = SMAppService.mainApp.status == .enabled
    }

    private func save() {
        if let data = settings.encoded() {
            UserDefaults.standard.set(data, forKey: Self.settingsKey)
        }
    }

    // MARK: Changes from the system

    private func displaysChanged() {
        displays = displayMonitor.displays
        // Keep the remembered name current when the chosen display is connected.
        if let display = chosenDisplay, display.name != settings.displayName {
            settings.displayName = display.name
            save()
        }
        applyAll()
    }

    private func appleDockChanged() {
        appleDockEdge = dockReader.edge
        appleDockAutohides = dockReader.autohides
        rebuildItems()
        applyDockGuard()
    }

    private func rebuildItems() {
        let built = LauncherItemBuilder.build(
            pinned: dockReader.pinned,
            running: apps.running,
            showRunningApps: settings.showRunningApps,
            ownBundleIdentifier: Bundle.main.bundleIdentifier
        )
        guard built != items else { return }
        items = built
        launcher.setItems(built)
    }

    private func applyAll() {
        launcher.configure(LauncherConfiguration(
            display: chosenDisplay,
            displays: displays,
            edge: settings.edge,
            iconSize: CGFloat(settings.iconSize),
            timing: RevealTiming(settings: settings),
            showOverFullScreenApps: settings.showOverFullScreenApps,
            isEnabled: settings.isEnabled
        ))
        applyDockGuard()
    }

    private func applyDockGuard() {
        guard settings.isEnabled,
              settings.keepAppleDockAway,
              accessibility.isTrusted,
              sharesEdgeWithAppleDock,
              let display = chosenDisplay else {
            dockGuard.stop()
            return
        }
        dockGuard.configure(display: display, edge: settings.edge, displays: displays)
        dockGuard.start()
    }

    // MARK: Windows and menu actions

    func showSettings() {
        if settingsWindow == nil {
            settingsWindow = SettingsWindowController(runtime: self)
        }
        accessibility.refresh()
        refreshLoginItem()
        settingsWindow?.show()
    }

    func quit() {
        NSApp.terminate(nil)
    }

    @objc func showSettingsAction(_ sender: Any?) {
        showSettings()
    }

    @objc func checkForUpdatesAction(_ sender: Any?) {
        NSApp.activate()
        updates.checkForUpdates()
    }
}
