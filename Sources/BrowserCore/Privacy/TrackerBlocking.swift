#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

/// Per-profile tracker blocking. Stored in `ProfileConfiguration` (encrypted with the profile).
///
/// NATIVE: the app compiles these settings into a `WKContentRuleList` (WebKit's content-blocker
/// engine) and attaches it to the profile's `WKUserContentController`. Blocking happens inside
/// WebKit before a request is sent, for every tab and popup of the profile. Other profiles are
/// unaffected: each session has its own rule list.
public struct TrackerBlockingSettings: Codable, Equatable, Sendable {
    public enum Level: String, Codable, CaseIterable, Sendable {
        /// No content rules.
        case off
        /// Third-party requests to known advertising and analytics domains are blocked.
        case standard
        /// `standard` + social-network trackers and widgets, and no cookies on any third-party request.
        case strict
    }

    public var level: Level
    /// Sites (and their subdomains) on which nothing is blocked, e.g. a site that breaks.
    public var allowedSites: [String]
    /// Extra domains (and subdomains) to block as third parties, on top of the built-in list.
    public var blockedDomains: [String]

    public static let maxListEntries = 1_000

    public init(level: Level = .standard, allowedSites: [String] = [], blockedDomains: [String] = []) {
        self.level = level
        self.allowedSites = allowedSites
        self.blockedDomains = blockedDomains
    }

    private enum CodingKeys: String, CodingKey { case level, allowedSites, blockedDomains }

    /// Tolerant: an unknown level from a newer build reads as `standard`.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        level = (try? c.decodeIfPresent(Level.self, forKey: .level)) ?? .standard
        allowedSites = try c.decodeIfPresent([String].self, forKey: .allowedSites) ?? []
        blockedDomains = try c.decodeIfPresent([String].self, forKey: .blockedDomains) ?? []
    }

    public func validate() throws {
        for (list, name) in [(allowedSites, "allowed sites"), (blockedDomains, "blocked domains")] {
            guard list.count <= Self.maxListEntries else {
                throw CoreError.invalidConfiguration("too many \(name) (max \(Self.maxListEntries))")
            }
            for domain in list where ContentBlockerRules.normalizedDomain(domain) != domain {
                throw CoreError.invalidConfiguration("not a domain name: \(domain)")
            }
        }
    }
}

