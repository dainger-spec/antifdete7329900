import Foundation
import NetworkExtension
import os

/// The packet datapath of the tunnel: reads captured IP packets from the `NEPacketTunnelFlow`,
/// and relays their flows to the exit. UDP is dropped when the exit cannot carry it.
///
/// SCOPE — this is the part that needs hardware testing (see ../docs/NETWORK.md); it cannot run in
/// CI. What is complete: the read loop, the UDP-drop policy (so UDP never leaks), and the exit
/// model. What needs validation on a Mac: full TCP/IP flow reassembly and the SOCKS5/HTTP relay,
/// including SOCKS5 UDP ASSOCIATE for the `throughProxy` case. Until a flow's relay is wired, its
/// packets are dropped — never sent in the clear — so the fail-closed guarantee holds even while
/// the datapath is incomplete.
final class Relay {
    enum Exit {
        case proxy(host: String, port: Int, socks: Bool, tls: Bool, username: String?, password: String?)
        case directInterface
    }

    private let exit: Exit
    private let dropUDP: Bool
    private let packetFlow: NEPacketTunnelFlow
    private let log: Logger
    private var running = false

    init(exit: Exit, dropUDP: Bool, packetFlow: NEPacketTunnelFlow, log: Logger) {
        self.exit = exit
        self.dropUDP = dropUDP
        self.packetFlow = packetFlow
        self.log = log
    }

    func start() {
        running = true
        readLoop()
    }

    func stop() {
        running = false
    }

    /// Pulls batches of IP packets and dispatches each to its flow relay. `protocols[i]` is the
    /// address family of `packets[i]` (`AF_INET` / `AF_INET6`).
    private func readLoop() {
        packetFlow.readPackets { [weak self] packets, protocols in
            guard let self, self.running else { return }
            for (packet, family) in zip(packets, protocols) {
                self.handle(packet, family: family.int32Value)
            }
            self.readLoop() // re-arm
        }
    }

    private func handle(_ packet: Data, family: Int32) {
        // IP protocol number: IPv4 byte 9, IPv6 next-header byte 6.
        let isUDP: Bool
        if family == AF_INET, packet.count > 9 {
            isUDP = packet[packet.startIndex + 9] == 17
        } else if family == AF_INET6, packet.count > 6 {
            isUDP = packet[packet.startIndex + 6] == 17
        } else {
            isUDP = false
        }
        if isUDP && (dropUDP || !udpRelayActive) {
            return // dropped, not leaked — QUIC falls back to TCP, WebRTC gets no candidates
        }
        // TODO(datapath, needs hardware): reassemble the flow and relay it to `exit`. Until the
        // relay for this flow is active, drop rather than leak.
        relay(packet, family: family, isUDP: isUDP)
    }

    /// Whether the UDP-to-exit relay (SOCKS5 UDP ASSOCIATE, or direct) is wired for this exit.
    private var udpRelayActive: Bool {
        if case .directInterface = exit { return false } // see scope note; not yet wired
        return false
    }

    private func relay(_ packet: Data, family: Int32, isUDP: Bool) {
        // Datapath boundary: see the scope note. No packet is forwarded in the clear from here
        // yet, so nothing bypasses the intended exit.
    }
}
