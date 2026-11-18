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
///     1.2.3.4	1080	user	pass                 (columns: copied from a spreadsheet or a provider's table)
///     socks5 1.2.3.4 1080 user pass
///     1.2.3.4;1080;user;pass                   (also "," and "|")
///     1.2.3.4:1080:user:pass https://provider.example/changeip?key=…
///     vless://uuid@server.example:443?security=reality&…#Name   (vmess://, trojan://, ss:// too)
///
/// A share link (`ShareLink`) is read whole as the link it is — its fragment is its label — and
/// what is wrong with one is said as a link's problem, without its secret. A provider's
/// subscription pasted as it is served (base64 of its links, one per line) is read as those links.
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
///
/// A line that does not read as written is read once more as columns (`columns`): its parts
/// separated by tabs, spaces, ";", "," or "|" — a row of a spreadsheet, of a provider's table or of
/// its CSV file — with the type as a word of its own ("socks5", "http") and the IP-change link as
/// a column of its own. Only then: a line that reads as written is never read another way, so a
/// password with a ";" or a "|" in it stays what it was.
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
        /// A share link (vless://, vmess://, trojan://, ss://) the relay cannot use, and why.
        case shareLink(ShareLinkError)
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
        let lines = subscriptionLinks(in: text).split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
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
            if ShareLink.looksLikeLink(written) {
                do {
                    let proxy = try ProxySettings(shareLink: written)
                    let identity = ProxyList.identity(of: proxy)
                    if let first = firstLine[identity] {
                        report.problems.append(Problem(line: number, text: ShareLink.masked(written), reason: .duplicate(ofLine: first)))
                        continue
                    }
                    firstLine[identity] = number
                    let name = label.isEmpty ? (proxy.shareLink?.name ?? "") : label
                    report.proxies.append(Line(line: number, proxy: proxy, label: ProxyList.cleanLabel(name), kindGiven: true))
                } catch {
                    let reason = (error as? ShareLinkError).map(Reason.shareLink) ?? .shareLink(.invalidBase64)
                    report.problems.append(Problem(line: number, text: ShareLink.masked(written), reason: reason))
                }
                continue
            }
            let (address, bracketLink) = splitChangeLink(written)
            var link = bracketLink
            var result = proxy(in: address, defaultKind: defaultKind)
            // Not a proxy as written: its parts may stand in columns. What is wrong with the line
            // as written is what is reported when that does not make a proxy either.
            if case .failure = result, let inColumns = columns(address),
               case .success(let read) = proxy(in: inColumns.address, defaultKind: defaultKind) {
                result = .success(read)
                link = link ?? inColumns.link
            }
            switch result {
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
        // A share link is written back as it was given: it holds its secret in plaintext too.
        if proxy.kind == .xray { return proxy.link ?? "" }
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
        // A share link's secret: its id or password, or the whole of a form that is base64.
        if case .proxy(let read) = readField(text), read.proxy.kind == .xray { return ShareLink.secretRange(in: text) }
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

    /// What stands between the columns of a row: tabs and spaces (a no-break space too), ";", ","
    /// and "|".
    private static let columnSeparators = CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\u{00A0};,|"))

    /// The words a type's column holds, with the scheme each stands for.
    private static let kindWords = ["socks5": "socks5", "socks5h": "socks5", "socks": "socks5", "http": "http", "https": "https"]

    /// A line whose parts stand in columns, as the one address `proxy(in:)` reads — or nil when it
    /// has no columns. From the columns, in this order: a last one that is an http(s) link with a
    /// path or a query is the IP-change link (a proxy's own address has neither); a first or a last
    /// one that is a type's word ("socks5", "HTTP") is the type; what is left — two to four parts,
    /// each possibly several already joined by ":" — is joined by ":" into `host:port:user:password`
    /// (or the other orders `ProxyHostField` reads). Quotes around a column, as a CSV file writes
    /// them, are taken off.
    ///
    /// Not columns, and nil: two proxies on one line ("1.2.3.4:8080 5.6.7.8:8080", "1.2.3.4 8080
    /// 5.6.7.8 8080") — joined, the second would be read as the first one's user name and password.
    /// Such a line stays what it was: not read, and said.
    static func columns(_ written: String) -> (address: String, link: URL?)? {
        var parts = written.components(separatedBy: columnSeparators)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) }
            .filter { !$0.isEmpty }
        guard parts.count >= 2 else { return nil }
        var link: URL?
        if let last = parts.last, looksLikeLink(last), let url = ProxyIPChange.link(from: last) {
            link = url
            parts.removeLast()
        }
        var scheme = ""
        if let first = parts.first, parts.count > 1, let word = kindWords[first.lowercased()] {
            scheme = word + "://"
            parts.removeFirst()
        } else if let last = parts.last, parts.count > 1, let word = kindWords[last.lowercased()] {
            scheme = word + "://"
            parts.removeLast()
        }
        guard !parts.isEmpty, parts.count <= 4 else { return nil }
        // Two columns that are each a proxy's whole address: two proxies.
        let whole = parts.filter { part in
            guard case .success(let field) = ProxyHostField.read(part), field.port != nil else { return false }
            return ProxyHostField.isPlausibleHost(field.host)
        }
        guard whole.count < 2 else { return nil }
        let joined = parts.joined(separator: ":")
        let pieces = joined.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        if pieces.count == 4, ProxySettings.isIPv4(pieces[0]), ProxySettings.isIPv4(pieces[2]) { return nil }
        return (scheme + joined, link)
    }

    /// An http(s) address with a path or a query: what an IP-change link is, and what a proxy's
    /// own address (`http://1.2.3.4:8080`) is not.
    private static func looksLikeLink(_ text: String) -> Bool {
        let lower = text.lowercased()
        guard lower.hasPrefix("http://") || lower.hasPrefix("https://"), let components = URLComponents(string: text) else {
            return false
        }
        return components.path.count > 1 || components.query != nil
    }

    /// A provider's subscription as it is served — base64 of its share links, one per line — as
    /// those lines; any other text as it is. Only a text that is one block of base64 and decodes to
    /// lines that hold share links is taken for one.
    static func subscriptionLinks(in text: String) -> String {
        let trimmed = text.trimmingCharacters(in: junk)
        guard !trimmed.isEmpty, !trimmed.contains("://"), trimmed.count <= ProxyList.maximumEntries * ShareLink.maximumLength,
              let decoded = ShareLink.base64Text(trimmed) else { return text }
        let holdsLinks = decoded.split(whereSeparator: \.isNewline).contains { ShareLink.looksLikeLink(String($0)) }
        return holdsLinks ? decoded : text
    }

    /// Whitespace, control characters and the invisible ones copied with text (BOM, zero-width).
    static let junk = CharacterSet.whitespacesAndNewlines
        .union(.controlCharacters)
        .union(CharacterSet(charactersIn: "\u{FEFF}\u{200B}\u{200C}\u{200D}\u{2060}"))
}
