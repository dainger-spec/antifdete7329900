import Foundation

/// A VLESS, VMess, Trojan or Shadowsocks server, as its share link names it — the
/// `vless://…`, `vmess://…`, `trojan://…` and `ss://…` lines providers hand out. A profile does not
/// talk to such a server itself: the app starts a relay for it (Xray, docs/TUNNEL.md, "Links"),
/// and the profile uses that relay as a SOCKS5 proxy on 127.0.0.1 (`ProxySettings.Kind.xray`).
///
/// Read strictly: every value the relay is given is checked here, and a link that asks for what the
/// relay cannot do — a transport Xray has removed, an old cipher, a plugin — is refused with what is
/// wrong, never half taken. Parameters the relay has no use for are left out, never passed on: none
/// of them may add a destination (XHTTP's `extra` can name a second server, `ech` a resolver).
///
/// The link holds secrets — VLESS and VMess the user's id, Trojan and Shadowsocks a password — and
/// is kept as a proxy's password is: in the encrypted settings, never logged (`redacted`).
public struct ShareLink: Equatable, Sendable {
    public enum Scheme: String, Sendable, CaseIterable {
        case vless, vmess, trojan, shadowsocks

        /// As the person reads it: "VLESS", "VMess", "Trojan", "Shadowsocks".
        public var displayName: String {
            switch self {
            case .vless: return "VLESS"
            case .vmess: return "VMess"
            case .trojan: return "Trojan"
            case .shadowsocks: return "Shadowsocks"
            }
        }

        /// The link's own prefix.
        public var prefix: String { self == .shadowsocks ? "ss" : rawValue }
    }

    /// How the protocol's stream is carried to the server. "tcp" is Xray's RAW.
    public enum Transport: String, Sendable, CaseIterable {
        case tcp, ws, grpc, httpupgrade, xhttp
    }

    public enum Security: String, Sendable, CaseIterable {
        case none, tls, reality
    }

    public var scheme: Scheme
    /// The server: a host name, an IPv4 address or an IPv6 one (without brackets).
    public var host: String
    public var port: Int
    /// The provider's name for it (the fragment, VMess's `ps`): one line, at most 64 characters.
    public var name: String
    /// VLESS and VMess: the user's id (a UUID, or Xray's 1–30 character form). Secret.
    public var userID: String?
    /// Trojan and Shadowsocks: the password (a 2022 cipher's: its key). Secret.
    public var password: String?
    /// Shadowsocks: the cipher; VMess: its security ("auto", "aes-128-gcm", …).
    public var method: String?
    /// VLESS: "xtls-rprx-vision" or "xtls-rprx-vision-udp443"; nil: none.
    public var flow: String?
    /// VLESS: "none", or VLESS Encryption's client string.
    public var encryption: String?
    public var transport: Transport
    /// WebSocket, HTTPUpgrade, XHTTP, and RAW with an HTTP header: the request's path.
    public var path: String?
    /// The same: the request's Host header.
    public var hostHeader: String?
    /// gRPC: the service name, and its authority (`:authority`).
    public var serviceName: String?
    public var authority: String?
    /// gRPC: multi mode ("mode=multi").
    public var grpcMultiMode: Bool
    /// XHTTP: "auto", "packet-up", "stream-up" or "stream-one".
    public var xhttpMode: String?
    /// RAW (TCP) with HTTP obfuscation (`headerType=http`).
    public var tcpHTTPHeader: Bool
    public var security: Security
    /// TLS and REALITY: the server name sent (SNI).
    public var serverName: String?
    /// uTLS fingerprint ("chrome", "firefox", "safari", …).
    public var fingerprint: String?
    public var alpn: [String]
    /// TLS: the server certificate's SHA-256 (`pcs`), hex, the way to accept a self-signed one.
    public var pinnedCertificateSHA256: String?
    /// TLS: the names the certificate is checked against instead of the SNI (`vcn`).
    public var verifyCertificateByName: String?
    /// REALITY: the server's X25519 public key (`pbk`), its short id (`sid`), the spider's path
    /// (`spx`) and the ML-DSA-65 key that verifies it (`pqv`).
    public var realityPublicKey: String?
    public var realityShortID: String?
    public var realitySpiderX: String?
    public var realityMLDSA65Verify: String?
    /// The link asked for the server's certificate not to be checked (`allowInsecure=1`). The relay
    /// checks it all the same (Xray has no such switch any more): a server whose certificate does
    /// not check needs `pcs`, its certificate's SHA-256.
    public var askedInsecure: Bool

