# The network of a virtual machine profile

A virtual machine profile runs a macOS guest with Apple's Virtualization.framework. The guest has
one network card, and that card is one end of a datagram socket (`VZFileHandleNetworkDeviceAttachment`:
each datagram is one Ethernet frame). `VMNetCore` is the other end: a network stack in Lumen's own
process that **is** the guest's whole network.

Everything the guest sends to the internet leaves through the profile's proxy — SOCKS5 or HTTP
CONNECT — and through nothing else. This is not a rule that is enforced on a network that could do
otherwise: there is no route, no NAT and no bridge to this Mac's network at all. The only sockets
the stack ever opens are connections to the proxy. What the proxy cannot carry does not leave.

No root, no kernel or system extension, no entitlement beyond the virtualization one, no code from
anybody else: Swift, Foundation and BSD sockets (`Sources/VMNetCore`, no dependency on the rest of
the package).

## What the guest sees

An ordinary small network: `192.168.1.0/24` by default, a router at `192.168.1.1`, an address for
itself from DHCP.

| The guest does | The stack does |
|---|---|
| ARP for the router | answers with the gateway's hardware address. No other ARP is answered: the guest is alone on its network |
| DHCP | offers the one address there is, to the guest's network card only: mask, router and DNS server = the gateway, a lease of a day |
| ping the router | answers. A ping of anything else gets no answer |
| a DNS query — to the router or to **any** other address | answers it itself and asks nobody (below) |
| opens a TCP connection | ends it here and carries its bytes through the proxy (below) |
| any other UDP (QUIC, STUN, NTP, …) | drops it and answers "port unreachable" at once, so that the guest gives up now instead of after a timeout; nothing is said to broadcasts and multicast |
| IPv6, in any form | nothing. No router advertisement is ever sent, so the guest has no IPv6 address but a link-local one, and no IPv6 route |

### DNS: a name for every address, and no query that leaves

The guest's DNS never leaves this Mac. An address query (A) is answered with a **fake address**
from `198.18.0.0/15` — a range set aside for benchmarks, which no host on the internet has — one per
name, the same for as long as the network runs. When the guest then connects to that address, the
stack knows which name it stands for and asks the proxy for the **name**: the proxy resolves it, as
it does for a browser profile. The guest's own resolver choice changes nothing: a query sent to
`8.8.8.8` is answered by the stack just the same, "from" `8.8.8.8`.

- Up to 60 000 names are remembered; past that, the name unused the longest is forgotten. An
  address is given to another name only after every other address of the range has been given out.
- AAAA, HTTPS (type 65), SVCB and every other record type: "no such record". The guest therefore
  never learns an IPv6 address, nor that a site speaks HTTP/3, and stays on TCP over IPv4.
- A name under one of the configuration's blocked suffixes (`blockedHostSuffixes`: the name itself
  and every subdomain) does not exist (NXDOMAIN). This is how a guest is kept from downloading
  gigabytes of system updates through a paid proxy.
- `localhost`, names without a dot and names under `.local` do not exist: they are this machine's
  and the local network's, and are never handed to a proxy. Neither is a name that is not letters,
  digits, hyphens and underscores — it would go into the proxy's request as text.

### TCP: ended here, carried on by the proxy

For each connection the guest opens, the stack first opens a tunnel through the proxy, and only
when the proxy has said yes does the guest get its SYN-ACK. If the proxy refuses, or has not
answered within 15 seconds, the guest's SYN is answered with a reset — what a closed port answers —
so a page fails at once instead of hanging.

Where a connection may go:

| The guest connects to | What happens |
|---|---|
| a fake address it was given for a name | the proxy is asked for that name |
| a fake address nobody was given | reset |
| any other public IPv4 address | the proxy is asked for that address |
| a private, loopback, link-local, carrier-NAT, multicast, reserved or broadcast address, or its own network | reset, and the proxy never hears of it: the guest must not reach anybody's LAN — not this Mac's, not the proxy's |

With no usable proxy (`VMNetUpstream.none`) every connection is reset at once; DHCP, DNS and ping
still work, so the guest sees a network on which nothing answers.

