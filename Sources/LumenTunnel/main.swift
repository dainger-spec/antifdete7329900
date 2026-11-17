#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import OpenVPNStack

// The program OpenVPN starts as its tun device (`--dev-node unix:…/LumenTunnel`, docs/OPENVPN.md):
// the packets of the tunnel on the socket pair OpenVPN gives it, and the profile's SOCKS5 server
// on the listening socket Lumen's app gave OpenVPN to pass on. It runs inside OpenVPN's sandbox
// (loopback only), and OpenVPN ends it (SIGINT) when the tunnel closes or starts again.
//
//   LumenTunnel --version    prints what it is and exits (the build's check)

setvbuf(stderr, nil, _IOLBF, 0)
if CommandLine.arguments.dropFirst().first == "--version" {
    print("LumenTunnel \(OpenVPNStackVersion.description)")
    exit(0)
}

func say(_ line: String) {
    fputs("LumenTunnel: \(line)\n", stderr)
}

var environment: [String: String] = [:]
var pointer = environ
while let entry = pointer.pointee {
    let text = String(cString: entry)
    if let equals = text.firstIndex(of: "=") {
        environment[String(text[..<equals])] = String(text[text.index(after: equals)...])
    }
    pointer += 1
}

let settings: TunnelSettings
do {
    settings = try TunnelSettings.read(environment)
} catch {
    say("not started: \(error)")
    exit(2)
}

let status = TunnelStatus(descriptor: settings.statusSocket)

// The listening socket must be on 127.0.0.1: a port anywhere else would open the tunnel to the network.
guard let listening = TunnelListener.check(settings.listeningSocket) else {
    say("not started: the listening socket is not a socket on 127.0.0.1")
    status.say(["event": "error", "reason": "listener"])
    exit(3)
}

signal(SIGPIPE, SIG_IGN)
let server = TunnelServer(settings: settings)
TunnelSignals.wake = server.wakeDescriptor
signal(SIGINT, tunnelSignalHandler)
signal(SIGTERM, tunnelSignalHandler)
signal(SIGHUP, tunnelSignalHandler)

let dns = settings.dnsServers.map { "\($0.address)" }
say("up: \(settings.ipv4.map { "\($0)" } ?? "no IPv4"), \(settings.ipv6.map { "\($0)" } ?? "no IPv6"), mtu \(settings.mtu), "
    + "DNS \(dns.joined(separator: " "))\(settings.dnsPushed ? "" : " (none pushed)"), SOCKS5 on 127.0.0.1:\(listening)")
status.say(["event": "up", "ipv4": settings.ipv4.map { "\($0)" } ?? "", "ipv6": settings.ipv6.map { "\($0)" } ?? "",
            "mtu": "\(settings.mtu)", "dns": dns.joined(separator: ","), "dnsPushed": settings.dnsPushed ? "1" : "0",
            "pid": "\(getpid())"])
let ending = server.run()
// The app is gone: OpenVPN, which nothing reaches any more, ends too.
if ending == .lifelineCut { kill(getppid(), SIGTERM) }
let counts = server.counts
say("down: \(ending) — clients \(counts.clients), refused \(counts.refusedCredentials), connects \(counts.connects), "
    + "failed \(counts.connectFailures), associations \(counts.associations), packets in \(counts.packetsIn) out \(counts.packetsOut) "
    + "dropped \(counts.packetsDropped), names \(counts.namesResolved) failed \(counts.namesFailed)")
status.say(["event": "down", "reason": "\(ending)", "pid": "\(getpid())"])
exit(0)