    public init(scheme: Scheme, host: String, port: Int, name: String = "", userID: String? = nil, password: String? = nil,
                method: String? = nil, flow: String? = nil, encryption: String? = nil, transport: Transport = .tcp,
                path: String? = nil, hostHeader: String? = nil, serviceName: String? = nil, authority: String? = nil,
                grpcMultiMode: Bool = false, xhttpMode: String? = nil, tcpHTTPHeader: Bool = false,
                security: Security = .none, serverName: String? = nil, fingerprint: String? = nil, alpn: [String] = [],
                pinnedCertificateSHA256: String? = nil, verifyCertificateByName: String? = nil,
                realityPublicKey: String? = nil, realityShortID: String? = nil, realitySpiderX: String? = nil,
                realityMLDSA65Verify: String? = nil, askedInsecure: Bool = false) {
        self.scheme = scheme
        self.host = host
        self.port = port
        self.name = name
        self.userID = userID
        self.password = password
        self.method = method
        self.flow = flow
        self.encryption = encryption
        self.transport = transport
        self.path = path
        self.hostHeader = hostHeader
        self.serviceName = serviceName
        self.authority = authority
        self.grpcMultiMode = grpcMultiMode
        self.xhttpMode = xhttpMode
        self.tcpHTTPHeader = tcpHTTPHeader
        self.security = security
        self.serverName = serverName
        self.fingerprint = fingerprint
        self.alpn = alpn
        self.pinnedCertificateSHA256 = pinnedCertificateSHA256
        self.verifyCertificateByName = verifyCertificateByName
        self.realityPublicKey = realityPublicKey
        self.realityShortID = realityShortID
        self.realitySpiderX = realitySpiderX
        self.realityMLDSA65Verify = realityMLDSA65Verify
        self.askedInsecure = askedInsecure
    }

    /// "host:port", an IPv6 host in brackets.
    public var address: String {
        (host.contains(":") ? "[\(host)]" : host) + ":\(port)"
    }

    /// What may be shown and logged: the protocol and the server, never the id or the password.
    public var redacted: String { "\(scheme.displayName) \(address)" }

    /// What makes two links the same account on the same server: the protocol, the server and the
    /// user's id or password. Holds the secret: for comparing only, never shown or logged.
    public var identity: String {
        [scheme.rawValue, host.lowercased(), String(port), userID ?? password ?? ""].joined(separator: "\u{0}")
    }

    /// At most this many characters in a link (a VMess link's JSON, a REALITY key with ML-DSA).
    public static let maximumLength = 8192

    /// The prefixes of the links read here.
    public static let prefixes = ["vless://", "vmess://", "trojan://", "ss://"]

    /// Whether `text` is written as a share link (one of `prefixes`, in any case) — what the
    /// proxy fields read as a link, and report a link's problems for, rather than a proxy address.
    public static func looksLikeLink(_ text: String) -> Bool {
        let lowered = text.trimmingCharacters(in: junk).lowercased()
        return prefixes.contains { lowered.hasPrefix($0) }
    }

    static let junk = CharacterSet.whitespacesAndNewlines
        .union(.controlCharacters)
        .union(CharacterSet(charactersIn: "\u{FEFF}\u{200B}\u{200C}\u{200D}\u{2060}"))

