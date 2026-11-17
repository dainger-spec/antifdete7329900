/// What OpenVPN hands the program it starts as its tun device (`--dev-node unix:`, OpenVPN 2.7's
/// AF_UNIX tun), read from that program's environment, and what Lumen's app adds to it.
///
/// OpenVPN's part: `TUNTAP_SOCKET_FD` (one end of a datagram socket pair: one IP packet per
/// datagram), `TUNTAP_DEV_TYPE` (tun; tap is refused), `TUNTAP_MTU`, the addresses the server
/// pushed (`ifconfig_local`, `ifconfig_ipv6_local`) and its DNS servers — as `dns_server_N_address_M`
/// (and `_port_M`), or as `foreign_option_N=dhcp-option DNS …` / `DNS6 …`.
///
/// The app's part (`setenv` in the configuration it gives OpenVPN): `LUMEN_SOCKS_FD`, the
/// listening socket on 127.0.0.1 the profile is given; `LUMEN_SOCKS_VERIFIER`, the SHA-256 of
/// the launch's credentials (`CredentialCheck`); `LUMEN_STATUS_FD`, where the program says what it
/// does (optional).
public struct TunnelSettings: Equatable, Sendable {
    public struct DNSServer: Equatable, Sendable {
        public var address: TunnelAddress
        public var port: UInt16
    }

    public var packetSocket: Int32
    public var listeningSocket: Int32
    public var statusSocket: Int32?
    public var verifier: [UInt8]
    public var mtu: Int
    public var ipv4: TunnelAddress?
    public var ipv6: TunnelAddress?
    /// The servers the VPN pushed, in its order; `dnsPushed` false when it pushed none and the
    /// fallback (public resolvers, asked through the tunnel) is used.
    public var dnsServers: [DNSServer]
    public var dnsPushed: Bool

    /// Asked through the tunnel when the VPN pushed no DNS server: never this Mac's own resolver.
    public static let fallbackDNS: [DNSServer] = [
        DNSServer(address: TunnelAddress("1.1.1.1")!, port: 53),
        DNSServer(address: TunnelAddress("8.8.8.8")!, port: 53),
    ]

    public enum Problem: Error, Equatable, CustomStringConvertible {
        case missing(String)
        case invalid(String)
        case tap
        case noAddress

        public var description: String {
            switch self {
            case .missing(let name): return "\(name) is not set"
            case .invalid(let name): return "\(name) is not valid"
            case .tap: return "a tap device was asked for: only tun is served"
            case .noAddress: return "the server pushed no IPv4 or IPv6 address"
            }
        }
    }

    public static func read(_ environment: [String: String]) throws -> TunnelSettings {
        func descriptor(_ name: String) throws -> Int32 {
            guard let text = environment[name] else { throw Problem.missing(name) }
            guard let value = Int32(text), value > 2 else { throw Problem.invalid(name) }
            return value
        }
        let packets = try descriptor("TUNTAP_SOCKET_FD")
        let listening = try descriptor("LUMEN_SOCKS_FD")
        let status = environment["LUMEN_STATUS_FD"] != nil ? try descriptor("LUMEN_STATUS_FD") : nil
        if let type = environment["TUNTAP_DEV_TYPE"], type != "tun" { throw Problem.tap }
        guard let verifierText = environment["LUMEN_SOCKS_VERIFIER"] else { throw Problem.missing("LUMEN_SOCKS_VERIFIER") }
        guard let verifier = hexBytes(verifierText), verifier.count == 32 else { throw Problem.invalid("LUMEN_SOCKS_VERIFIER") }
        var mtu = 1500
        if let text = environment["TUNTAP_MTU"] {
            guard let value = Int(text), (576...65_535).contains(value) else { throw Problem.invalid("TUNTAP_MTU") }
            mtu = value
        }
        let ipv4 = environment["ifconfig_local"].flatMap(TunnelAddress.init).flatMap { $0.family == .v4 && !$0.isAny ? $0 : nil }
        let ipv6 = environment["ifconfig_ipv6_local"].flatMap(TunnelAddress.init).flatMap { $0.family == .v6 && !$0.isAny ? $0 : nil }
        guard ipv4 != nil || ipv6 != nil else { throw Problem.noAddress }
        let pushed = dnsServers(environment)
        return TunnelSettings(packetSocket: packets, listeningSocket: listening, statusSocket: status, verifier: verifier,
                              mtu: mtu, ipv4: ipv4, ipv6: ipv6,
                              dnsServers: pushed.isEmpty ? fallbackDNS : pushed, dnsPushed: !pushed.isEmpty)
    }

    /// The pushed DNS servers: `dns_server_N_address_M` first (OpenVPN 2.7's form, in N then M
    /// order, with its port), then any `dhcp-option DNS`/`DNS6` not already among them. Duplicates
    /// once. Addresses only: a server named by a host name could not be asked without a resolver.
    static func dnsServers(_ environment: [String: String]) -> [DNSServer] {
        var found: [DNSServer] = []
        func add(_ server: DNSServer) {
            if !found.contains(server) { found.append(server) }
        }
        var structured: [(Int, Int, DNSServer)] = []
        for (key, value) in environment where key.hasPrefix("dns_server_") {
            let parts = key.split(separator: "_")
            // dns, server, N, address, M
            guard parts.count == 5, parts[3] == "address", let n = Int(parts[2]), let m = Int(parts[4]) else { continue }
            guard let address = TunnelAddress(value), !address.isAny else { continue }
            var port: UInt16 = 53
            if let text = environment["dns_server_\(n)_port_\(m)"], let value = UInt16(text), value > 0 { port = value }
            structured.append((n, m, DNSServer(address: address, port: port)))
        }
        for (_, _, server) in structured.sorted(by: { ($0.0, $0.1) < ($1.0, $1.1) }) { add(server) }
        var options: [(Int, String)] = []
        for (key, value) in environment where key.hasPrefix("foreign_option_") {
            guard let n = Int(key.dropFirst("foreign_option_".count)) else { continue }
            options.append((n, value))
        }
        for (_, value) in options.sorted(by: { $0.0 < $1.0 }) {
            let words = value.split(separator: " ", omittingEmptySubsequences: true)
            guard words.count == 3, words[0] == "dhcp-option", words[1] == "DNS" || words[1] == "DNS6",
                  let address = TunnelAddress(String(words[2])), !address.isAny else { continue }
            add(DNSServer(address: address, port: 53))
        }
        return found
    }

    static func hexBytes(_ text: String) -> [UInt8]? {
        let digits = Array(text.utf8)
        guard digits.count % 2 == 0 else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(digits.count / 2)
        var index = 0
        while index < digits.count {
            guard let high = hexValue(digits[index]), let low = hexValue(digits[index + 1]) else { return nil }
            bytes.append(high << 4 | low)
            index += 2
        }
        return bytes
    }

    private static func hexValue(_ digit: UInt8) -> UInt8? {
        switch digit {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return digit - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return digit - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): return digit - UInt8(ascii: "A") + 10
        default: return nil
        }
    }
}
