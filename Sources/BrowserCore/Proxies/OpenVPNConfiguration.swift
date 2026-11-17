import Foundation

/// A proxy that is an OpenVPN connection (docs/OPENVPN.md): the `.ovpn` configuration as
/// imported, everything inline. Kept in `ProxySettings.openVPN`, in the profile's encrypted
/// settings and the encrypted proxy list; its user name and password (auth-user-pass) are the
/// proxy's `username` and `password`, kept as every proxy's are.
public struct OpenVPNSettings: Codable, Equatable, Sendable {
    /// The configuration, normalized by `OpenVPNConfiguration.parse` (Unix newlines, no file named).
    public var configuration: String

    public init(configuration: String) {
        self.configuration = configuration
    }

    /// The parsed configuration.
    public func parsed() throws -> OpenVPNConfiguration { try OpenVPNConfiguration.parse(configuration) }

    /// A short fingerprint of the configuration (FNV-1a of its text): what tells two connections
    /// to the same server apart in the proxy list.
    public var fingerprint: String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in configuration.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return String(hash, radix: 16)
    }
}

/// Why a configuration cannot be used. `description` is the logs' English; the app says it in the
/// person's language (`openvpn.problem.*`).
public enum OpenVPNConfigProblem: Error, Equatable, CustomStringConvertible {
    case empty
    case tooLarge
    case notText
    /// A line that cannot be read (an unterminated quote): its number.
    case malformed(line: Int)
    /// `<name>` without `</name>`.
    case unterminatedBlock(String)
    /// A directive Lumen does not know: refused rather than passed on unread.
    case unknown(directive: String, line: Int)
    /// A directive known and refused, with why.
    case unsupported(directive: String, reason: UnsupportedReason)
    /// A file named instead of given inline (`ca ca.crt`); `OpenVPNConfiguration.inlining` takes
    /// files from beside the `.ovpn` at import.
    case fileReference(directive: String, file: String)
    case missing(String)
    case noRemote
    case invalidRemote(String)
    case encryptedKey

    public enum UnsupportedReason: String, Equatable, Sendable {
        /// A server's configuration, not a client's.
        case server
        /// A tap (Ethernet) device: only tun (IP) is carried.
        case tap
        /// PKCS#12, PKCS#11, the system's certificate store, an external key: not in this build's
        /// OpenVPN (mbed TLS, no smart cards).
        case keyStore
        /// The static-key mode (`secret`): no TLS, deprecated by OpenVPN.
        case staticKey
        /// Through another proxy (`http-proxy`, `socks-proxy`): OpenVPN would connect elsewhere.
        case proxy
        /// A one-time code asked at each connection (`static-challenge`).
        case challenge
        /// A cipher this build's OpenVPN does not have (BF-CBC and the like).
        case cipher
        /// A device or interface of this Mac named (`dev-node`, `lladdr`, …).
        case device
    }

    public var description: String {
        switch self {
        case .empty: return "the configuration is empty"
        case .tooLarge: return "the configuration is larger than 256 KB"
        case .notText: return "the file is not a text configuration"
        case .malformed(let line): return "line \(line) cannot be read (an unterminated quote)"
        case .unterminatedBlock(let name): return "<\(name)> is not closed"
        case .unknown(let directive, let line): return "line \(line): the directive \(directive) is not one Lumen knows"
        case .unsupported(let directive, let reason): return "\(directive) is not supported (\(reason.rawValue))"
        case .fileReference(let directive, let file): return "\(directive) names the file \(file): its content must be inline"
        case .missing(let what): return "the configuration has no \(what)"
        case .noRemote: return "the configuration names no server (remote)"
        case .invalidRemote(let text): return "the server \(text) is not a host name or address with a port"
        case .encryptedKey: return "the private key is encrypted"
        }
    }
}

/// A `.ovpn` configuration as Lumen runs it (docs/OPENVPN.md): read once at import, refused as a
/// whole when anything in it is unknown or would do what a profile's tunnel may not.
///
/// What is kept passes to OpenVPN unchanged; what concerns this Mac's network (routes, DNS
/// scripts, the user to drop to, logs) is left out and said; the servers (`remote`, in order,
/// each with its transport) are the only way out of the tunnel, and Lumen reaches them itself
/// (`runtime`).
public struct OpenVPNConfiguration: Equatable, Sendable {
    public enum Transport: String, Equatable, Sendable {
        case udp, tcp
    }

