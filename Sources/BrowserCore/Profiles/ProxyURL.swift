import Foundation

/// Proxy addresses as text: what users paste from a proxy provider, and what the app shows
/// and copies back out.
///
/// Accepted input (surrounding whitespace is trimmed; whitespace inside is rejected):
///
///     http://host:port              HTTP CONNECT proxy
///     https://host:port             HTTP CONNECT over TLS to the proxy (tlsToProxy)
///     socks5://host:port            SOCKS5
///     socks5h://host:port           SOCKS5 (same behaviour, see below)
///     scheme://user:pass@host:port  credentials, percent-encoded as in any URL
///     scheme://[2001:db8::1]:port   IPv6 literal in brackets
///     host:port                     provider shorthand, HTTP
///     host:port:user:pass           provider shorthand, HTTP; the password is the rest
///     user:pass@host:port           URL without a scheme, HTTP
///
/// Percent-decoding applies only to the URL form with a scheme; the shorthand forms are
/// taken literally, because providers hand out raw passwords that may contain `%`.
///
/// `socks5` vs `socks5h`: in curl the `h` means "let the proxy resolve hostnames". The app
/// has no choice to make here: Network.framework's SOCKS5 client always sends the hostname
/// to the proxy (remote DNS), which `PrivacyBrowser --self-test` verifies (`atyp=3` in
/// scripts/selftest_proxy.py). Both schemes therefore produce the same settings, and
/// `urlString` writes `socks5h` because that is what actually happens.
///
/// Default ports when the URL has none: 8080 for http (the usual proxy port; curl would use
/// 1080, browsers 80), 443 for https (the TLS port, as in curl and Chromium) and 1080 for
/// SOCKS5. The shorthand forms require an explicit port. Paths, queries and fragments are
/// rejected (a single trailing `/` is tolerated). Bypass domains cannot be written in a URL:
/// a parsed proxy has none, and `urlString` leaves them out.
extension ProxySettings {
    public static let defaultHTTPPort = 8080
    public static let defaultHTTPSPort = 443
    public static let defaultSOCKSPort = 1080

    /// Parses a proxy address in any of the forms above, then runs `validate()`.
    /// Throws `CoreError.invalidConfiguration` with a short English message.
    public init(parsing text: String) throws {
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { throw Self.invalid("proxy address is empty") }
        guard input.utf8.count <= 2048 else { throw Self.invalid("proxy address is too long") }
        guard !input.unicodeScalars.contains(where: {
            CharacterSet.whitespacesAndNewlines.contains($0) || CookieRecord.isControl($0)
        }) else {
            throw Self.invalid("proxy address must not contain spaces")
        }

        let kind: Kind
        let tlsToProxy: Bool
        let parsed: Authority
        if let separator = input.range(of: "://") {
            let scheme = input[..<separator.lowerBound].lowercased()
            let defaultPort: Int
            switch scheme {
            case "http": (kind, tlsToProxy, defaultPort) = (.httpConnect, false, Self.defaultHTTPPort)
            case "https": (kind, tlsToProxy, defaultPort) = (.httpConnect, true, Self.defaultHTTPSPort)
            case "socks5", "socks5h": (kind, tlsToProxy, defaultPort) = (.socks5, false, Self.defaultSOCKSPort)
            case "": throw Self.invalid("proxy address has no type before ://")
            default: throw Self.invalid("unsupported proxy type \"\(scheme)\" (use http, https, socks5 or socks5h)")
            }
            var rest = input[separator.upperBound...]
            if rest.hasSuffix("/") { rest = rest.dropLast() }
            guard !rest.contains(where: { $0 == "/" || $0 == "?" || $0 == "#" }) else {
                throw Self.invalid("proxy address must not contain a path or query")
            }
            parsed = try Self.parseAuthority(rest, percentDecode: true, defaultPort: defaultPort)
        } else {
            (kind, tlsToProxy) = (.httpConnect, false)
            parsed = try Self.parseShorthand(Substring(input))
        }

        self.init(kind: kind, host: parsed.host, port: parsed.port, username: parsed.username,
                  password: parsed.password, tlsToProxy: tlsToProxy)
        try validate()
    }

    /// `scheme://[user[:password]@]host:port`, credentials percent-encoded. With
    /// `includePassword == false` the password is shown as "•••" (and the result is then
    /// for display only, not for parsing). The scheme is `socks5h`, `https` or `http`.
    public func urlString(includePassword: Bool) -> String {
        let scheme: String
        switch kind {
        case .socks5: scheme = "socks5h"
        case .httpConnect: scheme = tlsToProxy ? "https" : "http"
        }
        var result = scheme + "://"
        if let username, !username.isEmpty {
            result += Self.percentEncode(username)
            if let password, !password.isEmpty {
                result += ":" + (includePassword ? Self.percentEncode(password) : "•••")
            }
            result += "@"
        }
        return result + hostAndPort
    }

    /// Short label without credentials, e.g. "SOCKS5 203.0.113.5:1080" or
    /// "HTTPS [2001:db8::1]:443".
    public var displayName: String {
        let label: String
        switch kind {
        case .socks5: label = "SOCKS5"
        case .httpConnect: label = tlsToProxy ? "HTTPS" : "HTTP"
        }
        return "\(label) \(hostAndPort)"
    }

    // MARK: - Parsing helpers

    private struct Authority {
        var host: String
        var port: Int
        var username: String?
        var password: String?
    }

