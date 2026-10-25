import Foundation

/// A target Apple OS "generation" a profile can be tagged with (the iStealth-style
/// version-aware idea). It bundles the **self-declared** signals that a profile can actually
/// control for a given iOS/iPadOS/macOS version: the `User-Agent` string, a suggested set of
/// defaults, and the id of the behaviour set (injected-script bundle) to use.
///
/// HONEST SCOPE — read before assuming more than this does:
///   * Choosing a generation changes the **declared** `User-Agent` (HTTP header +
///     `navigator.userAgent`) and some per-profile defaults. Nothing else.
///   * It does NOT switch the real WebKit core. The engine is always the macOS system WebKit
///     of the Mac the app runs on. Shipping or loading a different WebKit build (an older iOS
///     core, say) is not possible through public API; it needs the private/internal WebKit
///     frameworks, or bundling and running a separate engine.
///   * Only the macOS desktop generation (`matchesEngine == true`) is actually consistent with
///     the engine, and even then only when its version equals the host's real Safari version.
///     iOS/iPadOS generations change the UA string while every measured signal (rendering,
///     feature set, touch behaviour, TLS) still says "desktop Mac" — detectable, not emulation.
///   * UA strings here are illustrative and go stale as Apple ships new versions. Keep them
///     current, or type a custom UA copied from the real device/version you want to resemble.
///
/// The `behaviorSetID` field is the forward-looking extension point: when Apple ships a new
/// WebKit version with behaviours worth matching, a new behaviour set can be registered and
/// pointed at from new generations here, without touching the profile format or the rest of
/// the app (see `BehaviorSets` in the app layer).
public struct DeviceGeneration: Identifiable, Equatable, Sendable {
    public enum Platform: String, Codable, Sendable, CaseIterable {
        case macOS, iOS, iPadOS
    }

    public let id: String
    /// Localization key for the display name (resolved by the app layer).
    public let nameKey: String
    public let platform: Platform
    /// Marketing OS version, e.g. "26", "27".
    public let osVersionLabel: String
    public let userAgent: String
    /// True only for the macOS desktop family — the only one consistent with the real engine.
    public let matchesEngine: Bool
    /// Suggested default when a new profile picks this generation.
    public let defaultWebRTCPolicy: WebRTCPolicy
    /// Which injected-script behaviour set this generation uses (extension point).
    public let behaviorSetID: String

    public init(id: String, nameKey: String, platform: Platform, osVersionLabel: String,
                userAgent: String, matchesEngine: Bool,
                defaultWebRTCPolicy: WebRTCPolicy, behaviorSetID: String) {
        self.id = id
        self.nameKey = nameKey
        self.platform = platform
        self.osVersionLabel = osVersionLabel
        self.userAgent = userAgent
        self.matchesEngine = matchesEngine
        self.defaultWebRTCPolicy = defaultWebRTCPolicy
        self.behaviorSetID = behaviorSetID
    }
}

/// Catalog of selectable generations. Desktop first (recommended), then mobile UA-only ones.
public enum DeviceGenerations {
    /// The generation picked for a new profile and used when a stored id is unknown.
    public static let defaultID = "macos-26"

    /// Behaviour-set identifiers. Both currently resolve to the same WebKit shims (see the app
    /// layer); they exist so future per-generation behaviours have a stable key to hang on.
    public static let desktopBehavior = "desktop"
    public static let mobileBehavior = "mobile"

    public static let all: [DeviceGeneration] = [
        DeviceGeneration(
            id: "macos-26", nameKey: "gen.macos26", platform: .macOS, osVersionLabel: "26",
            userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15",
            matchesEngine: true, defaultWebRTCPolicy: .disabled, behaviorSetID: desktopBehavior),
        DeviceGeneration(
            id: "ios-27", nameKey: "gen.ios27", platform: .iOS, osVersionLabel: "27",
            userAgent: "Mozilla/5.0 (iPhone; CPU iPhone OS 27_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/27.0 Mobile/15E148 Safari/604.1",
            matchesEngine: false, defaultWebRTCPolicy: .disabled, behaviorSetID: mobileBehavior),
        DeviceGeneration(
            id: "ios-26", nameKey: "gen.ios26", platform: .iOS, osVersionLabel: "26",
            userAgent: "Mozilla/5.0 (iPhone; CPU iPhone OS 26_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Mobile/15E148 Safari/604.1",
            matchesEngine: false, defaultWebRTCPolicy: .disabled, behaviorSetID: mobileBehavior),
        DeviceGeneration(
            id: "ipados-26", nameKey: "gen.ipados26", platform: .iPadOS, osVersionLabel: "26",
            userAgent: "Mozilla/5.0 (iPad; CPU OS 26_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Mobile/15E148 Safari/604.1",
            matchesEngine: false, defaultWebRTCPolicy: .disabled, behaviorSetID: mobileBehavior),
    ]

    public static func generation(id: String?) -> DeviceGeneration? {
        guard let id else { return nil }
        return all.first { $0.id == id }
    }

    /// The generation for `id`, or the default generation if `id` is nil/unknown.
    public static func resolved(id: String?) -> DeviceGeneration {
        generation(id: id) ?? all.first { $0.id == defaultID } ?? all[0]
    }
}
