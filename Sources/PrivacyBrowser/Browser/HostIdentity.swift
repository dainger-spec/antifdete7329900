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
/// PLATFORM LIMITATION: WebKit hands each process this process's `AppleLanguages` when it launches
/// it (`AuxiliaryProcessProxy::populateOverrideLanguagesLaunchOptions`), and on macOS every profile
/// shares one network process, where CFNetwork writes `Accept-Language` with the list it was
/// launched with; a later list never reaches it (`WebProcessPool::setOverrideLanguages` updates
/// network processes only on libsoup ports). There is no public per-web-view setting (a content
/// rule list's `modify-headers` action needs the private `_activeContentRuleListActionPatterns`
/// and misses loads the network process starts). Docs §6. So the first profile launched in a run
/// decides: the language of
/// its proxy's country when that is known (`ProfileConfiguration.matchProxyLocation`), otherwise
/// the user's own languages — the list Safari on this Mac uses, not the app's UI language (which
/// `Localization.applyProcessLanguage` keeps in the app's own domain). The JavaScript shim never
/// overrides navigator.language(s), so the header and the script always agree — a mismatch
/// between them is itself a detection signal.
@MainActor
enum WebContentLanguage {
    /// What WebKit was given (`AppleLanguages` as WebKit reads it), once decided.
    private(set) static var decided: [String]?
    private static let log = Logger(subsystem: "PrivacyBrowser", category: "WebContentLanguage")

    /// Call before the first WebKit process launches, i.e. before the first `BrowserSession` is
    /// created. Only the first call counts; WebKit has read the list after it. `locale` (e.g.
    /// "ja_JP") also becomes this process's `AppleLocale`: a profile's own process sets both, as a
    /// launch with `-AppleLanguages` and `-AppleLocale` would (docs/PROCESS_PER_PROFILE.md).
    static func decide(_ language: String?, locale: String? = nil) {
        guard decided == nil else {
            if let language, decided?.first != language {
                log.notice("Websites keep seeing \(decided?.first ?? "?", privacy: .public) instead of \(language, privacy: .public) until the app is quit: WebKit's language is set once per run")
            }
            return
        }
        let languages = languages(for: language)
        if !languages.isEmpty || locale != nil {
            // The argument domain: this run only, never written to the app's preferences on disk
            // (the same way WebKit overrides it in its own processes). It also hides the app's UI
            // language from WebKit, which reads the same key.
            var arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
            if !languages.isEmpty { arguments["AppleLanguages"] = languages }
            if let locale { arguments["AppleLocale"] = locale }
            UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        }
        decided = UserDefaults.standard.stringArray(forKey: "AppleLanguages") ?? []
        log.info("Websites see the languages \(decided?.joined(separator: ",") ?? "", privacy: .public) for this run")
    }

    /// What WebKit reports for `language` at the head of its list (`navigator.language`,
    /// `Accept-Language`): it runs the list through `[NSLocale minimizedLanguagesFromLanguages:]`
    /// (WTF `LanguageCF.cpp` `platformUserPreferredLanguages`, `LanguageCocoa.mm`), as in Safari,
    /// so "ja-JP" is reported as "ja" while "de-DE" stays. `language` itself where this macOS has
    /// no such method.
    static func reported(_ language: String) -> String {
        let selector = NSSelectorFromString("minimizedLanguagesFromLanguages:")
        guard let method = class_getClassMethod(NSLocale.self, selector) else { return language }
        typealias Minimize = @convention(c) (AnyObject, Selector, NSArray) -> Unmanaged<NSArray>?
        let minimize = unsafeBitCast(method_getImplementation(method), to: Minimize.self)
        let minimized = minimize(NSLocale.self as AnyObject, selector, [language] as NSArray)?.takeUnretainedValue() as? [String]
        return minimized?.first?.replacingOccurrences(of: "_", with: "-") ?? language
    }

    /// The `AppleLocale` of a language tag with a region: "ja-JP" → "ja_JP"; nil without a region.
    static func appleLocale(for language: String) -> String? {
        let parts = language.split(separator: "-").map(String.init)
        guard parts.count >= 2, let region = parts.last, region.count == 2 else { return nil }
        return "\(parts[0])_\(region.uppercased())"
    }

    /// The list WebKit is given: the proxy country's language, else the user's own languages.
    static func languages(for language: String?) -> [String] {
        if let language { return [language] }
        return systemLanguages
    }

    /// What Safari reads: the user's preferred languages from the global domain, without this
    /// app's own `AppleLanguages` (the UI language); if none are set, the user's region locale.
    static var systemLanguages: [String] {
        func global(_ key: String) -> Any? {
            CFPreferencesCopyValue(key as CFString, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        }
        if let languages = global("AppleLanguages") as? [String], !languages.isEmpty { return languages }
        if let locale = global("AppleLocale") as? String, !locale.isEmpty {
            return [locale.split(separator: "@")[0].replacingOccurrences(of: "_", with: "-")]
        }
        return ["en-US"]
    }
}
