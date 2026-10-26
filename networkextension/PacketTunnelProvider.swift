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

        // A point-to-point IPv4 tunnel that claims the default route, so every flow of the app is
        // handed to us. The DNS server 10.111.0.1 is answered by `Relay`, which forwards each query
        // over TCP through the exit (the proxy for a proxy exit), so no plaintext DNS escapes around it.
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        let ipv4 = NEIPv4Settings(addresses: ["10.111.0.2"], subnetMasks: ["255.255.255.255"])
        ipv4.includedRoutes = [NEIPv4Route.default()]
        settings.ipv4Settings = ipv4
        settings.mtu = 1400
        settings.dnsSettings = NEDNSSettings(servers: ["10.111.0.1"])

        // Resolve the exit; a proxy password (if any) comes from the keychain, not the config.
        let exit: Relay.Exit
        if exitKind == "proxy", let host = config[Key.host], let port = config[Key.port].flatMap(Int.init) {
            let password = Self.keychainPassword(proto.passwordReference)
            exit = .proxy(host: host, port: port, socks: config[Key.proxyKind] == "socks5",
                          tls: config[Key.tls] == "1", username: config[Key.username], password: password)
        } else {
            exit = .directInterface
        }

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

    enum TunnelError: Error { case noConfiguration }
}
