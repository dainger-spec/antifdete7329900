#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

/// The only way from OpenVPN to its servers (docs/OPENVPN.md, "The way out"): OpenVPN runs
/// confined to loopback, and each of its servers is a port here on 127.0.0.1 that carries what it
/// sends to that server's one address — and nowhere else. A forwarder never resolves a name or
/// picks a destination: its target is fixed when it is made.
///
/// UDP: the first local sender is the client (OpenVPN's socket), and only its datagrams go out;
/// only the target's come back. TCP: each connection from this Mac gets one to the target, both
/// ways, with bounded buffers. Everything runs on one thread of its own, until `stop`.
public final class LoopbackForwarders: @unchecked Sendable {
    public enum Transport: Equatable, Sendable { case udp, tcp }

    public struct Target: Equatable, Sendable {
        public var address: TunnelAddress
        public var port: UInt16
        public var transport: Transport
        public init(address: TunnelAddress, port: UInt16, transport: Transport) {
            self.address = address
            self.port = port
            self.transport = transport
        }
    }

    public enum ForwarderError: Error, Equatable {
        case socket(Int32)
    }

    /// Bytes carried, each way, for the log.
    public struct Counts: Equatable, Sendable {
        public var toServers = 0
        public var fromServers = 0
        /// Datagrams or connections from anyone but the client, refused.
        public var refused = 0
    }

    private final class UDPForwarder {
        let local: Int32
        let remote: Int32
        var client: sockaddr_storage?
        init(local: Int32, remote: Int32) {
            self.local = local
            self.remote = remote
        }
    }

    private final class TCPPair {
        let inside: Int32
        let outside: Int32
        var connected = false
        var toOutside: [UInt8] = []
        var toInside: [UInt8] = []
        var insideDone = false
        var outsideDone = false
        var outsideShut = false
        var insideShut = false
        init(inside: Int32, outside: Int32) {
            self.inside = inside
            self.outside = outside
        }
    }

    private final class TCPForwarder {
        let listener: Int32
        let target: Target
        var pairs: [TCPPair] = []
        init(listener: Int32, target: Target) {
            self.listener = listener
            self.target = target
        }
    }

    /// The local port of each target, in the order given.
    public let ports: [UInt16]
    private var udp: [UDPForwarder] = []
    private var tcp: [TCPForwarder] = []
    private let lock = NSLock()
    private var counts = Counts()
    private var wakeRead: Int32 = -1
    private var wakeWrite: Int32 = -1
    private var thread: Thread?
    private var stopped = false
    private static let bufferLimit = 512 * 1024

    /// Opens a port on 127.0.0.1 for each target and starts carrying. Throws when a socket cannot
    /// be made; nothing is left open then.
    public init(targets: [Target]) throws {
        var ports: [UInt16] = []
        var made: [Int32] = []
        func fail(_ code: Int32) -> ForwarderError {
            for descriptor in made { TunnelSystem.close(descriptor) }
            return .socket(code)
        }
        for target in targets {
            switch target.transport {
            case .udp:
                guard let (local, port) = TunnelSystem.loopbackDatagramSocket() else { throw fail(errno) }
                made.append(local)
                let family = target.address.family == .v4 ? AF_INET : AF_INET6
                let remote = socket(family, TunnelSystem.datagramType, 0)
                guard remote >= 0 else { throw fail(errno) }
                made.append(remote)
                guard TunnelSystem.connect(remote, to: target.address, port: target.port) == 0 else { throw fail(errno) }
                TunnelSystem.setNonBlocking(remote)
                TunnelSystem.setCloseOnExec(remote)
                for descriptor in [local, remote] {
                    TunnelSystem.setBuffer(descriptor, SO_RCVBUF, bytes: 1 << 20)
                    TunnelSystem.setBuffer(descriptor, SO_SNDBUF, bytes: 1 << 20)
                }
                udp.append(UDPForwarder(local: local, remote: remote))
                ports.append(port)
            case .tcp:
                guard let (listener, port) = TunnelSystem.loopbackListener() else { throw fail(errno) }
                made.append(listener)
                tcp.append(TCPForwarder(listener: listener, target: target))
                ports.append(port)
            }
        }
        var ends: [Int32] = [0, 0]
        guard pipe(&ends) == 0 else { throw fail(errno) }
        wakeRead = ends[0]
        wakeWrite = ends[1]
        for descriptor in ends {
            TunnelSystem.setNonBlocking(descriptor)
            TunnelSystem.setCloseOnExec(descriptor)
        }
        self.ports = ports
        let thread = Thread { [self] in run() }
        thread.name = "Lumen OpenVPN forwarders"
        self.thread = thread
        thread.start()
    }

    deinit { stop() }

    public var currentCounts: Counts {
        lock.lock()
        defer { lock.unlock() }
        return counts
    }

