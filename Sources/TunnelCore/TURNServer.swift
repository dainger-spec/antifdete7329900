#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

/// The UDP path from an allocation to the Internet: in the tunnel, a SOCKS5 UDP association
/// through the profile's proxy. Implementations call back on the queue the TURN server runs on.
public protocol PeerRelay: AnyObject {
    func send(_ payload: [UInt8], to peer: SocketAddress)
    func close()
}

public protocol PeerRelayFactory: AnyObject {
    /// Opens a relay for one allocation of `route`. `onReady` gets the public address peers
    /// reach it at (the proxy's egress, found with STUN through the proxy) or an error;
    /// `onReceive` gets every datagram a peer sends to it; `onClosed` says the relay died after
    /// it was ready (the proxy dropped the association).
    func openRelay(for route: TunnelRoute, family: IPAddr.Family,
                   onReady: @escaping (Result<SocketAddress, Error>) -> Void,
                   onReceive: @escaping (SocketAddress, [UInt8]) -> Void,
                   onClosed: @escaping () -> Void) -> PeerRelay
}

/// A TURN server (RFC 8656, UDP allocations only) for one route: what a profile's pages use as
/// their only ICE server. Every allocation's relayed traffic goes through the profile's proxy,
/// so the address peers and STUN-checking sites see is the proxy's, never this Mac's.
///
/// Shaped for WebKit's libwebrtc, the only client: it never sends REQUESTED-ADDRESS-FAMILY, so an
/// allocation takes the family of the server address it was sent to (the IPv6 relay URL gives an
/// IPv6 relay); it also uses the server as a STUN server (a Binding at once, then every 10 s),
/// which is answered with the proxy's egress, never with the client's own address — that one is
/// this Mac's and a page reads it back from `getStats()`.
///
/// Not thread-safe: the owner calls it, and the relays call back, on one serial queue.
public final class TURNServer {
    public typealias SendToClient = (_ payload: [UInt8], _ client: SocketAddress, _ server: SocketAddress) -> Void

    public static let defaultLifetime: UInt32 = 600
    public static let maximumLifetime: UInt32 = 3600
    public static let permissionLifetime: Double = 300
    public static let channelLifetime: Double = 600
    public static let nonceLifetime: Double = 3600
    /// Allocations per route: a page normally needs one or two (IPv4, IPv6) per peer connection.
    public static let maximumAllocations = 64
    /// After a failed egress probe, Bindings are refused for this long before the proxy is tried again.
    public static let egressRetryInterval: Double = 30

    public let route: TunnelRoute
    private let relays: PeerRelayFactory
    private let now: () -> Double
    private let send: SendToClient
    private let log: (String) -> Void
    private let key: [UInt8]
    private let nonceSecret = SymmetricKey(size: .bits256)
    private var allocations: [FiveTuple: Allocation] = [:]
    /// The proxy's egress per family, as the last relay through it found it: a Binding's answer.
    private var egress: [IPAddr.Family: SocketAddress] = [:]
    private var egressProbes: [IPAddr.Family: PeerRelay] = [:]
    private var egressFailures: [IPAddr.Family: Double] = [:]

    struct FiveTuple: Hashable {
        var client: SocketAddress
        var server: SocketAddress
    }

    final class Allocation {
        let tuple: FiveTuple
        let family: IPAddr.Family
        var relay: PeerRelay?
        /// Nil until the relay is ready.
        var relayed: SocketAddress?
        var expiresAt: Double
        var permissions: [IPAddr: Double] = [:]
        var channels: [UInt16: (peer: SocketAddress, expiresAt: Double)] = [:]
        var channelOfPeer: [SocketAddress: UInt16] = [:]
        /// The Allocate that created it: a retransmission gets the same answer.
        let allocateTransaction: [UInt8]
        var allocateResponse: [UInt8]?
        let requestedLifetime: UInt32
        let fingerprint: Bool

        init(tuple: FiveTuple, family: IPAddr.Family, expiresAt: Double, allocateTransaction: [UInt8],
             requestedLifetime: UInt32, fingerprint: Bool) {
            self.tuple = tuple
            self.family = family
            self.expiresAt = expiresAt
            self.allocateTransaction = allocateTransaction
            self.requestedLifetime = requestedLifetime
            self.fingerprint = fingerprint
        }
    }

