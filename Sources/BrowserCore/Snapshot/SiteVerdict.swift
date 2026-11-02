import Foundation

/// What "What sites see" makes of a comparison with this Mac's Safari, for the person who bought the
/// app rather than for us: which signals the profile changes on purpose (where it says it is, what it
/// speaks), which ones should have been the real Safari's and are not, and what each difference is —
/// by the names it is about, not by a count that hides them.

/// A part of the profile's identity: what a profile is for, so it differs from this Mac's Safari on
/// purpose.
public enum IdentityAspect: String, CaseIterable, Sendable {
    /// The time zone and what follows from it: the offset, the date as the browser writes it.
    case timeZone
    /// The languages and the regional settings: navigator's, Intl's, the requests' Accept-Language.
    case language
}

/// What a signal is to the comparison.
public enum SiteSignalRole: Equatable, Sendable {
    /// Set by the profile: a difference from this Mac's Safari is the profile doing its job.
    case identity(IdentityAspect)
    /// Each window's own size, place and history: shown, never compared.
    case perWindow
    /// The engine and the Mac: should be what the real Safari has.
    case engine
}

/// What one difference is, said by what it is about.
public enum SiteDifference: Equatable, Sendable {
    /// Names Safari has and the profile does not (`missing`), and the other way round (`extra`):
    /// properties, features, functions, list items.
    case names(missing: [String], extra: [String])
    /// The same items, in another order.
    case order
    /// A function that looks to a page like one replaced by a script, not the browser's own.
    case replacedFunction(String)
    /// Only Safari reported it: the profile has nothing there at all.
    case onlyInSafari
    /// Only the profile reported it.
    case onlyInProfile
    /// An identity signal that is not what the profile is set to show.
    case notAsSet(expected: String)
    /// Two values, shown side by side.
    case values
}

/// What the profile was set to show sites: the time zone and the first language its launch was given.
/// Nil fields are not known, and nothing is checked against them.
public struct ExpectedIdentity: Equatable, Sendable {
    public var timeZone: String?
    public var language: String?

    public init(timeZone: String?, language: String?) {
        self.timeZone = timeZone
        self.language = language
    }
}

/// A comparison as the panel tells it: how many signals are the real Safari's, which differ on
/// purpose, and which are worth a look.
public struct SiteVerdict: Equatable, Sendable {
    /// Signals compared with Safari's (each window's own are not).
    public var compared: Int
    /// The same as Safari's.
    public var same: Int
    /// Different on purpose: the profile's identity, as it is set.
    public var intended: [SiteSignal]
    /// Should have been Safari's and are not, or are the profile's identity but not as it is set.
    public var attention: [SiteSignal]
    /// Each window's own: shown, not compared.
    public var notCompared: [SiteSignal]
    /// The parts of the identity among `intended`, in `IdentityAspect`'s order.
    public var aspects: [IdentityAspect]
}

extension SiteComparison {
    public static func role(of key: String) -> SiteSignalRole {
        if perWindow(key) { return .perWindow }
        switch key {
        case "probe.timeZone", "probe.tzOffset", "probe.dateString":
            return .identity(.timeZone)
        case "probe.language", "probe.languages", "probe.intlLocale":
            return .identity(.language)
        default:
            if key.hasPrefix("headers."), key.hasSuffix(".accept-language") { return .identity(.language) }
            return .engine
        }
    }

    /// The comparison told: every signal in one of the groups. `expected`: what the profile was set
    /// to show; an identity signal that is not that is worth a look, not "as it should be".
    public static func verdict(_ signals: [SiteSignal], expected: ExpectedIdentity? = nil) -> SiteVerdict {
        let notAsSet = Set(IdentityAspect.allCases.filter { !isAsSet($0, in: signals, expected: expected) })
        var verdict = SiteVerdict(compared: 0, same: 0, intended: [], attention: [], notCompared: [], aspects: [])
        for signal in signals {
            switch (role(of: signal.key), signal.verdict) {
            case (.perWindow, _), (_, .perWindow):
                verdict.notCompared.append(signal)
            case (_, .same):
                verdict.same += 1
            case (.identity(let aspect), .differs) where !notAsSet.contains(aspect):
                verdict.intended.append(signal)
            default:
                verdict.attention.append(signal)
            }
        }
        verdict.compared = verdict.same + verdict.intended.count + verdict.attention.count
        let differing = Set(verdict.intended.compactMap { signal -> IdentityAspect? in
            if case .identity(let aspect) = role(of: signal.key) { return aspect }
            return nil
        })
        verdict.aspects = IdentityAspect.allCases.filter(differing.contains)
        return verdict
    }

