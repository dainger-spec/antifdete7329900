#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import XCTest
@testable import BrowserCore

/// The probe (`ProxyProbe`) against real servers on the loopback interface, one per way a proxy
/// can behave — the states the Proxies screen must tell apart: a silent proxy (today's case: the
/// port open, no handshake), one that closes at once, a refused port, a name that does not resolve,
/// SOCKS5 and HTTP proxies with and without a login, right and wrong credentials, a proxy that
/// cannot reach the site, an HTTP proxy that refuses this Mac (403), a port that speaks both, and
/// something that is no proxy at all.
final class ProxyProbeTests: XCTestCase {
    /// Short timeouts: the servers are on this machine.
    let probe = ProxyProbe(targetHost: "geo.probe.invalid", targetPort: 443,
                           timeouts: .init(resolve: 3, connect: 2, answer: 1.5, grace: 0.5), latencySamples: 3)

    private func proxy(_ kind: ProxySettings.Kind, _ server: FakeProxyServer, user: String? = nil, password: String? = nil) -> ProxySettings {
        ProxySettings(kind: kind, host: "127.0.0.1", port: server.port, username: user, password: password)
    }

    // MARK: The states that must differ

    func testTodaysCaseAPortThatTakesTheConnectionAndSaysNothingIsSilent() throws {
        let server = try FakeProxyServer(.silent)
        defer { server.stop() }
        for kind in ProxySettings.Kind.allCases {
            let diagnosis = probe.runNow(proxy(kind, server, user: "u", password: "p"))
            XCTAssertEqual(diagnosis.verdict, .silent, "\(kind)")
            XCTAssertEqual(diagnosis.failedStep, 3)
            XCTAssertEqual(diagnosis.connectedAddress, "127.0.0.1")
            XCTAssertTrue(diagnosis.kinds.isEmpty)
        }
    }

    func testAPortThatClosesAtOnceIsToldFromASilentOne() throws {
        let server = try FakeProxyServer(.closeAtOnce)
        defer { server.stop() }
        XCTAssertEqual(probe.runNow(proxy(.socks5, server)).verdict, .closedWithoutAnswer)
    }

    func testARefusedConnectionAndANameThatDoesNotResolve() throws {
        let port = try FakeProxyServer.closedPort()
        let refused = probe.runNow(ProxySettings(kind: .socks5, host: "127.0.0.1", port: port))
        XCTAssertEqual(refused.verdict, .refused)
        XCTAssertEqual(refused.failedStep, 2)
        let unknown = probe.runNow(ProxySettings(kind: .httpConnect, host: "no-such-proxy.invalid", port: 1080))
        // A resolver that cannot be asked at all (no network) is said apart from a name it does not know.
        XCTAssertTrue([.hostNotFound, .resolverFailed].contains(unknown.verdict), "\(unknown)")
        XCTAssertEqual(unknown.failedStep, 1)
    }

    func testSomethingThatIsNoProxyIsSaidSoWithWhatItAnswered() throws {
        let server = try FakeProxyServer(.banner("SSH-2.0-OpenSSH_9.6\r\n"))
        defer { server.stop() }
        let diagnosis = probe.runNow(proxy(.socks5, server))
        XCTAssertEqual(diagnosis.verdict, .notAProxy)
        XCTAssertEqual(diagnosis.answer, "SSH-2.0-OpenSSH_9.6")
    }

    // MARK: SOCKS5

    func testASOCKS5ProxyIsFoundWhateverTheListSaysAndTheTargetIsNamedToIt() throws {
        let server = try FakeProxyServer(.socks5(login: nil))
        defer { server.stop() }
        // Listed as HTTP: the probe finds what it is.
        let diagnosis = probe.runNow(proxy(.httpConnect, server))
        XCTAssertEqual(diagnosis.verdict, .works)
        XCTAssertEqual(diagnosis.kinds, [.socks5])
        XCTAssertEqual(diagnosis.authentication, .notRequired)
        XCTAssertEqual(diagnosis.latencyAttempts, 3)
        XCTAssertEqual(diagnosis.latencies.count, 3, "\(diagnosis)")
        XCTAssertNotNil(diagnosis.medianLatency)
        // The target goes to the proxy by name (address type 3): this Mac resolves nothing of it.
        XCTAssertTrue(server.socksTargets.allSatisfy { $0 == "3 geo.probe.invalid:443" }, "\(server.socksTargets)")
        XCTAssertFalse(server.socksTargets.isEmpty)
    }

