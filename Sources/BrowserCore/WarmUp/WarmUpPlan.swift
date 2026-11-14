import Foundation

/// What the session warm-up robot does for a profile: the pages it visits one after the other in
/// the profile's own tab (a search first, when one is given, then the addresses in their order,
/// with any further searches spread between them), how long it stays on each, and whether it
/// scrolls and follows links. Kept per profile, encrypted (`warmup.bin`), on this Mac only.
public struct WarmUpPlan: Codable, Equatable, Sendable {
    /// Web addresses as the user typed them, one per line; `#` starts a comment line.
    public var addresses: String
    /// Searches (the address bar's search engine), one per line, or empty. The first starts the
    /// run; the others come between the addresses, as a person searches now and then. A plan
    /// saved before there could be several holds one line, and reads as it did.
    public var searchQuery: String
    /// Seconds on each page, chosen at random between these two (`dwellLimits`).
    public var minimumDwell: TimeInterval
    public var maximumDwell: TimeInterval
    /// Scroll down (now and then up) while on a page, as a trackpad would.
    public var scroll: Bool
    /// Before leaving a page, follow plain links on it: on the same site, or, on the search
    /// results, to a result. Never a sign-out, purchase, deletion or download link.
    public var followLinks: Bool
    /// How many links, one after the other, `followLinks` follows from a page (`hopLimits`): each
    /// from the page the one before led to, each with a stay of its own. Nil in plans from before
    /// there could be more than one: one.
    public var linkHops: Int?
    /// Where this plan came from, so the screen opens where it was left. Absent in plans saved
    /// before the screen had ready-made lists, and in those written by hand.
    public var choice: WarmUpChoice?
    /// What the robot's tab does not load, to spare the proxy's traffic (`WarmUpTrafficSaving`'s
    /// raw value; nil, or one this version does not know: everything loads). Text, so that a
    /// later version's value does not cost the whole plan.
    public var trafficSaving: String?

    /// `trafficSaving`, when it is one this version knows.
    public var savesTraffic: WarmUpTrafficSaving? { trafficSaving.flatMap(WarmUpTrafficSaving.init(rawValue:)) }

    public static let dwellLimits: ClosedRange<TimeInterval> = 2...300
    public static let maximumPages = 50
    public static let hopLimits: ClosedRange<Int> = 1...3
    /// Searches beyond these are not run: a run that is mostly searches is a scraper's.
    public static let maximumSearches = 5

    public init(addresses: String = "", searchQuery: String = "", minimumDwell: TimeInterval = 5, maximumDwell: TimeInterval = 15,
                scroll: Bool = true, followLinks: Bool = false, linkHops: Int? = nil, choice: WarmUpChoice? = nil) {
        self.addresses = addresses
        self.searchQuery = searchQuery
        self.minimumDwell = minimumDwell
        self.maximumDwell = maximumDwell
        self.scroll = scroll
        self.followLinks = followLinks
        self.linkHops = linkHops
        self.choice = choice
    }

