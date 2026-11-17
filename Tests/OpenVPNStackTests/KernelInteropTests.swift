#if canImport(Glibc)
import Glibc
import Foundation
import XCTest
@testable import OpenVPNStack

/// The tunnel's stack against Linux's own TCP/IP: the packet socket pair is bridged to a TUN
/// device, so the far side of the "tunnel" is the kernel — real TCP with its window scaling,
/// SACK, timestamps and delayed acknowledgements, real UDP, real ICMP. Needs root (a TUN device
/// and its address); skipped without (CI's container). Run where root is at hand:
/// `swift test --filter KernelInteropTests` as root.
final class KernelInteropTests: XCTestCase {
    private static let device = "lumenovpn0"
    private static let farAddress = "10.99.0.1"
    private static let stackAddress = "10.99.0.2"

    private var tun: Int32 = -1
    private var bridgeStop = false
    private var bridge: Thread?

    override func setUpWithError() throws {
        guard getuid() == 0, access("/dev/net/tun", R_OK | W_OK) == 0 else {
            throw XCTSkip("needs root and /dev/net/tun")
        }
        tun = Self.openTun(Self.device)
        guard tun >= 0 else { throw XCTSkip("no TUN device could be made here") }
        guard system("ip addr add \(Self.farAddress)/24 dev \(Self.device) && ip link set \(Self.device) up mtu 1500") == 0 else {
            close(tun)
            throw XCTSkip("the TUN device could not be configured")
        }
    }

    override func tearDown() {
        bridgeStop = true
        Thread.sleep(forTimeInterval: 0.2)
        if tun >= 0 { close(tun) }
        _ = system("ip link del \(Self.device) 2>/dev/null")
    }

    private static func openTun(_ name: String) -> Int32 {
        let descriptor = open("/dev/net/tun", O_RDWR)
        guard descriptor >= 0 else { return -1 }
        var request = [UInt8](repeating: 0, count: 40) // struct ifreq
        for (index, byte) in name.utf8.enumerated() { request[index] = byte }
        let flags: UInt16 = 0x0001 | 0x1000 // IFF_TUN | IFF_NO_PI
        request[16] = UInt8(flags & 0xFF)
        request[17] = UInt8(flags >> 8)
        let TUNSETIFF: UInt = 0x400454CA
        let result = ioctl(descriptor, TUNSETIFF, &request)
        guard result == 0 else { close(descriptor); return -1 }
        return descriptor
    }

    /// Packets both ways between the stack's far end of the pair and the TUN device.
    private func startBridge(far: Int32) {
        let tun = self.tun
        let thread = Thread { [unowned self] in
            var buffer = [UInt8](repeating: 0, count: 65_536)
            var entries = [pollfd(fd: far, events: Int16(POLLIN), revents: 0), pollfd(fd: tun, events: Int16(POLLIN), revents: 0)]
            while !self.bridgeStop {
                entries[0].revents = 0
                entries[1].revents = 0
                guard poll(&entries, 2, 100) > 0 else { continue }
                if entries[0].revents & Int16(POLLIN) != 0 {
                    let count = buffer.withUnsafeMutableBytes { recv(far, $0.baseAddress, $0.count, Int32(MSG_DONTWAIT)) }
                    if count > 0 { _ = buffer.withUnsafeBytes { write(tun, $0.baseAddress, count) } }
                }
                if entries[1].revents & Int16(POLLIN) != 0 {
                    let count = buffer.withUnsafeMutableBytes { read(tun, $0.baseAddress, $0.count) }
                    if count > 0 { _ = buffer.withUnsafeBytes { send(far, $0.baseAddress, count, 0) } }
                }
            }
        }
        thread.start()
        bridge = thread
    }

    /// A kernel TCP server on the far address: sends `payload`, then reads everything the client
    /// sends and records it, then closes.
    private func serve(port: inout UInt16, payload: [UInt8], received: @escaping ([UInt8]) -> Void) {
        let (listening, chosen) = TestSockets.listener(address: Self.farAddress)
        port = chosen
        Thread {
            let connection = accept(listening, nil, nil)
            close(listening)
            guard connection >= 0 else { return }
            TestSockets.setTimeout(connection, seconds: 30)
            TestSockets.sendAll(connection, payload)
            shutdown(connection, Int32(SHUT_WR))
            let (bytes, _) = TestSockets.receiveToEnd(connection)
            received(bytes)
            close(connection)
        }.start()
    }

