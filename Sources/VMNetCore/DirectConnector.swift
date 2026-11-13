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
/// CONNECT, no sign-in (nothing but this process reaches a port on loopback that the system chose
/// a moment ago), names resolved here. Like the network itself, it connects to public addresses
/// only: a name that resolves to this Mac, or to somebody's local network, is refused — a page in
/// a guest must not reach the Mac's own services by naming them.
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
    /// Connections carried at once; one more is refused.
    public static let maximumConnections = 1024

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
    /// This Mac's resolver did not answer in time: until then it is not asked before a proxy is
    /// (`namesOnlyLocalAddresses`), so that its silence costs one connection a wait, not each.
    private var resolverSilentUntil = 0.0

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

    /// The connector as `VMNetwork` is told of a proxy. Call after `start()`.
    public var upstream: VMNetUpstream {
        .socks5(host: "127.0.0.1", port: port, username: nil, password: nil)
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
            guard open.count < Self.maximumConnections * 2 else { return false }
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
            guard client >= 0 else { continue }
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

    /// Reads SOCKS5's greeting and its one request; nil for anything but a CONNECT.
    private func request(from client: Int32) -> (Target, UInt16)? {
        guard let greeting = Self.read(client, exactly: 2), greeting[0] == 5,
              let methods = Self.read(client, exactly: Int(greeting[1])) else { return nil }
        guard methods.contains(0) else {
            _ = Self.sendAll(client, [5, 0xFF])
            return nil
        }
        guard Self.sendAll(client, [5, 0]) else { return nil }
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
        if let proxy = systemProxy?(), proxy.applies(to: host) {
            return tunnel(through: proxy.upstream, to: target, port: port, deadline: deadline)
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
        switch rule {
        case .any: return true
        case .publicOnly: return Self.isPublic(address)
        case .publicOrIntoATunnel:
            if Self.isPublic(address) { return true }
            guard Self.isPrivate(address) else { return false }
            if let routesIntoTunnel { return routesIntoTunnel(Self.text(of: address)) }
            return Self.goesIntoATunnel(address)
        }
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
            // A name that this Mac knows only as its own or a local network's is not asked of the
            // proxy either: what a guest must not reach, it must not reach by a proxy on this Mac.
            if namesOnlyLocalAddresses(name) {
                return .failed(.notPublic, "the name's addresses here are not public ones (not asked of this Mac's proxy)")
            }
            asked = .name(name, port: port)
        case .address(let address):
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

    /// Whether this Mac's resolver gives the name addresses, and not one of them public. Asked
    /// with a limit of a second and a half: a resolver that does not answer (where only the proxy
    /// gets out, it may not) is no reason to refuse, and no reason to make a connection wait.
    private func namesOnlyLocalAddresses(_ name: String) -> Bool {
        guard !allowsLocalDestinations else { return false }
        lock.lock()
        let silent = Sys.now < resolverSilentUntil
        lock.unlock()
        guard !silent else { return false }
        final class Answer: @unchecked Sendable {
            let lock = NSLock()
            var found: [Address]?
        }
        let answer = Answer()
        let done = DispatchSemaphore(value: 0)
        let thread = Thread {
            let found = Self.addresses(of: name, port: 443).found
            answer.lock.lock()
            answer.found = found
            answer.lock.unlock()
            done.signal()
        }
        thread.stackSize = 512 << 10
        thread.start()
        guard done.wait(timeout: .now() + 1.5) == .success else {
            lock.lock()
            resolverSilentUntil = Sys.now + 30
            lock.unlock()
            return false
        }
        answer.lock.lock()
        let found = answer.found ?? []
        answer.lock.unlock()
        return !found.isEmpty && !found.contains { allows($0, by: .publicOrIntoATunnel) }
    }

    /// What the system has for a host, IPv4 first (a Mac whose IPv6 goes nowhere then costs no
    /// wait); with the resolver's code when it has nothing.
    private static func addresses(of host: String, port: UInt16) -> (found: [Address], code: Int32) {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = Sys.streamType
        hints.ai_flags = AI_NUMERICSERV
        var list: UnsafeMutablePointer<addrinfo>?
        let code = getaddrinfo(host, String(port), &hints, &list)
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
    private static func text(of address: Address) -> String {
        var storage = address.storage
        var buffer = [CChar](repeating: 0, count: 64)
        let done = withUnsafeMutablePointer(to: &storage) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getnameinfo($0, address.length, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST)
            }
        }
        return done == 0 ? String(cString: buffer) : ""
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

    /// An IPv6 address of the public internet: not unspecified or loopback, not link-local or
    /// unique-local, not multicast; one that carries an IPv4 address is judged by that.
    static func isPublicIPv6(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == 16 else { return false }
        if bytes[0..<10].allSatisfy({ $0 == 0 }) {
            // ::, ::1, IPv4-compatible and IPv4-mapped (::ffff:a.b.c.d).
            let mapped = bytes[10] == 0xFF && bytes[11] == 0xFF
            let compatible = bytes[10] == 0 && bytes[11] == 0
            guard mapped || compatible else { return false }
            let value = UInt32(bytes[12]) << 24 | UInt32(bytes[13]) << 16 | UInt32(bytes[14]) << 8 | UInt32(bytes[15])
            return mapped && !DestinationPolicy.isRefusedRange(VMNetIPv4(value))
        }
        if bytes[0] == 0xFF { return false }                       // ff00::/8, multicast
        if bytes[0] == 0xFE && bytes[1] & 0xC0 == 0x80 { return false }  // fe80::/10, link-local
        if bytes[0] & 0xFE == 0xFC { return false }                // fc00::/7, unique local
        return true
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
