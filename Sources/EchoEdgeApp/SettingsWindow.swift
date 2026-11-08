import AppKit
import EchoEdgeCore
import SwiftUI

/// The Settings window. While it's open EchoEdge shows in Apple's Dock and has a menu bar; when
/// it closes, EchoEdge goes back to being just the launcher.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let window: NSWindow

    init(runtime: EchoEdgeRuntime) {
        let hosting = NSHostingController(rootView: SettingsView(runtime: runtime, updates: runtime.updates, accessibility: runtime.accessibility))
        window = NSWindow(contentViewController: hosting)
        window.title = "EchoEdge"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 620, height: 760))
        window.contentMinSize = NSSize(width: 540, height: 480)
        window.isReleasedWhenClosed = false
        // Centred the first time; after that, where it was last left.
        window.center()
        window.setFrameAutosaveName("EchoEdge.settingsWindow")
        super.init()
        window.delegate = self
    }

    func show() {
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}

struct SettingsView: View {
    let runtime: EchoEdgeRuntime
    let updates: UpdateController
    let accessibility: AccessibilityAccess

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                placement
                behavior
                accessibilityBox
                general
                updatesBox
                footer
            }
            .padding(28)
            .frame(maxWidth: 760, alignment: .topLeading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(minWidth: 540, minHeight: 480)
    }

    // MARK: Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("EchoEdge")
                .font(.largeTitle.weight(.semibold))
            Text("An extra Dock on the display and edge you choose. It slides out when your pointer reaches that edge.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var placement: some View {
        GroupBox("Where") {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Display", selection: displayBinding) {
                    ForEach(displayOptions, id: \.id) { option in
                        Text(option.label).tag(option.id)
                    }
                }
                Picker("Edge", selection: binding(\.edge)) {
                    ForEach(ScreenEdge.allCases, id: \.self) { edge in
                        Text(edge.title).tag(edge)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 320)

                if runtime.chosenDisplay == nil {
                    Label(notConnectedText, systemImage: "display.trianglebadge.exclamationmark")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if runtime.chosenEdgeIsShared {
                    Label("Another display touches part of this edge, so the pointer can slip across. Pause at the edge for a moment there and EchoEdge slides out.", systemImage: "rectangle.split.2x1")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let note = appleDockNote {
                    Label(note, systemImage: "dock.rectangle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 12) {
                    Button("Show EchoEdge Now") { runtime.showLauncherNow() }
                        .disabled(runtime.chosenDisplay == nil || !runtime.settings.isEnabled)
                    Toggle("EchoEdge on", isOn: binding(\.isEnabled))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }

    private var behavior: some View {
        GroupBox("Behavior") {
            VStack(alignment: .leading, spacing: 12) {
                sliderRow(
                    "Icon size",
                    value: binding(\.iconSize),
                    range: EdgeSettings.iconSizeRange,
                    step: 4,
                    text: "\(Int(runtime.settings.iconSize)) pt"
                )
                sliderRow(
                    "Show after",
                    value: binding(\.showDelay),
                    range: EdgeSettings.showDelayRange,
                    step: 0.05,
                    text: seconds(runtime.settings.showDelay)
                )
                sliderRow(
                    "Hide after",
                    value: binding(\.hideDelay),
                    range: EdgeSettings.hideDelayRange,
                    step: 0.1,
                    text: seconds(runtime.settings.hideDelay)
                )
                Toggle("Show open apps that aren't in the Dock", isOn: binding(\.showRunningApps))
                Toggle("Show over full-screen apps", isOn: binding(\.showOverFullScreenApps))
                Toggle("Click the app in front to minimize its window", isOn: binding(\.minimizeFrontAppOnClick))
                Toggle("Keep Apple's Dock away from EchoEdge's edge", isOn: binding(\.keepAppleDockAway))
                Text("Right-click an app for its windows, Show in Finder, Hide and Quit. ⌘-click shows it in Finder. Drop files on an app to open them with it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }

    private var accessibilityBox: some View {
        GroupBox("Accessibility") {
            VStack(alignment: .leading, spacing: 10) {
                if accessibility.isTrusted {
                    Label("Allowed. EchoEdge can list windows, minimize and keep Apple's Dock away.", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Allow Accessibility so EchoEdge can list an app's windows, minimize the app in front and keep Apple's Dock away from its edge. The launcher works without it.")
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 12) {
                        Button("Allow Accessibility…") { accessibility.request() }
                        Button("Open System Settings") { accessibility.openSystemSettings() }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }

    private var general: some View {
        GroupBox("General") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Open EchoEdge at login", isOn: Binding(
                    get: { runtime.opensAtLogin },
                    set: { runtime.setOpensAtLogin($0) }
                ))
                if let message = runtime.loginItemMessage {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("To open Settings later, right-click an empty spot on the launcher, or open EchoEdge again from Applications.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Quit EchoEdge") { runtime.quit() }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }

    private var updatesBox: some View {
        GroupBox("Updates") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Check for updates automatically", isOn: Binding(
                    get: { updates.automaticallyChecks },
                    set: { updates.setAutomaticallyChecks($0) }
                ))
                Toggle("Install updates automatically", isOn: Binding(
                    get: { updates.automaticallyInstalls },
                    set: { updates.setAutomaticallyInstalls($0) }
                ))
                .disabled(!updates.automaticallyChecks)
                if let waiting = updates.updateWaiting {
                    Label("EchoEdge \(waiting) is ready to install.", systemImage: "arrow.down.circle.fill")
                        .foregroundStyle(.blue)
                }
                HStack(spacing: 12) {
                    Button("Check Now") {
                        NSApp.activate()
                        updates.checkForUpdates()
                    }
                    .disabled(!updates.canCheckForUpdates)
                    Text(lastCheckText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }

    private var footer: some View {
        Label("No account, no tracking, no server. EchoEdge only goes online to check GitHub for its own updates.", systemImage: "lock.shield")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Helpers

    private struct DisplayOption {
        let id: String
        let label: String
    }

    private var displayOptions: [DisplayOption] {
        let labels = DisplayChoice.labels(for: runtime.displays)
        var options = runtime.displays.map { DisplayOption(id: $0.id, label: labels[$0.id] ?? $0.name) }
        if let id = runtime.settings.displayID, !options.contains(where: { $0.id == id }) {
            let name = runtime.settings.displayName ?? "Chosen display"
            options.append(DisplayOption(id: id, label: "\(name) (not connected)"))
        }
        return options
    }

    private var displayBinding: Binding<String> {
        Binding(
            get: { runtime.settings.displayID ?? "" },
            set: { runtime.chooseDisplay($0) }
        )
    }

    private var notConnectedText: String {
        let name = runtime.settings.displayName ?? "The chosen display"
        return "\(name) isn't connected. EchoEdge comes back when it is, or pick another display."
    }

    private var appleDockNote: String? {
        guard runtime.sharesEdgeWithAppleDock else { return nil }
        if !runtime.settings.keepAppleDockAway {
            return "Apple's Dock is on this edge too, so it can move onto this display. Turn on \"Keep Apple's Dock away\" below, or pick another edge."
        }
        if !accessibility.isTrusted {
            return "Apple's Dock is on this edge too. Allow Accessibility below so EchoEdge can keep it on your other display."
        }
        return "Apple's Dock is on this edge too; EchoEdge keeps it on your other display."
    }

    private var lastCheckText: String {
        guard let date = updates.lastCheckDate else { return "Not checked yet" }
        return "Last checked \(date.formatted(date: .abbreviated, time: .shortened))"
    }

    private func seconds(_ value: Double) -> String {
        value == 0 ? "At once" : String(format: "%.2g s", value)
    }

    private func binding<T>(_ keyPath: WritableKeyPath<EdgeSettings, T>) -> Binding<T> {
        Binding(
            get: { runtime.settings[keyPath: keyPath] },
            set: { value in runtime.update { $0[keyPath: keyPath] = value } }
        )
    }

    private func sliderRow(
        _ title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        text: String
    ) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .frame(width: 90, alignment: .leading)
            Slider(value: value, in: range, step: step)
                .frame(maxWidth: 320)
            Text(text)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .leading)
        }
    }
}
