import XCTest
@testable import BrowserCore

/// A share link as a profile's proxy (`ProxySettings.Kind.xray`): the relay's configuration
/// (`XrayConfig`), the routes to running relays (`ProxyRoutes`), and how such a proxy is stored,
/// listed, imported, exported and kept from versions that cannot read it.
final class XrayLinkProxyTests: XCTestCase {
    static let uuid = ShareLinkTests.uuid
    static let reality = "vless://\(ShareLinkTests.uuid)@nl1.example.com:443?encryption=none&flow=xtls-rprx-vision&security=reality"
        + "&sni=www.microsoft.com&fp=chrome&pbk=\(ShareLinkTests.pbk)&sid=6ba85179e30d4fc2&spx=%2F&type=tcp#NL-1"
    static let inbound = XrayConfig.Inbound(port: 40123, username: "user-a", password: "pass-a")

    private func json(_ object: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
    }

    // MARK: The relay's configuration

    func testOneWayInWithALoginAndOneWayOut() throws {
        let link = try ShareLink.parse(Self.reality)
        let config = try XrayConfig.object(for: link, inbound: Self.inbound)
        XCTAssertEqual(Set(config.keys), ["log", "inbounds", "outbounds", "routing"], "no DNS, API, stats or observatory")
        let log = try XCTUnwrap(config["log"] as? [String: Any])
        XCTAssertEqual(log["access"] as? String, "none", "the hosts a profile visits are never written")
        XCTAssertEqual(log["loglevel"] as? String, "error")

        let inbounds = try XCTUnwrap(config["inbounds"] as? [[String: Any]])
        XCTAssertEqual(inbounds.count, 1)
        let socks = inbounds[0]
        XCTAssertEqual(socks["protocol"] as? String, "socks")
        XCTAssertEqual(socks["listen"] as? String, "127.0.0.1")
        XCTAssertEqual(socks["port"] as? Int, 40123)
        let settings = try XCTUnwrap(socks["settings"] as? [String: Any])
        XCTAssertEqual(settings["auth"] as? String, "password")
        XCTAssertEqual(settings["udp"] as? Bool, true)
        XCTAssertEqual(settings["ip"] as? String, "127.0.0.1")
        let accounts = try XCTUnwrap(settings["accounts"] as? [[String: String]])
        XCTAssertEqual(accounts, [["user": "user-a", "pass": "pass-a"]])
        XCTAssertEqual((socks["sniffing"] as? [String: Any])?["enabled"] as? Bool, false, "host names pass as they came")

        let outbounds = try XCTUnwrap(config["outbounds"] as? [[String: Any]])
        XCTAssertEqual(outbounds.count, 1, "the link's server is the only way out")
        let out = outbounds[0]
        XCTAssertEqual(out["protocol"] as? String, "vless")
        let outSettings = try XCTUnwrap(out["settings"] as? [String: Any])
        XCTAssertEqual(outSettings["address"] as? String, "nl1.example.com")
        XCTAssertEqual(outSettings["port"] as? Int, 443)
        XCTAssertEqual(outSettings["id"] as? String, Self.uuid)
        XCTAssertEqual(outSettings["flow"] as? String, "xtls-rprx-vision")
        XCTAssertEqual(outSettings["encryption"] as? String, "none")
        let stream = try XCTUnwrap(out["streamSettings"] as? [String: Any])
        XCTAssertEqual(stream["network"] as? String, "raw")
        XCTAssertEqual(stream["security"] as? String, "reality")
        XCTAssertNil(stream["sockopt"])
        XCTAssertNil(stream["address"], "no second destination in the stream")
        let reality = try XCTUnwrap(stream["realitySettings"] as? [String: Any])
        XCTAssertEqual(reality["serverName"] as? String, "www.microsoft.com")
        XCTAssertEqual(reality["publicKey"] as? String, ShareLinkTests.pbk)
        XCTAssertEqual(reality["shortId"] as? String, "6ba85179e30d4fc2")
        XCTAssertEqual(reality["fingerprint"] as? String, "chrome")
        XCTAssertEqual(reality["spiderX"] as? String, "/")

        let routing = try XCTUnwrap(config["routing"] as? [String: Any])
        XCTAssertEqual(routing["domainStrategy"] as? String, "AsIs", "nothing resolved to route by")
        let text = json(config)
        for absent in ["freedom", "blackhole", "\"dns\"", "dokodemo", "api", "fakedns", "downloadSettings", "extra", "allowInsecure"] {
            XCTAssertFalse(text.contains(absent), absent)
        }
    }

