#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

/// A TLS ClientHello as the server reads it: what a browser offers before anything is encrypted,
/// and so what any server it connects to can fingerprint — the versions, cipher suites, extensions
/// in their order, groups, signature algorithms and ALPN, and the JA3 and JA4 strings made of
/// them. "What sites see" reads the ClientHello of a profile and of Safari on a listener of this
/// Mac (`SiteSnapshotServer`) and compares the two.
///
/// GREASE values (RFC 8701), which a client picks at random for each connection, are left out of
/// every list, as JA3 and JA4 leave them out.
public struct TLSClientHello: Equatable, Sendable {
    /// The record's handshake version (0x0303 for TLS 1.2 and 1.3).
    public var legacyVersion: UInt16
    public var cipherSuites: [UInt16]
    /// Extension types in the order the client sent them.
    public var extensions: [UInt16]
    public var supportedGroups: [UInt16]
    public var pointFormats: [UInt8]
    public var signatureAlgorithms: [UInt16]
    public var alpn: [String]
    public var supportedVersions: [UInt16]
    public var serverName: String?

    public enum ParseError: Error, Equatable {
        /// More bytes are needed.
        case incomplete
        /// Not a TLS handshake that starts with a ClientHello.
        case notAClientHello
        case malformed
    }

    /// GREASE: 0x0A0A, 0x1A1A … 0xFAFA.
    public static func isGREASE(_ value: UInt16) -> Bool {
        value & 0x0F0F == 0x0A0A && value >> 8 == value & 0xFF
    }

    /// The ClientHello at the start of what a client sent (its handshake may span records).
    public static func parse(_ bytes: [UInt8]) throws -> TLSClientHello {
        // The handshake message, put together from the records that carry it.
        var handshake: [UInt8] = []
        var offset = 0
        while true {
            guard bytes.count >= offset + 5 else { throw ParseError.incomplete }
            guard bytes[offset] == 0x16, bytes[offset + 1] == 0x03 else { throw ParseError.notAClientHello }
            let length = Int(bytes[offset + 3]) << 8 | Int(bytes[offset + 4])
            guard bytes.count >= offset + 5 + length else { throw ParseError.incomplete }
            handshake += bytes[(offset + 5)..<(offset + 5 + length)]
            offset += 5 + length
            if handshake.count >= 4 {
                guard handshake[0] == 0x01 else { throw ParseError.notAClientHello }
                let needed = Int(handshake[1]) << 16 | Int(handshake[2]) << 8 | Int(handshake[3])
                if handshake.count >= 4 + needed {
                    return try parseBody(Array(handshake[4..<(4 + needed)]))
                }
            }
        }
    }

    private static func parseBody(_ body: [UInt8]) throws -> TLSClientHello {
        var reader = Reader(body)
        let legacyVersion = try reader.u16()
        try reader.skip(32) // random
        try reader.skip(Int(try reader.u8())) // session id
        let suites = try reader.bytes(Int(try reader.u16()))
        try reader.skip(Int(try reader.u8())) // compression methods
        var hello = TLSClientHello(legacyVersion: legacyVersion, cipherSuites: pairs(suites).filter { !isGREASE($0) },
                                   extensions: [], supportedGroups: [], pointFormats: [], signatureAlgorithms: [],
                                   alpn: [], supportedVersions: [], serverName: nil)
        guard !reader.isAtEnd else { return hello }
        var extensions = Reader(try reader.bytes(Int(try reader.u16())))
        while !extensions.isAtEnd {
            let type = try extensions.u16()
            var data = Reader(try extensions.bytes(Int(try extensions.u16())))
            if !isGREASE(type) { hello.extensions.append(type) }
            switch type {
            case 0x0000: // server_name: a list of (type, name)
                var names = Reader(try data.bytes(Int(try data.u16())))
                while !names.isAtEnd {
                    let kind = try names.u8()
                    let name = try names.bytes(Int(try names.u16()))
                    if kind == 0 { hello.serverName = String(decoding: name, as: UTF8.self) }
                }
            case 0x000A: // supported_groups
                hello.supportedGroups = pairs(try data.bytes(Int(try data.u16()))).filter { !isGREASE($0) }
            case 0x000B: // ec_point_formats
                hello.pointFormats = try data.bytes(Int(try data.u8()))
            case 0x000D: // signature_algorithms
                hello.signatureAlgorithms = pairs(try data.bytes(Int(try data.u16())))
            case 0x0010: // application_layer_protocol_negotiation
                var protocols = Reader(try data.bytes(Int(try data.u16())))
                while !protocols.isAtEnd {
                    hello.alpn.append(String(decoding: try protocols.bytes(Int(try protocols.u8())), as: UTF8.self))
                }
            case 0x002B: // supported_versions
                hello.supportedVersions = pairs(try data.bytes(Int(try data.u8()))).filter { !isGREASE($0) }
            default:
                break
            }
        }
        return hello
    }

