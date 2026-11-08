import AppKit
import BrowserCore
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
@MainActor
enum PhoneEngine {
    static func phone(of configuration: ProfileConfiguration) -> PhoneDevice? {
        configuration.deviceGeneration.platform == .iOS ? configuration.deviceGeneration.phone : nil
    }

    /// Every web view a profile's session makes (`BrowserSession.makeWebViewConfiguration`).
    static func apply(to webConfiguration: WKWebViewConfiguration, for configuration: ProfileConfiguration) {
        guard phone(of: configuration) != nil else { return }
        WebKitPreferences.setBool(webConfiguration.preferences, "_setNotificationsEnabled:", false)
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