    func testEveryProtocolAndTransportBuilds() throws {
        let key = Data(repeating: 9, count: 32).base64EncodedString().addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        let links = [
            Self.reality,
            "vless://\(Self.uuid)@a.example:443?security=tls&type=ws&path=%2Fws&host=a.example&sni=a.example&fp=chrome&alpn=http%2F1.1",
            "vless://\(Self.uuid)@a.example:443?security=tls&type=grpc&serviceName=svc&mode=multi&authority=a.example",
            "vless://\(Self.uuid)@a.example:443?security=reality&type=xhttp&path=%2Fx&mode=packet-up&sni=b.example&pbk=\(ShareLinkTests.pbk)",
            "vless://\(Self.uuid)@a.example:80?type=httpupgrade&path=%2Fu&host=a.example",
            "vless://\(Self.uuid)@a.example:80?type=tcp&headerType=http&host=a.example&path=%2F",
            ShareLinkTests.vmess(["add": "v.example", "port": "443", "id": Self.uuid, "aid": "0", "net": "ws", "path": "/v", "tls": "tls"]),
            "trojan://secret@t.example:443?sni=t.example#T",
            "ss://\(ShareLinkTests.base64("aes-128-gcm:pw", urlSafe: true, padded: false))@s.example:8388#S",
            "ss://2022-blake3-chacha20-poly1305:\(key)@s.example:8388",
        ]
        let expected: [(String, String, String)] = [
            ("vless", "raw", "reality"), ("vless", "ws", "tls"), ("vless", "grpc", "tls"), ("vless", "xhttp", "reality"),
            ("vless", "httpupgrade", "none"), ("vless", "raw", "none"), ("vmess", "ws", "tls"), ("trojan", "raw", "tls"),
            ("shadowsocks", "raw", "none"), ("shadowsocks", "raw", "none"),
        ]
        for (text, (protocolName, network, security)) in zip(links, expected) {
            let link = try ShareLink.parse(text)
            let config = try XrayConfig.object(for: link, inbound: Self.inbound)
            let out = try XCTUnwrap((config["outbounds"] as? [[String: Any]])?.first, text)
            XCTAssertEqual(out["protocol"] as? String, protocolName, text)
            let stream = try XCTUnwrap(out["streamSettings"] as? [String: Any])
            XCTAssertEqual(stream["network"] as? String, network, text)
            XCTAssertEqual(stream["security"] as? String, security, text)
            XCTAssertNoThrow(try XrayConfig.json(for: link, inbound: Self.inbound))
        }
        // gRPC's settings, and the header of RAW with HTTP obfuscation.
        let grpc = try XrayConfig.streamSettings(for: ShareLink.parse(links[2]))
        XCTAssertEqual((grpc["grpcSettings"] as? [String: Any])?["serviceName"] as? String, "svc")
        XCTAssertEqual((grpc["grpcSettings"] as? [String: Any])?["multiMode"] as? Bool, true)
        let header = try XrayConfig.streamSettings(for: ShareLink.parse(links[5]))
        XCTAssertTrue(json(header).contains("\"type\":\"http\""))
    }

    func testEachLaunchHasItsOwnLogin() {
        let first = XrayConfig.Inbound.random(port: 1)
        let second = XrayConfig.Inbound.random(port: 1)
        XCTAssertEqual(first.username.count, 32)
        XCTAssertEqual(first.password.count, 32)
        XCTAssertTrue(first.password.allSatisfy(\.isHexDigit))
        XCTAssertNotEqual(first.username, second.username)
        XCTAssertNotEqual(first.password, second.password)
        XCTAssertNotEqual(first.username, first.password)
    }

    func testAConfigurationIsRefusedForABadLocalSide() throws {
        let link = try ShareLink.parse(Self.reality)
        XCTAssertThrowsError(try XrayConfig.object(for: link, inbound: XrayConfig.Inbound(port: 0, username: "u", password: "p")))
        XCTAssertThrowsError(try XrayConfig.object(for: link, inbound: XrayConfig.Inbound(port: 1, username: "", password: "p")))
    }

    // MARK: The proxy