    public struct Remote: Equatable, Sendable {
        public var host: String
        public var port: Int
        public var transport: Transport
        /// Directives that belong to this connection entry (`<connection>` blocks).
        public var directives: [[String]]

        public init(host: String, port: Int, transport: Transport, directives: [[String]] = []) {
            self.host = host
            self.port = port
            self.transport = transport
            self.directives = directives
        }
    }

    /// Something of the configuration left out or changed, said at import.
    public enum Notice: Equatable, Sendable {
        /// Routes, DNS changes, scripts, users, logs: what concerns this Mac's network or system,
        /// which a profile's tunnel never touches. The directive's name.
        case leftOut(String)
        /// `ns-cert-type server`, which this build's OpenVPN does not have, checked as
        /// `remote-cert-tls server` (the same check, by the certificate's extended key usage).
        case nsCertType
        /// A cipher this build's OpenVPN lacks, dropped from the list: the server must offer another.
        case cipherDropped(String)
        /// OpenSSL's own cipher-list syntax (`DEFAULT:@SECLEVEL=0`), meaningless to mbed TLS: left out.
        case openSSLCipherList
        /// The user name and password were in the file (`<auth-user-pass>`): taken into the proxy's
        /// fields, kept encrypted as every proxy's.
        case credentialsTaken
    }

    public var remotes: [Remote]
    public var remoteRandom: Bool
    /// The server asks for a user name and password (`auth-user-pass`).
    public var needsCredentials: Bool
    /// Directives kept, in order, outside the servers' entries: name first, then its arguments.
    public var directives: [[String]]
    public struct Block: Equatable, Sendable {
        public var name: String
        public var content: String
    }

    /// Inline blocks kept, by name, in order.
    public var blocks: [Block]
    public var notices: [Notice]
    /// Credentials found inline (`<auth-user-pass>`), for the proxy's fields.
    public var inlineUsername: String?
    public var inlinePassword: String?
    /// The configuration in normal form (what `OpenVPNSettings.configuration` keeps).
    public var normalized: String

    public static let maximumSize = 256 * 1024

    // MARK: What each directive is

    /// Passed to OpenVPN as written.
    static let kept: Set<String> = [
        "client", "pull", "tls-client", "nobind", "persist-key",
        "remote-random", "server-poll-timeout", "connect-retry", "connect-retry-max", "connect-timeout",
        "ca", "cert", "key", "extra-certs", "tls-auth", "tls-crypt", "tls-crypt-v2", "key-direction", "crl-verify",
        "cipher", "data-ciphers", "data-ciphers-fallback", "ncp-ciphers", "ncp-disable", "auth", "tls-cipher",
        "tls-ciphersuites", "tls-version-min", "tls-version-max", "tls-groups", "ecdh-curve", "tls-cert-profile",
        "remote-cert-tls", "remote-cert-ku", "remote-cert-eku", "verify-x509-name", "verify-hash", "peer-fingerprint",
        "auth-nocache", "auth-token-user", "comp-lzo", "compress", "allow-compression", "mssfix", "tun-mtu", "tun-mtu-extra",
        "link-mtu", "fragment", "keepalive", "ping", "ping-restart", "ping-exit", "ping-timer-rem", "reneg-sec", "reneg-bytes",
        "reneg-pkts", "tran-window", "hand-window", "tls-timeout", "replay-window", "mute-replay-warnings", "float",
        "explicit-exit-notify", "push-peer-info", "pull-filter", "sndbuf", "rcvbuf", "tcp-nodelay", "fast-io", "inactive",
        "session-timeout", "topology", "dhcp-option", "dns", "tls-exit", "mute", "single-session", "allow-pull-fqdn",
        "machine-readable-output", "opt-verify",
    ]

