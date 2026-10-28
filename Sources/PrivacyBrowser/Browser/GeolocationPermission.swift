import Foundation
import WebKit

/// Geolocation for a profile that denies it (the default), answered by WebKit itself: the page
/// meets the engine's own `getCurrentPosition`, `GeolocationPositionError` and `PermissionStatus`,
/// and the shim leaves `navigator.geolocation` and `navigator.permissions` alone (`PrivacyScripts`).
///
/// WebKit asks the UI delegate whether a frame may have the position and what state
/// `navigator.permissions.query` reports for a site (`WKUIDelegatePrivate`, the methods Safari
/// implements; `BrowserTab` answers them). The answers are a user's who said no: the request is
/// denied, and the site's state is 'prompt' until a page of it asked, 'denied' after (until the tab
/// shows another page), and a PermissionStatus the page holds is told of the change
/// (`-[WKWebView _permissionChanged:forOrigin:]`). Every other permission is answered 'prompt',
/// what WebKit reports for them with a delegate that does not answer (the self-test compares them).
///
/// PLATFORM LIMITATION: private API, and nothing to detect: WebKit calls the delegate methods it
/// knows. One it does not call costs only the state after a request ('prompt' instead of
/// 'denied'): on the Mac WebKit denies a request its delegate leaves unanswered by itself.
enum GeolocationPermission {
    /// `-[WKWebView _permissionChanged:forOrigin:]`, where this WebKit has it: a page's
    /// PermissionStatus objects read the state again and fire 'change' when it differs.
    static let permissionChanged = NSSelectorFromString("_permissionChanged:forOrigin:")

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
