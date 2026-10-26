#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

/// STUN messages (RFC 8489) with the TURN methods and attributes (RFC 8656): parsing, building,
/// MESSAGE-INTEGRITY (long-term credentials) and FINGERPRINT.
public struct STUNMessage: Equatable, Sendable {
    public static let magicCookie: UInt32 = 0x2112_A442
    public static let headerLength = 20

    public enum Class: UInt16, Sendable { case request = 0, indication = 1, success = 2, error = 3 }

    public enum Method: UInt16, Sendable {
        case binding = 0x001, allocate = 0x003, refresh = 0x004, send = 0x006, data = 0x007
        case createPermission = 0x008, channelBind = 0x009
    }

    public enum Attribute {
        public static let mappedAddress: UInt16 = 0x0001
        public static let username: UInt16 = 0x0006
        public static let messageIntegrity: UInt16 = 0x0008
        public static let errorCode: UInt16 = 0x0009
        public static let unknownAttributes: UInt16 = 0x000A
        public static let channelNumber: UInt16 = 0x000C
        public static let lifetime: UInt16 = 0x000D
        public static let xorPeerAddress: UInt16 = 0x0012
        public static let data: UInt16 = 0x0013
        public static let realm: UInt16 = 0x0014
        public static let nonce: UInt16 = 0x0015
        public static let xorRelayedAddress: UInt16 = 0x0016
        public static let requestedAddressFamily: UInt16 = 0x0017
        public static let evenPort: UInt16 = 0x0018
        public static let requestedTransport: UInt16 = 0x0019
        public static let dontFragment: UInt16 = 0x001A
        public static let messageIntegritySHA256: UInt16 = 0x001C
        public static let xorMappedAddress: UInt16 = 0x0020
        public static let reservationToken: UInt16 = 0x0022
        public static let additionalAddressFamily: UInt16 = 0x8000
        public static let addressErrorCode: UInt16 = 0x8001
        public static let software: UInt16 = 0x8022
        public static let fingerprint: UInt16 = 0x8028

        /// Attributes below 0x8000 must be understood; an unknown one in a request gets 420.
        public static func isComprehensionRequired(_ type: UInt16) -> Bool { type < 0x8000 }
    }

    public var method: UInt16
    public var messageClass: Class
    public var transactionID: [UInt8]
    /// In wire order. Values are unpadded.
    public var attributes: [(type: UInt16, value: [UInt8])]

    public init(method: UInt16, messageClass: Class, transactionID: [UInt8], attributes: [(type: UInt16, value: [UInt8])] = []) {
        precondition(transactionID.count == 12)
        self.method = method
        self.messageClass = messageClass
        self.transactionID = transactionID
        self.attributes = attributes
    }

    public static func == (a: STUNMessage, b: STUNMessage) -> Bool {
        a.method == b.method && a.messageClass == b.messageClass && a.transactionID == b.transactionID
            && a.attributes.count == b.attributes.count
            && zip(a.attributes, b.attributes).allSatisfy { $0.type == $1.type && $0.value == $1.value }
    }

    // MARK: Type field

    /// The 14-bit type: method bits M11…M0 interleaved with class bits C1 C0.
    public static func encodeType(method: UInt16, messageClass: Class) -> UInt16 {
        let c = messageClass.rawValue
        return (method & 0x000F) | ((c & 1) << 4) | ((method & 0x0070) << 1) | ((c & 2) << 7) | ((method & 0x0F80) << 2)
    }

    public static func decodeType(_ type: UInt16) -> (method: UInt16, messageClass: Class) {
        let method = (type & 0x000F) | ((type & 0x00E0) >> 1) | ((type & 0x3E00) >> 2)
        let c = ((type & 0x0010) >> 4) | ((type & 0x0100) >> 7)
        return (method, Class(rawValue: c)!)
    }

    // MARK: Parsing

    /// True when `bytes` looks like a STUN message (first two bits 0 and the magic cookie), as
    /// opposed to TURN ChannelData (first two bits 01).
    public static func isSTUN(_ bytes: [UInt8]) -> Bool {
        bytes.count >= headerLength && bytes[0] & 0xC0 == 0 && get32(bytes, 4) == magicCookie
    }

