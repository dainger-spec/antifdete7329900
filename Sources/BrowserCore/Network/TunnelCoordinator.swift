import Foundation

/// Enforces the one hard platform rule of the unified tunnel: a `NEPacketTunnelProvider` on macOS
/// captures the **whole app's** traffic, not one `WKWebView`'s. So at most one profile can route
/// through the tunnel at a time — if a second tunnelled profile started, the first profile's
/// packets would leave through the second's exit.
///
/// This is the platform-independent, testable half of the rule. The app's `ProfileTunnelController`
/// calls `canStart` before bringing a tunnel up and refuses the launch (fail-closed) if it returns
/// a reason. Profiles with no tunnel (direct or TCP-only proxy) are unaffected and may run
/// alongside each other and alongside the one tunnelled profile.
public struct TunnelCoordinator: Equatable, Sendable {
    /// The profile whose tunnel is currently up, if any.
    public private(set) var activeProfile: UUID?

    public init() {}

    public enum Refusal: Equatable, Sendable {
        /// Another profile already holds the app-wide tunnel.
        case anotherTunnelActive(UUID)
    }

    /// Whether `profile` may bring the tunnel up now. nil = yes; otherwise the reason.
    public func canStart(_ profile: UUID) -> Refusal? {
        if let active = activeProfile, active != profile { return .anotherTunnelActive(active) }
        return nil
    }

    /// Records that `profile`'s tunnel is up. Precondition: `canStart(profile) == nil`.
    public mutating func started(_ profile: UUID) {
        activeProfile = profile
    }

    /// Records that `profile`'s tunnel is down (no-op if it wasn't the active one).
    public mutating func stopped(_ profile: UUID) {
        if activeProfile == profile { activeProfile = nil }
    }
}
