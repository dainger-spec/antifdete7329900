import BrowserCore
import Foundation
import os

/// The one way a proxy that a relay of the app's carries is started, handed over and given up
/// (docs/TUNNEL.md, "Relays"): a VLESS, VMess, Trojan or Shadowsocks link's (Xray, `XrayRelays`) and
/// an OpenVPN connection's (OpenVPN and LumenTunnel, `OpenVPNTunnels`). Each relay's own workings
/// stay its own; what a profile sees of either is the same:
///
/// - **Which.** `ProxySettings.localRelay`: none, `.xray` or `.openVPN`.
/// - **Start.** Before anything asks the proxy — the launch's probe, the location lookup, the
///   process. The relay answers as SOCKS5 on 127.0.0.1, with a user name and password made for this
///   run (`ProxyRoutes.Route`); from then on the proxy is reached through that route alone
///   (`ProxyRoutes`), and with no route, through nothing.
/// - **Hand over.** A profile's own process is given its route on its standard input right after its
///   grant (`routes(for:owner:)`, `ProxyRoutes.encodeRecord`), never in its arguments or environment;
///   it does not start without it, and the kernel holds it to that one port ("tcp-relay-only",
///   `ProfileNetworkGuard`).
/// - **Fail closed.** While a relay is down, nothing is behind its port (an OpenVPN tunnel
///   reconnecting) or the relay is started again on the same port with the same login (Xray, twice a
///   minute at most); a relay that does not come back calls the launch's `onLost` once, and the
///   manager stops the profile and says why (`ProfileManager.relayLost`).
@MainActor
enum LocalRelays {
    private static let log = Logger(subsystem: "PrivacyBrowser", category: "LocalRelays")

    /// Why a relay did not start, in words the person reads (`text`).
    enum Failure: Error {
        /// A link's, and this build has no Xray (or is sandboxed).
        case xrayNotInBuild
        /// A link's Xray ended, or did not answer with its login, in time.
        case xrayDidNotStart
        /// An OpenVPN connection's tunnel did not come up: OpenVPN's own reason.
        case openVPN(OpenVPNTunnels.Failure)

        /// What a launch refused for it says (`ProfileManager.LaunchError`).
        func launchError(name: String) -> ProfileManager.LaunchError {
            switch self {
            case .xrayNotInBuild: return .relayNotInBuild(name: name)
            case .xrayDidNotStart: return .relayDidNotStart(name: name)
            case .openVPN(let failure): return .openVPN(name: name, reason: failure.text)
            }
        }

        /// A failure the person can mend with the login: the check says "needs credentials".
        var isCredentials: Bool {
            guard case .openVPN(let failure) = self else { return false }
            return failure == .credentialsNeeded || failure == .authenticationFailed
        }
    }

    /// An OpenVPN tunnel this step started: its route, under an id of its own in `ProxyRoutes`, and
    /// what its owner is told should it go for good. (Xray's relays keep theirs: `XrayRelays`.)
    private struct Tunnel {
        let registration: UUID
        let route: ProxyRoutes.Route
        let onLost: (@MainActor (String) -> Void)?
    }
    private static var tunnels: [UUID: Tunnel] = [:]
    private static var listensToTunnels = false

    /// Whether this build can run the relay `relay` needs.
    static func isAvailable(_ relay: ProxySettings.LocalRelay) -> Bool {
        switch relay {
        case .xray: return XrayRelays.isAvailable
        case .openVPN: return OpenVPNTunnels.shared.isAvailable
        }
    }

