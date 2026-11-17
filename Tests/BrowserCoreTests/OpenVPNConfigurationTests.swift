import XCTest
@testable import BrowserCore

final class OpenVPNConfigurationTests: XCTestCase {
    static let ca = "-----BEGIN CERTIFICATE-----\nMIIBszCCAVmgAwIBAgIUQ0E=\n-----END CERTIFICATE-----"
    static let cert = "-----BEGIN CERTIFICATE-----\nMIIBtDCCAVqgAwIBAgIUQ0w=\n-----END CERTIFICATE-----"
    static let key = "-----BEGIN PRIVATE KEY-----\nMIGHAgEAMBMGByqGSM49AgE=\n-----END PRIVATE KEY-----"
    static let tlsCrypt = "-----BEGIN OpenVPN Static key V1-----\n0123456789abcdef\n-----END OpenVPN Static key V1-----"

    /// What a mobile-proxy seller's file looks like: a server, the usual options, everything inline.
    static func typical(_ extra: String = "", remote: String = "remote vpn.example.net 1194 udp") -> String {
        """
        client
        dev tun
        \(remote)
        resolv-retry infinite
        nobind
        persist-key
        persist-tun
        remote-cert-tls server
        cipher AES-256-GCM
        auth SHA256
        verb 3
        \(extra)
        <ca>
        \(ca)
        </ca>
        <cert>
        \(cert)
        </cert>
        <key>
        \(key)
        </key>
        <tls-crypt>
        \(tlsCrypt)
        </tls-crypt>
        """
    }

    func testATypicalFileIsReadWithItsServerAndBlocks() throws {
        let configuration = try OpenVPNConfiguration.parse(Self.typical())
        XCTAssertEqual(configuration.remotes, [.init(host: "vpn.example.net", port: 1194, transport: .udp)])
        XCTAssertEqual(configuration.blocks.map(\.name), ["ca", "cert", "key", "tls-crypt"])
        XCTAssertFalse(configuration.needsCredentials)
        XCTAssertTrue(configuration.directives.contains(["remote-cert-tls", "server"]))
        XCTAssertTrue(configuration.directives.contains(["cipher", "AES-256-GCM"]))
        // What concerns this Mac is left out, and said.
        for name in ["resolv-retry", "persist-tun", "verb"] {
            XCTAssertTrue(configuration.notices.contains(.leftOut(name)), name)
            XCTAssertFalse(configuration.directives.contains { $0.first == name }, name)
        }
    }

    func testTheNormalFormReadsBackTheSame() throws {
        let first = try OpenVPNConfiguration.parse(Self.typical("auth-user-pass\ncomp-lzo no"))
        let second = try OpenVPNConfiguration.parse(first.normalized)
        XCTAssertEqual(first.normalized, second.normalized)
        XCTAssertEqual(second.remotes, first.remotes)
        XCTAssertEqual(second.blocks, first.blocks)
        XCTAssertTrue(second.needsCredentials)
    }

    func testProtoAndPortApplyToRemotesThatDoNotNameTheirOwn() throws {
        let text = Self.typical("proto tcp\nport 443\nremote b.example.net\nremote c.example.net 8443 udp\nremote-random",
                                remote: "remote a.example.net")
        let configuration = try OpenVPNConfiguration.parse(text)
        XCTAssertEqual(configuration.remotes.map(\.host), ["a.example.net", "b.example.net", "c.example.net"])
        XCTAssertEqual(configuration.remotes.map(\.port), [443, 443, 8443])
        XCTAssertEqual(configuration.remotes.map(\.transport), [.tcp, .tcp, .udp])
        XCTAssertTrue(configuration.remoteRandom)
    }

    func testConnectionBlocksAreServersWithTheirOwnOptions() throws {
        let text = Self.typical("""
            <connection>
            remote one.example.net 1194
            proto udp
            explicit-exit-notify 2
            </connection>
            <connection>
            remote two.example.net 443
            proto tcp-client
            </connection>
            """, remote: "")
        let configuration = try OpenVPNConfiguration.parse(text)
        XCTAssertEqual(configuration.remotes, [
            .init(host: "one.example.net", port: 1194, transport: .udp, directives: [["explicit-exit-notify", "2"]]),
            .init(host: "two.example.net", port: 443, transport: .tcp),
        ])
    }