The guest never receives a connection: nothing outside can open one towards it.

## What the app does with it

```swift
// A connected pair of datagram sockets: one end for the virtual machine, one for the stack.
var ends: [Int32] = [-1, -1]
socketpair(AF_UNIX, SOCK_DGRAM, 0, &ends)
// Both ends need room: what one end sends waits in the OTHER end's receive buffer, and macOS's
// default for a datagram socket holds two frames. VMNetwork enlarges its own end's buffers; the
// virtual machine's end is the app's to enlarge (SO_RCVBUF of megabytes, SO_SNDBUF of at least
// a frame), before it is handed over.
let attachment = VZFileHandleNetworkDeviceAttachment(fileHandle: FileHandle(fileDescriptor: ends[0]))

let network = VMNetwork(configuration: VMNetConfiguration(guestMAC: mac, gatewayMAC: gateway, upstream: upstream,
                                                          blockedHostSuffixes: suffixes),
                        frameDescriptor: ends[1])
network.log = { line in … }     // counts and reasons only
network.start()                 // its own thread; returns at once
…
network.stop()                  // closes every proxy connection; returns when the thread has ended
close(ends[1])                  // the descriptor stays the app's
```

`guestMAC` must be the address of the virtual machine's network card (DHCP answers no other), and
`counters()` may be asked at any time from any thread: bytes each way, connections opened, failed
and open now, DNS queries and how many were blocked, datagrams dropped.

## Limits

- **TCP over IPv4 only.** No UDP gets out (so no QUIC/HTTP/3, no WebRTC media, no NTP: the guest's
  clock comes from the host), no IPv6, no ICMP beyond the router's ping.
- **One guest per network**, one address. Guests do not see each other or this Mac.
- **No TLS is opened or read.** The stack moves bytes; what the proxy and the site see is the
  guest's own TLS.
- **TCP is deliberately plain**: no selective acknowledgements, no timestamps. Data that arrives
  ahead of a gap is kept (inside the window) until the gap is filled. Loss on this wire is rare — a
  frame is lost only when the socket's buffer is full and the stack's own queue for it (1 MiB) is
  too — and is repaired by retransmission: three duplicate acknowledgements, or a timer that
  starts at 250 ms and doubles up to 30 s. Measured against Linux as the guest, with frames
  thrown away at random in both directions: an 8 MB download takes about 0.6 s at 1 % loss, 1.6 s
  at 3 %, 10 s at 5 %. Beyond that transfers crawl; nothing stalls for good.
- **Buffers**: 256 KiB per connection in each direction. A proxy slower than the guest shuts the
  guest's window; a guest slower than the proxy stops the stack reading from the proxy. Nothing is
  buffered without bound.
