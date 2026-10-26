import XCTest
@testable import TunnelCore

/// A relay that records what the TURN server sends through "the proxy", and lets the test play
/// the proxy's answers.
final class FakeRelayFactory: PeerRelayFactory {
    final class Relay: PeerRelay {
        let route: TunnelRoute
        let family: IPAddr.Family
        let onReady: (Result<SocketAddress, Error>) -> Void
        let onReceive: (SocketAddress, [UInt8]) -> Void
        let onClosed: () -> Void
        var sent: [(SocketAddress, [UInt8])] = []
        var closed = false

        init(route: TunnelRoute, family: IPAddr.Family, onReady: @escaping (Result<SocketAddress, Error>) -> Void,
             onReceive: @escaping (SocketAddress, [UInt8]) -> Void, onClosed: @escaping () -> Void) {
            self.route = route
            self.family = family
            self.onReady = onReady
            self.onReceive = onReceive
            self.onClosed = onClosed
        }

        func send(_ payload: [UInt8], to peer: SocketAddress) { sent.append((peer, payload)) }
        func close() { closed = true }
    }

    struct Refused: Error {}

    var relays: [Relay] = []
    /// When set, relays become ready at once with this egress (per route id).
    var egress: [String: SocketAddress] = [:]

    func openRelay(for route: TunnelRoute, family: IPAddr.Family, onReady: @escaping (Result<SocketAddress, Error>) -> Void,
                   onReceive: @escaping (SocketAddress, [UInt8]) -> Void, onClosed: @escaping () -> Void) -> PeerRelay {
        let relay = Relay(route: route, family: family, onReady: onReady, onReceive: onReceive, onClosed: onClosed)
        relays.append(relay)
        if let address = egress[route.id] { onReady(.success(address)) }
        return relay
    }
}

/// The client side of TURN, as a browser speaks it, for driving the server.
struct TURNTestClient {
    let username: String
    let realm: String
    let password: String
    var nonce: [UInt8]?

    var key: [UInt8] { STUNMessage.longTermKey(username: username, realm: realm, password: password) }

    static func transaction() -> [UInt8] { (0..<12).map { _ in UInt8.random(in: 0...255) } }

    func request(_ method: STUNMessage.Method, _ attributes: [(UInt16, [UInt8])], transaction: [UInt8] = transaction(),
                 authenticated: Bool = true) -> [UInt8] {
        var all = attributes.map { (type: $0.0, value: $0.1) }
        if authenticated, let nonce {
            all += [(STUNMessage.Attribute.username, Array(username.utf8)), (STUNMessage.Attribute.realm, Array(realm.utf8)),
                    (STUNMessage.Attribute.nonce, nonce)]
        }
        let message = STUNMessage(method: method.rawValue, messageClass: .request, transactionID: transaction, attributes: all)
        return message.encode(integrityKey: authenticated && nonce != nil ? key : nil, fingerprint: true)
    }
}

final class TURNServerTests: XCTestCase {
    let client = SocketAddress(ip: IPAddr("192.168.1.20")!, port: 50000)
    let relayAddress = SocketAddress(ip: TunnelAddressing.relayIPv4(slot: 0), port: 3478)
    let egress = SocketAddress(ip: IPAddr("203.0.113.9")!, port: 40001)
    let peer = SocketAddress(ip: IPAddr("198.51.100.7")!, port: 61000)

    var clock = 1_000_000.0
    var sent: [[UInt8]] = []
    var relays = FakeRelayFactory()
    var server: TURNServer!
    var turn = TURNTestClient(username: "user", realm: TunnelAddressing.realm, password: "secret", nonce: nil)

    func route(_ id: String = "route-a", slot: Int = 0, username: String = "user", password: String = "secret") -> TunnelRoute {
        TunnelRoute(id: id, relayIPv4: TunnelAddressing.relayIPv4(slot: slot), relayIPv6: TunnelAddressing.relayIPv6(slot: slot),
                    username: username, password: password, proxy: SOCKSProxy(host: "proxy.example", port: 1080))
    }

    override func setUp() {
        relays.egress["route-a"] = egress
        server = TURNServer(route: route(), relays: relays, now: { [unowned self] in self.clock },
                            send: { [unowned self] payload, client, server in
                                XCTAssertEqual(client, self.client)
                                XCTAssertEqual(server, self.relayAddress)
                                self.sent.append(payload)
                            })
    }