    func testASOCKS5LoginIsNeededTakenOrRefused() throws {
        let server = try FakeProxyServer(.socks5(login: ("pb-user", "pb-pass")))
        defer { server.stop() }
        let none = probe.runNow(proxy(.socks5, server))
        XCTAssertEqual(none.verdict, .credentialsNeeded)
        XCTAssertEqual(none.authentication, .missing)
        XCTAssertEqual(none.kinds, [.socks5])
        let wrong = probe.runNow(proxy(.socks5, server, user: "pb-user", password: "nope"))
        XCTAssertEqual(wrong.verdict, .credentialsRejected)
        XCTAssertEqual(wrong.authentication, .rejected)
        XCTAssertEqual(wrong.failedStep, 4)
        let right = probe.runNow(proxy(.socks5, server, user: "pb-user", password: "pb-pass"))
        XCTAssertEqual(right.verdict, .works)
        XCTAssertEqual(right.authentication, .accepted)
        // The password is the proxy's to know: it is in no part of the diagnosis.
        let encoded = String(decoding: try JSONEncoder().encode([none, wrong, right]), as: UTF8.self)
        XCTAssertFalse(encoded.contains("pb-pass") || encoded.contains("nope") || encoded.contains("pb-user"), encoded)
    }

    func testASOCKS5ProxyThatCannotReachTheSiteOrSaysNothingAfterTheLogin() throws {
        let refusing = try FakeProxyServer(.socks5(login: nil, connectReply: 0x05))
        defer { refusing.stop() }
        let refused = probe.runNow(proxy(.socks5, refusing))
        XCTAssertEqual(refused.verdict, .noUpstream)
        XCTAssertEqual(refused.answer, "SOCKS5 reply 0x05: connection refused")
        XCTAssertEqual(refused.failedStep, 5)
        let stalling = try FakeProxyServer(.socks5(login: nil, silentAfterGreeting: true))
        defer { stalling.stop() }
        XCTAssertEqual(probe.runNow(proxy(.socks5, stalling)).verdict, .noUpstream)
    }

    // MARK: HTTP CONNECT

    func testAnHTTPProxyIsFoundAndItsLoginIsNeededTakenOrRefused() throws {
        let open = try FakeProxyServer(.http(login: nil, status: 200))
        defer { open.stop() }
        let works = probe.runNow(proxy(.socks5, open))
        XCTAssertEqual(works.verdict, .works)
        XCTAssertEqual(works.kinds, [.httpConnect])
        XCTAssertEqual(works.answer, "HTTP/1.1 200 Connection Established")
        XCTAssertTrue(open.httpTargets.allSatisfy { $0 == "geo.probe.invalid:443" }, "\(open.httpTargets)")

        let guarded = try FakeProxyServer(.http(login: ("pb-user", "pb-pass"), status: 200))
        defer { guarded.stop() }
        XCTAssertEqual(probe.runNow(proxy(.httpConnect, guarded)).verdict, .credentialsNeeded)
        let wrong = probe.runNow(proxy(.httpConnect, guarded, user: "pb-user", password: "wrong"))
        XCTAssertEqual(wrong.verdict, .credentialsRejected)
        XCTAssertEqual(wrong.answer, "HTTP/1.1 407 Proxy Authentication Required")
        let right = probe.runNow(proxy(.httpConnect, guarded, user: "pb-user", password: "pb-pass"))
        XCTAssertEqual(right.verdict, .works)
        XCTAssertEqual(right.authentication, .accepted)
    }

