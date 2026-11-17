import Foundation

/// A target Apple OS "generation" a profile can be tagged with (the iStealth-style
/// version-aware idea). It bundles the **self-declared** signals that a profile can actually
/// control for a given macOS version: the `User-Agent` string, a suggested set of defaults, and
/// the id of the behaviour set (injected-script bundle) to use.
///
/// HONEST SCOPE — read before assuming more than this does:
///   * Choosing a generation changes the **declared** `User-Agent` (HTTP header +
///     `navigator.userAgent`) and some per-profile defaults. Nothing else.
///   * It does NOT switch the real WebKit core. The engine is always the macOS system WebKit
///     of the Mac the app runs on. Shipping or loading a different WebKit build is not possible
///     through public API; it needs the private/internal WebKit frameworks, or bundling and
///     running a separate engine.
///   * The macOS generation (`matchesEngine == true`) is consistent with the engine when its
///     version equals the host's real Safari version, which it declares at runtime
///     (`userAgent(hostSafariVersion:)`); its catalog string below is only the fallback.
///
/// The iPhone and iPad views a profile could once be are gone (the owner, 16 November): their ids
/// are `DeviceGenerations.retiredIDs`, and a profile stored with one opens as a Mac's.
///
/// The `behaviorSetID` field is the forward-looking extension point: when Apple ships a new
/// WebKit version with behaviours worth matching, a new behaviour set can be registered and
/// pointed at from new generations here, without touching the profile format or the rest of
/// the app (see `BehaviorSets` in the app layer).
public struct DeviceGeneration: Identifiable, Equatable, Sendable {
    public let id: String
    /// Localization key for the display name (resolved by the app layer).
    public let nameKey: String
    /// Marketing OS version, e.g. "26", "27".
    public let osVersionLabel: String
    public let userAgent: String
    /// True for the macOS desktop family — the one consistent with the real engine.
    public let matchesEngine: Bool
    /// Suggested default when a new profile picks this generation.
    public let defaultWebRTCPolicy: WebRTCPolicy
    /// Which injected-script behaviour set this generation uses (extension point).
    public let behaviorSetID: String

    public init(id: String, nameKey: String, osVersionLabel: String,
                userAgent: String, matchesEngine: Bool,
                defaultWebRTCPolicy: WebRTCPolicy, behaviorSetID: String) {
        self.id = id
        self.nameKey = nameKey
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
    /// macOS 11 freezes the OS version at that value.
    public func userAgent(hostSafariVersion: String?) -> String {
        guard matchesEngine, let version = hostSafariVersion, Self.isSafariVersion(version) else { return userAgent }
        return "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/\(version) Safari/605.1.15"
    }

    /// What Safari writes after "Version/": "26", "26.0", "26.0.1".
    public static func isSafariVersion(_ text: String) -> Bool {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        return (1...3).contains(parts.count) && parts.allSatisfy { part in
            (1...3).contains(part.count) && part.unicodeScalars.allSatisfy { ("0"..."9").contains($0) }
        }
    }
}

/// The Safari versions a macOS profile can name in its User-Agent instead of this Mac's own
/// (`ProfileConfiguration.safariVersion`). Naming one changes only what the profile calls itself:
/// the engine is still this Mac's WebKit, and what a page measures of it — its features, its
/// CSS and JavaScript — is still that Safari's.
public enum SafariVersions {
    /// Recent releases, newest first.
    public static let recent = ["27.0", "26.6", "26.5", "26.4", "26.3", "26.2", "26.1", "26.0", "18.6", "18.5", "18.4"]

    /// How far a named version is from the engine.
    public enum Distance: Equatable, Sendable {
        /// The same release (major and minor) as this Mac's Safari.
        case same
        /// Another release of the same major version: what changed between them is small.
        case close
        /// Another major version: what a page measures says the engine is not that version.
        case far
    }

