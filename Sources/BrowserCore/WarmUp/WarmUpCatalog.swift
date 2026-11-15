import Foundation

/// A kind of browsing a warm-up can be made of ("template"): not a list of sites but what a person
/// does of an evening — reads the news, looks for something to buy — which the catalogue turns
/// into the sites of the country the profile's proxy exits in.
public enum WarmUpInterest: String, CaseIterable, Codable, Sendable {
    /// The everyday mix: the weather, an encyclopedia, video, maps, a paper, a shop.
    case day
    case news, shop, video, forum, travel, tech, finance, sport, food, games, home

    /// The interest an older version's ready-made list stands for (`WarmUpPresets`), for a choice
    /// saved before templates were kinds of browsing; nil for a list that was no interest.
    public init?(presetID: String) {
        switch presetID {
        case "media": self = .news
        case "shopping": self = .shop
        case "social": self = .forum
        case "sports": self = .sport
        case "general", "light", "work": self = .day
        default:
            guard let interest = WarmUpInterest(rawValue: presetID) else { return nil }
            self = interest
        }
    }
}

/// The sites and searches the app knows, by interest and by country: part of the app, like the
/// lists it grew from (`WarmUpPresets`). Nothing is fetched and nothing about a profile is sent
/// anywhere to choose them. Only sites known for certain, readable without an account; when in
/// doubt a site was left out rather than guessed.
public enum WarmUpCatalog {
    /// What an interest comes to for a profile of one country.
    public struct Selection: Equatable, Sendable {
        /// The sites, the country's own first.
        public var sites: [String]
        public var searches: [String]
        /// The country has too few sites of its own for the interest (`minimumOwn`): sites known
        /// everywhere were added.
        public var usesWorld: Bool
    }

    /// With fewer of its own than this, a country's interest is filled up from the world's list.
    public static let minimumOwn = 3

    /// The countries the catalogue has sites of their own for (ISO 3166-1 alpha-2, lower case).
    public static var countries: [String] { WarmUpPresets.countries.map(\.id) }

    /// The sites and searches of `interest` for a profile whose proxy exits in `countryCode` (nil
    /// or a country the catalogue does not know: the world's).
    public static func selection(_ interest: WarmUpInterest, countryCode: String?) -> Selection {
        let code = countryCode?.lowercased() ?? ""
        let known = WarmUpPresets.country(code) != nil
        let own = known ? ownSites(interest, country: code) : []
        let searches = known ? ownSearches(interest, country: code) : (worldSearches[interest] ?? [])
        guard own.count < minimumOwn else { return Selection(sites: own, searches: searches, usesWorld: false) }
        var seen = Set(own)
        let rest = (world[interest] ?? []).filter { seen.insert($0).inserted }
        return Selection(sites: own + rest, searches: searches.isEmpty ? (worldSearches[interest] ?? []) : searches, usesWorld: true)
    }

    /// The country's own sites of an interest. The everyday mix is what is left of the country's
    /// list once its interests are taken out (the weather, the encyclopedia, maps, the portal),
    /// with the first site of its news and of its shops: everybody reads one paper and knows one shop.
    static func ownSites(_ interest: WarmUpInterest, country code: String) -> [String] {
        let tagged = byCountry[code] ?? [:]
        guard interest == .day else { return tagged[interest] ?? [] }
        let everything = WarmUpPresets.country(code)?.addresses ?? []
        let taken = Set(tagged.values.joined())
        // The search engine's own page is where a run searches, not a site to read.
        let plain = everything.filter { !taken.contains($0) && !isSearchEngineHome($0) }
        return plain + [tagged[.news]?.first, tagged[.shop]?.first].compactMap { $0 }
    }

    static func ownSearches(_ interest: WarmUpInterest, country code: String) -> [String] {
        if interest == .day { return WarmUpPresets.country(code)?.searches ?? [] }
        guard let language = languages[code] else { return [] }
        return searchesByLanguage[language]?[interest] ?? []
    }

