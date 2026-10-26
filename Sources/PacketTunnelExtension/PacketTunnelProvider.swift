import Foundation
import NetworkExtension
import os
import TunnelCore
import TunnelTransport

/// The packet tunnel of PrivacyBrowser: a WebRTC relay for every running profile that has a
/// SOCKS5 proxy, so a page's WebRTC (STUN, TURN, media) leaves through that profile's proxy
/// instead of being switched off.
///
/// It routes only a virtual subnet (192.0.2.0/24 and a unique-local /64, `TunnelAddressing`):
/// the pages are pointed at a TURN server on a virtual address of that subnet, one per profile,
/// and nothing else on the Mac — other apps, DNS, the profiles' own TCP to their proxies — is
/// routed into the tunnel. Each profile's allocations relay through its own SOCKS5 UDP
/// association; profiles with different proxies run side by side.
///
/// The app registers a route per profile launch with `TunnelControlMessage` over
/// `sendProviderMessage`, and registers them again whenever the tunnel (re)connects.
///
/// Info.plist names it module-qualified (`PacketTunnelExtension.PacketTunnelProvider`), as Apple
/// documents; NetworkExtension instantiates it after `startSystemExtensionMode()` (main.swift).
final class PacketTunnelProvider: NEPacketTunnelProvider {
    private let queue = DispatchQueue(label: "PrivacyBrowser.PacketTunnel")
    private let logger = Logger(subsystem: "PrivacyBrowser.PacketTunnel", category: "tunnel")
    private var router: PacketRouter?
    private var expiryTimer: DispatchSourceTimer?
    private var reading = false
    /// The app sends a message every minute while it has routes here. Uptime, not wall-clock
    /// time: a Mac's sleep does not count.
    private var lastAppMessage = DispatchTime.now()
    /// Routes the app stopped tending this long ago — it crashed or was force-quit — are dropped
    /// and the tunnel stops: nothing is left answering for a profile that no longer runs. Generous,
    /// as App Nap may delay the app's timer.
    static let heartbeatTimeout: TimeInterval = 600

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        logger.notice("startTunnel")
        // A split tunnel: only the relays' subnet. No DNS settings, so name resolution is unchanged.
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        let ipv4 = NEIPv4Settings(addresses: [TunnelAddressing.ipv4Interface.description], subnetMasks: [TunnelAddressing.ipv4Mask])
        ipv4.includedRoutes = [NEIPv4Route(destinationAddress: TunnelAddressing.ipv4Network.description, subnetMask: TunnelAddressing.ipv4Mask)]
        settings.ipv4Settings = ipv4
        let ipv6 = NEIPv6Settings(addresses: [TunnelAddressing.ipv6Interface.description],
                                  networkPrefixLengths: [NSNumber(value: TunnelAddressing.ipv6PrefixLength)])
        ipv6.includedRoutes = [NEIPv6Route(destinationAddress: TunnelAddressing.ipv6Network.description,
                                           networkPrefixLength: NSNumber(value: TunnelAddressing.ipv6PrefixLength))]
        settings.ipv6Settings = ipv6
        settings.mtu = 1500

        setTunnelNetworkSettings(settings) { [weak self] error in
            guard let self else { return }
            if let error {
                self.logger.error("setTunnelNetworkSettings: \(error.localizedDescription, privacy: .public)")
                completionHandler(error)
                return
            }
            self.queue.async {
                self.startRouter()
                completionHandler(nil)
            }
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        logger.notice("stopTunnel reason=\(reason.rawValue, privacy: .public)")
        queue.async {
            self.expiryTimer?.cancel()
            self.expiryTimer = nil
            self.router?.unregisterAll()
            self.router = nil
            self.reading = false
            completionHandler()
        }
    }

    /// Control messages from the app: register / unregister a profile's route, status.
    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        queue.async {
            self.lastAppMessage = DispatchTime.now()
            var reply = TunnelStatusReply(routes: self.router?.routeIDs ?? [], allocations: self.router?.allocationCount ?? 0)
            do {
                guard let router = self.router else { throw ProviderError.notRunning }
                switch try TunnelControlMessage.decode(messageData) {
                case let .register(route): router.register(route)
                case let .unregister(id): router.unregister(id: id)
                case .status: break
                }
                reply = TunnelStatusReply(routes: router.routeIDs, allocations: router.allocationCount)
            } catch {
                reply.error = String(describing: error)
            }
            completionHandler?(try? JSONEncoder().encode(reply))
        }
    }

    // MARK: Packets

    private func startRouter() {
        let relays = SOCKS5RelayFactory(queue: queue, log: { [logger] in logger.info("\($0, privacy: .public)") })
        router = PacketRouter(relays: relays, emit: { [weak self] packet in
            guard let self, let version = packet.first.map({ $0 >> 4 }) else { return }
            let family = NSNumber(value: version == 6 ? AF_INET6 : AF_INET)
            self.packetFlow.writePackets([Data(packet)], withProtocols: [family])
        }, log: { [logger] in logger.info("\($0, privacy: .public)") })
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 10, repeating: 10)
        timer.setEventHandler { [weak self] in
            guard let self, let router = self.router else { return }
            router.expire()
            let silent = Double(DispatchTime.now().uptimeNanoseconds - self.lastAppMessage.uptimeNanoseconds) / 1e9
            if !router.routeIDs.isEmpty, silent > Self.heartbeatTimeout {
                self.logger.notice("no message from the app for \(Int(Self.heartbeatTimeout)) s: stopping")
                router.unregisterAll()
                self.cancelTunnelWithError(nil)
            }
        }
        timer.resume()
        expiryTimer = timer
        lastAppMessage = DispatchTime.now()
        reading = true
        readPackets()
    }

    private func readPackets() {
        packetFlow.readPackets { [weak self] packets, _ in
            guard let self else { return }
            self.queue.async {
                guard self.reading, let router = self.router else { return }
                for packet in packets { router.handlePacket([UInt8](packet)) }
                self.readPackets()
            }
        }
    }

    enum ProviderError: Error { case notRunning }
}
