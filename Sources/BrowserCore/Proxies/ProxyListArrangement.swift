import Foundation

/// Which proxies of the list the Proxies section shows: all of them, or those in one state — what
/// a person looks for after checking a few hundred ("which are dead", "which did I not check",
/// "which are free").
public enum ProxyListFilter: String, CaseIterable, Sendable {
    case all
    /// Answered at their last check.
    case working
    /// Did not answer at their last check (or asked for a login the entry has not).
    case failing
    /// Never checked.
    case unchecked
    /// No profile uses them.
    case unused

    /// `profiles`: how many profiles use the entry (`ProxyList.identity(of:)`).
    public func includes(_ entry: ProxyListEntry, usedBy profiles: Int) -> Bool {
        switch self {
        case .all: return true
        case .working: return entry.lastCheck?.isAlive == true
        case .failing: return entry.lastCheck.map { !$0.isAlive } ?? false
        case .unchecked: return entry.lastCheck == nil
        case .unused: return profiles == 0
        }
    }
}

/// The order the Proxies section shows its rows in — a click on a column's title.
public enum ProxyListOrder: String, CaseIterable, Sendable {
    /// As they were added: the list's own order.
    case added
    /// By the name shown (the label, or the address without one), numbers by their value.
    case name
    /// By the country their last check found, by its name; those without one after the others.
    case country
    /// The fastest first; then those that answered without a measure, the unchecked, the dead.
    case latency
    /// What needs attention first: those that failed their last check, the unchecked, the working.
    case state

    /// `entries` in this order. Entries that compare the same keep the order they were given in.
    /// `countryName`: a country code's name as the list shows it.
    public func sorted(_ entries: [ProxyListEntry], countryName: (String) -> String) -> [ProxyListEntry] {
        if self == .added { return entries }
        // Each entry's key is found once, not at every comparison.
        let keyed: [(offset: Int, entry: ProxyListEntry, text: String?, number: Int)] = entries.enumerated().map { offset, entry in
            switch self {
            case .added:
                return (offset, entry, nil, 0)
            case .name:
                return (offset, entry, entry.displayName, 0)
            case .country:
                let code = entry.lastCheck?.isAlive == true ? entry.lastCheck?.countryCode : nil
                return (offset, entry, code.map(countryName), 0)
            case .latency:
                return (offset, entry, nil, Self.latencyRank(entry.lastCheck))
            case .state:
                return (offset, entry, nil, Self.stateRank(entry.lastCheck))
            }
        }
        return keyed.sorted { a, b in
            if a.number != b.number { return a.number < b.number }
            switch (a.text, b.text) {
            case let (first?, second?):
                let order = ProfileListOrder.compareNames(first, second)
                if order != .orderedSame { return order == .orderedAscending }
            case (.some, .none):
                return true
            case (.none, .some):
                return false
            case (.none, .none):
                break
            }
            return a.offset < b.offset
        }.map { $0.entry }
    }

    /// Milliseconds for a proxy that answered with a measure; above any of them, in turn: one that
    /// answered without a measure, one never checked, one that did not answer.
    static func latencyRank(_ check: ProxyCheckResult?) -> Int {
        guard let check else { return Int.max - 1 }
        guard check.isAlive else { return Int.max }
        return check.latencyMilliseconds.map { min(max($0, 0), Int.max - 3) } ?? Int.max - 2
    }

    static func stateRank(_ check: ProxyCheckResult?) -> Int {
        guard let check else { return 1 }
        return check.isAlive ? 2 : 0
    }
}

extension ProxyList {
    /// The country most of `codes` name (ISO 3166-1 alpha-2, in any case), upper case; of two as
    /// common, the first by the alphabet, so that the answer is the same every time; nil for none.
    public static func commonCountry(_ codes: [String]) -> String? {
        var counts: [String: Int] = [:]
        for code in codes where !code.isEmpty { counts[code.uppercased(), default: 0] += 1 }
        return counts.max { a, b in a.value != b.value ? a.value < b.value : a.key > b.key }?.key
    }

    /// The proxies to offer in place of `entry` for the `count` profiles that use it (a proxy that
    /// stopped answering): only those that answered at their last check and whose type is known,
    /// never `entry` itself; first those of `country` — where the profiles were last seen to come
    /// out, so that their time zone and language still fit — then, within each, those no profile
    /// uses yet (a mobile proxy is meant for one profile), the faster before the slower, then in
    /// the list's order. At most `count` of them, each once; empty when none answers.
    public static func replacements(for entry: ProxyListEntry, among entries: [ProxyListEntry], count: Int,
                                    country: String?, used: Set<String>) -> [ProxyListEntry] {
        let working = entries.filter { $0.id != entry.id && $0.kindKnown && $0.lastCheck?.isAlive == true }
        let ranked = working.enumerated().sorted { a, b in
            func rank(_ candidate: ProxyListEntry) -> Int {
                let elsewhere = country.map { candidate.lastCheck?.countryCode?.caseInsensitiveCompare($0) != .orderedSame } ?? false
                return (elsewhere ? 2 : 0) + (used.contains(identity(of: candidate.proxy)) ? 1 : 0)
            }
            let (ra, rb) = (rank(a.element), rank(b.element))
            if ra != rb { return ra < rb }
            let la = a.element.lastCheck?.latencyMilliseconds ?? Int.max
            let lb = b.element.lastCheck?.latencyMilliseconds ?? Int.max
            if la != lb { return la < lb }
            return a.offset < b.offset
        }.map { $0.element }
        return Array(ranked.prefix(max(count, 1)))
    }
}
