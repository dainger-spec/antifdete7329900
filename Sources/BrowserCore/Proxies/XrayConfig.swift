import Foundation

/// The relay's configuration for one running profile (docs/TUNNEL.md, "Links"): Xray with one way in
/// and one way out, and nothing else.
///
/// - In: SOCKS5 on 127.0.0.1 at the launch's port, with the launch's own user name and password
///   (`auth: password`; SOCKS4 and plain HTTP are refused without them too), UDP on — each UDP
///   association gets a socket of its own after that login, answering only the client that made it
///   (Xray's `TempUDPConn`) — and no sniffing: the host names the profile sends are passed on as
///   they came, never resolved here and never replaced.
/// - Out: the link's server, the only outbound there is. No `freedom` (direct) outbound, no DNS
///   section, no routing to anything else, no `sockopt` and no second address (XHTTP's `extra`,
///   `downloadSettings`): the relay can send a profile's traffic to that server or nowhere.
/// - The log: errors only, no access log — the hosts a profile visits are never written by it.
public enum XrayConfig {
    /// The local side: where the profile's process connects, and with what.
    public struct Inbound: Equatable, Sendable {
        public var port: Int
        public var username: String
        public var password: String

        public init(port: Int, username: String, password: String) {
            self.port = port
            self.username = username
            self.password = password
        }

        /// A new one for a launch: `port` is the one found free, the user name and password 32 hex
        /// characters each from `SystemRandomNumberGenerator`.
        public static func random(port: Int) -> Inbound {
            Inbound(port: port, username: randomHex(16), password: randomHex(16))
        }

        static func randomHex(_ bytes: Int) -> String {
            var generator = SystemRandomNumberGenerator()
            return (0..<bytes).map { _ in String(format: "%02x", UInt8.random(in: 0...255, using: &generator)) }.joined()
        }

        /// The profile's way to this relay while it runs (`ProxyRoutes`).
        public var route: ProxyRoutes.Route {
            ProxyRoutes.Route(port: port, username: username, password: password)
        }
    }

    public static let listenAddress = "127.0.0.1"
    static let inboundTag = "lumen-in"
    static let outboundTag = "lumen-out"

    /// The configuration as Xray reads it (JSON), for `xray run -c stdin:`.
    public static func json(for link: ShareLink, inbound: Inbound) throws -> Data {
        try JSONSerialization.data(withJSONObject: object(for: link, inbound: inbound), options: [.sortedKeys])
    }

    public static func object(for link: ShareLink, inbound: Inbound) throws -> [String: Any] {
        try ShareLink.validate(link)
        guard (1...65535).contains(inbound.port), !inbound.username.isEmpty, !inbound.password.isEmpty else {
            throw CoreError.invalidConfiguration("the relay's local port and login")
        }
        let socks: [String: Any] = [
            "tag": inboundTag,
            "listen": listenAddress,
            "port": inbound.port,
            "protocol": "socks",
            "settings": [
                "auth": "password",
                "accounts": [["user": inbound.username, "pass": inbound.password]],
                "udp": true,
                "ip": listenAddress,
            ] as [String: Any],
            "sniffing": ["enabled": false],
        ]
        var outbound = try protocolOutbound(for: link)
        outbound["tag"] = outboundTag
        outbound["streamSettings"] = streamSettings(for: link)
        return [
            "log": ["loglevel": "error", "access": "none", "dnsLog": false] as [String: Any],
            "inbounds": [socks],
            "outbounds": [outbound],
            "routing": [
                "domainStrategy": "AsIs",
                "rules": [["type": "field", "inboundTag": [inboundTag], "outboundTag": outboundTag] as [String: Any]],
            ] as [String: Any],
        ]
    }

    static func protocolOutbound(for link: ShareLink) throws -> [String: Any] {
        switch link.scheme {
        case .vless:
            var settings: [String: Any] = [
                "address": link.host, "port": link.port, "id": link.userID ?? "", "encryption": link.encryption ?? "none",
            ]
            if let flow = link.flow { settings["flow"] = flow }
            return ["protocol": "vless", "settings": settings]
        case .vmess:
            let settings: [String: Any] = [
                "address": link.host, "port": link.port, "id": link.userID ?? "", "security": link.method ?? "auto",
            ]
            return ["protocol": "vmess", "settings": settings]
        case .trojan:
            let settings: [String: Any] = ["address": link.host, "port": link.port, "password": link.password ?? ""]
            return ["protocol": "trojan", "settings": settings]
        case .shadowsocks:
            guard let method = link.method.flatMap({ ShareLink.shadowsocksMethods[$0] }) else {
                throw ShareLinkError.unsupportedCipher(link.method ?? "")
            }
            let settings: [String: Any] = [
                "address": link.host, "port": link.port, "method": method, "password": link.password ?? "",
            ]
            return ["protocol": "shadowsocks", "settings": settings]
        }
    }

    static func streamSettings(for link: ShareLink) -> [String: Any] {
        var stream: [String: Any] = [:]
        switch link.transport {
        case .tcp:
            stream["network"] = "raw"
            if link.tcpHTTPHeader {
                var request: [String: Any] = ["path": [link.path ?? "/"]]
                if let host = link.hostHeader {
                    let names = host.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                    request["headers"] = ["Host": names]
                }
                stream["rawSettings"] = ["header": ["type": "http", "request": request] as [String: Any]]
            }
        case .ws:
            stream["network"] = "ws"
            stream["wsSettings"] = pathAndHost(link)
        case .httpupgrade:
            stream["network"] = "httpupgrade"
            stream["httpupgradeSettings"] = pathAndHost(link)
        case .xhttp:
            stream["network"] = "xhttp"
            var settings = pathAndHost(link)
            settings["mode"] = link.xhttpMode ?? "auto"
            stream["xhttpSettings"] = settings
        case .grpc:
            stream["network"] = "grpc"
            var settings: [String: Any] = ["serviceName": link.serviceName ?? "", "multiMode": link.grpcMultiMode]
            if let authority = link.authority { settings["authority"] = authority }
            stream["grpcSettings"] = settings
        }
        switch link.security {
        case .none:
            stream["security"] = "none"
        case .tls:
            stream["security"] = "tls"
            var tls: [String: Any] = [:]
            if let serverName = link.serverName { tls["serverName"] = serverName }
            if let fingerprint = link.fingerprint { tls["fingerprint"] = fingerprint }
            if !link.alpn.isEmpty { tls["alpn"] = link.alpn }
            if let pinned = link.pinnedCertificateSHA256 { tls["pinnedPeerCertSha256"] = pinned }
            if let names = link.verifyCertificateByName { tls["verifyPeerCertByName"] = names }
            stream["tlsSettings"] = tls
        case .reality:
            stream["security"] = "reality"
            var reality: [String: Any] = [
                "serverName": link.serverName ?? "",
                // REALITY always speaks as a browser's TLS: Chrome's unless the link names another.
                "fingerprint": link.fingerprint ?? "chrome",
                "publicKey": link.realityPublicKey ?? "",
                "shortId": link.realityShortID ?? "",
                "spiderX": link.realitySpiderX ?? "",
            ]
            if let verify = link.realityMLDSA65Verify { reality["mldsa65Verify"] = verify }
            stream["realitySettings"] = reality
        }
        return stream
    }

    private static func pathAndHost(_ link: ShareLink) -> [String: Any] {
        var settings: [String: Any] = ["path": link.path ?? "/"]
        if let host = link.hostHeader { settings["host"] = host }
        return settings
    }
}