    /// The link as stored: without the spaces and invisible characters a paste brings around it.
    public static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: junk)
    }

    /// A link as it may be shown where it could not be read, or where its whole text should not
    /// be: its scheme and server, never its id, password or the base64 that holds them.
    public static func masked(_ text: String) -> String {
        let link = trimmed(text)
        guard let separator = link.range(of: "://") else { return "…" }
        let scheme = String(link[..<separator.lowerBound].prefix(8))
        var body = link[separator.upperBound...]
        if let hash = body.firstIndex(of: "#") { body = body[..<hash] }
        if let mark = body.firstIndex(of: "?") { body = body[..<mark] }
        guard let at = body.lastIndex(of: "@") else { return scheme + "://…" }
        return scheme + "://…@" + String(body[body.index(after: at)...].prefix(80))
    }

    /// Where the secret is in a link as it was typed or pasted (the first line that holds one), for
    /// a field to show it as dots: the id or password before the server, or the whole body of a
    /// form that is base64 (VMess, Shadowsocks's legacy one). Nil without a link.
    public static func secretRange(in text: String) -> Range<String.Index>? {
        guard let separator = text.range(of: "://") else { return nil }
        let scheme = text[..<separator.lowerBound].lowercased()
        let start = separator.upperBound
        var end = text[start...].firstIndex(where: { $0 == "#" || $0.isNewline || $0.isWhitespace }) ?? text.endIndex
        guard start < end else { return nil }
        if scheme.hasSuffix("vmess") { return start..<end }
        if let mark = text[start..<end].firstIndex(of: "?") { end = mark }
        if let at = text[start..<end].lastIndex(of: "@") { return start < at ? start..<at : nil }
        return start..<end
    }

    // MARK: Reading

    public static func parse(_ raw: String) throws -> ShareLink {
        let text = trimmed(raw)
        guard !text.isEmpty else { throw ShareLinkError.empty }
        guard text.count <= maximumLength else { throw ShareLinkError.tooLong }
        guard !text.unicodeScalars.contains(where: { junk.contains($0) }) else { throw ShareLinkError.containsWhitespace }
        guard let separator = text.range(of: "://") else { throw ShareLinkError.unsupportedScheme("") }
        let schemeText = text[..<separator.lowerBound].lowercased()
        var body = String(text[separator.upperBound...])
        var name = ""
        if let hash = body.firstIndex(of: "#") {
            let fragment = String(body[body.index(after: hash)...])
            name = cleanName(fragment.removingPercentEncoding ?? fragment)
            body = String(body[..<hash])
        }
        switch schemeText {
        case "vless": return try readURLForm(.vless, body: body, name: name)
        case "trojan": return try readURLForm(.trojan, body: body, name: name)
        case "ss": return try readShadowsocks(body: body, name: name)
        case "vmess": return try readVMess(body: body, name: name)
        default: throw ShareLinkError.unsupportedScheme(String(schemeText.prefix(16)))
        }
    }

    /// One line, at most 64 characters, without the spaces around it.
    static func cleanName(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let printable = String(line.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
        return String(printable.trimmingCharacters(in: .whitespaces).prefix(64))
    }

    /// `userinfo@host:port[/][?query]`: the parts of a VLESS, Trojan or SIP002 Shadowsocks link.
    private struct URLParts {
        var userInfo: String?
        var host: String
        var port: Int
        var query: [String: String]
    }

    private static func urlParts(_ body: String) throws -> URLParts {
        var rest = body
        var query: [String: String] = [:]
        if let mark = rest.firstIndex(of: "?") {
            query = try readQuery(String(rest[rest.index(after: mark)...]))
            rest = String(rest[..<mark])
        }
        // SIP002 allows a "/" before the query; a path is meaningless anywhere else.
        if rest.hasSuffix("/") { rest.removeLast() }
        var userInfo: String?
        if let at = rest.lastIndex(of: "@") {
            userInfo = String(rest[..<at])
            rest = String(rest[rest.index(after: at)...])
        }
        guard !rest.contains("/") else { throw ShareLinkError.hasPath }
        let (host, port) = try hostAndPort(rest)
        return URLParts(userInfo: userInfo, host: host, port: port, query: query)
    }

    static func hostAndPort(_ text: String) throws -> (String, Int) {
        var host: String
        var portText: String
        if text.hasPrefix("[") {
            guard let close = text.firstIndex(of: "]") else { throw ShareLinkError.invalidHost(String(text.prefix(64))) }
            host = String(text[text.index(after: text.startIndex)..<close])
            let after = text[text.index(after: close)...]
            guard after.hasPrefix(":") else { throw ShareLinkError.missingPort }
            portText = String(after.dropFirst())
        } else {
            guard let colon = text.lastIndex(of: ":") else { throw ShareLinkError.missingPort }
            host = String(text[..<colon])
            portText = String(text[text.index(after: colon)...])
            // An IPv6 address must be in brackets: "::1:443" cannot be told apart.
            guard !host.contains(":") else { throw ShareLinkError.invalidHost(String(host.prefix(64))) }
        }
        host = host.removingPercentEncoding ?? host
        guard ProxySettings.isValidHost(host) else { throw ShareLinkError.invalidHost(String(host.prefix(64))) }
        guard let port = portNumber(portText) else { throw ShareLinkError.invalidPort(String(portText.prefix(16))) }
        return (host, port)
    }

    static func portNumber(_ text: String) -> Int? {
        guard (1...5).contains(text.count), text.allSatisfy({ $0.isASCII && $0.isNumber }),
              let value = Int(text), (1...65535).contains(value) else { return nil }
        return value
    }

    /// `a=1&b=2`, each name and value percent-decoded ("+" stays itself: it is a character of a
    /// base64 key, never a space here). The first of a name given twice is the one read; names are
    /// compared in any case.
    static func readQuery(_ text: String) throws -> [String: String] {
        var query: [String: String] = [:]
        for pair in text.split(separator: "&", omittingEmptySubsequences: true) {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let rawName = String(parts[0])
            let rawValue = parts.count > 1 ? String(parts[1]) : ""
            guard let name = rawName.removingPercentEncoding, let value = rawValue.removingPercentEncoding else {
                throw ShareLinkError.invalidParameter(name: String(rawName.prefix(32)))
            }
            let key = name.lowercased()
            if query[key] == nil { query[key] = value }
        }
        return query
    }

    private static func readURLForm(_ scheme: Scheme, body: String, name: String) throws -> ShareLink {
        let parts = try urlParts(body)
        guard let rawUser = parts.userInfo, !rawUser.isEmpty else { throw ShareLinkError.missingCredentials }
        guard let user = rawUser.removingPercentEncoding, !user.isEmpty else { throw ShareLinkError.missingCredentials }
        var link = ShareLink(scheme: scheme, host: parts.host, port: parts.port, name: name)
        let query = parts.query
        switch scheme {
        case .vless:
            guard isUserID(user) else { throw ShareLinkError.invalidUserID }
            link.userID = user
            link.encryption = try vlessEncryption(query["encryption"])
            link.flow = try flow(query["flow"])
        case .trojan:
            guard isPassword(user) else { throw ShareLinkError.invalidPassword }
            link.password = user
            // Read to be refused: a flow is VLESS's alone (`validate`).
            link.flow = try flow(query["flow"])
        default:
            break
        }
        // Trojan is TLS unless the link says otherwise; VLESS has none unless it says one.
        let defaultSecurity: Security = scheme == .trojan ? .tls : .none
        try applyStream(query: query, to: &link, defaultSecurity: defaultSecurity)
        try validate(link)
        return link
    }

    /// The transport and security parameters, the same for VLESS, Trojan and (from its JSON) VMess.
    static func applyStream(query: [String: String], to link: inout ShareLink, defaultSecurity: Security) throws {
        link.transport = try transport(query["type"] ?? query["net"])
        link.security = try security(query["security"], default: defaultSecurity)
        let path = nonEmpty(query["path"])
        let host = nonEmpty(query["host"])
        switch link.transport {
        case .tcp:
            switch (query["headertype"] ?? "none").lowercased() {
            case "", "none": break
            case "http":
                link.tcpHTTPHeader = true
                link.path = path
                link.hostHeader = host
            case let other: throw ShareLinkError.unsupportedParameter(name: "headerType", value: String(other.prefix(32)))
            }
        case .ws, .httpupgrade:
            link.path = path
            link.hostHeader = host
        case .xhttp:
            link.path = path
            link.hostHeader = host
            let mode = (query["mode"] ?? "auto").lowercased()
            guard ["", "auto", "packet-up", "stream-up", "stream-one"].contains(mode) else {
                throw ShareLinkError.unsupportedParameter(name: "mode", value: String(mode.prefix(32)))
            }
            link.xhttpMode = mode.isEmpty ? "auto" : mode
        case .grpc:
            link.serviceName = nonEmpty(query["servicename"]) ?? path
            link.authority = nonEmpty(query["authority"])
            let mode = (query["mode"] ?? "gun").lowercased()
            guard ["", "gun", "multi"].contains(mode) else {
                throw ShareLinkError.unsupportedParameter(name: "mode", value: String(mode.prefix(32)))
            }
            link.grpcMultiMode = mode == "multi"
        }
        switch link.security {
        case .none:
            break
        case .tls, .reality:
            link.serverName = nonEmpty(query["sni"]) ?? nonEmpty(query["peer"])
            link.fingerprint = try fingerprint(query["fp"])
            link.alpn = try alpn(query["alpn"])
            if link.security == .tls {
                link.pinnedCertificateSHA256 = try pinnedCertificate(query["pcs"])
                link.verifyCertificateByName = try names(query["vcn"])
                let insecure = (query["allowinsecure"] ?? query["insecure"] ?? "0").lowercased()
                link.askedInsecure = insecure == "1" || insecure == "true"
            } else {
                link.realityPublicKey = query["pbk"]
                link.realityShortID = nonEmpty(query["sid"])
                link.realitySpiderX = nonEmpty(query["spx"])
                link.realityMLDSA65Verify = nonEmpty(query["pqv"])
            }
        }
    }

    // MARK: Shadowsocks

    private static func readShadowsocks(body: String, name: String) throws -> ShareLink {
        var link: ShareLink
        let beforeQuery = body.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        if beforeQuery.contains("@") {
            // SIP002: ss://userinfo@host:port[/][?plugin=…]
            let parts = try urlParts(body)
            guard let userInfo = parts.userInfo, !userInfo.isEmpty else { throw ShareLinkError.missingCredentials }
            if let plugin = nonEmpty(parts.query["plugin"]) {
                throw ShareLinkError.shadowsocksPlugin(pluginName(plugin))
            }
            let (method, password) = try shadowsocksCredentials(userInfo)
            link = ShareLink(scheme: .shadowsocks, host: parts.host, port: parts.port, name: name)
            link.method = method
            link.password = password
            // Shadowsocks is TCP and UDP to the server itself: a transport named is one it has not.
            link.transport = try transport(parts.query["type"])
        } else {
            // The legacy form: ss://base64(method:password@host:port)
            guard !beforeQuery.isEmpty, let decoded = base64Text(beforeQuery) else { throw ShareLinkError.invalidBase64 }
            guard let at = decoded.lastIndex(of: "@") else { throw ShareLinkError.missingCredentials }
            let credentials = String(decoded[..<at])
            let (host, port) = try hostAndPort(String(decoded[decoded.index(after: at)...]))
            guard let colon = credentials.firstIndex(of: ":") else { throw ShareLinkError.missingCredentials }
            link = ShareLink(scheme: .shadowsocks, host: host, port: port, name: name)
            link.method = String(credentials[..<colon]).lowercased()
            link.password = String(credentials[credentials.index(after: colon)...])
            if let mark = body.firstIndex(of: "?") {
                let query = try readQuery(String(body[body.index(after: mark)...]))
                if let plugin = nonEmpty(query["plugin"]) {
                    throw ShareLinkError.shadowsocksPlugin(pluginName(plugin))
                }
            }
        }
        try validate(link)
        return link
    }

    /// The plugin's program, from `plugin=obfs-local;obfs=http;…`.
    static func pluginName(_ plugin: String) -> String {
        String((plugin.split(separator: ";").first.map(String.init) ?? plugin).prefix(32))
    }

    /// SIP002's userinfo: `method:password` percent-encoded (required for the 2022 ciphers), or
    /// base64url of it (the older ciphers).
    static func shadowsocksCredentials(_ userInfo: String) throws -> (String, String) {
        var plain: String?
        if let decoded = userInfo.removingPercentEncoding, decoded.contains(":") {
            plain = decoded
        } else if let decoded = base64Text(userInfo.removingPercentEncoding ?? userInfo), decoded.contains(":") {
            plain = decoded
        }
        guard let plain, let colon = plain.firstIndex(of: ":") else { throw ShareLinkError.missingCredentials }
        let method = String(plain[..<colon]).lowercased()
        let password = String(plain[plain.index(after: colon)...])
        return (method, password)
    }

    /// Shadowsocks ciphers Xray has, by the names links use.
    static let shadowsocksMethods: [String: String] = [
        "aes-128-gcm": "aes-128-gcm",
        "aes-256-gcm": "aes-256-gcm",
        "chacha20-poly1305": "chacha20-poly1305",
        "chacha20-ietf-poly1305": "chacha20-poly1305",
        "xchacha20-poly1305": "xchacha20-poly1305",
        "xchacha20-ietf-poly1305": "xchacha20-poly1305",
        "2022-blake3-aes-128-gcm": "2022-blake3-aes-128-gcm",
        "2022-blake3-aes-256-gcm": "2022-blake3-aes-256-gcm",
        "2022-blake3-chacha20-poly1305": "2022-blake3-chacha20-poly1305",
    ]

    // MARK: VMess

    /// V2RayN's form: `vmess://` and base64 of a JSON object (`v`, `ps`, `add`, `port`, `id`, `aid`,
    /// `scy`, `net`, `type`, `host`, `path`, `tls`, `sni`, `alpn`, `fp`).
    private static func readVMess(body: String, name: String) throws -> ShareLink {
        guard let text = base64Text(body) else { throw ShareLinkError.invalidBase64 }
        guard let data = text.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw ShareLinkError.invalidVMessJSON
        }
        func string(_ key: String) -> String? {
            if let value = object[key] as? String { return value }
            if let value = object[key] as? NSNumber { return value.stringValue }
            return nil
        }
        guard let address = nonEmpty(string("add")) else { throw ShareLinkError.invalidHost("") }
        let bracketed = address.contains(":") && !address.hasPrefix("[") ? "[\(address)]" : address
        let (host, port) = try hostAndPort(bracketed + ":" + (string("port") ?? ""))
        let ps = cleanName(string("ps") ?? "")
        var link = ShareLink(scheme: .vmess, host: host, port: port, name: ps.isEmpty ? name : ps)
        guard let id = string("id"), isUserID(id) else { throw ShareLinkError.invalidUserID }
        link.userID = id
        let alterID = Int(string("aid") ?? "0") ?? -1
        guard alterID == 0 else { throw ShareLinkError.vmessAlterID }
        let cipher = (nonEmpty(string("scy")) ?? "auto").lowercased()
        guard ["auto", "aes-128-gcm", "chacha20-poly1305", "none", "zero"].contains(cipher) else {
            throw ShareLinkError.unsupportedCipher(String(cipher.prefix(32)))
        }
        link.method = cipher
        var query: [String: String] = [:]
        query["type"] = nonEmpty(string("net")) ?? "tcp"
        let tls = (string("tls") ?? "").lowercased()
        query["security"] = tls.isEmpty ? "none" : tls
        for key in ["host", "path", "sni", "alpn", "fp", "pcs", "vcn", "allowInsecure", "authority"] {
            if let value = string(key) { query[key.lowercased()] = value }
        }
        // `type`: RAW's header ("none", "http"), gRPC's mode ("gun", "multi"), XHTTP's mode.
        let headerOrMode = string("type") ?? ""
        switch query["type"]?.lowercased() {
        case "grpc", "xhttp", "splithttp": query["mode"] = headerOrMode
        default: query["headertype"] = headerOrMode
        }
        if query["type"]?.lowercased() == "grpc" { query["servicename"] = string("path") }
        try applyStream(query: query, to: &link, defaultSecurity: .none)
        guard link.security != .reality else { throw ShareLinkError.unsupportedSecurity("reality") }
        try validate(link)
        return link
    }

    // MARK: Values

    static func nonEmpty(_ text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        return text
    }

    /// Base64 in either alphabet, padded or not, with the line breaks some providers wrap it in.
    static func base64Text(_ text: String) -> String? {
        var cleaned = text.filter { !$0.isWhitespace }
            .replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        guard !cleaned.isEmpty, cleaned.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "+/=".contains($0)) }) else {
            return nil
        }
        cleaned = cleaned.replacingOccurrences(of: "=", with: "")
        let remainder = cleaned.count % 4
        if remainder == 1 { return nil }
        if remainder > 0 { cleaned += String(repeating: "=", count: 4 - remainder) }
        guard let data = Data(base64Encoded: cleaned), let decoded = String(data: data, encoding: .utf8) else { return nil }
        return decoded
    }

    static func base64Bytes(_ text: String) -> Int? {
        guard let data = base64Data(text) else { return nil }
        return data.count
    }

    static func base64Data(_ text: String) -> Data? {
        var cleaned = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        guard !cleaned.isEmpty, cleaned.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "+/=".contains($0)) }) else {
            return nil
        }
        cleaned = cleaned.replacingOccurrences(of: "=", with: "")
        let remainder = cleaned.count % 4
        if remainder == 1 { return nil }
        if remainder > 0 { cleaned += String(repeating: "=", count: 4 - remainder) }
        return Data(base64Encoded: cleaned)
    }

    /// A UUID, or the 1–30 printable characters Xray maps to one.
    static func isUserID(_ text: String) -> Bool {
        if isUUID(text) { return true }
        return (1...30).contains(text.count) && text.unicodeScalars.allSatisfy { $0.value > 0x20 && $0.value < 0x7F }
    }

    static func isUUID(_ text: String) -> Bool {
        let groups = text.split(separator: "-", omittingEmptySubsequences: false)
        guard groups.count == 5, groups.map(\.count) == [8, 4, 4, 4, 12] else { return false }
        return groups.allSatisfy { $0.allSatisfy { $0.isHexDigit && $0.isASCII } }
    }

    /// 1–256 characters, none of them a control character.
    static func isPassword(_ text: String) -> Bool {
        (1...256).contains(text.count) && !text.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    static func transport(_ value: String?) throws -> Transport {
        let text = (value ?? "tcp").lowercased()
        switch text {
        case "", "tcp", "raw": return .tcp
        case "ws", "websocket": return .ws
        case "grpc", "gun": return .grpc
        case "httpupgrade": return .httpupgrade
        case "xhttp", "splithttp": return .xhttp
        case "http", "h2", "h3", "quic": throw ShareLinkError.removedTransport(text)
        default: throw ShareLinkError.unsupportedTransport(String(text.prefix(32)))
        }
    }

    static func security(_ value: String?, default fallback: Security) throws -> Security {
        guard let value, !value.isEmpty else { return fallback }
        switch value.lowercased() {
        case "none": return .none
        case "tls": return .tls
        case "reality": return .reality
        case let other: throw ShareLinkError.unsupportedSecurity(String(other.prefix(32)))
        }
    }

    static func flow(_ value: String?) throws -> String? {
        guard let value = nonEmpty(value) else { return nil }
        let lowered = value.lowercased()
        guard ["xtls-rprx-vision", "xtls-rprx-vision-udp443"].contains(lowered) else {
            throw ShareLinkError.unsupportedFlow(String(value.prefix(32)))
        }
        return lowered
    }

    static func vlessEncryption(_ value: String?) throws -> String {
        guard let value = nonEmpty(value), value.lowercased() != "none" else { return "none" }
        // VLESS Encryption's client string: "mlkem768x25519plus.<mode>.<rtt>…<keys>".
        let allowed = value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }
        guard value.lowercased().hasPrefix("mlkem768x25519plus."), allowed, value.count <= 4096 else {
            throw ShareLinkError.unsupportedEncryption(String(value.prefix(32)))
        }
        return value
    }

    static let fingerprints: Set<String> = ["chrome", "firefox", "safari", "ios", "android", "edge", "360", "qq",
                                            "random", "randomized", "randomizednoalpn"]

    static func fingerprint(_ value: String?) throws -> String? {
        guard let value = nonEmpty(value) else { return nil }
        let lowered = value.lowercased()
        guard fingerprints.contains(lowered) else { throw ShareLinkError.unsupportedParameter(name: "fp", value: String(value.prefix(32))) }
        return lowered
    }

    static func alpn(_ value: String?) throws -> [String] {
        guard let value = nonEmpty(value) else { return [] }
        let items = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        for item in items {
            guard item.count <= 32, item.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "./-".contains($0)) }) else {
                throw ShareLinkError.unsupportedParameter(name: "alpn", value: String(item.prefix(32)))
            }
        }
        return items
    }

    static func pinnedCertificate(_ value: String?) throws -> String? {
        guard let value = nonEmpty(value) else { return nil }
        for item in value.split(separator: ",") {
            let hex = item.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ":", with: "")
            guard hex.count == 64, hex.allSatisfy({ $0.isHexDigit && $0.isASCII }) else { throw ShareLinkError.invalidPinnedCertificate }
        }
        return value
    }

    static func names(_ value: String?) throws -> String? {
        guard let value = nonEmpty(value) else { return nil }
        for item in value.split(separator: ",") {
            let name = item.trimmingCharacters(in: .whitespaces)
            guard ProxySettings.isValidHost(name) || (name.hasPrefix("*.") && ProxySettings.isValidHost(String(name.dropFirst(2)))) else {
                throw ShareLinkError.unsupportedParameter(name: "vcn", value: String(name.prefix(32)))
            }
        }
        return value
    }

    /// A path for a request: starts with "/", printable, at most 2048 characters.
    static func isRequestPath(_ text: String) -> Bool {
        text.hasPrefix("/") && text.count <= 2048 && text.unicodeScalars.allSatisfy { $0.value > 0x20 && $0.value < 0x7F }
    }

    // MARK: The whole link

    /// What no single value shows: the combinations the relay refuses, and each value the relay is
    /// given, checked once more however it was read.
    static func validate(_ link: ShareLink) throws {
        guard ProxySettings.isValidHost(link.host) else { throw ShareLinkError.invalidHost(String(link.host.prefix(64))) }
        guard (1...65535).contains(link.port) else { throw ShareLinkError.invalidPort(String(link.port)) }
        switch link.scheme {
        case .vless, .vmess:
            guard let id = link.userID, isUserID(id) else { throw ShareLinkError.invalidUserID }
        case .trojan:
            guard let password = link.password, isPassword(password) else { throw ShareLinkError.invalidPassword }
        case .shadowsocks:
            guard let method = link.method, let canonical = shadowsocksMethods[method] else {
                throw ShareLinkError.unsupportedCipher(String((link.method ?? "").prefix(32)))
            }
            guard let password = link.password, isPassword(password) else { throw ShareLinkError.invalidPassword }
            if canonical.hasPrefix("2022-") {
                // The key, base64: 16 bytes for AES-128, 32 for the others; "iPSK:uPSK" for a relay.
                let size = canonical == "2022-blake3-aes-128-gcm" ? 16 : 32
                for part in password.split(separator: ":", omittingEmptySubsequences: false) {
                    guard base64Bytes(String(part)) == size else { throw ShareLinkError.invalidShadowsocksKey(bytes: size) }
                }
            }
        }
        if let flow = link.flow {
            guard link.scheme == .vless else { throw ShareLinkError.unsupportedFlow(flow) }
            guard link.transport == .tcp, link.security != .none else { throw ShareLinkError.visionNeedsTLS }
        }
        if link.security == .reality {
            guard link.scheme == .vless || link.scheme == .trojan else { throw ShareLinkError.unsupportedSecurity("reality") }
            guard let key = link.realityPublicKey, !key.isEmpty else { throw ShareLinkError.missingRealityKey }
            guard key.count == 43, base64Bytes(key) == 32 else { throw ShareLinkError.invalidRealityKey }
            guard let serverName = link.serverName, ProxySettings.isValidHost(serverName) else { throw ShareLinkError.missingServerName }
            if let shortID = link.realityShortID {
                guard shortID.count <= 16, shortID.count % 2 == 0, shortID.allSatisfy({ $0.isHexDigit && $0.isASCII }) else {
                    throw ShareLinkError.invalidShortID
                }
            }
            if let spider = link.realitySpiderX, !isRequestPath(spider) {
                throw ShareLinkError.unsupportedParameter(name: "spx", value: String(spider.prefix(32)))
            }
            if let verify = link.realityMLDSA65Verify {
                guard verify.count <= 4096, base64Data(verify) != nil else {
                    throw ShareLinkError.unsupportedParameter(name: "pqv", value: String(verify.prefix(16)))
                }
            }
        }
        if link.security == .tls, let serverName = link.serverName, !ProxySettings.isValidHost(serverName) {
            throw ShareLinkError.unsupportedParameter(name: "sni", value: String(serverName.prefix(32)))
        }
        if let path = link.path, !isRequestPath(path) {
            throw ShareLinkError.unsupportedParameter(name: "path", value: String(path.prefix(32)))
        }
        if let header = link.hostHeader {
            // One name, or several separated by commas (RAW's HTTP header picks among them).
            for name in header.split(separator: ",") {
                let trimmedName = name.trimmingCharacters(in: .whitespaces)
                guard ProxySettings.isValidHost(trimmedName) else {
                    throw ShareLinkError.unsupportedParameter(name: "host", value: String(header.prefix(32)))
                }
            }
        }
        if let authority = link.authority, !ProxySettings.isValidHost(authority) {
            throw ShareLinkError.unsupportedParameter(name: "authority", value: String(authority.prefix(32)))
        }
        if let service = link.serviceName {
            let allowed = service.count <= 512 && service.unicodeScalars.allSatisfy { $0.value > 0x20 && $0.value < 0x7F }
            guard allowed else { throw ShareLinkError.unsupportedParameter(name: "serviceName", value: String(service.prefix(32))) }
        }
        if link.scheme == .shadowsocks, link.transport != .tcp || link.security != .none {
            throw ShareLinkError.unsupportedTransport(link.transport.rawValue)
        }
    }
}

