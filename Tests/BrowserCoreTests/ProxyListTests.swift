import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import BrowserCore

final class ProxyListImportTests: XCTestCase {
    private func read(_ text: String, kind: ProxySettings.Kind = .socks5) -> ProxyListImport.Report {
        ProxyListImport.read(text, defaultKind: kind)
    }

    func testTheCommonFormats() {
        let report = read("""
            1.2.3.4:1080
            5.6.7.8:8000:alice:secret
            bob:pw@proxy.example.com:3128
            socks5://carol:c%40t@9.9.9.9:1081
            socks5h://tor.example:9050/
            socks://plain.example:1082
            http://dave:d@h.example:8080
            HTTPS://erin:e@tls.example:443
            [2001:db8::1]:1083
            """)
        XCTAssertEqual(report.problems, [])
        XCTAssertEqual(report.linesRead, 9)
        XCTAssertEqual(report.proxies.map(\.line), Array(1...9))
        XCTAssertEqual(report.proxies.map(\.proxy), [
            ProxySettings(kind: .socks5, host: "1.2.3.4", port: 1080),
            ProxySettings(kind: .socks5, host: "5.6.7.8", port: 8000, username: "alice", password: "secret"),
            ProxySettings(kind: .socks5, host: "proxy.example.com", port: 3128, username: "bob", password: "pw"),
            ProxySettings(kind: .socks5, host: "9.9.9.9", port: 1081, username: "carol", password: "c@t"),
            ProxySettings(kind: .socks5, host: "tor.example", port: 9050),
            ProxySettings(kind: .socks5, host: "plain.example", port: 1082),
            ProxySettings(kind: .httpConnect, host: "h.example", port: 8080, username: "dave", password: "d"),
            ProxySettings(kind: .httpConnect, host: "tls.example", port: 443, username: "erin", password: "e", tlsToProxy: true),
            ProxySettings(kind: .socks5, host: "2001:db8::1", port: 1083),
        ])
        XCTAssertTrue(report.proxies.allSatisfy { $0.label.isEmpty })
    }

    func testLinesWithoutASchemeTakeTheChosenKind() {
        let report = read("1.2.3.4:3128\nsocks5://1.2.3.4:1080\nh.example:80:u:p", kind: .httpConnect)
        XCTAssertEqual(report.proxies.map(\.proxy.kind), [.httpConnect, .socks5, .httpConnect])
        // Without https:// there is no TLS to the proxy, whatever the kind.
        XCTAssertEqual(report.proxies.map(\.proxy.tlsToProxy), [false, false, false])
    }

    func testCredentialsKeepWhatPasswordsHold() {
        let report = read("""
            user:p@ss@h.example:80
            u:p:w@h2.example:81
            h3.example:82:user:pa#ss
            h4.example:83:user:
            solo@h5.example:84
            """)
        XCTAssertEqual(report.problems, [])
        XCTAssertEqual(report.proxies.map { [$0.proxy.username, $0.proxy.password] }, [
            ["user", "p@ss"], ["u", "p:w"], ["user", "pa#ss"], ["user", ""], ["solo", ""],
        ])
        // Credentials always come in pairs, as ProxySettings.validate wants them.
        XCTAssertNoThrow(try report.proxies.forEach { try $0.proxy.validate() })
    }

    func testLabelsBlankLinesCommentsAndLineEndings() {
        let text = "\u{FEFF}# my provider\r\n\r\n  1.2.3.4:1080   # Berlin 1  \r\n// old ones\r\n\t5.6.7.8:1080\t\r\n"
            + "\u{200B}9.9.9.9:1080 #\n"
        let report = read(text)
        XCTAssertEqual(report.problems, [])
        XCTAssertEqual(report.linesRead, 3)
        XCTAssertEqual(report.proxies.map(\.line), [3, 5, 6])
        XCTAssertEqual(report.proxies.map(\.label), ["Berlin 1", "", ""])
        XCTAssertEqual(report.proxies.map(\.proxy.host), ["1.2.3.4", "5.6.7.8", "9.9.9.9"])
    }

    func testEveryUnreadableLineIsReportedWithItsLineAndReason() {
        let report = read("""
            1.2.3.4
            ftp://h.example:21
            h.example:99999
            h.example:port
            1.2.3.4 1080
            a:b:c
            @h.example:80
            300.1.1.1:80
            socks5://h.example:1080/path
            [2001:db8::1
            1.2.3.4:1080
            """)
        XCTAssertEqual(report.proxies.map(\.line), [11])
        XCTAssertEqual(report.problems.map(\.line), Array(1...10))
        XCTAssertEqual(report.problems.map(\.reason), [
            .missingPort,
            .unreadable(.unsupportedScheme("ftp")),
            .unreadable(.invalidPort("99999")),
            .unreadable(.invalidPort("port")),
            .unreadable(.containsWhitespace),
            .unreadable(.notAHost("a:b:c")),
            .unreadable(.emptyUserName),
            .unreadable(.invalidHost("300.1.1.1")),
            .unreadable(.hasPath),
            .unreadable(.unterminatedIPv6),
        ])
        XCTAssertEqual(report.problems[4].text, "1.2.3.4 1080")
        XCTAssertEqual(report.failures.count, 10)
    }

    func testTheSameProxyTwiceIsReadOnce() {
        // The same host (in any case), port and user name: the same proxy, whatever the scheme or
        // the password; another user name is another proxy.
        let report = read("""
            1.2.3.4:1080
            socks5://1.2.3.4:1080
            PROXY.example:80:u:p
            u:p@proxy.example:80
            proxy.example:80:other:p
            http://1.2.3.4:1080
            proxy.example:80:u:another-password
            """)
        XCTAssertEqual(report.proxies.map(\.line), [1, 3, 5])
        XCTAssertEqual(report.problems.map(\.reason), [.duplicate(ofLine: 1), .duplicate(ofLine: 3), .duplicate(ofLine: 1),
                                                       .duplicate(ofLine: 3)])
        // A repeat is not a failure: the proxy was read.
        XCTAssertEqual(report.failures, [])
    }