    static func isSearchEngineHome(_ address: String) -> Bool {
        let host = address.lowercased()
        return !host.contains("/") && (host.hasPrefix("google.") || ["ya.ru", "seznam.cz", "naver.com", "daum.net", "yahoo.co.jp"].contains(host))
    }

    // MARK: The world's lists — where a country has none of its own, and for a profile without a proxy

    static let world: [WarmUpInterest: [String]] = [
        .day: ["wikipedia.org", "youtube.com", "weather.com", "imdb.com", "bbc.com", "amazon.com"],
        .news: ["bbc.com", "reuters.com", "theguardian.com", "apnews.com", "cnn.com"],
        .shop: ["amazon.com", "ebay.com", "etsy.com", "ikea.com", "aliexpress.com"],
        .video: ["youtube.com", "twitch.tv", "vimeo.com", "dailymotion.com"],
        .forum: ["reddit.com", "quora.com", "medium.com", "pinterest.com", "tumblr.com"],
        .travel: ["booking.com", "tripadvisor.com", "airbnb.com", "skyscanner.net", "expedia.com"],
        .tech: ["theverge.com", "techcrunch.com", "wired.com", "arstechnica.com", "producthunt.com"],
        .finance: ["investing.com", "finance.yahoo.com", "tradingview.com", "coinmarketcap.com"],
        .sport: ["espn.com", "eurosport.com", "goal.com", "skysports.com"],
        .food: ["allrecipes.com", "bbcgoodfood.com", "seriouseats.com"],
        .games: ["ign.com", "gamespot.com", "store.steampowered.com", "epicgames.com"],
        .home: ["ikea.com", "houzz.com", "autotrader.com"],
    ]

    static let worldSearches: [WarmUpInterest: [String]] = [
        .day: ["weather tomorrow", "how to cook rice", "news today", "what time is it in london"],
        .news: ["news today", "election results", "latest headlines"],
        .shop: ["running shoes", "coffee machine", "winter jacket", "wireless headphones"],
        .video: ["music video", "documentary", "live stream"],
        .forum: ["home decor ideas", "how to start a blog", "best books 2026"],
        .travel: ["cheap flights", "hotels in barcelona", "things to do in rome"],
        .tech: ["best laptop 2026", "ai news", "smartphone review"],
        .finance: ["bitcoin price", "s&p 500 today", "eur usd"],
        .sport: ["champions league results", "nba scores", "formula 1 standings"],
        .food: ["easy pasta recipe", "chocolate cake recipe", "healthy breakfast ideas"],
        .games: ["best games 2026", "free games", "game reviews"],
        .home: ["sofa ideas", "used cars", "apartment for rent"],
    ]

    /// The language a country searches in, for its interests' searches (its everyday searches are
    /// the country's own, `WarmUpPresets.countries`).
    static let languages: [String: String] = [
        "de": "de", "at": "de", "ch": "de", "fr": "fr", "es": "es", "mx": "es", "ar": "es", "cl": "es", "co": "es",
        "it": "it", "pl": "pl", "br": "pt", "pt": "pt", "nl": "nl", "ru": "ru", "kz": "ru", "tr": "tr",
        "us": "en", "gb": "en", "ca": "en", "au": "en", "ie": "en", "nz": "en", "za": "en", "sg": "en", "in": "en", "ae": "en",
    ]

