import Foundation

/// SOCKS5 (RFC 1928) with username/password authentication (RFC 1929): the bytes of the
/// handshake that opens a UDP association, and the header every relayed datagram carries.
/// Transport-free, so it is tested on Linux; `TunnelTransport` drives it over Network.framework.
public enum SOCKS5 {
    public enum Failure: Error, Equatable, Sendable {
        case malformed(String)
        case noAcceptableMethod
        case authenticationRejected
        /// The REP code of a refused request (7: command not supported — the proxy has no UDP).
        case requestRefused(UInt8)
        case credentialsTooLong
    }

    public struct Credentials: Equatable, Sendable {
        public var username: String
        public var password: String
        public init(username: String, password: String) {
            self.username = username
            self.password = password
        }
    }

    public static let version: UInt8 = 5
    public static let noAuthentication: UInt8 = 0x00
    public static let usernamePassword: UInt8 = 0x02
    public static let noAcceptable: UInt8 = 0xFF
    public static let udpAssociate: UInt8 = 0x03

    /// The client's greeting: the methods it can do (username/password only when it has credentials).
    public static func greeting(withCredentials: Bool) -> [UInt8] {
        withCredentials ? [version, 2, noAuthentication, usernamePassword] : [version, 1, noAuthentication]
    }

    /// The method the proxy chose, from its 2-byte answer.
    public static func parseMethodSelection(_ bytes: [UInt8]) throws -> UInt8 {
        guard bytes.count == 2, bytes[0] == version else { throw Failure.malformed("method selection") }
        guard bytes[1] != noAcceptable else { throw Failure.noAcceptableMethod }
        guard bytes[1] == noAuthentication || bytes[1] == usernamePassword else {
            throw Failure.malformed("method \(bytes[1]) was not offered")
        }
        return bytes[1]
    }

    /// RFC 1929 sub-negotiation: VER 1, ULEN, UNAME, PLEN, PASSWD.
    public static func authenticationRequest(_ credentials: Credentials) throws -> [UInt8] {
        let user = Array(credentials.username.utf8), pass = Array(credentials.password.utf8)
        guard (1...255).contains(user.count), (1...255).contains(pass.count) else { throw Failure.credentialsTooLong }
        return [1, UInt8(user.count)] + user + [UInt8(pass.count)] + pass
    }

    public static func parseAuthenticationReply(_ bytes: [UInt8]) throws {
        guard bytes.count == 2, bytes[0] == 1 else { throw Failure.malformed("authentication reply") }
        guard bytes[1] == 0 else { throw Failure.authenticationRejected }
    }

    /// UDP ASSOCIATE. The address is where this client will send from; unknown (all zeros) is
    /// allowed and makes the proxy accept datagrams from the address of the control connection.
    public static func udpAssociateRequest(from address: SocketAddress? = nil) -> [UInt8] {
        let address = address ?? SocketAddress(ip: .anyV4, port: 0)
        return [version, udpAssociate, 0] + encode(.address(address))
    }

    /// The fixed part of a reply: VER, REP, RSV, ATYP. The caller then reads `addressLength(atyp:)`
    /// more bytes (for a name, the first of them is the name's length) and the 2-byte port.
    public static func parseReplyHead(_ head: [UInt8]) throws -> UInt8 {
        guard head.count == 4, head[0] == version else { throw Failure.malformed("reply") }
        guard head[1] == 0 else { throw Failure.requestRefused(head[1]) }
        guard [1, 3, 4].contains(head[3]) else { throw Failure.malformed("address type \(head[3])") }
        return head[3]
    }

    /// The bound address of a successful reply (`rest` = everything after the 4-byte head).
    /// An unspecified address (0.0.0.0 or ::) means "the proxy's own address": the caller
    /// substitutes the address of the control connection's peer.
    public static func parseBoundAddress(atyp: UInt8, _ rest: [UInt8]) throws -> ProxyDestination {
        guard let (destination, used) = decodeAddress(atyp: atyp, rest, at: 0), used == rest.count else {
            throw Failure.malformed("bound address")
        }
        return destination
    }

    /// The datagram the client sends to the proxy's relay port: RSV(2) FRAG(1) ATYP DST.ADDR DST.PORT DATA.
    public static func wrapDatagram(_ payload: [UInt8], to destination: ProxyDestination) -> [UInt8] {
        [0, 0, 0] + encode(destination) + payload
    }

    /// The source and payload of a datagram the proxy relayed back, or nil for a malformed one or a
    /// fragment (FRAG ≠ 0: fragmentation is optional for proxies and not supported here).
    public static func unwrapDatagram(_ datagram: [UInt8]) -> (source: ProxyDestination, payload: [UInt8])? {
        guard datagram.count >= 4, datagram[0] == 0, datagram[1] == 0, datagram[2] == 0 else { return nil }
        guard let (source, used) = decodeAddress(atyp: datagram[3], datagram, at: 4) else { return nil }
        return (source, Array(datagram[(4 + used)...]))
    }

    // MARK: Addresses

    /// ATYP DST.ADDR DST.PORT.
    static func encode(_ destination: ProxyDestination) -> [UInt8] {
        switch destination {
        case let .address(address):
            return [address.family == .v4 ? 1 : 4] + address.ip.bytes + be16(address.port)
        case let .name(name, port):
            let bytes = Array(name.utf8.prefix(255))
            return [3, UInt8(bytes.count)] + bytes + be16(port)
        }
    }

    /// Decodes ADDR PORT for `atyp` starting at `offset`; returns the destination and how many
    /// bytes it used (ATYP itself excluded).
    static func decodeAddress(atyp: UInt8, _ bytes: [UInt8], at offset: Int) -> (ProxyDestination, Int)? {
        switch atyp {
        case 1, 4:
            let length = atyp == 1 ? 4 : 16
            guard bytes.count >= offset + length + 2, let ip = IPAddr(bytes: Array(bytes[offset..<(offset + length)])) else { return nil }
            return (.address(SocketAddress(ip: ip, port: get16(bytes, offset + length))), length + 2)
        case 3:
            guard bytes.count > offset else { return nil }
            let length = Int(bytes[offset])
            guard length > 0, bytes.count >= offset + 1 + length + 2,
                  let name = String(bytes: bytes[(offset + 1)..<(offset + 1 + length)], encoding: .utf8) else { return nil }
            return (.name(name, port: get16(bytes, offset + 1 + length)), 1 + length + 2)
        default:
            return nil
        }
    }

    /// How many bytes follow the reply head for `atyp` before the port, or nil when the length
    /// is in the next byte (a name).
    public static func addressLength(atyp: UInt8) -> Int? {
        switch atyp {
        case 1: return 4
        case 4: return 16
        default: return nil
        }
    }
}
