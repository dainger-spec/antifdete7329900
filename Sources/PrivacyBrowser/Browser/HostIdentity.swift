import AppKit
import BrowserCore
import os

/// The Safari of this Mac, and the Safari a macOS profile names (`DeviceGeneration.userAgent(hostSafariVersion:)`).
/// Safari and every WKWebView usually render with the same system WebKit; when they do not — Safari
/// updated beyond the WebKit this Mac gives apps (CI run 718: Safari 27.2, apps on WebKit 21624.5.1.11.3)
/// — a profile names the Safari of the engine it runs (`SafariVersions.declared`).
@MainActor
enum HostSafari {
    /// Safari.app's version and its own build (the build of the WebKit Safari runs), if readable.
    static let app: (version: String, build: String?)? = {
        let candidates = [NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Safari"),
                          URL(fileURLWithPath: "/Applications/Safari.app")]
        for case let url? in candidates {
            let bundle = Bundle(url: url)
            if let version = bundle?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
               DeviceGeneration.isSafariVersion(version) {
                return (version, bundle?.object(forInfoDictionaryKey: "CFBundleVersion") as? String)
            }
        }
        return nil
    }()

    /// What a macOS profile's User-Agent names, and whether Safari runs this app's WebKit.
    static let declared: SafariVersions.Declared = {
        guard let app else {
            let os = ProcessInfo.processInfo.operatingSystemVersion
            return .init(version: DeviceGenerations.bundledSafariVersion(macOSMajor: os.majorVersion, minor: os.minorVersion),
                         sharesEngine: true)
        }
        return SafariVersions.declared(appVersion: app.version, appBuild: app.build,
                                       webKitBuild: WebKitBuild.version == "?" ? nil : WebKitBuild.version)
    }()

    /// e.g. "26.0.1": the Safari a macOS profile names — this Mac's Safari when it runs this app's
    /// WebKit, else the Safari of that WebKit.
    static var version: String { declared.version }
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
/// the user's own languages — the list Safari on this Mac uses. Never the app's interface language
/// (`InterfaceLanguage`), in either direction: in this process the interface's is set first and
/// this list replaces it for WebKit; in a profile's own process the websites' list is the command
/// line's and the interface's is fixed before anything reads it (`ProfileProcess`,
/// `Localization.pinInterfaceLanguage`). The self-test's group "interface and websites' languages"
/// fails if they are ever linked. The JavaScript shim never overrides navigator.language(s), so
/// the header and the script always agree — a mismatch between them is itself a detection signal.
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
                log.notice("Websites keep seeing \(decided?.first ?? "?", privacy: .private) instead of \(language, privacy: .private) until the app is quit: WebKit's language is set once per run")
            }
            return
        }
        let languages = languages(for: language)
        if !languages.isEmpty {
            // The argument domain: this run only, never written to the app's preferences on disk
            // (the same way WebKit overrides it in its own processes). It also hides the app's UI
            // language from WebKit, which reads the same key.
            var arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
            arguments["AppleLanguages"] = languages
            UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        }
        decided = UserDefaults.standard.stringArray(forKey: "AppleLanguages") ?? []
        log.info("Websites see the languages \(decided?.joined(separator: ",") ?? "", privacy: .private) for this run")
    }

    /// In a profile's own process: the list its command line gave (`-AppleLanguages`), which is
    /// the one WebKit read before anything in the process could change it (CI run 579). Only the
    /// first call counts, as with `decide`.
    static func adoptCommandLine() {
        guard decided == nil else { return }
        let arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        decided = arguments["AppleLanguages"] as? [String] ?? UserDefaults.standard.stringArray(forKey: "AppleLanguages") ?? []
        log.info("Websites see the languages \(decided?.joined(separator: ",") ?? "", privacy: .private) for this run (the process's command line)")
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
