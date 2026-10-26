import Foundation
var failures = 0
func check(_ c: Bool, _ m: String) { print(c ? "PASS" : "FAIL", m); if !c { failures += 1 } }
let client: UInt32 = 0x0A6F0002, server: UInt32 = 0x5DB8D822, proxyIP: UInt32 = 0x0A000001
let log = Logger(subsystem: "", category: "")

final class Harness {
    let flow = NEPacketTunnelFlow(); let relay: Relay
    init(_ exit: Relay.Exit, dropUDP: Bool = false) { relay = Relay(exit: exit, dropUDP: dropUDP, packetFlow: flow, log: log); relay.start(); relay.queue.sync {} }
    func inject(_ p: Data, family: Int32 = AF_INET, wait: Double = 0.05) { relay.queue.sync {}; flow.reader!([p], [NSNumber(value: family)]); Thread.sleep(forTimeInterval: wait); relay.queue.sync {} }
    func pump(_ s: Double = 0.05) { Thread.sleep(forTimeInterval: s); relay.queue.sync {} }
    func take() -> [(Data, Int32)] { var o: [(Data, Int32)] = []; relay.queue.sync { o = Array(zip(flow.written, flow.writtenFamilies.map { $0.int32Value })); flow.written = []; flow.writtenFamilies = [] }; return o }
    func takeTCP() -> [TCPSegment] { take().compactMap { IPv4Packet($0.0).flatMap(TCPSegment.init) } }
}
func ones(_ x: ArraySlice<UInt8>, _ s: inout UInt32) { var i = x.startIndex; while i + 1 < x.endIndex { s += UInt32(x[i]) << 8 | UInt32(x[i+1]); i += 2 }; if i < x.endIndex { s += UInt32(x[i]) << 8 } }
func fold(_ s: UInt32) -> UInt32 { var s = s; while s >> 16 != 0 { s = (s & 0xffff) + (s >> 16) }; return s }
func checksumOK(_ d: Data) -> Bool {
    let b = [UInt8](d); var s: UInt32 = 0
    ones(b[0..<20], &s); guard fold(s) == 0xffff else { return false }
    var ps: UInt32 = (be32(b,12) >> 16) + (be32(b,12) & 0xffff) + (be32(b,16) >> 16) + (be32(b,16) & 0xffff) + UInt32(b[9]) + UInt32(b.count - 20)
    ones(b[20...], &ps)
    return fold(ps) == 0xffff
}
func checksum6OK(_ d: Data) -> Bool {
    let b = [UInt8](d); guard b.count >= 40 else { return false }
    var s: UInt32 = UInt32(b.count - 40) + UInt32(b[6])
    ones(b[8..<24], &s); ones(b[24..<40], &s); ones(b[40...], &s)
    return fold(s) == 0xffff
}

