import BrowserCore
import Foundation

/// How a profile's own process learns its OpenVPN tunnel's local port (docs/OPENVPN.md): the
/// manager started the tunnel for this launch, and writes the port and its credentials on the
/// child's standard input right after the profile's grant — never in its environment or
/// arguments, which other processes of this Mac can read. `PB_TUNNEL_PROXY=1` tells the child
/// that a record follows the grant.
///
/// A profile whose stored proxy is an OpenVPN connection does not start without its record: it
/// would otherwise be held to the VPN server's address as if it were a SOCKS5 proxy, which
/// carries nothing — but it must not even try.
enum OpenVPNHandoff {
    static let variable = "PB_TUNNEL_PROXY"

    /// In a profile's own process: the local port its manager gave it.
    nonisolated(unsafe) static var received: ProxySettings?

    enum HandoffError: Error, CustomStringConvertible {
        case missing
        case malformed

        var description: String {
            switch self {
            case .missing: return "the profile's OpenVPN tunnel was not given to its process"
            case .malformed: return "the profile's OpenVPN tunnel's record could not be read"
            }
        }
    }

    /// The record: a 4-byte big-endian length, then the local proxy as JSON.
    static func record(_ proxy: ProxySettings) throws -> Data {
        let body = try JSONEncoder().encode(proxy)
        var data = Data([UInt8(body.count >> 24 & 0xFF), UInt8(body.count >> 16 & 0xFF), UInt8(body.count >> 8 & 0xFF), UInt8(body.count & 0xFF)])
        data.append(body)
        return data
    }

    /// Reads the record with `next` (n bytes, or nil at the end). Only a SOCKS5 proxy on 127.0.0.1
    /// with credentials is taken: anything else is not a tunnel's port.
    static func read(_ next: (Int) -> Data?) throws -> ProxySettings {
        guard let head = next(4), head.count == 4 else { throw HandoffError.missing }
        let bytes = [UInt8](head)
        let length = Int(bytes[0]) << 24 | Int(bytes[1]) << 16 | Int(bytes[2]) << 8 | Int(bytes[3])
        guard length > 0, length < 65_536, let body = next(length), body.count == length,
              let proxy = try? JSONDecoder().decode(ProxySettings.self, from: body),
              proxy.kind == .socks5, proxy.host == "127.0.0.1", proxy.openVPN == nil, proxy.username != nil, proxy.password != nil,
              (try? proxy.validate()) != nil else {
            throw HandoffError.malformed
        }
        return proxy
    }

    /// The proxy a profile's process runs with when `stored` is its stored one: an OpenVPN
    /// connection is replaced by the port it was given (none given: refused); any other proxy is
    /// itself.
    static func effective(_ stored: ProxySettings?) throws -> ProxySettings? {
        guard let stored, stored.isOpenVPN else { return stored }
        guard var local = received else { throw HandoffError.missing }
        local.excludedDomains = stored.excludedDomains
        return local
    }
}

/// What is said of an OpenVPN configuration, in the person's language.
enum OpenVPNTexts {
    static func problem(_ problem: OpenVPNConfigProblem) -> String {
        switch problem {
        case .empty: return L("openvpn.problem.empty")
        case .tooLarge: return L("openvpn.problem.tooLarge")
        case .notText: return L("openvpn.problem.notText")
        case .malformed(let line): return String(format: L("openvpn.problem.malformed"), line)
        case .unterminatedBlock(let name): return String(format: L("openvpn.problem.unterminatedBlock"), name)
        case .unknown(let directive, _): return String(format: L("openvpn.problem.unknown"), directive)
        case .unsupported(let directive, let reason):
            return String(format: L("openvpn.problem.unsupported"), directive) + " " + L("openvpn.reason.\(reason.rawValue)")
        case .fileReference(let directive, let file): return String(format: L("openvpn.problem.fileReference"), directive, file)
        case .missing(let what): return String(format: L("openvpn.problem.missing"), what)
        case .noRemote: return L("openvpn.problem.noRemote")
        case .invalidRemote(let text): return String(format: L("openvpn.problem.invalidRemote"), text)
        case .encryptedKey: return L("openvpn.problem.encryptedKey")
        }
    }

    static func notice(_ notice: OpenVPNConfiguration.Notice) -> String {
        switch notice {
        case .leftOut(let directive): return String(format: L("openvpn.notice.leftOut"), directive)
        case .nsCertType: return L("openvpn.notice.nsCertType")
        case .cipherDropped(let cipher): return String(format: L("openvpn.notice.cipherDropped"), cipher)
        case .openSSLCipherList: return L("openvpn.notice.openSSLCipherList")
        case .credentialsTaken: return L("openvpn.notice.credentialsTaken")
        }
    }
}