    func testALinksProxyValidatesOnlyAsTheLinkSays() throws {
        let proxy = try ProxySettings(shareLink: "  " + Self.reality + "\n")
        XCTAssertEqual(proxy.kind, .xray)
        XCTAssertEqual(proxy.host, "nl1.example.com")
        XCTAssertEqual(proxy.port, 443)
        XCTAssertEqual(proxy.link, Self.reality, "kept as pasted, without what the paste brought around it")
        XCTAssertNil(proxy.username)
        XCTAssertNoThrow(try proxy.validate())
        XCTAssertEqual(proxy.shareLink?.scheme, .vless)
        XCTAssertEqual(proxy.redactedAddress, "VLESS nl1.example.com:443")
        XCTAssertTrue(proxy.carriesUDP)

        var otherServer = proxy
        otherServer.host = "elsewhere.example"
        XCTAssertThrowsError(try otherServer.validate())
        var noLink = proxy
        noLink.link = nil
        XCTAssertThrowsError(try noLink.validate())
        var broken = proxy
        broken.link = "vless://nothing"
        XCTAssertThrowsError(try broken.validate())
        var credentials = proxy
        credentials.username = "u"
        credentials.password = "p"
        XCTAssertThrowsError(try credentials.validate())
        var socksWithLink = ProxySettings(kind: .socks5, host: "1.2.3.4", port: 1080)
        socksWithLink.link = Self.reality
        XCTAssertThrowsError(try socksWithLink.validate())
        XCTAssertThrowsError(try ProxySettings(shareLink: "vless://\(Self.uuid)@a.example:443?type=h2"))
    }

    func testTheSettingsOfAProfileWithALinkAreFormatTwoAndOthersAsBefore() throws {
        var configuration = ProfileConfiguration()
        configuration.proxy = try ProxySettings(shareLink: Self.reality)
        let data = try JSONCoding.encoder.encode(configuration)
        XCTAssertEqual(DocumentFormat.declared(in: data), 2)
        // A version that reads format 1 refuses the file as a newer version's (R2).
        XCTAssertThrowsError(try DocumentFormat.check(data, supported: 1, what: "config.bin")) { error in
            guard case CoreError.newerFormat = error else { return XCTFail("\(error)") }
        }
        let read = try ProfileRepository.decodeConfiguration(data)
        XCTAssertEqual(read.proxy, configuration.proxy)

        configuration.proxy = ProxySettings(kind: .socks5, host: "1.2.3.4", port: 1080)
        let plain = try JSONCoding.encoder.encode(configuration)
        XCTAssertFalse(String(decoding: plain, as: UTF8.self).contains("\"format\""), "written as before")
        XCTAssertFalse(String(decoding: plain, as: UTF8.self).contains("\"link\""))
    }

    func testAProfileWithALinkIsSavedAndReadBack() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("xray-link-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try ProfileRepository(vault: MasterVault.create(in: root, password: "pw", iterations: 1_000))
        let proxy = try ProxySettings(shareLink: Self.reality)
        let summary = try repository.create(name: "Linked", configuration: ProfileConfiguration(proxy: proxy))
        XCTAssertEqual(try repository.loadConfiguration(summary.id).proxy, proxy)
        // On disk it is sealed: neither the id nor the server is there in clear.
        let sealed = try Data(contentsOf: root.appendingPathComponent("profiles/\(summary.id.uuidString)/config.bin"))
        XCTAssertNil(sealed.range(of: Data(Self.uuid.utf8)))
        XCTAssertNil(sealed.range(of: Data("nl1.example.com".utf8)))
    }

    func testTheExportOfAProfileWithALinkIsFormatFour() throws {
        var configuration = ProfileConfiguration()
        let documents = ProfileTransfer.Documents(passwords: [], history: nil, bookmarks: nil, warmUpPlan: nil)
        XCTAssertEqual(ProfileTransfer.exportFormat(configuration: configuration, documents: documents), 2)
        configuration.proxy = try ProxySettings(shareLink: Self.reality)
        XCTAssertEqual(ProfileTransfer.exportFormat(configuration: configuration, documents: documents), 4)
        XCTAssertEqual(ProfileTransfer.format, 4)
    }

    func testWhereALinkExitsIsKeyedByItsAccountNeverByItsRelay() throws {
        let a = try ProxySettings(shareLink: Self.reality)
        let renamed = try ProxySettings(shareLink: Self.reality.replacingOccurrences(of: "#NL-1", with: "#Other"))
        let other = try ProxySettings(shareLink: Self.reality.replacingOccurrences(of: Self.uuid, with: "11111111-2222-3333-4444-555555555555"))
        XCTAssertEqual(ProxyLocation.endpoint(of: a), ProxyLocation.endpoint(of: renamed))
        XCTAssertNotEqual(ProxyLocation.endpoint(of: a), ProxyLocation.endpoint(of: other))
        XCTAssertFalse(ProxyLocation.endpoint(of: a).contains(Self.uuid))
        XCTAssertTrue(ProxyLocation.endpoint(of: a).hasPrefix("xray://nl1.example.com:443#"))
    }