    /// Left out, and said: what would change this Mac (routes, DNS, scripts, privileges, logs,
    /// daemonizing) or what Lumen sets itself (verbosity, management, the device's node).
    static let leftOut: Set<String> = [
        "route", "route-ipv6", "route-gateway", "route-ipv6-gateway", "route-metric", "route-delay", "route-method",
        "route-noexec", "route-nopull", "route-pre-down", "max-routes", "redirect-gateway", "redirect-private",
        "block-outside-dns", "register-dns", "block-ipv6", "ip-win32", "dhcp-renew", "dhcp-release", "tap-sleep",
        "dhcp-pre-release", "win-sys", "service", "windows-driver", "allow-recursive-routing",
        "script-security", "up", "down", "up-delay", "up-restart", "down-pre", "route-up", "ipchange", "tls-verify",
        "learn-address", "client-connect", "client-disconnect", "auth-user-pass-verify", "dns-updown",
        "user", "group", "chroot", "cd", "daemon", "writepid", "log", "log-append", "status", "status-version",
        "syslog", "suppress-timestamps", "verb", "echo", "mlock", "nice", "persist-tun", "persist-local-ip",
        "persist-remote-ip", "resolv-retry", "lport", "bind", "ifconfig-noexec", "ifconfig-nowarn", "txqueuelen",
        "management", "management-hold", "management-query-passwords", "management-client", "management-signal",
        "management-forget-disconnect", "management-up-down", "management-log-cache", "management-client-auth",
        "auth-retry", "askpass", "auth-user-pass-optional", "setenv", "setenv-safe", "ignore-unknown-option",
        "engine", "providers", "mark", "bind-dev", "iproute", "disable-dco", "tun-ipv6", "allow-nonadmin", "dev-type",
        "block-local", "remote-random-hostname", "auth-token", "socket-flags", "multihome", "passtos",
        // Gone from OpenVPN 2.7 (one method left, cipher negotiation always on), or Linux's alone.
        "key-method", "ncp-disable", "mtu-disc", "mtu-test",
    ]

    /// Belong to a server's entry (`remote`), here or in `<connection>`.
    static let perRemote: Set<String> = ["remote", "proto", "port", "rport"]

    /// Refused, with why.
    static let refused: [String: OpenVPNConfigProblem.UnsupportedReason] = [
        "server": .server, "server-bridge": .server, "mode": .server, "tls-server": .server, "dh": .server,
        "client-config-dir": .server, "push": .server, "ifconfig-pool": .server, "duplicate-cn": .server,
        "ifconfig": .server, "ifconfig-ipv6": .server,
        "pkcs12": .keyStore, "pkcs11-providers": .keyStore, "pkcs11-id": .keyStore, "pkcs11-id-management": .keyStore,
        "cryptoapicert": .keyStore, "management-external-key": .keyStore, "management-external-cert": .keyStore,
        "secret": .staticKey,
        "http-proxy": .proxy, "http-proxy-option": .proxy, "http-proxy-user-pass": .proxy, "socks-proxy": .proxy,
        "socks-proxy-retry": .proxy, "http-proxy-retry": .proxy, "http-proxy-timeout": .proxy,
        "static-challenge": .challenge,
        "dev-node": .device, "lladdr": .device,
    ]

    /// Blocks that hold a file's content.
    static let fileBlocks: Set<String> = ["ca", "cert", "key", "extra-certs", "tls-auth", "tls-crypt", "tls-crypt-v2", "crl-verify",
                                          "auth-user-pass", "peer-fingerprint"]

    /// Ciphers this build's OpenVPN (mbed TLS 3.6) does not have.
    static let missingCiphers: Set<String> = ["BF-CBC", "BF-CFB", "BF-OFB", "CAST5-CBC", "CAST5-CFB", "CAST5-OFB",
                                              "DES-CBC", "DES-CFB", "DES-OFB", "DESX-CBC", "RC2-CBC", "RC2-40-CBC", "RC2-64-CBC",
                                              "IDEA-CBC", "SEED-CBC", "SEED-CFB", "SEED-OFB"]

    // MARK: Reading

