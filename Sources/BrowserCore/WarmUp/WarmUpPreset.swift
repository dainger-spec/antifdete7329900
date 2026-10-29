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
        // The same kind of list for each: the country's Google, its main news sites, the shop or
        // classifieds everyone uses, its weather service, a sports or property site — all of them
        // readable without an account, in the country's own language.
        WarmUpPreset(id: "nl", name: "Нидерланды", group: .country,
                     addresses: ["google.nl", "nu.nl", "nos.nl", "telegraaf.nl", "marktplaats.nl",
                                 "bol.com", "buienradar.nl", "funda.nl", "ah.nl"],
                     searches: ["weer morgen", "goedkope vliegtickets", "recept lasagne"]),
        WarmUpPreset(id: "ua", name: "Украина", group: .country,
                     addresses: ["google.com.ua", "pravda.com.ua", "unian.ua", "tsn.ua", "rozetka.com.ua",
                                 "olx.ua", "prom.ua", "sinoptik.ua", "ukr.net"],
                     searches: ["погода на завтра", "вакансії київ", "рецепт борщу"]),
        WarmUpPreset(id: "kz", name: "Казахстан", group: .country,
                     addresses: ["google.kz", "tengrinews.kz", "nur.kz", "zakon.kz", "kolesa.kz",
                                 "krisha.kz", "olx.kz", "kaspi.kz"],
                     searches: ["погода алматы", "курс тенге", "вакансии астана"]),
        WarmUpPreset(id: "ee", name: "Эстония", group: .country,
                     addresses: ["google.ee", "postimees.ee", "err.ee", "delfi.ee", "okidoki.ee",
                                 "kv.ee", "hinnavaatlus.ee", "ilmateenistus.ee"],
                     searches: ["ilm homme", "odavad lennupiletid", "lihtsad retseptid"]),
        WarmUpPreset(id: "lv", name: "Латвия", group: .country,
                     addresses: ["google.lv", "delfi.lv", "lsm.lv", "tvnet.lv", "ss.lv",
                                 "salidzini.lv", "inbox.lv", "sportacentrs.com"],
                     searches: ["laika prognoze rīt", "lēti lidojumi", "receptes vakariņām"]),
        WarmUpPreset(id: "lt", name: "Литва", group: .country,
                     addresses: ["google.lt", "delfi.lt", "lrt.lt", "15min.lt", "lrytas.lt",
                                 "skelbiu.lt", "pigu.lt", "meteo.lt"],
                     searches: ["orai rytoj", "pigūs skrydžiai", "receptai vakarienei"]),
        WarmUpPreset(id: "fi", name: "Финляндия", group: .country,
                     addresses: ["google.fi", "yle.fi", "hs.fi", "iltalehti.fi", "tori.fi",
                                 "verkkokauppa.com", "oikotie.fi", "ilmatieteenlaitos.fi"],
                     searches: ["sää huomenna", "halvat lennot", "helppo resepti"]),
        WarmUpPreset(id: "se", name: "Швеция", group: .country,
                     addresses: ["google.se", "aftonbladet.se", "svt.se", "dn.se", "expressen.se",
                                 "blocket.se", "prisjakt.nu", "hemnet.se", "smhi.se"],
                     searches: ["väder imorgon", "billiga flyg", "recept middag"]),
        WarmUpPreset(id: "no", name: "Норвегия", group: .country,
                     addresses: ["google.no", "vg.no", "nrk.no", "dagbladet.no", "finn.no",
                                 "prisjakt.no", "komplett.no", "yr.no"],
                     searches: ["været i morgen", "billige flybilletter", "middag oppskrift"]),
        WarmUpPreset(id: "dk", name: "Дания", group: .country,
                     addresses: ["google.dk", "dr.dk", "tv2.dk", "politiken.dk", "ekstrabladet.dk",
                                 "dba.dk", "pricerunner.dk", "boligsiden.dk", "dmi.dk"],
                     searches: ["vejret i morgen", "billige flybilletter", "opskrift aftensmad"]),
        WarmUpPreset(id: "cz", name: "Чехия", group: .country,
                     addresses: ["google.cz", "seznam.cz", "idnes.cz", "novinky.cz", "alza.cz",
                                 "heureka.cz", "bazos.cz", "sreality.cz", "chmi.cz"],
                     searches: ["počasí zítra", "levné letenky", "recept na večeři"]),
        WarmUpPreset(id: "pt", name: "Португалия", group: .country,
                     addresses: ["google.pt", "publico.pt", "jn.pt", "cmjornal.pt", "record.pt",
                                 "olx.pt", "worten.pt", "idealista.pt", "ipma.pt"],
                     searches: ["tempo amanhã", "voos baratos", "receitas fáceis"]),
        WarmUpPreset(id: "mx", name: "Мексика", group: .country,
                     addresses: ["google.com.mx", "eluniversal.com.mx", "milenio.com", "excelsior.com.mx",
                                 "mercadolibre.com.mx", "liverpool.com.mx", "inmuebles24.com", "record.com.mx"],
                     searches: ["clima mañana", "vuelos baratos", "recetas fáciles"]),
        WarmUpPreset(id: "ca", name: "Канада", group: .country,
                     addresses: ["google.ca", "cbc.ca", "ctvnews.ca", "theglobeandmail.com", "kijiji.ca",
                                 "canadiantire.ca", "realtor.ca", "tsn.ca", "theweathernetwork.com"],
                     searches: ["weather tomorrow", "hockey scores", "cheap flights canada"]),
        WarmUpPreset(id: "au", name: "Австралия", group: .country,
                     addresses: ["google.com.au", "abc.net.au", "smh.com.au", "news.com.au", "gumtree.com.au",
                                 "jbhifi.com.au", "realestate.com.au", "bom.gov.au"],
                     searches: ["weather tomorrow", "afl scores", "cheap flights to bali"]),
        WarmUpPreset(id: "jp", name: "Япония", group: .country,
                     addresses: ["google.co.jp", "yahoo.co.jp", "nhk.or.jp", "asahi.com", "mainichi.jp",
                                 "rakuten.co.jp", "kakaku.com", "cookpad.com", "tenki.jp"],
                     searches: ["明日の天気", "格安航空券", "簡単 レシピ"]),
        WarmUpPreset(id: "in", name: "Индия", group: .country,
                     addresses: ["google.co.in", "timesofindia.indiatimes.com", "ndtv.com", "hindustantimes.com",
                                 "flipkart.com", "amazon.in", "cricbuzz.com", "moneycontrol.com"],
                     searches: ["weather today", "cricket live score", "आज का मौसम"]),
    ]

    public static func preset(id: String) -> WarmUpPreset? { all.first { $0.id == id } }
}

