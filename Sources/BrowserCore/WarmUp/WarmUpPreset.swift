import Foundation

/// A ready-made warm-up ("template"): the sites to visit and the searches to run, with two dials
/// over them — how long the run may take and how thoroughly each page is read.
///
/// The lists are part of the app. Nothing is fetched and nothing about the profile is sent
/// anywhere to build one: a request like "sites for a German shopping profile" would say more
/// about the profile than the warm-up gains. They are ordinary, widely used sites in each
/// country's own language, which is the point — a profile whose proxy exits in Germany and whose
/// history is entirely American reads as what it is. Every site of them is readable without an
/// account.
public struct WarmUpPreset: Identifiable, Equatable, Sendable {
    public enum Group: String, Equatable, Sendable, CaseIterable {
        case general, country, interest
        /// The person's own templates (`WarmUpTemplate`), kept in the vault.
        case user
    }

    public let id: String
    /// Shown when the app has no name of its own for it (the screen names the lists it ships in
    /// the interface's language, a country's by the country, the person's by what they called it).
    public let name: String
    public let group: Group
    /// The sites: a run visits them in an order of its own (`WarmUpPlan.from`).
    public let addresses: [String]
    /// Searches to run: two or three of them per run, chosen anew each time (the profile's search
    /// engine runs them, and a run that follows links goes into a result).
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

    /// The shortest and the longest stay on a page; the stays fall mostly near the shorter, now
    /// and then long (`WarmUpTiming.dwell`).
    public var dwell: ClosedRange<TimeInterval> {
        switch self {
        case .quick: return 4...14
        case .normal: return 8...45
        case .deep: return 20...120
        }
    }

    public var scrolls: Bool { self != .quick }

    /// Links followed one after the other from each site: at least the lower bound, and, when the
    /// time given has room once every site of the list is in, up to the upper (`WarmUpPlan.from`).
    public var linkHops: ClosedRange<Int> {
        switch self {
        case .quick: return 0...1
        case .normal: return 0...2
        case .deep: return 2...3
        }
    }

    /// What one page costs on average with `hops` links followed from it, for fitting a run into
    /// the time it was given (`WarmUpPlan.cost`).
    func secondsPerPage(hops: Int) -> TimeInterval {
        WarmUpPlan.cost(minimumDwell: dwell.lowerBound, maximumDwell: dwell.upperBound, hops: hops)
    }
}

extension WarmUpPlan {
    /// What a page costs on average: its stay (`WarmUpTiming.meanDwell`) and its loading, and for
    /// each link followed from it, half a stay more (the robot reads a followed page half as long)
    /// with finding, aiming at and loading the link.
    static func cost(minimumDwell: TimeInterval, maximumDwell: TimeInterval, hops: Int) -> TimeInterval {
        let stay = WarmUpTiming.meanDwell(minimumDwell, maximumDwell)
        return stay + 3 + Double(max(0, hops)) * (stay / 2 + 4)
    }

    /// Builds a plan from a preset for a run of about `minutes` at this quality.
    ///
    /// * The sites come in an order of their own each run (`generator`), so that two short runs of
    ///   one list are not the same few sites; `keepingOrder` keeps a list typed by hand as typed.
    /// * Two or three of its searches, chosen anew, come first and between the sites.
    /// * The time decides how much: first as many sites as fit, then — once every site is in —
    ///   more links followed from each (`WarmUpQuality.linkHops`). More minutes is a wider run,
    ///   then a deeper one.
    ///
    /// Running out of time cuts the list rather than hurrying through it: pages read in a hurry are
    /// what a warm-up is trying not to look like.
    public static func from(preset: WarmUpPreset, minutes: Int, quality: WarmUpQuality, keepingOrder: Bool = false,
                            using generator: inout some RandomNumberGenerator) -> WarmUpPlan {
        let budget = TimeInterval(max(1, minutes) * 60)
        var seen: Set<String> = []
        let unique = preset.addresses.filter { seen.insert($0.lowercased()).inserted }
        let sites = keepingOrder ? unique : unique.shuffled(using: &generator)
        let wanted = preset.searches.isEmpty ? 0 : min(preset.searches.count, Int.random(in: 2...3, using: &generator))
        var searches = Array(preset.searches.shuffled(using: &generator).prefix(wanted))
        var hops = quality.linkHops.lowerBound
        func fits(_ hops: Int) -> Int { Int(budget / quality.secondsPerPage(hops: hops)) }
        // A search for every three sites at most: a short run is mostly sites.
        let room = max(1, fits(hops))
        searches = Array(searches.prefix(max(0, (room - 1) / 3)))
        // Deeper only while the whole list still fits: sites first, depth with the time left over.
        while hops < quality.linkHops.upperBound, fits(hops + 1) >= sites.count + searches.count { hops += 1 }
        let pages = min(max(1, fits(hops)), sites.count + searches.count, WarmUpPlan.maximumPages)
        let addresses = Array(sites.prefix(max(1, pages - searches.count)))
        return WarmUpPlan(addresses: addresses.joined(separator: "\n"),
                          searchQuery: searches.joined(separator: "\n"),
                          minimumDwell: quality.dwell.lowerBound,
                          maximumDwell: quality.dwell.upperBound,
                          scroll: quality.scrolls,
                          followLinks: hops > 0,
                          linkHops: hops > 0 ? hops : nil)
    }

