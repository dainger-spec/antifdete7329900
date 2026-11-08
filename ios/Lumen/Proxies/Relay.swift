import Foundation
import LumenCore
import Network

/// What only the end-to-end tests see, in a DEBUG build they start with LUMEN_TEST_HOOKS=1: the
/// relay's port (so that a test, from its own process, can knock on the relay's door as another app
/// would). A release build has none.
enum TestHooks {
    static let enabled: Bool = {
        #if DEBUG
        return ProcessInfo.processInfo.environment["LUMEN_TEST_HOOKS"] == "1"
        #else
        return false
        #endif
    }()
}

/// Where a session's connections leave the device.
enum RelayRoute: Equatable {
    /// Nothing leaves: every connection is refused (until the session's route is set).
    case closed
    /// Straight to the site: a session without a proxy.
    case direct
    /// Through the session's proxy. The site's name is handed to the proxy as it is — never looked
    /// up on this device.
    case proxy(kind: ProxyKind, host: String, port: UInt16, username: String, password: String)
}

/// A session's local relay (посредник), WebKit's only way out of the session.
///
/// The session's data store has one proxy — this relay, on 127.0.0.1, with a password — and no
/// fallback. The relay takes each CONNECT WebKit makes and carries it the session's current way:
/// through its proxy, or straight to the site for a session without one. So:
///  - a proxy change closes every connection the relay carries, and the next one goes the new way:
///    WebKit's own connections cannot be moved or closed from outside (CI runs 14–16 of stage 2: they
///    kept their old route after a change), but the relay's can;
///  - a proxy that cannot carry a connection is a 502 for that connection, never a direct one;
///  - the relay takes connections from this device only, and only with its password: other apps
///    reach 127.0.0.1 too, and must not use a session's proxy.
final class Relay: @unchecked Sendable {
    static let username = "lumen"
    /// The relay's password, new on every start of the app: WebKit presents it (Proxy-Authorization).
    let password: String
    /// What a request to the relay must carry.
    fileprivate let expectedAuthorization: String
    fileprivate let queue: DispatchQueue
    /// Called on the main queue with the port the relay listens on, and with nil when it stopped listening.
    var onPort: ((UInt16?) -> Void)?

    // Everything below: on `queue` only.
    private var listener: NWListener?
    private var monitor: NWPathMonitor?
    /// The network as last seen: its status and the interface it goes out on.
    private var network: String?
    private var stopped = false
    fileprivate private(set) var route: RelayRoute = .closed
    private var links: [ObjectIdentifier: RelayLink] = [:]

    init(label: String) {
        let secret = (0..<24).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
        password = secret
        expectedAuthorization = "Basic " + Data("\(Relay.username):\(secret)".utf8).base64EncodedString()
        queue = DispatchQueue(label: "lumen.relay.\(label)")
    }