    /// The searches of `searchQuery`, one per line, each once and at most `maximumSearches`.
    public var searches: [String] {
        var seen: Set<String> = []
        let lines = searchQuery.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        return Array(lines.filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }.prefix(Self.maximumSearches))
    }

    /// Links followed one after the other from each page: none without `followLinks`, else
    /// `linkHops` kept to `hopLimits` (one when the plan does not say).
    public var hops: Int {
        followLinks ? min(max(linkHops ?? 1, Self.hopLimits.lowerBound), Self.hopLimits.upperBound) : 0
    }

    public struct Page: Equatable, Sendable {
        public enum Kind: String, Codable, Sendable {
            /// One of the user's addresses: links followed stay on its site.
            case address
            /// The search results: a followed link leaves for a result's site.
            case search
        }

        public var url: URL
        public var kind: Kind
        /// For a search: its words, which the robot types on the engine's own page when it can
        /// (`url` is the results page it opens otherwise).
        public var query: String?

        public init(url: URL, kind: Kind, query: String? = nil) {
            self.url = url
            self.kind = kind
            self.query = query
        }
    }

    /// A line of `addresses` that is not visited.
    public struct Problem: Equatable, Sendable {
        public enum Reason: Equatable, Sendable {
            /// Not a web address (text with spaces belongs in the search field).
            case notAWebAddress
            /// Another scheme than http and https (`file:`, `javascript:`, `about:` …).
            case unsupportedScheme(String)
            /// The same address again (it is visited once).
            case duplicate
            /// Beyond `maximumPages`.
            case tooMany
        }

        public var line: Int
        public var text: String
        public var reason: Reason
    }

    /// The pages to visit, and the lines that are not; the searches with the profile's `engine`:
    /// the first before the addresses, the others spread evenly between them — always in the same
    /// places, so that what the screen lists is what runs.
    public func pages(searchEngine engine: SearchEngine = .standard) -> (pages: [Page], problems: [Problem]) {
        var pages: [Page] = []
        var problems: [Problem] = []
        var seen: Set<String> = []
        var searchPages: [Page] = []
        for query in searches {
            guard let search = WebAddress.searchURL(for: query, engine: engine), seen.insert(search.absoluteString).inserted else { continue }
            searchPages.append(Page(url: search, kind: .search, query: query))
        }
        for (index, rawLine) in addresses.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).enumerated() {
            let text = rawLine.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty, !text.hasPrefix("#") else { continue }
            let line = index + 1
            guard let url = Self.webURL(text) else {
                var reason = Problem.Reason.notAWebAddress
                if let scheme = URL(string: text)?.scheme?.lowercased(), !["http", "https"].contains(scheme) {
                    reason = .unsupportedScheme(scheme)
                }
                problems.append(Problem(line: line, text: text, reason: reason))
                continue
            }
            guard seen.insert(url.absoluteString).inserted else {
                problems.append(Problem(line: line, text: text, reason: .duplicate))
                continue
            }
            guard pages.count < Self.maximumPages else {
                problems.append(Problem(line: line, text: text, reason: .tooMany))
                continue
            }
            pages.append(Page(url: url, kind: .address))
        }
        // Search j of k (from 0) goes before address j·n/k: the first leads, the rest come between.
        let count = pages.count
        for (j, search) in searchPages.enumerated().reversed() {
            pages.insert(search, at: j == 0 ? 0 : min(count, j * count / searchPages.count))
        }
        return (pages, problems)
    }

    /// An http(s) address with a host; a bare host name gets https. Text that starts with
    /// another scheme (`javascript:`, `mailto:a@b.c`, `file:///`) is none, not a host name.
    static func webURL(_ text: String) -> URL? {
        if let scheme = URL(string: text)?.scheme?.lowercased(), !["http", "https"].contains(scheme),
           !(text.dropFirst(scheme.count + 1).first?.isNumber ?? false) { // `example.com:8080` is a host and port
            return nil
        }
        guard let url = WebAddress.url(fromTypedAddress: text), let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme), let host = url.host, !host.isEmpty else { return nil }
        return url
    }

    /// The plan with its times inside `dwellLimits` and in order.
    public var normalized: WarmUpPlan {
        var plan = self
        plan.minimumDwell = min(max(minimumDwell, Self.dwellLimits.lowerBound), Self.dwellLimits.upperBound)
        plan.maximumDwell = min(max(maximumDwell, plan.minimumDwell), Self.dwellLimits.upperBound)
        return plan
    }
}

/// The robot's random timing, from a generator the tests can seed.
public struct WarmUpTiming: Sendable {
    /// One scroll gesture: wheel steps of `deltas` points (positive scrolls down), `interval`
    /// seconds apart, starting `at` seconds after the page is ready.
    public struct Gesture: Equatable, Sendable {
        public var at: TimeInterval
        public var deltas: [Double]
        public var interval: TimeInterval
    }

    /// How the stays on pages are spread between the plan's two times: most short, a few long —
    /// the long tail of a person who now and then reads a page through. The share of the way from
    /// the shortest to the longest is `(e^(λu) − 1) / (e^λ − 1)` for an even `u` in 0…1.
    static let dwellTail = 2.2

    /// The average share of the way from the shortest stay to the longest — the mean of the
    /// spread above, `1/λ − 1/(e^λ − 1)` — for what a page costs on average.
    public static var meanDwellFraction: Double { 1 / dwellTail - 1 / (exp(dwellTail) - 1) }

    /// The average stay between `minimum` and `maximum`.
    public static func meanDwell(_ minimum: TimeInterval, _ maximum: TimeInterval) -> TimeInterval {
        minimum + (max(minimum, maximum) - minimum) * meanDwellFraction
    }

