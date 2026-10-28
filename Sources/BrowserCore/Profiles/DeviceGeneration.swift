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
///   * The macOS generation declares the host's own Safari version at runtime
///     (`userAgent(hostSafariVersion:)`); its catalog string below is only the fallback. A mobile
///     generation of the host's release declares the host's major.minor; one of another release
///     keeps its catalog string and is offered only to profiles that have it. Mobile
///     UA strings are the ones Safari sends on that OS: from iOS 26.1 on, Safari freezes the OS
///     token at "18_7" (as macOS Safari freezes "10_15_7"; WebKit bug 298260) and only
///     "Version/" names the release, so "iPhone OS 26_0" is a string no Safari sends. iPadOS
///     Safari asks for desktop websites by default and then sends the Mac's UA. The Version
///     tokens go stale as Apple ships updates: keep them current, or type a custom UA copied
///     from the real device you want to resemble.
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

    /// The User-Agent this generation declares on a Mac whose Safari is `hostSafariVersion`
    /// (e.g. "26.0.1"). The engine-matching macOS generation names that version: Safari and
    /// WKWebView render with the same system WebKit, so any other version would contradict the
    /// engine a page can measure. "Intel Mac OS X 10_15_7" is genuine — every Safari since
    /// macOS 11 freezes the OS version at that value. A mobile generation of the engine's own
    /// major (`isOfEngine`) names the engine's release as major.minor; another keeps its catalog
    /// UA, whose Version token would announce a release the engine is not.
    public func userAgent(hostSafariVersion: String?) -> String {
        guard let version = hostSafariVersion, Self.isSafariVersion(version) else { return userAgent }
        if matchesEngine {
            return "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/\(version) Safari/605.1.15"
        }
        guard isOfEngine(hostSafariVersion: version),
              let token = userAgent.range(of: "Version/[0-9.]+", options: .regularExpression) else { return userAgent }
        let parts = version.split(separator: ".")
        return userAgent.replacingCharacters(in: token, with: "Version/\(parts[0]).\(parts.count > 1 ? parts[1] : "0")")
    }

    /// Whether this generation's OS release is the one the Mac's Safari — the engine — belongs to
    /// (its major). An unknown host version counts as a match: nothing is hidden on a guess.
    public func isOfEngine(hostSafariVersion: String?) -> Bool {
        guard let version = hostSafariVersion, Self.isSafariVersion(version) else { return true }
        return version.split(separator: ".").first.map(String.init) == osVersionLabel
    }

    /// What Safari writes after "Version/": "26", "26.0", "26.0.1".
    public static func isSafariVersion(_ text: String) -> Bool {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        return (1...3).contains(parts.count) && parts.allSatisfy { part in
            (1...3).contains(part.count) && part.unicodeScalars.allSatisfy { ("0"..."9").contains($0) }
        }
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
            userAgent: "Mozilla/5.0 (iPhone; CPU iPhone OS 18_7 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/27.0 Mobile/15E148 Safari/604.1",
            matchesEngine: false, defaultWebRTCPolicy: .disabled, behaviorSetID: mobileBehavior),
        DeviceGeneration(
            id: "ios-26", nameKey: "gen.ios26", platform: .iOS, osVersionLabel: "26",
            userAgent: "Mozilla/5.0 (iPhone; CPU iPhone OS 18_7 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.6 Mobile/15E148 Safari/604.1",
            matchesEngine: false, defaultWebRTCPolicy: .disabled, behaviorSetID: mobileBehavior),
        DeviceGeneration(
            id: "ipados-26", nameKey: "gen.ipados26", platform: .iPadOS, osVersionLabel: "26",
            // Safari's default on an iPad: the desktop website, with the Mac's UA.
            userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.6 Safari/605.1.15",
            matchesEngine: false, defaultWebRTCPolicy: .disabled, behaviorSetID: mobileBehavior),
    ]

    public static func generation(id: String?) -> DeviceGeneration? {
        guard let id else { return nil }
        return all.first { $0.id == id }
    }

    /// The Safari version macOS `major.minor` ships with, for when Safari's own bundle cannot be
    /// read: macOS 14 shipped Safari 17.0–17.6 and macOS 15 Safari 18.0–18.6 (minor following
    /// the OS minor); from macOS 26 on Safari carries the OS version. A newer Safari installed on
    /// an older macOS is only seen through Safari's bundle.
    public static func bundledSafariVersion(macOSMajor major: Int, minor: Int) -> String {
        switch major {
        case ..<26: return "\(major + 3).\(min(max(minor, 0), 6))"
        default: return "\(major).\(max(minor, 0))"
        }
    }

    /// What the device picker offers on a Mac whose Safari is `hostSafariVersion`: the macOS
    /// generation and the mobile ones of the engine's release; one of another release only where
    /// a profile already has it (`current`), so it can be seen and changed.
    public static func selectable(hostSafariVersion: String?, current: String?) -> [DeviceGeneration] {
        all.filter { $0.matchesEngine || $0.isOfEngine(hostSafariVersion: hostSafariVersion) || $0.id == current }
    }

    /// The generation for `id`, or the default generation if `id` is nil/unknown.
    public static func resolved(id: String?) -> DeviceGeneration {
        generation(id: id) ?? all.first { $0.id == defaultID } ?? all[0]
    }
}
