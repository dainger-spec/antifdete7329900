import Foundation

/// The addresses a VPN's own DNS gives out in place of real ones ("fake IP", as Clash, sing-box,
/// Surge and others call it): every name is answered at once with an address from a range no host
/// on the internet has, and a connection to that address goes into the VPN, which maps it back to
/// the name and connects by name itself. Such a resolver answers names that do not exist too, so
/// behind it "no such host" never comes from the resolver: the connection fails later, inside the
/// VPN, and looks like a proxy that refuses, closes or says nothing (`ProxyProbe`).
///
/// The ranges: 198.18.0.0/15, set aside for benchmarking (RFC 2544) and the default range of most
/// of these VPNs, and 240.0.0.0/4, reserved and never routed — the one such a VPN was seen
/// answering `.invalid` names with. Written as IPv4, or as IPv4-mapped IPv6.
public enum SubstituteDNS {
    /// `address` as `getnameinfo` writes it ("240.0.0.91", "::ffff:198.18.0.7").
    public static func isSubstitute(_ address: String) -> Bool {
        var text = Substring(address.lowercased())
        if text.hasPrefix("::ffff:") { text = text.dropFirst(7) }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        let bytes = parts.compactMap { part -> UInt8? in
            guard !part.isEmpty, part.count <= 3, part.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
            return UInt8(part)
        }
        guard bytes.count == 4 else { return false }
        // 198.18.0.0/15: 198.18.x.x and 198.19.x.x.
        if bytes[0] == 198 && bytes[1] & 0xFE == 18 { return true }
        // 240.0.0.0/4: 240.x.x.x to 255.x.x.x.
        return bytes[0] & 0xF0 == 0xF0
    }
}