    func testAtMostTheListsLimitIsRead() {
        let lines = (0..<(ProxyListImport.maximumProxies + 2)).map { "10.\($0 / 65536 % 256).\($0 / 256 % 256).\($0 % 256):1080" }
        let report = read(lines.joined(separator: "\n"))
        XCTAssertEqual(report.proxies.count, ProxyListImport.maximumProxies)
        XCTAssertEqual(report.problems.map(\.reason), [.tooMany(ProxyListImport.maximumProxies)])
        XCTAssertEqual(report.problems.first?.line, ProxyListImport.maximumProxies + 1)
    }

    func testOneFieldReadsWhatProvidersSellAsOneLineOfAList() {
        func proxy(_ text: String) -> ProxyListImport.Line? {
            if case .proxy(let line) = ProxyListImport.readField(text) { return line }
            return nil
        }
        // The forms, as the editor's field takes them: the same proxy each time — the credentials
        // before or after the address, with ":" or "@".
        let expected = ProxySettings(kind: .socks5, host: "1.2.3.4", port: 1080, username: "alice", password: "s3cret")
        for text in ["1.2.3.4:1080:alice:s3cret", "alice:s3cret@1.2.3.4:1080", "socks5://alice:s3cret@1.2.3.4:1080",
                     " socks5://alice:s3cret@1.2.3.4:1080/\n", "1.2.3.4:1080@alice:s3cret", "alice:s3cret:1.2.3.4:1080",
                     "socks5://1.2.3.4:1080@alice:s3cret"] {
            XCTAssertEqual(proxy(text)?.proxy, expected, text)
        }
        XCTAssertEqual(proxy("1.2.3.4:1080")?.proxy, ProxySettings(kind: .socks5, host: "1.2.3.4", port: 1080))
        // The type comes from the scheme; without one it is not known (the placeholder is not a guess
        // the field acts on: `kindGiven` false), whatever the import's default would be.
        XCTAssertEqual(proxy("socks5://alice:s3cret@1.2.3.4:1080")?.kindGiven, true)
        XCTAssertEqual(proxy("http://h.example:3128")?.proxy.kind, .httpConnect)
        XCTAssertEqual(proxy("https://h.example:443")?.proxy.tlsToProxy, true)
        XCTAssertEqual(proxy("1.2.3.4:1080:alice:s3cret")?.kindGiven, false)
        XCTAssertEqual(proxy("alice:s3cret@1.2.3.4:1080")?.kindGiven, false)
        XCTAssertEqual(proxy("1.2.3.4:1080")?.kindGiven, false)
        // Nothing, a comment, not a proxy (with the import's reasons), and a list.
        XCTAssertEqual(ProxyListImport.readField(" \n"), .empty)
        XCTAssertEqual(ProxyListImport.readField("# my provider"), .empty)
        XCTAssertEqual(ProxyListImport.readField("1.2.3.4"), .problem(.missingPort))
        XCTAssertEqual(ProxyListImport.readField("h.example:99999"), .problem(.unreadable(.invalidPort("99999"))))
        XCTAssertEqual(ProxyListImport.readField("ftp://h.example:21"), .problem(.unreadable(.unsupportedScheme("ftp"))))
        XCTAssertEqual(ProxyListImport.readField("1.2.3.4 1080"), .problem(.unreadable(.containsWhitespace)))
        XCTAssertEqual(ProxyListImport.readField("1.2.3.4:1080\n5.6.7.8:1080"), .several(2))
        XCTAssertEqual(ProxyListImport.readField("# provider\n1.2.3.4:1080  # Berlin"),
                       .proxy(ProxyListImport.Line(line: 2, proxy: ProxySettings(kind: .socks5, host: "1.2.3.4", port: 1080),
                                                   label: "Berlin", kindGiven: false)))
    }

    func testALineWrittenForAProxyReadsBackAsThatProxy() {
        let proxies = [
            ProxySettings(kind: .socks5, host: "1.2.3.4", port: 1080),
            ProxySettings(kind: .socks5, host: "h.example", port: 1080, username: "u:s@r", password: "p#a%ss w:@"),
            ProxySettings(kind: .httpConnect, host: "h.example", port: 8080, username: "u", password: ""),
            ProxySettings(kind: .httpConnect, host: "tls.example", port: 443, username: "u", password: "p", tlsToProxy: true),
            ProxySettings(kind: .socks5, host: "2001:db8::1", port: 1083),
        ]
        for proxy in proxies {
            let line = ProxyListImport.line(for: proxy)
            guard case .proxy(let read) = ProxyListImport.readField(line) else { return XCTFail(line) }
            XCTAssertEqual(read.proxy, proxy, line)
            XCTAssertTrue(read.kindGiven, line)
        }
        XCTAssertEqual(ProxyListImport.line(for: proxies[3]), "https://u:p@tls.example:443")
        XCTAssertEqual(ProxyListImport.line(for: proxies[4]), "socks5://[2001:db8::1]:1083")
        // Without a known type there is no scheme, and the line reads back as not known.
        XCTAssertEqual(ProxyListImport.line(for: proxies[0], kindKnown: false), "1.2.3.4:1080")
        guard case .proxy(let unknown) = ProxyListImport.readField(ProxyListImport.line(for: proxies[1], kindKnown: false)) else {
            return XCTFail("no proxy")
        }
        XCTAssertFalse(unknown.kindGiven)
        XCTAssertEqual(unknown.proxy.password, "p#a%ss w:@")
        // The export writes the same lines.
        XCTAssertEqual(ProxyList.exportText([ProxyListEntry(label: "B", proxy: proxies[3])]),
                       "# Lumen proxies. The user names and passwords below are in plaintext.\nhttps://u:p@tls.example:443  # B\n")
    }

