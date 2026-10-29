import Foundation

/// The cookies of one site once a warm-up run is over: how many the profile holds for it, and how
/// many of those the run added. The warm-up screen lists these after a run — the answer to "what
/// did it actually leave behind, and where".
public struct WarmUpCookieSite: Codable, Equatable, Sendable, Identifiable {
    /// The registrable domain (`example.co.uk` for the cookies of `www.example.co.uk` and of
    /// `.example.co.uk` alike), or the host itself for an IP address or a single-label host.
    public var site: String
    /// Cookies the profile holds for the site now.
    public var cookies: Int
    /// Of those, the ones that were not there when the run began.
    public var added: Int

    public var id: String { site }

    public init(site: String, cookies: Int, added: Int) {
        self.site = site
        self.cookies = cookies
        self.added = added
    }
}

/// Counting a profile's cookies per site, before a run and after it.
///
/// "Added" is by identity, not by count: a cookie is one per name, domain and path, as a browser
/// keeps them, so a cookie a page sets again with a new value is not new, and one the run added
/// while another expired still counts. A count taken before and after would call that nothing.
public enum WarmUpCookieCount {
    /// A cookie as a browser tells it apart from the others.
    public struct Cookie: Hashable, Sendable {
        public var name: String
        /// As the store reports it: with a leading dot for a cookie its subdomains get too.
        public var domain: String
        public var path: String

        public init(name: String, domain: String, path: String) {
            self.name = name
            self.domain = domain.lowercased()
            self.path = path.isEmpty ? "/" : path
        }

        /// The site the cookie belongs to (`WarmUpCookieSite.site`).
        public var site: String { WarmUpCookieCount.site(ofCookieDomain: domain) }
    }

    /// At most this many sites are listed, those the run added cookies to first. A profile used for
    /// a long time holds cookies of hundreds of sites, and the list crosses from the profile's own
    /// process to the manager in a report line; the counts the screen shows are the run's anyway.
    public static let maximumSites = 100

    /// How many of `after` were not in `before`.
    public static func added(before: Set<Cookie>, after: [Cookie]) -> Int {
        Set(after).subtracting(before).count
    }

    /// The profile's cookies per site after a run: the sites the run added cookies to first (most
    /// added first), then the rest by how many cookies they hold, then by name. Sites whose last
    /// cookie went during the run are not listed: the list is what the profile holds.
    public static func sites(before: Set<Cookie>, after: [Cookie], limit: Int = maximumSites) -> [WarmUpCookieSite] {
        var bySite: [String: (cookies: Int, added: Int)] = [:]
        for cookie in Set(after) {
            let site = cookie.site
            var counts = bySite[site] ?? (cookies: 0, added: 0)
            counts.cookies += 1
            if !before.contains(cookie) { counts.added += 1 }
            bySite[site] = counts
        }
        let sites = bySite.map { WarmUpCookieSite(site: $0.key, cookies: $0.value.cookies, added: $0.value.added) }
        let ordered = sites.sorted { a, b in
            if a.added != b.added { return a.added > b.added }
            if a.cookies != b.cookies { return a.cookies > b.cookies }
            return a.site < b.site
        }
        return Array(ordered.prefix(max(0, limit)))
    }

    /// The site of a cookie's domain: `.www.example.co.uk` and `example.co.uk` are both
    /// `example.co.uk` (`PublicSuffixList`); an IP address or `localhost` is itself.
    static func site(ofCookieDomain domain: String) -> String {
        var host = domain.lowercased()
        while host.hasPrefix(".") { host.removeFirst() }
        if host.hasSuffix(".") { host.removeLast() }
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        return PublicSuffixList.registrableDomain(of: host) ?? host
    }
}
