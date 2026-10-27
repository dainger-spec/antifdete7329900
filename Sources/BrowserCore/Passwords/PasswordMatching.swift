import Foundation

/// A web origin a saved password belongs to: http or https, a host, a port. Built from the URL of
/// a page or, in the browser, from the frame's `WKSecurityOrigin` (never from what a page script
/// says about itself).
public struct WebOrigin: Hashable, Sendable {
    public let scheme: String
    /// Lower case, without brackets for IPv6.
    public let host: String
    /// Always explicit: 443 / 80 for the scheme's default.
    public let port: Int

    /// `port` 0 (how `WKSecurityOrigin` reports the scheme's default) is the default port. Nil for
    /// any other scheme, and for an opaque origin (no host: a sandboxed frame, `data:`).
    public init?(scheme: String, host: String, port: Int) {
        let scheme = scheme.lowercased()
        guard scheme == "http" || scheme == "https", (0...65535).contains(port) else { return nil }
        var host = host.lowercased()
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        if host.hasSuffix(".") { host.removeLast() }
        guard !host.isEmpty else { return nil }
        self.scheme = scheme
        self.host = host
        self.port = port == 0 ? Self.defaultPort(scheme) : port
    }

    public init?(url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme, let host = components.host else { return nil }
        self.init(scheme: scheme, host: host, port: components.port ?? 0)
    }

    /// Parses a serialized origin (`PasswordEntry.origin`).
    public init?(_ string: String) {
        guard let url = URL(string: string) else { return nil }
        self.init(url: url)
    }

    private static func defaultPort(_ scheme: String) -> Int { scheme == "https" ? 443 : 80 }

    public var isDefaultPort: Bool { port == Self.defaultPort(scheme) }

    /// `scheme://host[:port]`, the port only when it is not the default: how entries store it.
    public var serialized: String {
        let hostPart = host.contains(":") ? "[\(host)]" : host
        return isDefaultPort ? "\(scheme)://\(hostPart)" : "\(scheme)://\(hostPart):\(port)"
    }

    /// The site, as Safari groups saved passwords: the registrable domain (`example.co.uk` for
    /// `login.example.co.uk`, `PublicSuffixList`), or the host itself for an IP address,
    /// `localhost` or a name under a public suffix only.
    public var site: String { PublicSuffixList.registrableDomain(of: host) ?? host }
}

/// Which saved logins a page is offered, and what a sign-in on it means for the vault.
///
/// As Safari: logins are grouped by site, so one saved on `example.com` is offered on
/// `login.example.com` (the page's own host first), and a public suffix keeps unrelated sites
/// apart (`alice.github.io` never sees `bob.github.io`'s). Stricter than Safari in one way, as
/// Chrome and Firefox are: a login saved on an https page is never offered on an http page, where
/// the network could read it. One saved on http is offered on the https page of the same site.
public enum PasswordMatching {
    /// Saved logins that may be offered on (and filled into) a page of `page`, best first: the
    /// page's own origin, then the same host by another scheme, then the rest of the site; most
    /// recently used first within each.
    public static func candidates(_ entries: [PasswordEntry], for page: WebOrigin) -> [PasswordEntry] {
        let scored: [(entry: PasswordEntry, rank: Int)] = entries.compactMap { entry in
            guard let origin = WebOrigin(entry.origin), offers(origin, on: page) else { return nil }
            let rank = origin == page ? 0 : origin.host == page.host ? 1 : 2
            return (entry, rank)
        }
        return scored.sorted { a, b in
            if a.rank != b.rank { return a.rank < b.rank }
            let usedA = a.entry.lastUsedAt ?? a.entry.updatedAt, usedB = b.entry.lastUsedAt ?? b.entry.updatedAt
            if usedA != usedB { return usedA > usedB }
            return a.entry.username < b.entry.username
        }.map(\.entry)
    }

    /// Whether a login saved on `saved` may be offered on a page of `page`.
    public static func offers(_ saved: WebOrigin, on page: WebOrigin) -> Bool {
        guard saved.site == page.site else { return false }
        // Never an https login on an http page; http on https is the same site, upgraded.
        guard page.scheme == "https" || saved.scheme == "http" else { return false }
        return saved.port == page.port || (saved.isDefaultPort && page.isDefaultPort)
    }

    public enum SaveDecision: Equatable, Sendable {
        /// Saved already (on this page's origin, or for this user name elsewhere on the site).
        case alreadySaved
        /// A new login for the page's origin.
        case save
        /// The user name is saved on the site with another password: offer to update that entry.
        case update(PasswordEntry)
    }

    /// What signing in on `page` as `username` with `password` means for `entries`.
    public static func decision(username: String, password: String, at page: WebOrigin,
                                entries: [PasswordEntry]) -> SaveDecision {
        let sameUser = entries.filter { $0.username == username }
        if let exact = sameUser.first(where: { WebOrigin($0.origin) == page }) {
            return exact.password == password ? .alreadySaved : .update(exact)
        }
        let related = candidates(sameUser, for: page)
        if related.contains(where: { $0.password == password }) { return .alreadySaved }
        // One login for this user on the site: the password changed there. Several: save a new one
        // for this page rather than guess which.
        if related.count == 1 { return .update(related[0]) }
        return .save
    }

    /// Whether `page` is on a site the user answered "Never for This Website" for.
    public static func isNeverSaved(_ page: WebOrigin, sites: [String]) -> Bool {
        sites.contains { WebOrigin($0)?.site == page.site }
    }
}
