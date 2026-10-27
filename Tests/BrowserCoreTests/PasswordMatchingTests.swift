@testable import BrowserCore
import XCTest

final class PasswordMatchingTests: XCTestCase {
    func testRegistrableDomainFollowsThePublicSuffixList() {
        let cases: [(String, String?)] = [
            ("example.com", "example.com"),
            ("login.example.com", "example.com"),
            ("WWW.Example.COM.", "example.com"),
            ("a.b.example.co.uk", "example.co.uk"),
            ("co.uk", nil),                         // a public suffix itself
            ("alice.github.io", "alice.github.io"), // private suffix: each name is its own site
            ("github.io", nil),
            ("x.foo.ck", "x.foo.ck"),               // *.ck
            ("www.ck", "www.ck"),                   // !www.ck
            ("a.www.ck", "www.ck"),
            ("login.selftest.invalid", "selftest.invalid"), // unlisted TLD: the default rule `*`
            ("localhost", nil),
            ("192.168.1.10", nil),
            ("::1", nil),
            ("xn--80ak6aa92e.xn--p1ai", "xn--80ak6aa92e.xn--p1ai"), // .рф, in ASCII
        ]
        for (host, expected) in cases {
            XCTAssertEqual(PublicSuffixList.registrableDomain(of: host), expected, host)
        }
        XCTAssertFalse(PublicSuffixList.version.isEmpty)
    }

    func testWebOriginNormalisesWhatWebKitAndURLsSay() throws {
        let fromFrame = try XCTUnwrap(WebOrigin(scheme: "HTTPS", host: "Login.Example.com", port: 0))
        XCTAssertEqual(fromFrame.serialized, "https://login.example.com")
        XCTAssertEqual(fromFrame.port, 443)
        XCTAssertEqual(fromFrame.site, "example.com")
        XCTAssertEqual(WebOrigin(url: URL(string: "https://login.example.com:443/path?q")!), fromFrame)
        XCTAssertEqual(WebOrigin("http://example.com:8080")?.serialized, "http://example.com:8080")
        XCTAssertEqual(WebOrigin(scheme: "http", host: "[::1]", port: 8080)?.serialized, "http://[::1]:8080")
        XCTAssertNil(WebOrigin(scheme: "file", host: "", port: 0))
        XCTAssertNil(WebOrigin(scheme: "https", host: "", port: 0), "an opaque origin (sandboxed frame)")
        XCTAssertNil(WebOrigin(scheme: "data", host: "x", port: 0))
        XCTAssertEqual(PasswordEntry.normalizedOrigin(for: URL(string: "https://EXAMPLE.com:443/login")!), "https://example.com")
    }

    private func entry(_ origin: String, _ username: String, _ password: String = "pw",
                       used: TimeInterval? = nil, updated: TimeInterval = 0) -> PasswordEntry {
        PasswordEntry(origin: origin, username: username, password: password,
                      updatedAt: Date(timeIntervalSince1970: updated), lastUsedAt: used.map(Date.init(timeIntervalSince1970:)))
    }

    func testCandidatesAreTheSiteOwnOriginFirstNeverAcrossSitesOrDowngraded() throws {
        let entries = [
            entry("https://example.com", "apex", used: 50),
            entry("https://login.example.com", "own", used: 10),
            entry("http://login.example.com", "plain", used: 99),
            entry("https://other.example.com", "recent", used: 100),
            entry("https://other.example.com", "older", used: 20),
            entry("https://example.com:8443", "port"),
            entry("https://example.org", "elsewhere"),
            entry("https://alice.github.io", "alice"),
        ]
        let page = try XCTUnwrap(WebOrigin("https://login.example.com"))
        XCTAssertEqual(PasswordMatching.candidates(entries, for: page).map(\.username),
                       ["own", "plain", "recent", "apex", "older"])

        // An http page: never a login saved on https.
        let plainPage = try XCTUnwrap(WebOrigin("http://login.example.com"))
        XCTAssertEqual(PasswordMatching.candidates(entries, for: plainPage).map(\.username), ["plain"])
        // Ports: only the same one (or both the scheme's default).
        XCTAssertEqual(PasswordMatching.candidates(entries, for: try XCTUnwrap(WebOrigin("https://example.com:8443"))).map(\.username), ["port"])
        // A private public suffix keeps people apart.
        XCTAssertTrue(PasswordMatching.candidates(entries, for: try XCTUnwrap(WebOrigin("https://bob.github.io"))).isEmpty)
        // IP addresses and single labels: the host only.
        let local = [entry("http://localhost:3000", "dev"), entry("http://127.0.0.1:3000", "ip")]
        XCTAssertEqual(PasswordMatching.candidates(local, for: try XCTUnwrap(WebOrigin("http://localhost:3000"))).map(\.username), ["dev"])
    }