    /// Seconds on a page: between the plan's two times, mostly nearer the shorter (`dwellTail`).
    /// Stays of one length, or spread evenly, are a pattern a person does not make.
    public static func dwell(_ plan: WarmUpPlan, using generator: inout some RandomNumberGenerator) -> TimeInterval {
        let plan = plan.normalized
        guard plan.minimumDwell < plan.maximumDwell else { return plan.minimumDwell }
        let u = Double.random(in: 0...1, using: &generator)
        let fraction = (exp(dwellTail * u) - 1) / (exp(dwellTail) - 1)
        let span = plan.maximumDwell - plan.minimumDwell
        return min(plan.maximumDwell, max(plan.minimumDwell, plan.minimumDwell + span * fraction))
    }

    /// Seconds between leaving a page and asking for the next.
    public static func pause(using generator: inout some RandomNumberGenerator) -> TimeInterval {
        Double.random(in: 1...3, using: &generator)
    }

    /// How often a search is typed on the engine's own page rather than opened by its results'
    /// address (what Safari's address bar does with words typed into it): people do both.
    public static let typedSearchShare = 0.7

    /// The pause before each character of `text` is typed, as a person types: 80–240 ms between
    /// letters, longer after a space (the next word is thought of), and now and then a hesitation
    /// of half a second to a second. The first is the moment between the click in the box and the
    /// first key.
    public static func keyGaps(for text: String, using generator: inout some RandomNumberGenerator) -> [TimeInterval] {
        var gaps: [TimeInterval] = []
        var previous: Character?
        for character in text {
            var gap: TimeInterval
            if previous == nil {
                gap = Double.random(in: 0.35...0.9, using: &generator)
            } else if previous == " " {
                gap = Double.random(in: 0.15...0.45, using: &generator)
            } else {
                gap = Double.random(in: 0.08...0.24, using: &generator)
            }
            if previous != nil, Double.random(in: 0..<1, using: &generator) < 0.06 {
                gap += Double.random(in: 0.5...1.0, using: &generator)
            }
            gaps.append(gap)
            previous = character
        }
        return gaps
    }

    /// Scroll gestures spread over `dwell` (none in the last second): about one every four
    /// seconds, at most six; mostly down, now and then a little back up. Each gesture is a
    /// trackpad-like flick: larger steps first, then slowing.
    public static func gestures(over dwell: TimeInterval, using generator: inout some RandomNumberGenerator) -> [Gesture] {
        let usable = dwell - 1
        guard usable >= 1 else { return [] }
        let count = min(6, max(1, Int(usable / 4)))
        let slot = usable / Double(count)
        return (0..<count).map { index in
            let start = Double(index) * slot + Double.random(in: 0...(slot * 0.5), using: &generator)
            let up = index > 0 && Double.random(in: 0..<1, using: &generator) < 0.15
            let distance = Double.random(in: up ? 80...240 : 240...720, using: &generator) * (up ? -1 : 1)
            let steps = Int.random(in: 8...14, using: &generator)
            // Weights steps...1: each step a little smaller than the one before.
            let total = Double(steps * (steps + 1) / 2)
            let deltas = (0..<steps).map { (distance * Double(steps - $0) / total).rounded() }
            return Gesture(at: start, deltas: deltas, interval: Double.random(in: 0.016...0.035, using: &generator))
        }
    }

    /// When the pointer drifts while a page is read, as a hand resting on a mouse does: every few
    /// seconds (3–9), never in the second before a scroll gesture of `gestures` nor while one runs
    /// (the wheel scrolls where the pointer is), and not in the last two seconds of the stay.
    public static func pointerMoves(over dwell: TimeInterval, avoiding gestures: [Gesture],
                                    using generator: inout some RandomNumberGenerator) -> [TimeInterval] {
        var times: [TimeInterval] = []
        var at = Double.random(in: 0.8...3, using: &generator)
        while at < dwell - 2 {
            let clear = gestures.allSatisfy { gesture in
                let end = gesture.at + Double(gesture.deltas.count) * gesture.interval
                return at < gesture.at - 1 || at > end + 0.3
            }
            if clear { times.append(at) }
            at += Double.random(in: 3...9, using: &generator)
        }
        return times
    }
}

