#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

/// The way out for a machine that has no proxy: this Mac's own connection, as any app has it.
///
/// Apple's NAT for virtual machines (`VZNATNetworkDeviceAttachment`) carries a guest's packets
/// through a network of the system's own, beside the apps' — and where the Mac runs a VPN or a
/// proxy tool that takes the apps' traffic, the guest's packets are not taken with it and go
/// nowhere (the first run on a person's Mac, 13 November: a machine "through my network" had no
/// internet at all). Here the guest's connections are instead made by this process, as ordinary
/// sockets: they go wherever the connections of any app on this Mac go — through its VPN, by its
/// routes, under its firewall.
///
/// It is a SOCKS5 server on loopback that the machine's network (`VMNetwork`) uses as its proxy:
/// the two parts already speak that between them, and nothing of the network changes. Only
/// CONNECT, names resolved here — and a sign-in (RFC 1929) with a user name and password made up
/// at random for this run, which only the machine's network is given (`upstream`): any process
/// on this Mac can reach a port on loopback, and without it any of them could have its
/// connections made here, past whatever the Mac does about that process. Like the network
/// itself, it connects to public addresses only: a name that resolves to this Mac, or to
/// somebody's local network, is refused — and so is an address of the Mac's own (its public
/// IPv4, its global IPv6) or of a network it is on, public or not. A name that is local by the
/// way it is written (one label, `localhost`, `.local`, an address written as a name) is never
/// looked up or asked of a proxy.
///
/// Where the connection is asked of the Mac's own proxy (below), that proxy resolves the name, and
/// where it then connects is its decision: a proxy tool that sends some public names straight to
/// an address of the local network (a rule of its own, a resolver that answers so) takes a
/// machine's connection there too, as it takes Safari's on this Mac. That is the limit of this
/// rule, said in docs/VM_NETWORK.md; the settings' own exceptions (`VMNetSystemProxy.applies`)
/// go by the rule above.
///
/// With one exception, which is a VPN's: many VPN tools answer every name with an address of
/// their own making from a private range (100.64.x.x, 10.x.x.x, …) and take the connection to it
/// in their tunnel, where they put the real destination back. Such an address is not anybody's
/// local network — this Mac sends it into the tunnel — and refusing it left a machine on such a
/// Mac with no internet at all (the third run on a person's Mac, 13 November). So a private
/// address a name resolved to is taken when this Mac's route for it is a tunnel's interface, and
/// refused when it is the Mac itself or a network the Mac is on.
///
/// Where this Mac's own network settings name a proxy (a VPN or proxy tool in its "system proxy"
/// mode), the connection is asked of that proxy instead, as Safari on this Mac asks it
/// (`VMNetSystemProxy`): such a tool takes no packets, and a plain socket would pass it by.
///
/// One thread per direction of a connection, blocking: a few hundred connections of a browser
/// are a few hundred idle threads, and the code is what can be read.
public final class VMNetDirectConnector: @unchecked Sendable {
    /// Connections carried at once; one more is refused. Fewer where the process may not open
    /// enough descriptors for them (`connectionsAllowed`).
    public static let maximumConnections = 1024

    /// Each connection of a machine without a proxy holds three descriptors of the helper: the
    /// machine's network's socket to this connector, the one this connector accepted, and the
    /// one to the destination.
    public static let descriptorsPerConnection = 3

    /// How many connections may be carried at once with `descriptorLimit` descriptors to the
    /// process: as the machine's network counts them (`NetworkLoop.connectionLimit`), three
    /// descriptors each.
    static func connectionsAllowed(descriptorLimit: Int) -> Int {
        NetworkLoop.connectionLimit(wanted: maximumConnections, descriptorLimit: descriptorLimit,
                                    descriptorsPerConnection: descriptorsPerConnection)
    }

    /// Why a connection was not made: a kind, never where it was going.
    public enum Trouble: String, Sendable, Codable, CaseIterable {
        /// This Mac found no address for the name.
        case nameNotFound
        /// Every address the name has here is this Mac's own or a local network's.
        case notPublic
        /// The addresses did not take the connection: refused, or no answer.
        case unreachable
        /// The proxy of this Mac's network settings did not take the connection.
        case proxyUnreachable
        /// That proxy answered, and said no.
        case proxyRefused
        /// This Mac's network settings have the proxy chosen by a configuration file (PAC) or
        /// found on the network (WPAD), which a machine cannot follow: nothing is connected — not
        /// without the proxy either, which would be going out where the Mac's apps do not.
        case proxyConfigurationFile
    }

    /// What the connector has done so far. Counts and a kind only.
    public struct Report: Equatable, Sendable {
        public var connected: UInt64 = 0
        public var failed: UInt64 = 0
        /// Connections that failed one after another since the last one made.
        public var failedInARow: UInt64 = 0
        /// Why the last connection failed; nil when it was made.
        public var trouble: Trouble?
        /// The same in the log's words — a kind, a range or an error's name, never a name or an
        /// address — for whoever is asked what is wrong.
        public var detail: String?
        /// The last connection made went through the proxy of this Mac's network settings.
        public var usesSystemProxy = false

        public init() {}
    }

    private let allowsLocalDestinations: Bool
    /// The tests' own answer to "what addresses has this name": nil asks the system.
    private let resolve: (@Sendable (String) -> [String]?)?
    /// The proxy this Mac's network settings name now, if any: asked for every connection, so a
    /// tool switched on while a machine runs is followed from the next connection on.
    private let systemProxy: (@Sendable () -> VMNetSystemProxy?)?
    /// The tests' own answer to "does this machine send packets for this address into a tunnel"
    /// (the address as text): nil asks the system (`goesIntoATunnel`).
    private let routesIntoTunnel: (@Sendable (String) -> Bool)?