    func testSaveDecisions() throws {
        let page = try XCTUnwrap(WebOrigin("https://login.example.com"))
        let own = entry("https://login.example.com", "ann", "old")
        let sibling = entry("https://www.example.com", "bob", "b1")
        let entries = [own, sibling, entry("https://example.org", "cid", "c1")]
        func decide(_ user: String, _ password: String, at origin: WebOrigin? = nil) -> PasswordMatching.SaveDecision {
            PasswordMatching.decision(username: user, password: password, at: origin ?? page, entries: entries)
        }
        XCTAssertEqual(decide("ann", "old"), .alreadySaved)
        XCTAssertEqual(decide("ann", "new"), .update(own))
        XCTAssertEqual(decide("bob", "b1"), .alreadySaved, "saved on another host of the site")
        XCTAssertEqual(decide("bob", "b2"), .update(sibling), "the site's only login for that user")
        XCTAssertEqual(decide("cid", "c1"), .save, "another site's login is not this one")
        XCTAssertEqual(decide("", "pin"), .save)
        let two = entries + [entry("https://app.example.com", "bob", "b3")]
        XCTAssertEqual(PasswordMatching.decision(username: "bob", password: "b4", at: page, entries: two), .save,
                       "two logins for the user on the site: a new one rather than a guess")
    }

    func testNeverSavedIsPerSite() throws {
        let sites = ["https://www.example.com", "not an origin"]
        XCTAssertTrue(PasswordMatching.isNeverSaved(try XCTUnwrap(WebOrigin("https://login.example.com")), sites: sites))
        XCTAssertTrue(PasswordMatching.isNeverSaved(try XCTUnwrap(WebOrigin("http://example.com")), sites: sites))
        XCTAssertFalse(PasswordMatching.isNeverSaved(try XCTUnwrap(WebOrigin("https://example.org")), sites: sites))
    }
}

final class PasswordVaultEditingTests: XCTestCase {
    var root: URL!
    var repo: ProfileRepository!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("pb-test-\(UUID().uuidString)")
        repo = try ProfileRepository(vault: MasterVault.create(in: root, password: "pw", iterations: 1_000))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testEditRefusesDuplicatesAndKeepsUsageAcrossReopen() throws {
        let profile = try repo.create(name: "P", configuration: ProfileConfiguration())
        let vault = try repo.passwordVault(for: profile.id)
        try vault.upsert(PasswordEntry(origin: "https://example.com", username: "a", password: "1"))
        try vault.upsert(PasswordEntry(origin: "https://example.com", username: "b", password: "2"))
        let a = try XCTUnwrap(vault.allEntries().first { $0.username == "a" })

        var renamed = a
        renamed.username = "b"
        XCTAssertThrowsError(try vault.update(renamed)) { XCTAssertEqual($0 as? PasswordVaultError, .duplicate) }
        renamed.username = "c"
        renamed.password = "3"
        renamed.note = "work"
        try vault.update(renamed)
        var gone = a
        gone.id = UUID()
        XCTAssertThrowsError(try vault.update(gone)) { XCTAssertEqual($0 as? PasswordVaultError, .notFound) }

        let used = Date(timeIntervalSince1970: 1_800_000_000)
        try vault.markUsed(id: a.id, at: used)
        // Replacing the login (a new password saved from a page) keeps when it was used.
        try vault.upsert(PasswordEntry(origin: "https://example.com", username: "c", password: "4"))

        let reopened = try repo.passwordVault(for: profile.id)
        let c = try XCTUnwrap(reopened.allEntries().first { $0.username == "c" })
        XCTAssertEqual(c.password, "4")
        XCTAssertEqual(c.lastUsedAt, used)
        XCTAssertEqual(reopened.allEntries().count, 2)
        let page = try XCTUnwrap(WebOrigin("https://login.example.com"))
        XCTAssertEqual(reopened.candidates(for: page).map(\.username), ["c", "b"], "the used one first")
        XCTAssertEqual(reopened.saveDecision(username: "b", password: "2", at: page), .alreadySaved)
    }

    func testFilesWrittenBeforeLastUsedStillOpen() throws {
        let legacy = #"[{"id":"7C0A2F44-2F8B-4C38-9A1B-0E4C1D9F3A11","origin":"https://example.com","username":"a","password":"1","updatedAt":"2026-01-01T00:00:00Z"}]"#
        let entries = try JSONCoding.decoder.decode([PasswordEntry].self, from: Data(legacy.utf8))
        XCTAssertEqual(entries.first?.username, "a")
        XCTAssertNil(entries.first?.lastUsedAt)
    }

    func testPasswordSettingsDecodeForOlderConfigsAndSurviveAnEdit() throws {
        let legacy = #"{"geolocation":{"deny":{}},"webRTCPolicy":"disabled"}"#
        let old = try JSONCoding.decoder.decode(ProfileConfiguration.self, from: Data(legacy.utf8))
        XCTAssertTrue(old.passwordAutoFill)
        XCTAssertEqual(old.passwordNeverSaveSites, [])

        let stored = ProfileConfiguration(passwordAutoFill: true, passwordNeverSaveSites: ["https://example.com"])
        let decoded = try JSONCoding.decoder.decode(ProfileConfiguration.self, from: JSONCoding.encoder.encode(stored))
        XCTAssertEqual(decoded, stored)
        // The editor opened before "Never for This Website": saving keeps the stored list, and its
        // own AutoFill switch.
        let edited = ProfileConfiguration(passwordAutoFill: false)
        let saved = edited.keepingStoredState(of: stored)
        XCTAssertEqual(saved.passwordNeverSaveSites, ["https://example.com"])
        XCTAssertFalse(saved.passwordAutoFill)
    }
}
