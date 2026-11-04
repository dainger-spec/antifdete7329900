import Foundation

/// Whether a profile's pages may reach this Mac and the local network (`ProfileConfiguration.localRequests`).
public enum LocalRequests: String, Codable, Sendable, CaseIterable {
    /// A page from the internet cannot reach this Mac or the local network (the default).
    case protected
    /// It can, as in Safari.
    case allowed
}

/// The content rule list of a profile that protects its local requests and has no proxy
/// (`ProfileConfiguration.blocksLocalNetwork`; the app's `ContentRules` compiles it).
///
/// A page from the internet could otherwise load from this Mac and from the local network —
/// `127.0.0.1:<port>`, `192.168.1.1`, a printer's `.local` name — and learn from what answers
/// which ports this Mac has open and which devices share its network: the same in every profile,
/// so something that tells the profiles apart from other people's, or links them to each other.
/// Every load to an address on this Mac (`ProxiedContentRules.thisMacURLPatterns`) or on a
/// private network is blocked, unless the page itself is on this Mac or that network (its own
/// loads are the user's). A profile with a proxy needs none of it: this Mac is blocked by the
/// proxied list already (the system never sends loopback through a proxy), and a private address
/// goes through the proxy, to the proxy's network rather than this one.
public enum LocalNetworkRules {
    /// Changes with the rules, so that WebKit's compiled copy of an earlier list is not reused.
    public static let identifier = "pb-local-network-v1"

    /// Addresses on a private network as WebKit writes them in a URL (WebKit's `url-filter`
    /// subset: no alternation, so each range is spelled out), matched case-insensitively.
    public static let localNetworkURLPatterns: [String] = [
        #"^[a-z]+://10\.[0-9]+\.[0-9]+\.[0-9]+[:/]"#,
        #"^[a-z]+://192\.168\.[0-9]+\.[0-9]+[:/]"#,
        #"^[a-z]+://172\.1[6-9]\.[0-9]+\.[0-9]+[:/]"#,
        #"^[a-z]+://172\.2[0-9]\.[0-9]+\.[0-9]+[:/]"#,
        #"^[a-z]+://172\.3[01]\.[0-9]+\.[0-9]+[:/]"#,
        #"^[a-z]+://169\.254\.[0-9]+\.[0-9]+[:/]"#,
        // 100.64.0.0/10: carrier-grade NAT, and the address space of mesh VPNs.
        #"^[a-z]+://100\.6[4-9]\.[0-9]+\.[0-9]+[:/]"#,
        #"^[a-z]+://100\.[7-9][0-9]\.[0-9]+\.[0-9]+[:/]"#,
        #"^[a-z]+://100\.1[01][0-9]\.[0-9]+\.[0-9]+[:/]"#,
        #"^[a-z]+://100\.12[0-7]\.[0-9]+\.[0-9]+[:/]"#,
        // IPv6: unique local (fc00::/7) and link-local (fe80::/10).
        #"^[a-z]+://\[f[cd][0-9a-f]*:"#,
        #"^[a-z]+://\[fe[89ab][0-9a-f]*:"#,
        // The same IPv4 ranges written as IPv4-mapped IPv6, as a URL canonicalizes them.
        #"^[a-z]+://\[::ffff:a[0-9a-f][0-9a-f]:"#,
        #"^[a-z]+://\[::ffff:c0a8:"#,
        #"^[a-z]+://\[::ffff:ac1[0-9a-f]:"#,
        #"^[a-z]+://\[::ffff:a9fe:"#,
        #"^[a-z]+://\[::ffff:64[4-7][0-9a-f]:"#,
        // Names only the local network answers.
        #"^[a-z]+://[a-z0-9.-]*\.local\.?[:/]"#,
        #"^[a-z]+://[a-z0-9.-]*\.home\.arpa\.?[:/]"#,
        #"^[a-z]+://[a-z0-9.-]*\.lan\.?[:/]"#,
        #"^[a-z]+://[a-z0-9.-]*\.internal\.?[:/]"#,
    ]

    /// This Mac and the local network.
    public static var patterns: [String] { ProxiedContentRules.thisMacURLPatterns + localNetworkURLPatterns }

    /// The list, as WebKit's content-blocker JSON.
    public static var json: String {
        let all = patterns
        let rules: [[String: Any]] = all.map { pattern in
            ["trigger": ["url-filter": pattern, "unless-top-url": all], "action": ["type": "block"]]
        }
        let data = (try? JSONSerialization.data(withJSONObject: rules, options: [.sortedKeys])) ?? Data("[]".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    /// Whether the list blocks a load of `url` made by a page whose top document is `topURL`, as
    /// WebKit would decide it — the unit tests' and the self-test's reading of the rules.
    public static func blocks(_ url: String, topURL: String) -> Bool {
        let local = { (text: String) in patterns.contains { ProxiedContentRules.matches($0, text) } }
        return local(url) && !local(topURL)
    }
}
