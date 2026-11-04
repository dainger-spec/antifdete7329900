import Foundation

/// Where the network guard stands: the system extension that lets the processes of a profile
/// whose WebRTC goes through its proxy reach that proxy and nothing else (docs/TUNNEL.md). A
/// proxied profile gets WebRTC only while it is `ready`; anything else keeps the engine's WebRTC
/// off for that profile, and says why.
public enum NetworkGuardState: String, Codable, Equatable, Sendable, CaseIterable {
    /// This build has no guard in it.
    case notInBuild
    /// In the build, never installed (or removed).
    case notInstalled
    /// Installation asked; macOS waits for the person to allow it in System Settings.
    case awaitingApproval
    /// Installed, and switched off: in System Settings, or its filter configuration declined.
    case off
    /// On, but it does not answer: not running, being replaced by an update's, or a version other
    /// than this app's.
    case notAnswering
    /// Installed and switched on, but macOS starts it only at the next restart: an earlier copy is
    /// still there, "terminated waiting to uninstall on reboot", and until then the new one does
    /// not answer (the owner's Mac, 0.1.2, macOS 27.0.1, 4 November).
    case restartNeeded
    /// On and answering, but this Mac has not shown that the guard tells a profile's connections
    /// from everyone else's (the check after installing, and after each update of macOS).
    case unproven
    /// On, answering, this app's version, and proven on this Mac.
    case ready
}

/// What is known of a proxy's UDP: a SOCKS5 UDP ASSOCIATE, a STUN answer through it, and whether
/// it leaves from the address the proxy's TCP leaves from — the one sites see the pages come from.
public enum ProxyUDPSupport: String, Codable, Equatable, Sendable, CaseIterable {
    case unknown
    /// The proxy relays UDP, and from the address its TCP leaves from.
    case supported
    /// It does not: UDP ASSOCIATE refused, or nothing came back through the association.
    case unsupported
    /// It relays UDP, but from another address than its TCP: a site would see two addresses, which
    /// tells it the profile goes through a proxy.
    case elsewhere
    /// It relays UDP, but the address its TCP leaves from could not be found out: the two cannot be
    /// compared.
    case exitUnknown
}

/// Why a profile that wants WebRTC runs without it. Each one is said to the person in words
/// (`launch.webrtcOff.*`), with what they can do about it, where there is something.
public enum WebRTCRefusal: String, Codable, Equatable, Sendable, CaseIterable {
    case guardNotInBuild
    case guardNotInstalled
    case guardAwaitingApproval
    case guardOff
    case guardNotAnswering
    case guardRestartNeeded
    case guardUnproven
    /// An HTTP CONNECT proxy carries TCP only.
    case httpProxy
    /// The proxy refused UDP ASSOCIATE, or no STUN answer came back through it.
    case proxyWithoutUDP
    /// The proxy's UDP leaves from another address than its TCP.
    case proxyUDPElsewhere
    /// Where the proxy's TCP leaves from could not be found out, so its UDP could not be compared.
    case proxyExitUnknown
    /// Whether the proxy relays UDP could not be found out before the profile started.
    case proxyUDPUnknown
    /// A profile that runs inside the app's own process (the build with the App Sandbox): the guard
    /// tells profiles apart by their processes, and this one has none of its own.
    case notOwnProcess
    /// The guard did not take this profile's process, or the relay could not start.
    case notRegistered
}

/// What a launch does with a profile's WebRTC.
public enum WebRTCLaunchDecision: Equatable, Sendable {
    /// No proxy: the engine's own WebRTC as the profile's setting says.
    case native(WebRTCPolicy)
    /// Off in the engine. Without a reason, the profile's own setting (Disabled).
    case off(WebRTCRefusal?)
    /// Through the relay and the profile's proxy, held there by the network guard.
    case relay
}

/// The one place that decides whether a proxied profile gets WebRTC. Fail closed: the relay only
/// when every condition holds, with the first one that does not as the reason.
public enum WebRTCGate {
    public static func decide(policy: WebRTCPolicy, proxy: ProxySettings?, ownProcess: Bool,
                              guardState: NetworkGuardState, udp: ProxyUDPSupport) -> WebRTCLaunchDecision {
        if policy == .disabled { return .off(nil) }
        guard let proxy else { return .native(policy) }
        // What the person can change about the proxy comes first: no guard makes HTTP carry UDP.
        guard proxy.kind == .socks5 else { return .off(.httpProxy) }
        switch guardState {
        case .notInBuild: return .off(.guardNotInBuild)
        case .notInstalled: return .off(.guardNotInstalled)
        case .awaitingApproval: return .off(.guardAwaitingApproval)
        case .off: return .off(.guardOff)
        case .notAnswering: return .off(.guardNotAnswering)
        case .restartNeeded: return .off(.guardRestartNeeded)
        case .unproven: return .off(.guardUnproven)
        case .ready: break
        }
        guard ownProcess else { return .off(.notOwnProcess) }
        switch udp {
        case .supported: return .relay
        case .unsupported: return .off(.proxyWithoutUDP)
        case .elsewhere: return .off(.proxyUDPElsewhere)
        case .exitUnknown: return .off(.proxyExitUnknown)
        case .unknown: return .off(.proxyUDPUnknown)
        }
    }

    /// Whether a launch needs to ask anything at all (the guard, the proxy's UDP): only a profile
    /// with a SOCKS5 proxy whose WebRTC is not Disabled.
    public static func wantsRelay(policy: WebRTCPolicy, proxy: ProxySettings?) -> Bool {
        policy != .disabled && proxy?.kind == .socks5
    }
}

/// What macOS's answers about the guard come to, where they need reading together.
public enum NetworkGuardReading {
    /// A guard macOS reports installed and switched on that does not answer (or answers without its
    /// filter, or as another version): `earlierCopyAwaitsRestart` when macOS also keeps an earlier
    /// copy of it that is to be removed at the next restart (`OSSystemExtensionProperties.isUninstalling`,
    /// `systemextensionsctl list`: "terminated waiting to uninstall on reboot").
    public static func silent(earlierCopyAwaitsRestart: Bool) -> NetworkGuardState {
        earlierCopyAwaitsRestart ? .restartNeeded : .notAnswering
    }
}
