import Foundation
import NetworkExtension
import os

/// Per-profile packet tunnel: captures all of the container app's traffic (TCP and UDP) and
/// forwards it to one exit, so a profile's QUIC/HTTP3 and WebRTC share the exit IP of its proxy
/// instead of leaking through the real interface (see ../docs/NETWORK.md).
///
/// Built and loaded only by a provisioned `NE=1` build; never compiled by the Swift package or CI.
/// It has no dependency on BrowserCore so it stays small (the system caps a packet-tunnel
/// provider's memory): it re-declares the handful of `providerConfiguration` keys that
/// `TunnelConfiguration.dictionary` writes.
///
/// The control flow (configuration decode, tunnel settings, start/stop, fail-closed) lives here;
/// the packet datapath — TCP relayed over SOCKS5/HTTP CONNECT (or direct), UDP over SOCKS5 UDP
/// ASSOCIATE (or direct, or dropped), DNS answered on 10.111.0.1 — is `Relay`. It cannot run in CI:
/// run the manual checklist in ../docs/NETWORK.md on a Mac with an `NE=1` build before trusting it.
final class PacketTunnelProvider: NEPacketTunnelProvider {
    private let log = Logger(subsystem: "PrivacyBrowser.PacketTunnel", category: "tunnel")
    private var relay: Relay?

    // Keys shared with BrowserCore.TunnelConfiguration.dictionary (kept in sync by hand).
    private enum Key {
        static let exitKind = "exitKind", host = "host", port = "port", proxyKind = "proxyKind"
        static let tls = "tls", username = "username", udp = "udp", profileID = "profileID"
    }

    override func startTunnel(options: [String: NSObject]?) async throws {
        guard let proto = protocolConfiguration as? NETunnelProviderProtocol,
              let config = proto.providerConfiguration as? [String: String] else {
            throw TunnelError.noConfiguration
        }
        let exitKind = config[Key.exitKind] ?? "direct"
        let udpDropped = config[Key.udp] == "dropped"
        log.notice("startTunnel exit=\(exitKind, privacy: .public) udpDropped=\(udpDropped, privacy: .public)")

        // Resolve the exit; a proxy password (if any) comes from the keychain, not the config.
        // The proxy host is resolved HERE, before the tunnel's network settings apply: once they do,
        // the system resolver is the tunnel's own 10.111.0.1, which cannot resolve the exit it needs
        // to reach. No IPv4 address for the proxy → the tunnel does not come up (fail-closed).
        let exit: Relay.Exit
        var remoteAddress = "127.0.0.1"
        if exitKind == "proxy", let host = config[Key.host], let port = config[Key.port].flatMap(UInt16.init) {
            let addresses = await Self.resolveIPv4(host)
            guard let first = addresses.first else {
                log.error("proxy host has no IPv4 address; not starting")
                throw TunnelError.proxyUnresolvable
            }
            log.notice("proxy resolved to \(addresses.count, privacy: .public) IPv4 address(es)")
            remoteAddress = Self.dotted(first)
            let password = Self.keychainPassword(proto.passwordReference)
            exit = .proxy(Relay.Proxy(host: host, addresses: addresses, port: port,
                                      socks: config[Key.proxyKind] == "socks5", tls: config[Key.tls] == "1",
                                      username: config[Key.username], password: password))
        } else {
            exit = .directInterface
        }

        // A point-to-point tunnel that claims the IPv4 and IPv6 default routes, so every flow of the app is
        // handed to us. The DNS server 10.111.0.1 is answered by `Relay`, which forwards each query
        // over TCP through the exit (the proxy for a proxy exit), so no plaintext DNS escapes around it.
        // The remote address is the proxy (the tunnel's real far end), so the system keeps a route
        // to it outside the tunnel in addition to excluding this provider's own traffic.
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: remoteAddress)
        let ipv4 = NEIPv4Settings(addresses: ["10.111.0.2"], subnetMasks: ["255.255.255.255"])
        ipv4.includedRoutes = [NEIPv4Route.default()]
        settings.ipv4Settings = ipv4
        // IPv6 is captured too, so IPv6 literals cannot bypass the tunnel; Relay refuses it (IPv4-only datapath).
        let ipv6 = NEIPv6Settings(addresses: ["fd00::2"], networkPrefixLengths: [128])
        ipv6.includedRoutes = [NEIPv6Route.default()]
        settings.ipv6Settings = ipv6
        settings.mtu = 1400
        settings.dnsSettings = NEDNSSettings(servers: ["10.111.0.1"])

        do {
            try await setTunnelNetworkSettings(settings)
        } catch {
            log.error("setTunnelNetworkSettings failed: \(error.localizedDescription, privacy: .public)")
            throw error // fail-closed: the app sees the tunnel not come up and gives the profile no network
        }

        let relay = Relay(exit: exit, dropUDP: udpDropped, packetFlow: packetFlow, log: log)
        self.relay = relay
        relay.start()
    }

    override func stopTunnel(with reason: NEProviderStopReason) async {
        log.notice("stopTunnel reason=\(reason.rawValue, privacy: .public)")
        relay?.stop()
        relay = nil
    }

    /// IPv4 addresses of `host` (an IP literal resolves to itself), in host byte order, via the
    /// ordinary resolver. Only called before `setTunnelNetworkSettings`.
    private static func resolveIPv4(_ host: String) async -> [UInt32] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var hints = addrinfo()
                hints.ai_family = AF_INET
                hints.ai_socktype = SOCK_STREAM
                var list: UnsafeMutablePointer<addrinfo>?
                guard getaddrinfo(host, nil, &hints, &list) == 0, let first = list else {
                    continuation.resume(returning: [])
                    return
                }
                defer { freeaddrinfo(first) }
                var addresses: [UInt32] = []
                var node: UnsafeMutablePointer<addrinfo>? = first
                while let entry = node {
                    if entry.pointee.ai_family == AF_INET, let sockaddr = entry.pointee.ai_addr {
                        let raw = sockaddr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
                        let address = UInt32(bigEndian: raw)
                        if !addresses.contains(address) { addresses.append(address) }
                    }
                    node = entry.pointee.ai_next
                }
                continuation.resume(returning: addresses)
            }
        }
    }

    private static func dotted(_ address: UInt32) -> String {
        [address >> 24, (address >> 16) & 0xff, (address >> 8) & 0xff, address & 0xff].map(String.init).joined(separator: ".")
    }

    private static func keychainPassword(_ reference: Data?) -> String? {
        guard let reference else { return nil }
        var item: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass: kSecClassGenericPassword,
            kSecValuePersistentRef: reference,
            kSecReturnData: true,
        ] as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    enum TunnelError: Error { case noConfiguration, proxyUnresolvable }
}