    func testCommentsQuotesAndDashesAreReadAsOpenVPNReadsThem() throws {
        XCTAssertEqual(OpenVPNConfiguration.tokens("remote a.example.net 1194 # the main one"), ["remote", "a.example.net", "1194"])
        XCTAssertEqual(OpenVPNConfiguration.tokens("verify-x509-name \"CN=my server\" subject"), ["verify-x509-name", "CN=my server", "subject"])
        XCTAssertEqual(OpenVPNConfiguration.tokens("pull-filter ignore 'route'"), ["pull-filter", "ignore", "route"])
        XCTAssertEqual(OpenVPNConfiguration.tokens("x \"a\\\"b\""), ["x", "a\"b"])
        XCTAssertNil(OpenVPNConfiguration.tokens("verify-x509-name \"unterminated"))
        let configuration = try OpenVPNConfiguration.parse(Self.typical("--remote-cert-eku \"TLS Web Server Authentication\"\n; a comment\n# another"))
        XCTAssertTrue(configuration.directives.contains(["remote-cert-eku", "TLS Web Server Authentication"]))
        // And the quoted value is quoted again when written.
        XCTAssertTrue(configuration.normalized.contains("remote-cert-eku \"TLS Web Server Authentication\""))
    }

    func testCRLFLinesAndUnknownCaseAreRead() throws {
        let configuration = try OpenVPNConfiguration.parse(Self.typical().replacingOccurrences(of: "\n", with: "\r\n").replacingOccurrences(of: "client", with: "CLIENT"))
        XCTAssertEqual(configuration.remotes.count, 1)
    }

    // MARK: Refused, each with why

    func testWhatCannotBeCarriedIsRefusedWithItsReason() {
        let cases: [(String, OpenVPNConfigProblem)] = [
            ("dev tap", .unsupported(directive: "dev tap", reason: .tap)),
            ("dev-type tap", .unsupported(directive: "dev-type", reason: .tap)),
            ("http-proxy proxy.example.net 8080", .unsupported(directive: "http-proxy", reason: .proxy)),
            ("socks-proxy 127.0.0.1 1080", .unsupported(directive: "socks-proxy", reason: .proxy)),
            ("static-challenge \"Enter OTP\" 1", .unsupported(directive: "static-challenge", reason: .challenge)),
            ("secret static.key", .unsupported(directive: "secret", reason: .staticKey)),
            ("pkcs12 bundle.p12", .unsupported(directive: "pkcs12", reason: .keyStore)),
            ("cryptoapicert \"SUBJ:me\"", .unsupported(directive: "cryptoapicert", reason: .keyStore)),
            ("server 10.8.0.0 255.255.255.0", .unsupported(directive: "server", reason: .server)),
            ("dev-node utun9", .unsupported(directive: "dev-node", reason: .device)),
            ("frobnicate yes", .unknown(directive: "frobnicate", line: 12)),
        ]
        for (line, problem) in cases {
            XCTAssertThrowsError(try OpenVPNConfiguration.parse(Self.typical(line)), line) { error in
                XCTAssertEqual(error as? OpenVPNConfigProblem, problem, line)
            }
        }
    }

    func testFilesMustBeInline() {
        let text = "client\ndev tun\nremote vpn.example.net 1194\nca ca.crt\ncert client.crt\nkey client.key\n"
        XCTAssertThrowsError(try OpenVPNConfiguration.parse(text)) { error in
            XCTAssertEqual(error as? OpenVPNConfigProblem, .fileReference(directive: "ca", file: "ca.crt"))
        }
    }

    func testFilesBesideTheConfigurationAreTakenInline() throws {
        let text = "client\ndev tun\nremote vpn.example.net 1194\nca ca.crt\ncert client.crt\nkey client.key\ntls-auth ta.key 1\n"
        let files = ["ca.crt": Self.ca, "client.crt": Self.cert, "client.key": Self.key, "ta.key": Self.tlsCrypt]
        let inlined = OpenVPNConfiguration.inlining(text) { files[$0] }
        let configuration = try OpenVPNConfiguration.parse(inlined)
        XCTAssertEqual(configuration.blocks.map(\.name), ["ca", "cert", "key", "tls-auth"])
        XCTAssertTrue(configuration.directives.contains(["key-direction", "1"]))
        XCTAssertEqual(configuration.blocks.first { $0.name == "ca" }?.content, Self.ca)
    }

