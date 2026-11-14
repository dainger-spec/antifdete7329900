import Foundation

/// What the proxy is asked to connect to.
enum ProxyTarget: Equatable {
    /// A host name: the proxy resolves it.
    case name(String, port: UInt16)
    /// An address the guest connected to as written.
    case address(VMNetIPv4, port: UInt16)

    var port: UInt16 {
        switch self {
        case .name(_, let port), .address(_, let port): return port
        }
    }

    /// The host as a proxy's request carries it in text.
    var hostText: String {
        switch self {
        case .name(let name, _): return name
        case .address(let address, _): return address.string
        }
    }
}

/// Where a connection the guest opens may go.
///
/// A fake address stands for the name it was given for, and the proxy is asked for that name. Any
/// other public address is asked of the proxy as it is. Everything else is refused before the
/// proxy hears of it: an address of somebody's local network, of a machine itself, or of no
/// machine at all would be reached from the proxy's side — the guest must not reach anybody's LAN.
enum DestinationPolicy {
    enum Decision: Equatable {
        case connect(ProxyTarget)
        case refuse(Refusal)
    }

    enum Refusal: String, Equatable {
        /// A fake address no name was given for (or whose name was forgotten since).
        case unknownFakeAddress = "a fake address without a name"
        /// The guest's own network: the gateway offers no TCP service, and there is nobody else.
        case ownNetwork = "the guest's own network"
        /// Private, loopback, link-local, multicast, reserved and broadcast addresses.
        case notPublic = "not a public address"
        case noPort = "port 0"
    }

    /// The ranges no connection is made to: (network, prefix length).
    static let refusedRanges: [(UInt32, Int)] = [
        (0x0000_0000, 8),   // 0.0.0.0/8: "this network"
        (0x0A00_0000, 8),   // 10.0.0.0/8: private
        (0x6440_0000, 10),  // 100.64.0.0/10: carrier-grade NAT, private to a provider
        (0x7F00_0000, 8),   // 127.0.0.0/8: loopback
        (0xA9FE_0000, 16),  // 169.254.0.0/16: link-local
        (0xAC10_0000, 12),  // 172.16.0.0/12: private
        (0xC000_0000, 24),  // 192.0.0.0/24: protocol assignments
        (0xC0A8_0000, 16),  // 192.168.0.0/16: private
        (0xE000_0000, 4),   // 224.0.0.0/4: multicast
        (0xF000_0000, 4),   // 240.0.0.0/4: reserved, and the broadcast address
    ]

    static func isRefusedRange(_ address: VMNetIPv4) -> Bool {
        refusedRanges.contains { address.isIn($0.0, $0.1) }
    }

    /// `nameForFakeAddress` is the DNS responder's memory of which name a fake address was given for.
    static func decide(address: VMNetIPv4, port: UInt16, gateway: VMNetIPv4, prefixLength: Int,
                       nameForFakeAddress: (VMNetIPv4) -> String?) -> Decision {
        guard port != 0 else { return .refuse(.noPort) }
        if FakeAddressPool.contains(address) {
            guard let name = nameForFakeAddress(address) else { return .refuse(.unknownFakeAddress) }
            return .connect(.name(name, port: port))
        }
        if address.isIn(gateway.value, prefixLength) { return .refuse(.ownNetwork) }
        if isRefusedRange(address) { return .refuse(.notPublic) }
        return .connect(.address(address, port: port))
    }
}
