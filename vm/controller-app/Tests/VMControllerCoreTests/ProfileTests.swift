import Foundation
import XCTest
@testable import VMControllerCore

final class ProfileModelTests: XCTestCase {
    func testVMNameIsSafeSlugPlusID() {
        let p = Profile(id: "abcd1234", name: "My Work Profile!")
        XCTAssertEqual(p.vmName, "pb-my-work-profile-abcd1234")
        XCTAssertEqual(Profile(id: "x", name: "  ").vmName, "pb-profile-x")
        XCTAssertEqual(Profile(id: "x", name: "Работа").vmName, "pb-profile-x", "non-ASCII collapses, id disambiguates")
        XCTAssertEqual(Profile(id: "x", name: "a/b\\c").vmName, "pb-a-b-c-x")
    }

    func testNewIDIsEightHex() {
        let id = Profile.newID()
        XCTAssertEqual(id.count, 8)
        XCTAssertTrue(id.allSatisfy { $0.isHexDigit })
    }
}

final class ProfileStoreTests: XCTestCase {
    var store: ProfileStore!
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("pstore-\(UUID().uuidString)")
        store = ProfileStore(url: dir.appendingPathComponent("profiles.json"))
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    func testEmptyWhenMissing() throws {
        XCTAssertEqual(try store.list(), [])
    }

    func testAddListPersistAcrossInstances() throws {
        let a = try store.add(Profile(name: "Alpha", proxy: "socks5://10.0.0.1:1080"))
        _ = try store.add(Profile(name: "Beta"))
        XCTAssertEqual(try store.list().map(\.name), ["Alpha", "Beta"], "sorted by createdAt")

        // A fresh store over the same file sees the same data (ISO8601 dates round-trip).
        let reopened = ProfileStore(url: store.url)
        let loaded = try reopened.get(a.id)
        XCTAssertEqual(loaded?.proxy, "socks5://10.0.0.1:1080")
    }

    func testDuplicateNameRejectedCaseInsensitively() throws {
        _ = try store.add(Profile(name: "Work"))
        XCTAssertThrowsError(try store.add(Profile(name: "work"))) { error in
            XCTAssertEqual(error as? ProfileError, .duplicateName("work"))
        }
    }

    func testBlankNameRejected() throws {
        XCTAssertThrowsError(try store.add(Profile(name: "   "))) { XCTAssertEqual($0 as? ProfileError, .invalidName) }
    }

    func testUpdateBumpsTimestampAndPersists() throws {
        let p = try store.add(Profile(name: "Gamma"))
        let before = p.updatedAt
        Thread.sleep(forTimeInterval: 0.01)
        let updated = try store.update(p.id) { $0.lastURL = "https://example.com"; $0.cookieCount = 3 }
        XCTAssertEqual(updated.lastURL, "https://example.com")
        XCTAssertEqual(updated.cookieCount, 3)
        XCTAssertGreaterThan(updated.updatedAt, before)
        XCTAssertEqual(try store.get(p.id)?.cookieCount, 3)
    }

    func testRemove() throws {
        let p = try store.add(Profile(name: "Delta"))
        try store.remove(p.id)
        XCTAssertEqual(try store.list(), [])
        XCTAssertThrowsError(try store.remove(p.id)) { XCTAssertEqual($0 as? ProfileError, .notFound(p.id)) }
    }

    func testClipboardDefaultsOff() throws {
        XCTAssertFalse(try store.add(Profile(name: "Eps")).clipboardShared)
    }

    func testDirectoriesAreUnderStore() {
        let p = Profile(id: "id1", name: "x")
        XCTAssertTrue(store.cookiesURL(for: p).path.hasSuffix("profiles/id1/cookies.json"))
    }
}

final class ProxyAndNetworkTests: XCTestCase {
    func testProxyEndpointParsing() {
        let e = ProxyEndpoint("socks5://user:pass@10.1.2.3:1080")
        XCTAssertEqual(e?.scheme, "socks5")
        XCTAssertEqual(e?.host, "10.1.2.3")
        XCTAssertEqual(e?.port, 1080)
        XCTAssertTrue(e!.isIPv4)
        XCTAssertEqual(e?.allowCIDR, "10.1.2.3/32")

        XCTAssertFalse(ProxyEndpoint("http://proxy.example.com:8080")!.isIPv4)
        XCTAssertNil(ProxyEndpoint("http://proxy.example.com:8080")!.allowCIDR, "hostname needs resolving")
        XCTAssertNil(ProxyEndpoint("not a url"))
        XCTAssertNil(ProxyEndpoint("ftp://10.0.0.1"), "unsupported scheme")
    }

    func testFailClosedPolicy() {
        XCTAssertEqual(NetworkPolicy.failClosed(proxy: "socks5://10.0.0.9:1080"),
                       .proxyOnly(allowCIDR: "10.0.0.9/32"))
        XCTAssertEqual(NetworkPolicy.failClosed(proxy: nil), .isolated, "no proxy = no internet")
        XCTAssertEqual(NetworkPolicy.failClosed(proxy: "http://host.example:8080"), .isolated,
                       "hostname proxy fails closed until resolved to an IP")
        XCTAssertEqual(NetworkPolicy.failClosed(proxy: "garbage"), .isolated)
    }