    func exchange(_ bytes: [UInt8]) throws -> STUNMessage {
        sent.removeAll()
        server.receive(bytes, from: client, to: relayAddress)
        let reply = try XCTUnwrap(sent.last, "no answer")
        return try XCTUnwrap(STUNMessage.parse(reply))
    }

    /// Unauthenticated Allocate → 401 with realm and nonce → authenticated Allocate → success.
    @discardableResult
    func allocate(family: UInt8? = nil) throws -> STUNMessage {
        var attributes: [(UInt16, [UInt8])] = [(STUNMessage.Attribute.requestedTransport, [17, 0, 0, 0])]
        if let family { attributes.append((STUNMessage.Attribute.requestedAddressFamily, [family, 0, 0, 0])) }
        let challenge = try exchange(turn.request(.allocate, attributes, authenticated: false))
        XCTAssertEqual(challenge.messageClass, .error)
        XCTAssertEqual(challenge.attribute(STUNMessage.Attribute.errorCode).flatMap(STUNMessage.decodeErrorCode), 401)
        XCTAssertEqual(challenge.attribute(STUNMessage.Attribute.realm), Array(TunnelAddressing.realm.utf8))
        turn.nonce = try XCTUnwrap(challenge.attribute(STUNMessage.Attribute.nonce))
        return try exchange(turn.request(.allocate, attributes))
    }

    func testAllocateAnswersWithTheProxyEgressAndAValidIntegrity() throws {
        let transaction = TURNTestClient.transaction()
        _ = try allocate()
        sent.removeAll()
        server.receive(turn.request(.allocate, [(STUNMessage.Attribute.requestedTransport, [17, 0, 0, 0])], transaction: transaction),
                       from: client, to: relayAddress)
        // A second Allocate with another transaction on the same 5-tuple: 437.
        let mismatch = try XCTUnwrap(STUNMessage.parse(try XCTUnwrap(sent.last)))
        XCTAssertEqual(mismatch.attribute(STUNMessage.Attribute.errorCode).flatMap(STUNMessage.decodeErrorCode), 437)
    }

    func testAllocateSuccessContents() throws {
        let success = try allocate()
        XCTAssertEqual(success.messageClass, .success)
        let raw = try XCTUnwrap(sent.last)
        XCTAssertTrue(STUNMessage.verifyIntegrity(raw, key: turn.key))
        XCTAssertTrue(STUNMessage.verifyFingerprint(raw))
        XCTAssertEqual(STUNMessage.decodeXorAddress(try XCTUnwrap(success.attribute(STUNMessage.Attribute.xorRelayedAddress)),
                                                    transactionID: success.transactionID), egress)
        // The mapped address is the egress too: the client's own address is this Mac's.
        XCTAssertEqual(STUNMessage.decodeXorAddress(try XCTUnwrap(success.attribute(STUNMessage.Attribute.xorMappedAddress)),
                                                    transactionID: success.transactionID), egress)
        XCTAssertEqual(success.attribute(STUNMessage.Attribute.lifetime).flatMap(STUNMessage.decodeUInt32), 600)
        XCTAssertEqual(server.allocationCount, 1)
        XCTAssertEqual(relays.relays.count, 1)
        XCTAssertEqual(relays.relays[0].route.proxy.host, "proxy.example")
    }

    func testRetransmittedAllocateGetsTheSameAnswer() throws {
        _ = try allocate()
        let first = try XCTUnwrap(sent.last)
        // Replay the exact request bytes: same transaction → same response, no second relay.
        let message = try XCTUnwrap(STUNMessage.parse(first))
        let replay = turn.request(.allocate, [(STUNMessage.Attribute.requestedTransport, [17, 0, 0, 0])], transaction: message.transactionID)
        sent.removeAll()
        server.receive(replay, from: client, to: relayAddress)
        XCTAssertEqual(sent.last, first)
        XCTAssertEqual(relays.relays.count, 1)
    }

