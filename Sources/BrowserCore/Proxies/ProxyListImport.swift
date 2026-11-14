import Foundation

/// Reads a list of proxies pasted as text, one per line, in the forms providers hand them out:
///
///     1.2.3.4:1080
///     1.2.3.4:1080:user:pass
///     user:pass@1.2.3.4:1080
///     socks5://user:pass@1.2.3.4:1080      (socks5, socks5h, socks, http, https)
///     http://proxy.example.com:3128  # Berlin 1
///     [2001:db8::1]:1080
///     socks5://user:pass@1.2.3.4:1080[https://provider.example/changeip?key=…]
///
/// Each line is taken apart as the editor's Host field takes a pasted proxy apart
/// (`ProxyHostField`), so a line the list accepts is one the editor would accept too. A line with a
/// scheme is that type; `https://` means TLS to the proxy. A line without one gets the type chosen
/// for the import (`defaultKind`) — or, chosen "find out", none yet: the first check finds it by
/// asking the proxy both ways (`ProxyProbe`, `kindGiven` false). Text after ` #` is the proxy's
/// label; a link in brackets right after the address is the proxy's IP-change link
/// (`ProxyIPChange`), as mobile proxies are sold; blank lines and lines starting with `#` or `//`
/// are skipped. Every other line that is not
/// a usable proxy is reported with its line number and why, as the cookie import reports its file —
/// never silently dropped. The same proxy twice (the same host, port and user name,
/// `ProxyList.identity(of:)`) is read once: the first time.
public enum ProxyListImport {
    /// At most this many proxies are read from one paste (the list's own limit).
    public static let maximumProxies = ProxyList.maximumEntries

    /// A proxy read from the text.
    public struct Line: Equatable, Sendable {
        /// 1-based.
        public var line: Int
        public var proxy: ProxySettings
        /// From ` # label` after the address; empty without one.
        public var label: String
        /// The type is the line's own (its scheme) or the one chosen for the import. False: the line
        /// had no scheme and the import was asked to find out, so `proxy.kind` is only a placeholder
        /// until the first check (`ProxyListEntry.kindKnown`).
        public var kindGiven: Bool
        /// From `[https://…]` right after the address: the provider's IP-change link.
        public var changeIPURL: URL?

        public init(line: Int, proxy: ProxySettings, label: String = "", kindGiven: Bool = true, changeIPURL: URL? = nil) {
            self.line = line
            self.proxy = proxy
            self.label = label
            self.kindGiven = kindGiven
            self.changeIPURL = changeIPURL
        }
    }

    public enum Reason: Equatable, Sendable {
        /// Not a proxy address; `ProxyHostField.Problem` says what is wrong with it.
        case unreadable(ProxyHostField.Problem)
        /// A host without a port: a proxy is always a host and a port.
        case missingPort
        /// The same proxy (`ProxyList.identity(of:)`) as an earlier line, which is the one read.
        case duplicate(ofLine: Int)
        /// More than `maximumProxies` proxies: the lines from this one on were not read.
        case tooMany(Int)
    }

    public struct Problem: Equatable, Sendable {
        /// 1-based.
        public var line: Int
        /// The line as written (shortened), so the user can find it.
        public var text: String
        public var reason: Reason

        public init(line: Int, text: String, reason: Reason) {
            self.line = line
            self.text = text
            self.reason = reason
        }
    }

    public struct Report: Equatable, Sendable {
        public var proxies: [Line]
        public var problems: [Problem]
        /// Lines that held something: neither blank nor a comment.
        public var linesRead: Int

        public init(proxies: [Line] = [], problems: [Problem] = [], linesRead: Int = 0) {
            self.proxies = proxies
            self.problems = problems
            self.linesRead = linesRead
        }

        /// Problems that left a proxy out, not counting lines that repeat one already read.
        public var failures: [Problem] {
            problems.filter { if case .duplicate = $0.reason { return false } else { return true } }
        }
    }

    /// `defaultKind`: the type of a line without a scheme; nil to find it by checking.
    public static func read(_ text: String, defaultKind: ProxySettings.Kind? = nil) -> Report {
        var report = Report(proxies: [], problems: [], linesRead: 0)
        var firstLine: [String: Int] = [:]
        // Character.isNewline: \n, \r\n (one Character), \r and the Unicode line separators.
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        for (index, raw) in lines.enumerated() {
            let number = index + 1
            let trimmed = raw.trimmingCharacters(in: Self.junk)
            if trimmed.isEmpty || trimmed.hasPrefix("#") || trimmed.hasPrefix("//") { continue }
            report.linesRead += 1
            let shown = String(trimmed.prefix(120))
            guard report.proxies.count < maximumProxies else {
                report.problems.append(Problem(line: number, text: shown, reason: .tooMany(maximumProxies)))
                break
            }
            let (written, label) = splitLabel(trimmed)
            let (address, link) = splitChangeLink(written)
            switch proxy(in: address, defaultKind: defaultKind) {
            case .failure(let failure):
                report.problems.append(Problem(line: number, text: shown, reason: failure.reason))
            case .success(let (proxy, kindGiven)):
                let identity = ProxyList.identity(of: proxy)
                if let first = firstLine[identity] {
                    report.problems.append(Problem(line: number, text: shown, reason: .duplicate(ofLine: first)))
                    continue
                }
                firstLine[identity] = number
                report.proxies.append(Line(line: number, proxy: proxy, label: ProxyList.cleanLabel(label), kindGiven: kindGiven,
                                           changeIPURL: link))
            }
        }
        return report
    }