    /// Reads `text` (a `.ovpn` file's content, its files already inline: `inlining`).
    public static func parse(_ text: String) throws -> OpenVPNConfiguration {
        guard text.utf8.count <= maximumSize else { throw OpenVPNConfigProblem.tooLarge }
        guard !text.unicodeScalars.contains(where: { $0.value == 0 }) else { throw OpenVPNConfigProblem.notText }
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        var state = Reading()
        var index = 0
        var inConnection: [[String]]?
        var connections: [[[String]]] = []
        while index < lines.count {
            let lineNumber = index + 1
            let line = lines[index].trimmingCharacters(in: .whitespaces)
            index += 1
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") { continue }
            if line.hasPrefix("<"), line.hasSuffix(">"), !line.hasPrefix("</") {
                let name = String(line.dropFirst().dropLast()).lowercased()
                if name == "connection" {
                    guard inConnection == nil else { throw OpenVPNConfigProblem.malformed(line: lineNumber) }
                    inConnection = []
                    continue
                }
                var content: [String] = []
                var closed = false
                while index < lines.count {
                    let inner = lines[index]
                    index += 1
                    if inner.trimmingCharacters(in: .whitespaces).lowercased() == "</\(name)>" {
                        closed = true
                        break
                    }
                    content.append(inner)
                }
                guard closed else { throw OpenVPNConfigProblem.unterminatedBlock(name) }
                try state.block(name, content: content.joined(separator: "\n"))
                continue
            }
            if line.lowercased() == "</connection>" {
                guard let entry = inConnection else { throw OpenVPNConfigProblem.malformed(line: lineNumber) }
                connections.append(entry)
                inConnection = nil
                continue
            }
            guard var words = tokens(line) else { throw OpenVPNConfigProblem.malformed(line: lineNumber) }
            guard !words.isEmpty else { continue }
            if words[0].hasPrefix("--") { words[0].removeFirst(2) }
            words[0] = words[0].lowercased()
            if inConnection != nil {
                inConnection!.append(words)
                continue
            }
            try state.directive(words, line: lineNumber)
        }
        if inConnection != nil { throw OpenVPNConfigProblem.unterminatedBlock("connection") }
        return try state.finish(connections: connections)
    }

    /// The tokens of one line as OpenVPN reads them: separated by blanks; "…" with backslash
    /// escapes and '…' literal group; a token that begins with # or ; begins a comment. Nil for an
    /// unterminated quote.
    static func tokens(_ line: String) -> [String]? {
        var result: [String] = []
        var current = ""
        var inToken = false
        var quote: Character?
        var escaped = false
        for character in line {
            if let open = quote {
                if escaped {
                    current.append(character)
                    escaped = false
                } else if open == "\"" && character == "\\" {
                    escaped = true
                } else if character == open {
                    quote = nil
                } else {
                    current.append(character)
                }
                continue
            }
            if character == " " || character == "\t" {
                if inToken {
                    result.append(current)
                    current = ""
                    inToken = false
                }
                continue
            }
            if !inToken && (character == "#" || character == ";") { break }
            inToken = true
            if character == "\"" || character == "'" {
                quote = character
            } else if character == "\\" {
                escaped = true
                continue
            } else if escaped {
                current.append(character)
                escaped = false
            } else {
                current.append(character)
            }
        }
        if quote != nil { return nil }
        if inToken { result.append(current) }
        return result
    }

    /// What reading has gathered so far.
    private struct Reading {
        var remotes: [(host: String, port: Int?, transport: Transport?)] = []
        var defaultProto: Transport = .udp
        var defaultPort = 1194
        var protoGiven = false
        var remoteRandom = false
        var needsCredentials = false
        var directives: [[String]] = []
        var blocks: [Block] = []
        var notices: [Notice] = []
        var inlineUsername: String?
        var inlinePassword: String?
        var hasClient = false
        var hasTLSClient = false
        var hasPull = false
        var referencedBlocks: Set<String> = []

        mutating func note(_ notice: Notice) {
            if !notices.contains(notice) { notices.append(notice) }
        }