// 1. Direct UDP echo
do {
    let h = Harness(.directInterface)
    h.inject(PacketBuilder.udp(src: client, srcPort: 5000, dst: server, dstPort: 9999, payload: Array("hi".utf8)), wait: 0.1)
    let out = h.take()
    check(out.count == 1 && checksumOK(out[0].0), "direct UDP: one reply with valid checksums")
    if let p = out.first.map({ IPv4Packet($0.0)! }) {
        let b = p.bytes, o = p.payloadStart
        check(p.src == server && p.dst == client && be16(b, o) == 9999 && be16(b, o+2) == 5000 && Array(b[(o+8)...]) == Array("hi".utf8), "direct UDP: reply addressed back to the app socket")
    }
}
// 2. dropUDP flag on direct exit
do {
    let h = Harness(.directInterface, dropUDP: true)
    h.inject(PacketBuilder.udp(src: client, srcPort: 5000, dst: server, dstPort: 9999, payload: [1]))
    check(h.take().isEmpty, "direct exit with udp=dropped drops UDP")
}
// 3. SOCKS over TLS drops UDP
do {
    proxyLog = []
    let h = Harness(.proxy(Relay.Proxy(host: "p", addresses: [proxyIP], port: 1080, socks: true, tls: true, username: nil, password: nil)))
    h.inject(PacketBuilder.udp(src: client, srcPort: 5000, dst: server, dstPort: 9999, payload: [1]))
    check(h.take().isEmpty && proxyLog.isEmpty, "SOCKS5 over TLS drops UDP without dialling")
}
// 4. SOCKS5 UDP ASSOCIATE
do {
    var phase = 0; proxyLog = []
    proxyScript = { d in
        proxyLog.append(d)
        switch phase {
        case 0: phase = 1; return Data([5, 0])
        case 1: phase = 2; return Data([5, 0, 0, 1, 0, 0, 0, 0, 0x9C, 0x40]) // bound 0.0.0.0:40000
        default: return nil
        }
    }
    let h = Harness(.proxy(Relay.Proxy(host: "p", addresses: [proxyIP], port: 1080, socks: true, tls: false, username: nil, password: nil)))
    h.inject(PacketBuilder.udp(src: client, srcPort: 6000, dst: server, dstPort: 3478, payload: Array("stun".utf8)), wait: 0.3)
    check(proxyLog.count >= 2 && [UInt8](proxyLog[0]) == [5,1,0] && [UInt8](proxyLog[1]) == [5,3,0,1,0,0,0,0,0,0], "SOCKS5 UDP ASSOCIATE request bytes")
    check(proxyLog.count >= 3 && [UInt8](proxyLog[2]) == [0,0,0,1] + bytes32(server) + bytes16(3478) + Array("stun".utf8), "SOCKS5 UDP datagram header + payload")
    let out = h.take()
    check(out.count == 1 && checksumOK(out[0].0), "SOCKS5 UDP reply mapped back: one packet")
    if let p = out.first.map({ IPv4Packet($0.0)! }) {
        let b = p.bytes, o = p.payloadStart
        check(p.src == server && be16(b, o) == 3478 && p.dst == client && be16(b, o+2) == 6000 && Array(b[(o+8)...]) == Array("stun".utf8), "SOCKS5 UDP reply addressed from peer to app socket")
    }
    let before = proxyLog.count
    h.inject(PacketBuilder.udp(src: client, srcPort: 6000, dst: 0x08080808, dstPort: 53, payload: [7]), wait: 0.1)
    check(proxyLog.count == before + 1 && h.take().count == 1, "same app socket reuses the association")
    proxyScript = nil
}
// 5. Pass-through to the proxy itself
do {
    proxyLog = []
    proxyScript = { d in proxyLog.append(d); return nil }
    let h = Harness(.proxy(Relay.Proxy(host: "proxy.example", addresses: [proxyIP], port: 1080, socks: true, tls: false, username: nil, password: nil)))
    h.inject(PacketBuilder.tcp(src: client, srcPort: 40100, dst: proxyIP, dstPort: 1080, seq: 7, ack: 0, flags: TCPFlag.syn, window: 65535))
    let sa = h.takeTCP()
    check(sa.count == 1 && sa[0].flags == TCPFlag.syn | TCPFlag.ack && proxyLog.isEmpty, "flow to the proxy itself: no handshake by the relay")
    let srv = sa[0].seq &+ 1
    h.inject(PacketBuilder.tcp(src: client, srcPort: 40100, dst: proxyIP, dstPort: 1080, seq: 8, ack: srv, flags: TCPFlag.ack | TCPFlag.psh, window: 65535, payload: [5, 1, 0]))
    let data = h.takeTCP().filter { !$0.payload.isEmpty }
    check(data.count == 1 && Array(data[0].payload) == [5, 1, 0] && proxyLog.count == 1, "pass-through relays the app's own SOCKS bytes raw")
    proxyLog = []; var phase = 0
    proxyScript = { d in proxyLog.append(d); phase += 1; return phase == 1 ? Data([5, 0]) : (phase == 2 ? Data([5, 0, 0, 1, 0,0,0,0, 0,0]) : nil) }
    h.inject(PacketBuilder.tcp(src: client, srcPort: 40101, dst: proxyIP, dstPort: 443, seq: 7, ack: 0, flags: TCPFlag.syn, window: 65535), wait: 0.1)
    check(proxyLog.count == 2 && [UInt8](proxyLog[0]) == [5,1,0], "same address, other port: goes through the proxy")
    proxyScript = nil
}
// 6. DNS: proxy's own name answered locally
do {
    proxyLog = []
    proxyScript = { d in proxyLog.append(d); return nil }
    let h = Harness(.proxy(Relay.Proxy(host: "Proxy.Example.", addresses: [proxyIP, 0x0A000002], port: 1080, socks: true, tls: false, username: nil, password: nil)))
    let q: [UInt8] = [0xAB,0xCD, 0x01,0x00, 0,1, 0,0, 0,0, 0,0, 5]+Array("proxy".utf8)+[7]+Array("example".utf8)+[0, 0,1, 0,1]
    h.inject(PacketBuilder.udp(src: client, srcPort: 53010, dst: Relay.gatewayAddress, dstPort: 53, payload: q), wait: 0.1)
    let out = h.take()
    check(out.count == 1 && proxyLog.isEmpty, "proxy name: answered without touching the exit")
    if let p = out.first.map({ IPv4Packet($0.0)! }) {
        let m = Array(p.bytes[(p.payloadStart + 8)...])
        let qe = DNS.questionEnd(q)!
        check(m.count == qe + 32 && be16(m, 6) == 2 && Array(m[(qe+12)..<(qe+16)]) == bytes32(proxyIP) && Array(m[(qe+28)..<(qe+32)]) == bytes32(0x0A000002) && m[2] & 0x80 != 0 && be16(m, 0) == 0xABCD, "proxy name: two A records")
    }
    let q2: [UInt8] = [0x11,0x22, 0x01,0x00, 0,1, 0,0, 0,0, 0,0, 3]+Array("foo".utf8)+[0, 0,1, 0,1]
    h.inject(PacketBuilder.udp(src: client, srcPort: 53011, dst: Relay.gatewayAddress, dstPort: 53, payload: q2), wait: 0.2)
    check(!proxyLog.isEmpty && h.take().count == 1, "other names: forwarded through the exit")
    proxyScript = nil
}
// 7. IPv6 SYN → RST
do {
    let h = Harness(.directInterface)
    var p = [UInt8](repeating: 0, count: 60)
    p[0] = 0x60; p[5] = 20; p[6] = 6; p[7] = 64
    let src: [UInt8] = [0xfd,0,0,0, 0,0,0,0, 0,0,0,0, 0,0,0,2], dst: [UInt8] = [0x26,0x06,0x47,0, 0,0,0,0, 0,0,0,0, 0,0,0x11,0x11]
    p.replaceSubrange(8..<24, with: src); p.replaceSubrange(24..<40, with: dst)
    put16(&p, 40, 51000); put16(&p, 42, 443); put32(&p, 44, 1000); p[52] = 5 << 4; p[53] = TCPFlag.syn; put16(&p, 54, 65535)
    h.inject(Data(p), family: AF_INET6)
    let out = h.take()
    check(out.count == 1 && out[0].1 == AF_INET6, "IPv6 SYN: one IPv6 reply")
    if let r = out.first.map({ [UInt8]($0.0) }) {
        check(r[0] >> 4 == 6 && Array(r[8..<24]) == dst && Array(r[24..<40]) == src && be16(r, 40) == 443 && be16(r, 42) == 51000 && r[53] == TCPFlag.rst | TCPFlag.ack && be32(r, 48) == 1001 && checksum6OK(out[0].0), "IPv6 RST fields and checksum")
    }
    p[6] = 17
    h.inject(Data(p), family: AF_INET6)
    check(h.take().isEmpty, "IPv6 UDP dropped silently")
}
// 8. keepalive gets an ACK; zero window probe + fast resume
do {
    let h = Harness(.directInterface)
    h.inject(PacketBuilder.tcp(src: client, srcPort: 40200, dst: server, dstPort: 80, seq: 7, ack: 0, flags: TCPFlag.syn, window: 65535))
    let sa = h.takeTCP()[0]; let srv = sa.seq &+ 1
    h.inject(PacketBuilder.tcp(src: client, srcPort: 40200, dst: server, dstPort: 80, seq: 8, ack: srv, flags: TCPFlag.ack, window: 65535))
    _ = h.take()
    h.inject(PacketBuilder.tcp(src: client, srcPort: 40200, dst: server, dstPort: 80, seq: 7, ack: srv, flags: TCPFlag.ack, window: 65535))
    let ka = h.takeTCP()
    check(ka.count == 1 && ka[0].flags == TCPFlag.ack && ka[0].ack == 8 && ka[0].payload.isEmpty, "keepalive answered with an ACK")
    h.inject(PacketBuilder.tcp(src: client, srcPort: 40200, dst: server, dstPort: 80, seq: 8, ack: srv, flags: TCPFlag.ack, window: 65535))
    check(h.take().isEmpty, "pure ACK gets no reply")
    h.inject(PacketBuilder.tcp(src: client, srcPort: 40200, dst: server, dstPort: 80, seq: 8, ack: srv, flags: TCPFlag.ack | TCPFlag.psh, window: 0, payload: ArraySlice(Array(0..<10))))
    h.pump(0.1)
    let held = h.takeTCP()
    check(held.allSatisfy { $0.payload.isEmpty }, "zero window: data held back")
    h.pump(1.3)
    let probe = h.takeTCP().filter { !$0.payload.isEmpty }
    check(probe.count == 1 && probe[0].payload.count == 1 && probe[0].seq == srv, "zero window: one-byte probe after RTO")
    h.inject(PacketBuilder.tcp(src: client, srcPort: 40200, dst: server, dstPort: 80, seq: 18, ack: srv, flags: TCPFlag.ack, window: 65535))
    let resumed = h.takeTCP().filter { !$0.payload.isEmpty }
    check(resumed.count == 1 && resumed[0].seq == srv && Array(resumed[0].payload) == Array(0..<10), "window opened: full data resent immediately from the probe byte")
}
print(failures == 0 ? "ALL OK" : "\(failures) FAILURES"); exit(failures == 0 ? 0 : 1)