    static let searchesByLanguage: [String: [WarmUpInterest: [String]]] = [
        "en": worldSearches,
        "de": [.news: ["nachrichten heute", "aktuelle schlagzeilen"], .shop: ["laufschuhe test", "kaffeemaschine vergleich", "winterjacke herren", "kopfhörer bluetooth"],
               .video: ["musikvideo", "doku"], .forum: ["einrichtungsideen", "buchempfehlungen"], .travel: ["günstige flüge", "hotel barcelona", "urlaub italien"],
               .tech: ["bester laptop 2026", "smartphone test"], .finance: ["dax aktuell", "euro dollar kurs", "bitcoin kurs"], .sport: ["bundesliga ergebnisse", "formel 1 wertung"],
               .food: ["rezept kartoffelsalat", "schnelle rezepte", "kuchen rezept"], .games: ["beste spiele 2026", "kostenlose spiele"], .home: ["sofa kaufen", "gebrauchtwagen", "wohnung mieten"]],
        "fr": [.news: ["actualités", "infos du jour"], .shop: ["chaussures de running", "machine à café", "veste d'hiver", "casque bluetooth"],
               .video: ["clip musical", "documentaire"], .forum: ["idées déco", "idées de lecture"], .travel: ["vol pas cher", "hôtel barcelone", "week-end rome"],
               .tech: ["meilleur ordinateur portable 2026", "test smartphone"], .finance: ["cac 40", "cours euro dollar", "cours bitcoin"], .sport: ["résultats ligue 1", "classement formule 1"],
               .food: ["recette poulet", "recette facile", "gâteau au chocolat"], .games: ["meilleurs jeux 2026", "jeux gratuits"], .home: ["canapé", "voiture occasion", "appartement à louer"]],
        "es": [.news: ["noticias de hoy", "últimas noticias"], .shop: ["zapatillas running", "cafetera", "chaqueta invierno", "auriculares bluetooth"],
               .video: ["videoclip", "documental"], .forum: ["ideas de decoración", "libros recomendados"], .travel: ["vuelos baratos", "hoteles en barcelona", "qué ver en roma"],
               .tech: ["mejor portátil 2026", "análisis móvil"], .finance: ["ibex 35", "euro dólar", "precio bitcoin"], .sport: ["resultados liga", "clasificación fórmula 1"],
               .food: ["recetas fáciles", "receta tortilla", "tarta de chocolate"], .games: ["mejores juegos 2026", "juegos gratis"], .home: ["sofá", "coches de segunda mano", "piso en alquiler"]],
        "it": [.news: ["notizie di oggi", "ultime notizie"], .shop: ["scarpe da corsa", "macchina da caffè", "giacca invernale", "cuffie bluetooth"],
               .video: ["video musicale", "documentario"], .forum: ["idee arredamento", "libri consigliati"], .travel: ["voli economici", "hotel barcellona", "cosa vedere a roma"],
               .tech: ["miglior portatile 2026", "recensione smartphone"], .finance: ["ftse mib", "cambio euro dollaro", "prezzo bitcoin"], .sport: ["classifica serie a", "classifica formula 1"],
               .food: ["ricette veloci", "ricetta carbonara", "torta al cioccolato"], .games: ["migliori giochi 2026", "giochi gratis"], .home: ["divano", "auto usate", "appartamento in affitto"]],
        "pl": [.news: ["wiadomości", "wiadomości dnia"], .shop: ["buty do biegania", "ekspres do kawy", "kurtka zimowa", "słuchawki bluetooth"],
               .video: ["teledysk", "film dokumentalny"], .forum: ["pomysły na wystrój", "polecane książki"], .travel: ["tanie loty", "hotel barcelona", "co zobaczyć w rzymie"],
               .tech: ["najlepszy laptop 2026", "test smartfona"], .finance: ["kurs euro", "wig20", "kurs bitcoina"], .sport: ["wyniki ekstraklasy", "klasyfikacja formuły 1"],
               .food: ["przepisy obiad", "szybkie przepisy", "ciasto czekoladowe"], .games: ["najlepsze gry 2026", "darmowe gry"], .home: ["sofa", "samochody używane", "mieszkanie do wynajęcia"]],
        "pt": [.news: ["notícias de hoje", "últimas notícias"], .shop: ["tênis de corrida", "cafeteira", "casaco de inverno", "fone bluetooth"],
               .video: ["videoclipe", "documentário"], .forum: ["ideias de decoração", "livros recomendados"], .travel: ["passagens aéreas baratas", "hotéis em lisboa", "o que fazer em roma"],
               .tech: ["melhor notebook 2026", "análise smartphone"], .finance: ["cotação do dólar", "preço bitcoin", "bolsa hoje"], .sport: ["resultados futebol", "classificação fórmula 1"],
               .food: ["receitas fáceis", "bolo de chocolate", "receita de frango"], .games: ["melhores jogos 2026", "jogos grátis"], .home: ["sofá", "carros usados", "apartamento para alugar"]],
        "nl": [.news: ["nieuws vandaag", "laatste nieuws"], .shop: ["hardloopschoenen", "koffiemachine", "winterjas", "bluetooth koptelefoon"],
               .video: ["muziekvideo", "documentaire"], .forum: ["interieur ideeën", "boekentips"], .travel: ["goedkope vliegtickets", "hotel barcelona", "stedentrip rome"],
               .tech: ["beste laptop 2026", "smartphone review"], .finance: ["aex koers", "euro dollar koers", "bitcoin koers"], .sport: ["eredivisie stand", "formule 1 stand"],
               .food: ["recept lasagne", "makkelijke recepten", "chocoladetaart"], .games: ["beste games 2026", "gratis games"], .home: ["bank kopen", "tweedehands auto", "huurwoning"]],
        "ru": [.news: ["новости сегодня", "главные новости"], .shop: ["кроссовки для бега", "кофемашина", "зимняя куртка", "беспроводные наушники"],
               .video: ["клип", "документальный фильм"], .forum: ["идеи для интерьера", "что почитать"], .travel: ["авиабилеты дешево", "отели в стамбуле", "что посмотреть в казани"],
               .tech: ["лучший ноутбук 2026", "обзор смартфона"], .finance: ["курс доллара", "курс евро", "курс биткоина"], .sport: ["результаты матчей", "турнирная таблица"],
               .food: ["рецепт борща", "быстрые рецепты", "шоколадный торт"], .games: ["лучшие игры 2026", "бесплатные игры"], .home: ["диван", "авто с пробегом", "снять квартиру"]],
        "tr": [.news: ["son dakika haberler", "bugünkü haberler"], .shop: ["koşu ayakkabısı", "kahve makinesi", "kışlık mont", "bluetooth kulaklık"],
               .video: ["müzik videosu", "belgesel"], .forum: ["dekorasyon fikirleri", "kitap önerileri"], .travel: ["ucuz uçak bileti", "barselona otelleri", "roma gezilecek yerler"],
               .tech: ["en iyi laptop 2026", "telefon incelemesi"], .finance: ["dolar kuru", "euro kuru", "bitcoin fiyatı"], .sport: ["süper lig puan durumu", "formula 1 puan durumu"],
               .food: ["kolay yemek tarifleri", "kek tarifi", "tavuk tarifi"], .games: ["en iyi oyunlar 2026", "ücretsiz oyunlar"], .home: ["koltuk takımı", "ikinci el araba", "kiralık daire"]],
    ]

