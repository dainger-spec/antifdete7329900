import OpenVPNLink
import CLwIP

/// Names looked up through the tunnel, at the DNS servers the VPN pushed (or, when it pushed
/// none, public ones — still through the tunnel). This Mac's own resolver is never asked: the
/// tunnel's program has no other way out, and asks nothing else.
///
/// A for an IPv4 tunnel, AAAA for an IPv6 one, A first when there are both. Each question is
/// asked again after `attemptTimeout`, of the next server, at most `attempts` times; a server
/// that fails (SERVFAIL, REFUSED) gives way to the next at once. Answers are kept for their TTL
/// (between `minimumTTL` and `maximumTTL`), names that do not exist for a shorter while.
public final class TunnelResolver {
    typealias Completion = (Result<[TunnelAddress], ResolverFailure>) -> Void

    public struct Tuning {
        public var attemptTimeout = 1.5
        public var attempts = 4
        public var minimumTTL: Double = 30
        public var maximumTTL: Double = 3600
        public var maximumNegativeTTL: Double = 300
        public var cacheLimit = 4096
        public init() {}
    }

    private struct Pending {
        var name: String
        var type: DNSMessage.RecordType
        var id: UInt16
        var serverIndex: Int
        var attempt: Int
        var deadline: Double
        var waiters: [Completion]
    }

    private struct Cached {
        var addresses: [TunnelAddress]
        var noSuchName: Bool
        var expires: Double
    }

    let servers: [TunnelSettings.DNSServer]
    let tuning: Tuning
    private let families: Set<TunnelAddress.Family>
    /// Runs a completion once lwIP has returned (`TunnelServer.later`).
    private let later: (@escaping () -> Void) -> Void
    private var endpoint4: OpaquePointer?
    private var endpoint6: OpaquePointer?
    private var pending: [UInt16: Pending] = [:]
    private var pendingByQuestion: [String: UInt16] = [:]
    private var cache: [String: Cached] = [:]
    /// Questions sent, answers taken, for the report.
    private(set) var questionsSent = 0
    private(set) var answersTaken = 0

    init(servers: [TunnelSettings.DNSServer], families: Set<TunnelAddress.Family>, tuning: Tuning = Tuning(),
         later: @escaping (@escaping () -> Void) -> Void) {
        // A server is asked only over a family the tunnel has.
        self.servers = servers.filter { families.contains($0.address.family) }
        self.families = families
        self.tuning = tuning
        self.later = later
    }

    deinit { close() }

    func close() {
        if let endpoint4 { lumen_udp_free(endpoint4) }
        if let endpoint6 { lumen_udp_free(endpoint6) }
        endpoint4 = nil
        endpoint6 = nil
        for (_, query) in pending {
            for waiter in query.waiters { waiter(.failure(.noAnswer)) }
        }
        pending = [:]
        pendingByQuestion = [:]
    }

    /// Looks `name` up; `completion` runs later (never inside this call), once.
    func resolve(_ name: String, now: Double, completion: @escaping Completion) {
        let types: [DNSMessage.RecordType] = families.contains(.v4) ? (families.contains(.v6) ? [.a, .aaaa] : [.a]) : [.aaaa]
        resolve(name, types: types[...], now: now, completion: completion)
    }

    private func resolve(_ name: String, types: ArraySlice<DNSMessage.RecordType>, now: Double, completion: @escaping Completion) {
        guard let type = types.first else {
            later { completion(.failure(.noAnswer)) }
            return
        }
        let rest = types.dropFirst()
        let next: Completion = { [weak self] result in
            switch result {
            case .success(let addresses) where !addresses.isEmpty:
                completion(result)
            case .failure(.noSuchName):
                completion(result)
            default:
                guard let self, !rest.isEmpty else {
                    completion(result.flatMap { $0.isEmpty ? .failure(.noAnswer) : .success($0) })
                    return
                }
                self.resolve(name, types: rest, now: TunnelSystem.now, completion: completion)
            }
        }
        ask(name, type: type, now: now, completion: next)
    }

    private func ask(_ name: String, type: DNSMessage.RecordType, now: Double, completion: @escaping Completion) {
        let key = "\(type.rawValue) \(name)"
        if let cached = cache[key] {
            if cached.expires > now {
                let result: Result<[TunnelAddress], ResolverFailure> = cached.noSuchName ? .failure(.noSuchName) : .success(cached.addresses)
                later { completion(result) }
                return
            }
            cache[key] = nil
        }
        if let id = pendingByQuestion[key] {
            pending[id]?.waiters.append(completion)
            return
        }
        guard !servers.isEmpty else {
            later { completion(.failure(.noAnswer)) }
            return
        }
        var id = UInt16(truncatingIfNeeded: lumen_net_random())
        while pending[id] != nil { id &+= 1 }
        var query = Pending(name: name, type: type, id: id, serverIndex: 0, attempt: 0, deadline: now, waiters: [completion])
        guard send(&query, now: now) else {
            later { completion(.failure(.noAnswer)) }
            return
        }
        pending[id] = query
        pendingByQuestion[key] = id
    }

