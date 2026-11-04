import XCTest
@testable import BrowserCore

/// A seeded generator (SplitMix64), so random timing can be tested.
private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

final class WarmUpPlanTests: XCTestCase {
    func testAddressesAreReadLineByLineWithTheSearchFirst() {
        let plan = WarmUpPlan(addresses: """
            # news first
            https://news.example.com/today
            example.org
              example.net/path?q=1  \r
            localhost:8080

            http://Example.org
            """, searchQuery: "  weather berlin ")
        let (pages, problems) = plan.pages()
        XCTAssertEqual(pages.map(\.url.absoluteString), [
            "https://duckduckgo.com/?q=weather%20berlin", "https://news.example.com/today", "https://example.org",
            "https://example.net/path?q=1", "https://localhost:8080", "http://Example.org",
        ])
        XCTAssertEqual(pages.map(\.kind), [.search, .address, .address, .address, .address, .address])
        XCTAssertTrue(problems.isEmpty, "\(problems)")
    }

    func testLinesThatAreNoWebAddressAreReportedWithTheirLine() {
        let plan = WarmUpPlan(addresses: """
            https://ok.example
            javascript:alert(1)
            mailto:someone@example.com
            file:///etc/passwd
            about:blank
            two words
            https://ok.example
            nodot
            http://
            """)
        let (pages, problems) = plan.pages()
        XCTAssertEqual(pages.map(\.url.absoluteString), ["https://ok.example"])
        XCTAssertEqual(problems.map(\.line), [2, 3, 4, 5, 6, 7, 8, 9])
        XCTAssertEqual(problems.map(\.reason), [
            .unsupportedScheme("javascript"), .unsupportedScheme("mailto"), .unsupportedScheme("file"), .unsupportedScheme("about"),
            .notAWebAddress, .duplicate, .notAWebAddress, .notAWebAddress,
        ])
    }

    func testAtMostFiftyPages() {
        let plan = WarmUpPlan(addresses: (1...55).map { "https://site\($0).example" }.joined(separator: "\n"))
        let (pages, problems) = plan.pages()
        XCTAssertEqual(pages.count, WarmUpPlan.maximumPages)
        XCTAssertEqual(problems.map(\.reason), Array(repeating: .tooMany, count: 5))
        XCTAssertEqual(problems.first?.line, 51)
    }

    func testTimesAreKeptWithinTheLimitsAndInOrder() {
        var plan = WarmUpPlan(minimumDwell: 0.1, maximumDwell: 10_000)
        XCTAssertEqual(plan.normalized.minimumDwell, WarmUpPlan.dwellLimits.lowerBound)
        XCTAssertEqual(plan.normalized.maximumDwell, WarmUpPlan.dwellLimits.upperBound)
        plan = WarmUpPlan(minimumDwell: 30, maximumDwell: 10)
        XCTAssertEqual(plan.normalized.maximumDwell, 30, "a maximum below the minimum is the minimum")
    }

    func testTheAddressBarStillSearchesTextAndOpensAddresses() {
        XCTAssertEqual(WebAddress.url(fromAddressBarInput: "example.com")?.absoluteString, "https://example.com")
        XCTAssertEqual(WebAddress.url(fromAddressBarInput: "http://a.test/x")?.absoluteString, "http://a.test/x")
        XCTAssertEqual(WebAddress.url(fromAddressBarInput: "about:blank")?.absoluteString, "about:blank")
        XCTAssertEqual(WebAddress.url(fromAddressBarInput: "cats & dogs?")?.absoluteString,
                       "https://duckduckgo.com/?q=cats%20%26%20dogs%3F")
        XCTAssertNil(WebAddress.url(fromAddressBarInput: "   "))
    }
}