        mutating func directive(_ words: [String], line: Int) throws {
            let name = words[0]
            if let reason = OpenVPNConfiguration.refused[name] {
                throw OpenVPNConfigProblem.unsupported(directive: name, reason: reason)
            }
            switch name {
            case "dev":
                let device = words.count > 1 ? words[1].lowercased() : ""
                guard device.hasPrefix("tun") else { throw OpenVPNConfigProblem.unsupported(directive: "dev \(device)", reason: .tap) }
                return
            case "dev-type":
                if words.count > 1, words[1].lowercased() != "tun" { throw OpenVPNConfigProblem.unsupported(directive: "dev-type", reason: .tap) }
                return
            case "proto":
                guard words.count > 1, let transport = Self.transport(words[1]) else {
                    throw OpenVPNConfigProblem.invalidRemote(words.joined(separator: " "))
                }
                defaultProto = transport
                protoGiven = true
                return
            case "port", "rport":
                guard words.count > 1, let port = Int(words[1]), (1...65_535).contains(port) else {
                    throw OpenVPNConfigProblem.invalidRemote(words.joined(separator: " "))
                }
                defaultPort = port
                return
            case "remote":
                remotes.append(try Self.remote(words))
                return
            case "remote-random":
                remoteRandom = true
            case "client":
                hasClient = true
            case "tls-client":
                hasTLSClient = true
            case "pull":
                hasPull = true
            case "auth-user-pass":
                needsCredentials = true
                // A file named holds them: not read here (only inline content is taken). The
                // person types them into the proxy's fields.
                if words.count > 1, words[1] != "[inline]" { note(.leftOut("auth-user-pass \(words[1])")) }
                return
            case "ns-cert-type":
                guard words.count > 1, words[1].lowercased() == "server" else {
                    throw OpenVPNConfigProblem.unsupported(directive: "ns-cert-type", reason: .server)
                }
                note(.nsCertType)
                directives.append(["remote-cert-tls", "server"])
                return
            case "cipher", "data-ciphers-fallback":
                guard words.count > 1 else { break }
                if OpenVPNConfiguration.missingCiphers.contains(words[1].uppercased()) {
                    note(.cipherDropped(words[1].uppercased()))
                    return
                }
            case "data-ciphers", "ncp-ciphers":
                guard words.count > 1 else { break }
                let ciphers = words[1].split(separator: ":").map(String.init)
                let kept = ciphers.filter { !OpenVPNConfiguration.missingCiphers.contains($0.uppercased()) }
                for dropped in ciphers where OpenVPNConfiguration.missingCiphers.contains(dropped.uppercased()) {
                    note(.cipherDropped(dropped.uppercased()))
                }
                guard !kept.isEmpty else { throw OpenVPNConfigProblem.unsupported(directive: name, reason: .cipher) }
                directives.append([name, kept.joined(separator: ":")])
                return
            case "tls-cipher":
                if words.count > 1, words[1].contains("@SECLEVEL") || words[1].uppercased().hasPrefix("DEFAULT") || words[1].contains("!") {
                    note(.openSSLCipherList)
                    return
                }
            default:
                break
            }
            if OpenVPNConfiguration.leftOut.contains(name) {
                note(.leftOut(name))
                return
            }
            guard OpenVPNConfiguration.kept.contains(name) else {
                throw OpenVPNConfigProblem.unknown(directive: name, line: line)
            }
            if name == "peer-fingerprint", words.count == 2, words[1].contains(":") {
                // One fingerprint given on the line itself.
                directives.append(words)
                return
            }
            if OpenVPNConfiguration.fileBlocks.contains(name) {
                // `ca file` or `tls-auth file 1`: the file must have come inline.
                guard words.count > 1 else { throw OpenVPNConfigProblem.missing(name) }
                guard words[1] == "[inline]" else { throw OpenVPNConfigProblem.fileReference(directive: name, file: words[1]) }
                referencedBlocks.insert(name)
                // `tls-auth [inline] 1`: the block, and its direction.
                if name == "tls-auth", words.count > 2 { directives.append(["key-direction", words[2]]) }
                return
            }
            directives.append(words)
        }

        mutating func block(_ name: String, content: String) throws {
            if let reason = OpenVPNConfiguration.refused[name] {
                throw OpenVPNConfigProblem.unsupported(directive: "<\(name)>", reason: reason)
            }
            if name == "auth-user-pass" {
                let lines = content.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                needsCredentials = true
                if lines.count >= 2 {
                    inlineUsername = lines[0]
                    inlinePassword = lines[1]
                    note(.credentialsTaken)
                } else if lines.count == 1 {
                    inlineUsername = lines[0]
                    note(.credentialsTaken)
                }
                return
            }
            guard OpenVPNConfiguration.fileBlocks.contains(name) else {
                throw OpenVPNConfigProblem.unknown(directive: "<\(name)>", line: 0)
            }
            if name == "key", content.contains("ENCRYPTED") { throw OpenVPNConfigProblem.encryptedKey }
            blocks.removeAll { $0.name == name }
            blocks.append(Block(name: name, content: content))
        }

