import Foundation

/// Asks a proxy, one step at a time, what it is and whether it works (`ProxyDiagnosis`):
///
///   1. its name, resolved (an IP address is taken as it is);
///   2. a TCP connection to it;
///   3. a handshake as a SOCKS5 proxy and, on another connection at the same time, as an HTTP
///      proxy (CONNECT) — whichever answers is what it is, whatever the list says;
///   4. the login, when it asks for one (SOCKS5's RFC 1929, HTTP's `Proxy-Authorization: Basic`);
///   5. a tunnel to `target` (CONNECT): can it reach a site at all;
///   6. two more tunnels the same way, for a median latency and how steady it is.
///
/// Every connection goes to the proxy and nowhere else: the target is named to the proxy, which
/// resolves it and connects to it (SOCKS5 address type 3, HTTP CONNECT host name), so nothing about
/// the target is looked up or reached from this Mac. The only thing this Mac asks anyone but the
/// proxy is its resolver, for the proxy's own name — as anything using the proxy has to.
///
/// The user name and password go to the proxy, as a profile would send them, and nowhere else:
/// not into the diagnosis, a log line or an error.
///
/// A proxy spoken to through TLS (`https://`) is only connected to: its handshake is inside TLS,
/// which the checker's request through it covers (`Verdict.reachable`).
public struct ProxyProbe: Sendable {
    public struct Timeouts: Sendable {
        /// For the resolver's answer.
        public var resolve: TimeInterval
        /// For a TCP connection to be taken.
        public var connect: TimeInterval
        /// For each answer of the handshake, the login and the tunnel.
        public var answer: TimeInterval
        /// Once one handshake has answered, how much longer the other gets (a port that speaks both).
        public var grace: TimeInterval

        public init(resolve: TimeInterval = 5, connect: TimeInterval = 5, answer: TimeInterval = 5, grace: TimeInterval = 1) {
            self.resolve = resolve
            self.connect = connect
            self.answer = answer
            self.grace = grace
        }
    }

    /// What the tunnel asks the proxy to connect to: a site the checker then asks through it.
    public var targetHost: String
    public var targetPort: Int
    public var timeouts: Timeouts
    /// Tunnels set up for the latency (the one of step 5 among them).
    public var latencySamples: Int
    /// Sent with the HTTP handshake, as a browser's would be.
    public var userAgent: String