final class WebAddressTests: XCTestCase {
    func testTheSamePageAsTypedAndAsTheBrowserWritesIt() {
        func same(_ a: String, _ b: String) -> Bool { WebAddress.isSameDocument(URL(string: a), URL(string: b)) }
        XCTAssertTrue(same("https://example.com#news", "https://example.com/#news"))
        XCTAssertTrue(same("https://example.com/#news", "https://example.com/#/news"))
        XCTAssertTrue(same("https://example.com/a#news", "https://example.com/a"))
        XCTAssertTrue(same("HTTPS://Example.COM/a?b=1#c", "https://example.com/a?b=1#c"))
        XCTAssertTrue(same("https://example.com:443/", "https://example.com/"))
        XCTAssertTrue(same("http://example.com:80/x", "http://example.com/x"))
        XCTAssertTrue(same("https://example.com?q=1", "https://example.com/?q=1"))
        XCTAssertFalse(same("https://example.com/a", "https://example.com/A"))
        XCTAssertFalse(same("https://example.com/?q=1#x", "https://example.com/?q=2#x"))
        XCTAssertFalse(same("https://example.com:8443/", "https://example.com/"))
        XCTAssertFalse(same("https://example.com/", "http://example.com/"))
        XCTAssertFalse(WebAddress.isSameDocument(nil, URL(string: "about:blank")))
        XCTAssertFalse(same("about:blank", "https://example.com/"))
        XCTAssertFalse(same("about:blank", "https://example.com/#x"))
    }
}

final class WarmUpTimingTests: XCTestCase {
    func testDwellStaysBetweenThePlansTimes() {
        var generator = SeededGenerator(state: 1)
        let plan = WarmUpPlan(minimumDwell: 4, maximumDwell: 9)
        let dwells = (0..<500).map { _ in WarmUpTiming.dwell(plan, using: &generator) }
        XCTAssertTrue(dwells.allSatisfy { (4...9).contains($0) })
        XCTAssertGreaterThan(Set(dwells.map { Int($0) }).count, 3, "random, not one fixed time")
        XCTAssertEqual(WarmUpTiming.dwell(WarmUpPlan(minimumDwell: 6, maximumDwell: 6), using: &generator), 6)
        let pauses = (0..<200).map { _ in WarmUpTiming.pause(using: &generator) }
        XCTAssertTrue(pauses.allSatisfy { (1...3).contains($0) })
    }

    func testGesturesFitTheDwellAndMostlyScrollDown() {
        var generator = SeededGenerator(state: 7)
        for dwell in [2.0, 5, 12, 40, 300] {
            let gestures = WarmUpTiming.gestures(over: dwell, using: &generator)
            XCTAssertEqual(gestures.count, min(6, max(1, Int((dwell - 1) / 4))))
            for gesture in gestures {
                let end = gesture.at + Double(gesture.deltas.count) * gesture.interval
                XCTAssertLessThanOrEqual(end, dwell - 0.4, "a gesture ends before the robot leaves (dwell \(dwell))")
                XCTAssertTrue((8...14).contains(gesture.deltas.count))
                let sizes = gesture.deltas.map(abs)
                XCTAssertEqual(sizes, sizes.sorted(by: >), "each step no larger than the one before")
            }
            XCTAssertGreaterThan(gestures.first?.deltas.reduce(0, +) ?? 0, 0, "the first gesture scrolls down")
        }
        XCTAssertTrue(WarmUpTiming.gestures(over: 1.5, using: &generator).isEmpty, "no time to scroll")
        var down = 0, up = 0
        for _ in 0..<200 {
            for gesture in WarmUpTiming.gestures(over: 30, using: &generator) {
                if gesture.deltas.reduce(0, +) > 0 { down += 1 } else { up += 1 }
            }
        }
        XCTAssertGreaterThan(up, 0)
        XCTAssertGreaterThan(down, up * 3)
    }
}

final class WarmUpLinkPolicyTests: XCTestCase {
    private let viewport = (width: 1200.0, height: 800.0)

    private func link(_ href: String, _ text: String = "Read more", target: String = "", download: Bool = false,
                      y: Double = 100) -> WarmUpLink {
        WarmUpLink(href: href, text: text, target: target, download: download, x: 20, y: y, width: 120, height: 20)
    }

