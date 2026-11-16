import AppKit
import BrowserCore
import os
import WebKit

/// What WebKit itself answers as an iPhone does, in an iPhone view — in both of its disguises
/// (`PhoneDisguise`), because none of it is a script's: the page's own getters stay the engine's.
///
///   * `navigator.platform` "iPhone": WKWebpagePreferences' `_customNavigatorPlatform`, set on each
///     main frame's navigation (`setPlatform`), which the page and its frames answer from (measured, macOS 26 and 27, claude/measure-native-spoof).
///     Workers answer this Mac's ("MacIntel": `NavigatorBase::platform`), which only a script can
///     change (`PrivacyScripts`, the full disguise).
///   * `devicePixelRatio` 3: WKWebView's `_overrideDeviceScaleFactor`; WebKit renders at 3× and the
///     stylesheet's `resolution` media queries agree (measured, the same branch).
///   * `ApplePaySession`, which an iPhone's Safari has, comes with every profile's web views
///     (`BrowserSession.makeWebViewConfiguration`).
///   * No `Notification`, which an iPhone's Safari has none of outside a web app on the home
///     screen (the owner's iPhone, 8 November): WebKit's `NotificationsEnabled` off.
///   * An iPhone's fonts (`PhoneFonts`): in a profile's own process, the process pool's font allow
///     list — WebKit's own (`WKContextSetFontAllowList`, which its test runner uses to give pages a
///     fixed set of fonts): each web content process the pool starts finds a family by name only
///     when it is on the list, so a font this Mac has and an iPhone has not is not installed for the
///     page — measured through CSS fallback, a canvas's `measureText`, `FontFace` with `local()`,
///     `document.fonts`, in every frame and every worker, because the font lookup itself says so.
///     And CSS `cursive` is an iPhone's (Snell Roundhand, not Apple Chancery), per web view.
@MainActor
enum PhoneEngine {
    static func phone(of configuration: ProfileConfiguration) -> PhoneDevice? {
        configuration.deviceGeneration.platform == .iOS ? configuration.deviceGeneration.phone : nil
    }

    /// Every web view a profile's session makes (`BrowserSession.makeWebViewConfiguration`).
    static func apply(to webConfiguration: WKWebViewConfiguration, for configuration: ProfileConfiguration) {
        guard phone(of: configuration) != nil else { return }
        WebKitPreferences.setBool(webConfiguration.preferences, "_setNotificationsEnabled:", false)
        setCursiveFamily(PhoneFonts.iOSCursiveFamily, on: webConfiguration.preferences)
        // Before the web view exists, so the pool has the list before it starts a process for it.
        restrictFonts(of: webConfiguration)
    }

    // MARK: Fonts

    private typealias SetFontAllowList = @convention(c) (UnsafeRawPointer, UnsafeRawPointer?) -> Void
    private typealias SetFontFamily = @convention(c) (UnsafeRawPointer, UnsafeRawPointer?) -> Void
    private typealias CreateString = @convention(c) (UnsafePointer<CChar>) -> UnsafeRawPointer?
    private typealias CreateArray = @convention(c) (UnsafeMutablePointer<UnsafeRawPointer?>?, Int) -> UnsafeRawPointer?
    private typealias Release = @convention(c) (UnsafeRawPointer) -> Void

    /// WebKit's C API for the fonts, looked up at run time (`NativeGeolocation` does the same for
    /// the geolocation provider): a WKProcessPool is the C API's WKContextRef, a WKPreferences its
    /// WKPreferencesRef — the same objects.
    private struct FontAPI {
        let setAllowList: SetFontAllowList?
        let setCursive: SetFontFamily?
        let createString: CreateString
        let createArray: CreateArray
        let release: Release
    }

