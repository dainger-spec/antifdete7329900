import Foundation

/// What the session warm-up robot does for a profile: the pages it visits one after the other in
/// the profile's own tab (a search first, when one is given, then the addresses in their order),
/// how long it stays on each, and whether it scrolls and follows a link. Kept per profile,
/// encrypted (`warmup.bin`), on this Mac only.
public struct WarmUpPlan: Codable, Equatable, Sendable {
    /// Web addresses as the user typed them, one per line; `#` starts a comment line.
    public var addresses: String
    /// A search to start with (the address bar's search engine), or empty.
    public var searchQuery: String
    /// Seconds on each page, chosen at random between these two (`dwellLimits`).
    public var minimumDwell: TimeInterval
    public var maximumDwell: TimeInterval
    /// Scroll down (now and then up) while on a page, as a trackpad would.
    public var scroll: Bool
    /// Before leaving a page, follow one plain link on it: on the same site, or, on the search
    /// results, to a result. Never a sign-out, purchase, deletion or download link.
    public var followLinks: Bool

    public static let dwellLimits: ClosedRange<TimeInterval> = 2...300
    public static let maximumPages = 50

    public init(addresses: String = "", searchQuery: String = "", minimumDwell: TimeInterval = 5, maximumDwell: TimeInterval = 15,
                scroll: Bool = true, followLinks: Bool = false) {
        self.addresses = addresses
        self.searchQuery = searchQuery
        self.minimumDwell = minimumDwell
        self.maximumDwell = maximumDwell
        self.scroll = scroll
        self.followLinks = followLinks
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

        public init(url: URL, kind: Kind) {
            self.url = url
            self.kind = kind
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

    /// The pages to visit, and the lines that are not.
    public func pages() -> (pages: [Page], problems: [Problem]) {
        var pages: [Page] = []
        var problems: [Problem] = []
        var seen: Set<String> = []
        if let search = WebAddress.searchURL(for: searchQuery) {
            pages.append(Page(url: search, kind: .search))
            seen.insert(search.absoluteString)
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

    /// Seconds on a page: anywhere between the plan's two times.
    public static func dwell(_ plan: WarmUpPlan, using generator: inout some RandomNumberGenerator) -> TimeInterval {
        let plan = plan.normalized
        return plan.minimumDwell == plan.maximumDwell ? plan.minimumDwell
            : Double.random(in: plan.minimumDwell...plan.maximumDwell, using: &generator)
    }

    /// Seconds between leaving a page and asking for the next.
    public static func pause(using generator: inout some RandomNumberGenerator) -> TimeInterval {
        Double.random(in: 1...3, using: &generator)
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
    static func site(of url: URL) -> String {
        WebOrigin(url: url)?.site ?? (url.host ?? "").lowercased()
    }

    static func sameDocument(_ a: URL, _ b: URL) -> Bool {
        func strip(_ url: URL) -> String {
            var components = URLComponents(url: url, resolvingAgainstBaseURL: true)
            components?.fragment = nil
            return components?.url?.absoluteString ?? url.absoluteString
        }
        return strip(a) == strip(b)
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
    }

    public let id: Int
    public var url: URL
    public var kind: WarmUpPlan.Page.Kind
    public var outcome: Outcome?
    public var title: String
    public var dwell: TimeInterval
    public var scrolls: Int
    /// The link followed from this page, and whether its page loaded.
    public var followed: URL?
    public var followedOutcome: Outcome?

    public init(id: Int, url: URL, kind: WarmUpPlan.Page.Kind) {
        self.id = id
        self.url = url
        self.kind = kind
        self.title = ""
        self.dwell = 0
        self.scrolls = 0
    }
}
