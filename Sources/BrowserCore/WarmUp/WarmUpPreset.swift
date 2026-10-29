import Foundation

/// A ready-made warm-up: the sites to visit and the searches to run, with two dials over them —
/// how long the run may take and how thoroughly each page is read.
///
/// The lists are part of the app. Nothing is fetched and nothing about the profile is sent
/// anywhere to build one: a request like "sites for a German shopping profile" would say more
/// about the profile than the warm-up gains. They are ordinary, widely used sites in each
/// country's own language, which is the point — a profile whose proxy exits in Germany and whose
/// history is entirely American reads as what it is.
public struct WarmUpPreset: Identifiable, Equatable, Sendable {
    public enum Group: String, Equatable, Sendable, CaseIterable {
        case general, country, interest
    }

    public let id: String
    /// Shown as it is; country presets carry the country's own name.
    public let name: String
    public let group: Group
    /// The sites, in the order they are visited.
    public let addresses: [String]
    /// Searches to start from, one is chosen per run (the profile's search engine runs it, and a
    /// run with `followLinks` goes into a result).
    public let searches: [String]

    public init(id: String, name: String, group: Group, addresses: [String], searches: [String] = []) {
        self.id = id
        self.name = name
        self.group = group
        self.addresses = addresses
        self.searches = searches
    }
}

/// How thoroughly a page is read. The numbers are what the robot does with each page, and they are
/// deliberately unremarkable: a warm-up that reads every page for exactly the same time, never
/// scrolls and never follows a link is itself a pattern.
public enum WarmUpQuality: String, Codable, CaseIterable, Sendable {
    /// Open, glance, move on.
    case quick
    /// Read it: scroll, stay a while.
    case normal
    /// Read it and go where it leads.
    case deep

    public var dwell: ClosedRange<TimeInterval> {
        switch self {
        case .quick: return 4...12
        case .normal: return 10...35
        case .deep: return 25...90
        }
    }

    public var scrolls: Bool { self != .quick }
    public var followsLinks: Bool { self == .deep }

    /// What one page costs on average, used to fit a run into the time it was given.
    var averageSeconds: TimeInterval {
        let middle = (dwell.lowerBound + dwell.upperBound) / 2
        // Loading, and the page a followed link leads to.
        return middle + 3 + (followsLinks ? middle + 3 : 0)
    }
}

extension WarmUpPlan {
    /// Builds a plan from a preset: as many of its sites as fit into `minutes` at this quality, in
    /// the preset's order, with one of its searches first when it has any.
    ///
    /// Running out of time cuts the list rather than hurrying through it: pages read in a hurry are
    /// what a warm-up is trying not to look like.
    public static func from(preset: WarmUpPreset, minutes: Int, quality: WarmUpQuality,
                            randomness: @autoclosure () -> Double = Double.random(in: 0...1)) -> WarmUpPlan {
        let budget = TimeInterval(max(1, minutes) * 60)
        var fits = Int(budget / quality.averageSeconds)
        let search = preset.searches.isEmpty ? "" : preset.searches[Int(randomness() * Double(preset.searches.count)) % preset.searches.count]
        if !search.isEmpty { fits -= 1 } // the search results are a page of the run too
        let addresses = Array(preset.addresses.prefix(max(1, min(fits, WarmUpPlan.maximumPages))))
        return WarmUpPlan(addresses: addresses.joined(separator: "\n"),
                          searchQuery: search,
                          minimumDwell: quality.dwell.lowerBound,
                          maximumDwell: quality.dwell.upperBound,
                          scroll: quality.scrolls,
                          followLinks: quality.followsLinks)
    }

    /// Roughly how long a run of this plan takes, for the warm-up screen to show before it starts.
    public func estimatedMinutes(quality: WarmUpQuality) -> Int {
        let pages = pages().pages.count
        return max(1, Int((Double(pages) * quality.averageSeconds / 60).rounded()))
    }
}

public enum WarmUpPresets {
    /// Everything the app ships, in the order the warm-up screen lists it.
    public static let all: [WarmUpPreset] = [general, light, shopping, media, work] + countries

    public static let general = WarmUpPreset(
        id: "general", name: "Обычный день", group: .general,
        addresses: ["wikipedia.org", "youtube.com", "reddit.com", "imdb.com", "weather.com",
                    "booking.com", "ebay.com", "tripadvisor.com", "pinterest.com", "quora.com"],
        searches: ["weather tomorrow", "how to cook rice", "cheap flights", "best laptop 2026"])

