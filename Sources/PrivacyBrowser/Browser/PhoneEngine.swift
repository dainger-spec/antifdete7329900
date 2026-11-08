import AppKit
import BrowserCore
import WebKit

/// What WebKit itself answers as an iPhone does, in an iPhone view — in both of its disguises
/// (`PhoneDisguise`), because none of it is a script's: the page's own getters stay the engine's.
///
///   * `navigator.platform` "iPhone": WKWebpagePreferences' `_customNavigatorPlatform`, which the
///     page and its frames answer from (measured, macOS 26 and 27, claude/measure-native-spoof).
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
        guard let phone = phone(of: configuration) else { return }
        let preferences = WKWebpagePreferences()
        let setter = NSSelectorFromString("_setCustomNavigatorPlatform:")
        if preferences.responds(to: setter) { preferences.perform(setter, with: phone.platform) }
        webConfiguration.defaultWebpagePreferences = preferences
        WebKitPreferences.setBool(webConfiguration.preferences, "_setNotificationsEnabled:", false)
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
