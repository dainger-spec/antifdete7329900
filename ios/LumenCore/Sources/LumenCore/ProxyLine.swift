import Foundation

/// A proxy written as one line, in the forms providers hand them out — read by the Mac's rules
/// (its `ProxyHostField` and `ProxyListImport`), so a line the Mac takes the iPhone takes too:
///
///     1.2.3.4:1080
///     1.2.3.4:1080:user:pass          user:pass:1.2.3.4:1080
///     user:pass@1.2.3.4:1080          1.2.3.4:1080@user:pass
///     socks5://user:pass@1.2.3.4:1080 (socks5, socks5h, socks, http)
///     http://proxy.example.com:3128  # Berlin 1
///     [2001:db8::1]:1080
///
/// A line with a scheme is that type; one without says nothing of the type (`kind` nil), and the
/// person chooses it. Text after ` #` is the proxy's name. The iPhone has no TLS to a proxy, so
/// `https://` is refused by name instead of being taken for plain HTTP.
public struct ProxyLine: Equatable, Sendable {
    public var kind: ProxyKind?
    public var host: String
    public var port: Int
    /// Empty: no login.
    public var username: String
    /// Nil: the line holds no password (an edited proxy keeps the one it has).
    public var password: String?
    /// From ` # name` after the address; empty without one.
    public var label: String

    public init(kind: ProxyKind? = nil, host: String, port: Int, username: String = "", password: String? = nil, label: String = "") {
        self.kind = kind
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.label = label
    }

    public enum Problem: Error, Equatable, Sendable {
        case empty
        case several
        case spaces
        case scheme(String)
        case path
        case emptyUser
        case notAHost
        case port
        case missingPort

        /// The problem in the person's words.
        public var text: String {
            switch self {
            case .empty: return L("Введите адрес прокси.")
            case .several: return L("Здесь один прокси: одна строка.")
            case .spaces: return L("В адресе прокси не бывает пробелов.")
            case let .scheme(scheme): return L("Вид прокси «%@» не поддерживается: подойдут socks5 и http.", scheme)
            case .path: return L("У адреса прокси нет пути после порта.")
            case .emptyUser: return L("Перед паролем нужен логин.")
            case .notAHost: return L("Это не адрес прокси: нужен адрес и порт.")
            case .port: return L("Порт — число от 1 до 65535.")
            case .missingPort: return L("Укажите порт: адрес:порт.")
            }
        }
    }

    private static let junk = CharacterSet.whitespacesAndNewlines
        .union(.controlCharacters)
        .union(CharacterSet(charactersIn: "\u{FEFF}\u{200B}\u{200C}\u{200D}\u{2060}"))