    /// Stops carrying and closes every socket (the loop's thread closes them as it ends).
    public func stop() {
        lock.lock()
        let first = !stopped
        stopped = true
        lock.unlock()
        if first, wakeWrite >= 0 { _ = TunnelSystem.write(wakeWrite, [1]) }
    }

    private var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    private func tally(_ change: (inout Counts) -> Void) {
        lock.lock()
        change(&counts)
        lock.unlock()
    }

    // MARK: The loop

    private func run() {
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while !isStopped {
            var entries = [pollfd(fd: wakeRead, events: Int16(POLLIN), revents: 0)]
            for forwarder in udp {
                entries.append(pollfd(fd: forwarder.local, events: Int16(POLLIN), revents: 0))
                entries.append(pollfd(fd: forwarder.remote, events: Int16(POLLIN), revents: 0))
            }
            for forwarder in tcp {
                entries.append(pollfd(fd: forwarder.listener, events: Int16(POLLIN), revents: 0))
                for pair in forwarder.pairs {
                    var inside: Int16 = 0
                    var outside: Int16 = 0
                    if !pair.insideDone && pair.toOutside.count < Self.bufferLimit { inside |= Int16(POLLIN) }
                    if !pair.toInside.isEmpty { inside |= Int16(POLLOUT) }
                    if !pair.connected { outside |= Int16(POLLOUT) } else {
                        if !pair.outsideDone && pair.toInside.count < Self.bufferLimit { outside |= Int16(POLLIN) }
                        if !pair.toOutside.isEmpty { outside |= Int16(POLLOUT) }
                    }
                    entries.append(pollfd(fd: pair.inside, events: inside, revents: 0))
                    entries.append(pollfd(fd: pair.outside, events: outside, revents: 0))
                }
            }
            let ready = TunnelSystem.wait(&entries, milliseconds: 1000)
            if ready <= 0 { continue }
            if entries[0].revents != 0 { break }
            var index = 1
            for forwarder in udp {
                if entries[index].revents & Int16(POLLIN) != 0 { fromClient(forwarder, &buffer) }
                if entries[index + 1].revents & Int16(POLLIN) != 0 { fromServer(forwarder, &buffer) }
                index += 2
            }
            for forwarder in tcp {
                let listenerEvents = entries[index].revents
                index += 1
                for pair in forwarder.pairs {
                    service(pair, inside: entries[index].revents, outside: entries[index + 1].revents, &buffer)
                    index += 2
                }
                forwarder.pairs.removeAll { pair in
                    let finished = (pair.insideDone && pair.outsideDone && pair.toInside.isEmpty && pair.toOutside.isEmpty)
                        || pair.inside < 0
                    if finished { close(pair) }
                    return finished
                }
                if listenerEvents & Int16(POLLIN) != 0 { acceptConnections(forwarder) }
            }
        }
        for forwarder in udp {
            TunnelSystem.close(forwarder.local)
            TunnelSystem.close(forwarder.remote)
        }
        for forwarder in tcp {
            TunnelSystem.close(forwarder.listener)
            for pair in forwarder.pairs { close(pair) }
        }
        TunnelSystem.close(wakeRead)
        TunnelSystem.close(wakeWrite)
    }

    // MARK: UDP

    private func fromClient(_ forwarder: UDPForwarder, _ buffer: inout [UInt8]) {
        for _ in 0..<256 {
            let (count, from) = buffer.withUnsafeMutableBytes { TunnelSystem.receiveFrom(forwarder.local, $0) }
            guard count >= 0 else { return }
            guard let sender = TunnelSystem.endpoint(of: from), TunnelSystem.isLoopback(sender.address) else {
                tally { $0.refused += 1 }
                continue
            }
            if let client = forwarder.client {
                guard TunnelSystem.sameEndpoint(client, from) else {
                    tally { $0.refused += 1 }
                    continue
                }
            } else {
                forwarder.client = from
            }
            let sent = buffer.withUnsafeBytes { TunnelSystem.send(forwarder.remote, UnsafeRawBufferPointer(rebasing: $0[0..<count])) }
            if sent > 0 { tally { $0.toServers += sent } }
        }
    }

    private func fromServer(_ forwarder: UDPForwarder, _ buffer: inout [UInt8]) {
        for _ in 0..<256 {
            // A connected UDP socket takes datagrams from its target alone.
            let count = buffer.withUnsafeMutableBytes { TunnelSystem.receive(forwarder.remote, $0) }
            if count < 0 {
                if TunnelSystem.wouldBlock(TunnelSystem.lastError) { return }
                // An ICMP error from the server's side (refused, unreachable): nothing to carry.
                continue
            }
            guard let client = forwarder.client else { continue }
            if TunnelSystem.sendTo(forwarder.local, Array(buffer[0..<count]), client) > 0 {
                tally { $0.fromServers += count }
            }
        }
    }