/// Why a text is not a share link the relay can use. `message` is the logs' English; the app says
/// each in the person's language (`translatedErrorText`). None of them carries the link's secret.
public enum ShareLinkError: Error, Equatable, Sendable, CustomStringConvertible {
    case empty
    case tooLong
    case containsWhitespace
    /// Not vless, vmess, trojan or ss.
    case unsupportedScheme(String)
    /// `scheme://host:port/path`: a link's server has no path.
    case hasPath
    /// No id or password before the server.
    case missingCredentials
    case invalidUserID
    case invalidPassword
    case invalidHost(String)
    case missingPort
    case invalidPort(String)
    case invalidParameter(name: String)
    /// A transport Xray has removed: HTTP/2 ("http", "h2"), HTTP/3, QUIC.
    case removedTransport(String)
    case unsupportedTransport(String)
    case unsupportedSecurity(String)
    case unsupportedFlow(String)
    /// xtls-rprx-vision needs RAW (TCP) with TLS or REALITY.
    case visionNeedsTLS
    case unsupportedEncryption(String)
    case unsupportedCipher(String)
    case invalidShadowsocksKey(bytes: Int)
    /// SIP003 plugins (obfs-local, v2ray-plugin, …) are programs of their own: the relay has none.
    case shadowsocksPlugin(String)
    case invalidBase64
    case invalidVMessJSON
    /// VMess with an alterId other than 0: the old MD5 authentication, which Xray no longer has.
    case vmessAlterID
    case missingRealityKey
    case invalidRealityKey
    case invalidShortID
    /// REALITY needs the server name (`sni`) the server expects.
    case missingServerName
    case invalidPinnedCertificate
    case unsupportedParameter(name: String, value: String)