- **2048 connections at once**; one more is reset. Every connection is a socket of Lumen's, so a
  network never takes more than half of the descriptors the process may open: with macOS's default
  limit of 256 that is 128 connections, and the full 2048 need a limit of 4096 (the app raises it
  with `setrlimit`; the log's first line says what the network got). A connection on which nothing
  moved for two hours is closed; a guest that has not answered for 15 minutes while data waits for
  it is given up on.
- **The proxy's own address** is resolved with this Mac's resolver (once, and again after a
  connection to it failed). That is the one name this Mac looks up for a virtual machine profile,
  as it does for a browser profile.
- The log (`VMNetwork.log`) holds counts and reasons — "the proxy refused (code 5)", "refused, not
  a public address" — and never a destination's name or address, nor the proxy's host, user name
  or password.

## The pieces

| File | What it is |
|---|---|
| `VMNetwork.swift` | the public class: a configuration, a frame descriptor, `start()`, `stop()`, `counters()` |
| `NetworkLoop.swift` | the one thread: `poll(2)` on the guest's wire and on every proxy connection, non-blocking throughout |
| `LinkResponder.swift` | ARP, ping, DHCP, DNS, and "port unreachable" — frames in, frames out, no sockets |
| `DHCPServer.swift`, `DNSResponder.swift` | the two servers and the pool of fake addresses |
| `DestinationPolicy.swift` | where a connection may go |
| `TCPConnection.swift` | one connection's TCP: segments in, segments out, a clock passed in |
| `ProxyHandshake.swift` | SOCKS5 (RFC 1928, 1929) and HTTP CONNECT as bytes in and bytes out |
| `Wire.swift`, `ByteQueue.swift` | Ethernet, ARP, IPv4, ICMP, UDP and TCP frames; checksums; a queue of bytes |
| `Sys.swift` | the system calls, under one set of names on macOS and Linux; the proxy's resolver |

## How it is tested

**Unit tests** (`swift test --filter VMNetCoreTests`, on Linux and macOS). The protocol code has no
sockets in it, so it is tested as data: checksums against known values, frames built and read back,
every DHCP exchange, the DNS responder (the pool, letter case, empty answers, blocked suffixes,
malformed queries), every refused address range, both proxy handshakes byte by byte, and the TCP
machine against a guest written out by hand — the handshake only after the tunnel, data both ways,
a lost segment sent again, duplicates, data ahead of a gap, windows that shut and open, FIN and
reset from either side, sequence numbers that wrap, and whole transfers over a wire that loses up
to 30 % of its frames in both directions. Then the whole network over a real socket pair, with the
test as a small guest and proxies on loopback that sign in, refuse, stall, talk nonsense or are not
there. Last, the guest as an adversary: frames cut short, grown and changed byte by byte, and
plain noise, through every parser and through a running network — whatever the guest sends
arrives in Lumen's own process, where a trap would end the app.

**Interop** (`scripts/vmnet_interop.sh`, Linux, in a privileged container). A scripted guest proves
the code agrees with its author; this proves it agrees with a real TCP/IP stack. The stack is put
on a TAP device whose interface lives in a network namespace, so Linux's kernel is the guest:
`udhcpc` takes a lease, `ping` and `dig` ask the router (and `8.8.8.8`), and `curl` downloads 64 MB
and uploads 32 MB through a SOCKS5 and an HTTP CONNECT test double, compared by SHA-256. Also: 64
parallel downloads and uploads, a thousand short connections, half-close, a reader and an origin
that are slow, transfers cut off in the middle, refused names and addresses, UDP answered
"unreachable", a wire that loses 1 % of its frames each way, no proxy at all, and that the stack
uses no CPU when nothing happens. One PASS or FAIL line per check and the throughput of the large
download (some hundreds of MB/s on a build machine, the test doubles included).

```
docker run --rm --privileged -v "$PWD":/src -w /src swift:6.0-noble bash -c \
  'apt-get update && apt-get install -y python3 curl iproute2 iputils-ping dnsutils udhcpc && scripts/vmnet_interop.sh'
```

The interop is what found that data ahead of a gap has to be kept: answered with duplicate
acknowledgements and then dropped, it made Linux take the wire for one that reorders packets and
stop retransmitting on duplicates.

**Not tested here**: the code on macOS (CI compiles and runs the unit tests there), and a macOS
guest's own TCP — the interop's guest is Linux.

## Without a proxy: the direct connector

A machine with no proxy does not get Apple's NAT (`VZNATNetworkDeviceAttachment`): it gets the
same network, with `VMNetDirectConnector` for its "proxy" — a SOCKS5 server on a loopback port of
the system's choosing, in the same process, that makes each connection as the process's own
ordinary socket. The guest's traffic then goes wherever any app's on this Mac goes: through its
VPN, by its routes. Behind Apple's NAT a guest's packets go by a network of the system's own, and
on a Mac that runs a VPN or a proxy tool they went nowhere.

- CONNECT only, no sign-in; names are resolved here (the system's resolver), IPv4 addresses tried
  first.
- Public addresses only, as the network itself has it: a name that resolves to this machine or to
  a local network is refused, so a page in a guest cannot reach the Mac's own services by naming
  them.
- A thread per direction of a connection, blocking; at most `maximumConnections` at once.
- `DirectConnectorTests`: a connection both ways with megabytes and a half-close, a name resolved
  on this side, what is refused, a destination that is not there, stop and start — and the whole
  way with the network: a guest gets its address, resolves a name, and loads a page through the
  connector byte for byte.