    private var hostAndPort: String {
        (host.contains(":") ? "[\(host)]" : host) + ":\(port)"
    }

    private static func invalid(_ message: String) -> CoreError {
        .invalidConfiguration(message)
    }

    /// `host:port`, `host:port:user:pass`, `user:pass@host:port` or `[v6]:port`, no scheme.
    private static func parseShorthand(_ input: Substring) throws -> Authority {
        let parts = input.split(separator: ":", omittingEmptySubsequences: false)
        if input.contains("@") || input.hasPrefix("[") {
            do {
                return try parseAuthority(input, percentDecode: false, defaultPort: nil)
            } catch where parts.count >= 4 && !input.hasPrefix("[") {
                // host:port:user:pass whose username is an e-mail address; handled below.
            }
        }
        switch parts.count {
        case 1:
            throw invalid("proxy port is missing (expected host:port)")
        case 2:
            return Authority(host: try host(parts[0]), port: try port(parts[1]))
        case 3:
            throw invalid("expected host:port or host:port:user:password")
        default:
            let username = String(parts[2])
            guard !username.isEmpty else { throw invalid("proxy username is empty") }
            return Authority(host: try host(parts[0]), port: try port(parts[1]),
                             username: username, password: parts[3...].joined(separator: ":"))
        }
    }

    /// `[user[:password]@]host[:port]`; `defaultPort == nil` makes the port mandatory.
    private static func parseAuthority(_ authority: Substring, percentDecode: Bool, defaultPort: Int?) throws -> Authority {
        var hostPort = authority
        var username: String?
        var password: String?
        // The last '@' separates the credentials, so an unencoded '@' in a password still works.
        if let at = authority.lastIndex(of: "@") {
            let userInfo = authority[..<at]
            hostPort = authority[authority.index(after: at)...]
            let user: Substring
            let pass: Substring
            if let colon = userInfo.firstIndex(of: ":") {
                user = userInfo[..<colon]
                pass = userInfo[userInfo.index(after: colon)...]
            } else {
                user = userInfo
                pass = ""
            }
            username = try credential(user, percentDecode: percentDecode)
            password = try credential(pass, percentDecode: percentDecode)
            guard username?.isEmpty == false else { throw invalid("proxy username is empty") }
        }

        let host: String
        var portText: Substring?
        if hostPort.hasPrefix("[") {
            guard let close = hostPort.firstIndex(of: "]") else { throw invalid("missing ] after IPv6 address") }
            host = try ipv6(hostPort[hostPort.index(after: hostPort.startIndex)..<close])
            let after = hostPort[hostPort.index(after: close)...]
            if !after.isEmpty {
                guard after.first == ":" else { throw invalid("unexpected text after IPv6 address") }
                portText = after.dropFirst()
            }
        } else {
            let parts = hostPort.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count <= 2 else { throw invalid("IPv6 addresses must be written in brackets: [2001:db8::1]:port") }
            host = try self.host(parts[0])
            portText = parts.count == 2 ? parts[1] : nil
        }

        let port: Int
        if let portText {
            port = try self.port(portText)
        } else if let defaultPort {
            port = defaultPort
        } else {
            throw invalid("proxy port is missing (expected host:port)")
        }
        return Authority(host: host, port: port, username: username, password: password)
    }

    /// Hostname or IPv4 address: ASCII letters, digits, '-', '_' and '.' (IDNs as punycode).
    private static func host(_ text: Substring) throws -> String {
        guard !text.isEmpty else { throw invalid("proxy host is empty") }
        guard text.utf8.count <= 253,
              text.unicodeScalars.allSatisfy({ $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "-_.".unicodeScalars.contains($0)) }),
              !text.hasPrefix("."), !text.contains("..") else {
            throw invalid("proxy host \"\(text)\" is not a valid hostname or IP address")
        }
        return text.lowercased()
    }

    /// Bracket contents: hex digits and ':' (plus '.' for an embedded IPv4). Zone IDs
    /// (`%en0`) are rejected: a proxy is never link-local in practice.
    private static func ipv6(_ text: Substring) throws -> String {
        guard text.contains(":"), text.utf8.count <= 45,
              text.unicodeScalars.allSatisfy({ $0.properties.isASCIIHexDigit || $0 == ":" || $0 == "." }) else {
            throw invalid("\"[\(text)]\" is not a valid IPv6 address")
        }
        return text.lowercased()
    }

    private static func port(_ text: Substring) throws -> Int {
        guard !text.isEmpty, text.utf8.count <= 5,
              text.unicodeScalars.allSatisfy({ ("0"..."9").contains($0) }),
              let port = Int(text), (1...65535).contains(port) else {
            throw invalid("proxy port must be a number from 1 to 65535")
        }
        return port
    }

    private static func credential(_ text: Substring, percentDecode: Bool) throws -> String {
        guard percentDecode else { return String(text) }
        guard let decoded = String(text).removingPercentEncoding else {
            throw invalid("invalid %-encoding in proxy username or password")
        }
        guard !decoded.unicodeScalars.contains(where: CookieRecord.isControl) else {
            throw invalid("proxy username or password contains control characters")
        }
        return decoded
    }

    /// RFC 3986 unreserved characters stay; everything else (UTF-8 bytes) is %-encoded.
    private static let userInfoAllowed = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    private static func percentEncode(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: userInfoAllowed) ?? text
    }
}