    public init(targetHost: String, targetPort: Int = 443, timeouts: Timeouts = Timeouts(), latencySamples: Int = 3,
                userAgent: String = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko)") {
        self.targetHost = targetHost
        self.targetPort = targetPort
        self.timeouts = timeouts
        self.latencySamples = max(1, latencySamples)
        self.userAgent = userAgent
    }

    /// The diagnosis, off the caller's thread.
    public func run(_ proxy: ProxySettings) async -> ProxyDiagnosis {
        await withCheckedContinuation { continuation in
            Thread {
                continuation.resume(returning: self.runNow(proxy))
            }.start()
        }
    }

    /// The diagnosis, on this thread (it waits on the network: never call it on the main thread).
    public func runNow(_ proxy: ProxySettings) -> ProxyDiagnosis {
        // 1. The name.
        let addresses: [ProbeSocket.Address]
        switch ProbeSocket.resolve(proxy.host, port: proxy.port, timeout: timeouts.resolve) {
        case .notFound: return ProxyDiagnosis(verdict: .hostNotFound)
        case .failed(let reason): return ProxyDiagnosis(verdict: .resolverFailed, answer: reason)
        case .addresses(let found): addresses = found
        }

        // 2. A connection: the first address that takes one.
        var failures: [ProbeSocket.ConnectFailure] = []
        var reached: ProbeSocket.Address?
        for address in addresses.prefix(4) {
            switch ProbeSocket.connect(to: address, timeout: timeouts.connect) {
            case .success(let connection):
                connection.close()
                reached = address
            case .failure(let failure):
                failures.append(failure)
            }
            if reached != nil { break }
        }
        guard let address = reached else {
            if failures.contains(.refused) { return ProxyDiagnosis(verdict: .refused) }
            if failures.contains(.unreachable) { return ProxyDiagnosis(verdict: .unreachable) }
            if case .other(let number)? = failures.first(where: { if case .other = $0 { return true } else { return false } }) {
                return ProxyDiagnosis(verdict: .unreachable, answer: String(cString: strerror(number)))
            }
            return ProxyDiagnosis(verdict: .connectTimeout)
        }
        if proxy.kind == .httpConnect && proxy.tlsToProxy {
            return ProxyDiagnosis(verdict: .reachable, kinds: [.httpConnect], connectedAddress: address.text)
        }

        // 3–5. Both handshakes at once, each on its own connection.
        let (socks, http) = attempts(on: address, proxy: proxy)
        var diagnosis = Self.verdict(socks: socks, http: http, preferred: proxy.kind, hasCredentials: proxy.username != nil)
        diagnosis.connectedAddress = address.text

        // 6. The latency: the first tunnel's, and more of the same kind.
        if diagnosis.verdict == .works, let kind = diagnosis.kinds.first {
            var samples: [Int] = []
            if let first = [socks, http].compactMap({ $0.confirmed }).first(where: { $0.kind == kind && $0.tunnel == .open }) {
                samples.append(first.milliseconds)
            }
            for _ in samples.count..<latencySamples {
                let attempt = kind == .socks5 ? socksAttempt(on: address, proxy: proxy, token: nil)
                                              : httpAttempt(on: address, proxy: proxy, token: nil)
                if let confirmed = attempt.confirmed, confirmed.tunnel == .open { samples.append(confirmed.milliseconds) }
            }
            diagnosis.latencies = samples
            diagnosis.latencyAttempts = latencySamples
        }
        return diagnosis
    }

    // MARK: The two handshakes

    /// What one handshake found.
    enum Attempt: Equatable {
        case confirmed(Confirmed)
        /// Connected, and nothing came back in time.
        case silent
        /// Connected, and closed without a byte.
        case closed
        /// Something else answered (its first bytes, printable).
        case other(String)
        /// This connection was not taken (the first one was): said as the connection's failure.
        case noConnection(ProbeSocket.ConnectFailure)
        case cancelled

        var confirmed: Confirmed? {
            if case .confirmed(let confirmed) = self { return confirmed }
            return nil
        }
    }

    enum Tunnel: Equatable {
        /// The proxy connected to the target.
        case open
        /// It answered that it would not, or could not (`answer`).
        case refused
        /// It said nothing more after the login.
        case silent
        /// It closed the connection instead.
        case closed
        /// Not asked: the login failed first.
        case notTried
    }

    struct Confirmed: Equatable {
        var kind: ProxySettings.Kind
        var authentication: ProxyDiagnosis.Authentication
        var tunnel: Tunnel
        /// What the proxy said, where it says why (an HTTP status line, a SOCKS5 reply).
        var answer: String?
        /// From the start of the connection to the tunnel's answer.
        var milliseconds: Int
        /// An HTTP status code, when the proxy is an HTTP one.
        var status: Int?
    }

    /// Cancels the handshake still waiting once the other has answered and its grace is over.
    final class Token: @unchecked Sendable {
        private let lock = NSLock()
        private var connection: ProbeSocket.Connection?
        private var isCancelled = false

        func hold(_ connection: ProbeSocket.Connection) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if isCancelled { connection.cancel(); return false }
            self.connection = connection
            return true
        }

        func cancel() {
            lock.lock()
            defer { lock.unlock() }
            isCancelled = true
            connection?.cancel()
        }

        var cancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return isCancelled
        }
    }

    private func attempts(on address: ProbeSocket.Address, proxy: ProxySettings) -> (socks: Attempt, http: Attempt) {
        let socksBox = ResultBox<Attempt>(), httpBox = ResultBox<Attempt>()
        let socksToken = Token(), httpToken = Token()
        let finished = DispatchSemaphore(value: 0)
        Thread {
            socksBox.set(self.socksAttempt(on: address, proxy: proxy, token: socksToken))
            finished.signal()
        }.start()
        Thread {
            httpBox.set(self.httpAttempt(on: address, proxy: proxy, token: httpToken))
            finished.signal()
        }.start()
        finished.wait()
        // One has finished. A handshake that confirmed a proxy gives the other a moment more, then
        // stops it; anything else waits for the other's own timeouts.
        let firstConfirmed = socksBox.current?.confirmed != nil || httpBox.current?.confirmed != nil
        if firstConfirmed {
            if finished.wait(timeout: .now() + timeouts.grace) == .timedOut {
                socksToken.cancel()
                httpToken.cancel()
                finished.wait()
            }
        } else {
            finished.wait()
        }
        return (socksBox.current ?? .cancelled, httpBox.current ?? .cancelled)
    }

    private func open(_ address: ProbeSocket.Address, token: Token?) -> Result<ProbeSocket.Connection, ProbeSocket.ConnectFailure> {
        switch ProbeSocket.connect(to: address, timeout: timeouts.connect) {
        case .success(let connection):
            if let token, !token.hold(connection) { return .failure(.other(ECANCELED)) }
            return .success(connection)
        case .failure(let failure):
            return .failure(failure)
        }
    }

    func socksAttempt(on address: ProbeSocket.Address, proxy: ProxySettings, token: Token?) -> Attempt {
        let started = ProbeClock.now
        let connection: ProbeSocket.Connection
        switch open(address, token: token) {
        case .success(let opened): connection = opened
        case .failure(let failure): return token?.cancelled == true ? .cancelled : .noConnection(failure)
        }
        defer { connection.close() }
        let deadline = { ProbeClock.now + self.timeouts.answer }
        let credentials = Self.credentials(proxy)
        // Greeting: no authentication, and user name/password when there is one to give.
        let methods: [UInt8] = credentials == nil ? [0x00] : [0x00, 0x02]
        guard connection.send(Data([0x05, UInt8(methods.count)] + methods), before: deadline()) else {
            return token?.cancelled == true ? .cancelled : .closed
        }
        let (greeting, received) = connection.receive(exactly: 2, before: deadline())
        if let early = Self.noHandshake(greeting, received: received, connection: connection) {
            return token?.cancelled == true ? .cancelled : early
        }
        guard received[received.startIndex] == 0x05 else { return .other(Self.printable(received, more: connection)) }
        func confirmed(_ authentication: ProxyDiagnosis.Authentication, _ tunnel: Tunnel, _ answer: String? = nil) -> Attempt {
            .confirmed(Confirmed(kind: .socks5, authentication: authentication, tunnel: tunnel, answer: answer,
                                 milliseconds: Self.milliseconds(since: started), status: nil))
        }
        var authentication = ProxyDiagnosis.Authentication.notRequired
        switch received[received.startIndex + 1] {
        case 0x00:
            authentication = .notRequired
        case 0x02:
            guard let credentials else { return confirmed(.missing, .notTried) }
            let user = Array(credentials.user.utf8), password = Array(credentials.password.utf8)
            guard user.count <= 255, password.count <= 255 else {
                return confirmed(.rejected, .notTried, "SOCKS5: the user name or password is longer than 255 bytes")
            }
            let login = Data([0x01, UInt8(user.count)] + user + [UInt8(password.count)] + password)
            guard connection.send(login, before: deadline()) else { return confirmed(.rejected, .notTried, "SOCKS5: closed at the login") }
            let (status, reply) = connection.receive(exactly: 2, before: deadline())
            guard case .data = status else {
                return confirmed(.rejected, .notTried, status == .timedOut ? "SOCKS5: no answer to the login" : "SOCKS5: closed at the login")
            }
            guard reply[reply.startIndex + 1] == 0x00 else { return confirmed(.rejected, .notTried) }
            authentication = .accepted
        case 0xFF:
            // None of the methods offered: it wants a login and none was given, or one this probe
            // does not speak.
            return confirmed(credentials == nil ? .missing : .rejected, .notTried,
                             credentials == nil ? nil : "SOCKS5: no acceptable authentication method")
        case let method:
            return .other("SOCKS5 method 0x\(String(format: "%02X", Int(method)))")
        }

        // The tunnel: CONNECT to the target, named (the proxy resolves it).
        var request: [UInt8] = [0x05, 0x01, 0x00]
        let host = Array(targetHost.utf8)
        if let literal = Self.ipv4Bytes(targetHost) {
            request += [0x01] + literal
        } else if host.count <= 255 {
            request += [0x03, UInt8(host.count)] + host
        } else {
            return confirmed(authentication, .notTried, "the target's name is too long")
        }
        request += [UInt8(targetPort >> 8), UInt8(targetPort & 0xFF)]
        guard connection.send(Data(request), before: deadline()) else { return confirmed(authentication, .closed) }
        let (status, reply) = connection.receive(exactly: 2, before: deadline())
        switch status {
        case .data:
            let code = reply[reply.startIndex + 1]
            return code == 0x00 ? confirmed(authentication, .open) : confirmed(authentication, .refused, Self.socksReply(code))
        case .timedOut:
            return confirmed(authentication, .silent)
        default:
            return confirmed(authentication, .closed)
        }
    }

    func httpAttempt(on address: ProbeSocket.Address, proxy: ProxySettings, token: Token?) -> Attempt {
        let started = ProbeClock.now
        let connection: ProbeSocket.Connection
        switch open(address, token: token) {
        case .success(let opened): connection = opened
        case .failure(let failure): return token?.cancelled == true ? .cancelled : .noConnection(failure)
        }
        defer { connection.close() }
        let deadline = ProbeClock.now + timeouts.answer
        let target = Self.authority(targetHost, targetPort)
        var request = "CONNECT \(target) HTTP/1.1\r\nHost: \(target)\r\nUser-Agent: \(userAgent)\r\nProxy-Connection: keep-alive\r\n"
        let credentials = Self.credentials(proxy)
        if let credentials {
            request += "Proxy-Authorization: Basic \(Data("\(credentials.user):\(credentials.password)".utf8).base64EncodedString())\r\n"
        }
        request += "\r\n"
        guard connection.send(Data(request.utf8), before: deadline) else {
            return token?.cancelled == true ? .cancelled : .closed
        }
        let (status, head) = connection.receive(until: Data("\r\n\r\n".utf8), limit: 8192, before: deadline)
        if head.isEmpty {
            if token?.cancelled == true { return .cancelled }
            switch status {
            case .timedOut: return .silent
            default: return .closed
            }
        }
        guard let line = Self.statusLine(head), let code = Self.statusCode(line) else {
            // SOCKS5 answers the first bytes of "CONNECT" with a version it does not know, or closes.
            return .other(Self.printable(head, more: nil))
        }
        let elapsed = Self.milliseconds(since: started)
        let authentication: ProxyDiagnosis.Authentication
        let tunnel: Tunnel
        switch code {
        case 200..<300:
            authentication = credentials == nil ? .notRequired : .accepted
            tunnel = .open
        case 407:
            authentication = credentials == nil ? .missing : .rejected
            tunnel = .notTried
        default:
            authentication = credentials == nil ? .notRequired : .accepted
            tunnel = .refused
        }
        return .confirmed(Confirmed(kind: .httpConnect, authentication: authentication, tunnel: tunnel, answer: line,
                                    milliseconds: elapsed, status: code))
    }

    /// Nil when two bytes came; otherwise what not getting them means.
    private static func noHandshake(_ status: ProbeSocket.Connection.Received, received: Data,
                                    connection: ProbeSocket.Connection) -> Attempt? {
        switch status {
        case .data: return nil
        case .timedOut: return received.isEmpty ? .silent : .other(printable(received, more: nil))
        case .closed, .failed: return received.isEmpty ? .closed : .other(printable(received, more: nil))
        }
    }

    // MARK: The verdict

    /// What the two handshakes say together. `preferred` is the type the list has for the proxy:
    /// when both answer, it comes first.
    static func verdict(socks: Attempt, http: Attempt, preferred: ProxySettings.Kind, hasCredentials: Bool) -> ProxyDiagnosis {
        let confirmed = [socks.confirmed, http.confirmed].compactMap { $0 }
        if !confirmed.isEmpty {
            // The most useful answer first: one that went through, then the preferred type.
            func rank(_ c: Confirmed) -> Int {
                switch (c.tunnel, c.authentication) {
                case (.open, _): return 0
                case (.refused, _), (.silent, _), (.closed, _): return 1
                case (.notTried, .rejected), (.notTried, .missing): return 2
                default: return 3
                }
            }
            let ordered = confirmed.sorted {
                (rank($0), $0.kind == preferred ? 0 : 1) < (rank($1), $1.kind == preferred ? 0 : 1)
            }
            let best = ordered[0]
            let kinds = ordered.map(\.kind)
            var diagnosis = ProxyDiagnosis(verdict: .works, kinds: kinds, authentication: best.authentication, answer: best.answer)
            switch (best.tunnel, best.authentication) {
            case (.open, _):
                diagnosis.verdict = .works
            case (_, .missing):
                diagnosis.verdict = .credentialsNeeded
            case (_, .rejected):
                diagnosis.verdict = .credentialsRejected
            case (.refused, _) where best.status == 403:
                diagnosis.verdict = .refusedByProxy
            case (.refused, _) where best.status.map({ [400, 405, 501].contains($0) }) == true:
                // An HTTP server that is not a proxy (it does not take CONNECT).
                diagnosis.verdict = .notAProxy
            default:
                diagnosis.verdict = .noUpstream
            }
            return diagnosis
        }
        let outcomes = [socks, http]
        if let other = outcomes.compactMap({ if case .other(let text) = $0 { return text } else { return nil } }).first {
            return ProxyDiagnosis(verdict: .notAProxy, answer: other)
        }
        if outcomes.contains(.closed) && !outcomes.contains(.silent) {
            return ProxyDiagnosis(verdict: .closedWithoutAnswer)
        }
        if outcomes.contains(.silent) || outcomes.contains(.closed) {
            return ProxyDiagnosis(verdict: .silent)
        }
        // Neither connection was taken this time (it was a moment before).
        let failures = outcomes.compactMap { if case .noConnection(let failure) = $0 { return failure } else { return nil } }
        if failures.contains(.refused) { return ProxyDiagnosis(verdict: .refused) }
        if failures.contains(.unreachable) { return ProxyDiagnosis(verdict: .unreachable) }
        return ProxyDiagnosis(verdict: .connectTimeout)
    }

    // MARK: Wire details

    static func credentials(_ proxy: ProxySettings) -> (user: String, password: String)? {
        guard let user = proxy.username, !user.isEmpty else { return nil }
        return (user, proxy.password ?? "")
    }

    /// "host:port", an IPv6 host in brackets.
    static func authority(_ host: String, _ port: Int) -> String {
        "\(host.contains(":") ? "[\(host)]" : host):\(port)"
    }

    static func ipv4Bytes(_ host: String) -> [UInt8]? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        let bytes = parts.compactMap { UInt8($0) }
        return bytes.count == 4 ? bytes : nil
    }

    /// The first line of an HTTP answer ("HTTP/1.1 407 Proxy Authentication Required").
    static func statusLine(_ head: Data) -> String? {
        let text = String(decoding: head.prefix(512), as: UTF8.self)
        guard text.hasPrefix("HTTP/") else { return nil }
        return text.components(separatedBy: "\r\n").first.map { String($0.prefix(120)) }
    }

    static func statusCode(_ line: String) -> Int? {
        let parts = line.split(separator: " ", maxSplits: 2)
        guard parts.count >= 2, parts[0].hasPrefix("HTTP/1."), parts[1].count == 3 else { return nil }
        return Int(parts[1])
    }

    /// RFC 1928's reply codes, as the report shows them.
    static func socksReply(_ code: UInt8) -> String {
        let meaning: String
        switch code {
        case 0x01: meaning = "general failure"
        case 0x02: meaning = "not allowed by its rules"
        case 0x03: meaning = "network unreachable"
        case 0x04: meaning = "host unreachable"
        case 0x05: meaning = "connection refused"
        case 0x06: meaning = "TTL expired"
        case 0x07: meaning = "command not supported"
        case 0x08: meaning = "address type not supported"
        default: meaning = "unknown"
        }
        return "SOCKS5 reply 0x\(String(format: "%02X", Int(code))): \(meaning)"
    }

    /// The first bytes of an answer that is neither handshake, as text where they are text.
    static func printable(_ data: Data, more connection: ProbeSocket.Connection?) -> String {
        var bytes = data
        if let connection, bytes.count < 48 {
            if case .data(let extra) = connection.receive(atMost: 48 - bytes.count, before: ProbeClock.now + 0.3) {
                bytes.append(extra)
            }
        }
        let text = String(decoding: bytes.prefix(48), as: UTF8.self)
        if text.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value < 0x7F || $0 == "\r" || $0 == "\n" }) {
            return text.components(separatedBy: "\r\n").first ?? text
        }
        return bytes.prefix(16).map { String(format: "%02X", Int($0)) }.joined(separator: " ")
    }

    static func milliseconds(since start: TimeInterval) -> Int {
        max(1, Int(((ProbeClock.now - start) * 1000).rounded()))
    }
}
