import Foundation

/// A profile checked in one go: what its pages say next to where it leaves for the internet, and
/// whether the two agree — the things an anti-fraud system reads first. Every finding is a
/// sentence in the person's words (`check.<topic>.<code>` in the strings tables, with `values`),
/// and where the settings can put it right, a fix that says what it changes.
///
/// Nothing here asks anyone anything: the facts are gathered by the app — the page's own report
/// from a page of this Mac (`WhatSitesSee`), the exit from the lookup a launch makes anyway
/// (`ProxyGeoLookup`), the process's own report (`ProfileNetworkReport`) — and judged here.
public enum ProfileCheck {
    public enum Topic: String, CaseIterable, Sendable {
        case proxy, timeZone, language, geolocation, webRTC, dns, engine, window
    }

    public enum Level: String, Sendable {
        /// As it should be.
        case ok
        /// Something a site can hold against the profile: counted in the verdict.
        case attention
        /// Not looked at, and why: nothing to compare with. Not counted.
        case unknown
    }

    /// What the settings can put right. Each changes the profile's settings only; a running
    /// profile takes them at its next start.
    public enum Fix: String, Sendable, CaseIterable {
        /// The time zone of where the profile leaves for the internet.
        case timeZoneFromConnection
        /// The language of the country it leaves in.
        case languageFromConnection
        /// The User-Agent of this Mac's own Safari: no typed one, no other version named.
        case safariOfThisMac
        /// The window as the app opens windows: no size of its own.
        case windowOfTheApp
        /// The fixed position moved to where the profile leaves for the internet.
        case geolocationAtExit
    }

    public struct Finding: Equatable, Sendable, Identifiable {
        public var topic: Topic
        public var level: Level
        /// Which sentence of the topic: the key is `check.<topic>.<code>`.
        public var code: String
        /// The sentence's values, in its order. One that starts with `country:` is a country's
        /// code, to be said by its name in the interface's language.
        public var values: [String]
        public var fix: Fix?

        public var id: String { topic.rawValue }
        public var key: String { "check.\(topic.rawValue).\(code)" }

        public init(_ topic: Topic, _ level: Level, _ code: String, _ values: [String] = [], fix: Fix? = nil) {
            self.topic = topic
            self.level = level
            self.code = code
            self.values = values
            self.fix = fix
        }
    }

    public struct Size: Equatable, Sendable {
        public var width: Int
        public var height: Int
        public init(width: Int, height: Int) {
            self.width = width
            self.height = height
        }
        var text: String { "\(width) × \(height)" }
    }

    public struct Coordinate: Equatable, Sendable {
        public var latitude: Double
        public var longitude: Double
        public init(latitude: Double, longitude: Double) {
            self.latitude = latitude
            self.longitude = longitude
        }

        /// Kilometres between two places on the globe (haversine).
        public func distance(to other: Coordinate) -> Double {
            let radius = 6371.0
            func radians(_ degrees: Double) -> Double { degrees * .pi / 180 }
            let dLat = radians(other.latitude - latitude), dLon = radians(other.longitude - longitude)
            let a = sin(dLat / 2) * sin(dLat / 2)
                + cos(radians(latitude)) * cos(radians(other.latitude)) * sin(dLon / 2) * sin(dLon / 2)
            return 2 * radius * asin(min(1, sqrt(a)))
        }
    }

    /// What a page of the profile reported about itself.
    public struct Page: Equatable, Sendable {
        public var timeZone: String?
        public var language: String?
        public var userAgent: String?
        public var screen: Size?
        public var window: Size?

        public init(timeZone: String? = nil, language: String? = nil, userAgent: String? = nil, screen: Size? = nil, window: Size? = nil) {
            self.timeZone = timeZone
            self.language = language
            self.userAgent = userAgent
            self.screen = screen
            self.window = window
        }