    /// The same, with the system's generator: a run of its own each time.
    public static func from(preset: WarmUpPreset, minutes: Int, quality: WarmUpQuality, keepingOrder: Bool = false) -> WarmUpPlan {
        var generator = SystemRandomNumberGenerator()
        return from(preset: preset, minutes: minutes, quality: quality, keepingOrder: keepingOrder, using: &generator)
    }

    /// What one page of *this* plan costs on average — its own times and links, not a quality's —
    /// so that a hand-written plan gets an estimate too.
    public var secondsPerPage: TimeInterval {
        let inLimits = normalized
        return Self.cost(minimumDwell: inLimits.minimumDwell, maximumDwell: inLimits.maximumDwell, hops: hops)
    }

    /// Roughly how long a run of this plan takes, for the warm-up screen to show before it starts.
    public var estimatedSeconds: TimeInterval {
        Double(pages().pages.count) * secondsPerPage
    }
}

public enum WarmUpPresets {
    /// Everything the app ships, in the order the warm-up screen lists it: the countries first.
    public static let all: [WarmUpPreset] = countries + [general, light] + interests

    /// The kinds of browsing, mixed into a list composed for a profile (`composed`) or run alone.
    public static let interests: [WarmUpPreset] = [media, shopping, work, social, video, travel, finance, games, tech, food, sports]

    public static let general = WarmUpPreset(
        id: "general", name: "Обычный день", group: .general,
        addresses: ["wikipedia.org", "youtube.com", "reddit.com", "imdb.com", "weather.com",
                    "booking.com", "ebay.com", "tripadvisor.com", "pinterest.com", "quora.com",
                    "bbc.com", "amazon.com"],
        searches: ["weather tomorrow", "how to cook rice", "cheap flights", "best laptop 2026", "news today"])

    public static let light = WarmUpPreset(
        id: "light", name: "Короткий", group: .general,
        addresses: ["wikipedia.org", "youtube.com", "weather.com"],
        searches: ["news today", "weather tomorrow"])

    public static let shopping = WarmUpPreset(
        id: "shopping", name: "Покупки", group: .interest,
        addresses: ["amazon.com", "ebay.com", "etsy.com", "aliexpress.com", "walmart.com",
                    "ikea.com", "zalando.com", "asos.com"],
        searches: ["running shoes", "coffee machine", "winter jacket", "wireless headphones"])

    public static let media = WarmUpPreset(
        id: "media", name: "Новости и медиа", group: .interest,
        addresses: ["bbc.com", "theguardian.com", "reuters.com", "cnn.com", "nytimes.com",
                    "youtube.com", "spotify.com", "imdb.com"],
        searches: ["football results", "film premieres", "news today"])

    public static let work = WarmUpPreset(
        id: "work", name: "Работа", group: .interest,
        addresses: ["linkedin.com", "github.com", "stackoverflow.com", "notion.so", "slack.com",
                    "zoom.us", "canva.com", "medium.com"],
        searches: ["remote jobs", "how to write a cv", "excel formulas"])

    /// Social sites read without an account.
    public static let social = WarmUpPreset(
        id: "social", name: "Соцсети без входа", group: .interest,
        addresses: ["reddit.com", "pinterest.com", "quora.com", "medium.com", "tumblr.com"],
        searches: ["home decor ideas", "funny cat videos", "how to start a blog"])

    public static let video = WarmUpPreset(
        id: "video", name: "Видео", group: .interest,
        addresses: ["youtube.com", "twitch.tv", "vimeo.com", "dailymotion.com"],
        searches: ["music video", "documentary", "live stream"])