    // MARK: Countries — each country's sites by interest (what is not here stays in its everyday mix)

    static let byCountry: [String: [WarmUpInterest: [String]]] = [
        "de": [.news: ["spiegel.de", "tagesschau.de", "zeit.de", "faz.net", "sueddeutsche.de"], .shop: ["idealo.de", "otto.de", "kleinanzeigen.de", "amazon.de", "ebay.de", "mediamarkt.de", "zalando.de", "lidl.de"],
               .sport: ["kicker.de", "sport1.de"], .food: ["chefkoch.de", "lecker.de"], .home: ["mobile.de", "immobilienscout24.de"], .tech: ["heise.de", "golem.de", "chip.de"],
               .finance: ["finanzen.net", "boerse.de"], .travel: ["bahn.de"], .forum: ["gutefrage.net"], .games: ["gamestar.de"], .video: ["zdf.de"]],
        "fr": [.news: ["lemonde.fr", "lefigaro.fr", "francetvinfo.fr", "20minutes.fr", "liberation.fr"], .shop: ["leboncoin.fr", "fnac.com", "cdiscount.com", "amazon.fr", "darty.com"],
               .sport: ["lequipe.fr"], .food: ["marmiton.org"], .video: ["allocine.fr"], .tech: ["01net.com", "numerama.com"], .finance: ["boursorama.com"], .travel: ["sncf-connect.com"], .home: ["seloger.com", "lacentrale.fr"]],
        "gb": [.news: ["bbc.co.uk", "theguardian.com", "independent.co.uk", "telegraph.co.uk"], .shop: ["argos.co.uk", "gumtree.com", "ebay.co.uk", "amazon.co.uk", "johnlewis.com"],
               .sport: ["skysports.com"], .food: ["bbcgoodfood.com"], .home: ["rightmove.co.uk", "autotrader.co.uk"], .travel: ["nationalrail.co.uk"], .tech: ["techradar.com"]],
        "es": [.news: ["elpais.com", "elmundo.es", "20minutos.es", "abc.es"], .shop: ["milanuncios.com", "wallapop.com", "amazon.es", "elcorteingles.es", "pccomponentes.com"],
               .sport: ["marca.com", "as.com"], .home: ["idealista.com", "coches.net"], .video: ["filmaffinity.com"], .travel: ["renfe.com"], .tech: ["xataka.com"], .finance: ["expansion.com"]],
        "it": [.news: ["corriere.it", "repubblica.it", "ansa.it", "lastampa.it"], .shop: ["subito.it", "amazon.it", "ebay.it"], .sport: ["gazzetta.it"],
               .food: ["giallozafferano.it"], .home: ["immobiliare.it", "autoscout24.it"], .travel: ["trenitalia.com"], .finance: ["ilsole24ore.com"], .tech: ["hdblog.it"]],
        "pl": [.news: ["onet.pl", "wp.pl", "interia.pl", "gazeta.pl", "tvn24.pl"], .shop: ["allegro.pl", "olx.pl", "ceneo.pl", "empik.com"], .sport: ["sport.pl"],
               .video: ["filmweb.pl"], .home: ["otomoto.pl", "otodom.pl"], .finance: ["bankier.pl", "money.pl"], .tech: ["spidersweb.pl"], .food: ["kwestiasmaku.com"], .forum: ["wykop.pl"]],
        "us": [.news: ["nytimes.com", "cnn.com", "apnews.com", "usatoday.com", "npr.org"], .shop: ["amazon.com", "walmart.com", "target.com", "craigslist.org", "ebay.com", "bestbuy.com"],
               .sport: ["espn.com", "nba.com"], .home: ["zillow.com", "cars.com"], .food: ["allrecipes.com", "foodnetwork.com"], .tech: ["theverge.com", "wired.com"],
               .finance: ["finance.yahoo.com", "marketwatch.com"], .forum: ["reddit.com", "quora.com"], .travel: ["tripadvisor.com", "expedia.com"], .games: ["ign.com"]],
        "br": [.news: ["g1.globo.com", "uol.com.br", "folha.uol.com.br", "globo.com"], .shop: ["mercadolivre.com.br", "americanas.com.br", "olx.com.br", "magazineluiza.com.br"],
               .sport: ["ge.globo.com"], .food: ["tudogostoso.com.br"], .tech: ["tecmundo.com.br"], .finance: ["infomoney.com.br"]],
        "tr": [.news: ["hurriyet.com.tr", "sozcu.com.tr", "milliyet.com.tr", "ntv.com.tr"], .shop: ["sahibinden.com", "trendyol.com", "hepsiburada.com"], .sport: ["mackolik.com"]],
        "nl": [.news: ["nu.nl", "nos.nl", "telegraaf.nl", "ad.nl"], .shop: ["marktplaats.nl", "bol.com", "coolblue.nl", "ah.nl"], .home: ["funda.nl"], .travel: ["ns.nl"], .tech: ["tweakers.net"]],
        "ua": [.news: ["pravda.com.ua", "unian.ua", "tsn.ua", "ukr.net"], .shop: ["rozetka.com.ua", "olx.ua", "prom.ua"], .sport: ["football.ua"]],
        "kz": [.news: ["tengrinews.kz", "nur.kz", "zakon.kz"], .shop: ["kaspi.kz", "olx.kz"], .home: ["kolesa.kz", "krisha.kz"], .sport: ["sports.kz"]],
        "ee": [.news: ["postimees.ee", "err.ee", "delfi.ee", "ohtuleht.ee"], .shop: ["okidoki.ee", "hinnavaatlus.ee"], .home: ["kv.ee", "auto24.ee"]],
        "lv": [.news: ["delfi.lv", "lsm.lv", "tvnet.lv", "apollo.lv"], .shop: ["ss.lv", "salidzini.lv"], .sport: ["sportacentrs.com"]],
        "lt": [.news: ["delfi.lt", "lrt.lt", "15min.lt", "lrytas.lt"], .shop: ["skelbiu.lt", "pigu.lt"], .home: ["autoplius.lt", "aruodas.lt"]],
        "fi": [.news: ["yle.fi", "hs.fi", "iltalehti.fi", "is.fi"], .shop: ["tori.fi", "verkkokauppa.com"], .home: ["oikotie.fi"], .travel: ["vr.fi"]],
        "se": [.news: ["aftonbladet.se", "svt.se", "dn.se", "expressen.se"], .shop: ["blocket.se", "prisjakt.nu"], .home: ["hemnet.se"], .travel: ["sj.se"]],
        "no": [.news: ["vg.no", "nrk.no", "dagbladet.no", "aftenposten.no"], .shop: ["finn.no", "prisjakt.no", "komplett.no"], .travel: ["vy.no"]],
        "dk": [.news: ["dr.dk", "tv2.dk", "politiken.dk", "ekstrabladet.dk", "bt.dk"], .shop: ["dba.dk", "pricerunner.dk"], .home: ["boligsiden.dk"], .travel: ["rejseplanen.dk"]],
        "cz": [.news: ["idnes.cz", "novinky.cz", "aktualne.cz"], .shop: ["alza.cz", "heureka.cz", "bazos.cz"], .home: ["sreality.cz"], .sport: ["sport.cz"], .travel: ["idos.cz"]],
        "pt": [.news: ["publico.pt", "jn.pt", "cmjornal.pt", "observador.pt"], .shop: ["olx.pt", "worten.pt"], .sport: ["record.pt", "abola.pt"], .home: ["idealista.pt"], .travel: ["cp.pt"]],
        "mx": [.news: ["eluniversal.com.mx", "milenio.com", "excelsior.com.mx"], .shop: ["mercadolibre.com.mx", "liverpool.com.mx", "amazon.com.mx"], .sport: ["record.com.mx"],
               .home: ["inmuebles24.com"], .finance: ["elfinanciero.com.mx"]],
        "ca": [.news: ["cbc.ca", "ctvnews.ca", "theglobeandmail.com", "globalnews.ca"], .shop: ["kijiji.ca", "canadiantire.ca", "bestbuy.ca"], .sport: ["tsn.ca", "sportsnet.ca"], .home: ["realtor.ca"]],
        "au": [.news: ["abc.net.au", "smh.com.au", "news.com.au", "theage.com.au"], .shop: ["gumtree.com.au", "jbhifi.com.au"], .sport: ["afl.com.au"], .food: ["taste.com.au"],
               .home: ["realestate.com.au", "domain.com.au"]],
        "jp": [.news: ["nhk.or.jp", "asahi.com", "mainichi.jp", "yomiuri.co.jp"], .shop: ["rakuten.co.jp", "amazon.co.jp", "kakaku.com"], .food: ["cookpad.com", "tabelog.com"]],
        "in": [.news: ["timesofindia.indiatimes.com", "ndtv.com", "hindustantimes.com", "indianexpress.com"], .shop: ["flipkart.com", "amazon.in"], .sport: ["cricbuzz.com", "espncricinfo.com"],
               .finance: ["moneycontrol.com"]],
        "ru": [.news: ["rbc.ru", "lenta.ru", "ria.ru", "dzen.ru"], .shop: ["avito.ru", "ozon.ru", "wildberries.ru"], .sport: ["sport-express.ru", "championat.com"], .video: ["kinopoisk.ru", "rutube.ru"]],
        "at": [.news: ["orf.at", "derstandard.at", "krone.at", "diepresse.com", "kurier.at"], .shop: ["willhaben.at", "geizhals.at"], .sport: ["laola1.at"], .food: ["gutekueche.at"], .travel: ["oebb.at"]],
        "ch": [.news: ["20min.ch", "blick.ch", "srf.ch", "nzz.ch", "tagesanzeiger.ch"], .shop: ["ricardo.ch", "tutti.ch", "digitec.ch", "galaxus.ch"], .home: ["homegate.ch"], .travel: ["sbb.ch"]],
        "be": [.news: ["hln.be", "nieuwsblad.be", "vrt.be", "lesoir.be", "rtbf.be"], .shop: ["2dehands.be", "bol.com"], .home: ["immoweb.be"], .sport: ["sporza.be"], .travel: ["belgiantrain.be"]],
        "ie": [.news: ["rte.ie", "irishtimes.com", "independent.ie", "thejournal.ie"], .shop: ["donedeal.ie", "adverts.ie"], .home: ["daft.ie"], .sport: ["the42.ie"], .travel: ["irishrail.ie"]],
        "ro": [.news: ["digi24.ro", "hotnews.ro", "adevarul.ro", "libertatea.ro", "stirileprotv.ro"], .shop: ["emag.ro", "olx.ro"], .home: ["imobiliare.ro"], .sport: ["gsp.ro"], .travel: ["cfrcalatori.ro"]],
        "hu": [.news: ["index.hu", "telex.hu", "24.hu", "origo.hu", "hvg.hu"], .shop: ["jofogas.hu", "arukereso.hu", "emag.hu"], .home: ["ingatlan.com"], .sport: ["nemzetisport.hu"]],
        "gr": [.news: ["kathimerini.gr", "protothema.gr", "in.gr", "skai.gr", "iefimerida.gr"], .shop: ["skroutz.gr", "xe.gr"], .home: ["car.gr"], .sport: ["gazzetta.gr", "sport24.gr"]],
        "il": [.news: ["ynet.co.il", "haaretz.co.il", "mako.co.il", "walla.co.il", "maariv.co.il"], .shop: ["yad2.co.il", "zap.co.il"], .sport: ["sport5.co.il"]],
        "ae": [.news: ["gulfnews.com", "khaleejtimes.com", "thenationalnews.com", "emaratalyoum.com"], .shop: ["dubizzle.com", "noon.com", "amazon.ae"], .home: ["propertyfinder.ae"]],
        "sg": [.news: ["straitstimes.com", "channelnewsasia.com", "mothership.sg"], .shop: ["carousell.sg", "lazada.sg", "shopee.sg"], .home: ["propertyguru.com.sg", "sgcarmart.com"], .tech: ["hardwarezone.com.sg"]],
        "kr": [.news: ["chosun.com", "joongang.co.kr", "donga.com", "hani.co.kr"], .shop: ["coupang.com", "gmarket.co.kr", "11st.co.kr"]],
        "ar": [.news: ["clarin.com", "lanacion.com.ar", "infobae.com", "pagina12.com.ar"], .shop: ["mercadolibre.com.ar"], .home: ["zonaprop.com.ar"], .sport: ["ole.com.ar", "tycsports.com"]],
        "cl": [.news: ["emol.com", "latercera.com", "biobiochile.cl", "cooperativa.cl", "24horas.cl"], .shop: ["mercadolibre.cl", "yapo.cl", "falabella.com"], .home: ["portalinmobiliario.com"]],
        "co": [.news: ["eltiempo.com", "elespectador.com", "semana.com", "elcolombiano.com"], .shop: ["mercadolibre.com.co", "exito.com", "falabella.com.co"], .home: ["fincaraiz.com.co"], .sport: ["futbolred.com"]],
        "za": [.news: ["news24.com", "iol.co.za", "timeslive.co.za", "dailymaverick.co.za"], .shop: ["takealot.com", "gumtree.co.za"], .home: ["property24.com", "autotrader.co.za"], .sport: ["supersport.com"]],
        "nz": [.news: ["nzherald.co.nz", "stuff.co.nz", "rnz.co.nz", "1news.co.nz"], .shop: ["trademe.co.nz", "pbtech.co.nz", "thewarehouse.co.nz"], .home: ["realestate.co.nz"], .sport: ["allblacks.com"]],
    ]
}
