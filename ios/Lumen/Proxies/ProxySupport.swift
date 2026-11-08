import Foundation
import LumenCore
import Network
import Security
import WebKit

/// Proxy passwords, in the Keychain (this device only, after the first unlock).
enum ProxyPasswords {
    static let service = "io.lumenbrowser.ios.proxy"

    static func set(_ password: String?, for id: UUID) {
        remove(id)
        guard let password, !password.isEmpty, !Faults.isActive(.proxyPasswordNotSaved) else { return }
        let item: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: id.uuidString,
                                     kSecValueData: Data(password.utf8), kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemAdd(item as CFDictionary, nil)
        if status != errSecSuccess { NSLog("Lumen: the Keychain refused a proxy password: \(status)") }
    }

    static func get(_ id: UUID) -> String? {
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: id.uuidString,
                                      kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func remove(_ id: UUID) {
        SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: id.uuidString] as CFDictionary)
    }

    static func removeAll() {
        SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: service] as CFDictionary)
    }
}

/// A proxy entry as Network.framework's configuration (iOS 17), which WebKit applies per data store
/// and URLSession per session. Never a fallback to a direct connection: a proxy that does not answer
/// means no page at all (measured: `allowFailover = false` sends nothing around a dead proxy).
enum ProxyFactory {
    static func make(_ entry: ProxyEntry, password: String?) -> [ProxyConfiguration] {
        let port = NWEndpoint.Port(rawValue: UInt16(clamping: max(1, entry.port))) ?? 1
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(entry.host), port: port)
        var configuration = entry.kind == .socks5
            ? ProxyConfiguration(socksv5Proxy: endpoint)
            : ProxyConfiguration(httpCONNECTProxy: endpoint, tlsOptions: nil)
        if !entry.username.isEmpty || !(password ?? "").isEmpty {
            configuration.applyCredential(username: entry.username, password: password ?? "")
        }
        configuration.allowFailover = false
        return [configuration]
    }
}

/// WebKit's content rules for a session with a proxy: no `ping` loads (dns-prefetch rides on them
/// and asks the device's own resolver, measured on iOS 26.2 and 26.5) and no page reaching this
/// device's own addresses, which the system never sends through a proxy (measured on iOS 18.6–27.2).
@MainActor
enum ContentRules {
    private(set) static var proxied: WKContentRuleList?

    static func prepare() async {
        guard proxied == nil, let url = Bundle.main.url(forResource: "proxied-rules", withExtension: "json"),
              let json = try? String(contentsOf: url, encoding: .utf8), let ruleStore = WKContentRuleListStore.default() else { return }
        let list: WKContentRuleList? = try? await ruleStore.compileContentRuleList(forIdentifier: "lumen-proxied", encodedContentRuleList: json)
        proxied = list
    }
}

/// Is a proxy alive, where does it exit (IP, country, time zone), does it relay UDP.
enum ProxyChecker {
    /// Geolocation services that need no key, asked through the proxy in turn. A test points this
    /// at its own testbed (DEBUG builds only).
    static var geoURLs: [URL] {
        #if DEBUG
        if let value = ProcessInfo.processInfo.environment["LUMEN_TEST_GEO_URL"], let url = URL(string: value) { return [url] }
        #endif
        return ["https://ipinfo.io/json", "https://get.geojs.io/v1/ip/geo.json", "https://ipwho.is/"].compactMap(URL.init(string:))
    }

    /// The STUN server asked through a SOCKS5 proxy's UDP relay.
    static var stunServer: (host: String, port: UInt16) {
        #if DEBUG
        if let value = ProcessInfo.processInfo.environment["LUMEN_TEST_STUN"], let colon = value.lastIndex(of: ":"),
           let port = UInt16(value[value.index(after: colon)...]) {
            return (String(value[..<colon]), port)
        }
        #endif
        return ("stun.l.google.com", 19302)
    }