    func testOnTheUsersAddressesOnlyPlainLinksOfTheSameSite() {
        let page = URL(string: "https://www.example.co.uk/news/")!
        let links = [
            link("/news/story-1", "Story one"),                            // relative, same site
            link("https://shop.example.co.uk/about", "About us"),          // another host of the same site
            link("https://other.co.uk/x", "Elsewhere"),                     // another site
            link("https://www.example.co.uk/news/#top", "Top"),             // the same page
            link("https://www.example.co.uk/a", "New window", target: "_blank"),
            link("https://www.example.co.uk/report.pdf", "Annual report pdf"),
            link("https://www.example.co.uk/b", "File", download: true),
            link("https://www.example.co.uk/account/logout", "Account"),    // risky address
            link("https://www.example.co.uk/c", "Sign out"),                // risky words
            link("https://www.example.co.uk/d", "Add to cart"),
            link("https://www.example.co.uk/e", "Выйти"),
            link("javascript:void(0)", "Menu"),
            link("https://www.example.co.uk/f", "x"),                       // no words to read
            link("https://www.example.co.uk/g", "Below the fold", y: 900),  // not in view
            link("https://www.example.co.uk/h", "Explicit self", target: "_self"),
        ]
        let allowed = WarmUpLinkPolicy.candidates(links, on: page, kind: .address, viewport: viewport)
        XCTAssertEqual(allowed.map(\.text), ["Story one", "About us", "Explicit self"])
    }

    func testEachLinkIsJudgedByItselfNotByItsAddress() {
        let page = URL(string: "https://www.example.com/")!
        let plain = link("/story/42", "Story 42")
        let newWindow = link("/story/42", "Story 42 in a new window", target: "_blank")
        let download = link("/story/42", "Story 42 as a file", download: true)
        XCTAssertTrue(WarmUpLinkPolicy.allows(plain, on: page, kind: .address, viewport: viewport))
        XCTAssertFalse(WarmUpLinkPolicy.allows(newWindow, on: page, kind: .address, viewport: viewport))
        XCTAssertFalse(WarmUpLinkPolicy.allows(download, on: page, kind: .address, viewport: viewport))
        XCTAssertEqual(WarmUpLinkPolicy.candidates([newWindow, plain, download], on: page, kind: .address, viewport: viewport), [plain])
    }

    func testOnSearchResultsOnlyLinksToOtherSites() {
        let page = URL(string: "https://duckduckgo.com/?q=weather")!
        let links = [
            link("https://duckduckgo.com/?q=weather&ia=images", "Images"),
            link("https://www.weather.example/berlin", "Berlin weather"),
            link("https://help.duckduckgo.com/privacy", "Privacy"),
        ]
        let allowed = WarmUpLinkPolicy.candidates(links, on: page, kind: .search, viewport: viewport)
        XCTAssertEqual(allowed.map(\.text), ["Berlin weather"])
    }

    func testSelfTestHostsAreOneSite() {
        let page = URL(string: "http://warmup.selftest.invalid/pb-warmup/1")!
        let allowed = WarmUpLinkPolicy.candidates([link("http://warmup.selftest.invalid/pb-warmup/next", "Next page"),
                                                   link("http://other.invalid/x", "Other")],
                                                  on: page, kind: .address, viewport: viewport)
        XCTAssertEqual(allowed.map(\.text), ["Next page"])
    }
}

final class WarmUpStorageTests: XCTestCase {
    func testThePlanIsStoredEncryptedPerProfileAndNotSynced() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("pb-warmup-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let repository = try ProfileRepository(vault: MasterVault.create(in: base.appendingPathComponent("A"), password: "pw", iterations: 1_000))
        let id = try repository.create(name: "P", configuration: ProfileConfiguration()).id
        XCTAssertNil(try repository.warmUpPlan(for: id))
        let plan = WarmUpPlan(addresses: "https://secret-site.example/", searchQuery: "private words", minimumDwell: 3, maximumDwell: 8,
                              scroll: false, followLinks: true)
        try repository.saveWarmUpPlan(plan, for: id)
        XCTAssertEqual(try repository.warmUpPlan(for: id), plan)
        let onDisk = try Data(contentsOf: repository.warmUpPlanURL(for: id))
        XCTAssertNil(onDisk.range(of: Data("secret-site".utf8)))
        XCTAssertNil(onDisk.range(of: Data("private words".utf8)))

        let transport = LocalDirectorySyncTransport(directory: base.appendingPathComponent("server"))
        let report = try await SyncEngine(repository: repository, transport: transport).sync()
        XCTAssertFalse(report.pushed.contains { $0.hasSuffix("/warmup") }, "the plan stays on this Mac")
        XCTAssertEqual(Set(report.pushed), ["index", "profile/\(id.uuidString)/config"])
    }
}