    private static func pairs(_ bytes: [UInt8]) -> [UInt16] {
        stride(from: 0, to: bytes.count - 1, by: 2).map { UInt16(bytes[$0]) << 8 | UInt16(bytes[$0 + 1]) }
    }

    // MARK: Fingerprints

    /// JA3: the version, cipher suites, extensions, groups and point formats, in decimal.
    public var ja3: String {
        func list<T: BinaryInteger>(_ values: [T]) -> String { values.map { String($0) }.joined(separator: "-") }
        return [String(legacyVersion), list(cipherSuites), list(extensions), list(supportedGroups), list(pointFormats)]
            .joined(separator: ",")
    }

    /// The MD5 of `ja3`, as servers log it.
    public var ja3Hash: String {
        Insecure.MD5.hash(data: Data(ja3.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// JA4 (FoxIO): "t13d1516h2_8daaf6152771_e5627efa2ab1" — over TCP, the highest version
    /// offered, a name or not, how many suites and extensions, the first ALPN's first and last
    /// characters; the sorted suites, hashed; the sorted extensions but the name and ALPN, with
    /// the signature algorithms in their order, hashed.
    public var ja4: String {
        let version: String
        switch (supportedVersions.max() ?? legacyVersion) {
        case 0x0304: version = "13"
        case 0x0303: version = "12"
        case 0x0302: version = "11"
        case 0x0301: version = "10"
        case 0x0300: version = "s3"
        default: version = "00"
        }
        let name = extensions.contains(0x0000) ? "d" : "i"
        let alpnPart: String
        if let first = alpn.first, let head = first.unicodeScalars.first, let tail = first.unicodeScalars.last,
           head.isASCII, tail.isASCII, Character(head).isLetter || Character(head).isNumber,
           Character(tail).isLetter || Character(tail).isNumber {
            alpnPart = String(Character(head)) + String(Character(tail))
        } else if let first = alpn.first, let head = first.utf8.first, let tail = first.utf8.last {
            alpnPart = String(String(format: "%02x", head).prefix(1)) + String(String(format: "%02x", tail).suffix(1))
        } else {
            alpnPart = "00"
        }
        func twoDigits(_ count: Int) -> String { count < 10 ? "0\(count)" : String(min(count, 99)) }
        let a = "t" + version + name + twoDigits(cipherSuites.count) + twoDigits(extensions.count) + alpnPart
        func hex(_ values: [UInt16]) -> String { values.map { String(format: "%04x", $0) }.joined(separator: ",") }
        func truncatedHash(_ text: String) -> String {
            String(SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined().prefix(12))
        }
        let b = cipherSuites.isEmpty ? "000000000000" : truncatedHash(hex(cipherSuites.sorted()))
        let sortedExtensions = extensions.filter { $0 != 0x0000 && $0 != 0x0010 }.sorted()
        var cInput = hex(sortedExtensions)
        if !signatureAlgorithms.isEmpty { cInput += "_" + hex(signatureAlgorithms) }
        let c = sortedExtensions.isEmpty ? "000000000000" : truncatedHash(cInput)
        return a + "_" + b + "_" + c
    }

    /// What "What sites see" lists of a ClientHello, one line each.
    public var values: [String: String] {
        func hex(_ values: [UInt16]) -> String { values.map { String(format: "0x%04x", $0) }.joined(separator: ",") }
        return [
            "ja3": ja3Hash,
            "ja4": ja4,
            "versions": hex(supportedVersions.isEmpty ? [legacyVersion] : supportedVersions),
            "cipherSuites": hex(cipherSuites),
            "extensions": hex(extensions),
            "supportedGroups": hex(supportedGroups),
            "signatureAlgorithms": hex(signatureAlgorithms),
            "alpn": alpn.joined(separator: ","),
            "serverName": serverName ?? "none",
        ]
    }
}

/// Reads a TLS message's fields in order, refusing to read past its end.
private struct Reader {
    private let data: [UInt8]
    private var position = 0

    init(_ data: [UInt8]) { self.data = data }

    var isAtEnd: Bool { position >= data.count }

    mutating func u8() throws -> UInt8 {
        guard position < data.count else { throw TLSClientHello.ParseError.malformed }
        defer { position += 1 }
        return data[position]
    }

    mutating func u16() throws -> UInt16 {
        UInt16(try u8()) << 8 | UInt16(try u8())
    }

    mutating func bytes(_ count: Int) throws -> [UInt8] {
        guard count >= 0, position + count <= data.count else { throw TLSClientHello.ParseError.malformed }
        defer { position += count }
        return Array(data[position..<(position + count)])
    }

    mutating func skip(_ count: Int) throws {
        _ = try bytes(count)
    }
}