        /// From a snapshot's values (`SiteSnapshot.values`): the probe's and the geometry's keys.
        public init(snapshot values: [String: String]) {
            func size(_ text: String?) -> Size? {
                // "1512x982x1512x944x0x38", "1280×800": the first two whole numbers.
                let numbers = (text ?? "").split { !$0.isNumber }.compactMap { Int($0) }
                return numbers.count >= 2 ? Size(width: numbers[0], height: numbers[1]) : nil
            }
            func text(_ key: String) -> String? { values[key].flatMap { $0.isEmpty ? nil : $0 } }
            self.init(timeZone: text("probe.timeZone"), language: text("probe.language"), userAgent: text("probe.ua"),
                      screen: size(values["geometry.screen"] ?? values["probe.screen"]),
                      window: size(values["geometry.outer"] ?? values["probe.outerSize"]))
        }
    }

    /// How the launched profile does WebRTC.
    public enum WebRTC: String, Sendable {
        case off, throughProxy, direct
    }

    /// What the profile's own process says of its web views (`ProfileNetworkReport`).
    public struct Network: Equatable, Sendable {
        public var webViewsOffProfile: Int
        public var webViewsWithWebRTC: Int
        public var webViewsWithDNSPrefetch: Int
        public var udpClosed: Bool

        public init(webViewsOffProfile: Int = 0, webViewsWithWebRTC: Int = 0, webViewsWithDNSPrefetch: Int = 0, udpClosed: Bool = true) {
            self.webViewsOffProfile = webViewsOffProfile
            self.webViewsWithWebRTC = webViewsWithWebRTC
            self.webViewsWithDNSPrefetch = webViewsWithDNSPrefetch
            self.udpClosed = udpClosed
        }
    }

    public struct Facts: Sendable {
        public var configuration: ProfileConfiguration
        /// An iPhone or iPad view: Safari on this Mac under another device's name. Its engine
        /// and window are not judged against this Mac's.
        public var isMobileView = false
        /// The Safari of the WebKit the app runs ("26.6.2").
        public var hostSafariVersion: String
        public var page: Page?
        /// Where the profile leaves for the internet, as a lookup through its proxy (or, with no
        /// proxy, over this Mac's connection) found it.
        public var exit: ProxyLocation?
        public var exitCoordinate: Coordinate?
        /// The lookup got an answer from somewhere (with no `exit`: none that said where).
        public var lookupAnswered = false
        public var proxyNeedsCredentials = false
        public var webRTC: WebRTC
        public var network: Network?

        public init(configuration: ProfileConfiguration, hostSafariVersion: String, webRTC: WebRTC) {
            self.configuration = configuration
            self.hostSafariVersion = hostSafariVersion
            self.webRTC = webRTC
        }
    }

    /// A fixed position further than this from the exit is one a site can hold against it: an
    /// address's place is known to a city or a region, rarely closer.
    public static let farFromExit = 300.0

    /// Every topic's finding, in the order they are shown.
    public static func findings(_ facts: Facts, now: Date = Date()) -> [Finding] {
        [proxy(facts), timeZone(facts, now), language(facts), geolocation(facts), webRTC(facts), dns(facts), engine(facts), window(facts)]
    }

    /// How many findings a site can hold against the profile.
    public static func attention(in findings: [Finding]) -> Int {
        findings.filter { $0.level == .attention }.count
    }

    // MARK: The topics

    private static func country(_ exit: ProxyLocation) -> String { "country:" + (exit.countryCode ?? "") }

    static func proxy(_ facts: Facts) -> Finding {
        let hasProxy = facts.configuration.proxy != nil
        if let exit = facts.exit {
            return Finding(.proxy, .ok, hasProxy ? "alive" : "direct", [country(exit), exit.exitIP ?? ""])
        }
        guard hasProxy else { return Finding(.proxy, .unknown, "directUnknown") }
        if facts.proxyNeedsCredentials { return Finding(.proxy, .attention, "credentials") }
        return facts.lookupAnswered ? Finding(.proxy, .unknown, "noLocation") : Finding(.proxy, .attention, "silent")
    }