    /// One proxy from what a field holds.
    public static func read(_ raw: String) -> Result<ProxyLine, Problem> {
        let lines = raw.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: junk) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") && !$0.hasPrefix("//") }
        guard let line = lines.first else { return .failure(.empty) }
        guard lines.count == 1 else { return .failure(.several) }
        let (address, label) = splitLabel(line)
        switch parts(of: address) {
        case let .failure(problem): return .failure(problem)
        case let .success(parts):
            guard let port = parts.port else { return .failure(.missingPort) }
            return .success(ProxyLine(kind: parts.kind, host: parts.host, port: port, username: parts.username ?? "",
                                      password: parts.username == nil ? nil : parts.password, label: label))
        }
    }

    /// The line of a proxy as the list keeps it — without its password, which is never shown again.
    public static func write(kind: ProxyKind, host: String, port: Int, username: String) -> String {
        var line = kind == .socks5 ? "socks5://" : "http://"
        if !username.isEmpty {
            line += (username.addingPercentEncoding(withAllowedCharacters: userAllowed) ?? username) + "@"
        }
        return line + (host.contains(":") ? "[\(host)]" : host) + ":\(port)"
    }

    private static let userAllowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~!$&'()*+,;="))

    // MARK: - The Mac's reading, part for part

    private struct Parts {
        var kind: ProxyKind?
        var host = ""
        var port: Int?
        var username: String?
        var password: String?
    }

    private static func splitLabel(_ line: String) -> (address: String, label: String) {
        var previous: Character?
        for index in line.indices {
            let character = line[index]
            if character == "#", let previous, previous.isWhitespace {
                return (line[..<index].trimmingCharacters(in: junk), line[line.index(after: index)...].trimmingCharacters(in: .whitespaces))
            }
            previous = character
        }
        return (line, "")
    }

    private static func parts(of raw: String) -> Result<Parts, Problem> {
        var text = raw.trimmingCharacters(in: junk)
        guard !text.isEmpty else { return .failure(.empty) }
        guard text.unicodeScalars.allSatisfy({ !junk.contains($0) }) else { return .failure(.spaces) }
        var parts = Parts()
        if let separator = text.range(of: "://") {
            let scheme = text[..<separator.lowerBound].lowercased()
            switch scheme {
            case "socks5", "socks5h", "socks": parts.kind = .socks5
            case "http": parts.kind = .http
            default: return .failure(.scheme(scheme))
            }
            text = String(text[separator.upperBound...])
            if let slash = text.firstIndex(of: "/") {
                guard text[slash...].allSatisfy({ $0 == "/" }) else { return .failure(.path) }
                text = String(text[..<slash])
            }
        }
        // Around an "@" the credentials come first (user:pass@host:port, a URL's order) or last
        // (host:port@user:pass). Both readings are tried; where both make a proxy, the one whose
        // host is plausibly a proxy's wins, and the URL's order breaks a tie.
        if text.contains("@") {
            let before = credentialsBefore(text, parts), after = credentialsAfter(text, parts)
            switch (before, after) {
            case let (.success(first), .success(second)):
                return .success(isPlausibleHost(first.host) || !isPlausibleHost(second.host) ? first : second)
            case let (.success(first), .failure): return .success(first)
            case let (.failure, .success(second)): return .success(second)
            case let (.failure(problem), .failure): return .failure(problem)
            }
        }
        if !text.hasPrefix("["), !isIPv6(text) {
            let pieces = text.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            if pieces.count == 4 { return fourParts(pieces, parts) }
        }
        return hostAndPort(text, parts)
    }

    private static func credentialsBefore(_ text: String, _ parts: Parts) -> Result<Parts, Problem> {
        guard let at = text.lastIndex(of: "@") else { return .failure(.notAHost) }
        var parts = parts
        guard credentials(text[..<at], into: &parts) else { return .failure(.emptyUser) }
        return hostAndPort(String(text[text.index(after: at)...]), parts)
    }

    private static func credentialsAfter(_ text: String, _ parts: Parts) -> Result<Parts, Problem> {
        guard let at = text.firstIndex(of: "@") else { return .failure(.notAHost) }
        var parts = parts
        guard credentials(text[text.index(after: at)...], into: &parts) else { return .failure(.emptyUser) }
        switch hostAndPort(String(text[..<at]), parts) {
        case let .success(read): return read.port != nil ? .success(read) : .failure(.notAHost)
        case let .failure(problem): return .failure(problem)
        }
    }

    private static func credentials(_ text: Substring, into parts: inout Parts) -> Bool {
        let pieces = text.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let user = pieces.isEmpty ? "" : String(pieces[0])
        guard !user.isEmpty else { return false }
        parts.username = user.removingPercentEncoding ?? user
        let password = pieces.count > 1 ? String(pieces[1]) : ""
        parts.password = password.removingPercentEncoding ?? password
        return true
    }

    private static func fourParts(_ pieces: [String], _ parts: Parts) -> Result<Parts, Problem> {
        func reading(host: String, port: String, user: String, password: String) -> Parts? {
            guard !user.isEmpty, let port = portNumber(port), isValidHost(host) else { return nil }
            var read = parts
            read.host = host
            read.port = port
            read.username = user
            read.password = password
            return read
        }
        let hostFirst = reading(host: pieces[0], port: pieces[1], user: pieces[2], password: pieces[3])
        let userFirst = reading(host: pieces[2], port: pieces[3], user: pieces[0], password: pieces[1])
        switch (hostFirst, userFirst) {
        case let (first?, second?):
            return .success(isPlausibleHost(first.host) || !isPlausibleHost(second.host) ? first : second)
        case let (first?, nil): return .success(first)
        case let (nil, second?): return .success(second)
        case (nil, nil):
            return .failure(portNumber(pieces[1]) == nil && portNumber(pieces[3]) == nil ? .port : .notAHost)
        }
    }

    private static func hostAndPort(_ text: String, _ parts: Parts) -> Result<Parts, Problem> {
        var parts = parts
        if text.hasPrefix("[") {
            guard let close = text.firstIndex(of: "]") else { return .failure(.notAHost) }
            parts.host = String(text[text.index(after: text.startIndex)..<close])
            let rest = text[text.index(after: close)...]
            if !rest.isEmpty {
                guard rest.first == ":" else { return .failure(.notAHost) }
                guard let port = portNumber(String(rest.dropFirst())) else { return .failure(.port) }
                parts.port = port
            }
        } else if isIPv6(text) {
            parts.host = text   // a bare IPv6 literal has no port
        } else {
            let pieces = text.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            switch pieces.count {
            case 1:
                parts.host = pieces[0]
            case 2:
                parts.host = pieces[0]
                guard let port = portNumber(pieces[1]) else { return .failure(.port) }
                parts.port = port
            default:
                return .failure(.notAHost)
            }
        }
        guard isValidHost(parts.host) else { return .failure(.notAHost) }
        return .success(parts)
    }

    static func isPlausibleHost(_ host: String) -> Bool {
        isIPv4(host) || isIPv6(host) || host.contains(".") || host.lowercased() == "localhost"
    }

    private static func portNumber(_ text: String) -> Int? {
        guard !text.isEmpty, text.count <= 5, text.allSatisfy({ $0.isASCII && $0.isNumber }),
              let port = Int(text), (1...65535).contains(port) else { return nil }
        return port
    }

    static func isIPv4(_ text: String) -> Bool {
        let pieces = text.split(separator: ".", omittingEmptySubsequences: false)
        return pieces.count == 4 && pieces.allSatisfy { piece in
            !piece.isEmpty && piece.count <= 3 && piece.allSatisfy { $0.isASCII && $0.isNumber } && (Int(piece) ?? 256) <= 255
        }
    }

    static func isIPv6(_ text: String) -> Bool {
        guard text.contains(":") else { return false }
        var address = in6_addr()
        return inet_pton(AF_INET6, text, &address) == 1
    }

    static func isValidHost(_ host: String) -> Bool {
        guard !host.isEmpty, host.count <= 253 else { return false }
        if isIPv4(host) { return true }
        if host.contains(":") { return isIPv6(host) }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        for label in labels {
            guard (1...63).contains(label.count), label.first != "-", label.last != "-",
                  label.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else { return false }
        }
        // All-numeric but not an IPv4 address (1.2.3, 300.1.1.1): never a usable name.
        return !labels.allSatisfy { $0.allSatisfy { $0.isASCII && $0.isNumber } }
    }
}