    private static let fontAPI: FontAPI? = {
        func symbol<T>(_ name: String, as type: T.Type) -> T? {
            guard let pointer = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) else { return nil } // RTLD_DEFAULT
            return unsafeBitCast(pointer, to: type)
        }
        guard let createString = symbol("WKStringCreateWithUTF8CString", as: CreateString.self),
              let createArray = symbol("WKArrayCreate", as: CreateArray.self),
              let release = symbol("WKRelease", as: Release.self) else { return nil }
        // The name since WebKit renamed its allow lists (2020); the older one before that.
        let setAllowList = symbol("WKContextSetFontAllowList", as: SetFontAllowList.self)
            ?? symbol("WKContextSetFontWhitelist", as: SetFontAllowList.self)
        return FontAPI(setAllowList: setAllowList, setCursive: symbol("WKPreferencesSetCursiveFontFamily", as: SetFontFamily.self),
                       createString: createString, createArray: createArray, release: release)
    }()

    private static let fontLog = Logger(subsystem: "PrivacyBrowser", category: "PhoneFonts")

    /// The families this process's pages may find by name (`PhoneFonts.engineList`), from
    /// `engageFonts` on; nil: every font of the system.
    private(set) static var allowedFonts: [String]?

    /// In a profile's own process, before its first web view: an iPhone view's pages find an
    /// iPhone's fonts only. One profile per process — the list is the process pool's, and so every
    /// web view's of this process. False where this is not an iPhone view or WebKit lacks the API;
    /// the pages then have this Mac's fonts, as before.
    @discardableResult
    static func engageFonts(for configuration: ProfileConfiguration) -> Bool {
        if allowedFonts != nil { return true }
        guard let families = PhoneFonts.allowedFamilies(for: configuration) else { return false }
        guard let api = fontAPI, api.setAllowList != nil else {
            fontLog.notice("WebKit's font allow list is not in this macOS: an iPhone view's pages have this Mac's fonts")
            return false
        }
        allowedFonts = PhoneFonts.engineList(families)
        // The pool a configuration made from now on is given, before any process of it starts.
        restrictFonts(of: WKWebViewConfiguration())
        fontLog.notice("An iPhone view's pages find an iPhone's fonts only (\(families.count, privacy: .public) families)")
        return true
    }

    /// The font allow list on `webConfiguration`'s process pool, once `engageFonts` engaged it. Given
    /// for every web view the process makes or meets (`apply`, `ProfileNetworkGuard`), so that a
    /// pool Safari's code made has it too; the pool hands it to each process it starts afterwards.
    static func restrictFonts(of webConfiguration: WKWebViewConfiguration) {
        guard let list = allowedFonts, let api = fontAPI, let setAllowList = api.setAllowList,
              let pool = webConfiguration.value(forKey: "processPool") as? NSObject else { return }
        var strings: [UnsafeRawPointer?] = list.map { name in name.withCString { api.createString($0) } }
        defer { for case let string? in strings { api.release(string) } }
        guard let array = strings.withUnsafeMutableBufferPointer({ api.createArray($0.baseAddress, $0.count) }) else { return }
        setAllowList(Unmanaged.passUnretained(pool).toOpaque(), array)
        api.release(array)
    }

    /// CSS `cursive` as `family` (WebKit's own preference, as an iPhone's WebKit has it by default).
    private static func setCursiveFamily(_ family: String, on preferences: WKPreferences) {
        guard let api = fontAPI, let setCursive = api.setCursive,
              let string = family.withCString({ api.createString($0) }) else { return }
        setCursive(Unmanaged.passUnretained(preferences).toOpaque(), string)
        api.release(string)
    }

    /// The phone's platform on a main frame's navigation (`BrowserTab`'s navigation delegate).
    /// Never on the configuration's default preferences: WebKit applies those to a frame's
    /// navigation too, and raises for a custom platform there ("_customNavigatorPlatform must be nil
    /// for subframe navigations") — every page with an iframe ended the profile's process (run
    /// 42479119796, tiktok.com and Google, macOS 26 and 27). The page's frames answer from their
    /// main frame's.
    static func setPlatform(_ platform: String?, on preferences: WKWebpagePreferences, mainFrame: Bool) {
        guard let platform, mainFrame else { return }
        let setter = NSSelectorFromString("_setCustomNavigatorPlatform:")
        if preferences.responds(to: setter) { preferences.perform(setter, with: platform) }
    }

    /// Each tab's web view (`BrowserTab`).
    static func apply(to webView: WKWebView, scale: Double?) {
        guard let scale else { return }
        let setter = NSSelectorFromString("_setOverrideDeviceScaleFactor:")
        guard webView.responds(to: setter), let method = class_getInstanceMethod(type(of: webView), setter) else { return }
        typealias Set = @convention(c) (AnyObject, Selector, CGFloat) -> Void
        unsafeBitCast(method_getImplementation(method), to: Set.self)(webView, setter, CGFloat(scale))
    }
}