    static func timeZone(_ facts: Facts, _ now: Date) -> Finding {
        guard let page = facts.page?.timeZone else { return Finding(.timeZone, .unknown, "notMeasured") }
        guard let exit = facts.exit else { return Finding(.timeZone, .unknown, "noExit", [page]) }
        let wanted = exit.timeZoneIdentifier
        // Two names of one clock (Europe/Berlin, Europe/Paris) are the same to a page that reads
        // the offset, and a lookup's database need not name a zone as the system does.
        let sameClock = TimeZone(identifier: page).flatMap { a in
            TimeZone(identifier: wanted).map { a.secondsFromGMT(for: now) == $0.secondsFromGMT(for: now) }
        } ?? false
        if page == wanted || sameClock { return Finding(.timeZone, .ok, "matches", [page]) }
        // Set to follow the connection and still elsewhere: the exit moved since the profile started.
        let follows = facts.configuration.timeZoneIdentifier == nil && facts.configuration.matchProxyLocation
        return follows ? Finding(.timeZone, .attention, "stale", [page, wanted])
            : Finding(.timeZone, .attention, "differs", [page, wanted], fix: .timeZoneFromConnection)
    }

    private static func primary(_ tag: String) -> String {
        String(tag.split { $0 == "-" || $0 == "_" }.first ?? "").lowercased()
    }

    static func language(_ facts: Facts) -> Finding {
        guard let page = facts.page?.language else { return Finding(.language, .unknown, "notMeasured") }
        guard let exit = facts.exit, let code = exit.countryCode else { return Finding(.language, .unknown, "noExit", [page]) }
        guard let expected = ProxyLocation.webLanguages[code] else { return Finding(.language, .unknown, "noRule", [page, country(exit)]) }
        if primary(page) == primary(expected) { return Finding(.language, .ok, "matches", [page, country(exit)]) }
        let follows = facts.configuration.languageOverride == nil && facts.configuration.effectiveLocaleSource == .connection
            && facts.configuration.matchProxyLocation
        return follows ? Finding(.language, .attention, "stale", [page, country(exit), expected])
            : Finding(.language, .attention, "differs", [page, country(exit), expected], fix: .languageFromConnection)
    }

    static func geolocation(_ facts: Facts) -> Finding {
        guard case let .fixed(latitude, longitude, _) = facts.configuration.geolocation else { return Finding(.geolocation, .ok, "denied") }
        guard let exit = facts.exitCoordinate else { return Finding(.geolocation, .unknown, "noExit") }
        let distance = Coordinate(latitude: latitude, longitude: longitude).distance(to: exit)
        let shown = String(Int(distance.rounded()))
        return distance <= farFromExit ? Finding(.geolocation, .ok, "near", [shown])
            : Finding(.geolocation, .attention, "far", [shown], fix: .geolocationAtExit)
    }

    static func webRTC(_ facts: Facts) -> Finding {
        if let network = facts.network, network.webViewsWithWebRTC > 0 {
            return Finding(.webRTC, .attention, "onWhereOff", [String(network.webViewsWithWebRTC)])
        }
        guard facts.configuration.proxy != nil else {
            return Finding(.webRTC, .ok, facts.webRTC == .off ? "off" : "directNoProxy")
        }
        switch facts.webRTC {
        case .off: return Finding(.webRTC, .ok, "off")
        case .throughProxy: return Finding(.webRTC, .ok, "throughProxy")
        case .direct: return Finding(.webRTC, .attention, "direct")
        }
    }