    func testThePasswordIsFoundWhereItWasWrittenToBeMasked() {
        func masked(_ text: String) -> String? {
            guard let range = ProxyListImport.passwordRange(in: text) else { return nil }
            var shown = text
            shown.replaceSubrange(range, with: "•••")
            return shown
        }
        XCTAssertEqual(masked("1.2.3.4:1080:alice:s3cret"), "1.2.3.4:1080:alice:•••")
        XCTAssertEqual(masked("alice:s3cret@1.2.3.4:1080"), "alice:•••@1.2.3.4:1080")
        XCTAssertEqual(masked("socks5://alice:s3:cr@t@1.2.3.4:1080"), "socks5://alice:•••@1.2.3.4:1080")
        XCTAssertEqual(masked("socks5://alice:p%40ss@1.2.3.4:1080"), "socks5://alice:•••@1.2.3.4:1080")
        XCTAssertEqual(masked("  \u{FEFF}h.example:80:u:pa#ss  # Berlin\n"), "  \u{FEFF}h.example:80:u:•••  # Berlin\n")
        XCTAssertEqual(masked("# provider\r\nu:pw@h.example:80"), "# provider\r\nu:•••@h.example:80")
        // The providers' other orders; a password that reads like the port is masked where it is.
        XCTAssertEqual(masked("1.2.3.4:1080@alice:s3cret"), "1.2.3.4:1080@alice:•••")
        XCTAssertEqual(masked("alice:s3cret:1.2.3.4:1080"), "alice:•••:1.2.3.4:1080")
        XCTAssertEqual(masked("198.51.100.4:3128@admin:3128"), "198.51.100.4:3128@admin:•••")
        // No password, an empty one, or not one proxy: nothing to mask.
        XCTAssertNil(ProxyListImport.passwordRange(in: "1.2.3.4:1080"))
        XCTAssertNil(ProxyListImport.passwordRange(in: "solo@h.example:80"))
        XCTAssertNil(ProxyListImport.passwordRange(in: "h.example:80:user:"))
        XCTAssertNil(ProxyListImport.passwordRange(in: "1.2.3.4:1080:a:b\n5.6.7.8:1080:c:d"))
        XCTAssertNil(ProxyListImport.passwordRange(in: "h.example:99999:u:p"))
    }

    func testTheHostFieldsThrownMessagesAreUnchanged() {
        XCTAssertThrowsError(try ProxyHostField.parse("h.example:99999")) { error in
            XCTAssertEqual(error as? CoreError, .invalidConfiguration("“99999” is not a port number (1–65535)"))
        }
        XCTAssertThrowsError(try ProxyHostField.parse("ftp://h")) { error in
            XCTAssertEqual(error as? CoreError, .invalidConfiguration("unsupported proxy scheme “ftp” (use socks5, http or https)"))
        }
        XCTAssertEqual(ProxyHostField.problem(in: " "), .empty)
        XCTAssertNil(ProxyHostField.problem(in: "1.2.3.4:1080"))
    }
}