    static func check(_ entry: ProxyEntry, password: String?) async -> ProxyCheck {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.proxyConfigurations = ProxyFactory.make(entry, password: password)
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 15
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.waitsForConnectivity = false
        let delegate = ProxyAuthAnswer(user: entry.username, password: password)
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var lastError = "нет ответа"
        for url in geoURLs {
            do {
                let (data, response) = try await session.data(from: url)
                guard (response as? HTTPURLResponse)?.statusCode == 200,
                      let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    lastError = "ответ \((response as? HTTPURLResponse)?.statusCode ?? 0)"
                    continue
                }
                let country = ((json["country"] as? String) ?? (json["country_code"] as? String))?.uppercased()
                let zone = (json["timezone"] as? String) ?? ((json["timezone"] as? [String: Any])?["id"] as? String)
                let udp = await udpSupport(entry, password: password)
                return ProxyCheck(alive: true, exitIP: json["ip"] as? String, country: country, timeZone: zone, udp: udp)
            } catch {
                lastError = (error as NSError).localizedDescription
            }
        }
        return ProxyCheck(alive: false, udp: .unchecked, error: lastError)
    }

    /// An HTTP proxy carries no UDP. A SOCKS5 one does if it grants a UDP association and a STUN
    /// Binding sent through that association is answered (RFC 1928 §7) — nothing goes around it.
    static func udpSupport(_ entry: ProxyEntry, password: String?) async -> UDPSupport {
        guard entry.kind == .socks5 else { return .unsupported }
        let probe = SOCKSUDPProbe(entry: entry, password: password, stun: stunServer)
        return await probe.run(timeout: 8)
    }
}

/// Answers a proxy's 407 with the entry's credentials, once.
final class ProxyAuthAnswer: NSObject, URLSessionTaskDelegate {
    let user: String
    let password: String?