    func testPolicyRunArgs() {
        XCTAssertEqual(NetworkPolicy.proxyOnly(allowCIDR: "10.0.0.9/32").runArgs,
                       ["--net-softnet", "--net-softnet-allow", "10.0.0.9/32"])
        XCTAssertEqual(NetworkPolicy.isolated.runArgs, ["--net-softnet", "--net-softnet-allow", "127.0.0.1/32"])
        XCTAssertEqual(NetworkPolicy.openNAT.runArgs, [])
    }
}

final class ProfilePlanTests: XCTestCase {
    func testCreateIsCloneFromBase() {
        let p = Profile(id: "i", name: "n", baseImage: "ghcr.io/x/base:latest")
        XCTAssertEqual(ProfilePlan.create(p), ["clone", "ghcr.io/x/base:latest", "pb-n-i"])
    }

    func testRunCarriesFailClosedNetworking() {
        let proxied = Profile(id: "i", name: "n", proxy: "socks5://10.0.0.9:1080")
        XCTAssertEqual(ProfilePlan.run(proxied, headless: true),
                       ["run", "pb-n-i", "--net-softnet", "--net-softnet-allow", "10.0.0.9/32", "--no-graphics"])
        let noProxy = Profile(id: "i", name: "n")
        XCTAssertEqual(ProfilePlan.run(noProxy),
                       ["run", "pb-n-i", "--net-softnet", "--net-softnet-allow", "127.0.0.1/32"])
    }

    func testSizeDeleteBackup() {
        let p = Profile(id: "i", name: "n")
        XCTAssertEqual(ProfilePlan.size(p, memoryMiB: 1536, cpu: 2),
                       ["set", "pb-n-i", "--memory", "1536", "--cpu", "2"])
        XCTAssertEqual(ProfilePlan.delete(vmName: p.vmName), ["delete", "pb-n-i"])
        XCTAssertEqual(ProfilePlan.backup(p, label: "before update 1!"), ["clone", "pb-n-i", "pb-n-i--before-update-1-"])
    }
}

final class CookieImportTests: XCTestCase {
    func testDetectFormat() {
        XCTAssertEqual(CookieImport.detectFormat("[{}]"), .json)
        XCTAssertEqual(CookieImport.detectFormat("  {\"cookies\":[]}"), .json)
        XCTAssertEqual(CookieImport.detectFormat("# Netscape HTTP Cookie File\n"), .netscape)
    }

    func testNetscape() {
        let text = """
        # Netscape HTTP Cookie File
        # a comment

        .example.com\tTRUE\t/\tTRUE\t2147483647\tsid\tabc123
        #HttpOnly_.example.com\tTRUE\t/app\tFALSE\t0\ttoken\txyz
        malformed line without tabs
        """
        let cookies = CookieImport.parseNetscape(text)
        XCTAssertEqual(cookies.count, 2, "comment, blank and malformed lines skipped")
        XCTAssertEqual(cookies[0], Cookie(domain: ".example.com", path: "/", name: "sid", value: "abc123",
                                          secure: true, httpOnly: false, expires: 2147483647))
        XCTAssertEqual(cookies[1], Cookie(domain: ".example.com", path: "/app", name: "token", value: "xyz",
                                          secure: false, httpOnly: true, expires: nil), "expiry 0 = session; HttpOnly_ prefix")
    }

    func testJSONArrayWithExtensionFields() throws {
        let text = """
        [{"domain":".example.com","name":"sid","value":"v","path":"/","secure":true,"httpOnly":true,
          "expirationDate":1999999999.5,"hostOnly":false}]
        """
        let cookies = try CookieImport.parse(text)
        XCTAssertEqual(cookies, [Cookie(domain: ".example.com", path: "/", name: "sid", value: "v",
                                        secure: true, httpOnly: true, expires: 1999999999)])
    }

    func testJSONWrapperAndMissingFieldsSkipped() throws {
        let text = #"{"cookies":[{"domain":"x.com","name":"a","value":"1"},{"name":"nodomain","value":"2"}]}"#
        let cookies = try CookieImport.parse(text)
        XCTAssertEqual(cookies.count, 1)
        XCTAssertEqual(cookies[0].domain, "x.com")
        XCTAssertEqual(cookies[0].path, "/", "default path")
    }

    func testBadJSONThrows() {
        XCTAssertThrowsError(try CookieImport.parse("{not json")) { XCTAssertEqual($0 as? CookieError, .badJSON) }
    }

    func testRoundTripSerialize() throws {
        let cookies = [Cookie(domain: "x.com", name: "a", value: "1")]
        let data = try CookieImport.serialize(cookies)
        XCTAssertEqual(try JSONDecoder().decode([Cookie].self, from: data), cookies)
    }
}