extension WarmUpPresets {
    /// The country preset for an ISO 3166-1 alpha-2 code, when the app ships one.
    public static func country(_ code: String?) -> WarmUpPreset? {
        guard let code, !code.isEmpty else { return nil }
        return countries.first { $0.id.caseInsensitiveCompare(code) == .orderedSame }
    }

    /// A list put together here, from what the profile already says about itself: the country its
    /// proxy exits in, and the kinds of browsing chosen on the screen. The country's own sites
    /// lead and come twice as often as the rest, because that is what the profile is meant to look
    /// like; the order is shuffled within that, so two runs of the same choice are not the same
    /// list.
    ///
    /// Put together here, in the app: nothing is asked of any service and nothing about the
    /// profile leaves this Mac. A question like "sites for a German shopping profile" would tell a
    /// service more about the profile than the warm-up could gain from the answer.
    public static func composed(countryCode: String?, interests: [WarmUpPreset], name: String,
                                shuffle: ([String]) -> [String] = { $0.shuffled() }) -> WarmUpPreset {
        let local = country(countryCode)
        var localSites = shuffle(local?.addresses ?? [])
        var otherSites = shuffle(interests.flatMap(\.addresses) + (local == nil ? general.addresses : []))
        var addresses: [String] = []
        var seen: Set<String> = []
        // Two of the country's sites, then one of the rest, until both are spent.
        while !localSites.isEmpty || !otherSites.isEmpty {
            for _ in 0..<2 where !localSites.isEmpty {
                let site = localSites.removeFirst()
                if seen.insert(site).inserted { addresses.append(site) }
            }
            if !otherSites.isEmpty {
                let site = otherSites.removeFirst()
                if seen.insert(site).inserted { addresses.append(site) }
            }
        }
        let searches = shuffle((local?.searches ?? []) + interests.flatMap(\.searches))
        return WarmUpPreset(id: "composed", name: name, group: .general,
                            addresses: Array(addresses.prefix(WarmUpPlan.maximumPages)), searches: searches)
    }
}

extension WarmUpPlan {
    /// What one page of *this* plan costs on average — its own times, not a quality's — so that a
    /// hand-written plan gets an estimate too.
    public var secondsPerPage: TimeInterval {
        let inLimits = normalized
        let middle = (inLimits.minimumDwell + inLimits.maximumDwell) / 2
        return middle + 3 + (followLinks ? middle + 3 : 0)
    }

    /// Roughly how long a run of this plan takes, for the warm-up screen to show before it starts.
    public var estimatedSeconds: TimeInterval {
        Double(pages().pages.count) * secondsPerPage
    }
}