    func testWrongPasswordAndStaleNonce() throws {
        _ = try exchange(turn.request(.allocate, [(STUNMessage.Attribute.requestedTransport, [17, 0, 0, 0])], authenticated: false))
        turn.nonce = try XCTUnwrap(STUNMessage.parse(try XCTUnwrap(sent.last))?.attribute(STUNMessage.Attribute.nonce))
        var impostor = turn
        impostor = TURNTestClient(username: "user", realm: TunnelAddressing.realm, password: "guess", nonce: turn.nonce)
        let rejected = try exchange(impostor.request(.allocate, [(STUNMessage.Attribute.requestedTransport, [17, 0, 0, 0])]))
        XCTAssertEqual(rejected.attribute(STUNMessage.Attribute.errorCode).flatMap(STUNMessage.decodeErrorCode), 401)
        XCTAssertTrue(relays.relays.isEmpty)
        clock += TURNServer.nonceLifetime + 1
        let stale = try exchange(turn.request(.allocate, [(STUNMessage.Attribute.requestedTransport, [17, 0, 0, 0])]))
        XCTAssertEqual(stale.attribute(STUNMessage.Attribute.errorCode).flatMap(STUNMessage.decodeErrorCode), 438)
        XCTAssertNotNil(stale.attribute(STUNMessage.Attribute.nonce))
    }

    func testUnsupportedRequestsAreRefused() throws {
        _ = try allocate(family: 2) // an IPv6 allocation while the proxy's egress is IPv4
        let answer = try XCTUnwrap(STUNMessage.parse(try XCTUnwrap(sent.last)))
        XCTAssertEqual(answer.attribute(STUNMessage.Attribute.errorCode).flatMap(STUNMessage.decodeErrorCode), 440)
        XCTAssertEqual(server.allocationCount, 0)
        XCTAssertTrue(relays.relays[0].closed)
        let tcp = try exchange(turn.request(.allocate, [(STUNMessage.Attribute.requestedTransport, [6, 0, 0, 0])]))
        XCTAssertEqual(tcp.attribute(STUNMessage.Attribute.errorCode).flatMap(STUNMessage.decodeErrorCode), 442)
        let evenPort = try exchange(turn.request(.allocate, [(STUNMessage.Attribute.requestedTransport, [17, 0, 0, 0]),
                                                            (STUNMessage.Attribute.evenPort, [0x80, 0, 0, 0])]))
        XCTAssertEqual(evenPort.attribute(STUNMessage.Attribute.errorCode).flatMap(STUNMessage.decodeErrorCode), 420)
        XCTAssertEqual(evenPort.attribute(STUNMessage.Attribute.unknownAttributes), [0x00, 0x18])
    }

    func testProxyFailureGives508AndNoAllocation() throws {
        relays.egress = [:]
        _ = try exchange(turn.request(.allocate, [(STUNMessage.Attribute.requestedTransport, [17, 0, 0, 0])], authenticated: false))
        turn.nonce = try XCTUnwrap(STUNMessage.parse(try XCTUnwrap(sent.last))?.attribute(STUNMessage.Attribute.nonce))
        sent.removeAll()
        server.receive(turn.request(.allocate, [(STUNMessage.Attribute.requestedTransport, [17, 0, 0, 0])]), from: client, to: relayAddress)
        XCTAssertTrue(sent.isEmpty, "no answer until the proxy answered")
        relays.relays[0].onReady(.failure(FakeRelayFactory.Refused()))
        let answer = try XCTUnwrap(STUNMessage.parse(try XCTUnwrap(sent.last)))
        XCTAssertEqual(answer.attribute(STUNMessage.Attribute.errorCode).flatMap(STUNMessage.decodeErrorCode), 508)
        XCTAssertTrue(STUNMessage.verifyIntegrity(try XCTUnwrap(sent.last), key: turn.key))
        XCTAssertEqual(server.allocationCount, 0)
        XCTAssertTrue(relays.relays[0].closed)
    }