    /// The sign-in the SOCKS5 server asks for: made up at random for each connector, never
    /// written anywhere but into `upstream`.
    private let username = VMNetDirectConnector.randomToken()
    private let password = VMNetDirectConnector.randomToken()
    /// Connections carried at once, by the descriptors this process may open.
    private let connectionLimit = VMNetDirectConnector.connectionsAllowed(descriptorLimit: Sys.descriptorLimit)

    private let lock = NSLock()
    private var listener: Int32 = -1
    private var listeningPort = 0
    private var stopped = true
    /// Every socket of the connections under way, to cut them at `stop`.
    private var open: Set<Int32> = []
    private var threads = 0
    private var current = Report()
    /// What happened since the notes were last taken: a line of the log, and how many times.
    private var notes: [String: Int] = [:]

    /// `systemProxy`: what this Mac's network settings name as its proxy at the moment of asking
    /// (the helper reads the system's own dictionary); nil, or a nil answer: plain sockets.
    public init(systemProxy: (@Sendable () -> VMNetSystemProxy?)? = nil) {
        allowsLocalDestinations = false
        resolve = nil
        routesIntoTunnel = nil
        self.systemProxy = systemProxy
    }

    /// For the tests: destinations on this machine, and names given their addresses.
    init(allowsLocalDestinations: Bool, systemProxy: (@Sendable () -> VMNetSystemProxy?)? = nil,
         routesIntoTunnel: (@Sendable (String) -> Bool)? = nil, resolve: (@Sendable (String) -> [String]?)? = nil) {
        self.allowsLocalDestinations = allowsLocalDestinations
        self.resolve = resolve
        self.routesIntoTunnel = routesIntoTunnel
        self.systemProxy = systemProxy
    }

    deinit { stop() }

    public enum Failure: Error, Equatable {
        case noSocket(Int32)
        case alreadyStarted
    }

    /// The connector as `VMNetwork` is told of a proxy, with its sign-in. Call after `start()`.
    public var upstream: VMNetUpstream {
        .socks5(host: "127.0.0.1", port: port, username: username, password: password)
    }