    @discardableResult
    private func send(_ query: inout Pending, now: Double) -> Bool {
        let server = servers[query.serverIndex % servers.count]
        guard let message = DNSMessage.query(id: query.id, name: query.name, type: query.type),
              let endpoint = endpoint(for: server.address.family) else { return false }
        query.attempt += 1
        query.deadline = now + tuning.attemptTimeout
        questionsSent += 1
        let sent = message.withUnsafeBufferPointer { bytes in
            server.address.bytes.withUnsafeBufferPointer { address in
                lumen_udp_send(endpoint, server.address.family.rawValue, address.baseAddress, server.port,
                               bytes.baseAddress, bytes.count)
            }
        }
        // A send lwIP refused (no route yet, no memory) is asked again at the deadline.
        _ = sent
        return true
    }

    private func endpoint(for family: TunnelAddress.Family) -> OpaquePointer? {
        let context = Unmanaged.passUnretained(self).toOpaque()
        switch family {
        case .v4:
            if endpoint4 == nil { endpoint4 = lumen_udp_open(4, resolverReceive, context) }
            return endpoint4
        case .v6:
            if endpoint6 == nil { endpoint6 = lumen_udp_open(6, resolverReceive, context) }
            return endpoint6
        }
    }

    /// The soonest deadline of a question in flight.
    var nextDeadline: Double? { pending.values.map(\.deadline).min() }

    /// Asks again the questions whose deadline passed, or gives them up.
    func tick(now: Double) {
        for id in Array(pending.keys) {
            guard var query = pending[id], query.deadline <= now else { continue }
            if query.attempt >= tuning.attempts {
                finish(id, .failure(.noAnswer), cacheFor: nil, now: now)
                continue
            }
            query.serverIndex += 1
            send(&query, now: now)
            pending[id] = query
        }
    }

    /// A datagram to one of the resolver's endpoints (inside lwIP's input: only noted, completions later).
    fileprivate func received(from address: TunnelAddress, port: UInt16, bytes: [UInt8]) {
        guard bytes.count >= 2 else { return }
        let id = UInt16(bytes[0]) << 8 | UInt16(bytes[1])
        guard var query = pending[id] else { return }
        let server = servers[query.serverIndex % servers.count]
        // Only the server asked, from its port.
        guard server.address == address, server.port == port else { return }
        guard let answer = DNSMessage.readAnswer(bytes, name: query.name, type: query.type), answer.id == id else { return }
        let now = TunnelSystem.now
        answersTaken += 1
        switch answer.outcome {
        case .addresses(let addresses, let ttl):
            if addresses.isEmpty && answer.truncated {
                // Cut short with nothing usable in it: no TCP fallback here; the next server is
                // asked at the next tick (nothing is sent from inside lwIP's input).
                query.deadline = 0
                pending[id] = query
                return
            }
            let lifetime = min(max(Double(ttl), tuning.minimumTTL), tuning.maximumTTL)
            finish(id, .success(addresses), cacheFor: (addresses, false, addresses.isEmpty ? min(Double(ttl), tuning.maximumNegativeTTL) : lifetime), now: now)
        case .noSuchName(let ttl):
            finish(id, .failure(.noSuchName), cacheFor: ([], true, min(max(Double(ttl), 10), tuning.maximumNegativeTTL)), now: now)
        case .serverFailure:
            // The next server, at the next tick.
            query.deadline = 0
            pending[id] = query
        }
    }

    private func finish(_ id: UInt16, _ result: Result<[TunnelAddress], ResolverFailure>,
                        cacheFor entry: (addresses: [TunnelAddress], noSuchName: Bool, lifetime: Double)?, now: Double) {
        guard let query = pending.removeValue(forKey: id) else { return }
        let key = "\(query.type.rawValue) \(query.name)"
        pendingByQuestion[key] = nil
        if let entry, entry.lifetime > 0 {
            if cache.count >= tuning.cacheLimit {
                cache = cache.filter { $0.value.expires > now }
                if cache.count >= tuning.cacheLimit, let first = cache.keys.first { cache[first] = nil }
            }
            cache[key] = Cached(addresses: entry.addresses, noSuchName: entry.noSuchName, expires: now + entry.lifetime)
        }
        let waiters = query.waiters
        later { for waiter in waiters { waiter(result) } }
    }
}

/// Why a name was not found.
public enum ResolverFailure: Error, Equatable {
    case noSuchName
    case noAnswer
}

private let resolverReceive: lumen_udp_receive = { context, family, address, port, bytes, length in
    guard let context, let address else { return }
    let resolver = Unmanaged<TunnelResolver>.fromOpaque(context).takeUnretainedValue()
    let addressBytes = Array(UnsafeBufferPointer(start: address, count: family == 4 ? 4 : 16))
    guard let from = TunnelAddress(family: family == 4 ? .v4 : .v6, bytes: addressBytes) else { return }
    let payload = bytes.map { Array(UnsafeBufferPointer(start: $0, count: length)) } ?? []
    resolver.received(from: from, port: port, bytes: payload)
}
