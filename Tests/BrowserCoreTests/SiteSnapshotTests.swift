import XCTest
@testable import BrowserCore

/// "What sites see": a ClientHello as the server reads it, the page's report flattened, and the
/// comparison with Safari's.
final class SiteSnapshotTests: XCTestCase {
    /// A ClientHello as a client sends it, with GREASE in the suites, the extensions, the groups
    /// and the versions; `split`: carried by two records, cut after that many handshake bytes.
    static func clientHello(split: Int? = nil) -> [UInt8] {
        func u16(_ value: Int) -> [UInt8] { [UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)] }
        func list16(_ values: [UInt16]) -> [UInt8] {
            var bytes: [UInt8] = []
            for value in values { bytes += u16(Int(value)) }
            return bytes
        }
        func withLength16(_ content: [UInt8]) -> [UInt8] { u16(content.count) + content }
        let name: [UInt8] = Array("example.com".utf8)
        var nameEntry: [UInt8] = [0]
        nameEntry += withLength16(name)
        let sni = withLength16(nameEntry)
        let groups = withLength16(list16([0x0A0A, 0x001d, 0x0017, 0x0018]))
        var protocols: [UInt8] = []
        for text in ["h2", "http/1.1"] {
            protocols.append(UInt8(text.utf8.count))
            protocols += Array(text.utf8)
        }
        let alpn = withLength16(protocols)
        let signatures = withLength16(list16([0x0403, 0x0804, 0x0401]))
        var versions: [UInt8] = [6]
        versions += list16([0x1A1A, 0x0304, 0x0303])
        let extensions: [(UInt16, [UInt8])] = [
            (0x2A2A, []), (0x0000, sni), (0x0017, []), (0xff01, [0]), (0x000a, groups),
            (0x000b, [1, 0]), (0x0010, alpn), (0x000d, signatures), (0x002b, versions),
        ]
        var extensionBytes: [UInt8] = []
        for (type, data) in extensions {
            extensionBytes += u16(Int(type))
            extensionBytes += withLength16(data)
        }
        var body: [UInt8] = u16(0x0303)
        body += [UInt8](repeating: 7, count: 32)
        body.append(32)
        body += [UInt8](repeating: 1, count: 32)
        body += withLength16(list16([0x3A3A, 0x1301, 0x1302, 0x1303, 0xc02c, 0xc02b]))
        body += [1, 0]
        body += withLength16(extensionBytes)
        var handshake: [UInt8] = [0x01, UInt8(truncatingIfNeeded: body.count >> 16)]
        handshake += u16(body.count)
        handshake += body
        func record(_ fragment: [UInt8]) -> [UInt8] {
            var record: [UInt8] = [0x16, 0x03, 0x01]
            record += withLength16(fragment)
            return record
        }
        guard let split else { return record(handshake) }
        return record(Array(handshake[..<split])) + record(Array(handshake[split...]))
    }

    func testAClientHelloAsTheServerReadsIt() throws {
        let hello = try TLSClientHello.parse(Self.clientHello())
        XCTAssertEqual(hello.legacyVersion, 0x0303)
        XCTAssertEqual(hello.cipherSuites, [0x1301, 0x1302, 0x1303, 0xc02c, 0xc02b], "GREASE left out")
        XCTAssertEqual(hello.extensions, [0x0000, 0x0017, 0xff01, 0x000a, 0x000b, 0x0010, 0x000d, 0x002b], "in their order")
        XCTAssertEqual(hello.supportedGroups, [0x001d, 0x0017, 0x0018])
        XCTAssertEqual(hello.pointFormats, [0])
        XCTAssertEqual(hello.signatureAlgorithms, [0x0403, 0x0804, 0x0401])
        XCTAssertEqual(hello.alpn, ["h2", "http/1.1"])
        XCTAssertEqual(hello.supportedVersions, [0x0304, 0x0303])
        XCTAssertEqual(hello.serverName, "example.com")
        XCTAssertEqual(try TLSClientHello.parse(Self.clientHello(split: 40)), hello, "a handshake carried by two records")
    }

    /// JA3 and JA4 as FoxIO and Salesforce define them; the expected values were computed apart
    /// from this code (Python's hashlib over the same fields).
    func testJA3AndJA4() throws {
        let hello = try TLSClientHello.parse(Self.clientHello())
        XCTAssertEqual(hello.ja3, "771,4865-4866-4867-49196-49195,0-23-65281-10-11-16-13-43,29-23-24,0")
        XCTAssertEqual(hello.ja3Hash, "3a7feadf730413205c8c31fb23675dfe")
        XCTAssertEqual(hello.ja4, "t13d0508h2_bf5bdbdbea07_5e5676343554")
        XCTAssertEqual(hello.values["alpn"], "h2,http/1.1")
        XCTAssertEqual(hello.values["versions"], "0x0304,0x0303")
    }

    func testWhatIsNotAClientHello() {
        let full = Self.clientHello()
        for length in [0, 3, 5, 40, full.count - 1] {
            XCTAssertThrowsError(try TLSClientHello.parse(Array(full.prefix(length)))) { error in
                XCTAssertEqual(error as? TLSClientHello.ParseError, .incomplete, "\(length) bytes")
            }
        }
        XCTAssertThrowsError(try TLSClientHello.parse(Array("GET / HTTP/1.1\r\n\r\n".utf8))) { error in
            XCTAssertEqual(error as? TLSClientHello.ParseError, .notAClientHello)
        }
        // A handshake that is a ServerHello.
        XCTAssertThrowsError(try TLSClientHello.parse([0x16, 0x03, 0x03, 0x00, 0x04, 0x02, 0x00, 0x00, 0x00])) { error in
            XCTAssertEqual(error as? TLSClientHello.ParseError, .notAClientHello)
        }
        // Cipher suites said to be longer than the message.
        var broken = full
        // The record's header (5), the handshake's (4), the version (2), random (32), the session
        // id's length and the id (1 + 32): the cipher suites' length.
        let suitesLength = 76
        broken[suitesLength] = 0x7F
        XCTAssertThrowsError(try TLSClientHello.parse(broken)) { error in
            XCTAssertEqual(error as? TLSClientHello.ParseError, .malformed)
        }
        XCTAssertTrue(TLSClientHello.isGREASE(0x0A0A))
        XCTAssertTrue(TLSClientHello.isGREASE(0xFAFA))
        XCTAssertFalse(TLSClientHello.isGREASE(0x0A1A))
        XCTAssertFalse(TLSClientHello.isGREASE(0x1301))
    }

    func testThePagesReportFlattened() throws {
        let report = Data("""
        {"probe": {"ua": "Mozilla/5.0", "hardwareConcurrency": 8, "cookieEnabled": true, "devicePixelRatio": 2.5,
                   "webgl": {"vendor": "Apple Inc."}, "features": {"window": {"ApplePaySetup": "function"}}},
         "geometry": {"chrome": "0x87", "outer": "1000x600"},
         "headers": {"navigation.order": "Host,Accept,User-Agent", "navigation.accept-language": "de-DE,de;q=0.9"},
         "apis": {"quota": 1000000, "voices": -1, "share": null}}
        """.utf8)
        let hello = try TLSClientHello.parse(Self.clientHello())
        let snapshot = try SiteSnapshot(report: report, clientHello: hello)
        XCTAssertEqual(snapshot.values["probe.ua"], "Mozilla/5.0")
        XCTAssertEqual(snapshot.values["probe.hardwareConcurrency"], "8", "whole numbers as JavaScript prints them")
        XCTAssertEqual(snapshot.values["probe.cookieEnabled"], "true")
        XCTAssertEqual(snapshot.values["probe.devicePixelRatio"], "2.5")
        XCTAssertEqual(snapshot.values["probe.webgl.vendor"], "Apple Inc.")
        XCTAssertEqual(snapshot.values["probe.features.window.ApplePaySetup"], "function")
        XCTAssertEqual(snapshot.values["headers.navigation.order"], "Host,Accept,User-Agent")
        XCTAssertEqual(snapshot.values["apis.voices"], "-1")
        XCTAssertEqual(snapshot.values["apis.share"], "null")
        XCTAssertEqual(snapshot.values["tls.ja4"], "t13d0508h2_bf5bdbdbea07_5e5676343554")
        XCTAssertThrowsError(try SiteSnapshot(report: Data("not json".utf8), clientHello: nil))
    }

    func testTheComparison() {
        let profile = SiteSnapshot(values: [
            "probe.ua": "Safari/605.1.15", "probe.safari": "undefined", "geometry.chrome": "0x76",
            "geometry.outer": "1200x800", "headers.navigation.order": "Host,Accept", "tls.ja4": "t13d",
            "apis.voices": "180", "probe.screen": "1512x982",
        ])
        let safari = SiteSnapshot(values: [
            "probe.ua": "Safari/605.1.15", "probe.safari": "[object SafariRemoteNotification]", "geometry.chrome": "0x87",
            "geometry.outer": "1440x900", "headers.navigation.order": "Host,Accept", "tls.ja4": "t13d",
            "apis.quota": "1000", "probe.screen": "1512x982",
        ])
        let signals = SiteComparison.compare(profile: profile, safari: safari)
        func verdict(_ key: String) -> SiteSignal.Verdict? { signals.first { $0.key == key }?.verdict }
        XCTAssertEqual(verdict("probe.ua"), .same)
        XCTAssertEqual(verdict("probe.safari"), .differs)
        XCTAssertEqual(verdict("geometry.chrome"), .differs, "the bars around the page are compared")
        XCTAssertEqual(verdict("geometry.outer"), .perWindow, "each window's own size is not")
        XCTAssertEqual(verdict("apis.voices"), .onlyProfile)
        XCTAssertEqual(verdict("apis.quota"), .onlySafari)
        XCTAssertEqual(signals.map(\.category), signals.map(\.category).sorted { $0.order < $1.order }, "grouped in order")
        XCTAssertEqual(signals.first?.category, .navigator)
        XCTAssertTrue(SiteComparison.compare(profile: profile, safari: nil).allSatisfy { $0.verdict == .onlyProfile || $0.verdict == .perWindow })

        XCTAssertEqual(SiteComparison.category(of: "probe.screen"), .screen)
        XCTAssertEqual(SiteComparison.category(of: "geometry.devicePixelRatio"), .screen)
        XCTAssertEqual(SiteComparison.category(of: "geometry.chrome"), .window)
        XCTAssertEqual(SiteComparison.category(of: "probe.webgl.renderer"), .rendering)
        XCTAssertEqual(SiteComparison.category(of: "probe.natives.Date"), .apis)
        XCTAssertEqual(SiteComparison.category(of: "probe.timeZone"), .navigator)
        XCTAssertEqual(SiteComparison.category(of: "headers.fetch.accept"), .headers)
        XCTAssertEqual(SiteComparison.category(of: "tls.cipherSuites"), .tls)
        XCTAssertEqual(SiteComparison.noteKey(for: "probe.safari"), "whatSites.note.safariOnly")
        XCTAssertNil(SiteComparison.noteKey(for: "probe.ua"))
    }

    func testTheMeasuringPage() throws {
        let token = SiteSnapshotPage.token(.safari)
        XCTAssertTrue(token.hasPrefix("pbwss-") && token.hasSuffix("-safari"))
        XCTAssertNotEqual(token, SiteSnapshotPage.token(.safari), "a token of its own each time")
        let url = SiteSnapshotPage.url(port: 52000, token: token)
        XCTAssertTrue(SiteSnapshotPage.isMeasuringPage(url))
        XCTAssertFalse(SiteSnapshotPage.isMeasuringPage(try XCTUnwrap(URL(string: "http://127.0.0.1:52000/headers.html?token=other"))))
        XCTAssertFalse(SiteSnapshotPage.isMeasuringPage(try XCTUnwrap(URL(string: "https://example.com/headers.html?token=pbwss-1"))))

        let html = SiteSnapshotPage.html(scripts: ["probe": "return {ua: navigator.userAgent};", "geometry": "return {};",
                                                   "apis": "return {};", "headers": "return {};"],
                                         tlsPort: 52001, token: token, title: "What <sites> see", measuring: "…",
                                         done: "Done </script><b>")
        XCTAssertTrue(html.contains("return {ua: navigator.userAgent};"))
        XCTAssertTrue(html.contains("https://localhost:52001/tls?token=\(token)"))
        XCTAssertTrue(html.contains("'/report?token=\(token)'"))
        XCTAssertTrue(html.contains("<title>What &lt;sites> see</title>"), "text is not markup")
        XCTAssertFalse(html.contains("Done </script>"), "nor can it end the script")
    }
}