    /// 16 random bytes as hex: a user name or a password nobody guesses.
    private static func randomToken() -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255, using: &generator)) }.joined()
    }

    /// The loopback port it listens on; 0 before `start()`.
    public var port: Int {
        lock.lock()
        defer { lock.unlock() }
        return listeningPort
    }

    /// What the connector has done so far.
    public func report() -> Report {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    /// What happened since this was last asked, as a line for a log — kinds and counts, never a
    /// name or an address; nil when nothing did.
    public func takeNotes() -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard !notes.isEmpty else { return nil }
        let line = notes.sorted { $0.key < $1.key }.map { "\($0.value) × \($0.key)" }.joined(separator: "; ")
        notes.removeAll()
        return line
    }

    /// Whether a connection can be made at all right now, by the same way a guest's are: to a
    /// name of Apple's that every Mac asks for when it joins a network. For telling "this machine
    /// has no internet" from "the sites it asks for are not there" (a page's blocked trackers
    /// fail one after another on a Mac with a filtering resolver, and are no outage). Nothing is
    /// sent but the connection's opening; it is not counted in the report. Blocks: not for the
    /// main thread.
    public func canConnect() -> Bool {
        canConnect(to: "captive.apple.com", port: 80)
    }

    func canConnect(to name: String, port: UInt16) -> Bool {
        guard !isStopped else { return false }
        switch tunnel(to: .name(name), port: port) {
        case .made(let descriptor, _, _):
            Sys.close(descriptor)
            return true
        case .failed:
            return false
        }
    }

    private func record(made throughProxy: Bool) {
        lock.lock()
        current.connected += 1
        current.failedInARow = 0
        current.trouble = nil
        current.detail = nil
        current.usesSystemProxy = throughProxy
        notes[throughProxy ? "connected through this Mac's proxy" : "connected", default: 0] += 1
        lock.unlock()
    }

    private func record(_ trouble: Trouble, _ detail: String) {
        lock.lock()
        current.failed += 1
        current.failedInARow += 1
        current.trouble = trouble
        current.detail = detail
        notes[detail, default: 0] += 1
        lock.unlock()
    }

    /// Starts listening on a loopback port of the system's choosing and returns it.
    @discardableResult
    public func start() throws -> Int {
        lock.lock()
        defer { lock.unlock() }
        guard stopped, listener < 0 else { throw Failure.alreadyStarted }
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = Sys.streamType
        hints.ai_flags = AI_NUMERICHOST | AI_NUMERICSERV | AI_PASSIVE
        var list: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo("127.0.0.1", "0", &hints, &list) == 0, let first = list else { throw Failure.noSocket(errno) }
        defer { freeaddrinfo(list) }
        let descriptor = socket(AF_INET, Sys.streamType, 0)
        guard descriptor >= 0 else { throw Failure.noSocket(errno) }
        guard bind(descriptor, first.pointee.ai_addr, first.pointee.ai_addrlen) == 0, Self.systemListen(descriptor) == 0 else {
            let code = errno
            Sys.close(descriptor)
            throw Failure.noSocket(code)
        }
        var address = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
        }
        guard named == 0 else {
            let code = errno
            Sys.close(descriptor)
            throw Failure.noSocket(code)
        }
        listener = descriptor
        listeningPort = Int(UInt16(bigEndian: address.sin_port))
        stopped = false
        threads += 1
        let thread = Thread { [self] in
            acceptLoop(descriptor)
            finished()
        }
        thread.name = "VMNet direct connector"
        thread.start()
        return listeningPort
    }

    /// Ends the connector: its connections are cut, and its threads have ended when this returns
    /// (or a few seconds have passed).
    public func stop() {
        lock.lock()
        guard !stopped else {
            lock.unlock()
            return
        }
        stopped = true
        for descriptor in open { _ = shutdown(descriptor, Int32(SHUT_RDWR)) }
        lock.unlock()
        let deadline = Sys.now + 5
        while Sys.now < deadline {
            lock.lock()
            let left = threads
            lock.unlock()
            if left == 0 { break }
            usleep(2_000)
        }
        lock.lock()
        if listener >= 0 { Sys.close(listener) }
        listener = -1
        listeningPort = 0
        lock.unlock()
    }

    // MARK: - Bookkeeping

    private var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    private func finished() {
        lock.lock()
        threads -= 1
        lock.unlock()
    }

    /// Takes a socket into the connector's care; false when it has stopped (the socket is then
    /// the caller's to close) or carries all it may.
    private func register(_ descriptor: Int32, countsAsConnection: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !stopped else { return false }
        if countsAsConnection {
            // Two sockets of this connector's a connection (the third is the network's).
            guard open.count < connectionLimit * 2 else { return false }
            threads += 1
        }
        open.insert(descriptor)
        return true
    }

    private func release(_ descriptor: Int32) {
        lock.lock()
        open.remove(descriptor)
        lock.unlock()
        Sys.close(descriptor)
    }

    // MARK: - Accepting

    private func acceptLoop(_ descriptor: Int32) {
        while !isStopped {
            var entries = [pollfd(fd: descriptor, events: Sys.readable, revents: 0)]
            guard Sys.wait(&entries, milliseconds: 200) > 0 else { continue }
            #if canImport(Darwin)
            let client = Darwin.accept(descriptor, nil, nil)
            #else
            let client = Glibc.accept(descriptor, nil, nil)
            #endif
            guard client >= 0 else {
                let code = errno
                // Out of descriptors or memory: the connection waiting stays waiting, and the
                // listener reads as ready again at once — asked again now, it would be asked in
                // a loop as fast as the processor goes. Left alone for a moment instead.
                if code != EINTR, code != EAGAIN, code != EWOULDBLOCK, code != ECONNABORTED {
                    noteAcceptFailure(code)
                    usleep(250_000)
                }
                continue
            }
            Sys.setNoSigPipe(client)
            Sys.setNoDelay(client)
            guard register(client, countsAsConnection: true) else {
                Sys.close(client)
                continue
            }
            let thread = Thread { [self] in
                serve(client)
                release(client)
                finished()
            }
            // The system's resolver runs on it: the size the system gives a thread, not less.
            thread.stackSize = 512 << 10
            thread.start()
        }
    }

    private func noteAcceptFailure(_ code: Int32) {
        lock.lock()
        notes["a connection could not be taken (\(Sys.describe(code)))", default: 0] += 1
        lock.unlock()
    }

    private static func systemListen(_ descriptor: Int32) -> Int32 {
        #if canImport(Darwin)
        return Darwin.listen(descriptor, 256)
        #else
        return Glibc.listen(descriptor, 256)
        #endif
    }

    // MARK: - One connection

    private enum Target {
        case name(String)
        case address(VMNetIPv4)
    }

    private func serve(_ client: Int32) {
        // The network at the other end is this process: a request that does not come at once is
        // not coming.
        Self.setTimeout(client, seconds: 15)
        guard let (target, port) = request(from: client) else { return }
        let remote: Int32
        let leftover: [UInt8]
        switch tunnel(to: target, port: port) {
        case .failed(let trouble, let detail):
            if !isStopped { record(trouble, detail) }
            // 5: connection refused — what a guest's TCP is then told.
            _ = Self.sendAll(client, [5, 5, 0, 1, 0, 0, 0, 0, 0, 0])
            return
        case .made(let descriptor, let early, let throughProxy):
            record(made: throughProxy)
            remote = descriptor
            leftover = early
        }
        guard register(remote, countsAsConnection: false) else {
            Sys.close(remote)
            return
        }
        defer { release(remote) }
        guard Self.sendAll(client, [5, 0, 0, 1, 0, 0, 0, 0, 0, 0]) else { return }
        // What a proxy sent right behind its answer is already the connection's.
        guard leftover.isEmpty || Self.sendAll(client, leftover) else { return }
        Self.setTimeout(client, seconds: 0)

        // The answer's way back on a thread of its own; the request's way here.
        let back = DispatchSemaphore(value: 0)
        let thread = Thread {
            Self.carry(from: remote, to: client)
            back.signal()
        }
        thread.stackSize = 256 << 10
        thread.start()
        Self.carry(from: client, to: remote)
        back.wait()
    }

    /// Reads SOCKS5's greeting, the sign-in and its one request; nil for anything but a CONNECT
    /// from a client that has this connector's user name and password. Without a sign-in (method
    /// 0) nothing is taken: any process on this Mac reaches a port on loopback.
    private func request(from client: Int32) -> (Target, UInt16)? {
        guard let greeting = Self.read(client, exactly: 2), greeting[0] == 5,
              let methods = Self.read(client, exactly: Int(greeting[1])) else { return nil }
        guard methods.contains(2) else {
            _ = Self.sendAll(client, [5, 0xFF])
            return nil
        }
        guard Self.sendAll(client, [5, 2]) else { return nil }
        // RFC 1929: version 1, the user name, the password — each its length and its bytes.
        guard let version = Self.read(client, exactly: 2), version[0] == 1,
              let user = Self.read(client, exactly: Int(version[1])),
              let length = Self.read(client, exactly: 1),
              let secret = Self.read(client, exactly: Int(length[0])) else { return nil }
        guard Self.same(user, Array(username.utf8)), Self.same(secret, Array(password.utf8)) else {
            _ = Self.sendAll(client, [1, 1])
            return nil
        }
        guard Self.sendAll(client, [1, 0]) else { return nil }
        guard let head = Self.read(client, exactly: 4), head[0] == 5 else { return nil }
        let target: Target
        switch head[3] {
        case 1:
            guard let bytes = Self.read(client, exactly: 4) else { return nil }
            target = .address(VMNetIPv4(UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3])))
        case 3:
            guard let length = Self.read(client, exactly: 1), length[0] > 0,
                  let bytes = Self.read(client, exactly: Int(length[0])) else { return nil }
            let name = String(decoding: bytes, as: UTF8.self)
            // A name as names are written: nothing a resolver could take for anything else.
            guard bytes.allSatisfy({ $0 > 0x20 && $0 < 0x7F }) else { return nil }
            target = .name(name)
        default:
            // An IPv6 address, or nothing known: the machine's network asks for neither.
            _ = Self.sendAll(client, [5, 8, 0, 1, 0, 0, 0, 0, 0, 0])
            return nil
        }
        guard let portBytes = Self.read(client, exactly: 2) else { return nil }
        let port = UInt16(portBytes[0]) << 8 | UInt16(portBytes[1])
        guard head[1] == 1, port != 0 else {
            // 7: command not supported.
            _ = Self.sendAll(client, [5, 7, 0, 1, 0, 0, 0, 0, 0, 0])
            return nil
        }
        return (target, port)
    }

    /// Whether two byte strings are the same, in a time that does not depend on where they differ.
    private static func same(_ given: [UInt8], _ expected: [UInt8]) -> Bool {
        guard given.count == expected.count else { return false }
        var difference: UInt8 = 0
        for index in given.indices { difference |= given[index] ^ expected[index] }
        return difference == 0
    }

    // MARK: - Connecting

    private enum Tunnel {
        /// A connected socket; `leftover` is what a proxy sent behind its answer.
        case made(Int32, leftover: [UInt8], throughProxy: Bool)
        case failed(Trouble, String)
    }

    /// One address of a host, as the system gave it.
    struct Address {
        var family: Int32
        var storage: sockaddr_storage
        var length: socklen_t
    }

    /// The connection to the target: through the proxy of this Mac's network settings where they
    /// name one for it, as this process's own socket otherwise.
    private func tunnel(to target: Target, port: UInt16) -> Tunnel {
        let deadline = Sys.now + 20
        let host: String
        switch target {
        case .name(let name): host = name
        case .address(let address): host = address.string
        }
        // A name that is this machine's or the local network's by the way it is written, or an
        // address written as a name: not looked up here, not asked of a proxy — whichever way the
        // connection would go, and before the Mac's settings are asked which.
        if case .name(let name) = target, !allowsLocalDestinations, Self.isLocalName(name) {
            return .failed(.notPublic, "a name of this machine or the local network, or an address written as a name")
        }
        if let proxy = systemProxy?() {
            // A configuration file is a program to run for every address, which a machine does not
            // follow; and going out without the proxy would be going out where the Mac's own apps
            // do not. Nothing is connected — as with a proxy that is down.
            if proxy.usesConfigurationFile {
                return .failed(.proxyConfigurationFile,
                               "this Mac's proxy is set by a configuration file (PAC or WPAD), which a machine cannot follow")
            }
            if proxy.applies(to: host) {
                return tunnel(through: proxy.upstream, to: target, port: port, deadline: deadline)
            }
        }
        var hosts = [host]
        // A name's addresses are this Mac's resolver's — a VPN's own among them, which go into
        // its tunnel. An address the guest wrote itself is taken only if it is a public one.
        var rule = Rule.publicOnly
        if case .name(let name) = target {
            rule = .publicOrIntoATunnel
            if let resolve, let given = resolve(name) { hosts = given }
        }
        if allowsLocalDestinations { rule = .any }
        var failure = Tunnel.failed(.nameNotFound, "no address for the name")
        for host in hosts {
            switch dial(host, port: port, rule: rule, deadline: deadline) {
            case .made(let descriptor, _, _): return .made(descriptor, leftover: [], throughProxy: false)
            case .failed(let trouble, let detail): failure = .failed(trouble, detail)
            }
        }
        return failure
    }

    /// Which of a host's addresses a connection may be made to.
    private enum Rule {
        /// Public ones only.
        case publicOnly
        /// Public ones, and private ones this Mac sends into a tunnel (a VPN's own addresses).
        case publicOrIntoATunnel
        /// Any: the proxy of this Mac's settings, and the tests' servers.
        case any
    }

    private func allows(_ address: Address, by rule: Rule) -> Bool {
        if rule == .any { return true }
        // A public address may still be this Mac's own (a public IPv4 of its, its global IPv6) or
        // of a network it is on (a public prefix on its link): refused like a private one. Read
        // from the interfaces, with no socket.
        if Self.isPublic(address) { return !Self.isOnOwnNetwork(address) }
        guard rule == .publicOrIntoATunnel, Self.isPrivate(address) else { return false }
        if let routesIntoTunnel { return routesIntoTunnel(Self.text(of: address)) }
        // Which refuses the Mac's own addresses and networks first, too.
        return Self.goesIntoATunnel(address)
    }

    /// A connected socket to one of the host's addresses that `rule` allows, or why there is none.
    private func dial(_ host: String, port: UInt16, rule: Rule, deadline: Double) -> Tunnel {
        let (found, code) = Self.addresses(of: host, port: port)
        guard !found.isEmpty else { return .failed(.nameNotFound, "no address for the name (resolver's code \(code))") }
        let allowed = found.filter { allows($0, by: rule) }
        guard !allowed.isEmpty else {
            return .failed(.notPublic, "the name's addresses here are not public ones (\(Self.kind(of: found[0]))"
                + (rule == .publicOrIntoATunnel && Self.isPrivate(found[0]) ? ", and this Mac does not send them into a tunnel)" : ")"))
        }
        var last = "no time left"
        for address in allowed {
            guard !isStopped, Sys.now < deadline else { break }
            let descriptor = socket(address.family, Sys.streamType, 0)
            guard descriptor >= 0 else {
                last = Sys.describe(errno)
                continue
            }
            Sys.setNoSigPipe(descriptor)
            Sys.setNoDelay(descriptor)
            var storage = address.storage
            let code = withUnsafeMutablePointer(to: &storage) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Self.connect(descriptor, $0, address.length, seconds: min(8, deadline - Sys.now))
                }
            }
            if code == 0 { return .made(descriptor, leftover: [], throughProxy: false) }
            Sys.close(descriptor)
            last = Sys.describe(code)
        }
        return .failed(.unreachable, "the address did not take the connection (\(last))")
    }

    /// The connection as the proxy of this Mac's network settings makes it: the proxy is asked
    /// for the name itself, as it is by the Mac's own apps.
    private func tunnel(through proxy: VMNetUpstream, to target: Target, port: UInt16, deadline: Double) -> Tunnel {
        let asked: ProxyTarget
        switch target {
        case .name(let name):
            // The proxy is asked for the name and resolves it, as it does for this Mac's apps. The
            // name is NOT looked up here first: that would tell this Mac's resolver — on a network
            // where a proxy tool is used, often the very party the tool is there for — every name
            // a guest opens, which the Mac's own Safari does not; and a resolver that answers a
            // blocked name with a local address (many do) would have the name refused that the
            // proxy opens. Only what is local by the way it is written is not asked.
            if !allowsLocalDestinations, Self.isLocalName(name) {
                return .failed(.notPublic, "a name of this machine or the local network (not asked of this Mac's proxy)")
            }
            asked = .name(name, port: port)
        case .address(let address):
            // An address of this Mac or a local network is not asked of a proxy either (the
            // machine's network refuses those before they come here).
            if !allowsLocalDestinations, DestinationPolicy.isRefusedRange(address) {
                return .failed(.notPublic, "not a public address (not asked of this Mac's proxy)")
            }
            asked = .address(address, port: port)
        }
        guard let endpoint = proxy.endpoint, (1...65535).contains(endpoint.port), var handshake = proxy.handshake(for: asked) else {
            return .failed(.proxyUnreachable, "this Mac's proxy is not one a connection can be asked of")
        }
        // The proxy is this Mac's own setting, wherever it is — as a rule on this Mac itself.
        let descriptor: Int32
        switch dial(endpoint.host, port: UInt16(endpoint.port), rule: .any, deadline: deadline) {
        case .made(let made, _, _): descriptor = made
        case .failed(_, let detail): return .failed(.proxyUnreachable, "this Mac's proxy: " + detail)
        }
        Self.setTimeout(descriptor, seconds: 20)
        var step = handshake.begin()
        while true {
            switch step {
            case .send(let bytes):
                guard Self.sendAll(descriptor, bytes) else {
                    Sys.close(descriptor)
                    return .failed(.proxyUnreachable, "this Mac's proxy closed the connection")
                }
                step = .needMore
            case .needMore:
                var chunk = [UInt8](repeating: 0, count: 4096)
                let got = chunk.withUnsafeMutableBytes { recv(descriptor, $0.baseAddress, $0.count, 0) }
                if got < 0, errno == EINTR { continue }
                guard got > 0 else {
                    Sys.close(descriptor)
                    return .failed(.proxyUnreachable, got == 0 ? "this Mac's proxy closed the connection" : "this Mac's proxy did not answer")
                }
                step = handshake.receive(Array(chunk[0..<got]))
            case .established(let leftover):
                Self.setTimeout(descriptor, seconds: 0)
                return .made(descriptor, leftover: leftover, throughProxy: true)
            case .failed(let failure):
                Sys.close(descriptor)
                return .failed(.proxyRefused, "this Mac's proxy: " + failure.reason)
            }
        }
    }

    /// A name that is this machine's own or the local network's by the way it is written — one
    /// label, `localhost`, anything under `.local` — or that is not written as a name at all
    /// (an address written as a name included: `DNSResponder.isResolvable`).
    /// (The machine's own resolver gives such names no address, so its network never asks for
    /// one: this is the same rule, held here too.)
    static func isLocalName(_ name: String) -> Bool {
        let labels = name.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        return !DNSResponder.isResolvable(labels: labels.last == "" ? Array(labels.dropLast()) : labels, name: name)
    }

    /// What the system has for a host, IPv4 first (a Mac whose IPv6 goes nowhere then costs no
    /// wait); with the resolver's code when it has nothing.
    ///
    /// An address written out ("192.168.1.10") is read as it is written: the system's resolver is
    /// asked for names only. (Asked of such a literal alone, on a CI Mac, it did not bring up
    /// macOS's question about the local network — 14 November — but there is nothing for it to
    /// answer that the address does not already say.)
    private static func addresses(of host: String, port: UInt16) -> (found: [Address], code: Int32) {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = Sys.streamType
        hints.ai_flags = AI_NUMERICSERV | AI_NUMERICHOST
        var list: UnsafeMutablePointer<addrinfo>?
        var code = getaddrinfo(host, String(port), &hints, &list)
        if code != 0 {
            // A name: the resolver.
            hints.ai_flags = AI_NUMERICSERV
            list = nil
            code = getaddrinfo(host, String(port), &hints, &list)
        }
        guard code == 0 else { return ([], code) }
        defer { freeaddrinfo(list) }
        var found: [Address] = []
        var next = list
        while let entry = next {
            let family = entry.pointee.ai_family
            let length = Int(entry.pointee.ai_addrlen)
            if let address = entry.pointee.ai_addr, family == AF_INET || family == AF_INET6, length <= MemoryLayout<sockaddr_storage>.size {
                var storage = sockaddr_storage()
                withUnsafeMutableBytes(of: &storage) { $0.copyMemory(from: UnsafeRawBufferPointer(start: address, count: length)) }
                found.append(Address(family: family, storage: storage, length: entry.pointee.ai_addrlen))
            }
            next = entry.pointee.ai_next
        }
        return (found.filter { $0.family == AF_INET } + found.filter { $0.family == AF_INET6 }, 0)
    }

    private static func isPublic(_ address: Address) -> Bool {
        var storage = address.storage
        return withUnsafeMutablePointer(to: &storage) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { isPublic($0, family: address.family) }
        }
    }

    /// An address of a private range: somebody's local network — or a VPN's own making. Not this
    /// machine itself, a link's own addresses, a group's or nobody's: those are never taken.
    static func isPrivate(_ address: Address) -> Bool {
        var storage = address.storage
        if address.family == AF_INET {
            let value = withUnsafeMutablePointer(to: &storage) { pointer in
                pointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            }
            return isPrivateIPv4(VMNetIPv4(value))
        }
        guard address.family == AF_INET6 else { return false }
        let bytes = withUnsafeMutablePointer(to: &storage) { pointer in
            pointer.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { inner in
                withUnsafeBytes(of: inner.pointee.sin6_addr) { Array($0) }
            }
        }
        // fc00::/7, unique local.
        return bytes.count == 16 && bytes[0] & 0xFE == 0xFC
    }

    /// 10/8, 100.64/10, 172.16/12, 192.168/16, 192.0.0/24 and 240/4 short of the broadcast
    /// address. Not 0/8, loopback, link-local or multicast.
    static func isPrivateIPv4(_ address: VMNetIPv4) -> Bool {
        let ranges: [(UInt32, Int)] = [(0x0A00_0000, 8), (0x6440_0000, 10), (0xAC10_0000, 12), (0xC0A8_0000, 16),
                                       (0xC000_0000, 24), (0xF000_0000, 4)]
        return address != .broadcast && ranges.contains { address.isIn($0.0, $0.1) }
    }

    /// The address as text, for the tests' answer about its route.
    /// Written by `inet_ntop` from its bytes: nothing of the system's resolver is asked.
    ///
    /// It was `getnameinfo` (`NI_NUMERICHOST`). With it, the test that has a local network's
    /// address refused brought up macOS's question about the local network on CI's Macs — over
    /// what a later step of the full pipeline took a picture of; with this and the literals read
    /// as written, that test alone and every test of the package (878) did not (14 November).
    /// `getnameinfo` was not tried alone: that it was the cause is the likely reading, not a
    /// measured one.
    private static func text(of address: Address) -> String {
        var storage = address.storage
        var bytes = withUnsafeMutablePointer(to: &storage) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { addressBytes($0, family: address.family) }
        }
        guard bytes.count == 4 || bytes.count == 16 else { return "" }
        var buffer = [CChar](repeating: 0, count: 64)
        let written = inet_ntop(address.family, &bytes, &buffer, socklen_t(buffer.count))
        return written == nil ? "" : String(cString: buffer)
    }

    /// The bytes of the address in a socket address (4 or 16), or none.
    private static func addressBytes(_ pointer: UnsafePointer<sockaddr>, family: Int32) -> [UInt8] {
        if family == AF_INET {
            return pointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { withUnsafeBytes(of: $0.pointee.sin_addr) { Array($0) } }
        }
        if family == AF_INET6 {
            return pointer.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { withUnsafeBytes(of: $0.pointee.sin6_addr) { Array($0) } }
        }
        return []
    }

    /// Whether this machine sends a packet for the address into a tunnel — a point-to-point
    /// interface, as a VPN's is — and the address is not the machine's own.
    ///
    /// Asked of the system's routes the way a program may: a datagram socket is "connected" to
    /// the address, which sends nothing and makes the system choose the address it would send
    /// from; the interface that has that address is the route's.
    static func goesIntoATunnel(_ address: Address) -> Bool {
        // This machine itself, or a network it is on: not a tunnel's far side — and said without
        // a socket (below).
        guard !isOnOwnNetwork(address) else { return false }
        let probe = socket(address.family, Sys.datagramType, 0)
        guard probe >= 0 else { return false }
        defer { Sys.close(probe) }
        var destination = address.storage
        let connected: Int32 = withUnsafeMutablePointer(to: &destination) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { target in
                #if canImport(Darwin)
                return Darwin.connect(probe, target, address.length)
                #else
                return Glibc.connect(probe, target, address.length)
                #endif
            }
        }
        guard connected == 0 else { return false }
        var local = sockaddr_storage()
        var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let named = withUnsafeMutablePointer(to: &local) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(probe, $0, &length) }
        }
        guard named == 0 else { return false }
        let source = withUnsafeMutablePointer(to: &local) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { addressBytes($0, family: address.family) }
        }
        let target = withUnsafeMutablePointer(to: &destination) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { addressBytes($0, family: address.family) }
        }
        // Sent from the address it is sent to: this machine itself.
        guard !source.isEmpty, source != target else { return false }

        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return false }
        defer { freeifaddrs(list) }
        var found = false
        var next = list
        while let entry = next {
            next = entry.pointee.ifa_next
            guard let own = entry.pointee.ifa_addr, Int32(own.pointee.sa_family) == address.family,
                  addressBytes(own, family: address.family) == source else { continue }
            let flags = Int(entry.pointee.ifa_flags)
            // Every interface that has the address must be a tunnel's: one that is also a
            // network's own leaves the question open, and open is refused.
            guard flags & Int(IFF_UP) != 0, flags & Int(IFF_POINTOPOINT) != 0, flags & Int(IFF_LOOPBACK) == 0 else { return false }
            found = true
        }
        return found
    }

    /// Whether the address is this machine's own, or of a network the machine is on by an
    /// interface that is not a tunnel's — read from the interfaces' own addresses and masks, with
    /// no socket. On a Mac, so much as "connecting" a socket to an address of the network the Mac
    /// is on is a use of the local network, which macOS asks the person about in a window of its
    /// own (seen on CI, 14 November: the window stood over what a later check took a picture
    /// of). Such an address is refused anyway, so it is refused here, before anything is opened.
    ///
    /// An IPv6 address that carries an IPv4 one (`::ffff:a.b.c.d`, NAT64's `64:ff9b::a.b.c.d`) is
    /// asked about as that IPv4 address too: it is where the connection ends up.
    static func isOnOwnNetwork(_ address: Address) -> Bool {
        var storage = address.storage
        let target = withUnsafeMutablePointer(to: &storage) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { addressBytes($0, family: address.family) }
        }
        guard !target.isEmpty else { return false }
        if address.family == AF_INET6, let inner = embeddedIPv4(target), isOnOwnNetwork(family: AF_INET, target: inner) { return true }
        return isOnOwnNetwork(family: address.family, target: target)
    }

    /// The same, of an address's bytes (4 or 16, as the system has them) in `family`.
    private static func isOnOwnNetwork(family: Int32, target: [UInt8]) -> Bool {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return false }
        defer { freeifaddrs(list) }
        var next = list
        while let entry = next {
            next = entry.pointee.ifa_next
            guard let own = entry.pointee.ifa_addr, Int32(own.pointee.sa_family) == family else { continue }
            let flags = Int(entry.pointee.ifa_flags)
            guard flags & Int(IFF_UP) != 0 else { continue }
            let mine = addressBytes(own, family: family)
            if mine == target { return true }
            // A tunnel's far side is not a network the machine is on: it is what is asked about.
            guard flags & Int(IFF_POINTOPOINT) == 0, flags & Int(IFF_LOOPBACK) == 0, let netmask = entry.pointee.ifa_netmask else { continue }
            let mask = addressBytes(netmask, family: family)
            guard mask.count == target.count, mine.count == target.count, mask.contains(where: { $0 != 0 }) else { continue }
            var same = true
            for index in 0..<target.count where mine[index] & mask[index] != target[index] & mask[index] {
                same = false
                break
            }
            if same { return true }
        }
        return false
    }

    /// The same two questions of an address as it is written ("100.64.0.2"): for the tests.
    static func isOnOwnNetwork(numeric text: String) -> Bool {
        guard let address = addresses(of: text, port: 9).found.first else { return false }
        return isOnOwnNetwork(address)
    }

    /// The same, of an address as it is written ("100.64.0.2"): for the tests.
    static func goesIntoATunnel(numeric text: String) -> Bool {
        guard let address = addresses(of: text, port: 9).found.first else { return false }
        return goesIntoATunnel(address)
    }

    /// The kind of address that was refused, for the log: its range, never the address.
    private static func kind(of address: Address) -> String {
        guard address.family == AF_INET else { return "IPv6, local" }
        var storage = address.storage
        let value = withUnsafeMutablePointer(to: &storage) { pointer in
            pointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
        }
        guard let range = DestinationPolicy.refusedRanges.first(where: { VMNetIPv4(value).isIn($0.0, $0.1) }) else { return "IPv4" }
        return "\(VMNetIPv4(range.0).string)/\(range.1)"
    }

    /// Connects within `seconds`, and leaves the socket waiting on its reads and writes again.
    /// 0, or the error's number.
    private static func connect(_ descriptor: Int32, _ address: UnsafeMutablePointer<sockaddr>, _ length: socklen_t, seconds: Double) -> Int32 {
        let flags = fcntl(descriptor, F_GETFL, 0)
        _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK)
        #if canImport(Darwin)
        let status = Darwin.connect(descriptor, address, length)
        #else
        let status = Glibc.connect(descriptor, address, length)
        #endif
        if status != 0 {
            let code = errno
            guard code == EINPROGRESS else { return code }
            var entries = [pollfd(fd: descriptor, events: Sys.writable, revents: 0)]
            guard Sys.wait(&entries, milliseconds: Int32(max(1, seconds * 1000))) > 0 else { return ETIMEDOUT }
            let pending = Sys.pendingError(descriptor)
            guard pending == 0 else { return pending }
        }
        _ = fcntl(descriptor, F_SETFL, flags & ~O_NONBLOCK)
        return 0
    }

    /// The address is one of the public internet: not this machine, not a local network.
    static func isPublic(_ address: UnsafeMutablePointer<sockaddr>, family: Int32) -> Bool {
        if family == AF_INET {
            let value = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            return !DestinationPolicy.isRefusedRange(VMNetIPv4(value))
        }
        guard family == AF_INET6 else { return false }
        let bytes = address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { pointer in
            withUnsafeBytes(of: pointer.pointee.sin6_addr) { Array($0) }
        }
        return isPublicIPv6(bytes)
    }

    /// An IPv6 address of the public internet: not unspecified or loopback, not link-local,
    /// site-local or unique-local, not multicast; one that carries an IPv4 address (mapped, or
    /// behind NAT64's well-known prefix) is judged by that.
    static func isPublicIPv6(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == 16 else { return false }
        if bytes[0..<12].elementsEqual(nat64Prefix), let inner = embeddedIPv4(bytes) {
            return !DestinationPolicy.isRefusedRange(VMNetIPv4(UInt32(inner[0]) << 24 | UInt32(inner[1]) << 16 | UInt32(inner[2]) << 8 | UInt32(inner[3])))
        }
        if bytes[0..<10].allSatisfy({ $0 == 0 }) {
            // ::, ::1, IPv4-compatible and IPv4-mapped (::ffff:a.b.c.d).
            let mapped = bytes[10] == 0xFF && bytes[11] == 0xFF
            let compatible = bytes[10] == 0 && bytes[11] == 0
            guard mapped || compatible else { return false }
            let value = UInt32(bytes[12]) << 24 | UInt32(bytes[13]) << 16 | UInt32(bytes[14]) << 8 | UInt32(bytes[15])
            return mapped && !DestinationPolicy.isRefusedRange(VMNetIPv4(value))
        }
        if bytes[0] == 0xFF { return false }                       // ff00::/8, multicast
        if bytes[0] == 0xFE && bytes[1] & 0x80 == 0x80 { return false }  // fe80::/10, link-local; fec0::/10, site-local
        if bytes[0] & 0xFE == 0xFC { return false }                // fc00::/7, unique local
        return true
    }

    /// NAT64's well-known prefix, 64:ff9b::/96: its last four bytes are an IPv4 address.
    private static let nat64Prefix: [UInt8] = [0x00, 0x64, 0xFF, 0x9B, 0, 0, 0, 0, 0, 0, 0, 0]

    /// The IPv4 address an IPv6 address carries — IPv4-mapped (`::ffff:a.b.c.d`) or behind NAT64's
    /// well-known prefix — as its four bytes; nil for any other.
    static func embeddedIPv4(_ bytes: [UInt8]) -> [UInt8]? {
        guard bytes.count == 16 else { return nil }
        let mapped = bytes[0..<10].allSatisfy { $0 == 0 } && bytes[10] == 0xFF && bytes[11] == 0xFF
        guard mapped || bytes[0..<12].elementsEqual(nat64Prefix) else { return nil }
        return Array(bytes[12..<16])
    }

    // MARK: - Bytes

    /// A limit on how long a read or a write may wait; 0: none.
    private static func setTimeout(_ descriptor: Int32, seconds: Int) {
        var limit = timeval()
        limit.tv_sec = type(of: limit.tv_sec).init(seconds)
        limit.tv_usec = 0
        _ = setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
    }

    private static func read(_ descriptor: Int32, exactly count: Int) -> [UInt8]? {
        var bytes = [UInt8](repeating: 0, count: count)
        var have = 0
        while have < count {
            let got = bytes.withUnsafeMutableBytes { buffer in
                recv(descriptor, buffer.baseAddress! + have, count - have, 0)
            }
            if got > 0 {
                have += got
            } else if got < 0, errno == EINTR {
                continue
            } else {
                return nil
            }
        }
        return bytes
    }

    private static func sendAll(_ descriptor: Int32, _ bytes: [UInt8]) -> Bool {
        bytes.withUnsafeBytes { sendAll(descriptor, $0) }
    }

    private static func sendAll(_ descriptor: Int32, _ bytes: UnsafeRawBufferPointer) -> Bool {
        var sent = 0
        while sent < bytes.count {
            #if canImport(Darwin)
            let wrote = Darwin.send(descriptor, bytes.baseAddress! + sent, bytes.count - sent, 0)
            #else
            let wrote = Glibc.send(descriptor, bytes.baseAddress! + sent, bytes.count - sent, Int32(MSG_NOSIGNAL))
            #endif
            if wrote > 0 {
                sent += wrote
            } else if wrote < 0, errno == EINTR {
                continue
            } else {
                return false
            }
        }
        return true
    }

    /// Carries bytes one way until that way ends. A side that has finished sending is told so at
    /// the other (its answers may still come); a side that broke ends both ways.
    private static func carry(from source: Int32, to destination: Int32) {
        var buffer = [UInt8](repeating: 0, count: 64 << 10)
        while true {
            let got = buffer.withUnsafeMutableBytes { recv(source, $0.baseAddress, $0.count, 0) }
            if got > 0 {
                let delivered = buffer.withUnsafeBytes { sendAll(destination, UnsafeRawBufferPointer(rebasing: $0[0..<got])) }
                if !delivered {
                    _ = shutdown(source, Int32(SHUT_RDWR))
                    _ = shutdown(destination, Int32(SHUT_RDWR))
                    return
                }
            } else if got == 0 {
                _ = shutdown(destination, Int32(SHUT_WR))
                return
            } else if errno == EINTR {
                continue
            } else {
                _ = shutdown(source, Int32(SHUT_RDWR))
                _ = shutdown(destination, Int32(SHUT_RDWR))
                return
            }
        }
    }
}
