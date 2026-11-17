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

/// What the profiles window says at its foot when WebRTC through a proxy cannot work (the lead,
/// 7 November): only while the guard really does not work — not installed, waiting for the
/// person's approval, switched off, not answering, or waiting for a restart of the Mac — and
/// only when some profile wants it: a SOCKS5 proxy (the kind that carries UDP) with WebRTC not
/// switched off. Nothing while macOS is still being asked (`checking`: the guard starts as "not
/// installed" until its answer comes), in a build without the guard, or when the guard answers
/// but its check on this Mac has not passed (`unproven`: the settings page says that one).
public enum WebRTCProtectionNotice: String, Equatable, Sendable, CaseIterable {
    case restartNeeded
    case notInstalled
    case awaitingApproval
    case off
    case notAnswering

    public static func notice(state: NetworkGuardState, checking: Bool,
                              profilesWantingIt: Bool) -> WebRTCProtectionNotice? {
        guard profilesWantingIt, !checking else { return nil }
        switch state {
        case .restartNeeded: return .restartNeeded
        case .notInstalled: return .notInstalled
        case .awaitingApproval: return .awaitingApproval
        case .off: return .off
        case .notAnswering: return .notAnswering
        case .notInBuild, .unproven, .ready: return nil
        }
    }

    /// A profile that would carry WebRTC through its proxy if the guard worked.
    public static func wants(proxyKind: ProxySettings.Kind?, webRTC: WebRTCPolicy) -> Bool {
        (proxyKind == .socks5 || proxyKind == .xray) && webRTC != .disabled
    }
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
        guard proxy.carriesUDP else { return .off(.httpProxy) }
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
        policy != .disabled && proxy?.carriesUDP == true
    }

    /// Whether WebRTC that must not connect (`decide` said `.off`) can stay in the pages, as Safari
    /// has it, connecting nowhere (`WebRTCRouting.silent`) — rather than be removed, which no Safari
    /// shows. The page's script gives the engine relay-only with no ICE server, so it gathers and
    /// sends nothing; but a script is not a wall, so this is allowed only where a page that got
    /// past it still could not show another address than the profile's pages show:
    ///   * without a proxy: the engine's own WebRTC goes out as this Mac, as the pages do;
    ///   * with a proxy, only once the network guard holds the profile's own process to its proxy,
    ///     dropping every other flow — and only for a proxy that every site goes through (with sites
    ///     that bypass it, holding the process would cut them off).
    /// Anything else keeps WebRTC out of the pages, as before. Fail closed: `.afterHold` is a
    /// promise only once the hold was taken; a hold refused leaves WebRTC removed.
    public static func silence(proxy: ProxySettings?, ownProcess: Bool, guardState: NetworkGuardState) -> WebRTCSilence {
        guard let proxy else { return .withoutHold }
        guard proxy.excludedDomains.isEmpty, ownProcess, guardState == .ready else { return .no }
        return .afterHold
    }

    /// Whether the manager decides a launch's WebRTC for a profile in its own process, which then
    /// waits for its word (`WebRTCLaunchMessage`): every profile with a proxy, since with one the
    /// manager alone can have the network guard hold the process — for the relay, or to keep a
    /// WebRTC that must not connect in the pages (`silence`).
    public static func managerDecides(proxy: ProxySettings?) -> Bool { proxy != nil }

    /// Whether the person is told, at a launch, why WebRTC is off. Not when it was their choice
    /// (no reason), and not for Automatic with an HTTP proxy: Automatic means "the way the
    /// connection goes", and an HTTP proxy's way carries no UDP — nothing to do about it.
    public static func tells(_ reason: WebRTCRefusal?, automatic: Bool) -> Bool {
        guard let reason else { return false }
        return !(automatic && reason == .httpProxy)
    }

    /// The reason a proxied profile's WebRTC waits for the guard in `state`; nil when it is ready.
    public static func guardRefusal(_ state: NetworkGuardState) -> WebRTCRefusal? {
        switch state {
        case .notInBuild: return .guardNotInBuild
        case .notInstalled: return .guardNotInstalled
        case .awaitingApproval: return .guardAwaitingApproval
        case .off: return .guardOff
        case .notAnswering: return .guardNotAnswering
        case .restartNeeded: return .guardRestartNeeded
        case .unproven: return .guardUnproven
        case .ready: return nil
        }
    }

    /// What a profile's WebRTC comes to at its next launch, as far as can be said before it: the
    /// editor and the inspector say it in words (`WebRTCOutlook`). A SOCKS5 proxy is taken to carry
    /// UDP from its pages' address; the launch checks that, and keeps WebRTC present and connecting
    /// nowhere where it does not (`.throughProxy` says so).
    public static func outlook(mode: WebRTCMode, proxy: ProxySettings?, ownProcess: Bool,
                               guardState: NetworkGuardState) -> WebRTCOutlook {
        let policy = mode == .automatic ? WebRTCPolicy.unrestricted : (mode.policy ?? .disabled)
        guard let proxy else { return policy == .disabled ? .silentByChoice : .native(policy) }
        let decision = decide(policy: policy, proxy: proxy, ownProcess: ownProcess, guardState: guardState, udp: .supported)
        if decision == .relay { return .throughProxy }
        if silence(proxy: proxy, ownProcess: ownProcess, guardState: guardState) == .afterHold {
            return policy == .disabled ? .silentByChoice : .silentHTTPProxy
        }
        // Why it cannot stay in the pages: the guard first, which the person can do something about.
        if !proxy.excludedDomains.isEmpty, guardState == .ready, ownProcess { return .removedBypass }
        if let refusal = guardRefusal(guardState) { return .removed(refusal) }
        if !ownProcess { return .removed(.notOwnProcess) }
        return .removed(nil)
    }
}

/// Whether WebRTC that must not connect can stay in a profile's pages (`WebRTCGate.silence`).
public enum WebRTCSilence: Equatable, Sendable {
    /// Without a proxy: nothing a page could get past the script would show another address than
    /// its pages show.
    case withoutHold
    /// With a proxy: once the network guard holds the profile's process to it, and only then.
    case afterHold
    /// Removed from the pages, as before.
    case no
}

/// What a profile's WebRTC comes to at its next launch (`WebRTCGate.outlook`), said by the editor
/// and the inspector under the choice.
public enum WebRTCOutlook: Equatable, Sendable {
    /// No proxy: the engine's own — Unrestricted as Safari's, over this Mac's connection (the address
    /// the pages show); Relay only, through a site's own TURN server only.
    case native(WebRTCPolicy)
    /// Through the SOCKS5 proxy's relay, from the proxy's address, held there by the network guard;
    /// present and connecting nowhere if the proxy's UDP does not hold at the launch.
    case throughProxy
    /// Disabled: present as in Safari, connecting nowhere.
    case silentByChoice
    /// An HTTP proxy carries no UDP: present as in Safari, connecting nowhere.
    case silentHTTPProxy
    /// Removed from the pages, as before: the reason (the guard not ready, profiles inside the app);
    /// nil for none to name.
    case removed(WebRTCRefusal?)
    /// Removed: the proxy has sites that bypass it, so the guard cannot hold the process to it.
    case removedBypass
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