    public var description: String {
        switch self {
        case .empty: return "the link is empty"
        case .tooLong: return "the link is longer than \(ShareLink.maximumLength) characters"
        case .containsWhitespace: return "the link contains spaces or line breaks"
        case .unsupportedScheme(let scheme):
            return "“\(scheme)” links are not supported (vless://, vmess://, trojan:// and ss:// are)"
        case .hasPath: return "the server's address in the link has a path after it"
        case .missingCredentials: return "the link has no id or password before the server's address"
        case .invalidUserID: return "the link's id is neither a UUID nor 1–30 characters"
        case .invalidPassword: return "the link's password is empty, too long or has control characters"
        case .invalidHost(let host): return "“\(host)” is not a valid server name or IP address"
        case .missingPort: return "the link has no port after the server"
        case .invalidPort(let text): return "“\(text)” is not a port number (1–65535)"
        case .invalidParameter(let name): return "the link's parameter “\(name)” is not percent-encoded correctly"
        case .removedTransport(let name):
            return "the transport “\(name)” is no longer in Xray; ask the provider for an XHTTP, WebSocket, gRPC or TCP link"
        case .unsupportedTransport(let name): return "the transport “\(name)” is not supported for this link"
        case .unsupportedSecurity(let name): return "the security “\(name)” is not supported for this link"
        case .unsupportedFlow(let name): return "the flow “\(name)” is not supported (xtls-rprx-vision is)"
        case .visionNeedsTLS: return "the flow xtls-rprx-vision needs TCP with TLS or REALITY"
        case .unsupportedEncryption(let name): return "the VLESS encryption “\(name)” is not supported"
        case .unsupportedCipher(let name): return "the cipher “\(name)” is not supported"
        case .invalidShadowsocksKey(let bytes): return "the Shadowsocks 2022 key must be base64 of \(bytes) bytes"
        case .shadowsocksPlugin(let name): return "Shadowsocks plugins (“\(name)”) are not supported"
        case .invalidBase64: return "the link's base64 does not decode"
        case .invalidVMessJSON: return "the VMess link does not hold a JSON object"
        case .vmessAlterID: return "VMess with an alterId other than 0 is not supported"
        case .missingRealityKey: return "the REALITY link has no public key (pbk)"
        case .invalidRealityKey: return "the REALITY public key (pbk) is not 32 bytes of base64"
        case .invalidShortID: return "the REALITY short id (sid) must be up to 16 hex digits, an even number of them"
        case .missingServerName: return "the REALITY link has no server name (sni)"
        case .invalidPinnedCertificate: return "the certificate's SHA-256 (pcs) must be 64 hex digits"
        case .unsupportedParameter(let name, let value): return "the link's “\(name)” value “\(value)” is not supported"
        }
    }
}

extension ShareLinkError: LocalizedError {
    public var errorDescription: String? { CoreErrorText.translate?(self) ?? description }
}
