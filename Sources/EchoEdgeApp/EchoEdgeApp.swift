import AppKit

/// EchoEdge has no menu-bar icon and no window at launch: the launcher is the app. Settings open
/// from the launcher's right-click menu, or by opening EchoEdge again.
@main
enum EchoEdgeMain {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) {
            app.run()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var runtime: EchoEdgeRuntime?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let runtime = EchoEdgeRuntime()
        self.runtime = runtime
        NSApp.mainMenu = MainMenu.make(target: runtime)
        runtime.start()
    }

    /// Opening EchoEdge again (Finder, Spotlight, Launchpad) brings up Settings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        runtime?.showSettings()
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        runtime?.stop()
    }
}

/// The menu bar shown while Settings is open.
@MainActor
enum MainMenu {
    static func make(target: EchoEdgeRuntime) -> NSMenu {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "EchoEdge")
        appMenu.addItem(withTitle: "About EchoEdge", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        let updates = appMenu.addItem(withTitle: "Check for Updates…", action: #selector(EchoEdgeRuntime.checkForUpdatesAction(_:)), keyEquivalent: "")
        updates.target = target
        appMenu.addItem(.separator())
        let settings = appMenu.addItem(withTitle: "Settings…", action: #selector(EchoEdgeRuntime.showSettingsAction(_:)), keyEquivalent: ",")
        settings.target = target
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide EchoEdge", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit EchoEdge", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)
        NSApp.windowsMenu = windowMenu
        return main
    }
}