    init(user: String, password: String?) {
        self.user = user
        self.password = password
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.isProxy(), challenge.previousFailureCount == 0, !user.isEmpty {
            completionHandler(.useCredential, URLCredential(user: user, password: password ?? "", persistence: .none))
        } else if challenge.protectionSpace.isProxy() {
            completionHandler(.cancelAuthenticationChallenge, nil)
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}

/// SOCKS5 UDP ASSOCIATE, then a STUN Binding through the relay.
final class SOCKSUDPProbe: @unchecked Sendable {
    let entry: ProxyEntry
    let password: String?
    let stun: (host: String, port: UInt16)
    private let queue = DispatchQueue(label: "lumen.udp-probe")

    init(entry: ProxyEntry, password: String?, stun: (host: String, port: UInt16)) {
        self.entry = entry
        self.password = password
        self.stun = stun
    }

    enum ProbeError: Error { case closed, refused, timeout }

    private var tcp: NWConnection?
    private var udp: NWConnection?
    private let lock = NSLock()
    private var answered = false

    /// The probe's answer, or "no UDP" when it takes longer than `timeout`: the connections are then
    /// cancelled, which ends any receive still waiting.
    func run(timeout: TimeInterval) async -> UDPSupport {
        await withCheckedContinuation { (continuation: CheckedContinuation<UDPSupport, Never>) in
            let answer: (UDPSupport) -> Void = { [self] result in
                lock.lock()
                let first = !answered
                answered = true
                lock.unlock()
                if first { continuation.resume(returning: result) }
            }
            queue.asyncAfter(deadline: .now() + timeout) { [self] in
                answer(.unsupported)
                tcp?.cancel()
                udp?.cancel()
            }
            Task { answer(await self.probe()) }
        }
    }

    private func probe() async -> UDPSupport {
        guard let port = NWEndpoint.Port(rawValue: UInt16(clamping: entry.port)) else { return .unchecked }
        let tcp = NWConnection(host: NWEndpoint.Host(entry.host), port: port, using: .tcp)
        self.tcp = tcp
        defer { tcp.cancel() }
        do {
            try await ready(tcp)
        } catch {
            return .unchecked   // the proxy is not reachable at all: nothing said about UDP
        }
        do {
            let withAuth = !entry.username.isEmpty
            try await send(tcp, Data([5, 1, withAuth ? 2 : 0]))
            let method = try await receive(tcp, 2)
            if method[1] == 2 {
                let user = Data(entry.username.utf8), pass = Data((password ?? "").utf8)
                try await send(tcp, Data([1, UInt8(user.count)]) + user + Data([UInt8(pass.count)]) + pass)
                guard try await receive(tcp, 2)[1] == 0 else { return .unchecked }
            } else if method[1] != 0 {
                return .unchecked
            }
            try await send(tcp, Data([5, 3, 0, 1, 0, 0, 0, 0, 0, 0]))
            let head = try await receive(tcp, 4)
            guard head[1] == 0 else { return .unsupported }   // UDP ASSOCIATE refused
            var relayHost = entry.host
            switch head[3] {
            case 1:
                let address = try await receive(tcp, 4)
                let text = address.map(String.init).joined(separator: ".")
                if text != "0.0.0.0" { relayHost = text }
            case 4:
                _ = try await receive(tcp, 16)
            case 3:
                let length = try await receive(tcp, 1)[0]
                relayHost = String(decoding: try await receive(tcp, Int(length)), as: UTF8.self)
            default:
                return .unsupported
            }
            let portBytes = try await receive(tcp, 2)
            let relayPort = UInt16(portBytes[0]) << 8 | UInt16(portBytes[1])
            guard let udpPort = NWEndpoint.Port(rawValue: relayPort) else { return .unsupported }
            let udp = NWConnection(host: NWEndpoint.Host(relayHost), port: udpPort, using: .udp)
            self.udp = udp
            defer { udp.cancel() }
            try await ready(udp)
            var transaction = Data(count: 12)
            for i in 0..<12 { transaction[i] = UInt8.random(in: 0...255) }
            let request = Data([0, 1, 0, 0, 0x21, 0x12, 0xA4, 0x42]) + transaction
            let host = Data(stun.host.utf8)
            let wrapped = Data([0, 0, 0, 3, UInt8(host.count)]) + host + Data([UInt8(stun.port >> 8), UInt8(stun.port & 0xff)]) + request
            for _ in 0..<3 {
                try await send(udp, wrapped)
                if let reply = try? await receiveMessage(udp), reply.count >= 30 {
                    // Skip the SOCKS5 UDP header (10 bytes for an IPv4 source) to the STUN message.
                    let start = reply[3] == 1 ? 10 : (reply[3] == 4 ? 22 : 7 + Int(reply[4]))
                    if reply.count >= start + 20, reply[start] == 0x01, reply[start + 1] == 0x01,
                       reply.subdata(in: (start + 8)..<(start + 20)) == transaction {
                        return .supported
                    }
                }
            }
            return .unsupported
        } catch {
            return .unsupported
        }
    }

    private func ready(_ connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var done = false
            connection.stateUpdateHandler = { state in
                guard !done else { return }
                switch state {
                case .ready: done = true; continuation.resume()
                case .failed, .cancelled: done = true; continuation.resume(throwing: ProbeError.refused)
                case .waiting: done = true; continuation.resume(throwing: ProbeError.refused)
                default: break
                }
            }
            connection.start(queue: queue)
        }
    }

    private func send(_ connection: NWConnection, _ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }

    private func receive(_ connection: NWConnection, _ count: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            connection.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, _, error in
                if let error { continuation.resume(throwing: error) }
                else if let data, data.count == count { continuation.resume(returning: data) }
                else { continuation.resume(throwing: ProbeError.closed) }
            }
        }
    }

    private func receiveMessage(_ connection: NWConnection) async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            connection.receiveMessage { data, _, _, error in
                if let error { continuation.resume(throwing: error) }
                else if let data { continuation.resume(returning: data) }
                else { continuation.resume(throwing: ProbeError.closed) }
            }
        }
    }
}