    /// The data store's proxy settings for a relay on `port`: the relay with its password, and no
    /// fallback. Without a port (the relay not listening yet, or not any more), a port nothing
    /// listens on — with no fallback either, so nothing leaves at all (measured in stage 2: a proxy
    /// that does not answer, with allowFailover = false, lets nothing go around it).
    static func configurations(port: UInt16?, password: String) -> [ProxyConfiguration] {
        let endpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port ?? 1) ?? 1)
        var configuration = ProxyConfiguration(httpCONNECTProxy: endpoint, tlsOptions: nil)
        configuration.applyCredential(username: Relay.username, password: password)
        // No fallback: a relay that does not answer means nothing leaves. (The planted fault: the
        // system may then go around it, straight out.)
        configuration.allowFailover = Faults.isActive(.relayFailoverOn)
        return [configuration]
    }

    func start() {
        queue.async {
            self.listen()
            self.watchNetwork()
        }
    }

    func stop() {
        queue.async {
            self.stopped = true
            self.listener?.cancel()
            self.listener = nil
            self.monitor?.cancel()
            self.monitor = nil
            self.closeAll()
        }
    }

    /// The session's way out, from the next connection on. A change closes every connection the
    /// relay carries, open or still being made: none goes on the old way.
    func setRoute(_ newRoute: RelayRoute) {
        queue.async {
            guard newRoute != self.route else { return }
            self.route = newRoute
            Relay.log("route: \(Relay.describe(newRoute))")
            // The planted fault: open connections keep their old route.
            if !Faults.isActive(.proxyChangeKeepsConnections) { self.closeAll() }
        }
    }

    /// After the app comes back to the foreground: a listener the system stopped while the app was
    /// suspended is started again (on a new port, which the session's data store is then given).
    func ensureListening() {
        queue.async {
            guard !self.stopped else { return }
            if let listener = self.listener {
                switch listener.state {
                case .failed, .cancelled: self.restartListener()
                default: break
                }
            } else {
                self.listen()
            }
        }
    }

    // MARK: Listening

    private func listen() {
        guard !stopped, listener == nil else { return }
        let parameters = NWParameters.tcp
        // 127.0.0.1 only: nothing on a network reaches the relay. (The planted fault: every interface.)
        if !Faults.isActive(.relayOnNetwork) {
            parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        }
        parameters.allowLocalEndpointReuse = true
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            Relay.log("cannot listen: \(error)")
            queue.asyncAfter(deadline: .now() + 1) { self.listen() }
            return
        }
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard let self, let listener, listener === self.listener else { return }
            switch state {
            case .ready:
                let port = listener.port?.rawValue
                Relay.log("listening on \(port.map { String($0) } ?? "?")")
                self.report(port)
            case let .failed(error), let .waiting(error):
                Relay.log("the listener stopped: \(error)")
                self.restartListener()
            default:
                break
            }
        }
        listener.start(queue: queue)
    }

    /// The listener stopped (or is stopped): every connection closes, the data store is told there
    /// is no relay (its proxy becomes a port nothing answers on), and a new listener starts.
    private func restartListener(after delay: TimeInterval = 0.5) {
        listener?.cancel()
        listener = nil
        closeAll()
        report(nil)
        guard !stopped else { return }
        queue.asyncAfter(deadline: .now() + delay) { self.listen() }
    }

    // MARK: The network under the session

    private func watchNetwork() {
        guard monitor == nil, !stopped else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in self?.pathChanged(path) }
        monitor.start(queue: queue)
        self.monitor = monitor
    }

    private func pathChanged(_ path: NWPath) {
        let primary = path.availableInterfaces.first.map { "\($0.type) \($0.name)" } ?? "none"
        let now = "\(path.status), \(primary)"
        defer { network = now }
        guard let before = network, before != now else { return }
        networkChanged("\(before) → \(now)")
    }

    /// The network under the session changed — Wi-Fi to cellular or back, or gone: every connection
    /// the relay carries is closed, so none goes on over the old network, and each new one is made
    /// again, through the proxy, on the new one. (The relay itself never goes around the proxy: a
    /// connection it cannot make through the proxy is a 502.)
    private func networkChanged(_ why: String) {
        Relay.log("the network changed: \(why)")
        // The planted fault: the connections made on the old network stay open.
        guard !Faults.isActive(.pathChangeKeepsConnections) else { return }
        closeAll()
    }

    #if DEBUG
    /// What the end-to-end tests make happen to the relay (TestHooks).
    enum Drill {
        /// A change of network, as NWPathMonitor reports one (a simulator never switches).
        case networkChange
        /// The relay dies for 25 s: its listener gone, the data store still pointing at its port.
        case death
        /// The relay starts again with its listener down for 25 s, the data store told (as after the
        /// system stopped the listener of a suspended app).
        case restart
    }

    func drill(_ drill: Drill) {
        queue.async {
            Relay.log("drill: \(drill)")
            switch drill {
            case .networkChange:
                self.networkChanged("a drill")
            case .death:
                self.listener?.cancel()
                self.listener = nil
                self.closeAll()
                self.queue.asyncAfter(deadline: .now() + 25) { self.listen() }
            case .restart:
                self.restartListener(after: 25)
            }
        }
    }
    #endif

    private func report(_ port: UInt16?) {
        DispatchQueue.main.async { self.onPort?(port) }
    }

    private func accept(_ connection: NWConnection) {
        // From this device only (the listener is on 127.0.0.1; this is the second lock on that door).
        guard case let .hostPort(host, _) = connection.endpoint, Relay.isLoopback(host) || Faults.isActive(.relayOnNetwork) else {
            connection.cancel()
            return
        }
        let link = RelayLink(client: connection, relay: self)
        links[ObjectIdentifier(link)] = link
        link.start()
    }

    fileprivate func forget(_ link: RelayLink) {
        links.removeValue(forKey: ObjectIdentifier(link))
    }

    private func closeAll() {
        let all = Array(links.values)
        if !all.isEmpty { Relay.log("closing \(all.count) connection(s)") }
        for link in all { link.close() }
        links = [:]
    }

    // MARK: Helpers

    static func isLoopback(_ host: NWEndpoint.Host) -> Bool {
        switch host {
        case let .ipv4(address):
            return address.rawValue.first == 127
        case let .ipv6(address):
            return address == .loopback || address.asIPv4?.rawValue.first == 127
        default:
            return false
        }
    }

    /// Outbound TCP: to the proxy, or for a session without one, to the site. Never through a system
    /// proxy, and a connection that cannot be made within 10 s is given up.
    static func outbound() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = 10
        tcp.noDelay = true
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.preferNoProxies = true
        return parameters
    }

    /// A name's IPv4 address by this device's own resolver. Only the planted fault relayResolvesLocally
    /// uses it: a proxied session's names are the proxy's to look up.
    static func lookUp(_ name: String) -> String? {
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_STREAM
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(name, nil, &hints, &result) == 0, let first = result else { return nil }
        defer { freeaddrinfo(result) }
        var text = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(first.pointee.ai_addr, first.pointee.ai_addrlen, &text, socklen_t(text.count), nil, 0, NI_NUMERICHOST) == 0 else {
            return nil
        }
        return String(cString: text)
    }

    static func resolvedHere(_ target: RelayTarget) -> RelayTarget {
        lookUp(target.host).flatMap { RelayTarget(authority: "\($0):\(target.port)") } ?? target
    }

    static func describe(_ route: RelayRoute) -> String {
        switch route {
        case .closed: return "closed"
        case .direct: return "direct"
        case let .proxy(kind, host, port, _, _): return "\(kind.rawValue)://\(host):\(port)"
        }
    }

    static func log(_ message: @autoclosure () -> String) {
        #if DEBUG
        NSLog("Lumen relay: %@", message())
        #endif
    }

    static let headEnd = Data("\r\n\r\n".utf8)
    static let headLimit = 16 * 1024
}