final class ProxyListTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("pb-proxies-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func lines(_ text: String) -> [ProxyListImport.Line] {
        ProxyListImport.read(text).proxies
    }

    func testAddSkipsWhatTheListHasAndCleansLabels() {
        var list = ProxyList()
        let first = list.add(lines("1.2.3.4:1080 # \(String(repeating: "x", count: 80))\n5.6.7.8:1080:u:p"))
        XCTAssertEqual(first.added.count, 2)
        XCTAssertEqual(list.entries.map(\.label), [String(repeating: "x", count: 64), ""])
        XCTAssertEqual(list.entries.map(\.displayName), [String(repeating: "x", count: 64), "5.6.7.8:1080"])
        // The same host, port and user with another password is the proxy already listed.
        let second = list.add(lines("socks5://1.2.3.4:1080\n5.6.7.8:1080:u:other\n5.6.7.8:1080:v:p\n[::1]:9050"))
        XCTAssertEqual(second.alreadyListed, 2)
        XCTAssertEqual(second.added.count, 2)
        XCTAssertEqual(list.entries.map(\.address), ["1.2.3.4:1080", "5.6.7.8:1080", "5.6.7.8:1080", "[::1]:9050"])
        // A proxy that does not validate is never listed, however it got here.
        let invalid = ProxyListImport.Line(line: 1, proxy: ProxySettings(kind: .socks5, host: "1.2.3.4:80", port: 80))
        XCTAssertEqual(list.add([invalid]).added, [])
        XCTAssertEqual(list.entries.count, 4)
    }

    func testTheListHasALimit() {
        var list = ProxyList()
        let many = (0..<(ProxyList.maximumEntries + 3)).map { index in
            ProxyListImport.Line(line: index + 1, proxy: ProxySettings(kind: .socks5, host: "10.0.\(index / 256 % 256).\(index % 256)",
                                                                       port: 1000 + index / 65536))
        }
        let result = list.add(many)
        XCTAssertEqual(list.entries.count, ProxyList.maximumEntries)
        XCTAssertEqual(result.added.count, ProxyList.maximumEntries)
        XCTAssertEqual(result.overLimit, 3)
    }

    func testRenameRemoveAndRecord() throws {
        var list = ProxyList()
        let ids = list.add(lines("1.2.3.4:1080\n5.6.7.8:1080")).added
        list.rename(ids[0], to: "  Berlin\nsecond line ")
        XCTAssertEqual(list.entry(ids[0])?.label, "Berlin")
        let result = ProxyCheckResult.alive(location: ProxyLocation(timeZoneIdentifier: "Europe/Berlin", countryCode: "DE",
                                                                    proxyEndpoint: "x", exitIP: "203.0.113.7"),
                                            latency: 0.1234)
        list.record(result, for: ids[1])
        XCTAssertEqual(list.entry(ids[1])?.lastCheck, result)
        XCTAssertEqual(result.latencyMilliseconds, 123)
        XCTAssertEqual(result.exitIP, "203.0.113.7")
        list.remove([ids[1]])
        // A check that finishes after its proxy was removed does not bring it back.
        list.record(.dead(.noAnswer), for: ids[1])
        XCTAssertEqual(list.entries.map(\.id), [ids[0]])
    }

    func testCheckResults() {
        let proxy = ProxySettings(kind: .httpConnect, host: "h.example", port: 80, username: "u", password: "p")
        XCTAssertEqual(ProxyCheckResult.alive(location: nil, latency: 0.00001).latencyMilliseconds, 1)
        XCTAssertTrue(ProxyCheckResult.alive(location: nil, latency: nil).isAlive)
        XCTAssertNil(ProxyCheckResult.alive(location: nil, latency: 0.2).location(for: proxy))
        XCTAssertFalse(ProxyCheckResult.dead(.needsCredentials).isAlive)
        let time = Date(timeIntervalSince1970: 1_800_000_000)
        let found = ProxyCheckResult(checkedAt: time, exitIP: "198.51.100.4", countryCode: "JP", timeZoneIdentifier: "Asia/Tokyo",
                                     latencyMilliseconds: 80)
        XCTAssertEqual(found.location(for: proxy), ProxyLocation(timeZoneIdentifier: "Asia/Tokyo", countryCode: "JP",
                                                                 proxyEndpoint: ProxyLocation.endpoint(of: proxy),
                                                                 resolvedAt: time, exitIP: "198.51.100.4"))
        var dead = found
        dead.failure = .noAnswer
        XCTAssertNil(dead.location(for: proxy))
    }

    func testRotation() {
        var list = ProxyList()
        let ids = list.add(lines("1.1.1.1:1\n2.2.2.2:2")).added
        let profiles = (0..<5).map { _ in UUID() }
        let plan = ProxyList.rotation(of: list.entries, over: profiles)
        XCTAssertEqual(plan.map(\.profileID), profiles)
        XCTAssertEqual(plan.map(\.entry.id), [ids[0], ids[1], ids[0], ids[1], ids[0]])
        XCTAssertEqual(ProxyList.rotation(of: [list.entries[1]], over: profiles).map(\.entry.id), Array(repeating: ids[1], count: 5))
        XCTAssertEqual(ProxyList.rotation(of: [], over: profiles), [])
        XCTAssertEqual(ProxyList.rotation(of: list.entries, over: [profiles[0]]).map(\.entry.id), [ids[0]])
    }

    func testStoredEncryptedAtTheVaultRootAndOnlyThere() throws {
        let vault = try MasterVault.create(in: root, password: "pw", iterations: 1_000)
        XCTAssertEqual(try ProxyList.load(from: vault), ProxyList())
        var list = ProxyList()
        let ids = list.add(lines("socks5://alice:sup3r-secret@proxy-host.example:1080 # Label-Text"),
                           at: Date(timeIntervalSince1970: 1_790_000_000)).added
        list.record(ProxyCheckResult(checkedAt: Date(timeIntervalSince1970: 1_800_000_000), exitIP: "203.0.113.9",
                                     countryCode: "DE", timeZoneIdentifier: "Europe/Berlin", latencyMilliseconds: 42), for: ids[0])
        try list.save(to: vault)

        let file = root.appendingPathComponent("proxies.bin")
        let bytes = try Data(contentsOf: file)
        for secret in ["alice", "sup3r-secret", "proxy-host", "Label-Text", "203.0.113.9", "Europe"] {
            XCTAssertNil(bytes.range(of: Data(secret.utf8)), "\(secret) is readable on disk")
        }
        #if !os(Windows)
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)
        #endif

        let reopened = try MasterVault.unlock(in: root, password: "pw")
        XCTAssertEqual(try ProxyList.load(from: reopened), list)

        // Another vault's key, or the file moved in place of another document, does not open it.
        let otherRoot = root.appendingPathComponent("other")
        let other = try MasterVault.create(in: otherRoot, password: "pw", iterations: 1_000)
        try FileManager.default.copyItem(at: file, to: otherRoot.appendingPathComponent("proxies.bin"))
        XCTAssertThrowsError(try ProxyList.load(from: other))
        try FileManager.default.copyItem(at: file, to: root.appendingPathComponent("settings.bin"))
        XCTAssertThrowsError(try DeviceSettings.load(from: reopened))
    }

    func testAnEntryALaterBuildWroteDoesNotCostTheList() throws {
        let vault = try MasterVault.create(in: root, password: "pw", iterations: 1_000)
        let id = UUID()
        let json = """
            {"format": 1, "entries": [
              {"id": "\(UUID().uuidString)", "label": "future", "addedAt": "2026-01-01T00:00:00Z",
               "proxy": {"kind": "quic", "host": "h.example", "port": 1, "tlsToProxy": false, "excludedDomains": []}},
              {"id": "\(id.uuidString)", "label": "kept", "addedAt": "2026-01-01T00:00:00Z",
               "proxy": {"kind": "socks5", "host": "h.example", "port": 2, "tlsToProxy": false, "excludedDomains": []},
               "lastCheck": {"checkedAt": "2026-01-02T00:00:00Z", "failure": "somethingNew"}},
              42
            ]}
            """
        try SecureFile.write(AEAD.seal(Data(json.utf8), key: ProxyList.file(for: vault).key, aad: "proxy-list:v1:\(vault.vaultID.uuidString)"),
                             to: root.appendingPathComponent("proxies.bin"))
        let list = try ProxyList.load(from: vault)
        XCTAssertEqual(list.entries.map(\.id), [id])
        XCTAssertEqual(list.entries.first?.label, "kept")
        XCTAssertNil(list.entries.first?.lastCheck)

        try SecureFile.write(AEAD.seal(Data(#"{"format": 4, "entries": []}"#.utf8), key: ProxyList.file(for: vault).key,
                                       aad: "proxy-list:v1:\(vault.vaultID.uuidString)"),
                             to: root.appendingPathComponent("proxies.bin"))
        XCTAssertThrowsError(try ProxyList.load(from: vault)) { error in
            XCTAssertEqual(error as? CoreError, .newerFormat(what: "proxies.bin", found: 4, supported: 3))
        }
    }

    /// Where a proxy came from: the user, or PrivacyBrowser's service (which does not exist yet). A
    /// list of the user's own proxies is the file every version reads, as before; one with a
    /// service's proxy is format 2, which a version from before origins refuses rather than read it
    /// as the user's and write it back without its origin.
    func testWhereAProxyCameFrom() throws {
        // Whole seconds: the file keeps times to the second.
        let added = Date(timeIntervalSince1970: 1_790_000_000)
        var list = ProxyList()
        list.add(lines("socks5://u:p@a.example:1080\nb.example:3128"), at: added)
        XCTAssertTrue(list.takeIn(profileProxies: [ProxySettings(kind: .httpConnect, host: "c.example", port: 8080)], at: added).count == 1)
        XCTAssertEqual(list.entries.map(\.origin), [.user, .user, .user], "imported, pasted and taken in: the user's")

        func written(_ list: ProxyList) throws -> [String: Any] {
            try XCTUnwrap(JSONSerialization.jsonObject(with: JSONCoding.encoder.encode(list)) as? [String: Any])
        }
        var json = try written(list)
        XCTAssertEqual(json["format"] as? Int, 1)
        XCTAssertTrue((json["entries"] as? [[String: Any]])?.allSatisfy { $0["origin"] == nil } == true, "the user's: written as before")

        let given = ProxyListEntry(label: "From the service", proxy: ProxySettings(kind: .socks5, host: "s.example", port: 1080,
                                                                                    username: "svc", password: "x"),
                                   addedAt: added, origin: .service)
        var withService = ProxyList(entries: list.entries + [given])
        json = try written(withService)
        XCTAssertEqual(json["format"] as? Int, 2)
        XCTAssertEqual((json["entries"] as? [[String: Any]])?.map { $0["origin"] as? String }, [nil, nil, nil, "service"])

        // Kept through the vault, a check and an edit.
        let vault = try MasterVault.create(in: root, password: "pw", iterations: 1_000)
        withService.record(ProxyCheckResult(checkedAt: Date(timeIntervalSince1970: 1_800_000_000), exitIP: "203.0.113.9",
                                            countryCode: "DE", timeZoneIdentifier: "Europe/Berlin", latencyMilliseconds: 42), for: given.id)
        try withService.update(given.id, label: "Renamed", proxy: given.proxy)
        try withService.save(to: vault)
        let reopened = try ProxyList.load(from: vault)
        XCTAssertEqual(reopened, withService)
        XCTAssertEqual(reopened.entry(given.id)?.origin, .service)
        XCTAssertEqual(reopened.entries.filter { $0.origin == .user }.count, 3)

        // A file from before origins, of this version's format 1 or a service's 2: read as written.
        let before = #"{"format": 1, "entries": [{"id": "\#(UUID().uuidString)", "addedAt": "2026-01-01T00:00:00Z", "#
            + #""proxy": {"kind": "socks5", "host": "h.example", "port": 2, "tlsToProxy": false, "excludedDomains": []}}]}"#
        XCTAssertEqual(try JSONCoding.decoder.decode(ProxyList.self, from: Data(before.utf8)).entries.map(\.origin), [.user])
        // Removing the service's proxy makes it the file every version reads again.
        withService.remove([given.id])
        XCTAssertEqual(try written(withService)["format"] as? Int, 1)
    }

    /// A mobile proxy's IP-change link: read from an import line, kept through the vault, written
    /// back by the export as it was read — and the list is format 3 while one is set, so that a
    /// version from before links refuses it rather than write it back without them (R4).
    func testAnIPChangeLinkIsReadKeptAndExportedAndRaisesTheFormat() throws {
        let link = "https://changeip.example/api/v1/reboot?key=abc123&port=8001"
        let report = ProxyListImport.read("""
            socks5://u:p@m.example:8001[\(link)]  # Mobile 1
            http://u:p@n.example:3128
            [2001:db8::1]:1080
            o.example:9000:user:pass[http://ip.example/change?t=1]
            """)
        XCTAssertTrue(report.problems.isEmpty, "\(report.problems)")
        XCTAssertEqual(report.proxies.map(\.changeIPURL?.absoluteString), [link, nil, nil, "http://ip.example/change?t=1"])
        XCTAssertEqual(report.proxies.first?.label, "Mobile 1")
        XCTAssertEqual(report.proxies.first?.proxy.host, "m.example")
        XCTAssertEqual(report.proxies[2].proxy.host, "2001:db8::1", "an IPv6 host's brackets are not a link")
        XCTAssertEqual(report.proxies[3].proxy.username, "user")

        // A bracket that is not a link leaves the line unreadable rather than drop it quietly.
        XCTAssertEqual(ProxyListImport.read("socks5://h.example:1080[ftp://x.example/]").proxies.count, 0)
        XCTAssertEqual(ProxyListImport.read("socks5://h.example:1080[https://]").proxies.count, 0)

        var list = ProxyList()
        // Whole seconds: the file keeps times to the second.
        list.add(report.proxies, at: Date(timeIntervalSince1970: 1_790_000_000))
        let mobile = try XCTUnwrap(list.entries.first)
        XCTAssertEqual(mobile.changeIPURL?.absoluteString, link)
        XCTAssertFalse(mobile.changesIPOnLaunch)
        XCTAssertEqual(list.format, 3)

        try list.setIPChange(mobile.id, link: mobile.changeIPURL, onLaunch: true)
        XCTAssertTrue(list.entry(mobile.id)?.changesIPOnLaunch == true)
        let other = list.entries[1]
        try list.setIPChange(other.id, link: nil, onLaunch: true)
        XCTAssertEqual(list.entry(other.id)?.changesIPOnLaunch, false, "no link, nothing to change at launch")
        XCTAssertThrowsError(try list.setIPChange(UUID(), link: nil, onLaunch: false))

        let vault = try MasterVault.create(in: root, password: "pw", iterations: 1_000)
        try list.save(to: vault)
        let reopened = try ProxyList.load(from: vault)
        XCTAssertEqual(reopened, list)
        let onDisk = try Data(contentsOf: vault.root.appendingPathComponent("proxies.bin"))
        XCTAssertNil(onDisk.range(of: Data("abc123".utf8)), "the provider's key is encrypted with the list")

        let exported = ProxyList.exportText(list.entries)
        XCTAssertTrue(exported.contains("socks5://u:p@m.example:8001[\(link)]  # Mobile 1"), exported)
        XCTAssertEqual(ProxyListImport.read(exported).proxies.map(\.changeIPURL), report.proxies.map(\.changeIPURL))

        // Without any link the list is written as before.
        try list.setIPChange(mobile.id, link: nil, onLaunch: false)
        try list.setIPChange(list.entries[3].id, link: nil, onLaunch: false)
        XCTAssertEqual(list.format, 1)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONCoding.encoder.encode(list)) as? [String: Any])
        XCTAssertTrue((json["entries"] as? [[String: Any]])?.allSatisfy { $0["changeIPURL"] == nil && $0["changesIPOnLaunch"] == nil } == true)
    }
}