    func testPermissionsSendAndDataIndications() throws {
        try allocate()
        let relay = relays.relays[0]
        let peerAttribute = { (transaction: [UInt8]) in STUNMessage.xorAddress(self.peer, transactionID: transaction) }

        // Without a permission nothing is sent and nothing comes back.
        let earlyTransaction = TURNTestClient.transaction()
        server.receive(STUNMessage(method: STUNMessage.Method.send.rawValue, messageClass: .indication, transactionID: earlyTransaction,
                                   attributes: [(STUNMessage.Attribute.xorPeerAddress, peerAttribute(earlyTransaction)),
                                                (STUNMessage.Attribute.data, [1, 2, 3])]).encode(), from: client, to: relayAddress)
        XCTAssertTrue(relay.sent.isEmpty)

        let permissionTransaction = TURNTestClient.transaction()
        let permission = try exchange(turn.request(.createPermission, [(STUNMessage.Attribute.xorPeerAddress, peerAttribute(permissionTransaction))],
                                                   transaction: permissionTransaction))
        XCTAssertEqual(permission.messageClass, .success)

        let sendTransaction = TURNTestClient.transaction()
        server.receive(STUNMessage(method: STUNMessage.Method.send.rawValue, messageClass: .indication, transactionID: sendTransaction,
                                   attributes: [(STUNMessage.Attribute.xorPeerAddress, peerAttribute(sendTransaction)),
                                                (STUNMessage.Attribute.data, [1, 2, 3])]).encode(), from: client, to: relayAddress)
        XCTAssertEqual(relay.sent.count, 1)
        XCTAssertEqual(relay.sent[0].0, peer)
        XCTAssertEqual(relay.sent[0].1, [1, 2, 3])

        // The peer answers through the proxy: a Data indication to the client.
        sent.removeAll()
        relay.onReceive(peer, [9, 8, 7, 6, 5])
        let data = try XCTUnwrap(STUNMessage.parse(try XCTUnwrap(sent.last)))
        XCTAssertEqual(data.messageClass, .indication)
        XCTAssertEqual(data.method, STUNMessage.Method.data.rawValue)
        XCTAssertEqual(data.attribute(STUNMessage.Attribute.data), [9, 8, 7, 6, 5])
        XCTAssertEqual(STUNMessage.decodeXorAddress(try XCTUnwrap(data.attribute(STUNMessage.Attribute.xorPeerAddress)),
                                                    transactionID: data.transactionID), peer)

        // Another host the page has no permission for is not let through.
        sent.removeAll()
        relay.onReceive(SocketAddress(ip: IPAddr("198.51.100.8")!, port: 61000), [1])
        XCTAssertTrue(sent.isEmpty)

        // Permissions expire after 300 s.
        clock += TURNServer.permissionLifetime + 1
        server.expire()
        relay.onReceive(peer, [1])
        XCTAssertTrue(sent.isEmpty)
    }

    func testChannelsCarryDataBothWays() throws {
        try allocate()
        let relay = relays.relays[0]
        let transaction = TURNTestClient.transaction()
        let bind = try exchange(turn.request(.channelBind, [(STUNMessage.Attribute.channelNumber, [0x40, 0x01, 0, 0]),
                                                            (STUNMessage.Attribute.xorPeerAddress, STUNMessage.xorAddress(peer, transactionID: transaction))],
                                             transaction: transaction))
        XCTAssertEqual(bind.messageClass, .success)
        server.receive([0x40, 0x01, 0, 3, 7, 7, 7], from: client, to: relayAddress) // unpadded, as libwebrtc sends it
        XCTAssertEqual(relay.sent.last?.1, [7, 7, 7])
        XCTAssertEqual(relay.sent.last?.0, peer)
        server.receive([0x40, 0x01, 0, 2, 8, 8, 0, 0], from: client, to: relayAddress) // padded
        XCTAssertEqual(relay.sent.last?.1, [8, 8])
        sent.removeAll()
        relay.onReceive(peer, [1, 2, 3, 4, 5])
        XCTAssertEqual(sent.last, [0x40, 0x01, 0, 5, 1, 2, 3, 4, 5])
        // An unbound channel is ignored; the same channel for another peer is refused.
        server.receive([0x40, 0x02, 0, 1, 1, 0, 0, 0], from: client, to: relayAddress)
        XCTAssertEqual(relay.sent.count, 2)
        let other = SocketAddress(ip: IPAddr("198.51.100.9")!, port: 1)
        let otherTransaction = TURNTestClient.transaction()
        let conflict = try exchange(turn.request(.channelBind, [(STUNMessage.Attribute.channelNumber, [0x40, 0x01, 0, 0]),
                                                                (STUNMessage.Attribute.xorPeerAddress, STUNMessage.xorAddress(other, transactionID: otherTransaction))],
                                                 transaction: otherTransaction))
        XCTAssertEqual(conflict.attribute(STUNMessage.Attribute.errorCode).flatMap(STUNMessage.decodeErrorCode), 400)
        // An IPv6 peer on an IPv4 allocation: 443.
        let v6Transaction = TURNTestClient.transaction()
        let mismatch = try exchange(turn.request(.createPermission, [(STUNMessage.Attribute.xorPeerAddress,
                                                                      STUNMessage.xorAddress(SocketAddress(ip: IPAddr("2001:db8::1")!, port: 1), transactionID: v6Transaction))],
                                                 transaction: v6Transaction))
        XCTAssertEqual(mismatch.attribute(STUNMessage.Attribute.errorCode).flatMap(STUNMessage.decodeErrorCode), 443)
    }