/// The site a CONNECT asks for: its name (or address) and port, as WebKit wrote them.
struct RelayTarget: Equatable {
    let host: String
    let port: UInt16

    /// "host:port" or "[v6 address]:port".
    init?(authority: String) {
        guard let colon = authority.lastIndex(of: ":"), let port = UInt16(authority[authority.index(after: colon)...]), port > 0 else {
            return nil
        }
        var host = String(authority[..<colon])
        if host.hasPrefix("[") && host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        guard !host.isEmpty, host.utf8.count <= 255, !host.contains(where: { $0 == " " || $0 == "\r" || $0 == "\n" }) else { return nil }
        self.host = host
        self.port = port
    }

    /// As a CONNECT line writes it.
    var authority: String { host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)" }

    /// The SOCKS5 CONNECT request for it (RFC 1928 §4): an address as an address, a name as a name
    /// (ATYP 3), which the proxy looks up — this device never does.
    var socksRequest: Data {
        var request = Data([5, 1, 0])
        if let v4 = IPv4Address(host) {
            request.append(1)
            request.append(v4.rawValue)
        } else if let v6 = IPv6Address(host) {
            request.append(4)
            request.append(v6.rawValue)
        } else {
            let name = Data(host.utf8)
            request.append(3)
            request.append(UInt8(name.count))
            request.append(name)
        }
        request.append(UInt8(port >> 8))
        request.append(UInt8(port & 0xff))
        return request
    }
}

