import AppKit
import BrowserCore
import NetworkExtension
import os
import ServiceManagement
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

    @Published private(set) var state: State = .checking {
        didSet { if state != .checking { resumeStatusWaiters() } }
    }

    /// The extension's bundle identifier, written into the app's Info.plist by `NE=1 scripts/build-app.sh`.
    let extensionIdentifier: String?
    private let log = Logger(subsystem: "PrivacyBrowser", category: "Tunnel")
    private var manager: NETunnelProviderManager?
    private var routes: [UUID: TunnelRoute] = [:]
    private var statusObserver: NSObjectProtocol?
    private weak var observedConnection: NEVPNConnection?
    private var pendingRequest: OSSystemExtensionRequest?
    /// The pending request asks for activation (Enable, or an update), not just the properties (a refresh).
    private var pendingIsActivation = false
    /// The pending activation came from Enable: when it completes, the VPN configuration is
    /// installed (its prompt) or switched back on. An update keeps the configuration as it is.
    private var activationInstalls = false
    /// While routes exist the app tells the extension it is alive; the extension drops routes the
    /// app stopped tending (a crash, a force quit) and stops (`PacketTunnelProvider.heartbeatTimeout`).
    private var heartbeat: Timer?
    private var connectWaiters: [CheckedContinuation<Bool, Never>] = []
    private var statusWaiters: [CheckedContinuation<Void, Never>] = []
    /// Launches between reserving a route and the extension's answer: the tunnel is not stopped meanwhile.
    private var registering = 0

    override init() {
        let identifier = Bundle.main.object(forInfoDictionaryKey: "PBTunnelExtensionBundleIdentifier") as? String
        let bundled = identifier.map { Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/SystemExtensions/\($0).systemextension") }
        extensionIdentifier = bundled.map { FileManager.default.fileExists(atPath: $0.path) } == true ? identifier : nil
        super.init()
        state = extensionIdentifier == nil ? .notBuilt : .checking
        // Read at once, so the editor and the first launch know whether the tunnel can carry WebRTC.
        if extensionIdentifier != nil { DispatchQueue.main.async { self.refresh() } }
    }

    /// The tunnel can carry a profile's WebRTC now (it is started on demand).
    var canCarryWebRTC: Bool { state == .ready || state == .connected }

    // MARK: Status

    /// Reads where activation and the VPN configuration stand (no prompts).
    func refresh() {
        guard let identifier = extensionIdentifier, !(pendingIsActivation && pendingRequest != nil) else { return }
        let request = OSSystemExtensionRequest.propertiesRequest(forExtensionWithIdentifier: identifier, queue: .main)
        request.delegate = self
        pendingRequest = request
        pendingIsActivation = false
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    /// Waits (at most 5 s) until the state is known.
    private func knownState() async -> State {
        guard state == .checking else { return state }
        await withCheckedContinuation { continuation in
            statusWaiters.append(continuation)
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                self.resumeStatusWaiters()
            }
        }
        return state
    }

    private func resumeStatusWaiters() {
        let waiters = statusWaiters
        statusWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    private func extensionProperties(_ properties: [OSSystemExtensionProperties]) {
        if properties.contains(where: \.isEnabled) {
            // macOS replaces an installed extension only on an activation request: one that is not
            // this app's bundled version (an updated app) is replaced now, without a new approval.
            if let bundled = bundledExtensionVersion,
               !properties.contains(where: { $0.isEnabled && !$0.isUninstalling && $0.bundleVersion == bundled }) {
                log.notice("the enabled extension is not this app's version \(bundled, privacy: .public): updating it")
                activate(installing: false)
                return
            }
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
        activate(installing: true)
    }

    private func activate(installing: Bool) {
        guard let identifier = extensionIdentifier else { return }
        let request = OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier: identifier, queue: .main)
        request.delegate = self
        pendingRequest = request
        pendingIsActivation = true
        activationInstalls = installing
        state = .checking
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    /// CFBundleVersion of the extension inside this app (a new one per build, scripts/build-app.sh).
    private var bundledExtensionVersion: String? {
        guard let identifier = extensionIdentifier else { return nil }
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Library/SystemExtensions/\(identifier).systemextension")
        return Bundle(url: url)?.object(forInfoDictionaryKey: "CFBundleVersion") as? String
    }

    /// Opens System Settings where network extensions are allowed: on macOS 15+ General → Login
    /// Items & Extensions (Network Extensions is in that pane), through the documented API; on
    /// macOS 14 Privacy & Security, through its (undocumented) URL.
    func openSystemSettings() {
        if #available(macOS 15, *) {
            SMAppService.openSystemSettingsLoginItems()
            return
        }
        for candidate in ["x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension",
                          "x-apple.systempreferences:com.apple.preference.security"] {
            if let url = URL(string: candidate), NSWorkspace.shared.open(url) { return }
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
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
                // A socket bound to the physical interface's address would leave by that interface
                // whatever the routing table says. libwebrtc gathers on the tunnel interface for the
                // relays (measured with a utun in CI); enforced routes, documented to supersede such
                // scoping for the included routes (only the relays' subnets; includeAllNetworks
                // stays off), are a second line.
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
            let status = manager?.connection.status
            // A tunnel nothing needs — left running by a quit, a crash or a force quit — is stopped.
            if routes.isEmpty, registering == 0, status == .connected || status == .connecting || status == .reasserting {
                log.notice("stopping a tunnel no profile uses")
                manager?.connection.stopVPNTunnel()
            }
            state = manager?.connection.status == .connected ? .connected : .ready
        } catch {
            log.error("VPN configuration: \(error.localizedDescription, privacy: .public)")
            state = install ? .failed(error.localizedDescription) : .needsConfiguration
        }
    }

    /// Every load gives a new manager object, with a new connection object: the observer follows it.
    private func observeStatus() {
        guard let connection = manager?.connection, connection !== observedConnection else { return }
        if let statusObserver { NotificationCenter.default.removeObserver(statusObserver) }
        observedConnection = connection
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
        guard proxy.kind == .socks5, let port = UInt16(exactly: proxy.port), !Self.isInsideTunnel(proxy.host) else { return nil }
        registering += 1
        defer { registering -= 1 }
        let current = await knownState()
        guard current == .ready || current == .connected else { return nil }
        unregister(profile: id)
        // The slot is taken before anything is awaited: profiles launched together get different ones.
        let used = Set(routes.values.map(\.relayIPv4))
        guard let slot = TunnelAddressing.slots.first(where: { !used.contains(TunnelAddressing.relayIPv4(slot: $0)) }) else { return nil }
        let route = TunnelRoute(id: UUID().uuidString, relayIPv4: TunnelAddressing.relayIPv4(slot: slot),
                                relayIPv6: TunnelAddressing.relayIPv6(slot: slot),
                                username: Self.randomToken(8), password: Self.randomToken(16),
                                proxy: SOCKSProxy(host: proxy.host, port: port, username: proxy.username, password: proxy.password))
        routes[id] = route
        let connected = await connect()
        if !connected { log.notice("tunnel did not connect; WebRTC stays off for this profile") }
        guard connected, await send(.register(route)), routes[id] == route else {
            if routes[id] == route { routes[id] = nil }
            if !connected {
                await loadConfiguration(install: false) // switched off by another VPN, removed, …
            } else if routes.isEmpty, registering == 1, let connection = manager?.connection {
                connection.stopVPNTunnel() // started for this route alone
            }
            return nil
        }
        startHeartbeat()
        return WebRTCRelay(urls: route.turnURLs, username: route.username, credential: route.password)
    }

    func unregister(profile id: UUID) {
        guard let route = routes.removeValue(forKey: id) else { return }
        if routes.isEmpty, registering == 0 {
            // Nothing left to relay: stop the tunnel (and the VPN indicator) until it is needed, at
            // once — a quit does not wait for the extension's answer.
            heartbeat?.invalidate()
            heartbeat = nil
            if let connection = manager?.connection, connection.status != .disconnected { connection.stopVPNTunnel() }
        } else {
            Task { _ = await send(.unregister(id: route.id)) }
        }
    }

    private func startHeartbeat() {
        guard heartbeat == nil else { return }
        heartbeat = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.routes.isEmpty else { return }
                Task { _ = await self.send(.status) }
            }
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

    /// A proxy on the tunnel's own subnets could never be reached through it.
    private static func isInsideTunnel(_ host: String) -> Bool {
        guard let ip = IPAddr(host) else { return false }
        return ip.isIn(TunnelAddressing.ipv4Network, length: TunnelAddressing.ipv4PrefixLength)
            || ip.isIn(TunnelAddressing.ipv6Network, length: TunnelAddressing.ipv6PrefixLength)
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
            pendingRequest = nil
            pendingIsActivation = false
            switch result {
            case .completed:
                let install = activationInstalls
                Task { await loadConfiguration(install: install) }
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
            let activation = pendingIsActivation
            pendingRequest = nil
            pendingIsActivation = false
            // A refresh that fails (an extension never activated) just means it is off.
            guard activation else {
                state = .off
                return
            }
            switch (error as? OSSystemExtensionError)?.code {
            case .requestCanceled?: state = .off
            case .unsupportedParentBundleLocation?: state = .failed(L("tunnel.error.location"))
            case .missingEntitlement?, .codeSignatureInvalid?, .validationFailed?, .extensionNotFound?, .extensionMissingIdentifier?:
                state = .failed(L("tunnel.error.signing"))
            case .authorizationRequired?: state = .failed(L("tunnel.error.authorization"))
            case .forbiddenBySystemPolicy?: state = .failed(L("tunnel.error.policy"))
            default: state = .failed(error.localizedDescription)
            }
        }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, foundProperties properties: [OSSystemExtensionProperties]) {
        MainActor.assumeIsolated {
            pendingRequest = nil
            extensionProperties(properties)
        }
    }
}