/// A point of a page's viewport, in CSS pixels from its top left.
public struct WarmUpPoint: Equatable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// The way a hand takes the pointer from one place to another: a curve, not a ruler's line — a
/// cubic Bézier whose handles lie off the straight way by up to a fifth of the distance, mostly
/// to one side (an arc), now and then to both (an S) — eased at both ends, with a hand's tremor
/// (up to a pixel and a half) on every point but the last, which is exactly where it was going.
public enum WarmUpPointerPath {
    public static func path(from start: WarmUpPoint, to end: WarmUpPoint, steps: Int,
                            using generator: inout some RandomNumberGenerator) -> [WarmUpPoint] {
        let count = max(1, steps)
        let dx = end.x - start.x, dy = end.y - start.y
        let distance = (dx * dx + dy * dy).squareRoot()
        // The normal of the straight way, along which the handles are pushed.
        let nx = distance > 0 ? -dy / distance : 0, ny = distance > 0 ? dx / distance : 0
        let side: Double = Bool.random(using: &generator) ? 1 : -1
        let bend1 = side * distance * Double.random(in: 0.04...0.2, using: &generator)
        let bend2 = (Double.random(in: 0...1, using: &generator) < 0.8 ? side : -side)
            * distance * Double.random(in: 0.02...0.15, using: &generator)
        let along1 = Double.random(in: 0.2...0.4, using: &generator), along2 = Double.random(in: 0.6...0.8, using: &generator)
        let c1 = WarmUpPoint(x: start.x + dx * along1 + nx * bend1, y: start.y + dy * along1 + ny * bend1)
        let c2 = WarmUpPoint(x: start.x + dx * along2 + nx * bend2, y: start.y + dy * along2 + ny * bend2)
        return (1...count).map { step in
            let t = Double(step) / Double(count)
            let s = t * t * (3 - 2 * t)
            let u = 1 - s
            var x = u * u * u * start.x + 3 * u * u * s * c1.x + 3 * u * s * s * c2.x + s * s * s * end.x
            var y = u * u * u * start.y + 3 * u * u * s * c1.y + 3 * u * s * s * c2.y + s * s * s * end.y
            if step < count {
                x += Double.random(in: -1.5...1.5, using: &generator)
                y += Double.random(in: -1.5...1.5, using: &generator)
            }
            return WarmUpPoint(x: x, y: y)
        }
    }
}

