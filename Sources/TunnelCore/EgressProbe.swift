/// Finding the address peers will see: a STUN Binding request sent through the proxy's UDP
/// association answers with the proxy's public address and port for that association — the
/// relayed address the TURN server announces. The STUN server is named, not resolved here, so
/// the proxy resolves it and no DNS query for it leaves this Mac.
public struct EgressProbe: Sendable {
    public let transactionID: [UInt8]
    public let request: [UInt8]

    public init() {
        transactionID = (0..<12).map { _ in UInt8.random(in: 0...255) }
        request = STUNMessage(method: STUNMessage.Method.binding.rawValue, messageClass: .request, transactionID: transactionID)
            .encode(fingerprint: true)
    }

    /// The mapped address in `response`, if it answers this probe.
    public func mappedAddress(in response: [UInt8]) -> SocketAddress? {
        guard let message = STUNMessage.parse(response), message.transactionID == transactionID,
              message.messageClass == .success, message.method == STUNMessage.Method.binding.rawValue else { return nil }
        if let value = message.attribute(STUNMessage.Attribute.xorMappedAddress) {
            return STUNMessage.decodeXorAddress(value, transactionID: transactionID)
        }
        // Old servers answer with plain MAPPED-ADDRESS.
        guard let value = message.attribute(STUNMessage.Attribute.mappedAddress), value.count >= 8 else { return nil }
        let length = value[1] == 1 ? 4 : 16
        guard value.count == 4 + length, let ip = IPAddr(bytes: Array(value[4...])) else { return nil }
        return SocketAddress(ip: ip, port: get16(value, 2))
    }

    /// "host:port" or "[v6]:port" → a destination the proxy resolves (IP literals stay literals).
    public static func destination(_ server: String) -> ProxyDestination? {
        guard let colon = server.lastIndex(of: ":"), let port = UInt16(server[server.index(after: colon)...]) else { return nil }
        let host = String(server[..<colon])
        if let ip = IPAddr(host) { return .address(SocketAddress(ip: ip, port: port)) }
        guard !host.isEmpty, !host.contains(":") else { return nil }
        return .name(host, port: port)
    }
}

/// The other half of "one address": where a proxy's TCP leaves from. Cloudflare's trace
/// (`/cdn-cgi/trace`) answers in `key=value` lines, `ip=` among them — the address the request
/// came from. Asked through the proxy at one of Cloudflare's IPv4 addresses (`ProxyExitLookup`), it
/// can only be the proxy's IPv4 exit: no name is resolved anywhere.
public enum ExitTrace {
    /// The first `ip=` line's address when it is an IPv4 one; nil for anything else (no such line,
    /// not an address, an IPv6 one: none of them can be compared with an IPv4 relayed address).
    public static func ipv4(in text: String) -> IPAddr? {
        guard let line = text.split(whereSeparator: \.isNewline).first(where: { $0.hasPrefix("ip=") }),
              let ip = IPAddr(String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)), ip.family == .v4 else { return nil }
        return ip
    }
}