        mutating func finish(connections: [[[String]]]) throws -> OpenVPNConfiguration {
            // The servers: `remote` lines (each with the proto and port given at the top level
            // unless it names its own), or the `<connection>` entries.
            var entries: [Remote] = remotes.map {
                Remote(host: $0.host, port: $0.port ?? defaultPort, transport: $0.transport ?? defaultProto)
            }
            for connection in connections {
                var proto = defaultProto
                var port = defaultPort
                var found: [(host: String, port: Int?, transport: Transport?)] = []
                var extra: [[String]] = []
                for words in connection {
                    let name = words[0]
                    switch name {
                    case "proto":
                        guard words.count > 1, let transport = Self.transport(words[1]) else {
                            throw OpenVPNConfigProblem.invalidRemote(words.joined(separator: " "))
                        }
                        proto = transport
                    case "port", "rport":
                        guard words.count > 1, let value = Int(words[1]), (1...65_535).contains(value) else {
                            throw OpenVPNConfigProblem.invalidRemote(words.joined(separator: " "))
                        }
                        port = value
                    case "remote":
                        found.append(try Self.remote(words))
                    default:
                        if let reason = OpenVPNConfiguration.refused[name] {
                            throw OpenVPNConfigProblem.unsupported(directive: name, reason: reason)
                        }
                        if OpenVPNConfiguration.leftOut.contains(name) {
                            note(.leftOut(name))
                        } else if OpenVPNConfiguration.kept.contains(name) && !OpenVPNConfiguration.fileBlocks.contains(name) {
                            extra.append(words)
                        } else {
                            throw OpenVPNConfigProblem.unknown(directive: name, line: 0)
                        }
                    }
                }
                for remote in found {
                    entries.append(Remote(host: remote.host, port: remote.port ?? port, transport: remote.transport ?? proto,
                                          directives: extra))
                }
            }
            guard !entries.isEmpty else { throw OpenVPNConfigProblem.noRemote }
            // A client that takes its address from the server: `client`, or what it stands for.
            guard hasClient || (hasTLSClient && hasPull) else { throw OpenVPNConfigProblem.missing("client") }
            guard blocks.contains(where: { $0.name == "ca" }) || directives.contains(where: { $0.first == "peer-fingerprint" })
                    || blocks.contains(where: { $0.name == "peer-fingerprint" }) else {
                throw OpenVPNConfigProblem.missing("ca")
            }
            // A certificate and its key come together, or neither (user name and password alone).
            let hasCert = blocks.contains { $0.name == "cert" }
            let hasKey = blocks.contains { $0.name == "key" }
            guard hasCert == hasKey else { throw OpenVPNConfigProblem.missing(hasCert ? "key" : "cert") }
            guard hasCert || needsCredentials else { throw OpenVPNConfigProblem.missing("cert") }
            // `[inline]` references need their block.
            for name in referencedBlocks where !blocks.contains(where: { $0.name == name }) {
                throw OpenVPNConfigProblem.missing("<\(name)>")
            }
            let configuration = OpenVPNConfiguration(
                remotes: entries, remoteRandom: remoteRandom, needsCredentials: needsCredentials,
                directives: directives.filter { !["client", "pull", "tls-client", "nobind", "remote-random"].contains($0[0]) },
                blocks: blocks, notices: notices, inlineUsername: inlineUsername, inlinePassword: inlinePassword,
                normalized: "")
            return configuration.withNormalForm()
        }

        static func transport(_ text: String) -> Transport? {
            switch text.lowercased() {
            case "udp", "udp4", "udp6": return .udp
            case "tcp", "tcp4", "tcp6", "tcp-client", "tcp4-client", "tcp6-client": return .tcp
            default: return nil
            }
        }

        /// `remote host [port] [proto]`: what it gives; nil where the defaults apply.
        static func remote(_ words: [String]) throws -> (host: String, port: Int?, transport: Transport?) {
            guard words.count >= 2, words.count <= 4 else { throw OpenVPNConfigProblem.invalidRemote(words.joined(separator: " ")) }
            let host = words[1]
            guard ProxySettings.isValidHost(host) else { throw OpenVPNConfigProblem.invalidRemote(host) }
            var port: Int?
            if words.count >= 3 {
                guard let value = Int(words[2]), (1...65_535).contains(value) else { throw OpenVPNConfigProblem.invalidRemote(words.joined(separator: " ")) }
                port = value
            }
            var transport: Transport?
            if words.count == 4 {
                guard let value = Self.transport(words[3]) else { throw OpenVPNConfigProblem.invalidRemote(words.joined(separator: " ")) }
                transport = value
            }
            return (host, port, transport)
        }
    }

