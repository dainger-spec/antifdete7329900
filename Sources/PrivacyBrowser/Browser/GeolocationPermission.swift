import Foundation
import WebKit

/// Geolocation for a profile that denies it (the default), answered by WebKit itself: the page
/// meets the engine's own `getCurrentPosition`, `GeolocationPositionError` and `PermissionStatus`,
/// and the shim leaves `navigator.geolocation` and `navigator.permissions` alone (`PrivacyScripts`).
///
/// WebKit asks the UI delegate whether a frame may have the position and what state a site's
/// permission has (`WKUIDelegatePrivate`, the methods Safari implements; `BrowserTab` answers them).
/// The answers are a user's who said no: the request is denied, and the site's state is 'denied'
/// once a page of it asked (until the tab shows another page), 'prompt' before. WebKit adds its own
/// rule for a fresh `navigator.permissions.query` (macOS 26: 'denied' only to a document that asked,
/// with or without these answers); a PermissionStatus the page already holds reads the delegate's
/// answer as it is when told of a change (`+[WKWebView _permissionChanged:forOrigin:]`), so it turns
/// 'denied' and fires 'change' instead of staying 'prompt'. WebKit asks only for a page in view: a
/// request from a page out of sight waits until it is shown, as in Safari. Every other permission is
/// answered 'prompt', what WebKit reports for them with a delegate that does not answer (the
/// self-test compares them).
///
/// PLATFORM LIMITATION: private API, and nothing to detect: WebKit calls the delegate methods it
/// knows, and on the Mac denies a request no delegate answers. The answer is per tab and site, not
/// per document: a status a frame of the site's page holds turns 'denied' when the page asks, where a
/// fresh query in that frame says 'prompt'. WebKit before macOS 26 reports a geolocation 'denied'
/// as 'prompt'.
enum GeolocationPermission {
    /// `+[WKWebView _permissionChanged:forOrigin:]` (a class method; macOS 26.6.2 has it): the
    /// PermissionStatus objects of the origin's pages read the state again and fire 'change' when
    /// it differs.
    static let permissionChanged = NSSelectorFromString("_permissionChanged:forOrigin:")

    /// Tells the pages of `origin` that `name`'s state may have changed, where WebKit can.
    @MainActor
    static func announceChange(of name: String, for origin: WKSecurityOrigin) {
        let webViewClass: AnyObject = WKWebView.self
        guard webViewClass.responds(to: permissionChanged) else { return }
        _ = webViewClass.perform(permissionChanged, with: name, with: origin)
    }

    /// A site as its permission state is kept: the origin's scheme, host and port (0 for the
    /// scheme's default, as `WKSecurityOrigin` gives it).
    @MainActor
    static func site(_ origin: WKSecurityOrigin) -> String {
        "\(origin.protocol.lowercased())://\(origin.host.lowercased()):\(origin.port)"
    }

    /// The same for the page a tab shows (its top origin), nil without one.
    @MainActor
    static func site(of url: URL?) -> String? {
        guard let url, let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased() else { return nil }
        let defaultPort = scheme == "https" ? 443 : scheme == "http" ? 80 : nil
        let port = url.port.flatMap { $0 == defaultPort ? nil : $0 } ?? 0
        return "\(scheme)://\(host):\(port)"
    }
}
