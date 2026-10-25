import Foundation

/// Ready-made `User-Agent` strings for the per-profile user agent.
///
/// IMPORTANT / HONEST SCOPE: a preset only changes the *self-declared* `User-Agent` string
/// (the HTTP header and `navigator.userAgent`). It does NOT change the rendering engine, the
/// JavaScript feature set, touch/pointer behaviour, the TLS/HTTP2 fingerprint, or any of the
/// hardware/graphics signals (see docs/ISOLATION_AND_LIMITATIONS.md §2). The engine is always
/// the macOS system WebKit.
///
/// Therefore:
///   * `matchesEngine == true` presets (Safari on macOS) are *consistent* with what a site
///     actually measures, so they are the recommended, least-distinctive choice.
///   * `matchesEngine == false` presets (Safari on iPhone/iPad) make the UA claim a device
///     that the rest of the fingerprint contradicts. They are offered for completeness and for
///     sites that only read the UA string, but they are detectable and are NOT device emulation.
///
/// These strings go stale as Safari ships new versions; keep them current or type a custom UA
/// copied from the real device/browser you want to resemble.
public struct UserAgentPreset: Identifiable, Equatable, Sendable {
    public let id: String
    /// Localization key for the display name (resolved by the app layer).
    public let nameKey: String
    public let userAgent: String
    /// True when the UA is consistent with this app's actual engine (macOS WebKit / Safari).
    public let matchesEngine: Bool

    public init(id: String, nameKey: String, userAgent: String, matchesEngine: Bool) {
        self.id = id
        self.nameKey = nameKey
        self.userAgent = userAgent
        self.matchesEngine = matchesEngine
    }
}

public enum UserAgentPresets {
    /// Engine-consistent first (recommended), then UA-only device claims.
    public static let all: [UserAgentPreset] = [
        UserAgentPreset(
            id: "safari-macos",
            nameKey: "ua.preset.safariMac",
            userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.6 Safari/605.1.15",
            matchesEngine: true),
        UserAgentPreset(
            id: "safari-iphone",
            nameKey: "ua.preset.safariIPhone",
            userAgent: "Mozilla/5.0 (iPhone; CPU iPhone OS 17_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.6 Mobile/15E148 Safari/604.1",
            matchesEngine: false),
        UserAgentPreset(
            id: "safari-ipad",
            nameKey: "ua.preset.safariIPad",
            userAgent: "Mozilla/5.0 (iPad; CPU OS 17_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.6 Mobile/15E148 Safari/604.1",
            matchesEngine: false),
    ]

    public static func preset(id: String) -> UserAgentPreset? {
        all.first { $0.id == id }
    }

    /// The preset whose UA string equals `userAgent`, if any.
    public static func matching(userAgent: String?) -> UserAgentPreset? {
        guard let userAgent else { return nil }
        return all.first { $0.userAgent == userAgent }
    }
}
