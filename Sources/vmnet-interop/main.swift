// vmnet-interop: VMNetCore on a TAP device, for scripts/vmnet_interop.sh.
//
// The program opens /dev/net/tun as a TAP interface and holds its descriptor; the script moves the
// interface into a network namespace, where Linux's own TCP/IP stack then plays the guest. Every
// frame that namespace sends arrives here, in the userspace stack, exactly as a virtual machine's
// frames would. Linux only (Package.swift defines the target on Linux only).
#if os(Linux)
import Foundation
import Glibc
@_spi(Testing) import VMNetCore

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("vmnet-interop: " + message + "\n").utf8))
    exit(2)
}

/// "socks5://user:pass@host:port", "http://host:port" or "none".
func parseUpstream(_ text: String) -> VMNetUpstream? {
    if text == "none" { return VMNetUpstream.none }
    guard let separator = text.range(of: "://") else { return nil }
    let scheme = String(text[text.startIndex..<separator.lowerBound])
    var rest = String(text[separator.upperBound...])
    var username: String?, password: String?
    if let at = rest.lastIndex(of: "@") {
        let pair = rest[rest.startIndex..<at].split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        username = pair.first.map(String.init)
        password = pair.count > 1 ? String(pair[1]) : nil
        rest = String(rest[rest.index(after: at)...])
    }
    guard let colon = rest.lastIndex(of: ":"), let port = Int(rest[rest.index(after: colon)...]) else { return nil }
    let host = String(rest[rest.startIndex..<colon])
    switch scheme {
    case "socks5": return .socks5(host: host, port: port, username: username, password: password)
    case "http": return .httpConnect(host: host, port: port, username: username, password: password)
    default: return nil
    }
}

/// Opens /dev/net/tun as the TAP interface `name`: whole Ethernet frames, no extra header.
func openTap(_ name: String) -> Int32 {
    let descriptor = open("/dev/net/tun", O_RDWR)
    guard descriptor >= 0 else { fail("cannot open /dev/net/tun (errno \(errno))") }
    // struct ifreq: the interface's name in 16 bytes, then the flags as a short.
    var request = [UInt8](repeating: 0, count: 40)
    let nameBytes = Array(name.utf8.prefix(15))
    request.replaceSubrange(0..<nameBytes.count, with: nameBytes)
    let flags: UInt16 = 0x0002 | 0x1000 // IFF_TAP | IFF_NO_PI
    request[16] = UInt8(flags & 0xFF)
    request[17] = UInt8(flags >> 8)
    let setInterface: UInt = 0x4004_54CA // TUNSETIFF
    guard ioctl(descriptor, setInterface, &request) == 0 else { fail("TUNSETIFF failed (errno \(errno))") }
    return descriptor
}

var tapName = "vmtap0"
var upstream = VMNetUpstream.none
var guestMAC = VMNetMAC(string: "52:54:00:12:34:56")!
var gatewayMAC = VMNetMAC(string: "52:54:00:00:00:01")!
var gateway = VMNetIPv4(string: "192.168.1.1")!
var guest = VMNetIPv4(string: "192.168.1.23")!
var blocked: [String] = []
var waitFile: String?
var lossToGuest = 0.0, lossFromGuest = 0.0
var verbose = false

var arguments = Array(CommandLine.arguments.dropFirst())
func value(_ option: String) -> String {
    guard !arguments.isEmpty else { fail("\(option) needs a value") }
    return arguments.removeFirst()
}
while !arguments.isEmpty {
    let option = arguments.removeFirst()
    switch option {
    case "--tap": tapName = value(option)
    case "--upstream":
        guard let parsed = parseUpstream(value(option)) else { fail("--upstream: socks5://[user:pass@]host:port, http://[user:pass@]host:port or none") }
        upstream = parsed
    case "--guest-mac":
        guard let mac = VMNetMAC(string: value(option)) else { fail("--guest-mac: aa:bb:cc:dd:ee:ff") }
        guestMAC = mac
    case "--gateway":
        guard let address = VMNetIPv4(string: value(option)) else { fail("--gateway: a.b.c.d") }
        gateway = address
    case "--guest":
        guard let address = VMNetIPv4(string: value(option)) else { fail("--guest: a.b.c.d") }
        guest = address
    case "--block": blocked.append(value(option))
    case "--wait-file": waitFile = value(option)
    case "--loss-to-guest": lossToGuest = Double(value(option)) ?? 0
    case "--loss-from-guest": lossFromGuest = Double(value(option)) ?? 0
    case "--verbose": verbose = true
    default: fail("unknown option \(option)")
    }
}

setvbuf(stdout, nil, _IOLBF, 0)

// The signals that end the program are waited for below, not delivered to a handler: blocked
// here, before any thread starts, so that every thread inherits it.
var signals = sigset_t()
sigemptyset(&signals)
sigaddset(&signals, SIGINT)
sigaddset(&signals, SIGTERM)
pthread_sigmask(SIG_BLOCK, &signals, nil)

let tap = openTap(tapName)
print("READY tap=\(tapName)")

// The script moves the interface into its namespace and configures it first.
if let waitFile {
    while !FileManager.default.fileExists(atPath: waitFile) { usleep(20_000) }
}

let configuration = VMNetConfiguration(guestMAC: guestMAC, gatewayMAC: gatewayMAC, gatewayAddress: gateway, guestAddress: guest,
                                       upstream: upstream, blockedHostSuffixes: blocked)
let network = VMNetwork(configuration: configuration, frameDescriptor: tap)
network.setFrameLossForTesting(toGuest: lossToGuest, fromGuest: lossFromGuest)
network.log = { line in
    if verbose { print("LOG \(line)") }
}
network.start()
print("STARTED")

var received: Int32 = 0
sigwait(&signals, &received)

network.stop()
let counters = network.counters()
print("COUNTERS bytesFromGuest=\(counters.bytesFromGuest) bytesToGuest=\(counters.bytesToGuest) "
    + "connectionsOpened=\(counters.connectionsOpened) connectionsFailed=\(counters.connectionsFailed) "
    + "connectionsActive=\(counters.connectionsActive) dnsQueries=\(counters.dnsQueries) dnsBlocked=\(counters.dnsBlocked) "
    + "datagramsDropped=\(counters.datagramsDropped)")
close(tap)
exit(0)
#else
print("vmnet-interop runs on Linux only")
#endif