    // MARK: The list, the import and the export

    func testTheListKnowsALinkByItsAccountAndKeepsItsKind() throws {
        let proxy = try ProxySettings(shareLink: Self.reality)
        let other = try ProxySettings(shareLink: Self.reality.replacingOccurrences(of: Self.uuid, with: "11111111-2222-3333-4444-555555555555"))
        XCTAssertNotEqual(ProxyList.identity(of: proxy), ProxyList.identity(of: other))
        XCTAssertNotEqual(ProxyList.identity(of: proxy), ProxyList.identity(of: ProxySettings(kind: .socks5, host: "nl1.example.com", port: 443)))
        var list = ProxyList()
        let report = ProxyListImport.read(Self.reality + "\n" + Self.reality + "\nsocks5://1.2.3.4:1080")
        XCTAssertEqual(report.proxies.count, 2)
        XCTAssertEqual(report.problems.map(\.reason), [.duplicate(ofLine: 1)])
        XCTAssertFalse(report.problems[0].text.contains(Self.uuid), "a problem shows the link without its secret")
        list.add(report.proxies)
        XCTAssertEqual(ProxyList.format(for: list.entries), 4)
        let entry = try XCTUnwrap(list.entries.first)
        XCTAssertEqual(entry.label, "NL-1", "the link's own name")
        XCTAssertTrue(entry.kindKnown)
        XCTAssertEqual(list.entry(for: proxy)?.id, entry.id)
        // A check through the relay answers as SOCKS5: that never becomes the entry's type.
        let check = ProxyCheckResult(diagnosis: ProxyDiagnosis(verdict: .works, kinds: [.socks5]))
        XCTAssertNil(list.record(check, for: entry.id))
        XCTAssertEqual(list.entry(entry.id)?.proxy.kind, .xray)
        // Exported as the link it is, in plaintext like every password of the list.
        let text = ProxyList.exportText(list.entries)
        XCTAssertTrue(text.contains(Self.reality))
        XCTAssertEqual(ProxyListImport.read(text).proxies.map(\.proxy), list.entries.map(\.proxy))
        // The same link with another password is another connection to the same proxy.
        XCTAssertFalse(ProxyList.sameConnection(proxy, other))
    }

    func testTheImportSaysWhatIsWrongWithALink() {
        let report = ProxyListImport.read("""
            vless://\(Self.uuid)@a.example:443?type=h2#Old
            ss://\(ShareLinkTests.base64("rc4-md5:pw@a.example:443"))
            vmess://%%%
            trojan://pw@t.example:443#Fine
            """)
        XCTAssertEqual(report.proxies.map(\.label), ["Fine"])
        XCTAssertEqual(report.problems.map(\.reason), [
            .shareLink(.removedTransport("h2")), .shareLink(.unsupportedCipher("rc4-md5")), .shareLink(.invalidBase64),
        ])
        XCTAssertEqual(report.problems.map(\.text), ["vless://…@a.example:443", "ss://…", "vmess://…"])
    }

    func testAFieldTakesOneLinkAndHidesItsSecret() throws {
        guard case .proxy(let line) = ProxyListImport.readField(Self.reality) else { return XCTFail("not read") }
        XCTAssertEqual(line.proxy.kind, .xray)
        XCTAssertTrue(line.kindGiven)
        XCTAssertEqual(ProxyListImport.line(for: line.proxy), Self.reality)
        let range = try XCTUnwrap(ProxyListImport.passwordRange(in: Self.reality))
        XCTAssertEqual(String(Self.reality[range]), Self.uuid)
    }

    func testASubscriptionPastedAsServedIsReadAsItsLinks() {
        let body = ShareLinkTests.base64(Self.reality + "\ntrojan://pw@t.example:443#T\n")
        let report = ProxyListImport.read(body)
        XCTAssertEqual(report.proxies.count, 2)
        XCTAssertEqual(report.problems, [])
        // Text that only happens to be base64 is read as it is.
        XCTAssertEqual(ProxyListImport.subscriptionLinks(in: "abcd"), "abcd")
    }

    func testTheAutomationAPINamesALinksProtocolNeverItsSecret() throws {
        let summary = ProfileSummary(id: UUID(), name: "P", createdAt: Date(), lastLaunchedAt: nil, revision: 0)
        let proxy = try ProxySettings(shareLink: Self.reality)
        let row = AutomationProfiles.Entry(summary, running: false, busy: false, proxy: proxy)
        XCTAssertEqual(row.proxy, "vless://nl1.example.com:443")
    }

