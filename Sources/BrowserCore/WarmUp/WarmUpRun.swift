import Foundation

/// What a run did on one site: the row of a run's report.
public struct WarmUpSiteVisit: Codable, Equatable, Sendable, Identifiable {
    /// How the site was reached.
    public enum Arrival: String, Codable, Sendable {
        /// Its address was opened.
        case address
        /// Found in the profile's search engine by its name, its result followed.
        case search
        /// It is the search engine: a search was typed (or its results opened).
        case query
    }

    /// How the visit ended. Text, so that a later version's outcome does not cost the whole record.
    public enum Outcome: String, Codable, Sendable {
        case visited
        /// Did not load (the proxy, the site).
        case failed
        /// Still loading at the limit; the robot went on.
        case timedOut
        /// Showed an "are you a robot" check or a block page: left at once, nothing answered.
        case blocked
        /// A page with a password or a card field, or a checkout: left at once, nothing pressed.
        case sensitive
    }

    /// The registrable domain.
    public var site: String
    public var arrival: String
    public var outcome: String
    /// Pages read on it: its first and those its links led to.
    public var pages: Int
    public var seconds: Double
    /// Cookies of this site the run added.
    public var cookies: Int
    /// For a visit that was blocked or failed: what was seen ("cloudflare", "google", the error's words).
    public var detail: String?

    public var id: String { site }

    public init(site: String, arrival: Arrival, outcome: Outcome, pages: Int, seconds: Double, cookies: Int = 0, detail: String? = nil) {
        self.site = site
        self.arrival = arrival.rawValue
        self.outcome = outcome.rawValue
        self.pages = pages
        self.seconds = seconds
        self.cookies = cookies
        self.detail = detail
    }

    public var arrivalKind: Arrival { Arrival(rawValue: arrival) ?? .address }
    public var outcomeKind: Outcome { Outcome(rawValue: outcome) ?? .visited }
    public var isProblem: Bool { outcomeKind != .visited }

    /// At most this many rows are kept of a run (a deep run visits 27 sites; the rest is noise).
    public static let maximumRows = 60

    /// The visits of a run as rows, one per site in the order first visited: the pages and the time
    /// of every visit to the site together, the worst outcome kept, with the cookies the run added
    /// for it (`added`: `WarmUpCookieSite.site` → count).
    public static func rows(_ visits: [WarmUpSiteVisit], added: [String: Int]) -> [WarmUpSiteVisit] {
        var order: [String] = []
        var bySite: [String: WarmUpSiteVisit] = [:]
        for visit in visits where !visit.site.isEmpty {
            if var row = bySite[visit.site] {
                row.pages += visit.pages
                row.seconds += visit.seconds
                if row.outcomeKind == .visited, visit.isProblem, row.pages == 0 { row.outcome = visit.outcome; row.detail = visit.detail }
                if visit.outcomeKind == .visited { row.outcome = visit.outcome; row.detail = nil }
                bySite[visit.site] = row
            } else {
                order.append(visit.site)
                bySite[visit.site] = visit
            }
        }
        return order.prefix(maximumRows).compactMap { site in
            guard var row = bySite[site] else { return nil }
            row.cookies = added[site] ?? 0
            return row
        }
    }
}

/// How a run ended, for the history and the profile's state.
public enum WarmUpRunResult: String, Codable, Sendable {
    /// Every site of the plan was gone through.
    case finished
    /// Ended before that by the person, or with the profile.
    case stopped
    /// Ended by the robot: several pages in a row did not load.
    case proxyNotAnswering
    /// The profile or its run did not start.
    case notStarted
}

