import Foundation
let flow = NEPacketTunnelFlow()
let relay = Relay(exit: .directInterface, dropUDP: false, packetFlow: flow, log: Logger(subsystem: "", category: ""))
relay.start()
func pump(_ seconds: Double = 0.05) { relay.queue.sync {}; Thread.sleep(forTimeInterval: seconds); relay.queue.sync {} }
func check(_ c: Bool, _ m: String) { print(c ? "PASS" : "FAIL", m); if !c { failures += 1 } }
var failures = 0
let client: UInt32 = 0x0A6F0002, server: UInt32 = 0x5DB8D822
func inject(_ p: Data) { relay.queue.sync {}; let r = flow.reader!; r([p], [NSNumber(value: AF_INET)]); pump() }
func take() -> [Data] { var out: [Data] = []; relay.queue.sync { out = flow.written; flow.written = [] }; return out }
func checksumOK(_ d: Data) -> Bool {
    let b = [UInt8](d); var s: UInt32 = 0
    for i in stride(from: 0, to: 20, by: 2) { s += UInt32(b[i]) << 8 | UInt32(b[i+1]) }
    while s >> 16 != 0 { s = (s & 0xffff) + (s >> 16) }
    guard s == 0xffff else { return false }
    let t = Array(b[20...]); var ps: UInt32 = (be32(b,12) >> 16) + (be32(b,12) & 0xffff) + (be32(b,16) >> 16) + (be32(b,16) & 0xffff) + UInt32(b[9]) + UInt32(t.count)
    var i = 0; while i + 1 < t.count { ps += UInt32(t[i]) << 8 | UInt32(t[i+1]); i += 2 }; if i < t.count { ps += UInt32(t[i]) << 8 }
    while ps >> 16 != 0 { ps = (ps & 0xffff) + (ps >> 16) }
    return ps == 0xffff
}
// SYN
inject(PacketBuilder.tcp(src: client, srcPort: 50000, dst: server, dstPort: 443, seq: 1000, ack: 0, flags: TCPFlag.syn, window: 65535, options: [2,4,0x05,0x50]))
var out = take()
check(out.count == 1, "one SYN-ACK")
let synack = TCPSegment(IPv4Packet(out[0])!)!
check(synack.flags == TCPFlag.syn | TCPFlag.ack && synack.ack == 1001 && synack.mss == 1360, "SYN-ACK fields")
check(checksumOK(out[0]), "SYN-ACK checksums")
var srvNxt = synack.seq &+ 1
var cliNxt: UInt32 = 1001
// ACK + data
let total = 200_000
var sent = 0, received = [UInt8]()
let pattern = (0..<total).map { UInt8($0 % 251) }
inject(PacketBuilder.tcp(src: client, srcPort: 50000, dst: server, dstPort: 443, seq: cliNxt, ack: srvNxt, flags: TCPFlag.ack, window: 65535))
var rounds = 0
var gotFIN = false
while (received.count < total || !gotFIN) && rounds < 2000 {
    rounds += 1
    if sent < total {
        let n = min(1360, total - sent)
        inject(PacketBuilder.tcp(src: client, srcPort: 50000, dst: server, dstPort: 443, seq: cliNxt, ack: srvNxt, flags: TCPFlag.ack | TCPFlag.psh, window: 65535, payload: pattern[sent..<(sent+n)]))
        cliNxt &+= UInt32(n); sent += n
        if sent == total { inject(PacketBuilder.tcp(src: client, srcPort: 50000, dst: server, dstPort: 443, seq: cliNxt, ack: srvNxt, flags: TCPFlag.ack | TCPFlag.fin, window: 65535)); cliNxt &+= 1 }
    } else { pump() }
    for p in take() {
        if !checksumOK(p) { check(false, "checksum"); }
        let s = TCPSegment(IPv4Packet(p)!)!
        if s.flags & TCPFlag.rst != 0 { check(false, "unexpected RST"); rounds = 99999 }
        if s.seq == srvNxt && !s.payload.isEmpty { received += s.payload; srvNxt &+= UInt32(s.payload.count) }
        if s.flags & TCPFlag.fin != 0 && s.seq == srvNxt { srvNxt &+= 1; gotFIN = true }
    }
    inject(PacketBuilder.tcp(src: client, srcPort: 50000, dst: server, dstPort: 443, seq: cliNxt, ack: srvNxt, flags: TCPFlag.ack, window: 65535))
}
check(received == pattern, "echoed \(received.count)/\(total) bytes intact")
check(gotFIN, "server FIN after upstream EOF")
// segment for the now-closed flow gets RST
inject(PacketBuilder.tcp(src: client, srcPort: 50000, dst: server, dstPort: 443, seq: cliNxt, ack: srvNxt, flags: TCPFlag.ack, window: 65535, payload: [1]))
out = take()
check(out.count == 1 && TCPSegment(IPv4Packet(out[0])!)!.flags & TCPFlag.rst != 0, "flow closed; stray segment reset")
// DNS: echo server returns the length-prefixed query itself
let q: [UInt8] = [0x12,0x34, 0x01,0x00, 0,1, 0,0, 0,0, 0,0, 7]+Array("example".utf8)+[3]+Array("com".utf8)+[0, 0,1, 0,1]
inject(PacketBuilder.udp(src: client, srcPort: 53000, dst: Relay.gatewayAddress, dstPort: 53, payload: q))
pump(0.2)
out = take()
check(out.count == 1 && checksumOK(out[0]), "one DNS reply, checksums ok")
if let p = out.first { let ip = IPv4Packet(p)!; check(ip.src == Relay.gatewayAddress && Array(ip.bytes[28...]) == q, "DNS reply forwarded from resolver") }
var aaaa = q; aaaa[aaaa.count - 3] = 28
inject(PacketBuilder.udp(src: client, srcPort: 53001, dst: Relay.gatewayAddress, dstPort: 53, payload: aaaa))
out = take()
if let p = out.first { let b = [UInt8](p); check(b[28+2] & 0x80 != 0 && b[28+3] == 0x80 && be16(b, 28+6) == 0, "AAAA answered NODATA locally") } else { check(false, "AAAA reply") }
// UDP to multicast dropped; ICMP dropped
inject(PacketBuilder.udp(src: client, srcPort: 5353, dst: 0xE00000FB, dstPort: 5353, payload: [1,2,3]))
check(take().isEmpty, "multicast UDP dropped")
// HTTP-proxy relay drops UDP
let flow2 = NEPacketTunnelFlow()
let r2 = Relay(exit: .proxy(Relay.Proxy(host: "p", addresses: [0x0A000001], port: 8080, socks: false, tls: false, username: nil, password: nil)), dropUDP: false, packetFlow: flow2, log: Logger(subsystem: "", category: ""))
r2.start(); r2.queue.sync {}
r2.queue.sync {}; flow2.reader!([PacketBuilder.udp(src: client, srcPort: 4000, dst: server, dstPort: 443, payload: [1])], [NSNumber(value: AF_INET)]); Thread.sleep(forTimeInterval: 0.05); r2.queue.sync {}
check(flow2.written.isEmpty, "UDP dropped for HTTP CONNECT exit")
print(failures == 0 ? "ALL OK" : "\(failures) FAILURES")
exit(failures == 0 ? 0 : 1)
