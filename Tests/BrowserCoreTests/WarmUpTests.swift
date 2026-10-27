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
    func testTheSameAddressAsTypedAndAsTheBrowserWritesIt() {
        func same(_ a: String, _ b: String) -> Bool { WebAddress.isSameAddress(URL(string: a), URL(string: b)) }
        XCTAssertTrue(same("https://example.com#news", "https://example.com/#news"))
        XCTAssertTrue(same("HTTPS://Example.COM/a?b=1#c", "https://example.com/a?b=1#c"))
        XCTAssertTrue(same("https://example.com:443/", "https://example.com/"))
        XCTAssertTrue(same("http://example.com:80/x", "http://example.com/x"))
        XCTAssertTrue(same("https://example.com?q=1", "https://example.com/?q=1"))
        XCTAssertFalse(same("https://example.com/#news", "https://example.com/#other"))
        XCTAssertFalse(same("https://example.com/a", "https://example.com/A"))
        XCTAssertFalse(same("https://example.com:8443/", "https://example.com/"))
        XCTAssertFalse(same("https://example.com/", "http://example.com/"))
        XCTAssertFalse(WebAddress.isSameAddress(nil, URL(string: "about:blank")))
        XCTAssertFalse(same("about:blank", "https://example.com/"))
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
