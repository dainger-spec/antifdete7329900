import BrowserCore
import Foundation
#if canImport(NetworkExtension)
import NetworkExtension
#endif
#if canImport(Security)
import Security
#endif

/// Brings the per-profile packet tunnel up and down (see `docs/NETWORK.md`). The tunnel gives a
/// profile one exit IP for TCP and UDP; it needs the `PacketTunnel` Network Extension, which only
/// a provisioned `NE=1` build embeds. Without it `isAvailable` is false and the UI shows the
/// unified-exit option as unavailable.
///
/// Fail-closed is enforced by the caller (`ProfileManager`): it only creates the profile's web
/// views after `start(...)` reports the tunnel up, and refuses the launch otherwise, so a profile
/// that asked for the tunnel never browses without it.
@MainActor
final class ProfileTunnelController: ObservableObject {
    enum State: Equatable {
        case unavailable
        case down
        case connecting
        case up
        case failed(String)
    }

    @Published private(set) var state: State = ProfileTunnelController.isAvailable ? .down : .unavailable

    /// True only in a build that embedded the Network Extension (`NE=1`); set by the build flag.
    static var isAvailable: Bool {
        #if PB_NETWORK_EXTENSION
        return true
        #else
        return false
        #endif
    }

    /// The extension's bundle id, `<app id>.PacketTunnel` (matches build-app.sh).
    private static var tunnelBundleID: String {
        (Bundle.main.bundleIdentifier ?? "dev.local.PrivacyBrowser") + ".PacketTunnel"
    }

    enum TunnelError: LocalizedError {
        case unavailable
        case startFailed(String)

        var errorDescription: String? {
            switch self {
            case .unavailable: return L("tunnel.error.unavailable")
            case .startFailed(let why): return String(format: L("tunnel.error.start"), why)
            }
        }
    }

    #if PB_NETWORK_EXTENSION
    private var manager: NETunnelProviderManager?
    private var statusObserver: NSObjectProtocol?

    /// Loads or creates this profile's VPN configuration, stores the proxy password in the
    /// keychain, and starts the tunnel. Returns once the tunnel is up, or throws (fail-closed).
    func start(_ config: TunnelConfiguration, proxyPassword: String?) async throws {
        state = .connecting
        do {
            let manager = try await loadOrCreateManager(config: config, proxyPassword: proxyPassword)
            self.manager = manager
            observe(manager)
            try manager.connection.startVPNTunnel()
            try await waitForState(.connected, timeout: 20)
            state = .up
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            state = .failed(message)
            await stop()
            throw TunnelError.startFailed(message)
        }
    }

    func stop() async {
        if let statusObserver { NotificationCenter.default.removeObserver(statusObserver) }
        statusObserver = nil
        manager?.connection.stopVPNTunnel()
        // Remove the saved configuration so no profile's tunnel lingers in System Settings.
        try? await manager?.removeFromPreferences()
        manager = nil
        if state != .unavailable { state = .down }
    }

    private func loadOrCreateManager(config: TunnelConfiguration,
                                     proxyPassword: String?) async throws -> NETunnelProviderManager {
        let all = try await NETunnelProviderManager.loadAllFromPreferences()
        let manager = all.first { ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == Self.tunnelBundleID }
            ?? NETunnelProviderManager()
        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = Self.tunnelBundleID
        proto.serverAddress = config.summary
        proto.providerConfiguration = config.dictionary
        if let proxyPassword, !proxyPassword.isEmpty {
            proto.passwordReference = try KeychainPassword.store(proxyPassword, account: config.profileID.uuidString)
        }
        manager.protocolConfiguration = proto
        manager.localizedDescription = L("tunnel.config.name")
        manager.isEnabled = true
        try await manager.saveToPreferences()
        try await manager.loadFromPreferences() // re-load so connection is usable after save
        return manager
    }

    private func observe(_ manager: NETunnelProviderManager) {
        statusObserver = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange, object: manager.connection, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                switch manager.connection.status {
                case .connected: self.state = .up
                case .connecting, .reasserting: self.state = .connecting
                case .disconnected, .invalid: if self.state != .unavailable { self.state = .down }
                case .disconnecting: break
                @unknown default: break
                }
            }
        }
    }

    private func waitForState(_ target: NEVPNStatus, timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let status = manager?.connection.status
            if status == target { return }
            if status == .invalid || status == .disconnected {
                throw TunnelError.startFailed(L("tunnel.error.notStarted"))
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        throw TunnelError.startFailed(L("tunnel.error.timeout"))
    }
    #else
    // No extension in this build: the tunnel cannot run. Callers must check `isAvailable` and
    // fail the launch closed; these never succeed.
    func start(_ config: TunnelConfiguration, proxyPassword: String?) async throws {
        throw TunnelError.unavailable
    }

    func stop() async {}
    #endif
}

#if PB_NETWORK_EXTENSION
/// Stores the proxy password in the keychain and returns a persistent reference to hand the
/// extension via `NETunnelProviderProtocol.passwordReference` — the password never travels in the
/// provider configuration dictionary.
private enum KeychainPassword {
    static func store(_ password: String, account: String) throws -> Data {
        let service = "PrivacyBrowser.tunnel"
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service,
                                   kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
        var attributes = base
        attributes[kSecValueData as String] = Data(password.utf8)
        attributes[kSecReturnPersistentRef as String] = true
        var ref: CFTypeRef?
        let status = SecItemAdd(attributes as CFDictionary, &ref)
        guard status == errSecSuccess, let data = ref as? Data else {
            throw ProfileTunnelController.TunnelError.startFailed("keychain \(status)")
        }
        return data
    }
}
#endif
