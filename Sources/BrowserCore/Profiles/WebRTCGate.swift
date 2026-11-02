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
    /// On and answering, but this Mac has not shown that the guard tells a profile's connections
    /// from everyone else's (the check after installing, and after each update of macOS).
    case unproven
    /// On, answering, this app's version, and proven on this Mac.
    case ready
}

/// What is known of a proxy's UDP: a SOCKS5 UDP ASSOCIATE, and a STUN answer through it.
public enum ProxyUDPSupport: String, Codable, Equatable, Sendable {
    case unknown
    /// The proxy relays UDP: a STUN server answered through its association.
    case supported
    /// It does not: UDP ASSOCIATE refused, or nothing came back through the association.
    case unsupported
}

/// Why a profile that wants WebRTC runs without it. Each one is said to the person in words
/// (`launch.webrtcOff.*`), with what they can do about it, where there is something.
public enum WebRTCRefusal: String, Codable, Equatable, Sendable, CaseIterable {
    case guardNotInBuild
    case guardNotInstalled
    case guardAwaitingApproval
    case guardOff
    case guardNotAnswering
    case guardUnproven
    /// An HTTP CONNECT proxy carries TCP only.
    case httpProxy
    /// The proxy refused UDP ASSOCIATE, or no STUN answer came back through it.
    case proxyWithoutUDP
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
        case .unproven: return .off(.guardUnproven)
        case .ready: break
        }
        guard ownProcess else { return .off(.notOwnProcess) }
        switch udp {
        case .supported: return .relay
        case .unsupported: return .off(.proxyWithoutUDP)
        case .unknown: return .off(.proxyUDPUnknown)
        }
    }

    /// Whether a launch needs to ask anything at all (the guard, the proxy's UDP): only a profile
    /// with a SOCKS5 proxy whose WebRTC is not Disabled.
    public static func wantsRelay(policy: WebRTCPolicy, proxy: ProxySettings?) -> Bool {
        policy != .disabled && proxy?.kind == .socks5
    }
}
