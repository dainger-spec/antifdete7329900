import Foundation

/// Everything on the guest's wire that the stack answers by itself, without a connection: ARP for
/// the gateway, a ping of the gateway, DHCP, DNS, and "nothing is there" for other UDP. TCP
/// segments are sorted out and handed back for `NetworkLoop` to end at the proxy.
///
/// No sockets and no clock of its own: a frame goes in with the time, frames come out.
struct LinkResponder {
    /// What a frame from the guest asks of the stack.
    enum Verdict {
        /// Nothing: not for the stack, not understood, or simply dropped.
        case ignore
        /// One frame to send back.
        case reply([UInt8])
        /// A TCP segment for the terminator, with who sent it.
        case tcp(source: VMNetMAC, packet: IPv4Packet, segment: TCPSegment)
    }

    /// How many "port unreachable" answers a second, and how many at once. Enough for a page
    /// whose every host is tried over QUIC first; not an echo of a flood.
    static let unreachablePerSecond = 100.0
    static let unreachableBurst = 100.0

    let configuration: VMNetConfiguration
    private let dhcp: DHCPServer
    private(set) var dns: DNSResponder
    private var identification = UInt16.random(in: 0...UInt16.max)
    private var unreachableTokens = LinkResponder.unreachableBurst
    private var unreachableRefilled = -Double.infinity

    init(configuration: VMNetConfiguration, dnsPoolCapacity: Int = 60_000) {
        self.configuration = configuration
        dhcp = DHCPServer(guestMAC: configuration.guestMAC, guestAddress: configuration.guestAddress,
                          gatewayAddress: configuration.gatewayAddress, prefixLength: configuration.prefixLength,
                          mtu: configuration.effectiveMTU)
        dns = DNSResponder(blockedHostSuffixes: configuration.blockedHostSuffixes, poolCapacity: dnsPoolCapacity)
    }

    /// The host name a fake address stands for, when the guest connects to it.
    mutating func name(forFakeAddress address: VMNetIPv4) -> String? {
        dns.name(for: address)
    }

    private var subnetBroadcast: VMNetIPv4 {
        VMNetIPv4(configuration.gatewayAddress.value | ~VMNetIPv4.mask(configuration.prefixLength))
    }

    /// Addresses that name more than one machine, or none: no error is ever sent about them.
    private func isUnicast(_ address: VMNetIPv4) -> Bool {
        address != .unspecified && address != .broadcast && address != subnetBroadcast && !address.isIn(0xE000_0000, 4)
    }

    mutating func handle(_ bytes: UnsafeRawBufferPointer, now: Double, counters: inout VMNetCounters) -> Verdict {
        guard let frame = EthernetFrame(bytes) else { return .ignore }
        // Frames for the gateway, and those for everybody; never one that claims to come from the
        // gateway or from a group address.
        let toGateway = frame.destination == configuration.gatewayMAC
        guard toGateway || frame.destination.isGroup, !frame.source.isGroup, frame.source != configuration.gatewayMAC else { return .ignore }
        switch frame.etherType {
        case EtherType.arp:
            return arp(frame)
        case EtherType.ipv4:
            // IPv6 and VLAN tags fall through to "ignore": the guest's network is IPv4, untagged.
            guard let packet = IPv4Packet(frame.payload), !packet.isFragment else { return .ignore }
            switch packet.proto {
            case IPProtocol.icmp: return toGateway ? icmp(frame, packet) : .ignore
            case IPProtocol.udp: return udp(frame, packet, toGateway: toGateway, now: now, counters: &counters)
            case IPProtocol.tcp:
                guard toGateway, isUnicast(packet.source), let segment = TCPSegment(packet.payload) else { return .ignore }
                return .tcp(source: frame.source, packet: packet, segment: segment)
            default: return .ignore
            }
        default:
            return .ignore
        }
    }

    /// "Who has the gateway's address?" is the one question answered. The guest's check that
    /// nobody else has its own address gets no answer, which is the answer it wants.
    private func arp(_ frame: EthernetFrame) -> Verdict {
        guard let request = ARPPacket(frame.payload), request.operation == ARPPacket.request,
              request.targetAddress == configuration.gatewayAddress else { return .ignore }
        let reply = ARPPacket(operation: ARPPacket.reply, senderMAC: configuration.gatewayMAC, senderAddress: configuration.gatewayAddress,
                              targetMAC: request.senderMAC, targetAddress: request.senderAddress)
        return .reply(reply.frame(destination: frame.source, source: configuration.gatewayMAC))
    }