    func testLogRedactionTakesLinksOut() {
        let reason = "could not start: vless://\(Self.uuid)@nl1.example.com:443?security=reality and ss://YWVzOnB3@h:1"
        let redacted = LogRedaction.exceptionReason(reason)
        XCTAssertFalse(redacted.contains(Self.uuid))
        XCTAssertFalse(redacted.contains("YWVzOnB3"))
    }

    // MARK: Routes

    func testALinkIsReachedThroughItsRelayOrNotAtAll() throws {
        let routes = ProxyRoutes()
        var proxy = try ProxySettings(shareLink: Self.reality)
        proxy.excludedDomains = ["intranet.example"]
        let socks = ProxySettings(kind: .socks5, host: "1.2.3.4", port: 1080)
        XCTAssertEqual(routes.connectable(socks), socks)
        XCTAssertNil(routes.connectable(proxy), "no relay: nothing to connect to, never the link's server")
        let id = UUID()
        routes.add(ProxyRoutes.Route(port: 40000, username: "u", password: "p"), for: try XCTUnwrap(proxy.link), id: id)
        let connectable = try XCTUnwrap(routes.connectable(proxy))
        XCTAssertEqual(connectable, ProxySettings(kind: .socks5, host: "127.0.0.1", port: 40000, username: "u", password: "p",
                                                  excludedDomains: ["intranet.example"]))
        // A second relay for the same link (another profile on it), then the first one stops.
        let second = UUID()
        routes.add(ProxyRoutes.Route(port: 40001, username: "u2", password: "p2"), for: try XCTUnwrap(proxy.link), id: second)
        XCTAssertEqual(routes.connectable(proxy)?.port, 40001)
        routes.remove(id: second)
        XCTAssertEqual(routes.connectable(proxy)?.port, 40000)
        routes.remove(id: id)
        XCTAssertNil(routes.connectable(proxy))
    }

    func testTheRoutesRecordReadsBackExactly() throws {
        let routes = ["vless://a": ProxyRoutes.Route(port: 1, username: "u", password: "p")]
        var record = try ProxyRoutes.encodeRecord(routes)
        let trailing = Data("{\"command\":1}\n".utf8)
        var stream = record + trailing
        let read = try ProxyRoutes.readRecord { count in
            let chunk = stream.prefix(min(count, 3))
            stream.removeFirst(chunk.count)
            return chunk
        }
        XCTAssertEqual(read, routes)
        XCTAssertEqual(stream, trailing, "nothing after the record is read")
        XCTAssertEqual(try ProxyRoutes.readRecord(Self.reader(try ProxyRoutes.encodeRecord([:]))), [:])
        XCTAssertThrowsError(try ProxyRoutes.readRecord(Self.reader(Data("PBG1xxxx".utf8))))
        XCTAssertThrowsError(try ProxyRoutes.readRecord(Self.reader(record.prefix(6))))
        ProxyRoutes.erase(&record)
        XCTAssertTrue(record.isEmpty)
    }

    func testTheProbeAsksNoLinkWithoutItsRelay() throws {
        let diagnosis = ProxyProbe(targetHost: "example.com").runNow(try ProxySettings(shareLink: Self.reality))
        XCTAssertEqual(diagnosis.verdict, .relayNotStarted)
        XCTAssertFalse(diagnosis.isWorking)
    }

    /// WebRTC through a link's proxy goes as through a SOCKS5 proxy's: its relay is one, with UDP.
    func testTheGateTreatsALinkAsTheSOCKS5ProxyItsRelayIs() throws {
        let proxy = try ProxySettings(shareLink: Self.reality)
        XCTAssertTrue(WebRTCGate.wantsRelay(policy: .unrestricted, proxy: proxy))
        XCTAssertEqual(WebRTCGate.decide(policy: .unrestricted, proxy: proxy, ownProcess: true, guardState: .ready, udp: .supported), .relay)
        XCTAssertEqual(WebRTCGate.decide(policy: .unrestricted, proxy: proxy, ownProcess: true, guardState: .ready, udp: .unsupported),
                       .off(.proxyWithoutUDP))
        XCTAssertEqual(WebRTCGate.decide(policy: .disabled, proxy: proxy, ownProcess: true, guardState: .ready, udp: .supported), .off(nil))
        XCTAssertEqual(VMUDPRoute.forProxy(proxy, check: nil), .unknown)
    }

    static func reader(_ data: Data) -> (Int) -> Data? {
        var rest = data
        return { count in
            let chunk = rest.prefix(count)
            rest.removeFirst(chunk.count)
            return chunk
        }
    }
}