    private init(remotes: [Remote], remoteRandom: Bool, needsCredentials: Bool, directives: [[String]],
                 blocks: [Block], notices: [Notice], inlineUsername: String?, inlinePassword: String?,
                 normalized: String) {
        self.remotes = remotes
        self.remoteRandom = remoteRandom
        self.needsCredentials = needsCredentials
        self.directives = directives
        self.blocks = blocks
        self.notices = notices
        self.inlineUsername = inlineUsername
        self.inlinePassword = inlinePassword
        self.normalized = normalized
    }

    // MARK: Writing

    /// Quotes a token for OpenVPN's configuration when it needs it.
    static func quote(_ token: String) -> String {
        guard token.isEmpty || token.contains(where: { $0 == " " || $0 == "\t" || $0 == "\"" || $0 == "\\" || $0 == "#" || $0 == ";" || $0 == "'" }) else {
            return token
        }
        return "\"" + token.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private static func line(_ words: [String]) -> String { words.map(quote).joined(separator: " ") }

    /// The configuration as kept: the directives, the servers as `<connection>` entries, the
    /// blocks — no credentials (they are the proxy's fields).
    private func withNormalForm() -> OpenVPNConfiguration {
        var result = self
        var text = ["client"]
        if remoteRandom { text.append("remote-random") }
        for words in directives { text.append(Self.line(words)) }
        if needsCredentials { text.append("auth-user-pass") }
        for remote in remotes {
            text.append("<connection>")
            text.append(Self.line(["remote", remote.host, String(remote.port), remote.transport.rawValue]))
            for words in remote.directives { text.append(Self.line(words)) }
            text.append("</connection>")
        }
        for block in blocks {
            text.append("<\(block.name)>")
            text.append(block.content.trimmingCharacters(in: .newlines))
            text.append("</\(block.name)>")
        }
        result.normalized = text.joined(separator: "\n") + "\n"
        return result
    }

    /// The configuration OpenVPN is given for one launch (docs/OPENVPN.md, "The configuration"):
    /// the kept directives and blocks; each server replaced by the loopback forwarder Lumen keeps
    /// for it (`forwarders`, by the server's index), so that OpenVPN — confined to loopback — has
    /// no other way out; the tun device is `tunnelProgram`; nothing of this Mac's network is
    /// touched; the credentials inline; the local port's descriptor and verifier for LumenTunnel.
    public func runtime(forwarders: [Int: UInt16], tunnelProgram: String, username: String?, password: String?,
                        listeningDescriptor: Int32, statusDescriptor: Int32, verifierHex: String) throws -> String {
        var text = ["# Lumen: one launch's configuration, given on standard input", "client", "dev tun", "nobind"]
        text.append(Self.line(["dev-node", "unix:" + tunnelProgram]))
        text += ["script-security 2", "route-noexec", "ifconfig-noexec", "auth-retry none", "verb 3", "mute-replay-warnings",
                 // Answers a server pushes that would ask for more than a tun's addresses are not
                 // acted on anyway (route-noexec); a pushed script is never run (none is accepted).
                 "pull-filter ignore \"route\"", "pull-filter ignore \"redirect-gateway\"",
                 "connect-retry 2 8", "server-poll-timeout 15"]
        if remoteRandom { text.append("remote-random") }
        let compression = directives.contains { $0[0] == "comp-lzo" || $0[0] == "compress" }
        if compression && !directives.contains(where: { $0[0] == "allow-compression" }) {
            // Packets the server compressed are taken in; none is compressed on the way out (VORACLE).
            text.append("allow-compression asym")
        }
        for words in directives where !["connect-retry", "server-poll-timeout"].contains(words[0]) {
            text.append(Self.line(words))
        }
        // The keys and certificates before the servers' entries: OpenVPN 2.7 takes tls-auth,
        // tls-crypt and tls-crypt-v2 per entry, and ignores one given after the entries.
        for block in blocks {
            text.append("<\(block.name)>")
            text.append(block.content.trimmingCharacters(in: .newlines))
            text.append("</\(block.name)>")
        }
        text.append("setenv LUMEN_SOCKS_FD \(listeningDescriptor)")
        text.append("setenv LUMEN_STATUS_FD \(statusDescriptor)")
        text.append("setenv LUMEN_SOCKS_VERIFIER \(verifierHex)")
        var anyRemote = false
        for (index, remote) in remotes.enumerated() {
            guard let port = forwarders[index] else { continue }
            anyRemote = true
            text.append("<connection>")
            text.append(Self.line(["remote", "127.0.0.1", String(port), remote.transport == .udp ? "udp4" : "tcp4-client"]))
            for words in remote.directives { text.append(Self.line(words)) }
            text.append("</connection>")
        }
        guard anyRemote else { throw OpenVPNConfigProblem.noRemote }
        if needsCredentials {
            guard let username, !username.isEmpty, let password, !password.isEmpty else { throw OpenVPNConfigProblem.missing("auth-user-pass") }
            // One line each: a line break in either would be read as the next field.
            guard !username.contains(where: \.isNewline), !password.contains(where: \.isNewline),
                  !username.contains("</auth-user-pass>"), !password.contains("</auth-user-pass>") else {
                throw OpenVPNConfigProblem.missing("auth-user-pass")
            }
            text += ["<auth-user-pass>", username, password, "</auth-user-pass>"]
        }
        return text.joined(separator: "\n") + "\n"
    }

    // MARK: Import

    /// `text` with every file it names inline: `ca ca.crt` becomes a `<ca>` block holding what
    /// `read` gives for "ca.crt" (the import reads it from beside the `.ovpn`). A name `read`
    /// does not give is left as it was, and `parse` says which.
    public static func inlining(_ text: String, read: (String) -> String?) -> String {
        var out: [String] = []
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var inBlock: String?
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let name = inBlock {
                out.append(line)
                if trimmed.lowercased() == "</\(name)>" { inBlock = nil }
                continue
            }
            if trimmed.hasPrefix("<"), trimmed.hasSuffix(">"), !trimmed.hasPrefix("</") {
                let name = String(trimmed.dropFirst().dropLast()).lowercased()
                if name != "connection" { inBlock = name }
                out.append(line)
                continue
            }
            guard var words = tokens(trimmed), words.count >= 2 else { out.append(line); continue }
            if words[0].hasPrefix("--") { words[0].removeFirst(2) }
            let name = words[0].lowercased()
            guard fileBlocks.contains(name), name != "peer-fingerprint", words[1] != "[inline]",
                  let content = read(words[1]) else {
                out.append(line)
                continue
            }
            if name == "auth-user-pass" {
                out += ["<auth-user-pass>", content.trimmingCharacters(in: .newlines), "</auth-user-pass>"]
                continue
            }
            out += ["<\(name)>", content.trimmingCharacters(in: .newlines), "</\(name)>"]
            // `tls-auth file 1`: the direction becomes `key-direction 1`.
            if (name == "tls-auth") && words.count >= 3 { out.append("key-direction \(words[2])") }
        }
        return out.joined(separator: "\n")
    }