    public init(route: TunnelRoute, relays: PeerRelayFactory, now: @escaping () -> Double = { Date().timeIntervalSince1970 },
                send: @escaping SendToClient, log: @escaping (String) -> Void = { _ in }) {
        self.route = route
        self.relays = relays
        self.now = now
        self.send = send
        self.log = log
        key = STUNMessage.longTermKey(username: route.username, realm: route.realm, password: route.password)
    }

    public var allocationCount: Int { allocations.count }

    /// A datagram from a client (a page's TURN socket) to this server's address `server`.
    public func receive(_ payload: [UInt8], from client: SocketAddress, to server: SocketAddress) {
        let tuple = FiveTuple(client: client, server: server)
        if let first = payload.first, first & 0xC0 == 0x40 {
            receiveChannelData(payload, tuple: tuple)
            return
        }
        guard let message = STUNMessage.parse(payload), STUNMessage.verifyFingerprint(payload) else { return }
        switch (message.messageClass, STUNMessage.Method(rawValue: message.method)) {
        case (.request, .binding?):
            binding(message, tuple: tuple)
        case (.request, .allocate?), (.request, .refresh?), (.request, .createPermission?), (.request, .channelBind?):
            guard authenticate(message, raw: payload, tuple: tuple) else { return }
            handleAuthenticated(message, tuple: tuple)
        case (.indication, .send?):
            receiveSendIndication(message, tuple: tuple)
        case (.request, _):
            respondError(to: message, tuple: tuple, code: 400, reason: "Bad Request", authenticated: false)
        default:
            break // responses and unknown indications are ignored
        }
    }

    /// Drops what has expired: allocations (and their relays), permissions, channels.
    public func expire() {
        let time = now()
        for (tuple, allocation) in allocations where allocation.expiresAt <= time {
            close(allocation)
            allocations[tuple] = nil
        }
        for allocation in allocations.values {
            allocation.permissions = allocation.permissions.filter { $0.value > time }
            for (number, channel) in allocation.channels where channel.expiresAt <= time {
                allocation.channels[number] = nil
                allocation.channelOfPeer[channel.peer] = nil
            }
        }
    }

    public func shutdown() {
        for allocation in allocations.values { close(allocation) }
        allocations.removeAll()
        for probe in egressProbes.values { probe.close() }
        egressProbes.removeAll()
    }

    // MARK: Binding (the server as a STUN server)

    /// Answers with the proxy's egress for the family of the address the Binding was sent to. Until
    /// it is known, a relay through the proxy finds it and the Binding goes unanswered: the client
    /// retransmits (after 250 ms, then doubling), and a retransmission gets the answer.
    private func binding(_ message: STUNMessage, tuple: FiveTuple) {
        let family = tuple.server.ip.family
        let failedRecently = { self.egressFailures[family].map { self.now() - $0 < Self.egressRetryInterval } ?? false }
        if egress[family] == nil, !failedRecently() { probeEgress(family) }
        if let address = egress[family] {
            respond(to: message, tuple: tuple, authenticated: false,
                    attributes: [(STUNMessage.Attribute.xorMappedAddress, STUNMessage.xorAddress(address, transactionID: message.transactionID))])
        } else if failedRecently() {
            // The client gives up on this server at once instead of retransmitting for ~40 s.
            respondError(to: message, tuple: tuple, code: 500, reason: "Server Error", authenticated: false)
        }
    }

    private func probeEgress(_ family: IPAddr.Family) {
        guard egressProbes[family] == nil else { return }
        var finished = false
        let probe = relays.openRelay(for: route, family: family, onReady: { [weak self] result in
            guard let self, !finished else { return }
            finished = true
            switch result {
            case let .success(address) where address.family == family:
                self.egress[family] = address
                self.egressFailures[family] = nil
                self.log("egress \(family): \(address)")
            case .success:
                self.egressFailures[family] = self.now()
                self.log("egress \(family): the proxy has none")
            case let .failure(error):
                self.egressFailures[family] = self.now()
                self.log("egress \(family) probe failed: \(error)")
            }
            self.egressProbes[family]?.close()
            self.egressProbes[family] = nil
        }, onReceive: { _, _ in }, onClosed: {})
        // A relay may answer before `openRelay` returns: it is closed then and not kept.
        if finished { probe.close() } else { egressProbes[family] = probe }
    }

    // MARK: Authentication (long-term credentials)