    /// What one field holds: a single proxy typed or pasted where one proxy is entered (a profile's
    /// editor, the list's Edit sheet), read by the same rules as a line of a pasted list (`read`) —
    /// one parser for both, so a string the field takes is one the import takes, and the other way
    /// round.
    public enum Field: Equatable, Sendable {
        /// Nothing (blank, or only a comment).
        case empty
        /// One proxy. Without a scheme its type is not known (`Line.kindGiven` false; `proxy.kind`
        /// is a placeholder): a check finds it (`ProxyProbe`).
        case proxy(Line)
        /// Not a proxy, and why.
        case problem(Reason)
        /// More than one line that holds something: a list, which belongs in the import.
        case several(Int)
    }

    /// `text` as one proxy (`Field`). Nothing is assumed about the type of a line without a scheme.
    public static func readField(_ text: String) -> Field {
        let report = read(text, defaultKind: nil)
        if report.linesRead > 1 { return .several(report.linesRead) }
        if let line = report.proxies.first { return .proxy(line) }
        if let problem = report.problems.first { return .problem(problem.reason) }
        return .empty
    }

    /// `proxy` written as one line in the form `read` takes back:
    /// `scheme://user:password@host:port` — no scheme while its type is not known
    /// (`kindKnown` false), the user name and password percent-encoded where they hold `:`, `@`,
    /// `#`, `%` or spaces, an IPv6 host in brackets. The password is in it in plaintext.
    public static func line(for proxy: ProxySettings, kindKnown: Bool = true) -> String {
        var line = ""
        if kindKnown {
            line += proxy.kind == .socks5 ? "socks5://" : (proxy.tlsToProxy ? "https://" : "http://")
        }
        if let user = proxy.username, !user.isEmpty {
            line += ProxyList.userInfo(user) + ":" + ProxyList.userInfo(proxy.password ?? "") + "@"
        }
        return line + (proxy.host.contains(":") ? "[\(proxy.host)]" : proxy.host) + ":\(proxy.port)"
    }

    /// Where the password is in `text` as it was typed or pasted — for the field to show it as dots
    /// while it is not being edited. Nil when the text is not one proxy, has no password, or the
    /// password is not found where `readField` read it from (the caller then shows none of it).
    public static func passwordRange(in text: String) -> Range<String.Index>? {
        guard case .proxy(let read) = readField(text), let password = read.proxy.password, !password.isEmpty else { return nil }
        // The line `read` took: the first that is neither blank nor a comment.
        var start = text.startIndex
        while start < text.endIndex {
            let end = text[start...].firstIndex(where: \.isNewline) ?? text.endIndex
            let address = addressRange(in: text, line: start..<end)
            let written = text[address]
            if !written.isEmpty, !written.hasPrefix("#"), !written.hasPrefix("//") {
                return passwordRange(in: text, address: address, user: read.proxy.username ?? "", password: password)
            }
            start = end < text.endIndex ? text.index(after: end) : text.endIndex
        }
        return nil
    }

    /// A line without the junk around it and without its ` # label` (as `read` and `splitLabel`).
    private static func addressRange(in text: String, line: Range<String.Index>) -> Range<String.Index> {
        func isJunk(_ character: Character) -> Bool { character.unicodeScalars.allSatisfy { junk.contains($0) } }
        var lower = line.lowerBound, upper = line.upperBound
        while lower < upper, isJunk(text[lower]) { lower = text.index(after: lower) }
        var previous: Character?
        var index = lower
        while index < upper {
            if text[index] == "#", let previous, previous.isWhitespace {
                upper = index
                break
            }
            previous = text[index]
            index = text.index(after: index)
        }
        while upper > lower, isJunk(text[text.index(before: upper)]) { upper = text.index(before: upper) }
        return lower..<upper
    }

