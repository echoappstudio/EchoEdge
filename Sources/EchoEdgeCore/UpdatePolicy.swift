import Foundation

/// When EchoEdge may relaunch to install an update that has already downloaded.
public enum UpdateInstallPolicy {
    /// How often EchoEdge looks again while the launcher is in use.
    public static let retryInterval: TimeInterval = 5
    /// Someone parked on the launcher mustn't hold an update back forever.
    public static let longestWait: TimeInterval = 10 * 60

    /// Installs while the launcher is tucked away, so it never vanishes under the pointer.
    public static func canInstallNow(isLauncherShown: Bool, waitedSeconds: TimeInterval) -> Bool {
        !isLauncherShown || waitedSeconds >= longestWait
    }
}
