import Foundation

/// The proxy this Mac's own network settings name (System Settings → Network → Proxies, where a
/// VPN or proxy tool in its "system proxy" mode writes itself): what Safari and every other app
/// that follows the settings go through — and so what a machine without a proxy of its own goes
/// through too (`VMNetDirectConnector`). A tool in that mode takes no packets: a plain socket of
/// this process would pass it by, and on a network where only the tool gets out, reach nothing.
public struct VMNetSystemProxy: Equatable, Sendable {
    /// `.socks5` or `.httpConnect` — `.none` only with `usesConfigurationFile`.
    public var upstream: VMNetUpstream
    /// Hosts the settings say go without the proxy ("*.local", "localhost", "192.168.0.0/16",
    /// "169.254/16", …), lowercased.
    public var exceptions: [String]
    /// The settings have the proxy chosen by a configuration file (PAC) or found on the network
    /// (WPAD). That is a program to run for every address, which a machine does not follow — and
    /// going out without the proxy instead would be going out where the Mac's own apps do not:
    /// a machine then makes no connection at all (`VMNetDirectConnector.Trouble.proxyConfigurationFile`).
    public var usesConfigurationFile: Bool

    public init(upstream: VMNetUpstream, exceptions: [String] = [], usesConfigurationFile: Bool = false) {
        self.upstream = upstream
        self.exceptions = exceptions.map { $0.lowercased() }
        self.usesConfigurationFile = usesConfigurationFile
    }

    /// From the system's own dictionary (`CFNetworkCopySystemProxySettings`); nil when it names no
    /// proxy at all. A proxy configuration file (PAC) or discovery on the network (WPAD) is taken
    /// first, as the system takes it — and is not followed (`usesConfigurationFile`). Otherwise a
    /// SOCKS proxy is taken first — it carries a connection to any port — then the one for HTTPS,
    /// asked by CONNECT.
    public init?(settings: [String: Any]) {
        func isOn(_ key: String) -> Bool {
            switch settings[key] {
            case let value as Bool: return value
            case let value as Int: return value != 0
            case let value as NSNumber: return value.intValue != 0
            case let value as String: return value == "1"
            default: return false
            }
        }
        func port(_ key: String) -> Int? {
            let value: Int?
            switch settings[key] {
            case let number as Int: value = number
            case let number as NSNumber: value = number.intValue
            case let text as String: value = Int(text)
            default: value = nil
            }
            return value.flatMap { (1...65535).contains($0) ? $0 : nil }
        }
        func host(_ key: String) -> String? {
            guard let text = settings[key] as? String else { return nil }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            // A host as hosts are written: nothing a resolver could take for anything else.
            guard (1...253).contains(trimmed.utf8.count), trimmed.utf8.allSatisfy({ $0 > 0x20 && $0 < 0x7F }) else { return nil }
            return trimmed
        }
        usesConfigurationFile = false
        if isOn("ProxyAutoConfigEnable") || isOn("ProxyAutoDiscoveryEnable") {
            upstream = .none
            usesConfigurationFile = true
        } else if isOn("SOCKSEnable"), let host = host("SOCKSProxy"), let port = port("SOCKSPort") {
            upstream = .socks5(host: host, port: port, username: nil, password: nil)
        } else if isOn("HTTPSEnable"), let host = host("HTTPSProxy"), let port = port("HTTPSPort") {
            upstream = .httpConnect(host: host, port: port, username: nil, password: nil)
        } else {
            return nil
        }
        exceptions = ((settings["ExceptionsList"] as? [Any]) ?? []).compactMap { $0 as? String }.map { $0.lowercased() }
    }

    /// Whether a connection to `host` goes through the proxy: not when the settings' exceptions
    /// name it — itself, or by a pattern for every name under one ("*.example.com", ".example.com"),
    /// or, for an address, by a range as macOS writes one ("192.168.0.0/16", "169.254/16",
    /// "10.*", "127.0.0.1"). A host that is excepted goes without the proxy — by this Mac's own
    /// rules for a connection, which refuse an address of this Mac or its local network.
    public func applies(to host: String) -> Bool {
        let host = host.lowercased()
        let address = VMNetIPv4(string: host)
        for entry in exceptions where !entry.isEmpty {
            if entry == host { return false }
            if entry.hasPrefix("*.") || entry.hasPrefix(".") {
                let suffix = entry.hasPrefix("*") ? String(entry.dropFirst()) : entry
                if host.hasSuffix(suffix) || host == suffix.dropFirst() { return false }
            }
            if let address, let range = Self.range(entry), address.isIn(range.network, range.prefixLength) { return false }
        }
        return true
    }

    /// An exception that is a range of IPv4 addresses, as the Mac's settings write one: an address
    /// with or without a prefix length ("10.0.0.0/8", "127.0.0.1"), leading parts alone with one
    /// ("169.254/16") or without (then 8 bits a part: "10" is 10.0.0.0/8), parts that are "*" at
    /// the end ("192.168.*"). Nil for anything else.
    static func range(_ entry: String) -> (network: UInt32, prefixLength: Int)? {
        let pieces = entry.split(separator: "/", omittingEmptySubsequences: false)
        guard (1...2).contains(pieces.count) else { return nil }
        var parts = pieces[0].split(separator: ".", omittingEmptySubsequences: false)
        var wildcards = 0
        while let last = parts.last, last == "*" {
            parts.removeLast()
            wildcards += 1
        }
        guard (1...4).contains(parts.count), parts.count + wildcards <= 4 else { return nil }
        var network: UInt32 = 0
        for (index, part) in parts.enumerated() {
            guard (1...3).contains(part.count), part.allSatisfy({ $0.isASCII && $0.isNumber }), let byte = UInt8(part) else { return nil }
            network |= UInt32(byte) << UInt32(24 - 8 * index)
        }
        var prefixLength = parts.count * 8
        if pieces.count == 2 {
            guard wildcards == 0, (1...2).contains(pieces[1].count), pieces[1].allSatisfy({ $0.isASCII && $0.isNumber }),
                  let length = Int(pieces[1]), (0...32).contains(length) else { return nil }
            prefixLength = length
        }
        return (network, prefixLength)
    }
}
