/// The server side of SOCKS5 (RFC 1928) with user name and password (RFC 1929), as the tunnel's
/// local port speaks it: what a client sends, read from a buffer as it comes, and what is answered.
///
/// Only user name and password are offered: a client that does not offer them is refused before
/// anything else (method 0xFF). CONNECT and UDP ASSOCIATE are served; BIND is refused.
public enum SOCKS5Server {
    /// Something read from the front of a buffer: what it was and how many bytes it took.
    public enum Read<Value: Equatable>: Equatable {
        case needMore
        case invalid
        case value(Value, consumed: Int)
    }

    /// The client's greeting: whether it offers user name and password.
    public static func readGreeting(_ bytes: [UInt8]) -> Read<Bool> {
        guard bytes.count >= 2 else { return .needMore }
        guard bytes[0] == 5, bytes[1] >= 1 else { return .invalid }
        let count = Int(bytes[1])
        guard bytes.count >= 2 + count else { return .needMore }
        return .value(bytes[2..<(2 + count)].contains(2), consumed: 2 + count)
    }

    /// The method chosen: 0x02 (user name and password) or 0xFF (none acceptable).
    public static func methodChoice(acceptable: Bool) -> [UInt8] { [5, acceptable ? 2 : 0xFF] }

    public struct Credentials: Equatable, Sendable {
        public var username: [UInt8]
        public var password: [UInt8]
        public init(username: [UInt8], password: [UInt8]) {
            self.username = username
            self.password = password
        }
    }

    /// RFC 1929's request: version 1, the user name, the password (each 1–255 bytes).
    public static func readCredentials(_ bytes: [UInt8]) -> Read<Credentials> {
        guard bytes.count >= 2 else { return .needMore }
        guard bytes[0] == 1 else { return .invalid }
        let nameLength = Int(bytes[1])
        guard nameLength > 0 else { return .invalid }
        guard bytes.count >= 3 + nameLength else { return .needMore }
        let passwordLength = Int(bytes[2 + nameLength])
        guard passwordLength > 0 else { return .invalid }
        let end = 3 + nameLength + passwordLength
        guard bytes.count >= end else { return .needMore }
        return .value(Credentials(username: Array(bytes[2..<(2 + nameLength)]),
                                  password: Array(bytes[(3 + nameLength)..<end])), consumed: end)
    }

    public static func credentialsAnswer(accepted: Bool) -> [UInt8] { [1, accepted ? 0 : 1] }

    /// Where a request goes: an address, or a name the tunnel's resolver looks up.
    public enum Destination: Equatable, Sendable {
        case address(TunnelAddress)
        case name(String)
    }

    public enum Command: UInt8, Sendable {
        case connect = 1
        case bind = 2
        case udpAssociate = 3
    }

    public struct Request: Equatable, Sendable {
        public var command: UInt8
        public var destination: Destination
        public var port: UInt16
    }

    /// A request, or `.invalid` for a malformed one (another version, a reserved byte that is not
    /// zero, an unknown address type, a name that is not a plain host name).
    public static func readRequest(_ bytes: [UInt8]) -> Read<Request> {
        guard bytes.count >= 4 else { return .needMore }
        guard bytes[0] == 5, bytes[2] == 0 else { return .invalid }
        guard let (destination, length) = readAddress(bytes, at: 3) else {
            return addressIncomplete(bytes, at: 3) ? .needMore : .invalid
        }
        let portAt = 3 + length
        guard bytes.count >= portAt + 2 else { return .needMore }
        let port = UInt16(bytes[portAt]) << 8 | UInt16(bytes[portAt + 1])
        return .value(Request(command: bytes[1], destination: destination, port: port), consumed: portAt + 2)
    }

    /// RFC 1928's replies.
    public enum Reply: UInt8, Sendable {
        case succeeded = 0
        case generalFailure = 1
        case notAllowed = 2
        case networkUnreachable = 3
        case hostUnreachable = 4
        case connectionRefused = 5
        case ttlExpired = 6
        case commandNotSupported = 7
        case addressTypeNotSupported = 8
    }

    /// A reply with the bound address (all zeros IPv4 when there is none to give).
    public static func reply(_ code: Reply, bound: TunnelAddress? = nil, port: UInt16 = 0) -> [UInt8] {
        var bytes: [UInt8] = [5, code.rawValue, 0]
        let address = bound ?? TunnelAddress(family: .v4, bytes: [0, 0, 0, 0])!
        bytes.append(address.family == .v4 ? 1 : 4)
        bytes += address.bytes
        bytes += [UInt8(port >> 8), UInt8(port & 0xFF)]
        return bytes
    }

