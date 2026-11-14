import Foundation

/// Copies of a profile: new profiles set up as it is — the same device, language and time-zone
/// choices, WebRTC, camera, search engine, tags — each with a browsing past of its own (none yet),
/// and with a proxy of its own when asked: the original's, none, or the list's in turn.
///
/// A copy carries nothing that is the original's own: not its data (cookies, history, passwords,
/// bookmarks, website data — a new profile has none), nor what its launches learned (where its
/// proxy came out, `lastProxyLocation`), nor the person's notes about it (they are about that
/// profile's accounts), nor its glyph's colour (a copy is told apart at a glance).
public enum ProfileClone {
    /// At most this many copies at once.
    public static let maximumCopies = 50

    /// The settings a copy starts with, `proxy` its own (nil: none).
    public static func configuration(from original: ProfileConfiguration, proxy: ProxySettings?) -> ProfileConfiguration {
        var copy = original
        copy.proxy = proxy.map { proxy in
            var own = proxy
            // The original's bypass list goes with the original's own proxy only.
            if let theirs = original.proxy, ProxyList.sameConnection(proxy, theirs) {
                own.excludedDomains = theirs.excludedDomains
            } else {
                own.excludedDomains = []
            }
            return own
        }
        copy.lastProxyLocation = nil
        copy.settingsModifiedAt = nil
        copy.webRTCRelay = nil
        copy.notes = ""
        copy.avatar = nil
        return copy
    }

    /// Names for `count` copies of a profile named `name`: "Name 2", "Name 3", … — or, for a name
    /// that already ends in a number ("Shop 4"), on from it ("Shop 5") — never one in `taken`
    /// (compared without case), at most 128 characters each.
    public static func names(for name: String, count: Int, taken: [String]) -> [String] {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var base = trimmed
        var next = 2
        if let space = trimmed.lastIndex(of: " "), let number = Int(trimmed[trimmed.index(after: space)...]), number >= 0, number < 1_000_000 {
            base = String(trimmed[..<space])
            next = number + 1
        }
        if base.isEmpty { base = trimmed.isEmpty ? "Profile" : trimmed }
        var used = Set(taken.map { $0.lowercased() })
        var names: [String] = []
        while names.count < max(0, count) {
            let suffix = " \(next)"
            let candidate = String(base.prefix(128 - suffix.count)) + suffix
            next += 1
            guard used.insert(candidate.lowercased()).inserted else { continue }
            names.append(candidate)
        }
        return names
    }

    /// The proxies of the list for `count` copies, one each in turn: those whose type is known, of
    /// `country` when one is asked (by their last check), those no profile uses yet first — a
    /// mobile proxy is meant for one profile — then those that answered at their last check, then
    /// in the list's order. Fewer proxies than copies: round again (`ProxyList.rotation`). Empty
    /// when none fits.
    public static func proxies(from entries: [ProxyListEntry], count: Int, country: String?,
                               used: Set<String>) -> [ProxyListEntry] {
        let fitting = entries.enumerated().filter { _, entry in
            guard entry.kindKnown else { return false }
            guard let country else { return true }
            return entry.lastCheck?.countryCode?.caseInsensitiveCompare(country) == .orderedSame
        }
        let ordered = fitting.sorted { a, b in
            func rank(_ entry: ProxyListEntry) -> Int {
                (used.contains(ProxyList.identity(of: entry.proxy)) ? 2 : 0) + (entry.lastCheck?.isAlive == true ? 0 : 1)
            }
            let (ra, rb) = (rank(a.element), rank(b.element))
            return ra != rb ? ra < rb : a.offset < b.offset
        }.map(\.element)
        guard !ordered.isEmpty, count > 0 else { return [] }
        return (0..<count).map { ordered[$0 % ordered.count] }
    }
}