    /// Starts `owner`'s relay for `proxy` — a relay `owner` already has is stopped first — and
    /// returns its route once it answers. `onLost` is called once, with what to say, should the relay
    /// end for good while it is `owner`'s; it is never called after `stop(owner:)`.
    @discardableResult
    static func start(for proxy: ProxySettings, owner: UUID, name: String = "",
                      onLost: (@MainActor (String) -> Void)? = nil) async throws -> ProxyRoutes.Route {
        stop(owner: owner)
        switch proxy.localRelay {
        case .xray?:
            do {
                return try await XrayRelays.shared.start(for: proxy, owner: owner) { _ in
                    onLost?(String(format: L("launch.relayEnded"), name))
                }
            } catch XrayRelays.StartError.notInBuild {
                throw Failure.xrayNotInBuild
            } catch {
                log.error("The link's relay of \(owner.uuidString, privacy: .public) did not start: \(String(describing: error), privacy: .private)")
                throw Failure.xrayDidNotStart
            }
        case .openVPN?:
            listenToTunnels()
            let local: ProxySettings
            do {
                local = try await OpenVPNTunnels.shared.start(profile: owner, proxy: proxy)
            } catch let failure as OpenVPNTunnels.Failure {
                throw Failure.openVPN(failure)
            }
            guard let key = ProxyRoutes.key(of: proxy), let username = local.username, let password = local.password else {
                OpenVPNTunnels.shared.stop(profile: owner)
                throw Failure.openVPN(.ended("no route"))
            }
            let route = ProxyRoutes.Route(port: local.port, username: username, password: password)
            var said: (@MainActor (String) -> Void)?
            if let onLost {
                said = { reason in onLost(String(format: L("launch.openVPNLost"), name, reason)) }
            }
            let tunnel = Tunnel(registration: UUID(), route: route, onLost: said)
            tunnels[owner] = tunnel
            ProxyRoutes.shared.add(route, for: key, id: tunnel.registration)
            return route
        case nil:
            // Never asked for a proxy reached as it is; refused all the same.
            throw Failure.xrayDidNotStart
        }
    }

    /// Stops `owner`'s relay, whichever it is, if it has one: its route goes first, so that nothing
    /// is sent to its port while it ends.
    static func stop(owner: UUID) {
        if let tunnel = tunnels.removeValue(forKey: owner) {
            ProxyRoutes.shared.remove(id: tunnel.registration)
            OpenVPNTunnels.shared.stop(profile: owner)
        }
        XrayRelays.shared.stop(owner: owner)
    }

    /// Every relay (the app quits).
    static func stopAll() {
        for owner in Array(tunnels.keys) { stop(owner: owner) }
        OpenVPNTunnels.shared.stopAll()
        XrayRelays.shared.stopAll()
    }

    /// Relays an earlier run of the app left when it crashed.
    static func endLeftovers() {
        XrayRelays.endLeftovers()
        OpenVPNTunnels.endLeftovers()
    }

    /// `owner`'s own relay's route while it runs — not another profile's on the same proxy
    /// (`ProxyRoutes` keeps the newest for whoever asks by the proxy).
    static func route(owner: UUID) -> ProxyRoutes.Route? {
        if let tunnel = tunnels[owner], OpenVPNTunnels.shared.isRunning(owner) { return tunnel.route }
        return XrayRelays.shared.route(owner: owner)
    }

    /// The routes a profile's own process is given with its grant: its relay's, under the key its
    /// proxy is known by (`ProxyRoutes.key(of:)`); none for a proxy no relay carries, or whose relay
    /// does not run — that process then does not start.
    static func routes(for proxy: ProxySettings?, owner: UUID) -> [String: ProxyRoutes.Route] {
        guard let proxy, let key = ProxyRoutes.key(of: proxy), let route = route(owner: owner) else { return [:] }
        return [key: route]
    }

    /// What `owner`'s process is held to and its WebRTC sent through: its own relay, as the SOCKS5
    /// proxy it is to this Mac, or any other proxy as it is; nil for a proxy whose relay is not
    /// running.
    static func reach(of proxy: ProxySettings, owner: UUID) -> ProxySettings? {
        guard proxy.localRelay != nil else { return proxy }
        return route(owner: owner).map { ProxyRoutes.socks5($0, excludedDomains: proxy.excludedDomains) }
    }

    /// OpenVPN says a tunnel is gone (it ended, or did not come back within its grace): its route
    /// goes, and its owner is told — once.
    private static func listenToTunnels() {
        guard !listensToTunnels else { return }
        listensToTunnels = true
        OpenVPNTunnels.shared.onLost = { owner, failure in
            guard let tunnel = LocalRelays.tunnels.removeValue(forKey: owner) else { return }
            ProxyRoutes.shared.remove(id: tunnel.registration)
            LocalRelays.log.error("The OpenVPN tunnel of \(owner.uuidString, privacy: .public) is gone for good")
            tunnel.onLost?(failure.text)
        }
    }
}
