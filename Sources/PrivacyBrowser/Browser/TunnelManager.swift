import AppKit
import BrowserCore
import NetworkExtension
import os
import SystemExtensions
import TunnelCore

/// The app's side of the packet tunnel (`PacketTunnelExtension`): activating the system
/// extension, installing its VPN configuration, starting it when a profile needs it, and
/// registering each running profile's WebRTC route.
///
/// What the tunnel does and why it only routes a virtual subnet: `docs/TUNNEL.md`. Without it
/// — a build without `NE=1`, the extension not allowed, the VPN configuration declined — a
/// profile with a proxy keeps WebRTC switched off (`ProfileConfiguration.webRTCRouting`), because
/// WebKit sends WebRTC around a data store's proxy.
@MainActor
final class TunnelManager: NSObject, ObservableObject {
    static let shared = TunnelManager()

    enum State: Equatable {
        /// This build has no extension in it (built without `NE=1`).
        case notBuilt
        case checking
        /// Built in, never activated (or deactivated).
        case off
        /// Activation requested; macOS waits for the user to allow it in System Settings.
        case awaitingApproval
        /// Allowed, but the VPN configuration is missing (its prompt was declined or not shown yet).
        case needsConfiguration
        /// Ready: the tunnel starts when a profile with a SOCKS5 proxy and WebRTC launches.
        case ready
        case connected
        case failed(String)
    }

    @Published private(set) var state: State = .checking

    /// The extension's bundle identifier, written into the app's Info.plist by `NE=1 scripts/build-app.sh`.
    let extensionIdentifier: String?
    private let log = Logger(subsystem: "PrivacyBrowser", category: "Tunnel")
    private var manager: NETunnelProviderManager?
    private var routes: [UUID: TunnelRoute] = [:]
    private var statusObserver: NSObjectProtocol?
    private var pendingRequest: OSSystemExtensionRequest?
    private var connectWaiters: [CheckedContinuation<Bool, Never>] = []

