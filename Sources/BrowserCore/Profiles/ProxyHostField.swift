import Foundation

/// What a user typed or pasted into a profile's proxy Host field, taken apart.
///
/// People paste whole proxy strings there: `socks5://user:pass@1.2.3.4:1080`, `1.2.3.4:1080`,
/// `1.2.3.4:1080:user:pass` (a common provider format), `user:pass@host`, `[2001:db8::1]:1080`,
/// often with a trailing newline. Handed to `NWEndpoint.Host` as a name, any of that makes every
/// load fail (-1000 / cannot find host), so the editor splits it into its fields and rejects
/// anything that is not a host name or an IP address.
public struct ProxyHostField: Equatable, Sendable {
    public var host: String
    public var port: Int?
    public var username: String?
    public var password: String?
    /// From a scheme prefix: socks5 / socks5h / socks → SOCKS5, http / https → HTTP CONNECT.
    public var kind: ProxySettings.Kind?
    /// `https://` means TLS to the proxy, `http://` means none.
    public var tlsToProxy: Bool?

    public init(host: String, port: Int? = nil, username: String? = nil, password: String? = nil,
                kind: ProxySettings.Kind? = nil, tlsToProxy: Bool? = nil) {
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.kind = kind
        self.tlsToProxy = tlsToProxy
    }

    private static let junk = CharacterSet.whitespacesAndNewlines
        .union(.controlCharacters)
        .union(CharacterSet(charactersIn: "\u{FEFF}\u{200B}\u{200C}\u{200D}\u{2060}"))

    public static func parse(_ raw: String) throws -> ProxyHostField {
        var text = raw.trimmingCharacters(in: junk)
        guard !text.isEmpty else { throw invalid("the proxy host is empty") }
        guard text.unicodeScalars.allSatisfy({ !junk.contains($0) }) else {
            throw invalid("the proxy host contains spaces or invisible characters")
        }
        var field = ProxyHostField(host: "")

        if let separator = text.range(of: "://") {
            switch text[..<separator.lowerBound].lowercased() {
            case "socks5", "socks5h", "socks": field.kind = .socks5
            case "http": field.kind = .httpConnect; field.tlsToProxy = false
            case "https": field.kind = .httpConnect; field.tlsToProxy = true
            case let scheme: throw invalid("unsupported proxy scheme “\(scheme)” (use socks5, http or https)")
            }
            text = String(text[separator.upperBound...])
            if let slash = text.firstIndex(of: "/") {
                guard text[slash...].allSatisfy({ $0 == "/" }) else { throw invalid("a proxy address has no path") }
                text = String(text[..<slash])
            }
        }

        // user:pass@host — the last "@", so a password may contain "@".
        if let at = text.lastIndex(of: "@") {
            let credentials = text[..<at]
            text = String(text[text.index(after: at)...])
            let parts = credentials.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            let user = String(parts[0])
            guard !user.isEmpty else { throw invalid("the proxy user name is empty") }
            field.username = user.removingPercentEncoding ?? user
            let password = parts.count > 1 ? String(parts[1]) : ""
            field.password = password.removingPercentEncoding ?? password
        }

        if text.hasPrefix("[") {
            guard let close = text.firstIndex(of: "]") else { throw invalid("unterminated IPv6 address") }
            field.host = String(text[text.index(after: text.startIndex)..<close])
            let rest = text[text.index(after: close)...]
            if !rest.isEmpty {
                guard rest.first == ":" else { throw invalid("unexpected text after the IPv6 address") }
                field.port = try port(String(rest.dropFirst()))
            }
        } else if ProxySettings.isIPv6(text) {
            field.host = text // a bare IPv6 literal has no port
        } else {
            let parts = text.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            switch parts.count {
            case 1:
                field.host = parts[0]
            case 2:
                field.host = parts[0]
                field.port = try port(parts[1])
            case 4 where field.username == nil && !parts[2].isEmpty:
                // host:port:user:pass, as many proxy providers hand them out.
                field.host = parts[0]
                field.port = try port(parts[1])
                field.username = parts[2]
                field.password = parts[3]
            default:
                throw invalid("“\(text)” is not a host name or IP address")
            }
        }

        guard ProxySettings.isValidHost(field.host) else {
            throw invalid("“\(field.host)” is not a valid host name or IP address")
        }
        return field
    }

    private static func port(_ text: String) throws -> Int {
        guard !text.isEmpty, text.count <= 5, text.allSatisfy({ $0.isASCII && $0.isNumber }),
              let port = Int(text), (1...65535).contains(port) else {
            throw invalid("“\(text)” is not a port number (1–65535)")
        }
        return port
    }

    private static func invalid(_ message: String) -> CoreError {
        .invalidConfiguration(message)
    }
}

extension ProxySettings {
    /// A bare host name (ASCII letters, digits, "-" and "_" in dot-separated labels), an IPv4
    /// address or an IPv6 address without brackets. No scheme, port, credentials or whitespace.
    public static func isValidHost(_ host: String) -> Bool {
        guard !host.isEmpty, host.count <= 253 else { return false }
        if isIPv4(host) { return true }
        if host.contains(":") { return isIPv6(host) }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        for label in labels {
            guard (1...63).contains(label.count), label.first != "-", label.last != "-",
                  label.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else {
                return false
            }
        }
        // All-numeric but not a valid IPv4 address (1.2.3, 300.1.1.1): never a usable name.
        return !labels.allSatisfy { $0.allSatisfy { $0.isASCII && $0.isNumber } }
    }

    static func isIPv4(_ text: String) -> Bool {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { part in
            (1...3).contains(part.count) && part.allSatisfy({ $0.isASCII && $0.isNumber })
                && (Int(part).map { $0 <= 255 } ?? false)
        }
    }

    /// Hex groups separated by ":", at most one "::", optionally an IPv4 tail. No zone index.
    static func isIPv6(_ text: String) -> Bool {
        guard text.contains(":"), !text.contains(":::"),
              text.allSatisfy({ $0.isASCII && ($0.isHexDigit || $0 == ":" || $0 == ".") }) else { return false }
        if text.hasPrefix(":") && !text.hasPrefix("::") { return false }
        if text.hasSuffix(":") && !text.hasSuffix("::") { return false }
        let compressions = text.components(separatedBy: "::").count - 1
        guard compressions <= 1 else { return false }
        var groups = text.split(separator: ":").map(String.init)
        var count = groups.count
        if let last = groups.last, last.contains(".") {
            guard isIPv4(last) else { return false }
            groups.removeLast()
            count += 1 // an IPv4 tail takes the place of two groups
        }
        guard groups.allSatisfy({ (1...4).contains($0.count) && !$0.contains(".") }) else { return false }
        return compressions == 1 ? count <= 7 : count == 8
    }
}
