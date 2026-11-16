#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

// The guest's UDP through the proxy's UDP relay: SOCKS5 UDP ASSOCIATE (RFC 1928 §7). The pieces
// here are data — the header every relayed datagram carries, which address a reply is shown to
// the guest from, where the relay is, what may be relayed at all — so that they are tested
// without sockets. `NetworkLoop` owns the sockets.

/// An address as SOCKS5 writes one (ATYP and ADDR): an IPv4 address, an IPv6 one, or a name.
enum SOCKSAddress: Hashable {
    case ipv4(UInt32)
    case ipv6([UInt8])
    case name(String)

    static let typeIPv4: UInt8 = 1
    static let typeName: UInt8 = 3
    static let typeIPv6: UInt8 = 4

    /// From ATYP and the bytes of ADDR (for a name: its length byte, then the name). Nil for
    /// another type or the wrong length. An IPv4 address written as IPv6 (::ffff:a.b.c.d) is
    /// taken as the IPv4 address it is.
    init?<Bytes: Collection>(type: UInt8, bytes: Bytes) where Bytes.Element == UInt8 {
        let bytes = Array(bytes)
        switch type {
        case Self.typeIPv4:
            guard bytes.count == 4 else { return nil }
            self = .ipv4(bytes.reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
        case Self.typeIPv6:
            guard bytes.count == 16 else { return nil }
            if bytes[0..<10].allSatisfy({ $0 == 0 }), bytes[10] == 0xFF, bytes[11] == 0xFF {
                self = .ipv4(bytes[12...].reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
            } else {
                self = .ipv6(bytes)
            }
        case Self.typeName:
            guard let length = bytes.first, bytes.count == 1 + Int(length) else { return nil }
            self = .name(String(decoding: bytes[1...], as: UTF8.self))
        default:
            return nil
        }
    }

    /// 0.0.0.0 or ::, which in a proxy's answer means "my own address".
    var isUnspecified: Bool {
        switch self {
        case .ipv4(let value): return value == 0
        case .ipv6(let bytes): return bytes.allSatisfy { $0 == 0 }
        case .name: return false
        }
    }

    /// A name compared as the DNS responder compares names: lower case, without dots at its ends.
    var normalized: SOCKSAddress {
        if case .name(let name) = self { return .name(DNSResponder.normalized(name)) }
        return self
    }
}

/// The header of a datagram to and from the proxy's relay (RFC 1928 §7): RSV (two zero bytes),
/// FRAG, ATYP, DST.ADDR, DST.PORT, and the payload after it.
enum SOCKSDatagram {
    /// The guest's payload, for `target`: a name as a name (ATYP 3), so that the proxy resolves
    /// it; an address as an IPv4 address. Nil for a name SOCKS5 cannot carry (empty, or longer
    /// than 255 bytes).
    static func wrap(_ payload: UnsafeRawBufferPointer, to target: ProxyTarget) -> [UInt8]? {
        var bytes: [UInt8] = [0, 0, 0]
        switch target {
        case .name(let name, _):
            let text = Array(name.utf8)
            guard !text.isEmpty, text.count <= 255 else { return nil }
            bytes.reserveCapacity(7 + text.count + payload.count)
            bytes += [SOCKSAddress.typeName, UInt8(text.count)]
            bytes += text
        case .address(let address, _):
            bytes.reserveCapacity(10 + payload.count)
            bytes += [SOCKSAddress.typeIPv4, UInt8(address.value >> 24), UInt8(address.value >> 16 & 0xFF),
                      UInt8(address.value >> 8 & 0xFF), UInt8(address.value & 0xFF)]
        }
        bytes += [UInt8(target.port >> 8), UInt8(target.port & 0xFF)]
        bytes += payload
        return bytes
    }

    /// What a datagram from the relay says: where it came from, and where in `datagram` its
    /// payload starts. Nil for anything that is not a whole header, for RSV that is not zero, and
    /// for a fragment (FRAG ≠ 0: fragmentation is optional for a proxy, and not done here — a
    /// fragment is dropped, as the RFC lets an implementation that does not reassemble do).
    static func unwrap(_ datagram: UnsafeRawBufferPointer) -> (source: SOCKSAddress, port: UInt16, payloadOffset: Int)? {
        guard datagram.count >= 4, datagram[0] == 0, datagram[1] == 0, datagram[2] == 0 else { return nil }
        let type = datagram[3]
        let addressLength: Int
        switch type {
        case SOCKSAddress.typeIPv4: addressLength = 4
        case SOCKSAddress.typeIPv6: addressLength = 16
        case SOCKSAddress.typeName:
            guard datagram.count >= 5 else { return nil }
            addressLength = 1 + Int(datagram[4])
        default: return nil
        }
        let end = 4 + addressLength + 2
        guard datagram.count >= end,
              let source = SOCKSAddress(type: type, bytes: UnsafeRawBufferPointer(rebasing: datagram[4..<(4 + addressLength)])) else { return nil }
        if case .name(let name) = source, name.isEmpty { return nil }
        return (source, datagram.be16(end - 2), end)
    }
}

/// The guest's sending side as UDP associations are kept: one association, so one relay port at
/// the proxy, per address and port the guest sends from — whatever it sends to. A peer that
/// learns the relay's address for the guest's port (WebRTC's server-reflexive candidate) then
/// reaches that same port.
struct UDPKey: Hashable {
    var guestAddress: UInt32
    var guestPort: UInt16
}

/// What may be relayed at all, and where the relay is.
enum UDPRelayRules {
    /// Ports that are this machine's or its local network's and are never relayed, whatever the
    /// address: DNS and the time (answered here, `LinkResponder`), DHCP, NetBIOS, mDNS, LLMNR and
    /// SSDP. A datagram to one of them that the stack does not answer is answered "port unreachable".
    static let localPorts: Set<UInt16> = [53, 67, 68, 123, 137, 138, 1900, 5353, 5355]

    static func isRelayable(port: UInt16) -> Bool {
        port != 0 && !localPorts.contains(port)
    }

    /// Where the datagrams of an association go: the relay the proxy named (BND.ADDR, BND.PORT),
    /// read against the address the association's TCP connection reached (`proxy`).
    ///
    /// - 0.0.0.0 or `::`: the proxy's own address — what the RFC means by it.
    /// - the proxy's own address, or a public one: as named.
    /// - any other address that is not public (a private, loopback, link-local … one): the proxy's
    ///   own address with the port named. A proxy behind NAT names its address inside its own
    ///   network; and nothing of this Mac's is ever sent to an address of somebody's local
    ///   network on a proxy's word.
    /// - a name, or port 0: nil — the association fails.
    static func relayEndpoint(bound: SOCKSAddress, port: UInt16, proxy: SocketEndpoint) -> SocketEndpoint? {
        guard port != 0 else { return nil }
        let own = proxy.withPort(port)
        if bound.isUnspecified { return own }
        let proxyAddress = proxy.address
        switch bound {
        case .ipv4(let value):
            if proxyAddress == bound { return own }
            return DestinationPolicy.isRefusedRange(VMNetIPv4(value)) ? own : SocketEndpoint.ipv4(value, port: port)
        case .ipv6(let bytes):
            if proxyAddress == bound { return own }
            return isPublicIPv6(bytes) ? SocketEndpoint.ipv6(bytes, port: port) : own
        case .name:
            return nil
        }
    }

    /// Global unicast IPv6 (2000::/3) that is not a documentation, ORCHID or 6to4/Teredo-wrapped
    /// private one: anything else — loopback, link-local, unique-local, multicast, mapped,
    /// NAT64 — is not taken as a relay's address.
    static func isPublicIPv6(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == 16, bytes[0] & 0xE0 == 0x20 else { return false }
        // 2001:db8::/32 (documentation), 2001::/32 (Teredo), 2002::/16 (6to4), 2001:10::/28 (ORCHID).
        if bytes[0] == 0x20, bytes[1] == 0x01, bytes[2] == 0x0D, bytes[3] == 0xB8 { return false }
        if bytes[0] == 0x20, bytes[1] == 0x01, bytes[2] == 0x00, bytes[3] == 0x00 { return false }
        if bytes[0] == 0x20, bytes[1] == 0x02 { return false }
        if bytes[0] == 0x20, bytes[1] == 0x01, bytes[2] == 0x00, bytes[3] & 0xF0 == 0x10 { return false }
        return true
    }
}

/// One UDP association: the guest's address and port it is for, its TCP connection to the proxy
/// (which keeps it alive: when that connection ends, so does the association), its socket to the
/// proxy's relay, the datagrams that wait for it to come up, and every destination the guest sent
/// to from that port — so that an answer is shown to the guest from exactly the address and port
/// it sent to, and an answer from anywhere else is not shown at all.
final class UDPAssociation {
    enum Phase {
        /// The proxy's address is being resolved.
        case waiting
        /// The TCP connection to the proxy is being opened.
        case connecting
        /// The proxy is being asked for the association.
        case handshaking
        /// The relay is known and its socket open.
        case open
        /// Ended; nothing is open.
        case done
    }

    /// One destination the guest sent to: as it wrote it (a fake address stands for `target`'s
    /// name), and where the relay's answers from it came from, once one did.
    struct Destination {
        var guestAddress: VMNetIPv4
        var port: UInt16
        var target: ProxyTarget
        /// The host as the hosts' list names it.
        var host: String
        /// For a name: the address (as the relay wrote it) its answers came from, learned from
        /// the first of them.
        var answeredFrom: SOCKSAddress?
        var lastUsed: Double
    }

    /// A datagram waiting for the association to come up: the SOCKS5 datagram ready to send, and
    /// what the guest sent it to (for "port unreachable" if it never goes).
    struct Waiting {
        var datagram: [UInt8]
        var payloadLength: Int
        var host: String
        var quote: [UInt8]
        var destination: VMNetIPv4
    }

    /// At most this many destinations are remembered per association; one more, and the one
    /// unused the longest is forgotten (its answers are then not shown).
    static let destinationLimit = 64
    /// What waits for an association to come up, at most: datagrams and their bytes.
    static let waitingLimit = 32
    static let waitingBytesLimit = 64 * 1024

    let key: UDPKey
    let guestMAC: VMNetMAC
    var handshake: SOCKS5Handshake
    var phase = Phase.waiting
    var control: Int32 = -1
    var relay: Int32 = -1
    /// When the association must have come up by.
    var deadline: Double
    var attemptDeadline = Double.infinity
    var attempts = 0
    var addressIndex = 0
    var lastError = "no address"
    var outgoing: [UInt8] = []
    var outgoingSent = 0
    var lastActivity: Double
    /// Not waited on before this time: the control connection reported something that is no use.
    var holdUntil = 0.0
    private(set) var destinations: [Destination] = []
    private(set) var waiting: [Waiting] = []
    private(set) var waitingBytes = 0

    init(key: UDPKey, guestMAC: VMNetMAC, credentials: ProxyCredentials?, now: Double, setupTimeout: Double) {
        self.key = key
        self.guestMAC = guestMAC
        handshake = .udpAssociate(credentials: credentials)
        deadline = now + setupTimeout
        lastActivity = now
    }

    var nextDeadline: Double {
        switch phase {
        case .waiting, .handshaking: return deadline
        case .connecting: return min(deadline, attemptDeadline)
        case .open, .done: return .infinity
        }
    }

    /// Notes that the guest sends to `address`:`port` (`target` is where the proxy is asked to
    /// send it). True when the destination is new to this association.
    @discardableResult
    func noteDestination(_ address: VMNetIPv4, port: UInt16, target: ProxyTarget, host: String, now: Double) -> Bool {
        if let index = destinations.firstIndex(where: { $0.guestAddress == address && $0.port == port }) {
            destinations[index].lastUsed = now
            if destinations[index].target != target {
                // The fake address was given to another name since: what was learned is of the old one.
                destinations[index].target = target
                destinations[index].host = host
                destinations[index].answeredFrom = nil
            }
            return false
        }
        if destinations.count >= Self.destinationLimit,
           let oldest = destinations.indices.min(by: { destinations[$0].lastUsed < destinations[$1].lastUsed }) {
            destinations.remove(at: oldest)
        }
        destinations.append(Destination(guestAddress: address, port: port, target: target, host: host, answeredFrom: nil, lastUsed: now))
        return true
    }

    /// Forgets the destinations whose name `isBlocked` says is blocked now: their answers are no
    /// longer shown.
    func forgetDestinations(where isBlocked: (String) -> Bool) {
        destinations.removeAll { destination in
            if case .name(let name, _) = destination.target { return isBlocked(name) }
            return false
        }
    }

    /// Which destination an answer from the relay comes from: the one the guest sent to that
    /// address and port; for a name, the one whose answers came from there before, or the one
    /// the relay names; else the name with that port the guest sent to last that has had no
    /// answer yet (its first answer: the proxy resolved the name, and answers from the address it
    /// chose). Nil when the guest sent nothing there: the answer is not shown.
    func destination(answering source: SOCKSAddress, port: UInt16, now: Double) -> Destination? {
        let source = source.normalized
        var match: Int?
        if case .ipv4(let value) = source {
            match = destinations.firstIndex { destination in
                if case .address(let address, _) = destination.target { return address.value == value && destination.port == port }
                return false
            }
        }
        if match == nil {
            match = destinations.firstIndex { $0.port == port && $0.answeredFrom == source }
        }
        if match == nil, case .name(let name) = source {
            match = destinations.firstIndex { destination in
                if case .name(let wanted, _) = destination.target { return wanted == name && destination.port == port }
                return false
            }
        }
        if match == nil {
            var best: Int?
            for (index, destination) in destinations.enumerated() {
                guard destination.port == port, destination.answeredFrom == nil, case .name = destination.target else { continue }
                if best == nil || destination.lastUsed > destinations[best!].lastUsed { best = index }
            }
            if let best {
                destinations[best].answeredFrom = source
                match = best
            }
        }
        guard let match else { return nil }
        destinations[match].lastUsed = now
        return destinations[match]
    }

    /// Keeps a datagram until the association is up. False when the queue is full: it is dropped.
    func hold(_ waiting: Waiting) -> Bool {
        guard self.waiting.count < Self.waitingLimit, waitingBytes + waiting.datagram.count <= Self.waitingBytesLimit else { return false }
        self.waiting.append(waiting)
        waitingBytes += waiting.datagram.count
        return true
    }

    func takeWaiting() -> [Waiting] {
        defer {
            waiting = []
            waitingBytes = 0
        }
        return waiting
    }
}