    // MARK: TCP

    private func acceptConnections(_ forwarder: TCPForwarder) {
        while true {
            var storage = sockaddr_storage()
            var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let inside = withUnsafeMutablePointer(to: &storage) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { TunnelSystem.accept(forwarder.listener, $0, &length) }
            }
            guard inside >= 0 else { return }
            guard let peer = TunnelSystem.endpoint(of: storage), TunnelSystem.isLoopback(peer.address), forwarder.pairs.count < 8 else {
                TunnelSystem.close(inside)
                tally { $0.refused += 1 }
                continue
            }
            TunnelSystem.setNonBlocking(inside)
            TunnelSystem.setCloseOnExec(inside)
            TunnelSystem.setNoSigPipe(inside)
            let family = forwarder.target.address.family == .v4 ? AF_INET : AF_INET6
            let outside = socket(family, TunnelSystem.streamType, 0)
            guard outside >= 0 else {
                TunnelSystem.close(inside)
                continue
            }
            TunnelSystem.setNonBlocking(outside)
            TunnelSystem.setCloseOnExec(outside)
            TunnelSystem.setNoSigPipe(outside)
            let result = TunnelSystem.connect(outside, to: forwarder.target.address, port: forwarder.target.port)
            if result != 0 && TunnelSystem.lastError != EINPROGRESS {
                TunnelSystem.close(inside)
                TunnelSystem.close(outside)
                continue
            }
            let pair = TCPPair(inside: inside, outside: outside)
            pair.connected = result == 0
            forwarder.pairs.append(pair)
        }
    }

    private func service(_ pair: TCPPair, inside: Int16, outside: Int16, _ buffer: inout [UInt8]) {
        if !pair.connected {
            guard outside != 0 else { return }
            if TunnelSystem.pendingError(pair.outside) != 0 || outside & Int16(POLLERR | POLLHUP) != 0 {
                // The server refused or could not be reached: the client's connection ends too.
                pair.insideDone = true
                pair.outsideDone = true
                pair.toInside.removeAll()
                pair.toOutside.removeAll()
                return
            }
            pair.connected = true
        }
        if inside & Int16(POLLIN | POLLHUP | POLLERR) != 0 {
            pump(from: pair.inside, into: &pair.toOutside, done: &pair.insideDone, &buffer)
        }
        if outside & Int16(POLLIN | POLLHUP | POLLERR) != 0 {
            let before = pair.toInside.count
            pump(from: pair.outside, into: &pair.toInside, done: &pair.outsideDone, &buffer)
            let carried = pair.toInside.count - before
            if carried > 0 { tally { $0.fromServers += carried } }
        }
        if !pair.toOutside.isEmpty {
            let sent = flush(&pair.toOutside, to: pair.outside)
            if sent < 0 { pair.insideDone = true; pair.outsideDone = true; pair.toInside.removeAll(); pair.toOutside.removeAll() }
            else if sent > 0 { tally { $0.toServers += sent } }
        }
        if !pair.toInside.isEmpty, flush(&pair.toInside, to: pair.inside) < 0 {
            pair.insideDone = true
            pair.outsideDone = true
            pair.toInside.removeAll()
            pair.toOutside.removeAll()
        }
        // An end on one side is passed to the other once what it sent is through.
        if pair.insideDone && pair.toOutside.isEmpty && !pair.outsideShut {
            TunnelSystem.shutdownWrite(pair.outside)
            pair.outsideShut = true
        }
        if pair.outsideDone && pair.toInside.isEmpty && !pair.insideShut {
            TunnelSystem.shutdownWrite(pair.inside)
            pair.insideShut = true
        }
    }

    private func pump(from descriptor: Int32, into queue: inout [UInt8], done: inout Bool, _ buffer: inout [UInt8]) {
        while queue.count < Self.bufferLimit {
            let count = buffer.withUnsafeMutableBytes { TunnelSystem.receive(descriptor, $0) }
            if count > 0 {
                queue += buffer[0..<count]
                continue
            }
            if count == 0 || !TunnelSystem.wouldBlock(TunnelSystem.lastError) { done = true }
            return
        }
    }

    /// Writes what it can; the count written, or -1 when the socket failed.
    private func flush(_ queue: inout [UInt8], to descriptor: Int32) -> Int {
        let sent = queue.withUnsafeBytes { TunnelSystem.send(descriptor, $0) }
        if sent > 0 {
            queue.removeFirst(sent)
            return sent
        }
        return sent < 0 && !TunnelSystem.wouldBlock(TunnelSystem.lastError) ? -1 : 0
    }

    private func close(_ pair: TCPPair) {
        TunnelSystem.close(pair.inside)
        TunnelSystem.close(pair.outside)
    }
}