    /// A DNS server on the far address that answers every A question with `answer`, and records
    /// who asked.
    private func serveDNS(answer: [UInt8], askedFrom: @escaping (String) -> Void) -> Int32 {
        let descriptor = socket(AF_INET, TestSockets.datagram, 0)
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(53).bigEndian
        inet_pton(AF_INET, Self.farAddress, &address.sin_addr)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        precondition(bound == 0)
        TestSockets.setTimeout(descriptor, seconds: 1)
        Thread { [unowned self] in
            var buffer = [UInt8](repeating: 0, count: 2048)
            while !self.bridgeStop {
                var from = sockaddr_storage()
                var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
                let count = withUnsafeMutablePointer(to: &from) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(descriptor, &buffer, buffer.count, 0, $0, &length) }
                }
                guard count > 12 else { continue }
                if let sender = TunnelSystem.endpoint(of: from) { askedFrom("\(sender.address)") }
                let response = FakeDNS.answer(Array(buffer[0..<count]), with: answer)
                _ = withUnsafePointer(to: &from) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(descriptor, response, response.count, 0, $0, length) }
                }
            }
            close(descriptor)
        }.start()
        return descriptor
    }

    func testLargeTransfersBothWaysAgainstLinuxTCP() throws {
        let (stackEnd, farEnd) = TestSockets.packetPair()
        let (listening, port) = TestSockets.listener()
        let server = ServerThread(TunnelServer(settings: TestSockets.settings(packet: stackEnd, listening: listening), watchParent: false))
        startBridge(far: farEnd)
        defer { server.stop(); close(listening); close(stackEnd); close(farEnd) }

        let download = TestSockets.random(count: 8 << 20)
        let upload = TestSockets.random(count: 4 << 20)
        var farPort: UInt16 = 0
        let uploaded = expectation(description: "the far side read the upload")
        var receivedByFar: [UInt8] = []
        serve(port: &farPort, payload: download) { bytes in
            receivedByFar = bytes
            uploaded.fulfill()
        }
        let client = TestSockets.connect(to: "127.0.0.1", port: port)
        defer { close(client) }
        let reply = TestSockets.socksConnect(client, username: TestSockets.username, password: TestSockets.password,
                                             request: TestSockets.connectRequest(ipv4: [10, 99, 0, 1], port: farPort))
        XCTAssertEqual(reply.reply, 0)
        let writer = Thread {
            TestSockets.sendAll(client, upload)
            shutdown(client, Int32(SHUT_WR))
        }
        writer.start()
        let (bytes, ended) = TestSockets.receiveToEnd(client)
        XCTAssertTrue(ended, "the far side's FIN reached the client")
        XCTAssertEqual(bytes.count, download.count)
        XCTAssertTrue(bytes == download, "the download arrived intact")
        wait(for: [uploaded], timeout: 60)
        XCTAssertEqual(receivedByFar.count, upload.count)
        XCTAssertTrue(receivedByFar == upload, "the upload arrived intact")
    }

    func testNamesAreAskedOfTheTunnelsServerFromTheTunnelsAddress() throws {
        let (stackEnd, farEnd) = TestSockets.packetPair()
        let (listening, port) = TestSockets.listener()
        let server = ServerThread(TunnelServer(settings: TestSockets.settings(packet: stackEnd, listening: listening), watchParent: false))
        startBridge(far: farEnd)
        var askers: [String] = []
        let lock = NSLock()
        _ = serveDNS(answer: [10, 99, 0, 1]) { asker in lock.lock(); askers.append(asker); lock.unlock() }
        defer { server.stop(); close(listening); close(stackEnd); close(farEnd) }

        var farPort: UInt16 = 0
        let payload = Array("hello through the tunnel".utf8)
        serve(port: &farPort, payload: payload) { _ in }
        let client = TestSockets.connect(to: "127.0.0.1", port: port)
        defer { close(client) }
        let reply = TestSockets.socksConnect(client, username: TestSockets.username, password: TestSockets.password,
                                             request: TestSockets.connectRequest(name: "only-in-the-tunnel.test", port: farPort))
        XCTAssertEqual(reply.reply, 0)
        shutdown(client, Int32(SHUT_WR))
        XCTAssertEqual(TestSockets.receiveToEnd(client).bytes, payload)
        lock.lock()
        XCTAssertEqual(Set(askers), [Self.stackAddress], "the question came through the tunnel, from its address")
        lock.unlock()
    }

    func testAReceivedResetIsTheClientsRefusal() throws {
        let (stackEnd, farEnd) = TestSockets.packetPair()
        let (listening, port) = TestSockets.listener()
        let server = ServerThread(TunnelServer(settings: TestSockets.settings(packet: stackEnd, listening: listening), watchParent: false))
        startBridge(far: farEnd)
        defer { server.stop(); close(listening); close(stackEnd); close(farEnd) }
        let client = TestSockets.connect(to: "127.0.0.1", port: port)
        defer { close(client) }
        // Nothing listens on port 9 of the far address: Linux answers the SYN with a reset.
        let reply = TestSockets.socksConnect(client, username: TestSockets.username, password: TestSockets.password,
                                             request: TestSockets.connectRequest(ipv4: [10, 99, 0, 1], port: 9))
        XCTAssertEqual(reply.reply, SOCKS5Server.Reply.connectionRefused.rawValue)
    }
}
#endif