/// A link on a page, as the robot's reader reports it (the rectangle in viewport points).
public struct WarmUpLink: Codable, Equatable, Sendable {
    public var href: String
    public var text: String
    public var target: String
    public var download: Bool
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(href: String, text: String, target: String = "", download: Bool = false,
                x: Double, y: Double, width: Double, height: Double) {
        self.href = href
        self.text = text
        self.target = target
        self.download = download
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

/// Which links the robot may follow: plain, visible links that open a web page in the same tab
/// — on the same site for the user's addresses, to another site from the search results — and
/// never one whose words or address speak of signing out, deleting, buying, paying,
/// unsubscribing or downloading.
public enum WarmUpLinkPolicy {
    static let riskyWords = [
        "logout", "log-out", "log_out", "log out", "logoff", "log off", "signout", "sign-out", "sign_out", "sign out",
        "delete", "remove", "deactivate", "unsubscribe", "cancel", "close account",
        "cart", "basket", "checkout", "check-out", "buy", "purchase", "order", "pay", "donate", "subscribe", "billing",
        "download", "install", "report", "share", "print", "mailto",
        "выйти", "выход", "удалить", "корзин", "купить", "оформить", "заказ", "оплат", "подпис", "скачать",
    ]
    static let fileExtensions: Set<String> = [
        "pdf", "zip", "dmg", "pkg", "exe", "msi", "apk", "iso", "rar", "7z", "gz", "tgz", "bz2", "xz", "tar",
        "mp3", "mp4", "m4a", "mov", "avi", "mkv", "webm", "wav", "flac",
        "doc", "docx", "xls", "xlsx", "ppt", "pptx", "csv", "ics", "torrent",
    ]

    /// The links of `links` the robot may click on `page` (shown in a viewport of `viewport`).
    public static func candidates(_ links: [WarmUpLink], on page: URL, kind: WarmUpPlan.Page.Kind,
                                  viewport: (width: Double, height: Double)) -> [WarmUpLink] {
        links.filter { allows($0, on: page, kind: kind, viewport: viewport) }
    }

    /// Whether the robot may click `link` itself (another link to the same address may still be
    /// refused: one opening a new window, or downloading).
    public static func allows(_ link: WarmUpLink, on page: URL, kind: WarmUpPlan.Page.Kind,
                              viewport: (width: Double, height: Double)) -> Bool {
        guard let url = URL(string: link.href, relativeTo: page)?.absoluteURL,
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host, !host.isEmpty else { return false }
        // The same page (a fragment) is no visit.
        if sameDocument(url, page) { return false }
        switch kind {
        case .address: guard site(of: url) == site(of: page) else { return false }
        case .search: guard site(of: url) != site(of: page) else { return false }
        }
        let target = link.target.lowercased()
        guard ["", "_self", "_top", "_parent"].contains(target), !link.download else { return false }
        guard !fileExtensions.contains(url.pathExtension.lowercased()) else { return false }
        let words = (link.text + " " + url.path + " " + (url.query ?? "")).lowercased()
        guard !riskyWords.contains(where: words.contains) else { return false }
        guard link.text.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2 else { return false }
        // Wholly in view and large enough to aim at.
        return link.width >= 8 && link.height >= 8 && link.x >= 0 && link.y >= 0
            && link.x + link.width <= viewport.width && link.y + link.height <= viewport.height
    }

    /// The site (`WebOrigin.site`: the registrable domain, or the host itself for an IP address
    /// or a single-label host).
    public static func site(of url: URL) -> String {
        WebOrigin(url: url)?.site ?? (url.host ?? "").lowercased()
    }

    static func sameDocument(_ a: URL, _ b: URL) -> Bool {
        WebAddress.isSameDocument(a, b)
    }
}

/// What the robot did on one page of its run.
public struct WarmUpVisit: Equatable, Sendable, Identifiable {
    public enum Outcome: Equatable, Sendable {
        case loaded
        /// The page did not load (the message WebKit gave).
        case failed(String)
        /// Still loading after `WarmUpRobot.loadTimeout`: the robot went on.
        case timedOut
        /// The page asked something in a dialog: the dialog was answered "Cancel", the page left,
        /// and the run went on with the next.
        case dialog
    }

    public let id: Int
    public var url: URL
    public var kind: WarmUpPlan.Page.Kind
    public var outcome: Outcome?
    /// When the robot took the page as loaded: its own load had come and nothing was loading.
    public var loadedAt: Date?
    public var title: String
    public var dwell: TimeInterval
    public var scrolls: Int
    /// The first link followed from this page, and whether its page loaded.
    public var followed: URL?
    public var followedOutcome: Outcome?
    /// Links followed from this page one after the other, `followed` the first; their pages'
    /// addresses, for the sites a run went to.
    public var hops: [URL]
    /// A cookie banner's "accept" was pressed on this page, or on one its links led to.
    public var consentsAccepted: Int
    /// For a search: its words were typed on the engine's own page (otherwise its results page was
    /// opened by its address).
    public var typedSearch: Bool

    public init(id: Int, url: URL, kind: WarmUpPlan.Page.Kind) {
        self.id = id
        self.url = url
        self.kind = kind
        self.title = ""
        self.dwell = 0
        self.scrolls = 0
        self.hops = []
        self.consentsAccepted = 0
        self.typedSearch = false
    }
}

extension WarmUpVisit {
    /// The sites (registrable domains) whose pages a run's visits loaded — its own pages and those
    /// its links led to — for "sites visited".
    public static func sitesVisited(_ visits: [WarmUpVisit]) -> Int {
        var sites: Set<String> = []
        for visit in visits {
            if visit.outcome == .loaded, visit.kind == .address { sites.insert(WarmUpLinkPolicy.site(of: visit.url)) }
            for hop in visit.hops { sites.insert(WarmUpLinkPolicy.site(of: hop)) }
        }
        sites.remove("")
        return sites.count
    }
}

/// What a warm-up's tab leaves out to spend less of a proxy that is paid by the gigabyte (a
/// residential or mobile one): videos and sound — a news site's autoplaying clip is most of its
/// weight — and, at the stronger setting, images too. Only the robot's own tab, which nobody looks
/// at: the person's tabs of the profile load everything. A page sees those loads fail as a content
/// blocker makes them fail; cookies come from the pages and their scripts, which still load.
public enum WarmUpTrafficSaving: String, Codable, CaseIterable, Sendable {
    case media
    case mediaAndImages

    /// WebKit's resource types it blocks.
    public var blockedResourceTypes: [String] {
        switch self {
        case .media: return ["media"]
        case .mediaAndImages: return ["media", "image"]
        }
    }

    /// The content rule list (WebKit's JSON) of the robot's tab.
    public var ruleListJSON: String {
        let types = blockedResourceTypes.map { "\"\($0)\"" }.joined(separator: ",")
        return #"[{"trigger":{"url-filter":".*","resource-type":["# + types + #"]},"action":{"type":"block"}}]"#
    }

    /// The rule list's identifier in WebKit's store.
    public var ruleListIdentifier: String { "lumen-warmup-saving-\(rawValue)" }
}