    /// Where the password is in an address, in whichever of the providers' orders it was written
    /// (after any scheme): `user:password@host:port`, `host:port@user:password`,
    /// `host:port:user:password`, `user:password:host:port`. Only where the user name is where that
    /// order has it and the text is `password` — so a port or a host that happens to read like the
    /// password is never taken for it.
    private static func passwordRange(in text: String, address: Range<String.Index>, user: String,
                                      password: String) -> Range<String.Index>? {
        let written = text[address]
        let body = written.range(of: "://").map { written[$0.upperBound...] } ?? written
        func matches(_ range: Range<String.Index>, _ expected: String) -> Bool {
            let raw = String(text[range])
            return raw == expected || raw.removingPercentEncoding == expected
        }
        var candidates: [(user: Range<String.Index>, password: Range<String.Index>)] = []
        // user:password@host:port — the last "@".
        if let at = body.lastIndex(of: "@"), let colon = body[..<at].firstIndex(of: ":") {
            candidates.append((body.startIndex..<colon, body.index(after: colon)..<at))
        }
        // host:port@user:password — the first "@".
        if let at = body.firstIndex(of: "@") {
            let credentials = body[body.index(after: at)...]
            if let colon = credentials.firstIndex(of: ":") {
                candidates.append((credentials.startIndex..<colon, credentials.index(after: colon)..<body.endIndex))
            }
        }
        let colons = body.indices.filter { body[$0] == ":" }
        if !body.contains("@"), colons.count == 3 {
            // host:port:user:password, then user:password:host:port.
            candidates.append((body.index(after: colons[1])..<colons[2], body.index(after: colons[2])..<body.endIndex))
            candidates.append((body.startIndex..<colons[0], body.index(after: colons[0])..<colons[1]))
        }
        return candidates.first { matches($0.user, user) && matches($0.password, password) }?.password
    }

    /// One address (without its label) as the proxy it names, and whether its type is known.
    static func proxy(in address: String, defaultKind: ProxySettings.Kind?) -> Result<(ProxySettings, kindGiven: Bool), ReasonError> {
        let field: ProxyHostField
        switch ProxyHostField.read(address) {
        case .success(let read): field = read
        case .failure(let failure): return .failure(ReasonError(reason: .unreadable(failure.problem)))
        }
        guard let port = field.port else { return .failure(ReasonError(reason: .missingPort)) }
        // A placeholder while the type is unknown: SOCKS5, the type most proxy lists hand out.
        let kind = field.kind ?? defaultKind ?? .socks5
        let proxy = ProxySettings(kind: kind, host: field.host, port: port,
                                  username: field.username, password: field.username == nil ? nil : (field.password ?? ""),
                                  tlsToProxy: kind == .httpConnect && field.tlsToProxy == true)
        // What ProxyHostField accepted always validates; checked anyway, as a profile would be.
        guard (try? proxy.validate()) != nil else {
            return .failure(ReasonError(reason: .unreadable(.invalidHost(field.host))))
        }
        return .success((proxy, field.kind != nil || defaultKind != nil))
    }

    /// `Result` wants an `Error`.
    struct ReasonError: Error, Equatable {
        var reason: Reason
    }

    /// "address  # label" → ("address", "label"). Only a "#" after a space starts the label: one
    /// inside the address (a password may hold one) does not.
    static func splitLabel(_ line: String) -> (address: String, label: String) {
        var previous: Character?
        for index in line.indices {
            let character = line[index]
            if character == "#", let previous, previous.isWhitespace {
                let address = line[..<index].trimmingCharacters(in: junk)
                let label = line[line.index(after: index)...].trimmingCharacters(in: .whitespaces)
                return (address, label)
            }
            previous = character
        }
        return (line, "")
    }

    /// "address[https://link]" → ("address", the link). Only a bracket that opens an http(s) link
    /// and closes the line counts: an IPv6 host's brackets (`[2001:db8::1]:1080`) do not. A link
    /// that is not one (`ProxyIPChange.link(from:)`) leaves the line as it was, for the address to
    /// be found unreadable rather than a broken link to be dropped silently.
    static func splitChangeLink(_ written: String) -> (address: String, link: URL?) {
        guard written.hasSuffix("]") else { return (written, nil) }
        for opening in ["[https://", "[http://", "[HTTPS://", "[HTTP://"] {
            guard let range = written.range(of: opening, options: .backwards) else { continue }
            let inner = String(written[written.index(after: range.lowerBound)..<written.index(before: written.endIndex)])
            guard let link = ProxyIPChange.link(from: inner) else { return (written, nil) }
            return (written[..<range.lowerBound].trimmingCharacters(in: junk), link)
        }
        return (written, nil)
    }

    /// Whitespace, control characters and the invisible ones copied with text (BOM, zero-width).
    static let junk = CharacterSet.whitespacesAndNewlines
        .union(.controlCharacters)
        .union(CharacterSet(charactersIn: "\u{FEFF}\u{200B}\u{200C}\u{200D}\u{2060}"))
}