    func testRefreshZeroDeallocatesAndExpiryCloses() throws {
        try allocate()
        let refreshed = try exchange(turn.request(.refresh, [(STUNMessage.Attribute.lifetime, STUNMessage.uint32(1200))]))
        XCTAssertEqual(refreshed.attribute(STUNMessage.Attribute.lifetime).flatMap(STUNMessage.decodeUInt32), 1200)
        let deallocated = try exchange(turn.request(.refresh, [(STUNMessage.Attribute.lifetime, STUNMessage.uint32(0))]))
        XCTAssertEqual(deallocated.messageClass, .success)
        XCTAssertEqual(server.allocationCount, 0)
        XCTAssertTrue(relays.relays[0].closed)
        let gone = try exchange(turn.request(.refresh, []))
        XCTAssertEqual(gone.attribute(STUNMessage.Attribute.errorCode).flatMap(STUNMessage.decodeErrorCode), 437)

        try allocate()
        clock += Double(TURNServer.defaultLifetime) + 1
        server.expire()
        XCTAssertEqual(server.allocationCount, 0)
        XCTAssertTrue(relays.relays[1].closed)
    }

    func testAProxyThatDropsTheAssociationEndsTheAllocation() throws {
        try allocate()
        relays.relays[0].onClosed()
        XCTAssertEqual(server.allocationCount, 0)
        XCTAssertTrue(relays.relays[0].closed)
        let refresh = try exchange(turn.request(.refresh, []))
        XCTAssertEqual(refresh.attribute(STUNMessage.Attribute.errorCode).flatMap(STUNMessage.decodeErrorCode), 437)
    }

    func testEgressProbe() throws {
        let probe = EgressProbe()
        let request = try XCTUnwrap(STUNMessage.parse(probe.request))
        XCTAssertEqual(request.messageClass, .request)
        let mapped = SocketAddress(ip: IPAddr("203.0.113.5")!, port: 4444)
        let response = STUNMessage(method: STUNMessage.Method.binding.rawValue, messageClass: .success, transactionID: probe.transactionID,
                                   attributes: [(STUNMessage.Attribute.xorMappedAddress, STUNMessage.xorAddress(mapped, transactionID: probe.transactionID))])
        XCTAssertEqual(probe.mappedAddress(in: response.encode()), mapped)
        XCTAssertNil(EgressProbe().mappedAddress(in: response.encode()), "another probe's answer")
        XCTAssertEqual(EgressProbe.destination("stun.example.org:3478"), .name("stun.example.org", port: 3478))
        XCTAssertEqual(EgressProbe.destination("[2001:db8::1]:19302"), .address(SocketAddress(ip: IPAddr("2001:db8::1")!, port: 19302)))
        XCTAssertNil(EgressProbe.destination("nonsense"))
    }

    func bindingRequest() -> [UInt8] {
        STUNMessage(method: STUNMessage.Method.binding.rawValue, messageClass: .request, transactionID: TURNTestClient.transaction())
            .encode(fingerprint: true)
    }

    /// libwebrtc sends the TURN server Bindings as well (no credentials): the answer is the proxy's
    /// egress, found through the proxy, never the client's own address.
    func testBindingIsAnsweredWithTheProxyEgress() throws {
        let answer = try exchange(bindingRequest())
        XCTAssertEqual(answer.messageClass, .success)
        XCTAssertNil(answer.attribute(STUNMessage.Attribute.messageIntegrity))
        XCTAssertEqual(STUNMessage.decodeXorAddress(try XCTUnwrap(answer.attribute(STUNMessage.Attribute.xorMappedAddress)),
                                                    transactionID: answer.transactionID), egress)
        // The probe relay is closed once it has answered; later Bindings reuse what it found.
        XCTAssertEqual(relays.relays.count, 1)
        XCTAssertEqual(relays.relays[0].family, .v4)
        XCTAssertTrue(relays.relays[0].closed)
        _ = try exchange(bindingRequest())
        XCTAssertEqual(relays.relays.count, 1)
    }