    /// A datagram of a UDP association: the header (RFC 1928 §7) and the payload after it.
    public struct Datagram: Equatable, Sendable {
        public var destination: Destination
        public var port: UInt16
        public var payload: [UInt8]
    }

    /// A client's datagram; nil when malformed or fragmented (FRAG ≠ 0 is never reassembled: dropped).
    public static func readDatagram(_ bytes: [UInt8]) -> Datagram? {
        guard bytes.count >= 4, bytes[0] == 0, bytes[1] == 0, bytes[2] == 0 else { return nil }
        guard let (destination, length) = readAddress(bytes, at: 3) else { return nil }
        let portAt = 3 + length
        guard bytes.count >= portAt + 2 else { return nil }
        let port = UInt16(bytes[portAt]) << 8 | UInt16(bytes[portAt + 1])
        return Datagram(destination: destination, port: port, payload: Array(bytes[(portAt + 2)...]))
    }

    /// A datagram to the client, from `source` port `port`.
    public static func datagram(from source: TunnelAddress, port: UInt16, payload: [UInt8]) -> [UInt8] {
        var bytes: [UInt8] = [0, 0, 0, source.family == .v4 ? 1 : 4]
        bytes += source.bytes
        bytes += [UInt8(port >> 8), UInt8(port & 0xFF)]
        bytes += payload
        return bytes
    }

    // MARK: Addresses

    private static func readAddress(_ bytes: [UInt8], at start: Int) -> (Destination, Int)? {
        guard bytes.count > start else { return nil }
        switch bytes[start] {
        case 1:
            guard bytes.count >= start + 5 else { return nil }
            return (.address(TunnelAddress(family: .v4, bytes: Array(bytes[(start + 1)..<(start + 5)]))!), 5)
        case 4:
            guard bytes.count >= start + 17 else { return nil }
            return (.address(TunnelAddress(family: .v6, bytes: Array(bytes[(start + 1)..<(start + 17)]))!), 17)
        case 3:
            guard bytes.count >= start + 2 else { return nil }
            let length = Int(bytes[start + 1])
            guard length > 0, bytes.count >= start + 2 + length else { return nil }
            let raw = Array(bytes[(start + 2)..<(start + 2 + length)])
            // A literal sent as a name is that address: nothing to resolve.
            if raw.allSatisfy({ $0 > 0x20 && $0 < 0x7F }), let literal = TunnelAddress(String(decoding: raw, as: UTF8.self)) {
                return (.address(literal), 2 + length)
            }
            guard let name = HostName.normalized(raw) else { return nil }
            return (.name(name), 2 + length)
        default:
            return nil
        }
    }

    /// Whether the address at `start` is only cut short (more bytes may complete it), rather than
    /// malformed.
    private static func addressIncomplete(_ bytes: [UInt8], at start: Int) -> Bool {
        guard bytes.count > start else { return true }
        switch bytes[start] {
        case 1: return bytes.count < start + 5
        case 4: return bytes.count < start + 17
        case 3:
            guard bytes.count >= start + 2 else { return true }
            let length = Int(bytes[start + 1])
            return length > 0 && bytes.count < start + 2 + length
        default: return false
        }
    }
}

/// Host names as the tunnel's resolver takes them.
public enum HostName {
    /// The name in lower case without a final dot, when it is one a resolver can be asked:
    /// 1–253 bytes of letters, digits, hyphens, underscores and dots, no empty label, no label
    /// over 63. Anything else — spaces, control bytes, non-ASCII (pages' names come as punycode) —
    /// is refused.
    public static func normalized(_ raw: [UInt8]) -> String? {
        var bytes = raw
        if bytes.last == UInt8(ascii: ".") { bytes.removeLast() }
        guard !bytes.isEmpty, bytes.count <= 253 else { return nil }
        var labelLength = 0
        for byte in bytes {
            switch byte {
            case UInt8(ascii: "."):
                guard labelLength > 0 else { return nil }
                labelLength = 0
            case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"),
                 UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "-"), UInt8(ascii: "_"):
                labelLength += 1
                guard labelLength <= 63 else { return nil }
            default:
                return nil
            }
        }
        guard labelLength > 0 else { return nil }
        return String(decoding: bytes, as: UTF8.self).lowercased()
    }
}
