import Foundation

/// How much a warm-up is: how many sites, how deep into each, how long on a page. One choice in
/// place of the minutes and the quality an older screen asked for separately. The numbers the
/// screen shows are these (`estimatedSeconds`, `sites`, `pagesPerSite`), so it cannot promise
/// what the robot does not do.
public enum WarmUpIntensity: String, CaseIterable, Codable, Sendable {
    case light, normal, deep

    /// Sites visited (fewer when the templates chosen have fewer for the profile's country).
    public var sites: Int {
        switch self {
        case .light: return 8
        case .normal: return 16
        case .deep: return 24
        }
    }

    /// Searches typed in the profile's search engine besides the sites.
    public var searches: Int {
        switch self {
        case .light: return 1
        case .normal: return 2
        case .deep: return 3
        }
    }

    /// The shortest and the longest stay on a page; within them a page is read for as long as it
    /// is (`WarmUpReading.dwell`).
    public var dwell: ClosedRange<TimeInterval> {
        switch self {
        case .light: return 15...70
        case .normal: return 12...70
        case .deep: return 20...120
        }
    }

    /// Links followed one after the other from a site's first page.
    public var linkHops: Int {
        switch self {
        case .light: return 1
        case .normal: return 2
        case .deep: return 3
        }
    }

    /// Pages read on one site: its first, and up to `linkHops` more.
    public var pagesPerSite: ClosedRange<Int> { 1...(1 + linkHops) }

    /// The share of the sites reached through the profile's search engine rather than by address,
    /// when the plan lets the robot arrive that way.
    public var searchArrivalShare: Double {
        switch self {
        case .light: return 0.25
        case .normal: return 0.35
        case .deep: return 0.4
        }
    }

    /// The quality an older version reads this as (`WarmUpChoice.quality`).
    public var quality: WarmUpQuality {
        switch self {
        case .light: return .quick
        case .normal: return .normal
        case .deep: return .deep
        }
    }

    public init(quality: WarmUpQuality) {
        switch quality {
        case .quick: self = .light
        case .normal: self = .normal
        case .deep: self = .deep
        }
    }

    /// Roughly how long a run takes with `sites` sites (nil: as many as the intensity asks for).
    public func estimatedSeconds(sites count: Int? = nil) -> TimeInterval {
        let pages = min(count ?? sites, sites) + searches
        return Double(pages) * WarmUpPlan.cost(minimumDwell: dwell.lowerBound, maximumDwell: dwell.upperBound, hops: linkHops)
    }

    /// The same in whole minutes, for a choice kept in an older version's terms (`WarmUpChoice.minutes`).
    public var minutes: Int { max(WarmUpChoice.minuteRange.lowerBound, Int((estimatedSeconds() / 60).rounded())) }
}

/// What the robot does with a cookie banner.
public enum WarmUpConsentChoice: String, CaseIterable, Codable, Sendable {
    /// Presses "accept": the most cookies, what a warm-up is for (the default).
    case accept
    /// Mostly accepts, now and then keeps only what is necessary, as people do.
    case asPeople
    /// Leaves the banner as it is.
    case leave
}

/// A template as a warm-up names it: one of the app's kinds of browsing (`WarmUpInterest`), or one
/// of the person's own lists (`WarmUpTemplate.presetID`, "user:<uuid>").
public enum WarmUpTemplateRef: Equatable, Sendable {
    case interest(WarmUpInterest)
    case user(String)

    public init?(id: String) {
        if id.hasPrefix("user:") {
            self = .user(id)
        } else if let interest = WarmUpInterest(presetID: id) {
            self = .interest(interest)
        } else {
            return nil
        }
    }

    public var id: String {
        switch self {
        case .interest(let interest): return interest.rawValue
        case .user(let id): return id
        }
    }
}

/// Puts a run together from the templates chosen, for one profile.
public enum WarmUpPlanner {
    /// What the templates come to for a profile whose proxy exits in `countryCode`: each template's
    /// sites in an order of its own, then taken in turn — one of the first template, one of the
    /// second… — so that a mix is a mix from its first sites on, each site once.
    ///
    /// A list of the person's own that asks for it (`WarmUpTemplate.addsEveryday`, on unless turned
    /// off) is given the country's everyday sites around it: a dozen shops in a row are a pattern.
    public static func preset(templates ids: [String], countryCode: String?, userTemplates: [WarmUpTemplate] = [],
                              using generator: inout some RandomNumberGenerator) -> WarmUpPreset? {
        var queues: [[String]] = []
        var searches: [String] = []
        var wantsEveryday = false
        var hasEveryday = false
        for ref in ids.compactMap(WarmUpTemplateRef.init(id:)) {
            switch ref {
            case .interest(let interest):
                let selection = WarmUpCatalog.selection(interest, countryCode: countryCode)
                queues.append(selection.sites.shuffled(using: &generator))
                searches += selection.searches
                if interest == .day { hasEveryday = true }
            case .user(let id):
                guard let template = userTemplates.first(where: { $0.presetID == id }) else { continue }
                queues.append(template.addresses.shuffled(using: &generator))
                searches += template.searches
                if template.addsEveryday ?? true { wantsEveryday = true }
            }
        }
        guard !queues.isEmpty else { return nil }
        if wantsEveryday, !hasEveryday {
            let everyday = WarmUpCatalog.selection(.day, countryCode: countryCode)
            queues.insert(everyday.sites.shuffled(using: &generator), at: 0)
            searches += everyday.searches
        }
        var sites: [String] = []
        var seen: Set<String> = []
        while queues.contains(where: { !$0.isEmpty }) {
            for index in queues.indices where !queues[index].isEmpty {
                let site = queues[index].removeFirst()
                if seen.insert(site.lowercased()).inserted { sites.append(site) }
            }
        }
        guard !sites.isEmpty else { return nil }
        var seenSearches: Set<String> = []
        let unique = searches.filter { seenSearches.insert($0.lowercased()).inserted }
        return WarmUpPreset(id: "templates", name: "", group: .general, addresses: sites, searches: unique)
    }

    /// The plan of one run: as many of the sites as the intensity visits, its searches chosen anew,
    /// the stays and the depth the intensity names.
    public static func plan(templates ids: [String], countryCode: String?, intensity: WarmUpIntensity,
                            userTemplates: [WarmUpTemplate] = [], viaSearch: Bool = true,
                            consent: WarmUpConsentChoice = .accept,
                            using generator: inout some RandomNumberGenerator) -> WarmUpPlan? {
        guard let preset = preset(templates: ids, countryCode: countryCode, userTemplates: userTemplates, using: &generator) else { return nil }
        let sites = Array(preset.addresses.prefix(min(intensity.sites, WarmUpPlan.maximumPages - intensity.searches)))
        let searches = Array(preset.searches.shuffled(using: &generator).prefix(intensity.searches))
        var plan = WarmUpPlan(addresses: sites.joined(separator: "\n"), searchQuery: searches.joined(separator: "\n"),
                              minimumDwell: intensity.dwell.lowerBound, maximumDwell: intensity.dwell.upperBound,
                              scroll: true, followLinks: true, linkHops: intensity.linkHops)
        plan.searchArrivalShare = viaSearch ? intensity.searchArrivalShare : 0
        plan.consent = consent.rawValue
        plan.readsByPage = true
        return plan
    }
}