    func testBindingWaitsForASlowProxyAndBacksOffAfterAFailure() throws {
        relays.egress = [:]
        server.receive(bindingRequest(), from: client, to: relayAddress)
        server.receive(bindingRequest(), from: client, to: relayAddress) // a retransmission while the probe runs
        XCTAssertTrue(sent.isEmpty, "unanswered until the egress is known")
        XCTAssertEqual(relays.relays.count, 1, "one probe at a time")
        relays.relays[0].onReady(.failure(FakeRelayFactory.Refused()))
        XCTAssertTrue(relays.relays[0].closed)
        let refused = try exchange(bindingRequest())
        XCTAssertEqual(refused.attribute(STUNMessage.Attribute.errorCode).flatMap(STUNMessage.decodeErrorCode), 500)
        XCTAssertEqual(relays.relays.count, 1)

        clock += TURNServer.egressRetryInterval + 1
        sent.removeAll()
        server.receive(bindingRequest(), from: client, to: relayAddress)
        XCTAssertEqual(relays.relays.count, 2, "the proxy is tried again")
        relays.relays[1].onReady(.success(egress))
        let answer = try exchange(bindingRequest())
        XCTAssertEqual(STUNMessage.decodeXorAddress(try XCTUnwrap(answer.attribute(STUNMessage.Attribute.xorMappedAddress)),
                                                    transactionID: answer.transactionID), egress)
    }

    /// Sent to the IPv6 relay address without REQUESTED-ADDRESS-FAMILY (libwebrtc never sends it),
    /// an Allocate asks for an IPv6 relay.
    func testAllocationFamilyFollowsTheServerAddress() throws {
        let v6Server = SocketAddress(ip: TunnelAddressing.relayIPv6(slot: 0), port: 3478)
        let v6Egress = SocketAddress(ip: IPAddr("2001:db8:5::9")!, port: 40002)
        relays.egress["route-a"] = v6Egress
        var answers: [[UInt8]] = []
        let server = TURNServer(route: route(), relays: relays, now: { [unowned self] in self.clock },
                                send: { payload, _, _ in answers.append(payload) })
        let v6Client = SocketAddress(ip: IPAddr("2001:db8:1::20")!, port: 50000)
        let attributes: [(UInt16, [UInt8])] = [(STUNMessage.Attribute.requestedTransport, [17, 0, 0, 0])]
        server.receive(turn.request(.allocate, attributes, authenticated: false), from: v6Client, to: v6Server)
        turn.nonce = try XCTUnwrap(STUNMessage.parse(try XCTUnwrap(answers.last))?.attribute(STUNMessage.Attribute.nonce))
        server.receive(turn.request(.allocate, attributes), from: v6Client, to: v6Server)
        let success = try XCTUnwrap(STUNMessage.parse(try XCTUnwrap(answers.last)))
        XCTAssertEqual(success.messageClass, .success)
        XCTAssertEqual(relays.relays.last?.family, .v6)
        XCTAssertEqual(STUNMessage.decodeXorAddress(try XCTUnwrap(success.attribute(STUNMessage.Attribute.xorRelayedAddress)),
                                                    transactionID: success.transactionID), v6Egress)
    }
}