    func testAMissingPieceIsSaid() {
        XCTAssertThrowsError(try OpenVPNConfiguration.parse("client\ndev tun\n<ca>\n\(Self.ca)\n</ca>\nauth-user-pass\n")) {
            XCTAssertEqual($0 as? OpenVPNConfigProblem, .noRemote)
        }
        XCTAssertThrowsError(try OpenVPNConfiguration.parse("client\nremote a.example.net 1194\nauth-user-pass\n")) {
            XCTAssertEqual($0 as? OpenVPNConfigProblem, .missing("ca"))
        }
        XCTAssertThrowsError(try OpenVPNConfiguration.parse("remote a.example.net 1194\nauth-user-pass\n<ca>\n\(Self.ca)\n</ca>\n")) {
            XCTAssertEqual($0 as? OpenVPNConfigProblem, .missing("client"))
        }
        XCTAssertThrowsError(try OpenVPNConfiguration.parse("client\nremote a.example.net 1194\n<ca>\n\(Self.ca)\n</ca>\n<cert>\n\(Self.cert)\n</cert>\n")) {
            XCTAssertEqual($0 as? OpenVPNConfigProblem, .missing("key"))
        }
        XCTAssertThrowsError(try OpenVPNConfiguration.parse("client\nremote a.example.net 1194\n<ca>\n\(Self.ca)\n</ca>\n")) {
            XCTAssertEqual($0 as? OpenVPNConfigProblem, .missing("cert"))
        }
        XCTAssertThrowsError(try OpenVPNConfiguration.parse("client\nremote a.example.net 1194\n<ca>\n\(Self.ca)\n")) {
            XCTAssertEqual($0 as? OpenVPNConfigProblem, .unterminatedBlock("ca"))
        }
        XCTAssertThrowsError(try OpenVPNConfiguration.parse("")) { XCTAssertEqual($0 as? OpenVPNConfigProblem, .noRemote) }
        XCTAssertThrowsError(try OpenVPNConfiguration.parse(String(repeating: "#", count: OpenVPNConfiguration.maximumSize + 1))) {
            XCTAssertEqual($0 as? OpenVPNConfigProblem, .tooLarge)
        }
    }

    func testAnEncryptedKeyIsRefused() {
        let encrypted = "-----BEGIN ENCRYPTED PRIVATE KEY-----\nMIIBvTBXBgkqhkiG9w0BBQ0w\n-----END ENCRYPTED PRIVATE KEY-----"
        let text = Self.typical().replacingOccurrences(of: Self.key, with: encrypted)
        XCTAssertThrowsError(try OpenVPNConfiguration.parse(text)) { XCTAssertEqual($0 as? OpenVPNConfigProblem, .encryptedKey) }
    }

    func testBadServersAreRefused() {
        for remote in ["remote", "remote a.example.net 99999", "remote a.example.net 1194 sctp", "remote \"bad host\" 1194",
                       "remote http://a.example.net 1194"] {
            XCTAssertThrowsError(try OpenVPNConfiguration.parse(Self.typical(remote: remote)), remote)
        }
    }

    // MARK: Mapped, with a notice

    func testNsCertTypeIsCheckedByExtendedKeyUsage() throws {
        let configuration = try OpenVPNConfiguration.parse(Self.typical("ns-cert-type server"))
        XCTAssertTrue(configuration.notices.contains(.nsCertType))
        XCTAssertFalse(configuration.directives.contains { $0.first == "ns-cert-type" })
    }

    func testCiphersThisBuildLacksAreDroppedAndSaid() throws {
        let configuration = try OpenVPNConfiguration.parse(Self.typical("data-ciphers AES-256-GCM:BF-CBC\ndata-ciphers-fallback BF-CBC")
            .replacingOccurrences(of: "cipher AES-256-GCM", with: "cipher BF-CBC"))
        XCTAssertTrue(configuration.notices.contains(.cipherDropped("BF-CBC")))
        XCTAssertTrue(configuration.directives.contains(["data-ciphers", "AES-256-GCM"]))
        XCTAssertFalse(configuration.directives.contains { $0.contains("BF-CBC") })
        XCTAssertThrowsError(try OpenVPNConfiguration.parse(Self.typical("data-ciphers BF-CBC"))) {
            XCTAssertEqual($0 as? OpenVPNConfigProblem, .unsupported(directive: "data-ciphers", reason: .cipher))
        }
    }

    func testOpenSSLCipherListsAreLeftOut() throws {
        let configuration = try OpenVPNConfiguration.parse(Self.typical("tls-cipher \"DEFAULT:@SECLEVEL=0\""))
        XCTAssertTrue(configuration.notices.contains(.openSSLCipherList))
        XCTAssertFalse(configuration.directives.contains { $0.first == "tls-cipher" })
    }

