import XCTest
@testable import BrowserCore

/// The share links providers hand out (vless://, vmess://, trojan://, ss://), read as the relay will
/// use them, and every way one can be refused (`ShareLink`, docs/TUNNEL.md, "Links").
final class ShareLinkTests: XCTestCase {
    static let uuid = "b831381d-6324-4d53-ad4f-8cda48b30811"
    static let pbk = "SbVKOEMjK0sIlbwg4akyBg5mL5KZwwB-ed4eEE7YnRc"

    private func parse(_ text: String, file: StaticString = #filePath, line: UInt = #line) -> ShareLink? {
        do {
            return try ShareLink.parse(text)
        } catch {
            XCTFail("\(text.prefix(60))…: \(error)", file: file, line: line)
            return nil
        }
    }

    private func refused(_ text: String, _ expected: ShareLinkError, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try ShareLink.parse(text), file: file, line: line) { error in
            XCTAssertEqual(error as? ShareLinkError, expected, "\(text.prefix(80))", file: file, line: line)
        }
    }

    static func base64(_ text: String, urlSafe: Bool = false, padded: Bool = true) -> String {
        var encoded = Data(text.utf8).base64EncodedString()
        if urlSafe { encoded = encoded.replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_") }
        if !padded { encoded = encoded.replacingOccurrences(of: "=", with: "") }
        return encoded
    }

    static func vmess(_ object: [String: Any], urlSafe: Bool = false, padded: Bool = true) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return "vmess://" + base64(String(decoding: data, as: UTF8.self), urlSafe: urlSafe, padded: padded)
    }

    // MARK: VLESS

    func testVLESSRealityVisionAsProvidersWriteIt() throws {
        let text = "vless://\(Self.uuid)@nl1.example.com:443?encryption=none&flow=xtls-rprx-vision&security=reality"
            + "&sni=www.microsoft.com&fp=chrome&pbk=\(Self.pbk)&sid=6ba85179e30d4fc2&spx=%2F&type=tcp&headerType=none"
            + "#%F0%9F%87%B3%F0%9F%87%B1%20NL-1"
        let link = try XCTUnwrap(parse(text))
        XCTAssertEqual(link.scheme, .vless)
        XCTAssertEqual(link.host, "nl1.example.com")
        XCTAssertEqual(link.port, 443)
        XCTAssertEqual(link.name, "🇳🇱 NL-1")
        XCTAssertEqual(link.userID, Self.uuid)
        XCTAssertEqual(link.flow, "xtls-rprx-vision")
        XCTAssertEqual(link.encryption, "none")
        XCTAssertEqual(link.transport, .tcp)
        XCTAssertEqual(link.security, .reality)
        XCTAssertEqual(link.serverName, "www.microsoft.com")
        XCTAssertEqual(link.fingerprint, "chrome")
        XCTAssertEqual(link.realityPublicKey, Self.pbk)
        XCTAssertEqual(link.realityShortID, "6ba85179e30d4fc2")
        XCTAssertEqual(link.realitySpiderX, "/")
        XCTAssertEqual(link.redacted, "VLESS nl1.example.com:443")
        XCTAssertFalse(link.redacted.contains(Self.uuid))
    }

    func testVLESSTransportsAndTLS() throws {
        let ws = try XCTUnwrap(parse("vless://\(Self.uuid)@cdn.example.org:443?encryption=none&security=tls&sni=cdn.example.org"
            + "&type=ws&host=cdn.example.org&path=%2Fws%3Fed%3D2048&alpn=h2%2Chttp%2F1.1&fp=safari#WS"))
        XCTAssertEqual(ws.transport, .ws)
        XCTAssertEqual(ws.path, "/ws?ed=2048")
        XCTAssertEqual(ws.hostHeader, "cdn.example.org")
        XCTAssertEqual(ws.alpn, ["h2", "http/1.1"])
        XCTAssertEqual(ws.fingerprint, "safari")
        XCTAssertEqual(ws.security, .tls)

        let grpc = try XCTUnwrap(parse("vless://\(Self.uuid)@1.2.3.4:443?security=tls&type=grpc&serviceName=grpc-svc&mode=multi"
            + "&sni=g.example.com&authority=g.example.com#gRPC"))
        XCTAssertEqual(grpc.transport, .grpc)
        XCTAssertEqual(grpc.serviceName, "grpc-svc")
        XCTAssertTrue(grpc.grpcMultiMode)
        XCTAssertEqual(grpc.authority, "g.example.com")

        let xhttp = try XCTUnwrap(parse("vless://\(Self.uuid)@[2001:db8::1]:8443/?security=reality&type=xhttp&path=%2Fxh"
            + "&mode=stream-one&sni=a.example&pbk=\(Self.pbk)&fp=firefox#v6"))
        XCTAssertEqual(xhttp.host, "2001:db8::1")
        XCTAssertEqual(xhttp.address, "[2001:db8::1]:8443")
        XCTAssertEqual(xhttp.transport, .xhttp)
        XCTAssertEqual(xhttp.xhttpMode, "stream-one")
        XCTAssertNil(xhttp.realityShortID)

        let upgrade = try XCTUnwrap(parse("vless://\(Self.uuid)@u.example:80?type=httpupgrade&path=%2Fup&host=u.example"))
        XCTAssertEqual(upgrade.transport, .httpupgrade)
        XCTAssertEqual(upgrade.security, .none)
        XCTAssertEqual(upgrade.name, "")

        let header = try XCTUnwrap(parse("vless://\(Self.uuid)@h.example:80?type=tcp&headerType=http&host=a.example%2Cb.example&path=%2F"))
        XCTAssertTrue(header.tcpHTTPHeader)
        XCTAssertEqual(header.hostHeader, "a.example,b.example")

        // Xray's own short id form (1–30 characters), and the parameters' names in any case.
        let custom = try XCTUnwrap(parse("VLESS://my-user-1@s.example:443?Security=TLS&SNI=s.example&Type=WS"))
        XCTAssertEqual(custom.userID, "my-user-1")
        XCTAssertEqual(custom.security, .tls)
        XCTAssertEqual(custom.transport, .ws)
    }

    func testVLESSRefusals() {
        let base = "vless://\(Self.uuid)@s.example.com:443"
        refused(base + "?type=http&security=tls", .removedTransport("http"))
        refused(base + "?type=h2&security=tls", .removedTransport("h2"))
        refused(base + "?type=quic", .removedTransport("quic"))
        refused(base + "?type=kcp", .unsupportedTransport("kcp"))
        refused(base + "?security=xtls", .unsupportedSecurity("xtls"))
        refused(base + "?flow=xtls-rprx-direct&security=tls", .unsupportedFlow("xtls-rprx-direct"))
        refused(base + "?flow=xtls-rprx-vision&security=tls&type=ws", .visionNeedsTLS)
        refused(base + "?flow=xtls-rprx-vision", .visionNeedsTLS)
        refused(base + "?security=reality&sni=a.example", .missingRealityKey)
        refused(base + "?security=reality&sni=a.example&pbk=abc", .invalidRealityKey)
        refused(base + "?security=reality&pbk=\(Self.pbk)", .missingServerName)
        refused(base + "?security=reality&sni=a.example&pbk=\(Self.pbk)&sid=abc", .invalidShortID)
        refused(base + "?security=reality&sni=a.example&pbk=\(Self.pbk)&sid=zz", .invalidShortID)
        refused(base + "?security=reality&sni=a.example&pbk=\(Self.pbk)&sid=0123456789abcdef01", .invalidShortID)
        refused(base + "?security=tls&fp=netscape", .unsupportedParameter(name: "fp", value: "netscape"))
        refused(base + "?security=tls&pcs=1234", .invalidPinnedCertificate)
        refused(base + "?encryption=aes-128-gcm", .unsupportedEncryption("aes-128-gcm"))
        refused(base + "?type=ws&path=ws", .unsupportedParameter(name: "path", value: "ws"))
        refused(base + "?type=ws&host=bad%20host", .unsupportedParameter(name: "host", value: "bad host"))
        refused(base + "?type=grpc&mode=duplex", .unsupportedParameter(name: "mode", value: "duplex"))
        refused(base + "?type=tcp&headerType=srtp", .unsupportedParameter(name: "headerType", value: "srtp"))
        refused(base + "?path=%ZZ", .invalidParameter(name: "path"))
        refused("vless://not a uuid@s.example:443", .containsWhitespace)
        refused("vless://\(String(repeating: "a", count: 31))@s.example:443", .invalidUserID)
        refused("vless://s.example:443?security=tls", .missingCredentials)
        refused("vless://@s.example:443", .missingCredentials)
        refused("vless://\(Self.uuid)@s.example", .missingPort)
        refused("vless://\(Self.uuid)@s.example:0", .invalidPort("0"))
        refused("vless://\(Self.uuid)@s.example:70000", .invalidPort("70000"))
        refused("vless://\(Self.uuid)@s.example:44a3", .invalidPort("44a3"))
        refused("vless://\(Self.uuid)@bad_host!:443", .invalidHost("bad_host!"))
        refused("vless://\(Self.uuid)@2001:db8::1:443", .invalidHost("2001:db8::1"))
        refused("vless://\(Self.uuid)@[2001:db8::1:443", .invalidHost("[2001:db8::1:443"))
        refused("vless://\(Self.uuid)@s.example:443/path?security=tls", .hasPath)
        refused("", .empty)
        refused("   \n", .empty)
        refused("vless://" + String(repeating: "a", count: ShareLink.maximumLength), .tooLong)
    }

    func testTheLinkIsTrimmedOfWhatAPasteBrings() throws {
        let link = try XCTUnwrap(parse("\u{FEFF}  vless://\(Self.uuid)@s.example:443?security=tls#A \n"))
        XCTAssertEqual(link.name, "A")
        XCTAssertEqual(ShareLink.trimmed("\u{200B}vless://x@y:1\n"), "vless://x@y:1")
    }

    func testAllowInsecureIsNotHonouredButSaid() throws {
        let link = try XCTUnwrap(parse("vless://\(Self.uuid)@s.example:443?security=tls&allowInsecure=1"))
        XCTAssertTrue(link.askedInsecure)
        let config = try XrayConfig.object(for: link, inbound: XrayConfig.Inbound(port: 1080, username: "u", password: "p"))
        let text = String(decoding: try JSONSerialization.data(withJSONObject: config), as: UTF8.self)
        XCTAssertFalse(text.contains("allowInsecure"), "Xray checks the certificate; the link's wish is not passed on")
        let pinned = String(repeating: "ab", count: 32)
        let pinnedLink = try XCTUnwrap(parse("vless://\(Self.uuid)@s.example:443?security=tls&pcs=\(pinned)&vcn=s.example"))
        XCTAssertEqual(pinnedLink.pinnedCertificateSHA256, pinned)
        XCTAssertEqual(pinnedLink.verifyCertificateByName, "s.example")
    }

    // MARK: VMess

    func testVMessAsV2RayNWritesIt() throws {
        let object: [String: Any] = ["v": "2", "ps": "VMess WS", "add": "vm.example.com", "port": "443", "id": Self.uuid,
                                     "aid": "0", "scy": "auto", "net": "ws", "type": "none", "host": "vm.example.com",
                                     "path": "/vm", "tls": "tls", "sni": "vm.example.com", "alpn": "h2,http/1.1", "fp": "chrome"]
        for text in [Self.vmess(object), Self.vmess(object, urlSafe: true, padded: false)] {
            let link = try XCTUnwrap(parse(text))
            XCTAssertEqual(link.scheme, .vmess)
            XCTAssertEqual(link.name, "VMess WS")
            XCTAssertEqual(link.host, "vm.example.com")
            XCTAssertEqual(link.port, 443)
            XCTAssertEqual(link.userID, Self.uuid)
            XCTAssertEqual(link.method, "auto")
            XCTAssertEqual(link.transport, .ws)
            XCTAssertEqual(link.path, "/vm")
            XCTAssertEqual(link.security, .tls)
            XCTAssertEqual(link.alpn, ["h2", "http/1.1"])
        }
        // Numbers where others write strings, gRPC's service name in `path` and its mode in `type`.
        let grpc = try XCTUnwrap(parse(Self.vmess(["add": "5.6.7.8", "port": 8443, "id": Self.uuid, "aid": 0, "net": "grpc",
                                                   "path": "svc", "type": "multi", "tls": ""])))
        XCTAssertEqual(grpc.transport, .grpc)
        XCTAssertEqual(grpc.serviceName, "svc")
        XCTAssertTrue(grpc.grpcMultiMode)
        XCTAssertEqual(grpc.security, .none)
        XCTAssertEqual(grpc.name, "")
        // A name in the fragment where `ps` has none.
        let named = try XCTUnwrap(parse(Self.vmess(["add": "a.example", "port": "80", "id": Self.uuid]) + "#Fragment"))
        XCTAssertEqual(named.name, "Fragment")
        XCTAssertEqual(named.transport, .tcp)
        // An IPv6 server.
        let six = try XCTUnwrap(parse(Self.vmess(["add": "2001:db8::2", "port": "443", "id": Self.uuid])))
        XCTAssertEqual(six.host, "2001:db8::2")
    }

    func testVMessRefusals() {
        let good: [String: Any] = ["add": "vm.example.com", "port": "443", "id": Self.uuid, "aid": "0"]
        var aid = good
        aid["aid"] = "64"
        refused(Self.vmess(aid), .vmessAlterID)
        var h2 = good
        h2["net"] = "h2"
        refused(Self.vmess(h2), .removedTransport("h2"))
        var cipher = good
        cipher["scy"] = "aes-256-cfb"
        refused(Self.vmess(cipher), .unsupportedCipher("aes-256-cfb"))
        var id = good
        id["id"] = ""
        refused(Self.vmess(id), .invalidUserID)
        var port = good
        port["port"] = "x"
        refused(Self.vmess(port), .invalidPort("x"))
        var reality = good
        reality["tls"] = "reality"
        reality["sni"] = "a.example"
        refused(Self.vmess(reality), .unsupportedSecurity("reality"))
        refused("vmess://%%%", .invalidBase64)
        refused("vmess://" + Self.base64("not json"), .invalidVMessJSON)
        refused("vmess://" + Self.base64("[1,2]"), .invalidVMessJSON)
    }

    // MARK: Trojan

    func testTrojan() throws {
        let link = try XCTUnwrap(parse("trojan://p%40ss%3Aword@tr.example.net:443?security=tls&sni=tr.example.net&type=tcp#Trojan%20DE"))
        XCTAssertEqual(link.scheme, .trojan)
        XCTAssertEqual(link.password, "p@ss:word")
        XCTAssertEqual(link.name, "Trojan DE")
        XCTAssertEqual(link.security, .tls)
        // TLS unless the link says otherwise.
        let plain = try XCTUnwrap(parse("trojan://secret@t.example:443#T"))
        XCTAssertEqual(plain.security, .tls)
        XCTAssertNil(plain.serverName)
        let ws = try XCTUnwrap(parse("trojan://secret@t.example:443?type=ws&path=%2Ftr&host=t.example&sni=t.example&peer=ignored.example"))
        XCTAssertEqual(ws.transport, .ws)
        XCTAssertEqual(ws.serverName, "t.example")
        let reality = try XCTUnwrap(parse("trojan://secret@t.example:443?security=reality&sni=r.example&pbk=\(Self.pbk)&sid=ab"))
        XCTAssertEqual(reality.security, .reality)
        refused("trojan://@t.example:443", .missingCredentials)
        refused("trojan://t.example:443", .missingCredentials)
        refused("trojan://secret@t.example:443?flow=xtls-rprx-vision", .unsupportedFlow("xtls-rprx-vision"))
    }

    // MARK: Shadowsocks

    func testShadowsocksSIP002AndLegacy() throws {
        let userInfo = Self.base64("chacha20-ietf-poly1305:se:cret", urlSafe: true, padded: false)
        let sip = try XCTUnwrap(parse("ss://\(userInfo)@ss.example.com:8388#SS%201"))
        XCTAssertEqual(sip.scheme, .shadowsocks)
        XCTAssertEqual(sip.method, "chacha20-ietf-poly1305")
        XCTAssertEqual(sip.password, "se:cret")
        XCTAssertEqual(sip.name, "SS 1")
        let config = try XrayConfig.object(for: sip, inbound: XrayConfig.Inbound(port: 1, username: "u", password: "p"))
        let settings = try XCTUnwrap(((config["outbounds"] as? [[String: Any]])?.first)?["settings"] as? [String: Any])
        XCTAssertEqual(settings["method"] as? String, "chacha20-poly1305", "the cipher by Xray's own name")

        let key = Data(repeating: 7, count: 32).base64EncodedString()
        let encoded = key.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? key
        let ss2022 = try XCTUnwrap(parse("ss://2022-blake3-aes-256-gcm:\(encoded)@1.2.3.4:443/?#ss22"))
        XCTAssertEqual(ss2022.method, "2022-blake3-aes-256-gcm")
        XCTAssertEqual(ss2022.password, key)
        let multi = Data(repeating: 1, count: 16).base64EncodedString() + ":" + Data(repeating: 2, count: 16).base64EncodedString()
        XCTAssertNotNil(parse("ss://2022-blake3-aes-128-gcm:\(multi.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!)@[::1]:443"))

        let legacy = try XCTUnwrap(parse("ss://" + Self.base64("aes-256-gcm:pa@ss@5.6.7.8:8388") + "#legacy"))
        XCTAssertEqual(legacy.method, "aes-256-gcm")
        XCTAssertEqual(legacy.password, "pa@ss")
        XCTAssertEqual(legacy.host, "5.6.7.8")
        XCTAssertEqual(legacy.port, 8388)
    }

    func testShadowsocksRefusals() {
        let info = Self.base64("aes-256-gcm:pw", urlSafe: true, padded: false)
        refused("ss://\(info)@s.example:443/?plugin=obfs-local%3Bobfs%3Dhttp#x", .shadowsocksPlugin("obfs-local"))
        refused("ss://\(Self.base64("aes-256-cfb:pw"))@s.example:443", .unsupportedCipher("aes-256-cfb"))
        refused("ss://\(Self.base64("none:pw"))@s.example:443", .unsupportedCipher("none"))
        refused("ss://\(Self.base64("rc4-md5:pw@s.example:443"))", .unsupportedCipher("rc4-md5"))
        refused("ss://2022-blake3-aes-256-gcm:\(Data(repeating: 1, count: 16).base64EncodedString())@s.example:443",
                .invalidShadowsocksKey(bytes: 32))
        refused("ss://2022-blake3-aes-128-gcm:short@s.example:443", .invalidShadowsocksKey(bytes: 16))
        refused("ss://\(Self.base64("aes-256-gcm"))@s.example:443", .missingCredentials)
        refused("ss://%%%", .invalidBase64)
        refused("ss://" + Self.base64("aes-256-gcm:pw-no-server"), .missingCredentials)
        refused("ss://\(info)@s.example:443?type=ws", .unsupportedTransport("ws"))
    }

    // MARK: Anything else

    func testOtherSchemesAndShapes() {
        refused("hysteria2://pw@h.example:443", .unsupportedScheme("hysteria2"))
        refused("socks5://u:p@h.example:1080", .unsupportedScheme("socks5"))
        refused("vless:/\(Self.uuid)@h.example:443", .unsupportedScheme(""))
        XCTAssertTrue(ShareLink.looksLikeLink("  VMESS://abc"))
        XCTAssertTrue(ShareLink.looksLikeLink("ss://abc"))
        XCTAssertFalse(ShareLink.looksLikeLink("socks5://h:1"))
        XCTAssertFalse(ShareLink.looksLikeLink("1.2.3.4:1080"))
    }

    func testWhatIsShownOfALinkHoldsNoSecret() {
        let link = "vless://\(Self.uuid)@s.example:443?security=tls&sni=s.example#Name"
        XCTAssertEqual(ShareLink.masked(link), "vless://…@s.example:443")
        XCTAssertEqual(ShareLink.masked("vmess://" + Self.base64("{\"id\":\"\(Self.uuid)\"}")), "vmess://…")
        XCTAssertEqual(ShareLink.masked("ss://" + Self.base64("aes-256-gcm:pw@h:1")), "ss://…")
        let range = ShareLink.secretRange(in: link)
        XCTAssertEqual(range.map { String(link[$0]) }, Self.uuid)
        let vmess = "vmess://" + Self.base64("{}") + "#n"
        XCTAssertEqual(ShareLink.secretRange(in: vmess).map { String(vmess[$0]) }, Self.base64("{}"))
        let errors: [ShareLinkError] = [.invalidUserID, .invalidPassword, .missingCredentials, .unsupportedCipher("x")]
        for error in errors { XCTAssertFalse(error.description.contains(Self.uuid)) }
    }

    func testTheIdentityTellsAccountsApart() throws {
        let a = try ShareLink.parse("vless://\(Self.uuid)@s.example:443?security=tls#A")
        let b = try ShareLink.parse("vless://\(Self.uuid)@S.EXAMPLE:443?security=tls&type=ws#B")
        let c = try ShareLink.parse("vless://11111111-2222-3333-4444-555555555555@s.example:443?security=tls#C")
        XCTAssertEqual(a.identity, b.identity, "the same account on the same server, reached another way")
        XCTAssertNotEqual(a.identity, c.identity)
    }
}