    /// Answers 401/438 itself and returns false when the request is not authenticated.
    private func authenticate(_ message: STUNMessage, raw: [UInt8], tuple: FiveTuple) -> Bool {
        guard message.attribute(STUNMessage.Attribute.messageIntegrity) != nil,
              let username = message.attribute(STUNMessage.Attribute.username),
              let realm = message.attribute(STUNMessage.Attribute.realm),
              let nonce = message.attribute(STUNMessage.Attribute.nonce) else {
            respondChallenge(to: message, tuple: tuple, code: 401, reason: "Unauthorized")
            return false
        }
        guard String(decoding: username, as: UTF8.self) == route.username,
              String(decoding: realm, as: UTF8.self) == route.realm,
              STUNMessage.verifyIntegrity(raw, key: key) else {
            respondChallenge(to: message, tuple: tuple, code: 401, reason: "Unauthorized")
            return false
        }
        guard isValidNonce(String(decoding: nonce, as: UTF8.self)) else {
            respondChallenge(to: message, tuple: tuple, code: 438, reason: "Stale Nonce")
            return false
        }
        return true
    }

    /// A nonce that carries its own expiry and a MAC of it, so nothing has to be stored.
    private func makeNonce() -> String {
        let expiry = String(Int(now() + Self.nonceLifetime))
        let mac = HMAC<SHA256>.authenticationCode(for: Array(expiry.utf8), using: nonceSecret)
        return expiry + "-" + mac.prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    private func isValidNonce(_ nonce: String) -> Bool {
        let parts = nonce.split(separator: "-", maxSplits: 1).map(String.init)
        guard parts.count == 2, let expiry = Double(parts[0]), expiry > now() else { return false }
        let mac = HMAC<SHA256>.authenticationCode(for: Array(parts[0].utf8), using: nonceSecret)
        return constantTimeEqual(Array(mac.prefix(12).map { String(format: "%02x", $0) }.joined().utf8), Array(parts[1].utf8))
    }

    private func respondChallenge(to message: STUNMessage, tuple: FiveTuple, code: Int, reason: String) {
        respondError(to: message, tuple: tuple, code: code, reason: reason, authenticated: false,
                     extra: [(STUNMessage.Attribute.realm, Array(route.realm.utf8)),
                             (STUNMessage.Attribute.nonce, Array(makeNonce().utf8))])
    }

    // MARK: Requests

    private func handleAuthenticated(_ message: STUNMessage, tuple: FiveTuple) {
        if let unknown = unknownRequiredAttributes(message), !unknown.isEmpty {
            respondError(to: message, tuple: tuple, code: 420, reason: "Unknown Attribute",
                         extra: [(STUNMessage.Attribute.unknownAttributes, unknown.flatMap(be16))])
            return
        }
        switch STUNMessage.Method(rawValue: message.method) {
        case .allocate?: allocate(message, tuple: tuple)
        case .refresh?: refresh(message, tuple: tuple)
        case .createPermission?: createPermission(message, tuple: tuple)
        case .channelBind?: channelBind(message, tuple: tuple)
        default: break
        }
    }

    /// Comprehension-required attributes this server does not act on. DONT-FRAGMENT is accepted
    /// (the proxy decides fragmentation); EVEN-PORT and RESERVATION-TOKEN are not supported.
    private func unknownRequiredAttributes(_ message: STUNMessage) -> [UInt16]? {
        let known: Set<UInt16> = [
            STUNMessage.Attribute.username, STUNMessage.Attribute.messageIntegrity, STUNMessage.Attribute.realm,
            STUNMessage.Attribute.nonce, STUNMessage.Attribute.lifetime, STUNMessage.Attribute.requestedTransport,
            STUNMessage.Attribute.requestedAddressFamily, STUNMessage.Attribute.dontFragment,
            STUNMessage.Attribute.xorPeerAddress, STUNMessage.Attribute.channelNumber, STUNMessage.Attribute.data,
            STUNMessage.Attribute.messageIntegritySHA256,
        ]
        return message.attributes.map(\.type).filter { STUNMessage.Attribute.isComprehensionRequired($0) && !known.contains($0) }
    }

    private func allocate(_ message: STUNMessage, tuple: FiveTuple) {
        if let existing = allocations[tuple] {
            if existing.allocateTransaction == message.transactionID {
                if let response = existing.allocateResponse { send(response, tuple.client, tuple.server) }
            } else {
                respondError(to: message, tuple: tuple, code: 437, reason: "Allocation Mismatch")
            }
            return
        }
        guard let transport = message.attribute(STUNMessage.Attribute.requestedTransport), transport.count == 4 else {
            respondError(to: message, tuple: tuple, code: 400, reason: "Bad Request")
            return
        }
        guard transport[0] == IPPacket.udp else {
            respondError(to: message, tuple: tuple, code: 442, reason: "Unsupported Transport Protocol")
            return
        }
        // Without REQUESTED-ADDRESS-FAMILY (libwebrtc never sends it) the family of the server
        // address: RFC 8656 says IPv4, but then the IPv6 relay URL would give a second IPv4 relay
        // and IPv6 peers none. libwebrtc accepts either.
        var family = tuple.server.ip.family
        if let requested = message.attribute(STUNMessage.Attribute.requestedAddressFamily) {
            guard requested.count == 4, requested[0] == 1 || requested[0] == 2 else {
                respondError(to: message, tuple: tuple, code: 440, reason: "Address Family not Supported")
                return
            }
            family = requested[0] == 1 ? .v4 : .v6
        }
        guard allocations.count < Self.maximumAllocations else {
            respondError(to: message, tuple: tuple, code: 486, reason: "Allocation Quota Reached")
            return
        }
        let lifetime = requestedLifetime(message)
        guard lifetime > 0 else {
            respondError(to: message, tuple: tuple, code: 400, reason: "Bad Request")
            return
        }
        let allocation = Allocation(tuple: tuple, family: family, expiresAt: now() + Double(lifetime),
                                    allocateTransaction: message.transactionID, requestedLifetime: lifetime,
                                    fingerprint: message.attribute(STUNMessage.Attribute.fingerprint) != nil)
        allocations[tuple] = allocation
        log("allocate \(tuple.client) family=\(family)")
        let relay = relays.openRelay(for: route, family: family, onReady: { [weak self, weak allocation] result in
            guard let self, let allocation, self.allocations[tuple] === allocation else { return }
            self.relayReady(allocation, message: message, result: result)
        }, onReceive: { [weak self, weak allocation] peer, payload in
            guard let self, let allocation, self.allocations[tuple] === allocation else { return }
            self.receiveFromPeer(peer, payload, allocation: allocation)
        }, onClosed: { [weak self, weak allocation] in
            // Without its association the allocation cannot carry anything: drop it, so the
            // browser's next Refresh gets 437 and it allocates again (through a new association).
            guard let self, let allocation, self.allocations[tuple] === allocation else { return }
            self.log("relay of \(tuple.client) closed by the proxy")
            self.close(allocation)
            self.allocations[tuple] = nil
        })
        // A relay may fail before `openRelay` returns: the allocation is gone then, and so must the relay be.
        if allocations[tuple] === allocation {
            allocation.relay = relay
        } else {
            relay.close()
        }
    }

    private func relayReady(_ allocation: Allocation, message: STUNMessage, result: Result<SocketAddress, Error>) {
        let tuple = allocation.tuple
        switch result {
        case let .success(relayed) where relayed.family == allocation.family:
            allocation.relayed = relayed
            egress[allocation.family] = relayed
            // The mapped address is the proxy's egress as well: the client's own is this Mac's.
            let response = encodeResponse(to: message, attributes: [
                (STUNMessage.Attribute.xorRelayedAddress, STUNMessage.xorAddress(relayed, transactionID: message.transactionID)),
                (STUNMessage.Attribute.xorMappedAddress, STUNMessage.xorAddress(relayed, transactionID: message.transactionID)),
                (STUNMessage.Attribute.lifetime, STUNMessage.uint32(allocation.requestedLifetime)),
            ], authenticated: true)
            allocation.allocateResponse = response
            send(response, tuple.client, tuple.server)
            log("allocated \(tuple.client) relayed=\(relayed)")
        case .success:
            log("allocation \(tuple.client): the proxy has no \(allocation.family) egress")
            fail(allocation, message: message, code: 440, reason: "Address Family not Supported")
        case let .failure(error):
            log("allocation \(tuple.client) failed: \(error)")
            fail(allocation, message: message, code: 508, reason: "Insufficient Capacity")
        }
    }

    private func fail(_ allocation: Allocation, message: STUNMessage, code: Int, reason: String) {
        close(allocation)
        allocations[allocation.tuple] = nil
        respondError(to: message, tuple: allocation.tuple, code: code, reason: reason)
    }

    private func requestedLifetime(_ message: STUNMessage) -> UInt32 {
        guard let value = message.attribute(STUNMessage.Attribute.lifetime), let seconds = STUNMessage.decodeUInt32(value) else {
            return Self.defaultLifetime
        }
        return seconds == 0 ? 0 : min(max(seconds, Self.defaultLifetime), Self.maximumLifetime)
    }

    private func refresh(_ message: STUNMessage, tuple: FiveTuple) {
        guard let allocation = allocations[tuple] else {
            respondError(to: message, tuple: tuple, code: 437, reason: "Allocation Mismatch")
            return
        }
        var lifetime = Self.defaultLifetime
        if let value = message.attribute(STUNMessage.Attribute.lifetime), let seconds = STUNMessage.decodeUInt32(value) {
            lifetime = seconds == 0 ? 0 : min(max(seconds, Self.defaultLifetime), Self.maximumLifetime)
        }
        if lifetime == 0 {
            close(allocation)
            allocations[tuple] = nil
            log("deallocated \(tuple.client)")
        } else {
            allocation.expiresAt = now() + Double(lifetime)
        }
        respond(to: message, tuple: tuple, attributes: [(STUNMessage.Attribute.lifetime, STUNMessage.uint32(lifetime))])
    }

    private func createPermission(_ message: STUNMessage, tuple: FiveTuple) {
        guard let allocation = allocations[tuple], allocation.relayed != nil else {
            respondError(to: message, tuple: tuple, code: 437, reason: "Allocation Mismatch")
            return
        }
        let peers = message.attributes.filter { $0.type == STUNMessage.Attribute.xorPeerAddress }
            .compactMap { STUNMessage.decodeXorAddress($0.value, transactionID: message.transactionID) }
        guard !peers.isEmpty else {
            respondError(to: message, tuple: tuple, code: 400, reason: "Bad Request")
            return
        }
        guard peers.allSatisfy({ $0.family == allocation.family }) else {
            respondError(to: message, tuple: tuple, code: 443, reason: "Peer Address Family Mismatch")
            return
        }
        guard peers.allSatisfy({ isAllowedPeer($0) }) else {
            respondError(to: message, tuple: tuple, code: 403, reason: "Forbidden")
            return
        }
        let expiry = now() + Self.permissionLifetime
        for peer in peers { allocation.permissions[peer.ip] = expiry }
        respond(to: message, tuple: tuple, attributes: [])
    }

    private func channelBind(_ message: STUNMessage, tuple: FiveTuple) {
        guard let allocation = allocations[tuple], allocation.relayed != nil else {
            respondError(to: message, tuple: tuple, code: 437, reason: "Allocation Mismatch")
            return
        }
        guard let numberValue = message.attribute(STUNMessage.Attribute.channelNumber), numberValue.count == 4,
              let peerValue = message.attribute(STUNMessage.Attribute.xorPeerAddress),
              let peer = STUNMessage.decodeXorAddress(peerValue, transactionID: message.transactionID) else {
            respondError(to: message, tuple: tuple, code: 400, reason: "Bad Request")
            return
        }
        let number = get16(numberValue, 0)
        // 0x4000–0x4FFF (RFC 8656); RFC 5766 allowed up to 0x7FFF, which older clients still use.
        guard (0x4000...0x7FFF).contains(number) else {
            respondError(to: message, tuple: tuple, code: 400, reason: "Bad Request")
            return
        }
        guard peer.family == allocation.family else {
            respondError(to: message, tuple: tuple, code: 443, reason: "Peer Address Family Mismatch")
            return
        }
        guard isAllowedPeer(peer) else {
            respondError(to: message, tuple: tuple, code: 403, reason: "Forbidden")
            return
        }
        if let bound = allocation.channels[number], bound.peer != peer {
            respondError(to: message, tuple: tuple, code: 400, reason: "Bad Request")
            return
        }
        if let other = allocation.channelOfPeer[peer], other != number {
            respondError(to: message, tuple: tuple, code: 400, reason: "Bad Request")
            return
        }
        let time = now()
        allocation.channels[number] = (peer, time + Self.channelLifetime)
        allocation.channelOfPeer[peer] = number
        allocation.permissions[peer.ip] = max(allocation.permissions[peer.ip] ?? 0, time + Self.permissionLifetime)
        respond(to: message, tuple: tuple, attributes: [])
    }

    /// Peers the relay sends to: Internet addresses only. A private or loopback peer would be
    /// reached on the proxy's side — its host and its networks — and the relays and this Mac's
    /// own networks are no peers. libwebrtc drops just that peer's pair on a 403.
    private func isAllowedPeer(_ peer: SocketAddress) -> Bool {
        peer.port != 0 && peer.ip.isGlobalUnicast && !route.endpoints.contains { $0.ip == peer.ip }
    }

    // MARK: Data

    private func receiveSendIndication(_ message: STUNMessage, tuple: FiveTuple) {
        guard let allocation = allocations[tuple], allocation.relayed != nil,
              let peerValue = message.attribute(STUNMessage.Attribute.xorPeerAddress),
              let peer = STUNMessage.decodeXorAddress(peerValue, transactionID: message.transactionID),
              let data = message.attribute(STUNMessage.Attribute.data),
              peer.family == allocation.family,
              let permission = allocation.permissions[peer.ip], permission > now() else { return }
        allocation.relay?.send(data, to: peer)
    }

    private func receiveChannelData(_ payload: [UInt8], tuple: FiveTuple) {
        guard payload.count >= 4, let allocation = allocations[tuple] else { return }
        let number = get16(payload, 0)
        let length = Int(get16(payload, 2))
        guard payload.count >= 4 + length, let channel = allocation.channels[number], channel.expiresAt > now() else { return }
        allocation.relay?.send(Array(payload[4..<(4 + length)]), to: channel.peer)
    }

    private func receiveFromPeer(_ peer: SocketAddress, _ payload: [UInt8], allocation: Allocation) {
        let time = now()
        guard let permission = allocation.permissions[peer.ip], permission > time else { return }
        let tuple = allocation.tuple
        if let number = allocation.channelOfPeer[peer], let channel = allocation.channels[number], channel.expiresAt > time {
            // Unpadded, as libwebrtc sends it (over UDP the padding is optional).
            send(be16(number) + be16(UInt16(payload.count)) + payload, tuple.client, tuple.server)
        } else {
            var transaction = [UInt8](repeating: 0, count: 12)
            for index in transaction.indices { transaction[index] = UInt8.random(in: 0...255) }
            let indication = STUNMessage(method: STUNMessage.Method.data.rawValue, messageClass: .indication, transactionID: transaction,
                                         attributes: [(STUNMessage.Attribute.xorPeerAddress, STUNMessage.xorAddress(peer, transactionID: transaction)),
                                                      (STUNMessage.Attribute.data, payload)])
            send(indication.encode(fingerprint: allocation.fingerprint), tuple.client, tuple.server)
        }
    }

    // MARK: Responses

    private func encodeResponse(to request: STUNMessage, attributes: [(UInt16, [UInt8])], authenticated: Bool,
                                messageClass: STUNMessage.Class = .success) -> [UInt8] {
        let response = STUNMessage(method: request.method, messageClass: messageClass, transactionID: request.transactionID,
                                   attributes: attributes.map { (type: $0.0, value: $0.1) })
        return response.encode(integrityKey: authenticated ? key : nil,
                               fingerprint: request.attribute(STUNMessage.Attribute.fingerprint) != nil)
    }

    private func respond(to request: STUNMessage, tuple: FiveTuple, authenticated: Bool = true, attributes: [(UInt16, [UInt8])]) {
        send(encodeResponse(to: request, attributes: attributes, authenticated: authenticated), tuple.client, tuple.server)
    }

    private func respondError(to request: STUNMessage, tuple: FiveTuple, code: Int, reason: String, authenticated: Bool = true,
                              extra: [(UInt16, [UInt8])] = []) {
        let attributes = [(STUNMessage.Attribute.errorCode, STUNMessage.errorCode(code, reason: reason))] + extra
        send(encodeResponse(to: request, attributes: attributes, authenticated: authenticated, messageClass: .error),
             tuple.client, tuple.server)
    }

    private func close(_ allocation: Allocation) {
        allocation.relay?.close()
        allocation.relay = nil
    }
}