    override init() {
        let identifier = Bundle.main.object(forInfoDictionaryKey: "PBTunnelExtensionBundleIdentifier") as? String
        let bundled = identifier.map { Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/SystemExtensions/\($0).systemextension") }
        extensionIdentifier = bundled.map { FileManager.default.fileExists(atPath: $0.path) } == true ? identifier : nil
        super.init()
        state = extensionIdentifier == nil ? .notBuilt : .checking
    }

    /// The tunnel can carry a profile's WebRTC now (it is started on demand).
    var canCarryWebRTC: Bool { state == .ready || state == .connected }

    // MARK: Status

    /// Reads where activation and the VPN configuration stand (no prompts).
    func refresh() {
        guard let identifier = extensionIdentifier else { return }
        let request = OSSystemExtensionRequest.propertiesRequest(forExtensionWithIdentifier: identifier, queue: .main)
        request.delegate = self
        pendingRequest = request
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    private func extensionProperties(_ properties: [OSSystemExtensionProperties]) {
        if properties.contains(where: \.isEnabled) {
            Task { await loadConfiguration(install: false) }
        } else if properties.contains(where: \.isAwaitingUserApproval) {
            state = .awaitingApproval
        } else {
            state = .off
        }
    }

    // MARK: Enable

    /// Asks macOS to activate the extension (a system prompt, then a switch in System Settings),
    /// then installs the VPN configuration (another prompt).
    func enable() {
        guard let identifier = extensionIdentifier else { return }
        let request = OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier: identifier, queue: .main)
        request.delegate = self
        pendingRequest = request
        state = .checking
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    /// Opens System Settings where network extensions are allowed (macOS 15+: General → Login
    /// Items & Extensions → Network Extensions; older: Privacy & Security).
    func openSystemSettings() {
        for candidate in ["x-apple.systempreferences:com.apple.LoginItems-Settings.extension",
                          "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension",
                          "x-apple.systempreferences:com.apple.preference.security"] {
            if let url = URL(string: candidate), NSWorkspace.shared.open(url) { return }
        }
    }

    /// Loads (and with `install`, creates and saves — the "add VPN configurations" prompt) the
    /// tunnel's VPN configuration.
    private func loadConfiguration(install: Bool) async {
        guard let identifier = extensionIdentifier else { return }
        do {
            let managers = try await NETunnelProviderManager.loadAllFromPreferences()
            var manager = managers.first { ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == identifier }
            // A configuration an older build saved without enforced routes is updated (no prompt for
            // that); one the user switched off stays off until they press Enable.
            let outdated = manager?.isEnabled == true && (manager?.protocolConfiguration as? NETunnelProviderProtocol)?.enforceRoutes == false
            if manager == nil || manager?.isEnabled == false || outdated {
                guard install || outdated else {
                    state = .needsConfiguration
                    return
                }
                let configuration = manager ?? NETunnelProviderManager()
                let proto = NETunnelProviderProtocol()
                proto.providerBundleIdentifier = identifier
                proto.serverAddress = "PrivacyBrowser WebRTC relay"
                // WebKit binds its WebRTC sockets to the physical interface's address, and macOS
                // would then send them out of that interface whatever the routing table says.
                // Enforced routes put everything addressed to the relays' subnet into the tunnel,
                // bound or not; nothing else is routed into it (includeAllNetworks stays off).
                proto.enforceRoutes = true
                proto.includeAllNetworks = false
                configuration.protocolConfiguration = proto
                configuration.localizedDescription = L("tunnel.configurationName")
                configuration.isEnabled = true
                try await configuration.saveToPreferences()
                try await configuration.loadFromPreferences()
                manager = configuration
            }
            self.manager = manager
            observeStatus()
            state = manager?.connection.status == .connected ? .connected : .ready
        } catch {
            log.error("VPN configuration: \(error.localizedDescription, privacy: .public)")
            state = install ? .failed(error.localizedDescription) : .needsConfiguration
        }
    }

    private func observeStatus() {
        guard statusObserver == nil, let connection = manager?.connection else { return }
        statusObserver = NotificationCenter.default.addObserver(forName: .NEVPNStatusDidChange, object: connection, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.statusChanged() }
        }
    }

    private func statusChanged() {
        guard let status = manager?.connection.status else { return }
        log.info("tunnel status \(status.rawValue, privacy: .public)")
        switch status {
        case .connected:
            state = .connected
            // A (re)started extension has no routes: give it every running profile's again.
            for route in routes.values { Task { _ = await send(.register(route)) } }
            resumeWaiters(true)
        case .disconnected, .invalid:
            if state == .connected { state = .ready }
            resumeWaiters(false)
        default:
            break
        }
    }

    private func resumeWaiters(_ connected: Bool) {
        let waiters = connectWaiters
        connectWaiters.removeAll()
        for waiter in waiters { waiter.resume(returning: connected) }
    }

    // MARK: Routes

    /// Starts the tunnel if needed and registers a route for a profile launch with a SOCKS5
    /// proxy: the relay its pages are given. Nil when the tunnel cannot carry it — the profile
    /// then runs with WebRTC off.
    func register(profile id: UUID, proxy: ProxySettings) async -> WebRTCRelay? {
        guard proxy.kind == .socks5, canCarryWebRTC, let port = UInt16(exactly: proxy.port) else { return nil }
        unregister(profile: id)
        let used = Set(routes.values.map(\.relayIPv4))
        guard let slot = TunnelAddressing.slots.first(where: { !used.contains(TunnelAddressing.relayIPv4(slot: $0)) }) else { return nil }
        let route = TunnelRoute(id: UUID().uuidString, relayIPv4: TunnelAddressing.relayIPv4(slot: slot),
                                relayIPv6: TunnelAddressing.relayIPv6(slot: slot),
                                username: Self.randomToken(8), password: Self.randomToken(16),
                                proxy: SOCKSProxy(host: proxy.host, port: port, username: proxy.username, password: proxy.password))
        guard await connect() else {
            log.notice("tunnel did not connect; WebRTC stays off for this profile")
            return nil
        }
        guard await send(.register(route)) else { return nil }
        routes[id] = route
        return WebRTCRelay(urls: route.turnURLs, username: route.username, credential: route.password)
    }

    func unregister(profile id: UUID) {
        guard let route = routes.removeValue(forKey: id) else { return }
        Task {
            _ = await send(.unregister(id: route.id))
            // Nothing left to relay: stop the tunnel (and the VPN indicator) until it is needed.
            if routes.isEmpty, manager?.connection.status == .connected { manager?.connection.stopVPNTunnel() }
        }
    }

    private func connect() async -> Bool {
        guard let connection = manager?.connection else { return false }
        if connection.status == .connected { return true }
        do {
            if connection.status != .connecting { try connection.startVPNTunnel() }
        } catch {
            log.error("startVPNTunnel: \(error.localizedDescription, privacy: .public)")
            return false
        }
        return await withCheckedContinuation { continuation in
            connectWaiters.append(continuation)
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                self.resumeWaiters(self.manager?.connection.status == .connected)
            }
        }
    }

    private func send(_ message: TunnelControlMessage) async -> Bool {
        guard let session = manager?.connection as? NETunnelProviderSession, let data = try? message.encoded() else { return false }
        return await withCheckedContinuation { continuation in
            do {
                try session.sendProviderMessage(data) { reply in
                    let status = reply.flatMap { try? JSONDecoder().decode(TunnelStatusReply.self, from: $0) }
                    continuation.resume(returning: status != nil && status?.error == nil)
                }
            } catch {
                continuation.resume(returning: false)
            }
        }
    }

    private static func randomToken(_ bytes: Int) -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<bytes).map { _ in String(format: "%02x", UInt8.random(in: 0...255, using: &generator)) }.joined()
    }
}

// MARK: - OSSystemExtensionRequestDelegate

extension TunnelManager: OSSystemExtensionRequestDelegate {
    nonisolated func request(_ request: OSSystemExtensionRequest, actionForReplacingExtension existing: OSSystemExtensionProperties,
                             withExtension replacement: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        .replace
    }

    nonisolated func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        MainActor.assumeIsolated { state = .awaitingApproval }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        MainActor.assumeIsolated {
            switch result {
            case .completed:
                Task { await loadConfiguration(install: true) }
            case .willCompleteAfterReboot:
                state = .failed(L("tunnel.state.reboot"))
            @unknown default:
                state = .failed("\(result.rawValue)")
            }
        }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        MainActor.assumeIsolated {
            log.error("system extension request: \(error.localizedDescription, privacy: .public)")
            state = .failed(error.localizedDescription)
        }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, foundProperties properties: [OSSystemExtensionProperties]) {
        MainActor.assumeIsolated { extensionProperties(properties) }
    }
}