    func testInlineCredentialsAreTakenIntoTheProxysFields() throws {
        let configuration = try OpenVPNConfiguration.parse(Self.typical("auth-user-pass\n<auth-user-pass>\nalice\ns3cret\n</auth-user-pass>"))
        XCTAssertTrue(configuration.needsCredentials)
        XCTAssertEqual(configuration.inlineUsername, "alice")
        XCTAssertEqual(configuration.inlinePassword, "s3cret")
        XCTAssertTrue(configuration.notices.contains(.credentialsTaken))
        // Never in the configuration kept: the proxy's fields hold them, encrypted.
        XCTAssertFalse(configuration.normalized.contains("s3cret"))
    }

    // MARK: What OpenVPN is given

    func testTheRuntimeConfigurationReachesOnlyTheForwardersAndChangesNothingOfTheMac() throws {
        let configuration = try OpenVPNConfiguration.parse(Self.typical("auth-user-pass\nproto tcp\nremote b.example.net 443\nroute 10.0.0.0 255.0.0.0\nup /etc/openvpn/update-resolv-conf"))
        let text = try configuration.runtime(forwarders: [0: 50001, 1: 50002], tunnelProgram: "/Applications/Lumen.app/Contents/MacOS/LumenTunnel",
                                             username: "alice", password: "pa ss", listeningDescriptor: 3, statusDescriptor: 4,
                                             verifierHex: String(repeating: "ab", count: 32))
        let lines = text.components(separatedBy: "\n")
        let remotes = lines.filter { $0.hasPrefix("remote ") }
        XCTAssertEqual(remotes, ["remote 127.0.0.1 50001 udp4", "remote 127.0.0.1 50002 tcp4-client"])
        XCTAssertFalse(text.contains("vpn.example.net"), "the server's own name is never given to OpenVPN")
        for required in ["dev-node unix:/Applications/Lumen.app/Contents/MacOS/LumenTunnel", "route-noexec", "ifconfig-noexec",
                         "script-security 2", "auth-retry none", "setenv LUMEN_SOCKS_FD 3", "setenv LUMEN_STATUS_FD 4", "nobind"] {
            XCTAssertTrue(lines.contains(required), required)
        }
        for forbidden in ["route 10.0.0.0", "up ", "persist-tun", "resolv-retry", "management"] {
            XCTAssertFalse(lines.contains { $0.hasPrefix(forbidden) }, forbidden)
        }
        XCTAssertTrue(text.contains("<auth-user-pass>\nalice\npa ss\n</auth-user-pass>"))
        // OpenVPN reads it back: the same tokens, a quoted path included.
        let spaced = try configuration.runtime(forwarders: [0: 1], tunnelProgram: "/Users/me/My Apps/Lumen.app/Contents/MacOS/LumenTunnel",
                                               username: "a", password: "b", listeningDescriptor: 3, statusDescriptor: 4, verifierHex: "00")
        let devNode = spaced.components(separatedBy: "\n").first { $0.hasPrefix("dev-node") }!
        XCTAssertEqual(OpenVPNConfiguration.tokens(devNode), ["dev-node", "unix:/Users/me/My Apps/Lumen.app/Contents/MacOS/LumenTunnel"])
    }

    func testCredentialsThatWouldBreakTheirBlockAreRefused() throws {
        let configuration = try OpenVPNConfiguration.parse(Self.typical("auth-user-pass"))
        for (user, pass) in [("alice", "two\nlines"), ("al\nice", "x"), ("alice", ""), ("", "x"), ("alice", "</auth-user-pass>")] {
            XCTAssertThrowsError(try configuration.runtime(forwarders: [0: 1], tunnelProgram: "/x", username: user, password: pass,
                                                           listeningDescriptor: 3, statusDescriptor: 4, verifierHex: "00"))
        }
    }

    func testCompressionIsTakenInButNeverSentOut() throws {
        let configuration = try OpenVPNConfiguration.parse(Self.typical("comp-lzo"))
        let text = try configuration.runtime(forwarders: [0: 1], tunnelProgram: "/x", username: nil, password: nil,
                                             listeningDescriptor: 3, statusDescriptor: 4, verifierHex: "00")
        XCTAssertTrue(text.contains("allow-compression asym"))
    }

    // MARK: As a profile's proxy