    public static let light = WarmUpPreset(
        id: "light", name: "Короткий", group: .general,
        addresses: ["wikipedia.org", "youtube.com", "weather.com"],
        searches: ["news today"])

    public static let shopping = WarmUpPreset(
        id: "shopping", name: "Покупки", group: .interest,
        addresses: ["amazon.com", "ebay.com", "etsy.com", "aliexpress.com", "walmart.com",
                    "ikea.com", "zalando.com", "asos.com"],
        searches: ["running shoes", "coffee machine", "winter jacket"])

    public static let media = WarmUpPreset(
        id: "media", name: "Новости и медиа", group: .interest,
        addresses: ["bbc.com", "theguardian.com", "reuters.com", "cnn.com", "nytimes.com",
                    "youtube.com", "spotify.com", "imdb.com"],
        searches: ["football results", "film premieres"])

    public static let work = WarmUpPreset(
        id: "work", name: "Работа", group: .interest,
        addresses: ["linkedin.com", "github.com", "stackoverflow.com", "notion.so", "slack.com",
                    "zoom.us", "canva.com", "medium.com"],
        searches: ["remote jobs", "how to write a cv"])

    /// Sites people in that country use, in its own language: a profile whose proxy exits there and
    /// whose history is entirely American is a profile that does not add up.
    public static let countries: [WarmUpPreset] = [
        WarmUpPreset(id: "de", name: "Германия", group: .country,
                     addresses: ["google.de", "spiegel.de", "zeit.de", "idealo.de", "otto.de",
                                 "chefkoch.de", "mobile.de", "wetter.de", "kicker.de"],
                     searches: ["wetter morgen", "günstige flüge", "beste laptops 2026"]),
        WarmUpPreset(id: "fr", name: "Франция", group: .country,
                     addresses: ["google.fr", "lemonde.fr", "leboncoin.fr", "fnac.com", "marmiton.org",
                                 "meteofrance.com", "lequipe.fr", "allocine.fr"],
                     searches: ["météo demain", "recette poulet", "vol pas cher"]),
        WarmUpPreset(id: "gb", name: "Великобритания", group: .country,
                     addresses: ["google.co.uk", "bbc.co.uk", "theguardian.com", "argos.co.uk",
                                 "rightmove.co.uk", "metoffice.gov.uk", "skysports.com", "gumtree.com"],
                     searches: ["weather tomorrow", "train times", "best broadband deals"]),
        WarmUpPreset(id: "es", name: "Испания", group: .country,
                     addresses: ["google.es", "elpais.com", "marca.com", "elmundo.es", "idealista.com",
                                 "milanuncios.com", "eltiempo.es", "filmaffinity.com"],
                     searches: ["el tiempo mañana", "ofertas de trabajo", "recetas fáciles"]),
        WarmUpPreset(id: "it", name: "Италия", group: .country,
                     addresses: ["google.it", "corriere.it", "repubblica.it", "subito.it", "immobiliare.it",
                                 "ilmeteo.it", "gazzetta.it", "giallozafferano.it"],
                     searches: ["meteo domani", "offerte di lavoro", "ricette veloci"]),
        WarmUpPreset(id: "pl", name: "Польша", group: .country,
                     addresses: ["google.pl", "onet.pl", "wp.pl", "allegro.pl", "olx.pl",
                                 "interia.pl", "filmweb.pl", "pogodynka.pl"],
                     searches: ["pogoda jutro", "praca zdalna", "przepisy obiad"]),
        WarmUpPreset(id: "us", name: "США", group: .country,
                     addresses: ["google.com", "nytimes.com", "cnn.com", "amazon.com", "walmart.com",
                                 "zillow.com", "espn.com", "weather.com", "yelp.com"],
                     searches: ["weather tomorrow", "jobs near me", "best credit cards"]),
        WarmUpPreset(id: "br", name: "Бразилия", group: .country,
                     addresses: ["google.com.br", "globo.com", "uol.com.br", "mercadolivre.com.br",
                                 "americanas.com.br", "climatempo.com.br", "ge.globo.com"],
                     searches: ["previsão do tempo", "vagas de emprego", "receitas fáceis"]),
        WarmUpPreset(id: "tr", name: "Турция", group: .country,
                     addresses: ["google.com.tr", "hurriyet.com.tr", "sahibinden.com", "trendyol.com",
                                 "mynet.com", "mackolik.com", "havadurumu15gunluk.xyz"],
                     searches: ["hava durumu yarın", "iş ilanları", "kolay yemek tarifleri"]),
    ]

    public static func preset(id: String) -> WarmUpPreset? { all.first { $0.id == id } }
}
