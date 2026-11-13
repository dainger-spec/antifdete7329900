import Foundation

/// The proxy this Mac's own network settings name (System Settings → Network → Proxies, where a
/// VPN or proxy tool in its "system proxy" mode writes itself): what Safari and every other app
/// that follows the settings go through — and so what a machine without a proxy of its own goes
/// through too (`VMNetDirectConnector`). A tool in that mode takes no packets: a plain socket of
/// this process would pass it by, and on a network where only the tool gets out, reach nothing.
public struct VMNetSystemProxy: Equatable, Sendable {
    /// `.socks5` or `.httpConnect`, never `.none`.
    public var upstream: VMNetUpstream
    /// Hosts the settings say go without the proxy ("*.local", "localhost", …), lowercased.
    public var exceptions: [String]

    public init(upstream: VMNetUpstream, exceptions: [String] = []) {
        self.upstream = upstream
        self.exceptions = exceptions.map { $0.lowercased() }
    }

    /// From the system's own dictionary (`CFNetworkCopySystemProxySettings`); nil when it names no
    /// proxy a connection can be carried by. A SOCKS proxy is taken first — it carries a
    /// connection to any port — then the one for HTTPS, asked by CONNECT. A proxy configuration
    /// file (PAC) is not followed: it is a program to run for every address.
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
        if isOn("SOCKSEnable"), let host = host("SOCKSProxy"), let port = port("SOCKSPort") {
            upstream = .socks5(host: host, port: port, username: nil, password: nil)
        } else if isOn("HTTPSEnable"), let host = host("HTTPSProxy"), let port = port("HTTPSPort") {
            upstream = .httpConnect(host: host, port: port, username: nil, password: nil)
        } else {
            return nil
        }
        exceptions = ((settings["ExceptionsList"] as? [Any]) ?? []).compactMap { $0 as? String }.map { $0.lowercased() }
    }

    /// Whether a connection to `host` goes through the proxy: not when the settings' exceptions
    /// name it — itself, or by a pattern for every name under one ("*.example.com", ".example.com").
    public func applies(to host: String) -> Bool {
        let host = host.lowercased()
        for entry in exceptions where !entry.isEmpty {
            if entry == host { return false }
            if entry.hasPrefix("*.") || entry.hasPrefix(".") {
                let suffix = entry.hasPrefix("*") ? String(entry.dropFirst()) : entry
                if host.hasSuffix(suffix) || host == suffix.dropFirst() { return false }
            }
        }
        return true
    }
}
