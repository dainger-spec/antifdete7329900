import XCTest
@testable import BrowserCore

private struct Seeded: RandomNumberGenerator {
    var state: UInt64
    init(_ seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

final class WarmUpCatalogTests: XCTestCase {
    func testEveryCountryHasItsOwnNewsShopsAndEverydaySites() {
        XCTAssertEqual(Set(WarmUpCatalog.byCountry.keys), Set(WarmUpCatalog.countries), "a country of the lists without its interests, or the other way")
        for code in WarmUpCatalog.countries {
            for interest in [WarmUpInterest.news, .shop] {
                XCTAssertGreaterThanOrEqual(WarmUpCatalog.ownSites(interest, country: code).count, 1, "\(code) \(interest)")
            }
            let day = WarmUpCatalog.selection(.day, countryCode: code)
            XCTAssertGreaterThanOrEqual(day.sites.count, 3, "\(code): the everyday mix")
            XCTAssertFalse(day.sites.contains(where: WarmUpCatalog.isSearchEngineHome), "\(code): the search engine's page is where a run searches")
            XCTAssertFalse(day.searches.isEmpty, code)
        }
    }

    func testEverySiteIsAWebAddressListedOncePerCountry() {
        for (code, interests) in WarmUpCatalog.byCountry {
            var seen: Set<String> = []
            for (interest, sites) in interests {
                for site in sites {
                    XCTAssertNotNil(WarmUpPlan.webURL(site), "\(code) \(interest): \(site)")
                    XCTAssertEqual(site, site.lowercased(), site)
                    XCTAssertTrue(seen.insert(site).inserted, "\(code): \(site) is under two interests")
                }
            }
        }
        for (interest, sites) in WarmUpCatalog.world {
            XCTAssertGreaterThanOrEqual(sites.count, WarmUpCatalog.minimumOwn, "\(interest)")
            XCTAssertEqual(Set(sites).count, sites.count, "\(interest)")
            for site in sites { XCTAssertNotNil(WarmUpPlan.webURL(site), site) }
        }
        XCTAssertEqual(Set(WarmUpCatalog.world.keys), Set(WarmUpInterest.allCases))
        XCTAssertEqual(Set(WarmUpCatalog.worldSearches.keys), Set(WarmUpInterest.allCases))
    }

    func testACountryGetsItsOwnSitesAndTheWorldOnlyWhereItHasTooFew() {
        let german = WarmUpCatalog.selection(.shop, countryCode: "DE")
        XCTAssertFalse(german.usesWorld)
        XCTAssertTrue(german.sites.contains("idealo.de"))
        XCTAssertFalse(german.sites.contains("walmart.com"), "a German profile's shopping is not America's")
        XCTAssertTrue(german.searches.contains("laufschuhe test"))

        let polish = WarmUpCatalog.selection(.shop, countryCode: "pl")
        XCTAssertTrue(polish.sites.contains("allegro.pl"))
        XCTAssertTrue(Set(polish.sites).isDisjoint(with: german.sites.filter { $0.hasSuffix(".de") }))

        // Estonia has no games sites of its own: the world's, and said so.
        let games = WarmUpCatalog.selection(.games, countryCode: "ee")
        XCTAssertTrue(games.usesWorld)
        XCTAssertEqual(games.sites, WarmUpCatalog.world[.games])

        // Too few of its own: its own first, then the world's, each once.
        let sport = WarmUpCatalog.selection(.sport, countryCode: "fr")
        XCTAssertTrue(sport.usesWorld)
        XCTAssertEqual(sport.sites.first, "lequipe.fr")
        XCTAssertEqual(Set(sport.sites).count, sport.sites.count)

        let nowhere = WarmUpCatalog.selection(.news, countryCode: nil)
        XCTAssertEqual(nowhere.sites, WarmUpCatalog.world[.news])
        XCTAssertEqual(WarmUpCatalog.selection(.news, countryCode: "zz").sites, nowhere.sites, "a country the catalogue does not know")
    }

    func testOlderListsNameTheirInterests() {
        XCTAssertEqual(WarmUpInterest(presetID: "media"), .news)
        XCTAssertEqual(WarmUpInterest(presetID: "shopping"), .shop)
        XCTAssertEqual(WarmUpInterest(presetID: "general"), .day)
        XCTAssertEqual(WarmUpInterest(presetID: "travel"), .travel)
        XCTAssertNil(WarmUpInterest(presetID: "de"))
    }
}

final class WarmUpPlannerTests: XCTestCase {
    func testAMixTakesTheTemplatesInTurnEachSiteOnce() throws {
        var generator = Seeded(7)
        let preset = try XCTUnwrap(WarmUpPlanner.preset(templates: ["news", "shop"], countryCode: "de", using: &generator))
        let news = Set(WarmUpCatalog.selection(.news, countryCode: "de").sites), shop = Set(WarmUpCatalog.selection(.shop, countryCode: "de").sites)
        XCTAssertEqual(Set(preset.addresses), news.union(shop))
        XCTAssertEqual(Set(preset.addresses).count, preset.addresses.count)
        for (index, site) in preset.addresses.prefix(8).enumerated() {
            XCTAssertTrue(index % 2 == 0 ? news.contains(site) : shop.contains(site), "site \(index) is not of its turn's template: \(site)")
        }
    }

    func testAPlanHasTheIntensitysSitesSearchesAndDepth() throws {
        for intensity in WarmUpIntensity.allCases {
            var generator = Seeded(11)
            let plan = try XCTUnwrap(WarmUpPlanner.plan(templates: WarmUpInterest.allCases.map(\.rawValue), countryCode: "us", intensity: intensity, using: &generator))
            let pages = plan.pages().pages
            XCTAssertEqual(pages.filter { $0.kind == .address }.count, intensity.sites, "\(intensity)")
            XCTAssertEqual(pages.filter { $0.kind == .search }.count, intensity.searches, "\(intensity)")
            XCTAssertEqual(plan.hops, intensity.linkHops)
            XCTAssertEqual(plan.minimumDwell, intensity.dwell.lowerBound)
            XCTAssertEqual(plan.maximumDwell, intensity.dwell.upperBound)
            XCTAssertEqual(plan.searchArrivalShare, intensity.searchArrivalShare)
            XCTAssertEqual(plan.readsByPage, true)
            XCTAssertTrue(plan.pages().problems.isEmpty)
        }
        XCTAssertLessThan(WarmUpIntensity.light.estimatedSeconds(), WarmUpIntensity.normal.estimatedSeconds())
        XCTAssertLessThan(WarmUpIntensity.normal.estimatedSeconds(), WarmUpIntensity.deep.estimatedSeconds())
        XCTAssertEqual(WarmUpIntensity(quality: WarmUpIntensity.deep.quality), .deep)
    }

    func testTwoRunsOfOneChoiceAreNotTheSameRun() throws {
        var first = Seeded(1), second = Seeded(2)
        let a = try XCTUnwrap(WarmUpPlanner.plan(templates: ["day", "shop"], countryCode: "de", intensity: .normal, using: &first))
        let b = try XCTUnwrap(WarmUpPlanner.plan(templates: ["day", "shop"], countryCode: "de", intensity: .normal, using: &second))
        XCTAssertNotEqual(a.addresses, b.addresses)
    }

    func testAListOfOnesOwnIsGivenTheCountrysEverydaySitesUnlessToldNot() throws {
        var template = WarmUpTemplate(name: "Shops", addresses: ["https://zalando.de/", "https://lidl.de/"], searches: ["sneaker sale"])
        var generator = Seeded(3)
        let mixed = try XCTUnwrap(WarmUpPlanner.preset(templates: [template.presetID], countryCode: "de", userTemplates: [template], using: &generator))
        XCTAssertTrue(mixed.addresses.contains("https://zalando.de/"))
        let everyday = WarmUpCatalog.selection(.day, countryCode: "de").sites
        XCTAssertTrue(mixed.addresses.contains { everyday.contains($0) }, "the everyday sites are around the list")
        XCTAssertTrue(mixed.searches.contains("sneaker sale"))

        template.addsEveryday = false
        let alone = try XCTUnwrap(WarmUpPlanner.preset(templates: [template.presetID], countryCode: "de", userTemplates: [template], using: &generator))
        XCTAssertEqual(Set(alone.addresses), ["https://zalando.de/", "https://lidl.de/"])

        XCTAssertNil(WarmUpPlanner.preset(templates: ["user:gone"], countryCode: "de", using: &generator), "a list deleted since is no run")
        XCTAssertNil(WarmUpPlanner.preset(templates: [], countryCode: "de", using: &generator))
    }

    func testAChoiceOfTemplatesBuildsItsPlanAndKeepsItself() throws {
        let choice = WarmUpChoice.templates(["day", "travel"], intensity: .light, viaSearch: false, consent: .asPeople)
        var generator = Seeded(5)
        let plan = try XCTUnwrap(choice.plan(countryCode: "fr", using: &generator))
        XCTAssertEqual(plan.choice, choice)
        XCTAssertEqual(plan.searchArrivalShare, 0)
        XCTAssertEqual(plan.consentChoice, .asPeople)
        XCTAssertEqual(choice.intensity, .light)
        let decoded = try JSONDecoder().decode(WarmUpChoice.self, from: JSONEncoder().encode(choice))
        XCTAssertEqual(decoded, choice)
    }

    func testChoicesOfTheOlderScreenComeToTheNearestTemplates() {
        XCTAssertEqual(WarmUpChoice(source: .preset, presetID: "de").templateIDs, ["day"])
        XCTAssertEqual(WarmUpChoice(source: .preset, presetID: "shopping").templateIDs, ["shop"])
        XCTAssertEqual(WarmUpChoice(source: .preset, presetID: "user:1").templateIDs, ["user:1"])
        XCTAssertEqual(WarmUpChoice(source: .composed, interestIDs: ["media", "shopping"]).templateIDs, ["day", "news", "shop"])
        XCTAssertEqual(WarmUpChoice(source: .manual).templateIDs, [])
        // A plan saved before the new fields reads as it did.
        let old = #"{"addresses":"a.example","searchQuery":"","minimumDwell":5,"maximumDwell":15,"scroll":true,"followLinks":false}"#
        let plan = try? JSONDecoder().decode(WarmUpPlan.self, from: Data(old.utf8))
        XCTAssertNotNil(plan)
        XCTAssertNil(plan?.searchArrivalShare)
        XCTAssertEqual(plan?.consentChoice, .accept)
    }
}

final class WarmUpReadingTests: XCTestCase {
    func testALongPageIsReadLongerThanAShortOneWithinThePlansTimes() {
        let range: ClosedRange<TimeInterval> = 12...70
        let short = WarmUpPageMeasure(textLength: 300, pageHeight: 800, viewportHeight: 800)
        let long = WarmUpPageMeasure(textLength: 9_000, pageHeight: 6_400, viewportHeight: 800)
        var shortTotal = 0.0, longTotal = 0.0
        for seed in 0..<200 {
            var generator = Seeded(UInt64(seed))
            let a = WarmUpReading.dwell(short, range: range, using: &generator), b = WarmUpReading.dwell(long, range: range, using: &generator)
            XCTAssertTrue(range.contains(a) && range.contains(b))
            shortTotal += a
            longTotal += b
        }
        XCTAssertEqual(shortTotal / 200, 12, accuracy: 1, "an empty page is left at the shortest stay")
        XCTAssertGreaterThan(longTotal / 200, 45)
    }

    func testScrollingGoesInBurstsDownToADepthAndNoFurther() {
        let page = WarmUpPageMeasure(textLength: 6_000, pageHeight: 5_000, viewportHeight: 800)
        for seed in 0..<100 {
            var generator = Seeded(UInt64(seed))
            let gestures = WarmUpReading.gestures(page, over: 60, using: &generator)
            XCTAssertFalse(gestures.isEmpty)
            let travelled = gestures.flatMap(\.deltas).reduce(0, +)
            XCTAssertLessThanOrEqual(travelled, 4_200 + 14, "never past the page's end")
            XCTAssertGreaterThan(travelled, 0)
            XCTAssertTrue(gestures.allSatisfy { $0.at >= 1.5 && $0.at < 59 })
            XCTAssertEqual(gestures.map(\.at), gestures.map(\.at).sorted())
            let gaps = zip(gestures.dropFirst(), gestures).map { $0.at - $1.at }
            XCTAssertTrue(gaps.contains { $0 >= 2.5 } || gestures.count <= 3, "bursts have reading pauses between them")
        }
        var generator = Seeded(1)
        XCTAssertTrue(WarmUpReading.gestures(WarmUpPageMeasure(textLength: 100, pageHeight: 700, viewportHeight: 800), over: 30, using: &generator).isEmpty,
                      "a page that fits its window is not scrolled")
        XCTAssertTrue(WarmUpReading.gestures(page, over: 2, using: &generator).isEmpty)
    }

    func testPausesAreShortMostlyAndNowAndThenLong() {
        var generator = Seeded(9)
        let pauses = (0..<1_000).map { _ in WarmUpReading.pause(using: &generator) }
        XCTAssertTrue(pauses.allSatisfy { $0 >= 1.5 && $0 <= 40 })
        let long = pauses.filter { $0 >= 12 }.count
        XCTAssertTrue((60...200).contains(long), "\(long) long pauses of 1000")
    }

    func testThreePagesInARowThatDoNotLoadEndTheRun() {
        var health = WarmUpHealth()
        XCTAssertFalse(health.record(loaded: false))
        XCTAssertFalse(health.record(loaded: false))
        XCTAssertFalse(health.record(loaded: true), "a page that loads starts the count again")
        XCTAssertFalse(health.record(loaded: false))
        XCTAssertFalse(health.record(loaded: false))
        XCTAssertTrue(health.record(loaded: false))
    }

    func testAutomaticConcurrencyFollowsMemoryAndProcessors() {
        let gb: UInt64 = 1_073_741_824
        XCTAssertEqual(WarmUpConcurrency.automatic(memoryBytes: 8 * gb, processors: 8), 1)
        XCTAssertEqual(WarmUpConcurrency.automatic(memoryBytes: 16 * gb, processors: 8), 4)
        XCTAssertEqual(WarmUpConcurrency.automatic(memoryBytes: 16 * gb, processors: 4), 2)
        XCTAssertEqual(WarmUpConcurrency.automatic(memoryBytes: 64 * gb, processors: 16), 8)
        XCTAssertEqual(WarmUpConcurrency.automatic(memoryBytes: 2 * gb, processors: 2), 1)
    }
}

final class WarmUpPageRulesTests: XCTestCase {
    func testChecksAndBlocksAreToldFromPagesToRead() {
        func kind(_ url: String, title: String = "", text: Double = 5_000, marks: [String] = []) -> String? {
            WarmUpBlockPage.kind(WarmUpPageSignals(url: url, title: title, textLength: text, marks: marks))
        }
        XCTAssertNil(kind("https://spiegel.de/", title: "DER SPIEGEL"))
        XCTAssertEqual(kind("https://www.google.com/sorry/index?continue=x"), "google")
        XCTAssertEqual(kind("https://shop.example/", title: "Just a moment..."), "cloudflare")
        XCTAssertEqual(kind("https://shop.example/", title: "Access Denied"), "blocked")
        XCTAssertEqual(kind("https://shop.example/", marks: ["perimeterx"]), "perimeterx")
        XCTAssertEqual(kind("https://shop.example/", text: 120, marks: ["recaptcha"]), "recaptcha", "a page that is only the widget is a wall")
        XCTAssertNil(kind("https://shop.example/contact", text: 4_000, marks: ["recaptcha"]), "a form with its own reCAPTCHA is a page to read")
        XCTAssertEqual(kind("https://ya.ru/showcaptcha?x=1"), "yandex")
        XCTAssertEqual(Set(WarmUpBlockPage.marks.map(\.name)).count, WarmUpBlockPage.marks.count)
    }

    func testPagesWhereOneSignsInOrPaysAreLeftAlone() {
        XCTAssertTrue(WarmUpSensitivePage.isSensitive(WarmUpPageSignals(url: "https://a.example/", hasPasswordField: true)))
        XCTAssertTrue(WarmUpSensitivePage.isSensitive(WarmUpPageSignals(url: "https://a.example/", hasCardField: true)))
        XCTAssertTrue(WarmUpSensitivePage.isSensitive(WarmUpPageSignals(url: "https://a.example/checkout/step1")))
        XCTAssertTrue(WarmUpSensitivePage.isSensitive(WarmUpPageSignals(url: "https://a.example/de/warenkorb")))
        XCTAssertTrue(WarmUpSensitivePage.isSensitive(WarmUpPageSignals(url: "https://a.example/login")))
        XCTAssertFalse(WarmUpSensitivePage.isSensitive(WarmUpPageSignals(url: "https://a.example/artikel/paywall-erklaert")))
        XCTAssertFalse(WarmUpSensitivePage.isSensitive(WarmUpPageSignals(url: "https://a.example/")))
    }

    func testConsentToolsAndTheStrictRuleForOtherBanners() {
        XCTAssertGreaterThanOrEqual(WarmUpConsent.tools.count, 25)
        XCTAssertEqual(Set(WarmUpConsent.tools.map(\.name)).count, WarmUpConsent.tools.count)
        XCTAssertTrue(WarmUpConsent.tools.allSatisfy { !$0.accept.isEmpty })
        XCTAssertTrue(WarmUpConsent.allowsGeneric(buttonText: " Alle akzeptieren ", containerName: "cookie-banner", isFixed: true, insideFormWithFields: false))
        XCTAssertFalse(WarmUpConsent.allowsGeneric(buttonText: "Buy now — accept", containerName: "cookie-banner", isFixed: true, insideFormWithFields: false), "only the whole text")
        XCTAssertFalse(WarmUpConsent.allowsGeneric(buttonText: "Accept", containerName: "order-summary", isFixed: true, insideFormWithFields: false))
        XCTAssertFalse(WarmUpConsent.allowsGeneric(buttonText: "Accept", containerName: "cookie-banner", isFixed: false, insideFormWithFields: false))
        XCTAssertFalse(WarmUpConsent.allowsGeneric(buttonText: "Accept", containerName: "consent", isFixed: true, insideFormWithFields: true))
        var generator = Seeded(4)
        XCTAssertEqual(WarmUpConsent.action(.accept, using: &generator), .accept)
        XCTAssertEqual(WarmUpConsent.action(.leave, using: &generator), .leave)
        let actions = (0..<1_000).map { _ in WarmUpConsent.action(.asPeople, using: &generator) }
        XCTAssertTrue((60...200).contains(actions.filter { $0 == .reject }.count))
    }

    func testLinksAHeadlineFirstNeverSignInSeldomTheFooter() {
        let page = URL(string: "https://news.example/")!
        let viewport = (width: 1200.0, height: 800.0)
        func link(_ href: String, _ text: String) -> WarmUpLink { WarmUpLink(href: href, text: text, x: 10, y: 10, width: 300, height: 24) }
        XCTAssertTrue(WarmUpLinkPolicy.allowsReading(link("/politik/artikel-1", "Bundestag beschließt neues Gesetz zur Bahn"), on: page, kind: .address, viewport: viewport))
        for (href, text) in [("/login", "Anmelden"), ("/account", "My account"), ("/user/register", "Join"), ("/a", "Войти"), ("/x", "Sign in")] {
            XCTAssertFalse(WarmUpLinkPolicy.allowsReading(link(href, text), on: page, kind: .address, viewport: viewport), "\(href) \(text)")
        }
        let headline = WarmUpLinkPolicy.weight(link("/a", "Bundestag beschließt neues Gesetz zur Bahn"), placement: .init(inContent: true, inChrome: false))
        let menu = WarmUpLinkPolicy.weight(link("/sport", "Sport"), placement: .init(inContent: false, inChrome: true))
        let legal = WarmUpLinkPolicy.weight(link("/impressum", "Impressum"), placement: .init(inContent: false, inChrome: true))
        XCTAssertGreaterThan(headline, menu * 10)
        XCTAssertGreaterThan(menu, legal * 10)

        var generator = Seeded(2)
        var picks: [String: Int] = [:]
        for _ in 0..<500 { picks[WarmUpLinkPolicy.pick(["headline", "menu", "legal"], weights: [headline, menu, legal], using: &generator) ?? "", default: 0] += 1 }
        XCTAssertGreaterThan(picks["headline", default: 0], 400)
        XCTAssertNil(WarmUpLinkPolicy.pick(["a"], weights: [0], using: &generator))
        XCTAssertNil(WarmUpLinkPolicy.pick([String](), weights: [], using: &generator))
    }

    func testASitesOwnResultIsFoundAmongASearchsLinksAndItsNameIsWhatIsTyped() {
        let results = URL(string: "https://www.google.de/search?q=spiegel")!
        let links = ["https://www.google.de/preferences", "https://de.wikipedia.org/wiki/Der_Spiegel", "https://www.spiegel.de/", "https://www.spiegel.de/politik/"]
        XCTAssertEqual(WarmUpLinkPolicy.result(for: "spiegel.de", among: links, href: { $0 }, on: results), "https://www.spiegel.de/")
        XCTAssertNil(WarmUpLinkPolicy.result(for: "zeit.de", among: links, href: { $0 }, on: results))
        XCTAssertEqual(WarmUpLinkPolicy.searchWords(forSite: "spiegel.de"), "spiegel")
        XCTAssertEqual(WarmUpLinkPolicy.searchWords(forSite: "https://www.bbc.co.uk/news"), "bbc.co.uk", "a name too short to find anything by")
        XCTAssertEqual(WarmUpLinkPolicy.searchWords(forSite: "de.wikipedia.org"), "wikipedia")
    }
}

final class WarmUpRunTests: XCTestCase {
    private func status(_ phase: WarmUpStatus.Phase, reason: String? = nil, rows: [WarmUpSiteVisit], sites: [WarmUpCookieSite]) -> WarmUpStatus {
        var status = WarmUpStatus(phase: phase, visited: 5, total: 6, failed: 1, cookies: sites.reduce(0) { $0 + $1.added }, sites: sites, stopReason: reason)
        status.siteVisits = rows
        status.pagesRead = 9
        status.searchesTyped = 1
        status.consents = 2
        return status
    }

    func testARunTellsItsCookiesOfTheSitesVisitedFromThoseOfOtherDomains() throws {
        let rows = [WarmUpSiteVisit(site: "spiegel.de", arrival: .search, outcome: .visited, pages: 3, seconds: 90, cookies: 12),
                    WarmUpSiteVisit(site: "otto.de", arrival: .address, outcome: .visited, pages: 2, seconds: 60, cookies: 7),
                    WarmUpSiteVisit(site: "idealo.de", arrival: .address, outcome: .blocked, pages: 0, seconds: 3, detail: "cloudflare")]
        let sites = [WarmUpCookieSite(site: "spiegel.de", cookies: 14, added: 12), WarmUpCookieSite(site: "otto.de", cookies: 7, added: 7),
                     WarmUpCookieSite(site: "doubleclick.net", cookies: 3, added: 3), WarmUpCookieSite(site: "old.example", cookies: 5, added: 0)]
        let choice = WarmUpChoice.templates(["day", "shop"], intensity: .normal)
        var plan = WarmUpPlan(addresses: "spiegel.de\notto.de\nidealo.de")
        plan.choice = choice
        let began = Date(timeIntervalSince1970: 1_000), ended = Date(timeIntervalSince1970: 1_600)
        let run = try XCTUnwrap(WarmUpRun(status(.finished, rows: rows, sites: sites), plan: plan, startedAt: began, endedAt: ended, countryCode: "de"))
        XCTAssertEqual(run.cookiesVisited, 19)
        XCTAssertEqual(run.cookiesOther, 3)
        XCTAssertEqual(run.cookies, 22)
        XCTAssertEqual(run.resultKind, .finished)
        XCTAssertEqual(run.visitedSites, 2)
        XCTAssertEqual(run.blockedSites.map(\.site), ["idealo.de"])
        XCTAssertEqual(run.plannedSites, 3)
        XCTAssertEqual(run.templates, ["day", "shop"])
        XCTAssertEqual(run.intensity, "normal")
        XCTAssertEqual(run.duration, 600)
        XCTAssertTrue(run.hasRemarks)
        XCTAssertEqual(WarmUpWarmth(last: run), .partly(ended), "checks on some sites: partly")

        XCTAssertNil(WarmUpRun(WarmUpStatus(phase: .running, visited: 2, total: 6), plan: plan, startedAt: began, endedAt: ended))
        XCTAssertNil(WarmUpRun(WarmUpStatus(phase: .stopped, visited: 0, total: 6), plan: plan, startedAt: began, endedAt: ended))
        let dead = try XCTUnwrap(WarmUpRun(WarmUpStatus(phase: .stopped, visited: 0, total: 6, stopReason: "proxyNotAnswering"), plan: plan, startedAt: began, endedAt: ended))
        XCTAssertEqual(dead.resultKind, .proxyNotAnswering)
        XCTAssertEqual(WarmUpWarmth(last: dead), .attention(ended))
    }

    func testRowsAreOnePerSiteWithItsCookies() {
        let visits = [WarmUpSiteVisit(site: "google.de", arrival: .query, outcome: .visited, pages: 1, seconds: 20),
                      WarmUpSiteVisit(site: "spiegel.de", arrival: .search, outcome: .visited, pages: 2, seconds: 50),
                      WarmUpSiteVisit(site: "google.de", arrival: .query, outcome: .visited, pages: 1, seconds: 15),
                      WarmUpSiteVisit(site: "x.example", arrival: .address, outcome: .failed, pages: 0, seconds: 10, detail: "timeout")]
        let rows = WarmUpSiteVisit.rows(visits, added: ["google.de": 4, "spiegel.de": 9])
        XCTAssertEqual(rows.map(\.site), ["google.de", "spiegel.de", "x.example"])
        XCTAssertEqual(rows[0].pages, 2)
        XCTAssertEqual(rows[0].seconds, 35)
        XCTAssertEqual(rows.map(\.cookies), [4, 9, 0])
        XCTAssertEqual(rows[2].outcomeKind, .failed)
    }

    func testTheStateOfAProfileFollowsItsLastRun() {
        let at = Date(timeIntervalSince1970: 5_000)
        let ok = WarmUpRun(startedAt: at, endedAt: at, result: .finished, sites: [WarmUpSiteVisit(site: "a.de", arrival: .address, outcome: .visited, pages: 1, seconds: 1)])
        let nothing = WarmUpRun(startedAt: at.addingTimeInterval(60), endedAt: at.addingTimeInterval(60), result: .stopped)
        XCTAssertEqual(WarmUpWarmth(last: nil), .never)
        XCTAssertEqual(WarmUpWarmth(last: ok), .warmed(at))
        XCTAssertEqual(WarmUpWarmth(last: nothing, previous: ok), .warmed(at), "a run that read nothing leaves the profile as it was")
        XCTAssertEqual(WarmUpWarmth(last: nothing), .never)
        XCTAssertEqual(WarmUpWarmth(record: WarmUpRecord(endedAt: at, pages: 3, total: 4, cookies: 9, finished: false)), .partly(at))
    }

    func testTheHistoryKeepsTheNewestFiftyAndIsStoredSealed() throws {
        var history = WarmUpHistory()
        for index in 0..<60 {
            let at = Date(timeIntervalSince1970: Double(index))
            history.add(WarmUpRun(startedAt: at, endedAt: at, result: .finished, pages: index))
        }
        XCTAssertEqual(history.runs.count, WarmUpHistory.maximumRuns)
        XCTAssertEqual(history.last?.pages, 59)
        XCTAssertEqual(history.runs.last?.pages, 10)

        let base = FileManager.default.temporaryDirectory.appendingPathComponent("warmup-history-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let repository = try ProfileRepository(vault: MasterVault.create(in: base.appendingPathComponent("A"), password: "pw", iterations: 1_000))
        let profile = try repository.create(name: "P", configuration: ProfileConfiguration())
        XCTAssertTrue(try repository.warmUpHistory(for: profile.id).runs.isEmpty)
        let run = WarmUpRun(startedAt: Date(timeIntervalSince1970: 10), endedAt: Date(timeIntervalSince1970: 70), result: .finished, pages: 4, cookiesVisited: 9)
        try repository.addWarmUpRun(run, for: profile.id)
        try repository.addWarmUpRun(WarmUpRun(startedAt: Date(timeIntervalSince1970: 100), endedAt: Date(timeIntervalSince1970: 130), result: .stopped), for: profile.id)
        let stored = try repository.warmUpHistory(for: profile.id)
        XCTAssertEqual(stored.runs.count, 2)
        XCTAssertEqual(stored.runs.last, run)
        let raw = try Data(contentsOf: repository.warmUpHistoryURL(for: profile.id))
        XCTAssertNil(raw.range(of: Data("cookiesVisited".utf8)), "the history is sealed")
    }

    func testTheQueueCanBePausedAndItsWaitingEntriesMovedAndTakenOff() {
        var queue = WarmUpQueue()
        let ids = (0..<4).map { _ in UUID() }
        for id in ids { queue.add(id, plan: nil, source: .user) }
        let first = queue.startNext(limit: 1)
        XCTAssertEqual(first?.profileID, ids[0])
        queue.isPaused = true
        XCTAssertNil(queue.startNext(limit: 4), "paused: nothing more starts")
        queue.isPaused = false
        let last = queue.waiting.last!
        queue.moveToFront(last.id)
        XCTAssertEqual(queue.waiting.map(\.profileID), [ids[3], ids[1], ids[2]])
        XCTAssertNotNil(queue.cancel(queue.waiting[1].id))
        XCTAssertNil(queue.cancel(first!.id), "the running one is not taken off this way")
        XCTAssertEqual(queue.startNext(limit: 2)?.profileID, ids[3])
        XCTAssertEqual(queue.waiting.map(\.profileID), [ids[2]])
        queue.finish(first!.id, as: .skipped(.notStarted))
        XCTAssertEqual(queue.failedProfiles, [ids[0]])
    }
}