/// The ready-made lists, the two dials over them, and what a plan made from them visits.
final class WarmUpPresetTests: XCTestCase {
    func testEveryShippedPresetIsUsableAsIs() {
        XCTAssertFalse(WarmUpPresets.all.isEmpty)
        for preset in WarmUpPresets.all {
            XCTAssertFalse(preset.addresses.isEmpty, "\(preset.id) has no sites")
            let plan = WarmUpPlan(addresses: preset.addresses.joined(separator: "\n"))
            let reading = plan.pages()
            XCTAssertEqual(reading.problems.count, 0,
                           "\(preset.id): \(reading.problems.map(\.text))")
            XCTAssertEqual(reading.pages.count, preset.addresses.count, preset.id)
            XCTAssertEqual(Set(preset.addresses).count, preset.addresses.count, "\(preset.id) lists a site twice")
        }
        // Every country list is named by its ISO 3166-1 alpha-2 code, which is how the screen
        // finds the one for a profile's exit country and draws its flag.
        for preset in WarmUpPresets.countries {
            XCTAssertEqual(preset.id.count, 2, preset.id)
            XCTAssertEqual(preset.id, preset.id.lowercased(), preset.id)
            XCTAssertNotNil(WarmUpPresets.country(preset.id.uppercased()))
        }
    }

    func testTheTimeGivenDecidesHowManySitesAreVisitedAndTheQualityHowLongEachTakes() {
        let quick = WarmUpPlan.from(preset: WarmUpPresets.general, minutes: 10, quality: .quick)
        let deep = WarmUpPlan.from(preset: WarmUpPresets.general, minutes: 10, quality: .deep)
        XCTAssertGreaterThan(quick.pages().pages.count, deep.pages().pages.count,
                             "the same ten minutes read fewer pages, more closely")
        XCTAssertEqual(deep.minimumDwell, WarmUpQuality.deep.dwell.lowerBound)
        XCTAssertTrue(deep.followLinks)
        XCTAssertFalse(quick.scroll)
        // What fits is what runs: the estimate for the plan stays inside the time given.
        for minutes in [5, 20, 60] {
            for quality in WarmUpQuality.allCases {
                let plan = WarmUpPlan.from(preset: WarmUpPresets.general, minutes: minutes, quality: quality)
                XCTAssertGreaterThan(plan.pages().pages.count, 0, "\(minutes) min, \(quality)")
                XCTAssertLessThanOrEqual(plan.estimatedSeconds, TimeInterval(minutes * 60) + plan.secondsPerPage,
                                         "\(minutes) min, \(quality)")
            }
        }
    }

    func testAComposedListLeadsWithTheProxysCountryAndMixesInWhatWasChosen() {
        let preset = WarmUpPresets.composed(countryCode: "de", interests: [WarmUpPresets.shopping],
                                            name: "mine", shuffle: { $0 })
        let german = Set(WarmUpPresets.country("de")!.addresses)
        XCTAssertEqual(Array(preset.addresses.prefix(2)), Array(WarmUpPresets.country("de")!.addresses.prefix(2)))
        XCTAssertTrue(preset.addresses.contains(where: WarmUpPresets.shopping.addresses.contains))
        XCTAssertEqual(Set(preset.addresses).count, preset.addresses.count, "a site is listed once")
        // Two of the country's own sites for every one of the rest, as long as it has them.
        let first = preset.addresses.prefix(6)
        XCTAssertEqual(first.filter(german.contains).count, 4)
        XCTAssertTrue(preset.searches.contains(where: WarmUpPresets.country("de")!.searches.contains))
    }

    func testAComposedListFallsBackToTheEverydayOneWithoutAKnownCountry() {
        for code in [nil, "", "zz"] as [String?] {
            let preset = WarmUpPresets.composed(countryCode: code, interests: [], name: "mine", shuffle: { $0 })
            XCTAssertEqual(preset.addresses, WarmUpPresets.general.addresses, "code=\(code ?? "nil")")
        }
    }