final class ProxyIPChangeTests: XCTestCase {
    func testOnlyAnHTTPLinkWithAHostIsALink() {
        XCTAssertEqual(ProxyIPChange.link(from: "  https://a.example/x?k=1 ")?.absoluteString, "https://a.example/x?k=1")
        // A provider's own modem server: http to its public address and port.
        XCTAssertNotNil(ProxyIPChange.link(from: "http://203.0.113.10:7001/apix/reset_me?arg=1"))
        XCTAssertNotNil(ProxyIPChange.link(from: "https://[2001:db8::7]/change?key=1"))
        for bad in ["", "a.example/x", "ftp://a.example/", "https://", "https://u:p@a.example/", "https://a.example/x y",
                    "javascript:alert(1)", "https://" + String(repeating: "a", count: 2100) + ".example/"] {
            XCTAssertNil(ProxyIPChange.link(from: bad), bad)
        }
    }

    /// The link is opened from this Mac's own connection: never to this Mac or its network.
    func testALinkToThisMacOrItsNetworkIsNotALink() {
        for local in ["http://10.0.0.1:8080/change", "http://127.0.0.1/x", "https://localhost/x", "https://LOCALHOST./x",
                      "http://app.localhost/x", "http://modem.local/reboot", "http://router.home.arpa/x", "http://box.lan/x",
                      "http://svc.internal/x", "http://router/reboot", "http://192.168.1.1/reboot", "http://172.16.0.1/x",
                      "http://172.31.255.254/x", "http://169.254.169.254/latest", "http://100.64.0.1/x", "http://0.0.0.0/x",
                      "http://224.0.0.1/x", "http://255.255.255.255/x", "http://127.1/x", "http://0x7f.0.0.1/x",
                      "http://2130706433/x", "http://017.0.0.1/x", "http://1.2.3.4.5/x", "http://[::1]/x", "http://[::]/x",
                      "http://[fe80::1]/x", "http://[fd00::1]/x", "http://[::ffff:127.0.0.1]/x", "http://[ff02::1]/x",
                      "http://[64:ff9b::7f00:1]/x"] {
            XCTAssertNil(ProxyIPChange.link(from: local), local)
        }
        for host in ["changeip.example", "api.provider.example.", "8.8.8.8", "172.32.0.1", "192.169.0.1", "100.128.0.1",
                     "[2a00:1450::1]", "2606:4700::1111"] {
            XCTAssertTrue(ProxyIPChange.isInternetHost(host), host)
        }
        // An import line whose link is local is unreadable rather than kept without it.
        XCTAssertEqual(ProxyListImport.read("socks5://u:p@m.example:8001[http://192.168.0.1/reboot]").proxies.count, 0)
    }