final class PacketRouterTests: XCTestCase {
    /// Two profiles with different proxies at once: each one's TURN traffic reaches its own server
    /// and leaves through its own proxy; one's credentials do not work at the other's address.
    func testRoutesSeveralProfilesAtOnce() throws {
        let relays = FakeRelayFactory()
        var out: [[UInt8]] = []
        let router = PacketRouter(relays: relays, emit: { out.append($0) })
        let a = TunnelRoute(id: "a", relayIPv4: TunnelAddressing.relayIPv4(slot: 0), relayIPv6: TunnelAddressing.relayIPv6(slot: 0),
                            username: "ua", password: "pa", proxy: SOCKSProxy(host: "proxy-a", port: 1080))
        let b = TunnelRoute(id: "b", relayIPv4: TunnelAddressing.relayIPv4(slot: 1), relayIPv6: TunnelAddressing.relayIPv6(slot: 1),
                            username: "ub", password: "pb", proxy: SOCKSProxy(host: "proxy-b", port: 1080))
        // B is reached at its IPv6 relay address, so its relay is an IPv6 one.
        relays.egress = ["a": SocketAddress(ip: IPAddr("203.0.113.1")!, port: 1), "b": SocketAddress(ip: IPAddr("2001:db8::2")!, port: 2)]
        router.register(a)
        router.register(b)
        XCTAssertEqual(router.routeIDs, ["a", "b"])

        let browser4 = SocketAddress(ip: IPAddr("192.168.1.20")!, port: 50000)
        let browser6 = SocketAddress(ip: IPAddr("fd6b:3a1c:94e2:1::1")!, port: 50001)

        func roundTrip(_ client: TURNTestClient, from: SocketAddress, to: SocketAddress, _ method: STUNMessage.Method = .allocate,
                       authenticated: Bool = true) throws -> STUNMessage {
            out.removeAll()
            let request = client.request(method, [(STUNMessage.Attribute.requestedTransport, [17, 0, 0, 0])], authenticated: authenticated)
            router.handlePacket(try XCTUnwrap(IPPacket.buildUDP(UDPDatagram(source: from, destination: to, payload: request))))
            let packet = try XCTUnwrap(out.last)
            let datagram = try XCTUnwrap(IPPacket.parseUDP(packet))
            XCTAssertEqual(datagram.source, to, "answers come from the virtual relay address")
            XCTAssertEqual(datagram.destination, from)
            return try XCTUnwrap(STUNMessage.parse(datagram.payload))
        }

        for (route, client) in [(a, browser4), (b, browser6)] {
            var turn = TURNTestClient(username: route.username, realm: route.realm, password: route.password, nonce: nil)
            let endpoint = client.family == .v4 ? route.endpoints[0] : route.endpoints[1]
            let challenge = try roundTrip(turn, from: client, to: endpoint, authenticated: false)
            turn.nonce = challenge.attribute(STUNMessage.Attribute.nonce)
            let success = try roundTrip(turn, from: client, to: endpoint)
            XCTAssertEqual(STUNMessage.decodeXorAddress(try XCTUnwrap(success.attribute(STUNMessage.Attribute.xorRelayedAddress)),
                                                        transactionID: success.transactionID), relays.egress[route.id])
        }
        XCTAssertEqual(relays.relays.map(\.route.proxy.host), ["proxy-a", "proxy-b"])
        XCTAssertEqual(router.allocationCount, 2)

        // B's credentials at A's address: refused.
        var intruder = TURNTestClient(username: "ub", realm: TunnelAddressing.realm, password: "pb", nonce: nil)
        let other = SocketAddress(ip: IPAddr("192.168.1.20")!, port: 50002)
        intruder.nonce = try roundTrip(intruder, from: other, to: a.endpoints[0], authenticated: false).attribute(STUNMessage.Attribute.nonce)
        let refused = try roundTrip(intruder, from: other, to: a.endpoints[0])
        XCTAssertEqual(refused.attribute(STUNMessage.Attribute.errorCode).flatMap(STUNMessage.decodeErrorCode), 401)

        // Anything not addressed to a relay is dropped.
        router.handlePacket(try XCTUnwrap(IPPacket.buildUDP(UDPDatagram(source: browser4, destination: SocketAddress(ip: IPAddr("198.18.0.99")!, port: 3478), payload: [0]))))
        XCTAssertEqual(router.droppedPackets, 1)

        router.unregister(id: "a")
        XCTAssertTrue(relays.relays[0].closed)
        XCTAssertFalse(relays.relays[1].closed)
        XCTAssertEqual(router.routeIDs, ["b"])
    }

    func testControlMessagesRoundTrip() throws {
        let route = TunnelRoute(id: "x", relayIPv4: TunnelAddressing.relayIPv4(slot: 5), relayIPv6: TunnelAddressing.relayIPv6(slot: 5),
                                username: "u", password: "p", proxy: SOCKSProxy(host: "h", port: 1, username: "pu", password: "pp"))
        for message in [TunnelControlMessage.register(route), .unregister(id: "x"), .status] {
            XCTAssertEqual(try TunnelControlMessage.decode(message.encoded()), message)
        }
        XCTAssertEqual(route.turnURLs, ["turn:198.18.0.15:3478?transport=udp", "turn:[fd6b:3a1c:94e2:1::f]:3478?transport=udp"])
        XCTAssertEqual(TunnelAddressing.relayIPv4(slot: 0).description, "198.18.0.10")
    }
}
