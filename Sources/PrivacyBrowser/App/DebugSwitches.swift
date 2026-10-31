import Foundation

/// Switches for hardware checks and site captures, never for everyday use.
enum DebugSwitches {
    /// WebRTC through the packet tunnel may gather on every interface, not only the tunnel's —
    /// for the hardware checks in docs/TUNNEL.md: `defaults write <bundle id> PBTunnelAllInterfaces
    /// -bool YES`. Read from the app's own saved settings only: not from a command-line argument or
    /// the global domain, where another program or a stray argument would turn it on unseen; and a
    /// site capture sets it for its own run in memory (`captureOverride`), never in the settings,
    /// where an interrupted capture would leave it on.
    static var tunnelAllInterfaces: Bool {
        if let value = captureOverride.value { return value }
        guard let bundleID = Bundle.main.bundleIdentifier else { return false }
        return UserDefaults.standard.persistentDomain(forName: bundleID)?["PBTunnelAllInterfaces"] as? Bool == true
    }

    /// Set by `--capture-sites` for one capture (`SiteCapture`), in this process only.
    static let captureOverride = Override()

    final class Override: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Bool?
        var value: Bool? {
            get { lock.withLock { stored } }
            set { lock.withLock { stored = newValue } }
        }
    }
}