    func testAnHTTPProxyThatRefusesThisMacOrCannotReachTheSiteOrIsNoProxy() throws {
        let forbidding = try FakeProxyServer(.http(login: nil, status: 403))
        defer { forbidding.stop() }
        let forbidden = probe.runNow(proxy(.httpConnect, forbidding))
        XCTAssertEqual(forbidden.verdict, .refusedByProxy)
        XCTAssertEqual(forbidden.answer, "HTTP/1.1 403 Forbidden")
        let gateway = try FakeProxyServer(.http(login: nil, status: 502))
        defer { gateway.stop() }
        XCTAssertEqual(probe.runNow(proxy(.httpConnect, gateway)).verdict, .noUpstream)
        let webServer = try FakeProxyServer(.http(login: nil, status: 405))
        defer { webServer.stop() }
        XCTAssertEqual(probe.runNow(proxy(.httpConnect, webServer)).verdict, .notAProxy)
    }

    func testAPortThatSpeaksBothListsBothTheListedTypeFirst() throws {
        let server = try FakeProxyServer(.mixed)
        defer { server.stop() }
        XCTAssertEqual(probe.runNow(proxy(.httpConnect, server)).kinds, [.httpConnect, .socks5])
        XCTAssertEqual(probe.runNow(proxy(.socks5, server)).kinds, [.socks5, .httpConnect])
    }

    func testATLSProxyIsOnlyConnectedTo() throws {
        let server = try FakeProxyServer(.silent)
        defer { server.stop() }
        var tls = proxy(.httpConnect, server)
        tls.tlsToProxy = true
        let diagnosis = probe.runNow(tls)
        XCTAssertEqual(diagnosis.verdict, .reachable)
        XCTAssertTrue(diagnosis.isWorking)
    }

    // MARK: Pieces

    func testMedianAndTolerantDecoding() throws {
        XCTAssertEqual(ProxyDiagnosis(verdict: .works, latencies: [300, 100, 200]).medianLatency, 200)
        XCTAssertEqual(ProxyDiagnosis(verdict: .works, latencies: [300, 100]).medianLatency, 100)
        XCTAssertNil(ProxyDiagnosis(verdict: .works).medianLatency)
        let later = Data(#"{"verdict":"somethingNew","kinds":["socks5"],"latencies":[5]}"#.utf8)
        let read = try JSONDecoder().decode(ProxyDiagnosis.self, from: later)
        XCTAssertEqual(read.verdict, .silent)
        XCTAssertEqual(read.kinds, [.socks5])
    }

    func testWirePieces() {
        XCTAssertEqual(ProxyProbe.statusCode("HTTP/1.1 407 Proxy Authentication Required"), 407)
        XCTAssertNil(ProxyProbe.statusCode("SSH-2.0-OpenSSH"))
        XCTAssertEqual(ProxyProbe.authority("2001:db8::1", 443), "[2001:db8::1]:443")
        XCTAssertEqual(ProxyProbe.ipv4Bytes("203.0.113.5"), [203, 0, 113, 5])
        XCTAssertNil(ProxyProbe.ipv4Bytes("geo.example"))
        XCTAssertEqual(ProxyProbe.printable(Data([0x16, 0x03, 0x01]), more: nil), "16 03 01")
    }
}

// MARK: - A proxy on the loopback interface that behaves as told

final class FakeProxyServer: @unchecked Sendable {
    enum Behavior {
        /// Takes the connection and says nothing, ever.
        case silent
        /// Takes the connection and closes it.
        case closeAtOnce
        /// Says `text` and nothing more.
        case banner(String)
        /// A SOCKS5 proxy: with a login when `login` is set; its answer to CONNECT is `connectReply`,
        /// or none after the greeting when `silentAfterGreeting`.
        case socks5(login: (String, String)?, connectReply: UInt8 = 0x00, silentAfterGreeting: Bool = false)
        /// An HTTP proxy: 407 without the right `login`, `status` to CONNECT otherwise.
        case http(login: (String, String)?, status: Int)
        /// SOCKS5 and HTTP on the same port, without logins.
        case mixed
    }