    func testTheChoiceIsKeptWithThePlanSoTheScreenOpensWhereItWasLeft() throws {
        let choice = WarmUpChoice(source: .composed, presetID: "general", interestIDs: ["work"], minutes: 45, quality: .deep)
        let plan = try XCTUnwrap(choice.plan(countryCode: "fr", composedName: "mine"))
        XCTAssertEqual(plan.choice, choice)
        XCTAssertEqual(plan.followLinks, true)
        let restored = try JSONDecoder().decode(WarmUpPlan.self, from: JSONEncoder().encode(plan))
        XCTAssertEqual(restored.choice, choice)
        XCTAssertNotNil(choice.plan(countryCode: nil), "a composed choice has a list even without a country")
        XCTAssertNil(WarmUpChoice(source: .manual).plan(countryCode: "fr"), "a hand-written list is the plan's own")
    }

    func testAPlanSavedBeforeTheScreenHadReadyMadeListsStillReads() throws {
        let json = Data("""
            {"addresses":"example.com","searchQuery":"","minimumDwell":5,"maximumDwell":15,"scroll":true,"followLinks":false}
            """.utf8)
        let plan = try JSONDecoder().decode(WarmUpPlan.self, from: json)
        XCTAssertNil(plan.choice)
        XCTAssertEqual(plan.pages().pages.count, 1)
    }

    func testTheStatusSaysHowFarAlongARunIs() {
        var status = WarmUpStatus(phase: .running, visited: 3, total: 12, failed: 1, cookies: 84, secondsRemaining: 300)
        XCTAssertEqual(status.fraction, 0.25)
        XCTAssertTrue(status.isRunning)
        status.phase = .finished
        XCTAssertFalse(status.isRunning)
        XCTAssertEqual(WarmUpStatus(phase: .running, visited: 0, total: 0).fraction, 0, "no pages, no bar")
        XCTAssertEqual(WarmUpStatus(phase: .finished, visited: 20, total: 12).fraction, 1, "never past the end")
    }

    func testTheCountriesAskedForEachHaveTheirOwnList() {
        let asked = ["US", "GB", "DE", "FR", "ES", "IT", "NL", "PL", "UA", "KZ", "EE", "LV", "LT", "FI", "SE", "NO",
                     "DK", "CZ", "PT", "TR", "BR", "MX", "CA", "AU", "JP", "IN"]
        for code in asked {
            guard let preset = WarmUpPresets.country(code) else {
                XCTFail("no list for \(code)")
                continue
            }
            XCTAssertGreaterThanOrEqual(preset.addresses.count, 7, code)
            XCTAssertEqual(preset.group, .country, code)
            XCTAssertFalse(preset.searches.isEmpty, code)
            for search in preset.searches {
                XCTAssertNotNil(WebAddress.searchURL(for: search), "\(code): \(search)")
            }
        }
        XCTAssertEqual(Set(WarmUpPresets.countries.map(\.id)).count, WarmUpPresets.countries.count, "one list per country")
    }
}

/// What a run leaves behind, per site: the report the warm-up screen shows once a run is over.
final class WarmUpCookieCountTests: XCTestCase {
    private func cookie(_ name: String, _ domain: String, _ path: String = "/") -> WarmUpCookieCount.Cookie {
        WarmUpCookieCount.Cookie(name: name, domain: domain, path: path)
    }

    func testCookiesAreCountedPerRegistrableDomainAndTheRunsOwnAreTold() {
        let before: Set<WarmUpCookieCount.Cookie> = [
            cookie("session", "www.example.co.uk"),
            cookie("consent", ".example.co.uk"),
            cookie("old", "news.example.com"),
        ]
        let after = [
            cookie("session", "www.example.co.uk"), // was there: a new value is not a new cookie
            cookie("consent", ".example.co.uk"),
            cookie("cart_id", "shop.example.co.uk"), // new, on the same site
            cookie("old", "news.example.com"),
            cookie("a", "alice.github.io"), cookie("b", "bob.github.io"), // a public suffix keeps them apart
            cookie("ip", "192.0.2.7"),
            cookie("lan", "localhost"),
            cookie("x", "Example.ORG", "/a"), cookie("x", "example.org", "/b"), // one per name, domain and path
        ]
        let sites = WarmUpCookieCount.sites(before: before, after: after)
        var table: [String: [Int]] = [:]
        for site in sites { table[site.site] = [site.cookies, site.added] }
        XCTAssertEqual(table, [
            "example.co.uk": [3, 1], "example.com": [1, 0], "alice.github.io": [1, 1], "bob.github.io": [1, 1],
            "192.0.2.7": [1, 1], "localhost": [1, 1], "example.org": [2, 2],
        ])
        XCTAssertEqual(WarmUpCookieCount.added(before: before, after: after), 7)
        // The run's own sites first, most added first, then by cookies held, then by name.
        XCTAssertEqual(sites.map(\.site), ["example.org", "example.co.uk", "192.0.2.7", "alice.github.io",
                                           "bob.github.io", "localhost", "example.com"])
    }

