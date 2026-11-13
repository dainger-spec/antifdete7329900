import Foundation

/// The content rule list every web view of a profile with a proxy gets (the app's `ContentRules`
/// compiles it): loads WebKit would otherwise make outside the profile's proxy.
///
///   * Every `ping`-type load. WebKit 7621 and later runs dns-prefetch through the rule lists as a
///     ping, and a prefetch is resolved by this Mac outside the proxy; `<a ping>` goes with it.
///   * Every load to this Mac itself — 127.0.0.0/8, `localhost` and `*.localhost`, `::1`, its
///     IPv4-mapped form, `0.0.0.0` and `::` — from a page that is not itself on this Mac. The
///     system never sends loopback through a proxy (measured: in Safari's chrome a page's fetch to
///     127.0.0.1, localhost and ::1 reached a listener on this Mac directly, CI run 382), so the
///     only fail-closed answer is not at all: a page could otherwise probe which ports this Mac
///     has open, the same set in every profile, and tell the profiles apart from other people's
///     or link them to each other. A page the user opened on this Mac (`http://127.0.0.1:…`) is
///     already local, and keeps its own loads (`unless-top-url`).
///
/// An address may carry a user name and password before its host (`http://x@127.0.0.1:631/`):
/// WebKit matches `url-filter` against the whole URL, user info and all, and loads such an address
/// for an image, a frame, a script, an XHR or a WebSocket — only `fetch()` refuses it. Until the
/// security audit of 12 November 2026 (APP-14) every pattern wanted the host right after the
/// scheme, so `ws://x@127.0.0.1:<port>` went by them all and a page could map this Mac's open
/// ports from any profile; every pattern now starts with `urlStart`, which takes the user info.
public enum ProxiedContentRules {
    /// Changes with the rules, so that WebKit's compiled copy of an earlier list is not reused.
    public static let identifier = "pb-proxied-profile-v3"

    /// How every pattern of this list and of `LocalNetworkRules` starts: a scheme, then a user name
    /// and password if the address has them (`x@`, `user:pass@` — a canonical URL writes any `/`,
    /// `?`, `#` or other `@` in them percent-encoded), then the host. A group with `?` and a negated
    /// set are in WebKit's `url-filter` subset; alternation and counted repetition are not.
    public static let urlStart = #"^[a-z]+://([^/?#@]*@)?"#

    /// URL patterns (WebKit's `url-filter` subset of regular expressions, matched case-insensitively
    /// against the whole canonical URL) of an address on this Mac.
    public static let thisMacURLPatterns: [String] = [
        #"127\.[0-9]+\.[0-9]+\.[0-9]+[:/]"#,
        #"0\.0\.0\.0[:/]"#,
        #"localhost\.?[:/]"#,
        #"[a-z0-9.-]*\.localhost\.?[:/]"#,
        #"\[::1\]"#,
        #"\[::\]"#,
        #"\[::ffff:7f"#,
        // 0.0.0.0 as IPv4-mapped IPv6 (`[::ffff:0.0.0.0]` canonicalizes to it): this Mac too.
        #"\[::ffff:0:0\]"#,
    ].map { urlStart + $0 }

    /// The list, as WebKit's content-blocker JSON.
    public static var json: String {
        var rules: [[String: Any]] = [
            ["trigger": ["url-filter": ".*", "resource-type": ["ping"]], "action": ["type": "block"]],
        ]
        for pattern in thisMacURLPatterns {
            rules.append(["trigger": ["url-filter": pattern, "unless-top-url": thisMacURLPatterns],
                          "action": ["type": "block"]])
        }
        let data = (try? JSONSerialization.data(withJSONObject: rules, options: [.sortedKeys])) ?? Data("[]".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    /// Whether the list blocks a load of `url` (of `resourceType`) made by a page whose top
    /// document is `topURL`, as WebKit would decide it — the self-test's and the unit tests'
    /// reading of the rules, not WebKit's own.
    public static func blocks(_ url: String, resourceType: String = "fetch", topURL: String) -> Bool {
        if resourceType == "ping" { return true }
        let local = { (text: String) in thisMacURLPatterns.contains { matches($0, text) } }
        return local(url) && !local(topURL)
    }

    static func matches(_ pattern: String, _ text: String) -> Bool {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return false }
        return expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
}