    /// Parses a whole message; nil for anything malformed (length, padding, cookie).
    public static func parse(_ bytes: [UInt8]) -> STUNMessage? {
        guard isSTUN(bytes) else { return nil }
        let length = Int(get16(bytes, 2))
        guard length % 4 == 0, headerLength + length == bytes.count else { return nil }
        let (method, messageClass) = decodeType(get16(bytes, 0))
        var attributes: [(type: UInt16, value: [UInt8])] = []
        var offset = headerLength
        while offset < bytes.count {
            guard offset + 4 <= bytes.count else { return nil }
            let type = get16(bytes, offset)
            let valueLength = Int(get16(bytes, offset + 2))
            let padded = (valueLength + 3) & ~3
            guard offset + 4 + padded <= bytes.count else { return nil }
            attributes.append((type, Array(bytes[(offset + 4)..<(offset + 4 + valueLength)])))
            offset += 4 + padded
        }
        return STUNMessage(method: method, messageClass: messageClass, transactionID: Array(bytes[8..<20]), attributes: attributes)
    }

    public func attribute(_ type: UInt16) -> [UInt8]? {
        attributes.first { $0.type == type }?.value
    }

    // MARK: Building

    /// The wire bytes, with MESSAGE-INTEGRITY (when `integrityKey` is given) and FINGERPRINT
    /// appended last, in that order, as RFC 8489 requires.
    public func encode(integrityKey: [UInt8]? = nil, fingerprint: Bool = false) -> [UInt8] {
        var bytes = be16(Self.encodeType(method: method, messageClass: messageClass)) + [0, 0] + be32(Self.magicCookie) + transactionID
        for attribute in attributes { Self.append(attribute.type, attribute.value, to: &bytes) }
        if let key = integrityKey {
            // The length covers the MESSAGE-INTEGRITY attribute being added (4 + 20 bytes).
            setLength(&bytes, bytes.count - Self.headerLength + 24)
            let mac = Array(HMAC<Insecure.SHA1>.authenticationCode(for: bytes, using: SymmetricKey(data: key)))
            Self.append(Attribute.messageIntegrity, mac, to: &bytes)
        }
        if fingerprint {
            setLength(&bytes, bytes.count - Self.headerLength + 8)
            Self.append(Attribute.fingerprint, be32(CRC32.checksum(bytes) ^ 0x5354_554E), to: &bytes)
        }
        setLength(&bytes, bytes.count - Self.headerLength)
        return bytes
    }

    /// Callers keep a message within STUN's 16-bit length (`maximumBodyLength`); one that is not
    /// gets a wrong length, never a trap in the shared extension.
    private func setLength(_ bytes: inout [UInt8], _ length: Int) {
        put16(&bytes, 2, UInt16(clamping: length))
    }

    public static let maximumBodyLength = 0xFFFF

    static func append(_ type: UInt16, _ value: [UInt8], to bytes: inout [UInt8]) {
        bytes += be16(type) + be16(UInt16(clamping: value.count)) + value
        let padding = (4 - value.count % 4) % 4
        bytes += [UInt8](repeating: 0, count: padding)
    }

    // MARK: Integrity and fingerprint (checked on the raw bytes)

    /// Checks MESSAGE-INTEGRITY in the raw message with `key`. Attributes after it other than
    /// FINGERPRINT are not allowed by RFC 8489 and make the check fail.
    public static func verifyIntegrity(_ bytes: [UInt8], key: [UInt8]) -> Bool {
        guard let offset = attributeOffset(bytes, Attribute.messageIntegrity), offset + 24 <= bytes.count else { return false }
        let after = offset + 24
        if after < bytes.count {
            guard get16(bytes, after) == Attribute.fingerprint, after + 8 == bytes.count else { return false }
        }
        var signed = Array(bytes[0..<offset])
        put16(&signed, 2, UInt16(offset + 24 - headerLength))
        let expected = Array(HMAC<Insecure.SHA1>.authenticationCode(for: signed, using: SymmetricKey(data: key)))
        return constantTimeEqual(expected, Array(bytes[(offset + 4)..<(offset + 24)]))
    }