    func testASiteWhoseCookiesWentIsNotListedAndTheListHasALimit() {
        let before: Set<WarmUpCookieCount.Cookie> = [cookie("gone", "expired.example")]
        XCTAssertTrue(WarmUpCookieCount.sites(before: before, after: []).isEmpty)
        XCTAssertEqual(WarmUpCookieCount.added(before: before, after: []), 0)
        let many = (0..<150).map { cookie("c", "site\($0).example") }
        let sites = WarmUpCookieCount.sites(before: [], after: many)
        XCTAssertEqual(sites.count, WarmUpCookieCount.maximumSites)
        XCTAssertTrue(sites.allSatisfy { $0.cookies == 1 && $0.added == 1 })
    }

    func testTheStatusCarriesTheSitesAcrossTheChannelAndReadsWithoutThem() throws {
        let status = WarmUpStatus(phase: .finished, visited: 4, total: 4, cookies: 3,
                                  sites: [WarmUpCookieSite(site: "example.de", cookies: 5, added: 3)])
        let decoded = try JSONDecoder().decode(WarmUpStatus.self, from: JSONEncoder().encode(status))
        XCTAssertEqual(decoded, status)
        // A report without the list (a run still going) reads as before.
        let running = Data(#"{"phase":"running","visited":1,"total":4,"failed":0,"cookies":2}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(WarmUpStatus.self, from: running).sites)
    }
}

/// "Warm up every N hours": what is due, and when the next run comes.
final class WarmUpScheduleTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private func hours(_ value: Double) -> TimeInterval { value * 3600 }

    func testTheFirstRunIsOneIntervalAfterTurningItOnAndThenAfterTheLastRun() {
        var schedule = WarmUpSchedule(everyHours: 6, since: start)
        XCTAssertFalse(schedule.isDue(at: start), "not at once: Start is there for a run now")
        XCTAssertFalse(schedule.isDue(at: start + hours(5.9)))
        XCTAssertTrue(schedule.isDue(at: start + hours(6)))
        // A run from anywhere (the warm-up screen too) moves the next one.
        schedule.lastRunAt = start + hours(5)
        XCTAssertEqual(schedule.nextRun, start + hours(11))
        // So does an attempt that came to nothing: a broken proxy is not launched every minute.
        schedule.lastAttemptAt = start + hours(12)
        XCTAssertEqual(schedule.nextRun, start + hours(18))
        // Off: never due, the times kept.
        schedule.isEnabled = false
        XCTAssertFalse(schedule.isDue(at: start + hours(100)))
    }

    func testAMacThatSleptThroughSeveralIntervalsRunsOnceNotOncePerInterval() {
        let id = UUID()
        var scheduler = WarmUpScheduler(schedules: [id: WarmUpSchedule(everyHours: 1, since: start)])
        let wake = start + hours(30)
        XCTAssertEqual(scheduler.due(at: wake), [id])
        scheduler.recordRun(id, at: wake + 600)
        XCTAssertEqual(scheduler.due(at: wake + 700), [], "one run, then a whole interval")
        XCTAssertEqual(scheduler.nextRun(of: id, now: wake + 700), wake + 600 + hours(1))
    }

    func testTheHoursAreKeptToTheirRange() {
        XCTAssertEqual(WarmUpSchedule(everyHours: 0, since: start).interval, hours(1))
        XCTAssertEqual(WarmUpSchedule(everyHours: 10_000, since: start).interval,
                       hours(Double(WarmUpSchedule.hourRange.upperBound)))
    }

