import AppKit
import ApplicationServices
import EchoEdgeCore

/// What clicking, right-clicking and dropping files on the launcher do.
@MainActor
final class AppActions {
    weak var runtime: EchoEdgeRuntime?

    // MARK: Click

    /// Opens or switches to the app, like Apple's Dock. Clicking the app that's already in front
    /// minimizes its window (when that's turned on and Accessibility is allowed); ⌘-click shows the
    /// app in Finder.
    func open(_ item: LauncherItem, modifiers: NSEvent.ModifierFlags) {
        guard item.kind == .app else { return }
        if modifiers.contains(.command) {
            revealInFinder(item)
            return
        }
        if let runtime, let processID = item.processID,
           runtime.settings.minimizeFrontAppOnClick,
           runtime.accessibility.isTrusted,
           NSWorkspace.shared.frontmostApplication?.processIdentifier == processID,
           WindowAccess.minimizeFocusedWindow(of: processID) {
            return
        }
        guard let url = appURL(for: item) else {
            if let processID = item.processID {
                WindowAccess.bringAppForward(processID)
            }
            return
        }
        // Opening a running app switches to it and lets it bring back a window (like the Dock).
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
            if let error {
                NSLog("EchoEdge couldn't open an app: %@", error.localizedDescription)
            }
        }
    }

    /// Files dropped on an app open in that app.
    func open(_ files: [URL], with item: LauncherItem) {
        guard item.kind == .app, !files.isEmpty, let url = appURL(for: item) else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open(files, withApplicationAt: url, configuration: configuration) { _, error in
            if let error {
                NSLog("EchoEdge couldn't open files in an app: %@", error.localizedDescription)
            }
        }
    }

    // MARK: Right-click menu

    func menu(for item: LauncherItem?) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        if let item, item.kind == .app {
            addAppItems(for: item, to: menu)
            menu.addItem(.separator())
        }
        menu.addItem(ActionMenuItem("EchoEdge Settings…") { [weak self] in self?.runtime?.showSettings() })
        if item == nil {
            menu.addItem(ActionMenuItem("Quit EchoEdge") { [weak self] in self?.runtime?.quit() })
        }
        return menu
    }

    private func addAppItems(for item: LauncherItem, to menu: NSMenu) {
        let header = NSMenuItem(title: item.name, action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        if let processID = item.processID {
            if runtime?.accessibility.isTrusted == true {
                let windows = WindowAccess.windows(of: processID)
                if !windows.isEmpty {
                    menu.addItem(.separator())
                    for window in windows {
                        let title = window.isMinimized ? "\(window.title) (minimized)" : window.title
                        let entry = ActionMenuItem(title) {
                            WindowAccess.bringForward(window, processID: processID)
                        }
                        entry.image = NSImage(systemSymbolName: window.isMinimized ? "minus.square" : "macwindow", accessibilityDescription: nil)
                        menu.addItem(entry)
                    }
                }
            } else {
                menu.addItem(.separator())
                menu.addItem(ActionMenuItem("Allow Accessibility to List Windows…") { [weak self] in
                    self?.runtime?.accessibility.request()
                    self?.runtime?.showSettings()
                })
            }
        }

        menu.addItem(.separator())
        if !item.isRunning {
            menu.addItem(ActionMenuItem("Open") { [weak self] in self?.open(item, modifiers: []) })
        }
        if appURL(for: item) != nil {
            menu.addItem(ActionMenuItem("Show in Finder") { [weak self] in self?.revealInFinder(item) })
        }
        if let processID = item.processID, let app = NSRunningApplication(processIdentifier: processID) {
            menu.addItem(.separator())
            if app.isHidden {
                menu.addItem(ActionMenuItem("Show") { app.unhide() })
            } else {
                menu.addItem(ActionMenuItem("Hide") { app.hide() })
            }
            // Finder can't be quit from the Dock either.
            if item.bundleIdentifier?.lowercased() != LauncherItemBuilder.finderBundleIdentifier {
                menu.addItem(ActionMenuItem("Quit") { app.terminate() })
            }
        }
    }

    // MARK: Helpers

    private func revealInFinder(_ item: LauncherItem) {
        guard let url = appURL(for: item) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func appURL(for item: LauncherItem) -> URL? {
        if let path = item.path, FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        if let bundleIdentifier = item.bundleIdentifier {
            return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
        }
        return nil
    }
}

/// A menu item that runs a closure.
@MainActor
final class ActionMenuItem: NSMenuItem {
    private let handler: @MainActor () -> Void

    init(_ title: String, handler: @escaping @MainActor () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run(_:)), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    @objc private func run(_ sender: Any?) {
        handler()
    }
}

/// Other apps' windows, through Accessibility.
@MainActor
enum WindowAccess {
    struct Window {
        let element: AXUIElement
        let title: String
        let isMinimized: Bool
    }

    /// Every Accessibility call EchoEdge makes gives up after half a second, so an app that
    /// doesn't answer can't freeze the launcher. Call once at launch.
    static func limitWaiting() {
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.5)
    }

    /// The app's ordinary windows, front to back (at most 40).
    static func windows(of processID: pid_t) -> [Window] {
        let app = application(processID)
        guard let elements = copy(app, "AXWindows") as? [AXUIElement] else { return [] }
        return elements.prefix(40).compactMap { element in
            guard (copy(element, "AXRole") as? String) == "AXWindow" else { return nil }
            let subrole = copy(element, "AXSubrole") as? String
            guard subrole == nil || subrole == "AXStandardWindow" || subrole == "AXDialog" else { return nil }
            let title = (copy(element, "AXTitle") as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Untitled"
            let minimized = (copy(element, "AXMinimized") as? Bool) ?? false
            return Window(element: element, title: title, isMinimized: minimized)
        }
    }

    /// Minimizes the app's focused window. Returns false if it has none (so the click opens it).
    static func minimizeFocusedWindow(of processID: pid_t) -> Bool {
        let app = application(processID)
        guard let value = copy(app, "AXFocusedWindow"),
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return false }
        let window = value as! AXUIElement
        if (copy(window, "AXMinimized") as? Bool) == true { return false }
        return AXUIElementSetAttributeValue(window, "AXMinimized" as CFString, NSNumber(value: true)) == .success
    }

    /// Brings one window to the front, restoring it if it's minimized.
    static func bringForward(_ window: Window, processID: pid_t) {
        if window.isMinimized {
            AXUIElementSetAttributeValue(window.element, "AXMinimized" as CFString, NSNumber(value: false))
        }
        AXUIElementPerformAction(window.element, "AXRaise" as CFString)
        AXUIElementSetAttributeValue(window.element, "AXMain" as CFString, NSNumber(value: true))
        bringAppForward(processID)
    }

    /// Brings an app to the front. EchoEdge itself is never the active app, and macOS may ignore
    /// an activation request from an inactive app, so Accessibility asks the app directly.
    static func bringAppForward(_ processID: pid_t) {
        let app = application(processID)
        if AXUIElementSetAttributeValue(app, "AXFrontmost" as CFString, NSNumber(value: true)) != .success {
            NSRunningApplication(processIdentifier: processID)?.activate(options: [])
        }
    }

    private static func application(_ processID: pid_t) -> AXUIElement {
        let app = AXUIElementCreateApplication(processID)
        // A busy app mustn't freeze the launcher.
        AXUIElementSetMessagingTimeout(app, 0.5)
        return app
    }

    private static func copy(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }
}