    /// A ping of the gateway is answered; a ping of anything else goes nowhere.
    private mutating func icmp(_ frame: EthernetFrame, _ packet: IPv4Packet) -> Verdict {
        guard packet.destination == configuration.gatewayAddress, isUnicast(packet.source),
              let message = ICMPMessage(packet.payload), message.type == ICMPMessage.echoRequest, message.code == 0 else { return .ignore }
        return .reply(FrameBuilder.icmp(destinationMAC: frame.source, sourceMAC: configuration.gatewayMAC,
                                        source: configuration.gatewayAddress, destination: packet.source,
                                        type: ICMPMessage.echoReply, code: 0, rest: message.rest, payload: message.payload,
                                        identification: nextIdentification()))
    }

    private mutating func udp(_ frame: EthernetFrame, _ packet: IPv4Packet, toGateway: Bool, now: Double,
                              counters: inout VMNetCounters) -> Verdict {
        guard let datagram = UDPDatagram(packet.payload) else { return .ignore }
        if datagram.destinationPort == DHCPServer.serverPort {
            guard let message = DHCPServer.Message(datagram.payload), let reply = dhcp.reply(to: message) else { return .ignore }
            // To everybody, as slirp does: a client that has no address yet hears it for certain,
            // and the guest is the only one listening.
            return .reply(FrameBuilder.udp(destinationMAC: .broadcast, sourceMAC: configuration.gatewayMAC,
                                           source: configuration.gatewayAddress, sourcePort: DHCPServer.serverPort,
                                           destination: .broadcast, destinationPort: DHCPServer.clientPort,
                                           payload: reply, identification: nextIdentification()))
        }
        if datagram.destinationPort == DNSResponder.port, toGateway, isUnicast(packet.source), isUnicast(packet.destination) {
            // Whatever resolver the guest asked, the answer is the stack's own and comes "from"
            // that resolver: a resolver written into the guest gets nothing past the stack.
            let (reply, outcome) = dns.respond(to: datagram.payload)
            if outcome != .dropped { counters.dnsQueries += 1 }
            if outcome == .blocked { counters.dnsBlocked += 1 }
            guard let reply else { return .ignore }
            return .reply(FrameBuilder.udp(destinationMAC: frame.source, sourceMAC: configuration.gatewayMAC,
                                           source: packet.destination, sourcePort: DNSResponder.port,
                                           destination: packet.source, destinationPort: datagram.sourcePort,
                                           payload: reply, identification: nextIdentification()))
        }
        // Any other UDP has no way out. Said at once — "nothing listens there" — so that QUIC and
        // STUN give up now instead of after their timeouts. Not for broadcasts and multicast.
        counters.datagramsDropped += 1
        guard toGateway, isUnicast(packet.source), isUnicast(packet.destination), takeUnreachableToken(now) else { return .ignore }
        // The error quotes the datagram's IP header and its first eight bytes (RFC 792).
        let quoted = Array(packet.header) + Array(packet.payload.prefix(8))
        return quoted.withUnsafeBytes { quote in
            .reply(FrameBuilder.icmp(destinationMAC: frame.source, sourceMAC: configuration.gatewayMAC,
                                     source: packet.destination, destination: packet.source,
                                     type: ICMPMessage.destinationUnreachable, code: ICMPMessage.portUnreachable, rest: 0,
                                     payload: quote, identification: nextIdentification()))
        }
    }

    private mutating func takeUnreachableToken(_ now: Double) -> Bool {
        if unreachableRefilled.isFinite {
            unreachableTokens = min(Self.unreachableBurst, unreachableTokens + max(now - unreachableRefilled, 0) * Self.unreachablePerSecond)
        }
        unreachableRefilled = now
        guard unreachableTokens >= 1 else { return false }
        unreachableTokens -= 1
        return true
    }

    private mutating func nextIdentification() -> UInt16 {
        identification = identification &+ 1
        return identification
    }
}