    func testDueRunsComeLongestOverdueFirstAndAProfileInUseIsTriedAgainLater() {
        let early = UUID(), late = UUID(), off = UUID(), notYet = UUID()
        var scheduler = WarmUpScheduler(schedules: [
            late: WarmUpSchedule(everyHours: 2, since: start + hours(1)),
            early: WarmUpSchedule(everyHours: 2, since: start),
            off: WarmUpSchedule(isEnabled: false, everyHours: 1, since: start),
            notYet: WarmUpSchedule(everyHours: 24, since: start),
        ])
        let now = start + hours(4)
        XCTAssertEqual(scheduler.due(at: now), [early, late])
        // The profile was in use: put off for a while, not until its next interval.
        scheduler.postpone(early, at: now)
        XCTAssertEqual(scheduler.due(at: now + 60), [late])
        XCTAssertEqual(scheduler.nextRun(of: early, now: now + 60), now + WarmUpScheduler.retryDelay)
        XCTAssertEqual(scheduler.due(at: now + WarmUpScheduler.retryDelay), [early, late])
        // A run of it, from anywhere, settles that.
        scheduler.recordRun(early, at: now + 120)
        XCTAssertEqual(scheduler.due(at: now + WarmUpScheduler.retryDelay), [late])
        XCTAssertNil(scheduler.nextRun(of: off, now: now))
        XCTAssertEqual(scheduler.nextRun(of: late, now: now), now, "already due: now")
        XCTAssertEqual(scheduler.nextRun(of: notYet, now: now), start + hours(24))
        XCTAssertEqual(scheduler.nextCheck(now: now + 300), now + 300, "something is due already")
        scheduler.recordAttempt(late, at: now)
        XCTAssertEqual(scheduler.nextCheck(now: now), now + hours(2), "the earliest next run of all")
    }

    func testAClockSetBackDoesNotLeaveTheProfileWaitingForATimeAlreadyPast() {
        let id = UUID()
        var scheduler = WarmUpScheduler(schedules: [id: WarmUpSchedule(everyHours: 6, since: start, lastRunAt: start + hours(48))])
        let now = start + hours(1) // the clock went back two days
        XCTAssertEqual(scheduler.due(at: now), [])
        XCTAssertEqual(scheduler.nextRun(of: id, now: now), now + hours(6))
        XCTAssertEqual(scheduler.due(at: now + hours(6)), [id])
    }

    func testSchedulesOfDeletedProfilesAreForgotten() {
        let kept = UUID(), deleted = UUID()
        var scheduler = WarmUpScheduler(schedules: [kept: WarmUpSchedule(since: start), deleted: WarmUpSchedule(since: start)])
        scheduler.postpone(deleted, at: start)
        scheduler.keep(only: [kept])
        XCTAssertEqual(Set(scheduler.schedules.keys), [kept])
        XCTAssertTrue(scheduler.postponedUntil.isEmpty)
        XCTAssertNil(scheduler.recordRun(deleted, at: start), "no schedule, nothing to store")
        scheduler.set(nil, for: kept)
        XCTAssertNil(scheduler.nextCheck(now: start))
    }

    func testTheScheduleIsStoredEncryptedPerProfileAndNeitherSyncedNorExported() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("pb-warmup-schedule-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let repository = try ProfileRepository(vault: MasterVault.create(in: base.appendingPathComponent("A"), password: "pw", iterations: 1_000))
        let id = try repository.create(name: "P", configuration: ProfileConfiguration()).id
        XCTAssertNil(try repository.warmUpSchedule(for: id))
        let schedule = WarmUpSchedule(everyHours: 12, since: start, lastRunAt: start + hours(3))
        try repository.saveWarmUpSchedule(schedule, for: id)
        XCTAssertEqual(try repository.warmUpSchedule(for: id), schedule)
        let onDisk = try Data(contentsOf: repository.warmUpScheduleURL(for: id))
        XCTAssertNil(onDisk.range(of: Data("everyHours".utf8)))

        let transport = LocalDirectorySyncTransport(directory: base.appendingPathComponent("server"))
        let report = try await SyncEngine(repository: repository, transport: transport).sync()
        XCTAssertFalse(report.pushed.contains { $0.contains("warmup") }, "the schedule stays on this Mac")

        let file = base.appendingPathComponent("P.pbprofile")
        try ProfileTransfer.export(id, from: repository, to: file, password: "transfer",
                                   kdf: KDFParameters.generate(iterations: 1_000))
        let imported = try ProfileTransfer.importProfile(from: file, password: "transfer", into: repository, name: "Copy")
        XCTAssertNil(try repository.warmUpSchedule(for: imported.id),
                     "another Mac does not start warming a profile up because this one was told to")
    }
}

