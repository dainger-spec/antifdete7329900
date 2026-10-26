import AppKit
import BrowserCore
import os

/// The Safari of this Mac. Safari and every WKWebView render with the same system WebKit, so
/// its version is the one the macOS generation's User-Agent declares
/// (`DeviceGeneration.userAgent(hostSafariVersion:)`).
@MainActor
enum HostSafari {
    /// e.g. "26.0.1": Safari's bundle version, or — if that cannot be read — the version this
    /// macOS release shipped with.
    static let version: String = {
        let candidates = [NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Safari"),
                          URL(fileURLWithPath: "/Applications/Safari.app")]
        for case let url? in candidates {
            if let version = Bundle(url: url)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
               DeviceGeneration.isSafariVersion(version) {
                return version
            }
        }
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return DeviceGenerations.bundledSafariVersion(macOSMajor: os.majorVersion, minor: os.minorVersion)
    }()
}

/// The language websites see: the `Accept-Language` header, `navigator.language(s)` and the
/// default locale of JavaScript's `Intl` and `Date` formatting.
///
/// PLATFORM LIMITATION: WebKit takes it from this process's `AppleLanguages` once, when it
/// launches its first web or network process, and gives that list to every process — every
/// profile — for the rest of the run (`AuxiliaryProcessProxy::platformOverrideLanguages`). There
/// is no public per-web-view setting (a content rule list's `modify-headers` action only applies
/// for Safari web extensions). So the first profile launched in a run decides: the language of
/// its proxy's country when that is known (`ProfileConfiguration.matchProxyLocation`), otherwise
/// the app's own languages. The JavaScript shim never overrides navigator.language(s), so the
/// header and the script always agree — a mismatch between them is itself a detection signal.
@MainActor
enum WebContentLanguage {
    /// What WebKit was given (`AppleLanguages` as WebKit reads it), once decided.
    private(set) static var decided: [String]?
    private static let log = Logger(subsystem: "PrivacyBrowser", category: "WebContentLanguage")

    /// Call before the first WebKit process launches, i.e. before the first `BrowserSession` is
    /// created. Only the first call counts; WebKit has read the list after it.
    static func decide(_ language: String?) {
        guard decided == nil else {
            if let language, decided?.first != language {
                log.notice("Websites keep seeing \(decided?.first ?? "?", privacy: .public) instead of \(language, privacy: .public) until the app is quit: WebKit's language is set once per run")
            }
            return
        }
        if let language {
            // The argument domain: this run only, never written to the app's preferences on disk
            // (the same way WebKit overrides it in its own processes).
            var arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
            arguments["AppleLanguages"] = [language]
            UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        }
        decided = UserDefaults.standard.stringArray(forKey: "AppleLanguages") ?? []
        log.info("Websites see the languages \(decided?.joined(separator: ",") ?? "", privacy: .public) for this run")
    }
}