    /// A link saved before the rule on hosts — to the local network — is the person's: the list
    /// reads it and writes it back as it is, and it is not opened.
    func testAStoredLocalLinkIsKeptButNotOpened() throws {
        let local = "http://192.168.1.1/reboot?key=abc"
        let proxy = ProxySettings(kind: .socks5, host: "m.example", port: 8001)
        let entry = ProxyListEntry(proxy: proxy, changeIPURL: URL(string: local), changesIPOnLaunch: true)
        let decoded = try JSONCoding.decoder.decode(ProxyListEntry.self, from: JSONCoding.encoder.encode(entry))
        XCTAssertEqual(decoded.changeIPURL?.absoluteString, local, "kept, not dropped on load")
        XCTAssertTrue(decoded.changesIPOnLaunch)
        XCTAssertEqual(try JSONCoding.decoder.decode(ProxyListEntry.self, from: JSONCoding.encoder.encode(decoded)), decoded)
        XCTAssertNotNil(ProxyIPChange.storedLink(from: local))
        XCTAssertNil(ProxyIPChange.link(from: local), "not taken when entered or edited")
        XCTAssertFalse(ProxyIPChange.mayOpen(try XCTUnwrap(decoded.changeIPURL)), "not opened")
        XCTAssertTrue(ProxyIPChange.mayOpen(try XCTUnwrap(URL(string: "https://changeip.example/x?key=1"))))
        // What the stored rule never took is still not taken.
        XCTAssertNil(ProxyIPChange.storedLink(from: "ftp://a.example/"))
        XCTAssertNil(ProxyIPChange.storedLink(from: "https://u:p@a.example/"))
    }

