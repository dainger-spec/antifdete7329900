#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// The local port's credentials: new at every launch of a profile (the app makes them), given to
/// the profile as its proxy's user name and password, and to the tunnel's program only as their
/// SHA-256 (`LUMEN_SOCKS_VERIFIER`) — so that neither OpenVPN's configuration nor any process's
/// environment holds what opens the port.
public enum CredentialCheck {
    /// The verifier of `username` and `password`: SHA-256 of a fixed prefix, the user name, a zero
    /// byte and the password.
    public static func verifier(username: [UInt8], password: [UInt8]) -> [UInt8] {
        var input = Array("lumen-socks-v1\u{0}".utf8)
        input += username
        input.append(0)
        input += password
        return Array(SHA256.hash(data: input))
    }

    /// Whether the credentials a client sent are the launch's: compared in constant time.
    public static func matches(_ credentials: SOCKS5Server.Credentials, verifier expected: [UInt8]) -> Bool {
        let actual = verifier(username: credentials.username, password: credentials.password)
        guard actual.count == expected.count else { return false }
        var difference: UInt8 = 0
        for index in 0..<actual.count { difference |= actual[index] ^ expected[index] }
        return difference == 0
    }

    /// Lower-case hex, as the environment carries it.
    public static func hex(_ bytes: [UInt8]) -> String {
        let digits = Array("0123456789abcdef".utf8)
        var text: [UInt8] = []
        text.reserveCapacity(bytes.count * 2)
        for byte in bytes {
            text.append(digits[Int(byte >> 4)])
            text.append(digits[Int(byte & 0xF)])
        }
        return String(decoding: text, as: UTF8.self)
    }
}