/// Builds WebKit content-blocker JSON (`WKContentRuleListStore.compileContentRuleList`).
public enum ContentBlockerRules {
    /// The JSON rule list for `settings`, or nil when nothing is to be blocked.
    ///
    /// Rule order matters: WebKit applies the rules of one list top to bottom, and the final
    /// `ignore-previous-rules` entry turns everything off on allow-listed sites.
    public static func json(for settings: TrackerBlockingSettings) -> String? {
        guard settings.level != .off else { return nil }
        var domains = TrackerDomains.advertising + TrackerDomains.analytics
        if settings.level == .strict { domains += TrackerDomains.social }
        domains += settings.blockedDomains.compactMap(normalizedDomain)

        var rules: [[String: Any]] = []
        var seen = Set<String>()
        for domain in domains where seen.insert(domain).inserted {
            rules.append(["trigger": ["url-filter": urlFilter(forDomain: domain), "load-type": ["third-party"]],
                          "action": ["type": "block"]])
        }
        if settings.level == .strict {
            rules.append(["trigger": ["url-filter": ".*", "load-type": ["third-party"]],
                          "action": ["type": "block-cookies"]])
        }
        let allowed = Array(Set(settings.allowedSites.compactMap(normalizedDomain))).sorted()
        if !allowed.isEmpty {
            rules.append(["trigger": ["url-filter": ".*", "if-domain": allowed.map { "*" + $0 }],
                          "action": ["type": "ignore-previous-rules"]])
        }
        guard let data = try? JSONSerialization.data(withJSONObject: rules, options: [.sortedKeys]) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Stable identifier for a compiled list: the same rules compile to the same identifier.
    public static func identifier(for json: String) -> String {
        let digest = SHA256.hash(data: Data(json.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        return "pb-trackers-v\(TrackerDomains.version)-\(digest)"
    }

    /// Matches `domain` and every subdomain, any scheme and port. WebKit's content-blocker
    /// regex subset has no alternation, so each domain is one rule.
    static func urlFilter(forDomain domain: String) -> String {
        "^[^:]+://+([^:/]+\\.)?" + domain.replacingOccurrences(of: ".", with: "\\.") + "[:/]"
    }

    /// Lower-case ASCII host from user input (`https://Ads.Example.com/x`, `*.example.com`,
    /// `example.com:8080` → `ads.example.com` / `example.com`). Nil for anything that is not a
    /// plausible DNS name with at least one dot. Non-ASCII (IDN) names must be entered in
    /// punycode (`xn--…`).
    public static func normalizedDomain(_ input: String) -> String? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let range = text.range(of: "://") { text = String(text[range.upperBound...]) }
        if let slash = text.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) { text = String(text[..<slash]) }
        if let at = text.lastIndex(of: "@") { text = String(text[text.index(after: at)...]) }
        if let colon = text.firstIndex(of: ":") { text = String(text[..<colon]) }
        while text.hasPrefix("*.") { text.removeFirst(2) }
        while text.hasPrefix(".") { text.removeFirst() }
        while text.hasSuffix(".") { text.removeLast() }
        guard !text.isEmpty, text.count <= 253, text.contains(".") else { return nil }
        for label in text.split(separator: ".", omittingEmptySubsequences: false) {
            guard (1...63).contains(label.count), label.first != "-", label.last != "-",
                  label.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else { return nil }
        }
        return text
    }
}

/// Built-in tracker domains: well-known advertising, analytics and social tracking hosts.
/// Each entry also covers its subdomains. Deliberately conservative: CDNs and API hosts that
/// sites need to work (gstatic.com, googleapis.com, fbcdn.net, …) are not listed.
///
/// This is a compact list compiled into the app, not a subscription: it is updated with the
/// app. Bump `version` when it changes.
public enum TrackerDomains {
    public static let version = 1

    public static let advertising: [String] = [
        "doubleclick.net", "googlesyndication.com", "googleadservices.com", "adservice.google.com",
        "pagead2.googlesyndication.com", "googletagservices.com", "2mdn.net", "admob.com",
        "adnxs.com", "adsrvr.org", "rubiconproject.com", "pubmatic.com", "openx.net", "casalemedia.com",
        "criteo.com", "criteo.net", "taboola.com", "outbrain.com", "bidswitch.net", "smartadserver.com",
        "adform.net", "yieldmo.com", "sharethrough.com", "3lift.com", "triplelift.com", "teads.tv",
        "moatads.com", "doubleverify.com", "adsafeprotected.com", "serving-sys.com", "flashtalking.com",
        "media.net", "contextweb.com", "indexww.com", "lijit.com", "sovrn.com", "gumgum.com",
        "advertising.com", "adtechus.com", "ads.yahoo.com", "adserver.yahoo.com", "yieldmanager.com",
        "amazon-adsystem.com", "adsymptotic.com", "adroll.com", "quantcount.com", "rlcdn.com",
        "bluekai.com", "demdex.net", "everesttech.net", "krxd.net", "exelator.com", "agkn.com",
        "mathtag.com", "turn.com", "simpli.fi", "spotxchange.com", "springserve.com", "zemanta.com",
        "revcontent.com", "mgid.com", "propellerads.com", "popads.net", "popcash.net", "exoclick.com",
        "juicyads.com", "trafficjunky.net", "adcolony.com", "applovin.com", "unityads.unity3d.com",
        "inmobi.com", "smaato.net", "vungle.com", "chartboost.com", "ironsrc.com", "mopub.com",
        "adsrvr.com", "adition.com", "betweendigital.com", "adriver.ru", "adfox.ru", "an.yandex.ru",
        "yabs.yandex.ru", "ads.adfox.ru", "begun.ru", "admitad.com", "cityads.com", "buzzoola.com",
        "otm-r.com", "sape.ru", "mytarget.ru", "ad.mail.ru", "r.mradx.net", "adhigh.net",
        "adskeeper.co.uk", "ad.gt", "id5-sync.com", "liveintent.com", "lkqd.net", "nativo.com",
        "onetag-sys.com", "33across.com", "tapad.com", "eyeota.net", "crwdcntrl.net", "addthis.com",
        "sharethis.com", "zedo.com", "undertone.com", "conversantmedia.com", "dotomi.com",
        "emxdgt.com", "rhythmone.com", "1rx.io", "yieldlab.net", "adnium.com", "adsterra.com",
    ]