    let behavior: Behavior
    private(set) var port = 0
    private let listener: Int32
    private let lock = NSLock()
    private var open: [Int32] = []
    private var stopped = false
    private var _socksTargets: [String] = []
    private var _httpTargets: [String] = []

    var socksTargets: [String] { lock.withLock { _socksTargets } }
    var httpTargets: [String] { lock.withLock { _httpTargets } }

    init(_ behavior: Behavior) throws {
        self.behavior = behavior
        listener = socket(AF_INET, Self.stream, 0)
        guard listener >= 0 else { throw POSIXError(.EIO) }
        var one: Int32 = 1
        setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        var address = Self.loopback(port: 0)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(listener, 16) == 0 else { throw POSIXError(.EADDRINUSE) }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listener, $0, &length) }
        }
        port = Int(UInt16(bigEndian: address.sin_port))
        Thread { [self] in acceptLoop() }.start()
    }

    /// A port nothing listens on (bound, then let go).
    static func closedPort() throws -> Int {
        let server = try FakeProxyServer(.silent)
        let port = server.port
        server.stop()
        return port
    }

    func stop() {
        let toClose: [Int32] = lock.withLock {
            stopped = true
            let all = open
            open = []
            return all
        }
        _ = shutdown(listener, Self.both)
        _ = Self.close(listener)
        for descriptor in toClose {
            _ = shutdown(descriptor, Self.both)
            _ = Self.close(descriptor)
        }
    }

    private func acceptLoop() {
        while true {
            let client = accept(listener, nil, nil)
            guard client >= 0 else { return }
            let keep: Bool = lock.withLock {
                guard !stopped else { return false }
                open.append(client)
                return true
            }
            guard keep else { _ = Self.close(client); return }
            Thread { [self] in serve(client) }.start()
        }
    }

    private func serve(_ client: Int32) {
        switch behavior {
        case .silent:
            return // held open until stop()
        case .closeAtOnce:
            finish(client)
        case .banner(let text):
            write(client, Array(text.utf8))
        case let .socks5(login, connectReply, silent):
            guard let first = read(client, 1)?.first else { return finish(client) }
            guard first == 0x05 else { return finish(client) }
            socks(client, login: login, connectReply: connectReply, silent: silent)
        case let .http(login, status):
            guard let first = read(client, 1)?.first else { return finish(client) }
            guard first != 0x05 else { return } // a SOCKS5 greeting: a real HTTP proxy waits for more
            http(client, first: first, login: login, status: status)
        case .mixed:
            guard let first = read(client, 1)?.first else { return finish(client) }
            if first == 0x05 { socks(client, login: nil, connectReply: 0, silent: false) } else { http(client, first: first, login: nil, status: 200) }
        }
    }

    private func socks(_ client: Int32, login: (String, String)?, connectReply: UInt8, silent: Bool) {
        guard let count = read(client, 1)?.first, let methods = read(client, Int(count)) else { return finish(client) }
        if let login {
            guard methods.contains(0x02) else { write(client, [0x05, 0xFF]); return finish(client) }
            write(client, [0x05, 0x02])
            guard let header = read(client, 2), let user = read(client, Int(header[1])),
                  let passwordLength = read(client, 1)?.first, let password = read(client, Int(passwordLength)) else { return finish(client) }
            guard String(decoding: user, as: UTF8.self) == login.0, String(decoding: password, as: UTF8.self) == login.1 else {
                write(client, [0x01, 0x01])
                return finish(client)
            }
            write(client, [0x01, 0x00])
        } else {
            write(client, [0x05, 0x00])
        }
        guard let request = read(client, 4) else { return finish(client) }
        var target = "\(request[3]) "
        switch request[3] {
        case 0x01:
            guard let address = read(client, 4) else { return finish(client) }
            target += address.map(String.init).joined(separator: ".")
        case 0x03:
            guard let length = read(client, 1)?.first, let name = read(client, Int(length)) else { return finish(client) }
            target += String(decoding: name, as: UTF8.self)
        default:
            return finish(client)
        }
        guard let port = read(client, 2) else { return finish(client) }
        target += ":\(Int(port[0]) << 8 | Int(port[1]))"
        lock.withLock { _socksTargets.append(target) }
        if silent { return }
        write(client, [0x05, connectReply, 0x00, 0x01, 0, 0, 0, 0, 0, 0])
        finish(client)
    }

    private func http(_ client: Int32, first: UInt8, login: (String, String)?, status: Int) {
        var head = [first]
        while !head.suffix(4).elementsEqual(Array("\r\n\r\n".utf8)) && head.count < 8192 {
            guard let byte = read(client, 1) else { return finish(client) }
            head += byte
        }
        let text = String(decoding: head, as: UTF8.self)
        let lines = text.components(separatedBy: "\r\n")
        let target = lines.first?.split(separator: " ").dropFirst().first.map(String.init) ?? "?"
        lock.withLock { _httpTargets.append(target) }
        if let login {
            let expected = "Basic " + Data("\(login.0):\(login.1)".utf8).base64EncodedString()
            let given = lines.first { $0.lowercased().hasPrefix("proxy-authorization:") }?
                .split(separator: ":", maxSplits: 1).last.map { $0.trimmingCharacters(in: .whitespaces) }
            guard given == expected else {
                write(client, Array("HTTP/1.1 407 Proxy Authentication Required\r\nProxy-Authenticate: Basic realm=\"t\"\r\nContent-Length: 0\r\n\r\n".utf8))
                return finish(client)
            }
        }
        let reason = [200: "Connection Established", 403: "Forbidden", 405: "Method Not Allowed", 502: "Bad Gateway"][status] ?? "Status"
        write(client, Array("HTTP/1.1 \(status) \(reason)\r\n\r\n".utf8))
        finish(client)
    }

    private func read(_ client: Int32, _ count: Int) -> [UInt8]? {
        guard count > 0 else { return [] }
        var buffer = [UInt8](repeating: 0, count: count)
        var got = 0
        while got < count {
            let n = buffer.withUnsafeMutableBytes { recv(client, $0.baseAddress!.advanced(by: got), count - got, 0) }
            guard n > 0 else { return nil }
            got += n
        }
        return buffer
    }

    private func write(_ client: Int32, _ bytes: [UInt8]) {
        _ = bytes.withUnsafeBytes { Self.send(client, $0.baseAddress!, bytes.count) }
    }

    private func finish(_ client: Int32) {
        let mine: Bool = lock.withLock {
            guard let index = open.firstIndex(of: client) else { return false }
            open.remove(at: index)
            return true
        }
        if mine { _ = Self.close(client) }
    }

    private static func loopback(port: UInt16) -> sockaddr_in {
        var address = sockaddr_in()
        #if canImport(Darwin)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        return address
    }

    #if canImport(Darwin)
    private static let stream = SOCK_STREAM
    private static let both = SHUT_RDWR
    private static func close(_ descriptor: Int32) -> Int32 { Darwin.close(descriptor) }
    private static func send(_ descriptor: Int32, _ bytes: UnsafeRawPointer, _ count: Int) -> Int { Darwin.send(descriptor, bytes, count, 0) }
    #else
    private static let stream = Int32(SOCK_STREAM.rawValue)
    private static let both = Int32(SHUT_RDWR)
    private static func close(_ descriptor: Int32) -> Int32 { Glibc.close(descriptor) }
    private static func send(_ descriptor: Int32, _ bytes: UnsafeRawPointer, _ count: Int) -> Int {
        Glibc.send(descriptor, bytes, count, Int32(MSG_NOSIGNAL))
    }
    #endif
}