    /// The Safari a macOS profile names: this Mac's Safari (`appVersion`) when Safari runs the WebKit
    /// this app runs, and otherwise the Safari of the WebKit this app runs — a page measures the
    /// engine, so naming another one is a contradiction it can see.
    ///
    /// Safari's own build (its CFBundleVersion, `appBuild`) is the build of the WebKit it runs: on
    /// macOS 26.6.2 and 27.0.1 both are the same as the system WebKit.framework every app loads
    /// (measured: Safari 26.6.2 = 21624.5.1.11.3, Safari 27.0.1 = 22625.1.29.11.28, Safari and its
    /// web processes mapping /System/Library/Frameworks/WebKit.framework). CI run 718, a runner on
    /// macOS 26.7.2 with Safari 27.2: the app ran WebKit 21624.5.1.11.3 while Safari had WebKit 27's
    /// features and its canvas — two engines on one Mac, and the profile called itself Safari 27.2.
    /// The engines are told apart by the builds' first number (21624 against 22…).
    public static func declared(appVersion: String, appBuild: String?, webKitBuild: String?) -> Declared {
        guard let appBuild, let webKitBuild, let appEngine = engine(appBuild), let ours = engine(webKitBuild),
              appEngine != ours else {
            return Declared(version: appVersion, sharesEngine: true)
        }
        if let known = knownBuilds[webKitBuild] { return Declared(version: known, sharesEngine: false) }
        // A build not measured here: its major version, which the first number says from Safari 26
        // on (21xxx is 26, 22xxx is 27), and no minor version this engine might not have.
        return Declared(version: "\(ours / 1000 + 5).0", sharesEngine: false)
    }

    public struct Declared: Equatable, Sendable {
        /// The version a macOS profile's User-Agent names.
        public let version: String
        /// Whether Safari runs the WebKit this app runs (a profile can then be this Mac's Safari).
        public let sharesEngine: Bool

        public init(version: String, sharesEngine: Bool) {
            self.version = version
            self.sharesEngine = sharesEngine
        }
    }

    /// Safari releases by the build of their WebKit, as measured on CI's runners.
    public static let knownBuilds: [String: String] = ["21624.5.1.11.3": "26.6.2", "22625.1.29.11.28": "27.0.1"]

    /// The first number of a WebKit build ("21624" of "21624.5.1.11.3"), from Safari 26 on.
    static func engine(_ build: String) -> Int? {
        guard let first = build.split(separator: ".").first, let number = Int(first), number >= 21000 else { return nil }
        return number
    }

    /// Whether Safari of `version` on a Mac gives pages `window.safari` (its legacy
    /// `pushNotification` object), measured in a plain Safari window (scripts/window_safari_check.py,
    /// run 42471690410, 8 November): Safari 26.6.2 and 27.0.1 do, Safari 27.2 does not — nor the owner's
    /// Safari on his Mac (8 November). Safari 27.1 was not measured; it is counted with 27.0.
    public static func givesWindowSafari(_ version: String) -> Bool {
        let parts = version.split(separator: ".").compactMap { Int($0) }
        guard let major = parts.first else { return false }
        let minor = parts.dropFirst().first ?? 0
        return major < 27 || (major == 27 && minor < 2)
    }

    /// How far `version` is from `host` (this Mac's Safari, e.g. "26.0.1").
    public static func distance(of version: String, fromHost host: String) -> Distance {
        func parts(_ text: String) -> [Int] { text.split(separator: ".").compactMap { Int($0) } }
        let named = parts(version), real = parts(host)
        guard let namedMajor = named.first, let realMajor = real.first, namedMajor == realMajor else { return .far }
        return (named.dropFirst().first ?? 0) == (real.dropFirst().first ?? 0) ? .same : .close
    }
}

/// Catalog of selectable generations: the Mac's.
public enum DeviceGenerations {
    /// The generation picked for a new profile and used when a stored id is unknown.
    public static let defaultID = "macos-26"

    /// Behaviour-set identifier (see the app layer); it exists so future per-generation
    /// behaviours have a stable key to hang on.
    public static let desktopBehavior = "desktop"

    public static let all: [DeviceGeneration] = [
        DeviceGeneration(
            id: "macos-26", nameKey: "gen.macos26", osVersionLabel: "26",
            userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15",
            matchesEngine: true, defaultWebRTCPolicy: .disabled, behaviorSetID: desktopBehavior),
    ]

    /// The iPhone and iPad views' ids, from before they were taken out (the owner, 16 November).
    /// A profile stored, synced or exported with one reads as the default generation, a Mac's
    /// (`migrated(id:)`).
    public static let retiredIDs: Set<String> = ["ios-27", "ios-26", "ipados-26"]

    /// The id a profile keeps: a retired one becomes the default generation's; any other, nil
    /// included, is kept as it is (one a later build knows still resolves to the default).
    public static func migrated(id: String?) -> String? {
        guard let id, retiredIDs.contains(id) else { return id }
        return defaultID
    }

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

    /// The generation for `id`, or the default generation if `id` is nil/unknown.
    public static func resolved(id: String?) -> DeviceGeneration {
        generation(id: id) ?? all.first { $0.id == defaultID } ?? all[0]
    }
}
