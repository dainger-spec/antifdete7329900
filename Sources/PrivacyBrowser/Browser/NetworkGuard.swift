import BrowserCore
import Foundation
import os

/// The app's side of the network guard: the system extension that lets the processes of a profile
/// whose WebRTC goes through its proxy reach that proxy and nothing else (docs/TUNNEL.md). Its
/// state is one input of `WebRTCGate`; while it is anything but `ready`, every proxied profile
/// runs with WebRTC off in the engine and is told why.
///
/// This build has no guard in it yet: the state is `notInBuild`. The self-test can stand in for the
/// guard — CI cannot load a system extension — for the profiles it starts itself, so that the relay
/// they get is the product's own; a launch the person makes never has a stand-in.
@MainActor
final class NetworkGuard {
    static let shared = NetworkGuard()

    /// Set by the self-test only (`SelfTest`), around the profiles it starts.
    var selfTestStandIn = false
    /// The processes held to their proxies, for `release`.
    private var held: Set<pid_t> = []
    private let log = Logger(subsystem: "PrivacyBrowser", category: "NetworkGuard")

    var state: NetworkGuardState { selfTestStandIn ? .ready : .notInBuild }

    /// Asks the guard to hold the process `pid` — a profile's own process, and what WebKit's
    /// processes do on its behalf — to `proxy`. False when it did not: the profile then runs with
    /// WebRTC off.
    func hold(pid: pid_t, proxy: ProxySettings) async -> Bool {
        guard state == .ready else { return false }
        if selfTestStandIn {
            log.notice("Self-test: the guard's place is taken by a stand-in for process \(pid, privacy: .public)")
            held.insert(pid)
            return true
        }
        return false
    }

    /// The process is gone or its profile stopped.
    func release(pid: pid_t) {
        held.remove(pid)
    }
}