/// One warm-up of a profile, as its history keeps it and its report shows it.
public struct WarmUpRun: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var startedAt: Date
    public var endedAt: Date
    /// `WarmUpRunResult`'s raw value (text: a later version's is kept as written).
    public var result: String
    /// Why a run that did not finish stopped (`WarmUpStatus.stopReason`).
    public var stopReason: String?
    /// Started by the schedule rather than by the person.
    public var scheduled: Bool
    /// The templates it was made of (`WarmUpTemplateRef` ids) and, for the person's own lists, their
    /// names at the time (a list deleted since is still named in the history).
    public var templates: [String]
    public var templateNames: [String: String]
    /// `WarmUpIntensity`'s raw value; nil for a run of an older screen's plan.
    public var intensity: String?
    /// The country the proxy exited in when it ran.
    public var countryCode: String?
    /// Sites the plan had, and pages that loaded.
    public var plannedSites: Int
    public var pages: Int
    public var searches: Int
    public var consents: Int
    /// Cookies the profile gained: of the sites the run visited, and of other domains.
    public var cookiesVisited: Int
    public var cookiesOther: Int
    public var sites: [WarmUpSiteVisit]

    public init(id: UUID = UUID(), startedAt: Date, endedAt: Date, result: WarmUpRunResult, stopReason: String? = nil, scheduled: Bool = false,
                templates: [String] = [], templateNames: [String: String] = [:], intensity: WarmUpIntensity? = nil, countryCode: String? = nil,
                plannedSites: Int = 0, pages: Int = 0, searches: Int = 0, consents: Int = 0, cookiesVisited: Int = 0, cookiesOther: Int = 0,
                sites: [WarmUpSiteVisit] = []) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.result = result.rawValue
        self.stopReason = stopReason
        self.scheduled = scheduled
        self.templates = templates
        self.templateNames = templateNames
        self.intensity = intensity?.rawValue
        self.countryCode = countryCode
        self.plannedSites = plannedSites
        self.pages = pages
        self.searches = searches
        self.consents = consents
        self.cookiesVisited = cookiesVisited
        self.cookiesOther = cookiesOther
        self.sites = sites
    }

    public var resultKind: WarmUpRunResult { WarmUpRunResult(rawValue: result) ?? .stopped }
    public var cookies: Int { cookiesVisited + cookiesOther }
    public var duration: TimeInterval { max(0, endedAt.timeIntervalSince(startedAt)) }
    /// Sites whose pages the run read.
    public var visitedSites: Int { sites.filter { $0.outcomeKind == .visited && $0.arrivalKind != .query }.count }
    public var blockedSites: [WarmUpSiteVisit] { sites.filter { $0.outcomeKind == .blocked } }
    public var failedSites: [WarmUpSiteVisit] { sites.filter { $0.outcomeKind == .failed || $0.outcomeKind == .timedOut } }
    public var hasRemarks: Bool { resultKind != .finished || sites.contains(where: \.isProblem) }

    /// The run of a status that is over (`WarmUpStatus`, with its per-site rows when the robot of
    /// this version sent them): nil while it runs, or when it never began a page.
    public init?(_ status: WarmUpStatus, plan: WarmUpPlan?, startedAt: Date, endedAt: Date, scheduled: Bool = false,
                 countryCode: String? = nil, templateNames: [String: String] = [:]) {
        guard !status.isRunning, status.visited > 0 || status.stopReason == "proxyNotAnswering" else { return nil }
        let result: WarmUpRunResult = status.phase == .finished ? .finished : status.stopReason == "proxyNotAnswering" ? .proxyNotAnswering : .stopped
        let rows = status.siteVisits ?? []
        let visited = Set(rows.map(\.site))
        var own = 0, other = 0
        for site in status.sites ?? [] where site.added > 0 {
            if visited.contains(site.site) { own += site.added } else { other += site.added }
        }
        // A robot of an older build sends no rows: the count alone, all taken as the sites' own.
        if status.sites == nil || rows.isEmpty { own = status.cookies; other = 0 }
        let choice = plan?.choice
        self.init(startedAt: status.startedAt ?? startedAt, endedAt: endedAt, result: result, stopReason: status.stopReason, scheduled: scheduled,
                  templates: choice?.templateIDs ?? [], templateNames: templateNames,
                  intensity: choice?.source == .templates ? choice?.intensity : nil, countryCode: countryCode,
                  plannedSites: plan.map { $0.pages().pages.filter { $0.kind == .address }.count } ?? status.total,
                  pages: status.pagesRead ?? max(0, status.visited - status.failed), searches: status.searchesTyped ?? 0, consents: status.consents ?? 0,
                  cookiesVisited: own, cookiesOther: other, sites: rows)
    }
}

/// A profile's warm-ups, the newest first — `warmup-history.bin`, sealed under the profile's key
/// like `warmup-last.bin`, on this Mac only: not synced, not in a profile's export.
public struct WarmUpHistory: Codable, Equatable, Sendable {
    public static let maximumRuns = 50

    public var runs: [WarmUpRun]

    public init(runs: [WarmUpRun] = []) {
        self.runs = runs
    }

    /// Adds a run at the front; the oldest beyond `maximumRuns` go.
    public mutating func add(_ run: WarmUpRun) {
        runs.insert(run, at: 0)
        if runs.count > Self.maximumRuns { runs.removeLast(runs.count - Self.maximumRuns) }
    }

    public var last: WarmUpRun? { runs.first }
}

/// Where a profile stands with warm-ups — what the lists show beside it.
public enum WarmUpWarmth: Equatable, Sendable {
    /// Never warmed up on this Mac.
    case never
    /// Its last warm-up went through (when).
    case warmed(Date)
    /// Its last warm-up read some sites and was stopped, or met checks on some (when).
    case partly(Date)
    /// Its last warm-up was ended by a problem: the proxy did not answer (when).
    case attention(Date)

    /// From the last run: finished without a blocked site — warmed; ended by the proxy — attention;
    /// anything else that read at least one site — partly; a run that read nothing leaves the
    /// profile as it was before it (`previous`).
    public init(last: WarmUpRun?, previous: WarmUpRun? = nil) {
        guard let last else { self = .never; return }
        switch last.resultKind {
        case .proxyNotAnswering, .notStarted:
            self = .attention(last.endedAt)
        case .finished:
            self = last.blockedSites.isEmpty ? .warmed(last.endedAt) : .partly(last.endedAt)
        case .stopped:
            if last.visitedSites > 0 { self = .partly(last.endedAt) } else { self = WarmUpWarmth(last: previous) }
        }
    }

    /// From the short record an older version kept (`WarmUpRecord`), when there is no history yet.
    public init(record: WarmUpRecord?) {
        guard let record else { self = .never; return }
        self = record.finished ? .warmed(record.endedAt) : .partly(record.endedAt)
    }

    public var isWarmed: Bool { if case .warmed = self { return true } else { return false } }
    public var needsAttention: Bool { if case .attention = self { return true } else { return false } }
    public var date: Date? {
        switch self {
        case .never: return nil
        case .warmed(let date), .partly(let date), .attention(let date): return date
        }
    }
}