    func testAnOpenVPNProxyValidatesAndCarriesItsFirstServer() throws {
        let configuration = try OpenVPNConfiguration.parse(Self.typical("auth-user-pass"))
        let proxy = ProxySettings.openVPN(configuration, username: "alice", password: "s3cret")
        XCTAssertEqual(proxy.host, "vpn.example.net")
        XCTAssertEqual(proxy.port, 1194)
        XCTAssertEqual(proxy.kind, .socks5)
        XCTAssertTrue(proxy.isOpenVPN)
        XCTAssertNoThrow(try proxy.validate())
        var withoutCredentials = proxy
        withoutCredentials.username = nil
        withoutCredentials.password = nil
        XCTAssertThrowsError(try withoutCredentials.validate())
        var moved = proxy
        moved.host = "elsewhere.example.net"
        XCTAssertThrowsError(try moved.validate())
        var broken = proxy
        broken.openVPN = OpenVPNSettings(configuration: "client\nfrobnicate\n")
        XCTAssertThrowsError(try broken.validate())
    }

    func testAProxyWithoutOpenVPNIsWrittenAsBefore() throws {
        let plain = ProxySettings(kind: .socks5, host: "proxy.example.net", port: 1080)
        let encoded = String(decoding: try JSONEncoder().encode(plain), as: UTF8.self)
        XCTAssertFalse(encoded.contains("openVPN"))
        let configuration = try OpenVPNConfiguration.parse(Self.typical())
        let vpn = ProxySettings.openVPN(configuration, username: nil, password: nil)
        let decoded = try JSONDecoder().decode(ProxySettings.self, from: try JSONEncoder().encode(vpn))
        XCTAssertEqual(decoded, vpn)
    }
}

final class OpenVPNFormatTests: XCTestCase {
    private func vpn() throws -> ProxySettings {
        ProxySettings.openVPN(try OpenVPNConfiguration.parse(OpenVPNConfigurationTests.typical()), username: nil, password: nil)
    }

    func testAProfileOnAnOpenVPNConnectionIsWrittenAsFormat2AndOthersAsBefore() throws {
        var configuration = ProfileConfiguration()
        XCTAssertEqual(configuration.format, 1)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(configuration), as: UTF8.self).contains("\"format\""))
        configuration.proxy = try vpn()
        XCTAssertEqual(configuration.format, 2)
        let json = try JSONEncoder().encode(configuration)
        XCTAssertTrue(String(decoding: json, as: UTF8.self).contains("\"format\":2"))
        // This version reads it back; a version that reads format 1 only is refused it.
        XCTAssertEqual(try ProfileRepository.decodeConfiguration(json).proxy, configuration.proxy)
        XCTAssertThrowsError(try DocumentFormat.check(json, supported: 1, what: "config.bin"))
    }

    func testAListWithAnOpenVPNConnectionIsFormat4AndTwoConfigurationsAreTwoConnections() throws {
        let plain = ProxyListEntry(proxy: ProxySettings(kind: .socks5, host: "p.example.net", port: 1080))
        XCTAssertEqual(ProxyList.format(for: [plain]), 1)
        let first = try vpn()
        XCTAssertEqual(ProxyList.format(for: [plain, ProxyListEntry(proxy: first)]), 4)
        var second = first
        second.openVPN = OpenVPNSettings(configuration: first.openVPN!.configuration.replacingOccurrences(of: "auth SHA256", with: "auth SHA512"))
        XCTAssertNotEqual(ProxyList.identity(of: first), ProxyList.identity(of: second))
        XCTAssertFalse(ProxyList.sameConnection(first, second))
    }
}

extension OpenVPNFormatTests {
    func testAnExportOfTheListDoesNotTurnAConnectionIntoAProxyLine() throws {
        let configuration = try OpenVPNConfiguration.parse(OpenVPNConfigurationTests.typical("auth-user-pass"))
        let entry = ProxyListEntry(label: "Mobile DE", proxy: ProxySettings.openVPN(configuration, username: "alice", password: "s3cret"))
        let text = ProxyList.exportText([entry])
        XCTAssertFalse(text.contains("s3cret"))
        XCTAssertFalse(text.contains("socks5://"))
        XCTAssertTrue(text.contains("# OpenVPN connection, not exported as a line: vpn.example.net:1194  (Mobile DE)"))
        XCTAssertTrue(ProxyListImport.read(text).proxies.isEmpty, "and nothing reads back from it")
    }
}