    /// A redirect is followed on the link's own host only, and never from https to http.
    func testARedirectIsFollowedOnTheSameHostOnly() throws {
        let link = try XCTUnwrap(URL(string: "https://changeip.example/api?key=1"))
        XCTAssertTrue(ProxyIPChange.mayFollowRedirect(from: link, to: try XCTUnwrap(URL(string: "https://changeip.example/api/v2?key=1"))))
        XCTAssertTrue(ProxyIPChange.mayFollowRedirect(from: link, to: try XCTUnwrap(URL(string: "https://CHANGEIP.example:8443/x"))))
        for other in ["https://elsewhere.example/api?key=1", "http://changeip.example/api?key=1", "https://127.0.0.1/x",
                      "http://192.168.1.1/reboot", "https://changeip.example.attacker.example/x"] {
            XCTAssertFalse(ProxyIPChange.mayFollowRedirect(from: link, to: try XCTUnwrap(URL(string: other))), other)
        }
        let plain = try XCTUnwrap(URL(string: "http://203.0.113.10:7001/reset"))
        XCTAssertTrue(ProxyIPChange.mayFollowRedirect(from: plain, to: try XCTUnwrap(URL(string: "https://203.0.113.10/reset"))))
    }

    func testTheRequestCarriesNothingOfTheApp() throws {
        let request = ProxyIPChange.request(for: try XCTUnwrap(URL(string: "https://a.example/x?k=1")))
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertFalse(request.httpShouldHandleCookies)
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "Lumen")
        XCTAssertEqual(request.timeoutInterval, ProxyIPChange.timeout)
    }

    func testTheProvidersAnswerIsReadAsItsAPIsSayIt() {
        func answer(_ status: Int, _ body: String) -> ProxyIPChange.Answer { ProxyIPChange.answer(status: status, body: Data(body.utf8)) }
        XCTAssertEqual(answer(200, #"{"status":"OK","new_ip":"1.2.3.4"}"#), .accepted(message: "OK"))
        XCTAssertEqual(answer(200, "IP changed"), .accepted(message: "IP changed"))
        XCTAssertEqual(answer(204, ""), .accepted(message: nil))
        XCTAssertEqual(answer(200, #"{"success":true,"error":null}"#), .accepted(message: nil))
        XCTAssertEqual(answer(200, #"{"status":"error","message":"Wait 60 seconds"}"#), .refused(status: 200, message: "Wait 60 seconds"))
        XCTAssertEqual(answer(200, #"{"success":false,"msg":"bad key"}"#), .refused(status: 200, message: "bad key"))
        XCTAssertEqual(answer(200, #"{"ok":false}"#), .refused(status: 200, message: nil))
        XCTAssertEqual(answer(200, #"{"error":"too often"}"#), .refused(status: 200, message: "too often"))
        XCTAssertEqual(answer(200, "Error: modem busy"), .refused(status: 200, message: "Error: modem busy"))
        XCTAssertEqual(answer(429, "slow down"), .refused(status: 429, message: "slow down"))
        XCTAssertEqual(answer(502, "<html><body>Bad gateway</body></html>"), .refused(status: 502, message: nil))
        // Shown as one short line.
        if case .accepted(let message?) = answer(200, String(repeating: "word ", count: 100) + "\n\u{7}") {
            XCTAssertLessThanOrEqual(message.count, 160)
            XCTAssertFalse(message.contains("\n"))
        } else {
            XCTFail("a long answer is still an answer")
        }
    }

    func testALaunchChangesTheIPOnlyWhenNoOtherRunningProfileIsOnTheProxy() {
        let proxy = ProxySettings(kind: .socks5, host: "m.example", port: 8001, username: "u", password: "p")
        var entry = ProxyListEntry(proxy: proxy, changeIPURL: URL(string: "https://a.example/x"), changesIPOnLaunch: true)
        XCTAssertTrue(ProxyIPChange.mayChange(entry, runningProxies: []))
        XCTAssertTrue(ProxyIPChange.mayChange(entry, runningProxies: [ProxyList.identity(of: ProxySettings(kind: .socks5, host: "o.example", port: 1))]))
        XCTAssertFalse(ProxyIPChange.mayChange(entry, runningProxies: [ProxyList.identity(of: proxy)]), "another profile is on it")
        entry.changesIPOnLaunch = false
        XCTAssertFalse(ProxyIPChange.mayChange(entry, runningProxies: []))
        entry.changesIPOnLaunch = true
        entry.changeIPURL = nil
        XCTAssertFalse(ProxyIPChange.mayChange(entry, runningProxies: []))
    }
}

final class ProxyAssignmentTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("pb-assign-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private let old = ProxySettings(kind: .socks5, host: "old.example", port: 1080)
    private let new = ProxySettings(kind: .httpConnect, host: "new.example", port: 3128, username: "u", password: "p")
    private let edited = Date(timeIntervalSince1970: 1_700_000_000)
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let checked = ProxyCheckResult(checkedAt: Date(timeIntervalSince1970: 1_790_000_000), exitIP: "198.51.100.4",
                                           countryCode: "JP", timeZoneIdentifier: "Asia/Tokyo", latencyMilliseconds: 90)

    private func configuration(warn: Bool = false) -> ProfileConfiguration {
        ProfileConfiguration(proxy: old,
                             lastProxyLocation: ProxyLocation(timeZoneIdentifier: "Europe/Berlin", countryCode: "DE",
                                                              proxyEndpoint: ProxyLocation.endpoint(of: old), exitIP: "203.0.113.7"),
                             warnOnProxyIPChange: warn, passwordNeverSaveSites: ["https://bank.example"], settingsModifiedAt: edited)
    }

    func testAnotherProxyReplacesWhatWasRememberedAboutTheOldOne() {
        let stored = configuration()
        let assigned = stored.assigning(new, check: checked, at: now)
        XCTAssertEqual(assigned.proxy, new)
        XCTAssertEqual(assigned.settingsModifiedAt, now)
        XCTAssertEqual(assigned.passwordNeverSaveSites, ["https://bank.example"])
        // The check's location, for the new proxy; its exit IP only while the warning asks for it.
        XCTAssertEqual(assigned.rememberedProxyLocation?.timeZoneIdentifier, "Asia/Tokyo")
        XCTAssertEqual(assigned.rememberedProxyLocation?.countryCode, "JP")
        XCTAssertNil(assigned.lastProxyLocation?.exitIP)
        XCTAssertEqual(configuration(warn: true).assigning(new, check: checked, at: now).lastProxyLocation?.exitIP, "198.51.100.4")
        // Without a check that found a location, nothing is remembered at all — nothing of the old proxy either.
        XCTAssertNil(stored.assigning(new, at: now).lastProxyLocation)
        XCTAssertNil(stored.assigning(new, check: .dead(.noAnswer), at: now).lastProxyLocation)
        // Everything else is the profile's own and stays.
        var unchanged = assigned
        unchanged.proxy = stored.proxy
        unchanged.lastProxyLocation = stored.lastProxyLocation
        unchanged.settingsModifiedAt = stored.settingsModifiedAt
        XCTAssertEqual(unchanged, stored)
    }

    func testTheSameProxyIsNoEdit() {
        let stored = configuration(warn: true)
        let again = stored.assigning(old, check: checked, at: now)
        XCTAssertEqual(again, stored)
        // The same endpoint with another bypass list is an edit, but about the same proxy: what was
        // found through it stays.
        var bypassing = old
        bypassing.excludedDomains = ["intranet.example"]
        let edit = stored.assigning(bypassing, check: checked, at: now)
        XCTAssertEqual(edit.settingsModifiedAt, now)
        XCTAssertEqual(edit.lastProxyLocation, stored.lastProxyLocation)
    }

    func testAssigningThroughTheRepository() throws {
        let repository = try ProfileRepository(vault: MasterVault.create(in: root, password: "pw", iterations: 1_000))
        let a = try repository.create(name: "A", configuration: configuration())
        let b = try repository.create(name: "B", configuration: ProfileConfiguration())
        let c = try repository.create(name: "C", configuration: ProfileConfiguration(proxy: new))
        var list = ProxyList()
        let ids = list.add(ProxyListImport.read("socks5://n1.example:1\nhttp://u:p@new.example:3128").proxies).added
        list.record(checked, for: ids[0])
        let missing = UUID()
        // a and b get the first proxy, c the second, which it already has.
        let plan = ProxyList.rotation(of: list.entries, over: [a.id, c.id, b.id, missing])
        let outcome = repository.assign(plan, at: now)
        XCTAssertEqual(outcome.changed, [a.id, b.id])
        XCTAssertEqual(outcome.unchanged, [c.id])
        XCTAssertEqual(Array(outcome.failed.keys), [missing])

        let savedA = try repository.loadConfiguration(a.id)
        XCTAssertEqual(savedA.proxy, list.entries[0].proxy)
        XCTAssertEqual(savedA.rememberedProxyLocation?.countryCode, "JP")
        XCTAssertEqual(savedA.passwordNeverSaveSites, ["https://bank.example"])
        XCTAssertEqual(try repository.loadConfiguration(b.id).proxy, list.entries[0].proxy)
        XCTAssertEqual(try repository.loadConfiguration(c.id).proxy, new)
        // Changed profiles are newer for sync; the one that already had its proxy is not.
        XCTAssertEqual(try repository.summary(for: a.id).revision, 2)
        XCTAssertEqual(try repository.summary(for: c.id).revision, 1)
    }
}

final class ProxyUDPLabelTests: XCTestCase {
    /// Three things said, each from what the check really found; nothing for a dead proxy or one
    /// whose UDP was not tried.
    func testTheLabelFollowsWhatTheCheckFound() {
        let expected: [ProxyUDPSupport: ProxyUDPLabel] = [
            .supported: .supported, .unsupported: .unsupported, .elsewhere: .unsupported,
            .unknown: .unchecked, .exitUnknown: .unchecked,
        ]
        for udp in ProxyUDPSupport.allCases {
            var alive = ProxyCheckResult.alive(location: nil, latency: 0.1)
            alive.udp = udp
            XCTAssertEqual(alive.udpLabel, expected[udp], "\(udp)")
            var dead = ProxyCheckResult.dead(.noAnswer)
            dead.udp = udp
            XCTAssertNil(dead.udpLabel, "a dead proxy says nothing of its UDP: \(udp)")
        }
        XCTAssertNil(ProxyCheckResult.alive(location: nil, latency: 0.1).udpLabel, "not tried: nothing said")
        XCTAssertEqual(Set(expected.values), Set(ProxyUDPLabel.allCases))
    }

    /// A check kept by a build before this one reads back without the UDP; one with it keeps it.
    func testAKeptCheckReadsWithAndWithoutTheUDP() throws {
        var result = ProxyCheckResult.alive(location: nil, latency: 0.2, at: Date(timeIntervalSince1970: 1_800_000_000))
        let old = try JSONEncoder().encode(result)
        XCTAssertFalse(String(decoding: old, as: UTF8.self).contains("udp"))
        XCTAssertNil(try JSONDecoder().decode(ProxyCheckResult.self, from: old).udp)
        result.udp = .unsupported
        let new = try JSONEncoder().encode(result)
        XCTAssertEqual(try JSONDecoder().decode(ProxyCheckResult.self, from: new).udp, .unsupported)
    }
}
