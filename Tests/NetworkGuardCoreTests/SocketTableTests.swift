import Foundation
import XCTest
@testable import NetworkGuardCore
#if canImport(Darwin)
import Darwin
#endif

/// The kernel's table of sockets (SocketTable) and whom the guard holds a flow for
/// (GuardAttribution) — the owner's Mac, 4 November: every packet of the probe's STUN request
/// counted by the kernel for the probe (`eproc LumenProfile:1738`), the filter given WebKit's network
/// process (1741) as its source application, and the guard letting it through.
final class SocketTableTests: XCTestCase {
    // MARK: A table's bytes, laid out as xnu's sysctl writes them

    private func put32(_ value: UInt32, _ bytes: inout [UInt8], _ offset: Int) {
        for index in 0..<4 { bytes[offset + index] = UInt8((value >> (8 * UInt32(index))) & 0xff) }
    }

    private func header() -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 24)
        put32(24, &bytes, 0)
        put32(1, &bytes, 4)
        return bytes
    }

    /// xinpcb_n, xsocket_n, two xsockbuf_n and an xsockstat_n, as in_pcblist.c writes one socket.
    private func socket(localPort: UInt16, remotePort: UInt16, local: [UInt8], remote: [UInt8], ipv6: Bool = false,
                        lastPID: Int32, effectivePID: Int32, flags: UInt32) -> [UInt8] {
        var inpcb = [UInt8](repeating: 0, count: 104)
        put32(104, &inpcb, 0)
        put32(0x10, &inpcb, 4)
        inpcb[16] = UInt8(remotePort >> 8); inpcb[17] = UInt8(remotePort & 0xff)
        inpcb[18] = UInt8(localPort >> 8); inpcb[19] = UInt8(localPort & 0xff)
        inpcb[44] = ipv6 ? 0x2 : 0x1
        let foreignStart = remote.count == 4 ? 60 : 48
        let localStart = local.count == 4 ? 76 : 64
        for (index, byte) in remote.enumerated() { inpcb[foreignStart + index] = byte }
        for (index, byte) in local.enumerated() { inpcb[localStart + index] = byte }
        var xsocket = [UInt8](repeating: 0, count: 104)
        put32(104, &xsocket, 0)
        put32(0x1, &xsocket, 4)
        put32(UInt32(bitPattern: lastPID), &xsocket, 68)
        put32(UInt32(bitPattern: effectivePID), &xsocket, 72)
        put32(flags, &xsocket, 84)
        var buffers: [UInt8] = []
        for kind in [UInt32(0x2), 0x4] {
            var buffer = [UInt8](repeating: 0, count: 32)
            put32(28, &buffer, 0)   // a length padded to 8 bytes by the reader
            put32(kind, &buffer, 4)
            buffers += buffer
        }
        var stats = [UInt8](repeating: 0, count: 136)
        put32(136, &stats, 0)
        put32(0x8, &stats, 4)
        return inpcb + xsocket + buffers + stats
    }

    private let delegated: UInt32 = 0x1000_0000

    /// The owner's probe: WebKit's network process (1741) sending for the probe (1738), and a socket
    /// of its own beside it.
    private func ownersTable() -> [UInt8] {
        header()
            + socket(localPort: 61656, remotePort: 3478, local: [198, 18, 0, 1], remote: [203, 0, 113, 1],
                     lastPID: 1741, effectivePID: 1738, flags: delegated | 0x4)
            + socket(localPort: 5353, remotePort: 0, local: [], remote: [], lastPID: 1741, effectivePID: 1741, flags: 0)
            + header()
    }

    func testTheOwnersProbeSocketReadsAsCountedForTheProbe() throws {
        let sockets = try XCTUnwrap(SocketTable.parse(ownersTable(), transport: .udp))
        XCTAssertEqual(sockets.count, 2)
        let probe = sockets[0]
        XCTAssertEqual(probe.localPort, 61656)
        XCTAssertEqual(probe.localAddress, "198.18.0.1")
        XCTAssertEqual(probe.remoteAddress, "203.0.113.1")
        XCTAssertEqual(probe.remotePort, 3478)
        XCTAssertEqual(probe.lastPID, 1741)
        XCTAssertTrue(probe.delegated)
        XCTAssertEqual(probe.countedFor, 1738)
        let own = sockets[1]
        XCTAssertNil(own.localAddress)
        XCTAssertNil(own.remoteAddress)
        XCTAssertFalse(own.delegated)
        XCTAssertEqual(own.countedFor, 1741)
    }

    func testAnEffectivePIDWithoutTheDelegatedFlagIsNotTaken() throws {
        let bytes = header()
            + socket(localPort: 4000, remotePort: 3478, local: [10, 0, 0, 2], remote: [203, 0, 113, 1],
                     lastPID: 500, effectivePID: 600, flags: 0)
            + header()
        let socket = try XCTUnwrap(SocketTable.parse(bytes, transport: .udp)?.first)
        XCTAssertFalse(socket.delegated)
        XCTAssertEqual(socket.countedFor, 500)
    }

    func testIPv6AndMappedAddresses() throws {
        var v6Local = [UInt8](repeating: 0, count: 16); v6Local[0] = 0x20; v6Local[1] = 0x01; v6Local[2] = 0x0d; v6Local[3] = 0xb8; v6Local[15] = 1
        var mapped = [UInt8](repeating: 0, count: 16); mapped[10] = 0xff; mapped[11] = 0xff
        mapped[12] = 203; mapped[13] = 0; mapped[14] = 113; mapped[15] = 1
        let bytes = header()
            + socket(localPort: 4001, remotePort: 3478, local: v6Local, remote: mapped, ipv6: true,
                     lastPID: 10, effectivePID: 11, flags: delegated)
            + header()
        let socket = try XCTUnwrap(SocketTable.parse(bytes, transport: .udp)?.first)
        XCTAssertEqual(socket.localAddress, GuardPolicy.canonicalAddress("2001:db8::1"))
        XCTAssertEqual(socket.remoteAddress, "203.0.113.1")
        XCTAssertEqual(socket.countedFor, 11)
    }

    func testBytesThatAreNotTheLayoutAreRefusedNeverReadPast() {
        XCTAssertNil(SocketTable.parse([], transport: .udp))
        XCTAssertNil(SocketTable.parse([UInt8](repeating: 0, count: 24), transport: .udp), "a header that does not say 24")
        // A record cut short of the layout it says it is.
        var short = header() + socket(localPort: 1, remotePort: 2, local: [1, 2, 3, 4], remote: [5, 6, 7, 8],
                                      lastPID: 1, effectivePID: 1, flags: 0)
        put32(96, &short, 24)
        XCTAssertNil(SocketTable.parse(short, transport: .udp))
        // A record that says it runs past the end.
        var long = header() + socket(localPort: 1, remotePort: 2, local: [1, 2, 3, 4], remote: [5, 6, 7, 8],
                                     lastPID: 1, effectivePID: 1, flags: 0)
        long = Array(long.prefix(24 + 150))
        XCTAssertNil(SocketTable.parse(long, transport: .udp))
    }

    func testTheFlowsSocketIsTheOneConnectedToItsRemoteEndElseOneNotConnected() throws {
        let bytes = header()
            + socket(localPort: 7000, remotePort: 0, local: [], remote: [], lastPID: 1741, effectivePID: 1741, flags: 0)
            + socket(localPort: 7000, remotePort: 3478, local: [10, 0, 0, 2], remote: [203, 0, 113, 1],
                     lastPID: 1741, effectivePID: 1738, flags: delegated)
            + socket(localPort: 7001, remotePort: 3478, local: [10, 0, 0, 2], remote: [203, 0, 113, 1],
                     lastPID: 900, effectivePID: 901, flags: delegated)
            + header()
        let sockets = try XCTUnwrap(SocketTable.parse(bytes, transport: .udp))
        let connected = SocketTable.socket(of: .udp, localPort: 7000, remoteAddress: "203.0.113.1", remotePort: 3478,
                                           openerPID: 1741, in: sockets)
        XCTAssertEqual(connected?.countedFor, 1738)
        let unconnected = SocketTable.socket(of: .udp, localPort: 7000, remoteAddress: "203.0.113.9", remotePort: 3478,
                                             openerPID: 1741, in: sockets)
        XCTAssertEqual(unconnected?.remoteAddress, nil)
        XCTAssertEqual(unconnected?.countedFor, 1741)
        XCTAssertNil(SocketTable.socket(of: .tcp, localPort: 7000, remoteAddress: "203.0.113.1", remotePort: 3478,
                                        openerPID: 1741, in: sockets), "another transport")
        XCTAssertNil(SocketTable.socket(of: .udp, localPort: 7002, remoteAddress: "203.0.113.1", remotePort: 3478,
                                        openerPID: 1741, in: sockets), "nothing on that port")
        XCTAssertNil(SocketTable.socket(of: .udp, localPort: 0, remoteAddress: "203.0.113.1", remotePort: 3478,
                                        openerPID: 1741, in: sockets), "a flow with no local port yet")
    }

    // MARK: Whom the guard holds a flow for

    private func probeSocket(delegated: Bool) -> KernelSocket {
        KernelSocket(transport: .udp, localAddress: "198.18.0.1", localPort: 61656, remoteAddress: "203.0.113.1",
                     remotePort: 3478, lastPID: 1741, effectivePID: 1738, delegated: delegated)
    }

    func testAFlowOfAHeldSourceApplicationIsItsHoldersBySourceApplication() {
        let holder = GuardAttribution.holder(appPID: 1738, socket: nil, isHeld: { $0 == 1738 })
        XCTAssertEqual(holder?.pid, 1738)
        XCTAssertEqual(holder?.source, .sourceApplication)
    }

    /// The owner's Mac, 4 November: the filter's source application WebKit's network process, the
    /// kernel's record the probe's. The guard holds it as the probe's.
    func testTheOwnersProbeFlowIsTheProbesByTheKernelsRecord() {
        let holder = GuardAttribution.holder(appPID: 1741, socket: probeSocket(delegated: true), isHeld: { $0 == 1738 })
        XCTAssertEqual(holder?.pid, 1738, "the kernel counts the socket for the probe, which the guard holds")
        XCTAssertEqual(holder?.source, .kernelSocket)
        let noToken = GuardAttribution.holder(appPID: nil, socket: probeSocket(delegated: true), isHeld: { $0 == 1738 })
        XCTAssertEqual(noToken?.pid, 1738, "without a source application's token, the kernel's record still says")
    }

    func testNotHeldWhenNeitherAnswerNamesAHeldProcess() {
        XCTAssertNil(GuardAttribution.holder(appPID: 1741, socket: probeSocket(delegated: false), isHeld: { $0 == 1738 }),
                     "not delegated: the socket is the network process's own")
        XCTAssertNil(GuardAttribution.holder(appPID: 1741, socket: probeSocket(delegated: true), isHeld: { $0 == 4242 }),
                     "delegated to a process the guard does not hold (Safari's, say)")
        XCTAssertNil(GuardAttribution.holder(appPID: 1741, socket: nil, isHeld: { $0 == 1738 }), "no record read")
    }

    #if canImport(Darwin)
    // MARK: This Mac's kernel

    /// A UDP socket of this process, connected to a documentation address (nothing is sent): the
    /// table read from the kernel must hold it, with its ports and address, used by this process and
    /// not delegated — the layout read is the kernel's.
    func testThisMacsKernelTableHoldsThisProcesssOwnSocket() throws {
        let descriptor = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { close(descriptor) }
        var remote = sockaddr_in()
        remote.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        remote.sin_family = sa_family_t(AF_INET)
        remote.sin_port = in_port_t(9).bigEndian
        inet_pton(AF_INET, "203.0.113.2", &remote.sin_addr)
        let connected = withUnsafePointer(to: &remote) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        XCTAssertEqual(connected, 0, "connect: errno \(errno)")
        var local = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &local) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
        }
        let port = UInt16(bigEndian: local.sin_port)
        XCTAssertNotEqual(port, 0)
        let sockets: [KernelSocket]
        switch SocketTable.read(.udp) {
        case .success(let read): sockets = read
        case .failure(let error): return XCTFail("the table: \(error)")
        }
        let mine = try XCTUnwrap(SocketTable.socket(of: .udp, localPort: port, remoteAddress: "203.0.113.2", remotePort: 9,
                                                    openerPID: getpid(), in: sockets),
                                 "this process's socket on port \(port) is not in the \(sockets.count) read")
        XCTAssertEqual(mine.remoteAddress, "203.0.113.2")
        XCTAssertEqual(mine.remotePort, 9)
        XCTAssertEqual(mine.lastPID, getpid())
        XCTAssertFalse(mine.delegated)
        XCTAssertEqual(mine.countedFor, getpid())
    }
    #endif
}