    /// What one signal's difference is; nil where there is none to tell (the same, each window's own).
    public static func difference(of signal: SiteSignal, expected: ExpectedIdentity? = nil) -> SiteDifference? {
        switch signal.verdict {
        case .same, .perWindow: return nil
        case .onlySafari: return .onlyInSafari
        case .onlyProfile: return .onlyInProfile
        case .differs: break
        }
        let mine = signal.profile ?? "", theirs = signal.safari ?? ""
        if signal.key == "probe.timeZone", let zone = expected?.timeZone, !sameZone(mine, zone) {
            return .notAsSet(expected: zone)
        }
        if signal.key == "probe.language", let language = expected?.language, !sameLanguage(mine, language) {
            return .notAsSet(expected: language)
        }
        let featurePrefix = "probe.features."
        if signal.key.hasPrefix(featurePrefix) {
            let name = String(signal.key.dropFirst(featurePrefix.count))
            if mine == "undefined" { return .names(missing: [name], extra: []) }
            if theirs == "undefined" { return .names(missing: [], extra: [name]) }
            return .values
        }
        let nativePrefix = "probe.natives."
        if signal.key.hasPrefix(nativePrefix) {
            let name = String(signal.key.dropFirst(nativePrefix.count))
            if mine == "absent" { return .names(missing: [name], extra: []) }
            if theirs == "absent" { return .names(missing: [], extra: [name]) }
            if mine.hasPrefix("TEXT:"), theirs.hasPrefix("native-text") { return .replacedFunction(name) }
            return .values
        }
        if let separator = listSeparator(for: signal.key) {
            let profileItems = items(mine, separator), safariItems = items(theirs, separator)
            let missing = remainder(safariItems, minus: profileItems)
            let extra = remainder(profileItems, minus: safariItems)
            if missing.isEmpty, extra.isEmpty { return .order }
            return .names(missing: missing, extra: extra)
        }
        return .values
    }

    /// The signals whose value is a list, and what separates its items.
    static func listSeparator(for key: String) -> Character? {
        switch key {
        case "probe.plugins", "probe.mimeTypes":
            return "|"
        case "probe.languages", "probe.ownNavigator", "probe.ownScreen", "probe.navigatorProperties",
             "probe.windowProperties", "probe.webgl.extensions", "apis.devices", "tls.versions",
             "tls.cipherSuites", "tls.extensions", "tls.supportedGroups", "tls.signatureAlgorithms", "tls.alpn":
            return ","
        default:
            if key.hasPrefix("headers."), key.hasSuffix(".order") { return "," }
            return nil
        }
    }

    private static func items(_ text: String, _ separator: Character) -> [String] {
        text.split(separator: separator, omittingEmptySubsequences: true).map(String.init)
    }

    /// The items of `list` left after taking away `other`'s, each as many times as it is over, in
    /// `list`'s order.
    private static func remainder(_ list: [String], minus other: [String]) -> [String] {
        var counts: [String: Int] = [:]
        for item in other { counts[item, default: 0] += 1 }
        var left: [String] = []
        for item in list {
            if let count = counts[item], count > 0 {
                counts[item] = count - 1
            } else {
                left.append(item)
            }
        }
        return left
    }

    /// For logs (CI's), in English: "31 same, 2 differ, 3 each window's own".
    public static func counts(_ signals: [SiteSignal]) -> String {
        let same = signals.filter { $0.verdict == .same }.count
        let perWindow = signals.filter { $0.verdict == .perWindow }.count
        return "\(same) same, \(signals.count - same - perWindow) differ, \(perWindow) each window's own"
    }

    /// The profile shows the `aspect` it was set to, or nothing is known of what it was set to.
    private static func isAsSet(_ aspect: IdentityAspect, in signals: [SiteSignal], expected: ExpectedIdentity?) -> Bool {
        let key = aspect == .timeZone ? "probe.timeZone" : "probe.language"
        guard let signal = signals.first(where: { $0.key == key }), let shown = signal.profile else { return true }
        switch aspect {
        case .timeZone: return expected?.timeZone.map { sameZone(shown, $0) } ?? true
        case .language: return expected?.language.map { sameLanguage(shown, $0) } ?? true
        }
    }

    /// The same zone under either of its names (Europe/Kiev and Europe/Kyiv): the same identifier, or
    /// two zones with the same offset on four days through the year.
    static func sameZone(_ first: String, _ second: String) -> Bool {
        if first == second { return true }
        guard let one = TimeZone(identifier: first), let other = TimeZone(identifier: second) else { return false }
        let year2024 = 1_704_067_200.0 // 2024-01-01T00:00:00Z
        return [15.0, 105.0, 196.0, 288.0].allSatisfy { day in
            let date = Date(timeIntervalSince1970: year2024 + day * 86_400)
            return one.secondsFromGMT(for: date) == other.secondsFromGMT(for: date)
        }
    }

    /// The same language, its region aside: "de-DE" is "de".
    static func sameLanguage(_ first: String, _ second: String) -> Bool {
        func primary(_ tag: String) -> String {
            String(tag.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first ?? "")
        }
        return !first.isEmpty && primary(first) == primary(second)
    }
}
