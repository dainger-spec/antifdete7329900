import Foundation

/// What a user typed or pasted into a profile's proxy Host field, taken apart.
///
/// People paste whole proxy strings there: `socks5://user:pass@1.2.3.4:1080`, `1.2.3.4:1080`,
/// `user:pass@host`, `[2001:db8::1]:1080`, and the providers' own orders — `1.2.3.4:1080:user:pass`,
/// `user:pass:1.2.3.4:1080`, `1.2.3.4:1080@user:pass` — often with a trailing newline. Handed to `NWEndpoint.Host` as a name, any of that makes every
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

    /// Why a text is not a proxy address. Kept apart from the thrown message so that a list of
    /// pasted proxies (`ProxyListImport`) can say per line what is wrong, in the UI's language.
    public enum Problem: Equatable, Sendable {
        case empty
        /// Spaces, line breaks or invisible characters inside the text.
        case containsWhitespace
        /// A scheme other than socks5 / socks5h / socks / http / https.
        case unsupportedScheme(String)
        /// `scheme://host:port/something`: a proxy address has no path.
        case hasPath
        /// `:password@host` or `@host`.
        case emptyUserName
        case unterminatedIPv6
        case textAfterIPv6
        /// Neither `host`, `host:port` nor `host:port:user:password`.
        case notAHost(String)
        case invalidPort(String)
        case invalidHost(String)

        /// The message `parse` throws (English, as the core's other configuration errors).
        public var message: String {
            switch self {
            case .empty: return "the proxy host is empty"
            case .containsWhitespace: return "the proxy host contains spaces or invisible characters"
            case .unsupportedScheme(let scheme): return "unsupported proxy scheme “\(scheme)” (use socks5, http or https)"
            case .hasPath: return "a proxy address has no path"
            case .emptyUserName: return "the proxy user name is empty"
            case .unterminatedIPv6: return "unterminated IPv6 address"
            case .textAfterIPv6: return "unexpected text after the IPv6 address"
            case .notAHost(let text): return "“\(text)” is not a host name or IP address"
            case .invalidPort(let text): return "“\(text)” is not a port number (1–65535)"
            case .invalidHost(let host): return "“\(host)” is not a valid host name or IP address"
            }
        }
    }

    public static func parse(_ raw: String) throws -> ProxyHostField {
        switch read(raw) {
        case .success(let field): return field
        case .failure(let failure): throw CoreError.invalidConfiguration(failure.problem.message)
        }
    }

    /// What is wrong with `raw` as a proxy address, nil when `parse` accepts it.
    public static func problem(in raw: String) -> Problem? {
        if case .failure(let failure) = read(raw) { return failure.problem }
        return nil
    }

    /// `Result` wants an `Error`; the `Problem` inside is a plain value the UI puts into words.
    struct Failure: Error, Equatable {
        var problem: Problem
    }

    /// `parse`, with what is wrong as a `Problem` instead of a thrown message.
    static func read(_ raw: String) -> Result<ProxyHostField, Failure> {
        func fail(_ problem: Problem) -> Result<ProxyHostField, Failure> { .failure(Failure(problem: problem)) }
        var text = raw.trimmingCharacters(in: junk)
        guard !text.isEmpty else { return fail(.empty) }
        guard text.unicodeScalars.allSatisfy({ !junk.contains($0) }) else { return fail(.containsWhitespace) }
        var field = ProxyHostField(host: "")

        if let separator = text.range(of: "://") {
            switch text[..<separator.lowerBound].lowercased() {
            case "socks5", "socks5h", "socks": field.kind = .socks5
            case "http": field.kind = .httpConnect; field.tlsToProxy = false
            case "https": field.kind = .httpConnect; field.tlsToProxy = true
            case let scheme: return fail(.unsupportedScheme(scheme))
            }
            text = String(text[separator.upperBound...])
            if let slash = text.firstIndex(of: "/") {
                guard text[slash...].allSatisfy({ $0 == "/" }) else { return fail(.hasPath) }
                text = String(text[..<slash])
            }
        }

        // Around an "@" the credentials come first (user:pass@host:port, the URL's order) or last
        // (host:port@user:pass, as many providers hand them out). Both readings are tried; where
        // both make a proxy, the one whose host is plausibly a proxy's (an IP address or a name
        // with a dot) wins, and the URL's order breaks a tie.
        if text.contains("@") {
            let before = credentialsBefore(text, field: field), after = credentialsAfter(text, field: field)
            switch (before, after) {
            case (.success(let first), .success(let second)):
                return .success(isPlausibleHost(first.host) || !isPlausibleHost(second.host) ? first : second)
            case (.success(let first), .failure):
                return .success(first)
            case (.failure, .success(let second)):
                return .success(second)
            case (.failure(let failure), .failure):
                return .failure(failure)
            }
        }

        if !text.hasPrefix("["), !ProxySettings.isIPv6(text) {
            let parts = text.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            if parts.count == 4 {
                return fourParts(parts, field: field)
            }
        }
        return hostAndPort(text, field: field)
    }

    /// user:pass@host[:port] — split at the last "@", so a password may contain "@".
    private static func credentialsBefore(_ text: String, field: ProxyHostField) -> Result<ProxyHostField, Failure> {
        guard let at = text.lastIndex(of: "@") else { return .failure(Failure(problem: .notAHost(text))) }
        var field = field
        guard credentials(text[..<at], into: &field) else { return .failure(Failure(problem: .emptyUserName)) }
        return hostAndPort(String(text[text.index(after: at)...]), field: field)
    }

    /// host:port@user:pass — split at the first "@", so a password may contain "@". The port is
    /// needed: `name@host` is the URL's order.
    private static func credentialsAfter(_ text: String, field: ProxyHostField) -> Result<ProxyHostField, Failure> {
        guard let at = text.firstIndex(of: "@") else { return .failure(Failure(problem: .notAHost(text))) }
        var field = field
        guard credentials(text[text.index(after: at)...], into: &field) else { return .failure(Failure(problem: .emptyUserName)) }
        switch hostAndPort(String(text[..<at]), field: field) {
        case .success(let read) where read.port != nil: return .success(read)
        case .success: return .failure(Failure(problem: .notAHost(text)))
        case .failure(let failure): return .failure(failure)
        }
    }

    /// "user:pass" (the password may contain ":"); false for an empty user name.
    private static func credentials(_ text: Substring, into field: inout ProxyHostField) -> Bool {
        let parts = text.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let user = String(parts[0])
        guard !user.isEmpty else { return false }
        field.username = user.removingPercentEncoding ?? user
        let password = parts.count > 1 ? String(parts[1]) : ""
        field.password = password.removingPercentEncoding ?? password
        return true
    }

    /// host:port:user:pass, or user:pass:host:port — both handed out by providers. Where both make
    /// a proxy, the host first unless only the other reading's host is plausibly a proxy's.
    private static func fourParts(_ parts: [String], field: ProxyHostField) -> Result<ProxyHostField, Failure> {
        func reading(host: String, port: String, user: String, password: String) -> ProxyHostField? {
            guard !user.isEmpty, let port = portNumber(port), ProxySettings.isValidHost(host) else { return nil }
            var read = field
            read.host = host
            read.port = port
            read.username = user
            read.password = password
            return read
        }
        let hostFirst = field.username == nil ? reading(host: parts[0], port: parts[1], user: parts[2], password: parts[3]) : nil
        let userFirst = field.username == nil ? reading(host: parts[2], port: parts[3], user: parts[0], password: parts[1]) : nil
        switch (hostFirst, userFirst) {
        case let (first?, second?):
            return .success(isPlausibleHost(first.host) || !isPlausibleHost(second.host) ? first : second)
        case let (first?, nil):
            return .success(first)
        case let (nil, second?):
            return .success(second)
        case (nil, nil):
            if portNumber(parts[1]) == nil, portNumber(parts[3]) == nil { return .failure(Failure(problem: .invalidPort(parts[1]))) }
            return .failure(Failure(problem: .notAHost(parts.joined(separator: ":"))))
        }
    }

    /// host, host:port, [IPv6]:port or a bare IPv6 address.
    private static func hostAndPort(_ text: String, field: ProxyHostField) -> Result<ProxyHostField, Failure> {
        func fail(_ problem: Problem) -> Result<ProxyHostField, Failure> { .failure(Failure(problem: problem)) }
        var field = field
        if text.hasPrefix("[") {
            guard let close = text.firstIndex(of: "]") else { return fail(.unterminatedIPv6) }
            field.host = String(text[text.index(after: text.startIndex)..<close])
            let rest = text[text.index(after: close)...]
            if !rest.isEmpty {
                guard rest.first == ":" else { return fail(.textAfterIPv6) }
                let portText = String(rest.dropFirst())
                guard let port = portNumber(portText) else { return fail(.invalidPort(portText)) }
                field.port = port
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
                guard let port = portNumber(parts[1]) else { return fail(.invalidPort(parts[1])) }
                field.port = port
            default:
                return fail(.notAHost(text))
            }
        }
        guard ProxySettings.isValidHost(field.host) else { return fail(.invalidHost(field.host)) }
        return .success(field)
    }

    /// A host a proxy is likely to have: an IP address, or a name with a dot in it ("localhost"
    /// too). A single word such as a user name is a valid host name, but rarely a proxy's.
    static func isPlausibleHost(_ host: String) -> Bool {
        ProxySettings.isIPv4(host) || ProxySettings.isIPv6(host) || host.contains(".") || host.lowercased() == "localhost"
    }

    private static func portNumber(_ text: String) -> Int? {
        guard !text.isEmpty, text.count <= 5, text.allSatisfy({ $0.isASCII && $0.isNumber }),
              let port = Int(text), (1...65535).contains(port) else {
            return nil
        }
        return port
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
