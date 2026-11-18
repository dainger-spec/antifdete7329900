#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import XCTest
import OpenVPNLink

/// The forwarders that are OpenVPN's only way to its servers: each carries to its one target,
/// UDP only for the first local sender, TCP both ways with its ends passed on.
final class LoopbackForwardersTests: XCTestCase {
    private func udpSocket(bindTo port: UInt16 = 0) -> (Int32, UInt16) {
        let descriptor = socket(AF_INET, TestSockets.datagram, 0)
        var storage = sockaddr_storage()
        let length = TunnelSystem.fill(&storage, address: TunnelAddress("127.0.0.1")!, port: port)
        _ = withUnsafePointer(to: &storage) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { systemBind(descriptor, $0, length) } }
        TestSockets.setTimeout(descriptor, seconds: 3)
        return (descriptor, TunnelSystem.localAddress(descriptor)!.port)
    }

    private func sendTo(_ descriptor: Int32, port: UInt16, _ bytes: [UInt8]) {
        var storage = sockaddr_storage()
        let length = TunnelSystem.fill(&storage, address: TunnelAddress("127.0.0.1")!, port: port)
        _ = withUnsafePointer(to: &storage) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(descriptor, bytes, bytes.count, 0, $0, length) } }
    }

    private func receive(_ descriptor: Int32) -> [UInt8]? {
        var buffer = [UInt8](repeating: 0, count: 2048)
        let count = recv(descriptor, &buffer, buffer.count, 0)
        return count > 0 ? Array(buffer[0..<count]) : nil
    }

    func testUDPGoesToItsTargetAndComesBackToItsFirstSenderOnly() throws {
        let (server, serverPort) = udpSocket()
        defer { close(server) }
        let forwarders = try LoopbackForwarders(targets: [.init(address: TunnelAddress("127.0.0.1")!, port: serverPort, transport: .udp)])
        defer { forwarders.stop() }
        let (client, _) = udpSocket()
        let (intruder, _) = udpSocket()
        defer { close(client); close(intruder) }

        sendTo(client, port: forwarders.ports[0], Array("hello".utf8))
        // The server sees it from the forwarder's own socket, and answers there.
        var from = sockaddr_storage()
        var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
        var buffer = [UInt8](repeating: 0, count: 2048)
        let count = withUnsafeMutablePointer(to: &from) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(server, &buffer, buffer.count, 0, $0, &length) } }
        XCTAssertEqual(Array(buffer[0..<max(0, count)]), Array("hello".utf8))
        _ = withUnsafePointer(to: &from) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(server, Array("answer".utf8), 6, 0, $0, length) } }
        XCTAssertEqual(receive(client), Array("answer".utf8))

        // Another sender on this Mac is not carried, and gets nothing back.
        sendTo(intruder, port: forwarders.ports[0], Array("intrude".utf8))
        Thread.sleep(forTimeInterval: 0.3)
        var pending = pollfd(fd: server, events: Int16(POLLIN), revents: 0)
        XCTAssertEqual(poll(&pending, 1, 300), 0, "nothing reached the server from the second sender")
        XCTAssertEqual(forwarders.currentCounts.refused, 1)
    }

    func testTCPCarriesBothWaysAndPassesEachEndOn() throws {
        let (listener, port) = TestSockets.listener()
        defer { close(listener) }
        let payload = TestSockets.random(count: 2 << 20)
        let upload = TestSockets.random(count: 1 << 20)
        let served = expectation(description: "the server read the client's bytes to their end")
        var received: [UInt8] = []
        Thread {
            let connection = accept(listener, nil, nil)
            TestSockets.setTimeout(connection, seconds: 20)
            TestSockets.sendAll(connection, payload)
            shutdown(connection, Int32(SHUT_WR))
            received = TestSockets.receiveToEnd(connection).bytes
            close(connection)
            served.fulfill()
        }.start()
        let forwarders = try LoopbackForwarders(targets: [.init(address: TunnelAddress("127.0.0.1")!, port: port, transport: .tcp)])
        defer { forwarders.stop() }
        let client = TestSockets.connect(to: "127.0.0.1", port: forwarders.ports[0])
        defer { close(client) }
        Thread {
            TestSockets.sendAll(client, upload)
            shutdown(client, Int32(SHUT_WR))
        }.start()
        let (bytes, ended) = TestSockets.receiveToEnd(client)
        XCTAssertTrue(ended)
        XCTAssertTrue(bytes == payload)
        wait(for: [served], timeout: 20)
        XCTAssertTrue(received == upload)
    }

    func testATargetThatRefusesEndsTheClientsConnection() throws {
        // A port nothing listens on: the forwarder's connection is refused, and so is the client's.
        let (probe, port) = TestSockets.listener()
        close(probe)
        let forwarders = try LoopbackForwarders(targets: [.init(address: TunnelAddress("127.0.0.1")!, port: port, transport: .tcp)])
        defer { forwarders.stop() }
        let client = TestSockets.connect(to: "127.0.0.1", port: forwarders.ports[0])
        defer { close(client) }
        let (bytes, ended) = TestSockets.receiveToEnd(client)
        XCTAssertTrue(bytes.isEmpty)
        XCTAssertTrue(ended)
    }

    func testStoppedForwardersCloseTheirPorts() throws {
        let forwarders = try LoopbackForwarders(targets: [.init(address: TunnelAddress("127.0.0.1")!, port: 9, transport: .tcp)])
        let port = forwarders.ports[0]
        forwarders.stop()
        Thread.sleep(forTimeInterval: 1.5)
        let descriptor = socket(AF_INET, TestSockets.stream, 0)
        defer { close(descriptor) }
        var storage = sockaddr_storage()
        let length = TunnelSystem.fill(&storage, address: TunnelAddress("127.0.0.1")!, port: port)
        let result = withUnsafePointer(to: &storage) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Glibc_connect(descriptor, $0, length) } }
        XCTAssertNotEqual(result, 0, "nothing listens there any more")
    }
}