    /// The first server, for the proxy's host and port (what lists show and what identifies it).
    public var firstRemote: Remote { remotes[0] }
}

extension ProxySettings {
    /// A proxy that is an OpenVPN connection: from its configuration (its first server's host
    /// and port) and its credentials. The configuration must parse.
    public static func openVPN(_ configuration: OpenVPNConfiguration, username: String?, password: String?) -> ProxySettings {
        let first = configuration.firstRemote
        let user = (username?.isEmpty ?? true) ? nil : username
        return ProxySettings(kind: .socks5, host: first.host, port: first.port, username: user, password: user == nil ? nil : (password ?? ""),
                             openVPN: OpenVPNSettings(configuration: configuration.normalized))
    }

    /// An OpenVPN connection's own rules: a configuration that parses, given as SOCKS5 without
    /// TLS, its host and port its first server's, and credentials when it asks for them.
    func validateOpenVPN() throws {
        guard let openVPN else { return }
        let parsed: OpenVPNConfiguration
        do {
            parsed = try openVPN.parsed()
        } catch {
            throw CoreError.invalidConfiguration("the OpenVPN configuration cannot be used: \(error)")
        }
        guard kind == .socks5, !tlsToProxy else {
            throw CoreError.invalidConfiguration("an OpenVPN connection is given to a profile as SOCKS5")
        }
        guard parsed.firstRemote.host == host, parsed.firstRemote.port == port else {
            throw CoreError.invalidConfiguration("an OpenVPN connection's host and port are its first server's")
        }
        if parsed.needsCredentials, username == nil {
            throw CoreError.invalidConfiguration("this OpenVPN server asks for a user name and password")
        }
    }

    /// Whether this is an OpenVPN connection.
    public var isOpenVPN: Bool { openVPN != nil }
}