    public static let travel = WarmUpPreset(
        id: "travel", name: "Путешествия", group: .interest,
        addresses: ["booking.com", "airbnb.com", "tripadvisor.com", "skyscanner.net", "expedia.com"],
        searches: ["cheap flights", "hotels in barcelona", "things to do in rome"])

    public static let finance = WarmUpPreset(
        id: "finance", name: "Финансы", group: .interest,
        addresses: ["investing.com", "finance.yahoo.com", "coinmarketcap.com", "tradingview.com"],
        searches: ["bitcoin price", "s&p 500 today", "eur usd"])

    public static let games = WarmUpPreset(
        id: "games", name: "Игры", group: .interest,
        addresses: ["store.steampowered.com", "ign.com", "gamespot.com", "epicgames.com"],
        searches: ["best games 2026", "free games", "game reviews"])

    public static let tech = WarmUpPreset(
        id: "tech", name: "Технологии", group: .interest,
        addresses: ["theverge.com", "techcrunch.com", "wired.com", "arstechnica.com", "producthunt.com"],
        searches: ["best laptop 2026", "ai news", "smartphone review"])

    public static let food = WarmUpPreset(
        id: "food", name: "Кулинария", group: .interest,
        addresses: ["allrecipes.com", "seriouseats.com", "bbcgoodfood.com"],
        searches: ["easy pasta recipe", "chocolate cake recipe", "healthy breakfast ideas"])

    public static let sports = WarmUpPreset(
        id: "sports", name: "Спорт", group: .interest,
        addresses: ["espn.com", "goal.com", "eurosport.com"],
        searches: ["champions league results", "nba scores", "formula 1 standings"])