    /// Checks FINGERPRINT when present (it must be the last attribute). True when absent.
    public static func verifyFingerprint(_ bytes: [UInt8]) -> Bool {
        guard let offset = attributeOffset(bytes, Attribute.fingerprint) else { return true }
        guard offset + 8 == bytes.count else { return false }
        return CRC32.checksum(Array(bytes[0..<offset])) ^ 0x5354_554E == get32(bytes, offset + 4)
    }

    /// Byte offset of the first attribute of `type` in a well-formed message.
    static func attributeOffset(_ bytes: [UInt8], _ type: UInt16) -> Int? {
        var offset = headerLength
        while offset + 4 <= bytes.count {
            if get16(bytes, offset) == type { return offset }
            offset += 4 + ((Int(get16(bytes, offset + 2)) + 3) & ~3)
        }
        return nil
    }

    /// The long-term credential key: MD5(username ":" realm ":" password) (RFC 8489 §9.2.2).
    /// SASLprep/OpaqueString is the identity for the ASCII credentials this relay generates.
    public static func longTermKey(username: String, realm: String, password: String) -> [UInt8] {
        Array(Insecure.MD5.hash(data: Array("\(username):\(realm):\(password)".utf8)))
    }
}

// MARK: Attribute values

extension STUNMessage {
    /// XOR-MAPPED-ADDRESS / XOR-PEER-ADDRESS / XOR-RELAYED-ADDRESS value.
    public static func xorAddress(_ address: SocketAddress, transactionID: [UInt8]) -> [UInt8] {
        let cookie = be32(magicCookie)
        let port = address.port ^ UInt16(magicCookie >> 16)
        let mask = address.family == .v4 ? cookie : cookie + transactionID
        let xored = zip(address.ip.bytes, mask).map { $0 ^ $1 }
        return [0, address.family == .v4 ? 1 : 2] + be16(port) + xored
    }

    public static func decodeXorAddress(_ value: [UInt8], transactionID: [UInt8]) -> SocketAddress? {
        guard value.count >= 8 else { return nil }
        let family = value[1]
        let length = family == 1 ? 4 : family == 2 ? 16 : 0
        guard length > 0, value.count == 4 + length else { return nil }
        let cookie = be32(magicCookie)
        let mask = family == 1 ? cookie : cookie + transactionID
        let bytes = zip(value[4...], mask).map { $0 ^ $1 }
        guard let ip = IPAddr(bytes: bytes) else { return nil }
        return SocketAddress(ip: ip, port: get16(value, 2) ^ UInt16(magicCookie >> 16))
    }

    /// ERROR-CODE value: class (hundreds) and number, then the reason phrase.
    public static func errorCode(_ code: Int, reason: String) -> [UInt8] {
        [0, 0, UInt8(code / 100), UInt8(code % 100)] + Array(reason.utf8)
    }

    public static func decodeErrorCode(_ value: [UInt8]) -> Int? {
        guard value.count >= 4 else { return nil }
        return Int(value[2] & 0x07) * 100 + Int(value[3])
    }

    public static func uint32(_ value: UInt32) -> [UInt8] { be32(value) }

    public static func decodeUInt32(_ value: [UInt8]) -> UInt32? {
        value.count == 4 ? get32(value, 0) : nil
    }
}

/// CRC-32 (ISO-HDLC / IEEE 802.3, the one zlib uses) for STUN FINGERPRINT.
enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { index in
        var c = UInt32(index)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func checksum(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes { crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        return crc ^ 0xFFFF_FFFF
    }
}

func constantTimeEqual(_ a: [UInt8], _ b: [UInt8]) -> Bool {
    guard a.count == b.count else { return false }
    var difference: UInt8 = 0
    for (x, y) in zip(a, b) { difference |= x ^ y }
    return difference == 0
}