    public static let analytics: [String] = [
        "google-analytics.com", "googletagmanager.com", "analytics.google.com", "stats.g.doubleclick.net",
        "scorecardresearch.com", "quantserve.com", "hotjar.com", "hotjar.io", "mixpanel.com",
        "segment.io", "cdn.segment.com", "api.segment.io", "amplitude.com", "heapanalytics.com",
        "fullstory.com", "mouseflow.com", "crazyegg.com", "luckyorange.com", "luckyorange.net",
        "inspectlet.com", "clicktale.net", "contentsquare.net", "smartlook.com", "logrocket.com",
        "logrocket.io", "clarity.ms", "bat.bing.com", "analytics.tiktok.com", "analytics.twitter.com",
        "static.ads-twitter.com", "ads-twitter.com", "snap.licdn.com", "px.ads.linkedin.com",
        "analytics.yahoo.com", "sp.analytics.yahoo.com", "chartbeat.com", "chartbeat.net",
        "parsely.com", "nr-data.net", "omtrdc.net", "2o7.net", "kissmetrics.com",
        "woopra.com", "statcounter.com", "histats.com", "clicky.com", "getclicky.com",
        "mc.yandex.ru", "mc.yandex.com", "top-fwz1.mail.ru", "top.mail.ru", "counter.yadro.ru",
        "tns-counter.ru", "mediascope.net", "openstat.net", "liveinternet.ru",
        "app-measurement.com", "appsflyer.com", "adjust.com", "kochava.com", "singular.net",
        "optimizely.com", "cdn.optimizely.com", "vwo.com", "visualwebsiteoptimizer.com",
        "pingdom.net", "bounceexchange.com", "bouncex.net", "pardot.com", "marketo.net", "mktoresp.com",
        "hs-analytics.net", "hs-scripts.com", "hubspot.net", "track.hubspot.com",
        "ensighten.com", "tealiumiq.com", "tiqcdn.com", "matomo.cloud", "piwik.pro", "plausible.io",
        "pixel.wp.com", "stats.wp.com", "quantcast.com", "comscore.com", "nielsen.com", "imrworldwide.com",
        "gemius.pl", "gemius.com", "webvisor.org", "counter.rambler.ru",
    ]

    /// `strict` only: social networks' tracking pixels and embedded widgets. Blocking these
    /// breaks "Log in with …" buttons and embedded posts on third-party sites.
    public static let social: [String] = [
        "connect.facebook.net", "facebook.net", "pixel.facebook.com", "an.facebook.com",
        "platform.twitter.com", "syndication.twitter.com", "platform.linkedin.com",
        "platform.instagram.com", "assets.pinterest.com", "ct.pinterest.com", "log.pinterest.com",
        "widgets.pinterest.com", "sc-static.net", "tr.snapchat.com", "connect.ok.ru", "vk.com",
        "userapi.com", "disqus.com", "disquscdn.com", "redditstatic.com", "alb.reddit.com",
        "ads.tiktok.com", "business-api.tiktok.com",
    ]
}
