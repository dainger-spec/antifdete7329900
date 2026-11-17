import BrowserCore
import Foundation

/// What the proxy field, the list and the editor say of a share link (`ShareLink`): how it reaches
/// its server, and what to know about it. Never its id or password.
enum ShareLinkText {
    /// "REALITY + TCP + Vision", "TLS + WebSocket", "2022-blake3-aes-128-gcm": protocol names, said
    /// as they are written everywhere.
    static func transport(_ link: ShareLink) -> String {
        if link.scheme == .shadowsocks { return link.method ?? "" }
        var parts: [String] = []
        switch link.security {
        case .reality: parts.append("REALITY") // l10n: not text
        case .tls: parts.append("TLS") // l10n: not text
        case .none: break
        }
        switch link.transport {
        case .tcp: parts.append("TCP") // l10n: not text
        case .ws: parts.append("WebSocket") // l10n: not text
        case .grpc: parts.append("gRPC") // l10n: not text
        case .httpupgrade: parts.append("HTTPUpgrade") // l10n: not text
        case .xhttp: parts.append("XHTTP") // l10n: not text
        }
        if link.flow != nil { parts.append("Vision") } // l10n: not text
        return parts.joined(separator: " + ") // l10n: not text
    }

    /// The link's own traffic to its server is readable on the way: VLESS or Trojan without TLS or
    /// REALITY (VLESS has no encryption of its own unless VLESS Encryption is on), VMess with its
    /// cipher off.
    static func isUnencrypted(_ link: ShareLink) -> Bool {
        guard link.security == .none else { return false }
        switch link.scheme {
        case .vless: return (link.encryption ?? "none") == "none"
        case .trojan: return true
        case .vmess: return link.method == "none" || link.method == "zero"
        case .shadowsocks: return false
        }
    }

    /// What is said under the link, in the person's language: its traffic readable on the way, or a
    /// certificate check the link wanted off and that is kept on.
    static func notes(_ link: ShareLink) -> [String] {
        var notes: [String] = []
        if isUnencrypted(link) { notes.append(L("proxyLine.link.unencrypted")) }
        if link.askedInsecure, link.pinnedCertificateSHA256 == nil { notes.append(L("proxyLine.link.insecureIgnored")) }
        return notes
    }
}
