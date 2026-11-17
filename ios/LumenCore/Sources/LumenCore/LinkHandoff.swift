import Foundation

/// A navigation a session's page starts to another host may be taken from the session by an app on
/// the iPhone. On iOS, when a web view's delegate answers `.allow` to a navigation a page started
/// during a tap — a tapped link, a script, a form, in the main frame or a new window — to a host other
/// than the page's, WebKit first offers the address to the app that claims it (a universal link:
/// YouTube, Instagram, Telegram, Amazon…). If one does, the web view loads nothing and the system
/// opens that app, which fetches the address itself: from the iPhone's own address and with the
/// account signed in there, outside the session's proxy and data. A load the app starts itself
/// (`WKWebView.load`) and its redirects are never offered to an app, and neither are frames,
/// back/forward and reloads.
///
/// So a tab holds such a navigation back and loads it again itself — "open here" (`BrowserTab`; the
/// only public way, WebKit's "allow without trying app links" is private). For the hosts in `apps`,
/// whose links an app commonly claims, it first says the link could open in that app and lets the
/// person choose (the owner's decision, 16 November: a warning, not a silent hand-off). A page's
/// POST is not loaded again (its body is the page's to send, not the tab's), nor a window a script
/// opens to a host not in `apps` (the page keeps its popup, as sign-in windows need).
public enum LinkHandoff {
    /// Where a navigation goes.
    public enum Target: Sendable {
        case mainFrame
        case frame
        /// A window the page opens (target=_blank, window.open): it has no frame yet.
        case newWindow
    }

    /// What started it (WebKit's WKNavigationType).
    public enum Kind: Sendable {
        case link
        case form
        case backForward
        case reload
        case other
    }

    /// What the tab does with it.
    public enum Decision: Equatable, Sendable {
        /// As WebKit would: nothing is offered to another app.
        case allow
        /// Held back, and loaded by the tab itself (a new window: in a new tab of the session).
        case openHere
        /// As `openHere`, after the person is told that `app` could open it and chose this session.
        case warn(app: String)
    }

    /// - Parameters:
    ///   - currentHost: the host of the page the tab shows (nil: none yet, as in a new window).
    ///   - method: the request's HTTP method (nil: GET).
    ///   - ownLoad: a load the tab started itself is under way in its main frame (its redirects come
    ///     as `.other`). It never covers a tapped link.
    public static func decide(url: URL, currentHost: String?, target: Target, kind: Kind, method: String?,
                              ownLoad: Bool) -> Decision {
        // The planted fault: every navigation as WebKit would have it, app links and all.
        if Faults.isActive(.appLinksAllowed) { return .allow }
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host?.lowercased(), !host.isEmpty else { return .allow }
        switch kind {
        case .backForward, .reload:
            return .allow
        case .link:
            break
        case .form, .other:
            guard (method ?? "GET").uppercased() == "GET" else { return .allow }
            if kind == .other && ownLoad && target == .mainFrame { return .allow }
        }
        if target == .frame { return .allow }
        if let current = currentHost?.lowercased(), current == host { return .allow }
        let app = self.app(forHost: host)
        if target == .newWindow && kind != .link && app == nil { return .allow }
        return app.map { .warn(app: $0) } ?? .openHere
    }

    /// The apps that commonly claim a host's links, by the name the warning gives them: each domain
    /// with its subdomains. The one list of them (the owner, 16 November).
    public static let apps: [(app: String, domains: [String])] = [
        ("YouTube", ["youtube.com", "youtu.be"]),
        ("Instagram", ["instagram.com"]),
        ("Facebook", ["facebook.com", "fb.com"]),
        ("X", ["x.com", "twitter.com"]),
        ("Telegram", ["t.me", "telegram.me"]),
        ("TikTok", ["tiktok.com"]),
        ("Amazon", ["amazon.com", "amazon.co.uk", "amazon.de", "amazon.fr", "amazon.it", "amazon.es", "amazon.nl",
                    "amazon.se", "amazon.pl", "amazon.com.be", "amazon.com.tr", "amazon.ca", "amazon.com.mx",
                    "amazon.com.br", "amazon.co.jp", "amazon.in", "amazon.com.au", "amazon.sg", "amazon.ae",
                    "amazon.sa", "amazon.eg"]),
        ("App Store", ["apps.apple.com"]),
        ("WhatsApp", ["wa.me", "whatsapp.com"]),
        ("LinkedIn", ["linkedin.com"]),
        ("Reddit", ["reddit.com"]),
        ("Spotify", ["spotify.com"]),
        ("Pinterest", ["pinterest.com"]),
    ]

    /// The app of `apps` that claims `host`, or nil.
    public static func app(forHost host: String) -> String? {
        var name = host.lowercased()
        while name.hasSuffix(".") { name.removeLast() }   // "youtube.com." is youtube.com
        for entry in apps {
            for domain in entry.domains where name == domain || name.hasSuffix("." + domain) {
                return entry.app
            }
        }
        return nil
    }
}