    /// Sites people in that country use, in its own language: a profile whose proxy exits there and
    /// whose history is entirely American is a profile that does not add up.
    ///
    /// The same kind of list for each: the search engine people there start from, two to four news
    /// sites, the shops and classifieds everyone uses, the weather service, maps (the country's own
    /// where it has them), video, sport, travel or property, and its Wikipedia — all of them
    /// readable without an account, and only domains known for certain (when in doubt, a site was
    /// left out rather than guessed). Five or six searches each, in the country's own language.
    public static let countries: [WarmUpPreset] = [
        WarmUpPreset(id: "de", name: "Германия", group: .country,
                     addresses: ["google.de", "spiegel.de", "zeit.de", "tagesschau.de", "idealo.de", "otto.de",
                                 "kleinanzeigen.de", "chefkoch.de", "mobile.de", "wetter.de", "kicker.de",
                                 "de.wikipedia.org", "google.de/maps", "youtube.com"],
                     searches: ["wetter morgen", "günstige flüge", "beste laptops 2026", "rezept kartoffelsalat",
                                "bundesliga tabelle", "bahn fahrplan"]),
        WarmUpPreset(id: "fr", name: "Франция", group: .country,
                     addresses: ["google.fr", "lemonde.fr", "lefigaro.fr", "francetvinfo.fr", "leboncoin.fr", "fnac.com",
                                 "cdiscount.com", "marmiton.org", "meteofrance.com", "lequipe.fr", "allocine.fr",
                                 "fr.wikipedia.org", "google.fr/maps", "youtube.com"],
                     searches: ["météo demain", "recette poulet", "vol pas cher", "résultats ligue 1", "horaires sncf",
                                "programme tv ce soir"]),
        WarmUpPreset(id: "gb", name: "Великобритания", group: .country,
                     addresses: ["google.co.uk", "bbc.co.uk", "theguardian.com", "independent.co.uk", "argos.co.uk",
                                 "rightmove.co.uk", "gumtree.com", "ebay.co.uk", "metoffice.gov.uk", "skysports.com",
                                 "bbcgoodfood.com", "en.wikipedia.org", "google.co.uk/maps", "youtube.com"],
                     searches: ["weather tomorrow", "train times", "best broadband deals", "premier league table",
                                "easy dinner recipes", "bank holidays 2026"]),
        WarmUpPreset(id: "es", name: "Испания", group: .country,
                     addresses: ["google.es", "elpais.com", "elmundo.es", "20minutos.es", "marca.com", "as.com",
                                 "idealista.com", "milanuncios.com", "wallapop.com", "eltiempo.es", "aemet.es",
                                 "filmaffinity.com", "es.wikipedia.org", "google.es/maps"],
                     searches: ["el tiempo mañana", "ofertas de trabajo", "recetas fáciles", "resultados la liga",
                                "vuelos baratos", "horarios renfe"]),
        WarmUpPreset(id: "it", name: "Италия", group: .country,
                     addresses: ["google.it", "corriere.it", "repubblica.it", "ansa.it", "gazzetta.it", "subito.it",
                                 "immobiliare.it", "amazon.it", "ilmeteo.it", "giallozafferano.it", "trenitalia.com",
                                 "it.wikipedia.org", "google.it/maps", "youtube.com"],
                     searches: ["meteo domani", "offerte di lavoro", "ricette veloci", "classifica serie a",
                                "voli economici", "orari treni"]),
        WarmUpPreset(id: "pl", name: "Польша", group: .country,
                     addresses: ["google.pl", "onet.pl", "wp.pl", "interia.pl", "gazeta.pl", "allegro.pl", "olx.pl",
                                 "otomoto.pl", "ceneo.pl", "filmweb.pl", "sport.pl", "pogodynka.pl",
                                 "pl.wikipedia.org", "google.pl/maps"],
                     searches: ["pogoda jutro", "praca zdalna", "przepisy obiad", "tanie loty", "wyniki ekstraklasy",
                                "rozkład jazdy pkp"]),
        WarmUpPreset(id: "us", name: "США", group: .country,
                     addresses: ["google.com", "nytimes.com", "cnn.com", "apnews.com", "amazon.com", "walmart.com",
                                 "target.com", "craigslist.org", "zillow.com", "espn.com", "weather.com", "yelp.com",
                                 "en.wikipedia.org", "google.com/maps", "youtube.com"],
                     searches: ["weather tomorrow", "jobs near me", "best credit cards", "nfl scores",
                                "easy dinner recipes", "cheap flights"]),
        WarmUpPreset(id: "br", name: "Бразилия", group: .country,
                     addresses: ["google.com.br", "globo.com", "g1.globo.com", "uol.com.br", "folha.uol.com.br",
                                 "mercadolivre.com.br", "americanas.com.br", "olx.com.br", "climatempo.com.br",
                                 "ge.globo.com", "tudogostoso.com.br", "pt.wikipedia.org", "google.com.br/maps", "youtube.com"],
                     searches: ["previsão do tempo", "vagas de emprego", "receitas fáceis", "tabela brasileirão",
                                "passagens aéreas baratas", "cotação do dólar"]),
        WarmUpPreset(id: "tr", name: "Турция", group: .country,
                     addresses: ["google.com.tr", "hurriyet.com.tr", "sozcu.com.tr", "milliyet.com.tr", "ntv.com.tr",
                                 "sahibinden.com", "trendyol.com", "hepsiburada.com", "mynet.com", "mackolik.com",
                                 "mgm.gov.tr", "tr.wikipedia.org", "google.com.tr/maps", "youtube.com"],
                     searches: ["hava durumu yarın", "iş ilanları", "kolay yemek tarifleri", "süper lig puan durumu",
                                "ucuz uçak bileti", "dolar kuru"]),
        WarmUpPreset(id: "nl", name: "Нидерланды", group: .country,
                     addresses: ["google.nl", "nu.nl", "nos.nl", "telegraaf.nl", "ad.nl", "marktplaats.nl", "bol.com",
                                 "coolblue.nl", "buienradar.nl", "funda.nl", "ah.nl", "ns.nl", "nl.wikipedia.org",
                                 "google.nl/maps"],
                     searches: ["weer morgen", "goedkope vliegtickets", "recept lasagne", "eredivisie stand",
                                "ns reisplanner", "vacatures"]),
        WarmUpPreset(id: "ua", name: "Украина", group: .country,
                     addresses: ["google.com.ua", "pravda.com.ua", "unian.ua", "tsn.ua", "ukr.net", "rozetka.com.ua",
                                 "olx.ua", "prom.ua", "sinoptik.ua", "football.ua", "uk.wikipedia.org",
                                 "google.com.ua/maps", "youtube.com"],
                     searches: ["погода на завтра", "вакансії київ", "рецепт борщу", "курс долара", "розклад поїздів",
                                "новини україни"]),
        WarmUpPreset(id: "kz", name: "Казахстан", group: .country,
                     addresses: ["google.kz", "tengrinews.kz", "nur.kz", "zakon.kz", "kolesa.kz", "krisha.kz", "olx.kz",
                                 "kaspi.kz", "2gis.kz", "kazhydromet.kz", "sports.kz", "ru.wikipedia.org", "youtube.com"],
                     searches: ["погода алматы", "курс тенге", "вакансии астана", "рецепт бешбармака",
                                "авиабилеты дешево", "новости казахстана"]),
        WarmUpPreset(id: "ee", name: "Эстония", group: .country,
                     addresses: ["google.ee", "postimees.ee", "err.ee", "delfi.ee", "ohtuleht.ee", "okidoki.ee", "kv.ee",
                                 "auto24.ee", "hinnavaatlus.ee", "ilmateenistus.ee", "et.wikipedia.org", "google.ee/maps",
                                 "youtube.com"],
                     searches: ["ilm homme", "odavad lennupiletid", "lihtsad retseptid", "tööpakkumised",
                                "bussi sõiduplaan", "uudised"]),
        WarmUpPreset(id: "lv", name: "Латвия", group: .country,
                     addresses: ["google.lv", "delfi.lv", "lsm.lv", "tvnet.lv", "apollo.lv", "ss.lv", "salidzini.lv",
                                 "inbox.lv", "sportacentrs.com", "meteo.lv", "lv.wikipedia.org", "google.lv/maps",
                                 "youtube.com"],
                     searches: ["laika prognoze rīt", "lēti lidojumi", "receptes vakariņām", "darba piedāvājumi",
                                "valūtas kurss", "ziņas"]),
        WarmUpPreset(id: "lt", name: "Литва", group: .country,
                     addresses: ["google.lt", "delfi.lt", "lrt.lt", "15min.lt", "lrytas.lt", "skelbiu.lt", "pigu.lt",
                                 "autoplius.lt", "aruodas.lt", "meteo.lt", "lt.wikipedia.org", "google.lt/maps",
                                 "youtube.com"],
                     searches: ["orai rytoj", "pigūs skrydžiai", "receptai vakarienei", "darbo skelbimai",
                                "krepšinio rezultatai", "valiutų kursai"]),
        WarmUpPreset(id: "fi", name: "Финляндия", group: .country,
                     addresses: ["google.fi", "yle.fi", "hs.fi", "iltalehti.fi", "is.fi", "tori.fi", "verkkokauppa.com",
                                 "oikotie.fi", "ilmatieteenlaitos.fi", "foreca.fi", "vr.fi", "fi.wikipedia.org",
                                 "google.fi/maps", "youtube.com"],
                     searches: ["sää huomenna", "halvat lennot", "helppo resepti", "työpaikat", "vr aikataulut",
                                "jääkiekko tulokset"]),
        WarmUpPreset(id: "se", name: "Швеция", group: .country,
                     addresses: ["google.se", "aftonbladet.se", "svt.se", "dn.se", "expressen.se", "blocket.se",
                                 "prisjakt.nu", "hemnet.se", "smhi.se", "klart.se", "sj.se", "sv.wikipedia.org",
                                 "google.se/maps", "youtube.com"],
                     searches: ["väder imorgon", "billiga flyg", "recept middag", "lediga jobb", "allsvenskan tabell",
                                "sj tidtabell"]),
        WarmUpPreset(id: "no", name: "Норвегия", group: .country,
                     addresses: ["google.no", "vg.no", "nrk.no", "dagbladet.no", "aftenposten.no", "finn.no",
                                 "prisjakt.no", "komplett.no", "yr.no", "vy.no", "no.wikipedia.org", "google.no/maps",
                                 "youtube.com"],
                     searches: ["været i morgen", "billige flybilletter", "middag oppskrift", "ledige stillinger",
                                "eliteserien tabell", "vy togtider"]),
        WarmUpPreset(id: "dk", name: "Дания", group: .country,
                     addresses: ["google.dk", "dr.dk", "tv2.dk", "politiken.dk", "ekstrabladet.dk", "bt.dk", "dba.dk",
                                 "pricerunner.dk", "boligsiden.dk", "dmi.dk", "rejseplanen.dk", "da.wikipedia.org",
                                 "google.dk/maps", "youtube.com"],
                     searches: ["vejret i morgen", "billige flybilletter", "opskrift aftensmad", "ledige stillinger",
                                "superliga stilling", "rejseplanen"]),
        WarmUpPreset(id: "cz", name: "Чехия", group: .country,
                     addresses: ["seznam.cz", "google.cz", "idnes.cz", "novinky.cz", "aktualne.cz", "alza.cz",
                                 "heureka.cz", "bazos.cz", "sreality.cz", "chmi.cz", "mapy.cz", "sport.cz", "idos.cz",
                                 "cs.wikipedia.org", "youtube.com"],
                     searches: ["počasí zítra", "levné letenky", "recept na večeři", "volná místa", "vlakové spojení",
                                "kurz eura"]),
        WarmUpPreset(id: "pt", name: "Португалия", group: .country,
                     addresses: ["google.pt", "publico.pt", "jn.pt", "cmjornal.pt", "observador.pt", "record.pt",
                                 "abola.pt", "olx.pt", "worten.pt", "idealista.pt", "ipma.pt", "cp.pt",
                                 "pt.wikipedia.org", "google.pt/maps", "youtube.com"],
                     searches: ["tempo amanhã", "voos baratos", "receitas fáceis", "ofertas de emprego",
                                "classificação liga portugal", "horários cp"]),
        WarmUpPreset(id: "mx", name: "Мексика", group: .country,
                     addresses: ["google.com.mx", "eluniversal.com.mx", "milenio.com", "excelsior.com.mx",
                                 "elfinanciero.com.mx", "mercadolibre.com.mx", "liverpool.com.mx", "amazon.com.mx",
                                 "inmuebles24.com", "record.com.mx", "smn.conagua.gob.mx", "es.wikipedia.org",
                                 "google.com.mx/maps", "youtube.com"],
                     searches: ["clima mañana", "vuelos baratos", "recetas fáciles", "bolsa de trabajo",
                                "resultados liga mx", "tipo de cambio dólar"]),
        WarmUpPreset(id: "ca", name: "Канада", group: .country,
                     addresses: ["google.ca", "cbc.ca", "ctvnews.ca", "theglobeandmail.com", "globalnews.ca", "kijiji.ca",
                                 "canadiantire.ca", "bestbuy.ca", "realtor.ca", "tsn.ca", "sportsnet.ca",
                                 "theweathernetwork.com", "en.wikipedia.org", "google.ca/maps"],
                     searches: ["weather tomorrow", "hockey scores", "cheap flights canada", "jobs near me",
                                "easy dinner recipes", "gas prices"]),
        WarmUpPreset(id: "au", name: "Австралия", group: .country,
                     addresses: ["google.com.au", "abc.net.au", "smh.com.au", "news.com.au", "theage.com.au",
                                 "gumtree.com.au", "jbhifi.com.au", "realestate.com.au", "domain.com.au", "bom.gov.au",
                                 "afl.com.au", "taste.com.au", "en.wikipedia.org", "google.com.au/maps"],
                     searches: ["weather tomorrow", "afl scores", "cheap flights to bali", "jobs near me",
                                "easy dinner recipes", "petrol prices"]),
        WarmUpPreset(id: "jp", name: "Япония", group: .country,
                     addresses: ["google.co.jp", "yahoo.co.jp", "nhk.or.jp", "asahi.com", "mainichi.jp", "yomiuri.co.jp",
                                 "rakuten.co.jp", "amazon.co.jp", "kakaku.com", "cookpad.com", "tenki.jp", "tabelog.com",
                                 "ja.wikipedia.org", "youtube.com"],
                     searches: ["明日の天気", "格安航空券", "簡単 レシピ", "求人", "プロ野球 結果", "乗換案内"]),
        WarmUpPreset(id: "in", name: "Индия", group: .country,
                     addresses: ["google.co.in", "timesofindia.indiatimes.com", "ndtv.com", "hindustantimes.com",
                                 "indianexpress.com", "flipkart.com", "amazon.in", "cricbuzz.com", "espncricinfo.com",
                                 "moneycontrol.com", "mausam.imd.gov.in", "en.wikipedia.org", "google.co.in/maps",
                                 "youtube.com"],
                     searches: ["weather today", "cricket live score", "आज का मौसम", "jobs in bangalore",
                                "gold rate today", "train running status"]),
        WarmUpPreset(id: "ru", name: "Россия", group: .country,
                     addresses: ["ya.ru", "dzen.ru", "rbc.ru", "lenta.ru", "ria.ru", "avito.ru", "ozon.ru",
                                 "wildberries.ru", "gismeteo.ru", "kinopoisk.ru", "2gis.ru", "sport-express.ru",
                                 "championat.com", "rutube.ru", "ru.wikipedia.org"],
                     searches: ["погода на завтра", "рецепт борща", "курс доллара", "авиабилеты дешево",
                                "вакансии москва", "расписание электричек"]),
        WarmUpPreset(id: "at", name: "Австрия", group: .country,
                     addresses: ["google.at", "orf.at", "derstandard.at", "krone.at", "diepresse.com", "kurier.at",
                                 "willhaben.at", "geizhals.at", "laola1.at", "wetter.at", "oebb.at", "gutekueche.at",
                                 "de.wikipedia.org", "google.at/maps"],
                     searches: ["wetter morgen wien", "günstige flüge", "rezept schnitzel", "jobs wien",
                                "bundesliga tabelle österreich", "öbb fahrplan"]),
        WarmUpPreset(id: "ch", name: "Швейцария", group: .country,
                     addresses: ["google.ch", "20min.ch", "blick.ch", "srf.ch", "nzz.ch", "tagesanzeiger.ch", "ricardo.ch",
                                 "tutti.ch", "digitec.ch", "galaxus.ch", "homegate.ch", "meteoschweiz.admin.ch", "sbb.ch",
                                 "de.wikipedia.org", "google.ch/maps"],
                     searches: ["wetter morgen", "sbb fahrplan", "günstige flüge", "rezept rösti",
                                "stellenangebote zürich", "super league tabelle"]),
        WarmUpPreset(id: "be", name: "Бельгия", group: .country,
                     addresses: ["google.be", "hln.be", "nieuwsblad.be", "vrt.be", "lesoir.be", "rtbf.be", "2dehands.be",
                                 "immoweb.be", "bol.com", "meteo.be", "sporza.be", "belgiantrain.be", "nl.wikipedia.org",
                                 "google.be/maps"],
                     searches: ["weer morgen", "météo demain", "goedkope vliegtickets", "recept stoofvlees",
                                "jupiler pro league stand", "treinuren nmbs"]),
        WarmUpPreset(id: "ie", name: "Ирландия", group: .country,
                     addresses: ["google.ie", "rte.ie", "irishtimes.com", "independent.ie", "thejournal.ie", "donedeal.ie",
                                 "daft.ie", "adverts.ie", "met.ie", "the42.ie", "irishrail.ie", "en.wikipedia.org",
                                 "google.ie/maps", "youtube.com"],
                     searches: ["weather tomorrow", "cheap flights from dublin", "rent in dublin", "gaa results",
                                "easy dinner recipes", "irish rail timetable"]),
        WarmUpPreset(id: "ro", name: "Румыния", group: .country,
                     addresses: ["google.ro", "digi24.ro", "hotnews.ro", "adevarul.ro", "libertatea.ro", "stirileprotv.ro",
                                 "emag.ro", "olx.ro", "imobiliare.ro", "meteoromania.ro", "gsp.ro", "cfrcalatori.ro",
                                 "ro.wikipedia.org", "google.ro/maps"],
                     searches: ["vremea mâine", "zboruri ieftine", "rețete ușoare", "locuri de muncă", "curs euro",
                                "liga 1 clasament"]),
        WarmUpPreset(id: "hu", name: "Венгрия", group: .country,
                     addresses: ["google.hu", "index.hu", "telex.hu", "24.hu", "origo.hu", "hvg.hu", "jofogas.hu",
                                 "arukereso.hu", "emag.hu", "ingatlan.com", "idokep.hu", "nemzetisport.hu",
                                 "hu.wikipedia.org", "google.hu/maps"],
                     searches: ["időjárás holnap", "olcsó repülőjegy", "egyszerű receptek", "állás budapest",
                                "euró árfolyam", "menetrend"]),
        WarmUpPreset(id: "gr", name: "Греция", group: .country,
                     addresses: ["google.gr", "kathimerini.gr", "protothema.gr", "in.gr", "skai.gr", "iefimerida.gr",
                                 "skroutz.gr", "car.gr", "xe.gr", "meteo.gr", "gazzetta.gr", "sport24.gr",
                                 "el.wikipedia.org", "google.gr/maps"],
                     searches: ["καιρός αύριο", "φθηνά αεροπορικά", "εύκολες συνταγές", "αγγελίες εργασίας",
                                "αποτελέσματα super league", "δρομολόγια πλοίων"]),
        WarmUpPreset(id: "il", name: "Израиль", group: .country,
                     addresses: ["google.co.il", "ynet.co.il", "haaretz.co.il", "mako.co.il", "walla.co.il", "maariv.co.il",
                                 "yad2.co.il", "zap.co.il", "ims.gov.il", "sport5.co.il", "he.wikipedia.org",
                                 "google.co.il/maps", "youtube.com"],
                     searches: ["מזג אוויר מחר", "טיסות זולות", "מתכונים קלים", "דרושים", "שער הדולר", "תוצאות כדורגל"]),
        WarmUpPreset(id: "ae", name: "ОАЭ", group: .country,
                     addresses: ["google.ae", "gulfnews.com", "khaleejtimes.com", "thenationalnews.com", "emaratalyoum.com",
                                 "dubizzle.com", "noon.com", "amazon.ae", "propertyfinder.ae", "ncm.ae", "timeoutdubai.com",
                                 "ar.wikipedia.org", "google.ae/maps", "youtube.com"],
                     searches: ["weather dubai tomorrow", "cheap flights from dubai", "jobs in dubai", "الطقس غدا",
                                "gold rate today", "things to do in abu dhabi"]),
        WarmUpPreset(id: "sg", name: "Сингапур", group: .country,
                     addresses: ["google.com.sg", "straitstimes.com", "channelnewsasia.com", "mothership.sg", "carousell.sg",
                                 "lazada.sg", "shopee.sg", "propertyguru.com.sg", "sgcarmart.com", "hardwarezone.com.sg",
                                 "weather.gov.sg", "en.wikipedia.org", "google.com.sg/maps", "youtube.com"],
                     searches: ["weather tomorrow singapore", "hawker food near me", "cheap flights to bangkok",
                                "jobs in singapore", "mrt map", "best laksa singapore"]),
        WarmUpPreset(id: "kr", name: "Южная Корея", group: .country,
                     addresses: ["naver.com", "daum.net", "google.co.kr", "chosun.com", "joongang.co.kr", "donga.com",
                                 "hani.co.kr", "coupang.com", "gmarket.co.kr", "11st.co.kr", "weather.go.kr", "namu.wiki",
                                 "ko.wikipedia.org", "youtube.com"],
                     searches: ["내일 날씨", "저렴한 항공권", "간단한 요리 레시피", "채용 정보", "환율", "야구 결과"]),
        WarmUpPreset(id: "ar", name: "Аргентина", group: .country,
                     addresses: ["google.com.ar", "clarin.com", "lanacion.com.ar", "infobae.com", "pagina12.com.ar",
                                 "mercadolibre.com.ar", "zonaprop.com.ar", "ole.com.ar", "tycsports.com", "smn.gob.ar",
                                 "es.wikipedia.org", "google.com.ar/maps", "youtube.com"],
                     searches: ["clima mañana buenos aires", "vuelos baratos", "recetas fáciles", "dólar blue hoy",
                                "resultados liga profesional", "empleos"]),
        WarmUpPreset(id: "cl", name: "Чили", group: .country,
                     addresses: ["google.cl", "emol.com", "latercera.com", "biobiochile.cl", "cooperativa.cl", "24horas.cl",
                                 "mercadolibre.cl", "yapo.cl", "portalinmobiliario.com", "falabella.com", "meteochile.gob.cl",
                                 "es.wikipedia.org", "google.cl/maps", "youtube.com"],
                     searches: ["clima mañana santiago", "vuelos baratos", "recetas fáciles", "ofertas de trabajo",
                                "valor del dólar", "resultados primera división"]),
        WarmUpPreset(id: "co", name: "Колумбия", group: .country,
                     addresses: ["google.com.co", "eltiempo.com", "elespectador.com", "semana.com", "elcolombiano.com",
                                 "mercadolibre.com.co", "fincaraiz.com.co", "exito.com", "falabella.com.co", "ideam.gov.co",
                                 "futbolred.com", "es.wikipedia.org", "google.com.co/maps", "youtube.com"],
                     searches: ["clima mañana bogotá", "vuelos baratos", "recetas fáciles", "empleos en bogotá",
                                "precio del dólar", "resultados liga betplay"]),
        WarmUpPreset(id: "za", name: "ЮАР", group: .country,
                     addresses: ["google.co.za", "news24.com", "iol.co.za", "timeslive.co.za", "dailymaverick.co.za",
                                 "takealot.com", "gumtree.co.za", "property24.com", "autotrader.co.za", "weathersa.co.za",
                                 "supersport.com", "en.wikipedia.org", "google.co.za/maps", "youtube.com"],
                     searches: ["weather tomorrow johannesburg", "load shedding schedule", "cheap flights cape town",
                                "jobs in johannesburg", "rand dollar exchange rate", "springboks results"]),
        WarmUpPreset(id: "nz", name: "Новая Зеландия", group: .country,
                     addresses: ["google.co.nz", "nzherald.co.nz", "stuff.co.nz", "rnz.co.nz", "1news.co.nz", "trademe.co.nz",
                                 "pbtech.co.nz", "thewarehouse.co.nz", "realestate.co.nz", "metservice.com",
                                 "allblacks.com", "en.wikipedia.org", "google.co.nz/maps", "youtube.com"],
                     searches: ["weather tomorrow auckland", "cheap flights to australia", "jobs in wellington",
                                "easy dinner recipes", "all blacks results", "petrol prices nz"]),
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