/// One connection WebKit made to the relay, and the one the relay made for it. On the relay's queue.
private final class RelayLink {
    let client: NWConnection
    private weak var relay: Relay?
    private let queue: DispatchQueue
    private var upstream: NWConnection?
    /// Waits for the upstream connection being made: called once, with it when it is up, nil when not.
    private var whenUp: ((NWConnection?) -> Void)?
    private var closed = false
    /// Directions of the tunnel that have ended (2: both, the link is done).
    private var ended = 0

    init(client: NWConnection, relay: Relay) {
        self.client = client
        self.relay = relay
        queue = relay.queue
    }

    func start() {
        client.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.close()
            default: break
            }
        }
        client.start(queue: queue)
        readHead(Data())
    }

    func close() {
        guard !closed else { return }
        closed = true
        whenUp = nil
        client.cancel()
        upstream?.cancel()
        upstream = nil
        relay?.forget(self)
    }

    // MARK: The request

    private func readHead(_ buffer: Data) {
        client.receive(minimumIncompleteLength: 1, maximumLength: Relay.headLimit) { [weak self] data, _, isComplete, error in
            guard let self, !self.closed else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Relay.headEnd) {
                self.handle(head: buffer.subdata(in: buffer.startIndex..<end.lowerBound),
                            early: buffer.subdata(in: end.upperBound..<buffer.endIndex))
            } else if error != nil || isComplete || buffer.count > Relay.headLimit {
                self.close()
            } else {
                self.readHead(buffer)
            }
        }
    }

    private func handle(head: Data, early: Data) {
        guard let relay else { return close() }
        let lines = String(decoding: head, as: UTF8.self).components(separatedBy: "\r\n")
        let request = (lines.first ?? "").split(separator: " ", omittingEmptySubsequences: true)
        let authorization = lines.dropFirst()
            .first { $0.lowercased().hasPrefix("proxy-authorization:") }
            .map { line in String(line[line.index(after: line.firstIndex(of: ":")!)...]).trimmingCharacters(in: .whitespaces) }
        // (The planted fault: the door is open to anyone.)
        guard authorization == relay.expectedAuthorization || Faults.isActive(.relayOpen) else {
            return refuse("407 Proxy Authentication Required", extra: "Proxy-Authenticate: Basic realm=\"Lumen\"\r\n")
        }
        guard request.count >= 2, request[0] == "CONNECT", let target = RelayTarget(authority: String(request[1])) else {
            return refuse("405 Method Not Allowed")
        }
        open(target, route: relay.route, early: early)
    }

    /// An answer to WebKit that ends the connection.
    private func refuse(_ status: String, extra: String = "") {
        let reply = "HTTP/1.1 \(status)\r\n\(extra)Content-Length: 0\r\nConnection: close\r\n\r\n"
        // (A connection's handlers run on the relay's queue, where it was started.)
        client.send(content: Data(reply.utf8), completion: .contentProcessed { [weak self] _ in self?.close() })
    }

    // MARK: The way out

    private func open(_ target: RelayTarget, route: RelayRoute, early: Data) {
        switch route {
        case .closed:
            refuse("502 Bad Gateway")
        case .direct:
            dial(target.host, target.port) { [weak self] server in
                guard let self else { return }
                guard let server else { return self.refuse("502 Bad Gateway") }
                self.established(server, early: early, leftover: Data())
            }
        case let .proxy(kind, host, port, username, password):
            // What the proxy is asked for: the site's name as WebKit gave it. (The planted fault: the
            // name looked up here, and its address handed on.)
            let asked = Faults.isActive(.relayResolvesLocally) ? Relay.resolvedHere(target) : target
            dial(host, port) { [weak self] server in
                guard let self else { return }
                guard let server else { return self.proxyFailed(target, early: early) }
                let done: (Data?) -> Void = { [weak self] leftover in
                    guard let self else { return }
                    guard let leftover else {
                        self.upstream = nil
                        server.cancel()
                        return self.proxyFailed(target, early: early)
                    }
                    self.established(server, early: early, leftover: leftover)
                }
                if kind == .socks5 {
                    self.socks(server, asked, username: username, password: password, then: done)
                } else {
                    self.httpConnect(server, asked, username: username, password: password, then: done)
                }
            }
        }
    }

    /// The session's proxy could not carry this connection: a 502 for it, never a direct connection.
    private func proxyFailed(_ target: RelayTarget, early: Data) {
        Relay.log("the proxy could not carry \(target.authority): 502")
        if Faults.isActive(.failoverOn) {   // the planted fault: the relay falls back to going direct
            return open(target, route: .direct, early: early)
        }
        refuse("502 Bad Gateway")
    }

    /// A TCP connection to `host`; `then` gets it once it is up, or nil if it cannot be made.
    private func dial(_ host: String, _ port: UInt16, then: @escaping (NWConnection?) -> Void) {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return then(nil) }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: Relay.outbound())
        upstream = connection
        whenUp = then
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection, !self.closed, connection === self.upstream else { return }
            switch state {
            case .ready:
                if let then = self.whenUp {
                    self.whenUp = nil
                    then(connection)
                }
            case let .waiting(error), let .failed(error):
                if let then = self.whenUp {
                    Relay.log("cannot reach \(host):\(port): \(error)")
                    self.whenUp = nil
                    self.upstream = nil
                    connection.cancel()
                    then(nil)
                } else {
                    self.close()   // it was up, and is not any more: the link ends
                }
            case .cancelled:
                self.close()
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    /// The SOCKS5 handshake (RFC 1928, RFC 1929): `then` gets what came after the reply, or nil.
    private func socks(_ server: NWConnection, _ target: RelayTarget, username: String, password: String,
                       then: @escaping (Data?) -> Void) {
        let withAuth = !username.isEmpty || !password.isEmpty
        let connect = { [weak self] in
            guard let self else { return }
            self.write(server, target.socksRequest) { ok in
                guard ok else { return then(nil) }
                self.socksReply(server, then: then)
            }
        }
        write(server, Data([5, 1, withAuth ? 2 : 0])) { [weak self] ok in
            guard let self, ok else { return then(nil) }
            self.read(server, 2) { method in
                guard let method, method[0] == 5 else { return then(nil) }
                switch method[1] {
                case 0 where !withAuth:
                    connect()
                case 2 where withAuth:
                    let user = Data(username.utf8.prefix(255)), pass = Data(password.utf8.prefix(255))
                    self.write(server, Data([1, UInt8(user.count)]) + user + Data([UInt8(pass.count)]) + pass) { ok in
                        guard ok else { return then(nil) }
                        self.read(server, 2) { status in
                            guard let status, status[1] == 0 else {
                                Relay.log("the SOCKS5 proxy refused the user and password")
                                return then(nil)
                            }
                            connect()
                        }
                    }
                default:
                    Relay.log("the SOCKS5 proxy chose method \(method[1])")
                    then(nil)
                }
            }
        }
    }

    private func socksReply(_ server: NWConnection, then: @escaping (Data?) -> Void) {
        read(server, 4) { [weak self] head in
            guard let self, let head, head[0] == 5 else { return then(nil) }
            guard head[1] == 0 else {
                Relay.log("the SOCKS5 proxy answered \(head[1])")
                return then(nil)
            }
            let skip: (Int) -> Void = { count in self.read(server, count) { $0 == nil ? then(nil) : then(Data()) } }
            switch head[3] {
            case 1: skip(4 + 2)
            case 4: skip(16 + 2)
            case 3:
                self.read(server, 1) { length in
                    if let length { skip(Int(length[0]) + 2) } else { then(nil) }
                }
            default: then(nil)
            }
        }
    }

    /// CONNECT through an HTTP proxy, its credentials sent at once: `then` gets what came after the
    /// proxy's 2xx head, or nil.
    private func httpConnect(_ server: NWConnection, _ target: RelayTarget, username: String, password: String,
                             then: @escaping (Data?) -> Void) {
        var head = "CONNECT \(target.authority) HTTP/1.1\r\nHost: \(target.authority)\r\n"
        if !username.isEmpty || !password.isEmpty {
            head += "Proxy-Authorization: Basic \(Data("\(username):\(password)".utf8).base64EncodedString())\r\n"
        }
        head += "\r\n"
        write(server, Data(head.utf8)) { [weak self] ok in
            guard let self, ok else { return then(nil) }
            self.readAnswer(server, Data(), then: then)
        }
    }

    private func readAnswer(_ server: NWConnection, _ buffer: Data, then: @escaping (Data?) -> Void) {
        server.receive(minimumIncompleteLength: 1, maximumLength: Relay.headLimit) { [weak self] data, _, isComplete, error in
            guard let self, !self.closed else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Relay.headEnd) {
                let status = String(decoding: buffer.subdata(in: buffer.startIndex..<end.lowerBound), as: UTF8.self)
                    .components(separatedBy: "\r\n").first ?? ""
                let parts = status.split(separator: " ")
                if parts.count >= 2, parts[0].hasPrefix("HTTP/1."), parts[1].count == 3, parts[1].hasPrefix("2") {
                    then(buffer.subdata(in: end.upperBound..<buffer.endIndex))
                } else {
                    Relay.log("the HTTP proxy answered: \(status)")
                    then(nil)
                }
            } else if error != nil || isComplete || buffer.count > Relay.headLimit {
                then(nil)
            } else {
                self.readAnswer(server, buffer, then: then)
            }
        }
    }

    // MARK: The tunnel

    private func established(_ server: NWConnection, early: Data, leftover: Data) {
        upstream = server
        client.send(content: Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8), completion: .contentProcessed { _ in })
        if !leftover.isEmpty { client.send(content: leftover, completion: .contentProcessed { _ in }) }
        if !early.isEmpty { server.send(content: early, completion: .contentProcessed { _ in }) }
        pump(from: client, to: server)
        pump(from: server, to: client)
    }

    /// Carries one direction until it ends; its end is passed on (a half close), and when both
    /// directions have ended, so has the link.
    private func pump(from source: NWConnection, to sink: NWConnection) {
        source.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, !self.closed else { return }
            if let data, !data.isEmpty {
                sink.send(content: data, completion: .contentProcessed { [weak self] sendError in
                    guard let self, !self.closed else { return }
                    if sendError != nil { return self.close() }
                    if isComplete { self.end(sink) } else if error != nil { self.close() } else { self.pump(from: source, to: sink) }
                })
            } else if isComplete {
                end(sink)
            } else if error != nil {
                close()
            } else {
                pump(from: source, to: sink)
            }
        }
    }

    private func end(_ sink: NWConnection) {
        sink.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in })
        ended += 1
        if ended >= 2 { close() }
    }

    // MARK: Reading and writing

    private func read(_ connection: NWConnection, _ count: Int, then: @escaping ([UInt8]?) -> Void) {
        guard count > 0 else { return then([]) }
        connection.receive(minimumIncompleteLength: count, maximumLength: count) { [weak self] data, _, _, error in
            guard let self, !self.closed else { return }
            if error == nil, let data, data.count == count { then([UInt8](data)) } else { then(nil) }
        }
    }

    private func write(_ connection: NWConnection, _ data: Data, then: @escaping (Bool) -> Void) {
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let self, !self.closed else { return }
            then(error == nil)
        })
    }
}