    static func dns(_ facts: Facts) -> Finding {
        guard facts.configuration.proxy != nil else { return Finding(.dns, .ok, "direct") }
        guard let network = facts.network else { return Finding(.dns, .unknown, "noReport") }
        if network.webViewsOffProfile > 0 { return Finding(.dns, .attention, "offProfile", [String(network.webViewsOffProfile)]) }
        if network.webViewsWithDNSPrefetch > 0 { return Finding(.dns, .attention, "prefetch", [String(network.webViewsWithDNSPrefetch)]) }
        if !network.udpClosed { return Finding(.dns, .attention, "udpOpen") }
        return Finding(.dns, .ok, "throughProxy")
    }

    /// The Safari version a User-Agent names ("26.6" of "… Version/26.6 Safari/605.1.15"); nil
    /// for one that is not Safari's.
    public static func safariVersion(inUserAgent userAgent: String) -> String? {
        for other in ["Chrome/", "Chromium/", "CriOS/", "Edg/", "OPR/", "Firefox/", "FxiOS/"] where userAgent.contains(other) { return nil }
        guard userAgent.contains("Safari/"), let marker = userAgent.range(of: "Version/") else { return nil }
        let version = userAgent[marker.upperBound...].prefix { $0.isNumber || $0 == "." }
        return version.isEmpty ? nil : String(version)
    }

    static func engine(_ facts: Facts) -> Finding {
        if facts.isMobileView { return Finding(.engine, .unknown, "mobile") }
        guard let userAgent = facts.page?.userAgent else { return Finding(.engine, .unknown, "notMeasured") }
        guard let named = safariVersion(inUserAgent: userAgent) else { return Finding(.engine, .attention, "notSafari", fix: .safariOfThisMac) }
        switch SafariVersions.distance(of: named, fromHost: facts.hostSafariVersion) {
        case .same: return Finding(.engine, .ok, "same", [named])
        case .close: return Finding(.engine, .ok, "close", [named, facts.hostSafariVersion])
        case .far: return Finding(.engine, .attention, "far", [named, facts.hostSafariVersion], fix: .safariOfThisMac)
        }
    }

    static func window(_ facts: Facts) -> Finding {
        if facts.isMobileView { return Finding(.window, .unknown, "mobile") }
        guard let screen = facts.page?.screen, let window = facts.page?.window else { return Finding(.window, .unknown, "notMeasured") }
        let fix: Fix? = facts.configuration.windowSize == nil ? nil : .windowOfTheApp
        if window.width > screen.width || window.height > screen.height {
            return Finding(.window, .attention, "larger", [window.text, screen.text], fix: fix)
        }
        // A size asked for that this Mac's screen cannot hold: the window was made smaller, and
        // differs from what the settings say every time it opens.
        if let asked = facts.configuration.windowSize?.frame, asked.width > screen.width || asked.height > screen.height {
            return Finding(.window, .attention, "cut", [Size(width: asked.width, height: asked.height).text, screen.text], fix: .windowOfTheApp)
        }
        return Finding(.window, .ok, "fits", [window.text, screen.text])
    }

    // MARK: Fixes

    /// `configuration` with `fix` made. `exit`: where the profile leaves for the internet, for the
    /// fix that needs it (without it that fix changes nothing).
    public static func applying(_ fix: Fix, to configuration: ProfileConfiguration, exit: Coordinate? = nil) -> ProfileConfiguration {
        var changed = configuration
        switch fix {
        case .timeZoneFromConnection:
            changed.timeZoneIdentifier = nil
            changed.matchProxyLocation = true
            if changed.languageOverride == nil { changed.localeSource = nil }
        case .languageFromConnection:
            changed.languageOverride = nil
            changed.matchProxyLocation = true
            if changed.timeZoneIdentifier == nil { changed.localeSource = nil }
        case .safariOfThisMac:
            changed.userAgent = nil
            changed.safariVersion = nil
        case .windowOfTheApp:
            changed.windowSize = nil
        case .geolocationAtExit:
            guard let exit, case let .fixed(_, _, accuracy) = configuration.geolocation else { break }
            changed.geolocation = .fixed(latitude: exit.latitude, longitude: exit.longitude, accuracyMeters: accuracy)
        }
        return changed
    }
}
