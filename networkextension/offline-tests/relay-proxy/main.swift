import Foundation
var failures = 0
func check(_ c: Bool, _ m: String) { print(c ? "PASS" : "FAIL", m); if !c { failures += 1 } }
let client: UInt32 = 0x0A6F0002, server: UInt32 = 0x5DB8D822
func run(_ exit: Relay.Exit, label: String) -> (Bool, [UInt8]) {
    let flow = NEPacketTunnelFlow()
    let relay = Relay(exit: exit, dropUDP: false, packetFlow: flow, log: Logger(subsystem: "", category: ""))
    relay.start(); relay.queue.sync {}
    func inject(_ p: Data) { relay.queue.sync {}; flow.reader!([p], [NSNumber(value: AF_INET)]); Thread.sleep(forTimeInterval: 0.05); relay.queue.sync {} }
    func take() -> [Data] { var o: [Data] = []; relay.queue.sync { o = flow.written; flow.written = [] }; return o }
    inject(PacketBuilder.tcp(src: client, srcPort: 40000, dst: server, dstPort: 80, seq: 7, ack: 0, flags: TCPFlag.syn, window: 65535))
    guard let sa = take().first.flatMap({ TCPSegment(IPv4Packet($0)!) }), sa.flags == TCPFlag.syn | TCPFlag.ack else { return (false, []) }
    var srv = sa.seq &+ 1
    inject(PacketBuilder.tcp(src: client, srcPort: 40000, dst: server, dstPort: 80, seq: 8, ack: srv, flags: TCPFlag.ack, window: 65535, payload: ArraySlice(Array("ping".utf8))))
    var got = [UInt8]()
    for p in take() { let s = TCPSegment(IPv4Packet(p)!)!; if s.seq == srv && !s.payload.isEmpty { got += s.payload; srv &+= UInt32(s.payload.count) } }
    return (true, got)
}
// SOCKS5 with username/password
var phase = 0
proxyScript = { d in
    proxyLog.append(d)
    switch phase {
    case 0: phase = 1; return Data([5, 2])
    case 1: phase = 2; return Data([1, 0])
    case 2: phase = 3; return Data([5, 0, 0, 1, 0, 0, 0, 0, 0, 0])
    default: return nil
    }
}
var (ok, got) = run(.proxy(Relay.Proxy(host: "p", addresses: [0x0A000001], port: 1080, socks: true, tls: false, username: "u", password: "pw")), label: "socks")
check(ok && String(decoding: got, as: UTF8.self) == "ping", "SOCKS5 handshake then relay")
check(proxyLog.count >= 3 && [UInt8](proxyLog[0]) == [5,2,0,2] && [UInt8](proxyLog[1]) == [1,1,0x75,2,0x70,0x77] && [UInt8](proxyLog[2]) == [5,1,0,1,0x5D,0xB8,0xD8,0x22,0,80], "SOCKS5 greeting/auth/CONNECT bytes")
// SOCKS5 refusal → RST, nothing relayed
phase = 0; proxyLog = []
proxyScript = { _ in phase += 1; return phase == 1 ? Data([5, 0]) : Data([5, 5, 0, 1, 0,0,0,0, 0,0]) }
do {
    let flow = NEPacketTunnelFlow()
    let relay = Relay(exit: .proxy(Relay.Proxy(host: "p", addresses: [0x0A000001], port: 1080, socks: true, tls: false, username: nil, password: nil)), dropUDP: false, packetFlow: flow, log: Logger(subsystem: "", category: ""))
    relay.start(); relay.queue.sync {}
    flow.reader!([PacketBuilder.tcp(src: client, srcPort: 40001, dst: server, dstPort: 80, seq: 7, ack: 0, flags: TCPFlag.syn, window: 65535)], [NSNumber(value: AF_INET)])
    Thread.sleep(forTimeInterval: 0.1); relay.queue.sync {}
    let segs = flow.written.map { TCPSegment(IPv4Packet($0)!)! }
    check(segs.count == 1 && segs[0].flags & TCPFlag.rst != 0 && segs[0].ack == 8, "SOCKS5 refusal → RST to app (fail-closed)")
}
// HTTP CONNECT with Basic auth and early server bytes after the header
phase = 0; proxyLog = []
proxyScript = { d in proxyLog.append(d); if phase == 0 { phase = 1; return Data("HTTP/1.1 200 Connection established\r\nVia: x\r\n\r\nHI".utf8) }; return nil }
(ok, got) = run(.proxy(Relay.Proxy(host: "p", addresses: [0x0A000001], port: 8080, socks: false, tls: false, username: "u", password: "pw")), label: "http")
check(ok && String(decoding: got, as: UTF8.self).hasPrefix("HI"), "HTTP CONNECT leftover bytes delivered: \(String(decoding: got, as: UTF8.self))")
let req = String(decoding: proxyLog.first ?? Data(), as: UTF8.self)
check(req.hasPrefix("CONNECT 93.184.216.34:80 HTTP/1.1\r\n") && req.contains("Proxy-Authorization: Basic dTpwdw==\r\n"), "HTTP CONNECT request")
// Retransmission: drop the first data segment, expect resend after RTO
proxyScript = nil
do {
    let flow = NEPacketTunnelFlow()
    let relay = Relay(exit: .directInterface, dropUDP: false, packetFlow: flow, log: Logger(subsystem: "", category: ""))
    relay.start(); relay.queue.sync {}
    func inject(_ p: Data) { relay.queue.sync {}; flow.reader!([p], [NSNumber(value: AF_INET)]); Thread.sleep(forTimeInterval: 0.05); relay.queue.sync {} }
    func take() -> [TCPSegment] { var o: [Data] = []; relay.queue.sync { o = flow.written; flow.written = [] }; return o.map { TCPSegment(IPv4Packet($0)!)! } }
    inject(PacketBuilder.tcp(src: client, srcPort: 40002, dst: server, dstPort: 80, seq: 7, ack: 0, flags: TCPFlag.syn, window: 65535))
    let sa = take()[0]; let srv = sa.seq &+ 1
    inject(PacketBuilder.tcp(src: client, srcPort: 40002, dst: server, dstPort: 80, seq: 8, ack: srv, flags: TCPFlag.ack, window: 65535, payload: [9, 9, 9]))
    let first = take().filter { !$0.payload.isEmpty }
    check(first.count == 1, "data sent once")
    Thread.sleep(forTimeInterval: 1.4); relay.queue.sync {}
    let again = take().filter { !$0.payload.isEmpty }
    check(again.count == 1 && again[0].seq == srv && Array(again[0].payload) == [9, 9, 9], "retransmitted after RTO")
}
print(failures == 0 ? "ALL OK" : "\(failures) FAILURES"); exit(failures == 0 ? 0 : 1)
