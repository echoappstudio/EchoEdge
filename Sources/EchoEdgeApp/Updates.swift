import AppKit
import EchoEdgeCore
import Observation
import Sparkle

/// EchoEdge's automatic updates, through Sparkle.
///
/// Sparkle checks every hour (set in Info.plist) and once right after launch. When automatic
/// installs are on, a downloaded update is installed and EchoEdge relaunched as soon as the
/// launcher is tucked away. The settings live in Sparkle's own saved preferences.
@MainActor
@Observable
final class UpdateController: NSObject {
    private(set) var canCheckForUpdates = false
    private(set) var automaticallyChecks = false
    private(set) var automaticallyInstalls = false
    private(set) var lastCheckDate: Date?
    /// A background check found an update and EchoEdge is waiting for the user to look at it.
    private(set) var updateWaiting: String?

    @ObservationIgnored var isLauncherShown: (() -> Bool)?
    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private var installWaitTask: Task<Void, Never>?
    @ObservationIgnored private var pendingInstall: (() -> Void)?

    private var updater: SPUUpdater? { controller?.updater }

    /// Starts the updater, then checks right away if automatic checks are on.
    func start() {
        guard controller == nil else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: self)
        self.controller = controller
        let updater = controller.updater
        observations = [
            updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
                MainActor.assumeIsolated { self?.refresh(from: updater) }
            },
            updater.observe(\.automaticallyChecksForUpdates, options: [.new]) { [weak self] updater, _ in
                MainActor.assumeIsolated { self?.refresh(from: updater) }
            },
            updater.observe(\.automaticallyDownloadsUpdates, options: [.new]) { [weak self] updater, _ in
                MainActor.assumeIsolated { self?.refresh(from: updater) }
            },
            updater.observe(\.lastUpdateCheckDate, options: [.new]) { [weak self] updater, _ in
                MainActor.assumeIsolated { self?.refresh(from: updater) }
            }
        ]
        refresh(from: updater)
        if updater.automaticallyChecksForUpdates {
            updater.checkForUpdatesInBackground()
        }
    }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }

    func setAutomaticallyChecks(_ enabled: Bool) {
        updater?.automaticallyChecksForUpdates = enabled
    }

    func setAutomaticallyInstalls(_ enabled: Bool) {
        updater?.automaticallyDownloadsUpdates = enabled
    }

    private func refresh(from updater: SPUUpdater) {
        canCheckForUpdates = updater.canCheckForUpdates
        automaticallyChecks = updater.automaticallyChecksForUpdates
        automaticallyInstalls = updater.automaticallyDownloadsUpdates
        lastCheckDate = updater.lastUpdateCheckDate
    }

    private var launcherIsShown: Bool {
        isLauncherShown?() ?? false
    }

    /// Runs `install` once the launcher is tucked away.
    private func installWhenIdle(_ install: @escaping () -> Void) {
        pendingInstall = install
        installWaitTask?.cancel()
        let started = Date()
        installWaitTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if UpdateInstallPolicy.canInstallNow(
                    isLauncherShown: self.launcherIsShown,
                    waitedSeconds: Date().timeIntervalSince(started)
                ) {
                    self.installWaitTask = nil
                    let install = self.pendingInstall
                    self.pendingInstall = nil
                    install?()
                    return
                }
                try? await Task.sleep(for: .seconds(UpdateInstallPolicy.retryInterval))
            }
        }
    }
}

extension UpdateController: SPUUpdaterDelegate {
    /// With automatic installs on, Sparkle hands over the downloaded update; EchoEdge installs and
    /// relaunches as soon as the launcher is hidden instead of waiting for the next quit.
    @objc(updater:willInstallUpdateOnQuit:immediateInstallationBlock:)
    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem, immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        installWhenIdle(immediateInstallHandler)
        return true
    }

    /// An update the user chose to install also waits for the launcher to hide.
    @objc(updater:shouldPostponeRelaunchForUpdate:untilInvokingBlock:)
    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem, untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        if UpdateInstallPolicy.canInstallNow(isLauncherShown: launcherIsShown, waitedSeconds: 0) {
            return false
        }
        installWhenIdle(installHandler)
        return true
    }
}

/// EchoEdge has no menu-bar icon, so updates found in the background are shown gently: a line in
/// Settings instead of a window that may open behind other apps.
extension UpdateController: @preconcurrency SPUStandardUserDriverDelegate {
    @objc var supportsGentleScheduledUpdateReminders: Bool { true }

    @objc(standardUserDriverShouldHandleShowingScheduledUpdate:andInImmediateFocus:)
    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        immediateFocus
    }

    @objc(standardUserDriverWillHandleShowingUpdate:forUpdate:state:)
    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        if !handleShowingUpdate {
            updateWaiting = update.displayVersionString
        }
    }

    @objc(standardUserDriverDidReceiveUserAttentionForUpdate:)
    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        updateWaiting = nil
    }

    @objc func standardUserDriverWillFinishUpdateSession() {
        updateWaiting = nil
    }
}