/// Warm-ups taking turns: who is next, and "profile n of N".
final class WarmUpQueueTests: XCTestCase {
    func testProfilesRunOneAfterTheOtherInTheOrderTheyWereAdded() throws {
        var queue = WarmUpQueue()
        let a = UUID(), b = UUID(), c = UUID()
        let plan = WarmUpPlan(addresses: "example.com")
        XCTAssertTrue(queue.add(a, plan: plan, source: .user))
        XCTAssertTrue(queue.add(b, plan: plan, source: .user))
        XCTAssertTrue(queue.add(c, plan: nil, source: .schedule))
        XCTAssertFalse(queue.add(b, plan: plan, source: .schedule), "already waiting")
        XCTAssertNil(queue.position, "nothing runs yet")

        let first = try XCTUnwrap(queue.startNext())
        XCTAssertEqual(first.profileID, a)
        XCTAssertNil(queue.startNext(), "one at a time")
        XCTAssertEqual(queue.position?.number, 1)
        XCTAssertEqual(queue.position?.count, 3)
        XCTAssertTrue(queue.isQueued(a))

        let status = WarmUpStatus(phase: .finished, visited: 1, total: 1, cookies: 4)
        queue.finish(first.id, as: .done(status))
        XCTAssertFalse(queue.isQueued(a))
        XCTAssertTrue(queue.add(a, plan: plan, source: .schedule), "a profile whose run is over can come again")
        let second = try XCTUnwrap(queue.startNext())
        XCTAssertEqual(second.profileID, b)
        XCTAssertEqual(queue.position?.number, 2)
        XCTAssertEqual(queue.position?.count, 4)
        queue.finish(second.id, as: .skipped(.inUse))
        let third = try XCTUnwrap(queue.startNext())
        XCTAssertEqual(third.profileID, c)
        XCTAssertNil(third.plan, "a scheduled run reads the profile's saved plan when its turn comes")
        XCTAssertEqual(Array(queue.entries.map(\.state).prefix(2)), [.done(status), .skipped(.inUse)])
    }

    func testTheRestCanBeCancelledWhileTheRunningOneGoesOn() throws {
        var queue = WarmUpQueue()
        let ids = [UUID(), UUID(), UUID(), UUID()]
        for id in ids { queue.add(id, plan: nil, source: .user) }
        let running = try XCTUnwrap(queue.startNext())
        let cancelled = queue.cancelWaiting()
        XCTAssertEqual(cancelled.map(\.profileID), Array(ids.dropFirst()))
        XCTAssertEqual(queue.current?.profileID, ids[0])
        XCTAssertEqual(queue.position?.number, 1)
        XCTAssertEqual(queue.position?.count, 1, "the run going on is now the last")
        XCTAssertNil(queue.startNext())
        // A late answer does not finish an entry that was cancelled.
        queue.finish(cancelled[0].id, as: .done(nil))
        XCTAssertEqual(queue.entries[1].state, .cancelled)
        queue.finish(running.id, as: .done(nil))
        XCTAssertFalse(queue.isActive)
    }

    func testANewQueueBeginsOnceTheLastOneIsOver() throws {
        var queue = WarmUpQueue()
        let a = UUID(), b = UUID()
        queue.add(a, plan: nil, source: .user)
        let entry = try XCTUnwrap(queue.startNext())
        queue.finish(entry.id, as: .done(nil))
        queue.add(b, plan: nil, source: .user)
        XCTAssertEqual(queue.entries.map(\.profileID), [b], "counted from 1 again")
        _ = queue.startNext()
        XCTAssertEqual(queue.position?.number, 1)
        queue.cancelAll()
        XCTAssertFalse(queue.isActive)
        XCTAssertNil(queue.current)
    }
}
