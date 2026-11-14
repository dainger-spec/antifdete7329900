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
- An address written as a name does not exist either: a name whose last label is a number
  (digits, or `0x` and hex digits) — `192.168.1.1`, `127.1`, `0x7f.1`, `169.254.169.254`. Whatever
  resolves it (a proxy, this Mac's resolver, `inet_aton`, which also reads octal, hex and fewer
  than four parts) reads it as that address, and a fake address standing for it would carry the
  guest to the Mac or its local network by a name. No top-level domain is a number.

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

- CONNECT only, and only with a sign-in (RFC 1929): a user name and password of 16 random bytes
  each, made up for each connector and given to the machine's network alone (`upstream`). Any
  process on this Mac can reach a port on loopback; without the sign-in any of them could have its
  connections made by the helper. A client that offers no sign-in (method 0) is told no method is
  acceptable, one with another sign-in is refused, and the connection is closed. Names are resolved
  here (the system's resolver), IPv4 addresses tried first.
- Public addresses only, as the network itself has it: a name that resolves to this machine or to
  a local network is refused, so a page in a guest cannot reach the Mac's own services by naming
  them. **Every** address a connection would be made to is first compared with the Mac's own
  interfaces, public or private: the Mac's own addresses (a public IPv4 of its, its global IPv6)
  and the networks it is on by an interface that is not a tunnel's (a public prefix on its link
  included) are refused. Site-local IPv6 (fec0::/10) counts as local; an address under NAT64's
  prefix (64:ff9b::/96) or IPv4-mapped is judged by the IPv4 address inside it. A name that is
  local by the way it is written — one label, `localhost`, `.local`, an address written as a name
  — is refused before anything is asked: not looked up here, not asked of a proxy.
- **Except a VPN's own addresses.** Many VPN tools answer every name with an address of their own
  making from a private range (100.64.0.0/10, 10.0.0.0/8, 240.0.0.0/4, fc00::/7 …) and take the
  connection to it in their tunnel, where they put the real destination back. To the rule above
  such an address was a local network's, and on such a Mac a machine without a proxy had no
  internet at all (the third run on a person's Mac, 13 November: every connection failed as "not
  a public address"). So a private address **that a name resolved to** is taken when this Mac's
  route for it is a tunnel: `goesIntoATunnel` "connects" a datagram socket to it — which sends
  nothing and makes the system choose the address it would send from — and takes it only if
  every interface with that source address is point-to-point, up and not loopback (a VPN's
  `utun`), and the source is not the destination (the Mac itself). Before any socket is opened
  the interfaces' own addresses and masks are read: an address that is this Mac's own, or of a
  network the Mac is on by an interface that is not a tunnel's, is refused there: on a Mac a
  connection there is a use of the local network, which macOS asks the person about in a window
  of its own. Addresses written out are read as written (`AI_NUMERICHOST`), not asked of the
  resolver, and written as text with `inet_ntop`. The full pipeline, 14 November: macOS's window
  stood over the disk image's window a later step takes a picture of, and in front of Safari's
  Print sheet in the menu walk. Found on CI's Macs by running the tests one group to a runner
  (scratch branch): it came with the test of private addresses alone, which on a Mac opens no
  socket but to loopback; with `getnameinfo` replaced by `inet_ntop` and the literals read as
  written, neither that test nor all 878 of the package brought it up. The resolver asked of
  such a literal alone did not either; `getnameinfo` alone was not tried. Never taken, whatever the
  routes: loopback, link-local, multicast, 0.0.0.0/8, the broadcast address — and a private
  address the guest wrote itself rather than a name (the network refuses those before the
  connector hears of them). What this lets through that the rule did not: a name that resolves
  to an address inside a VPN the Mac is connected to — which the Mac's own browser reaches too.
- **The Mac's own proxy.** A VPN or proxy tool in its "system proxy" mode takes no packets: it
  writes itself into the Mac's network settings, and the apps that follow them (Safari) ask it.
  A plain socket passes it by — and on a network where only the tool gets out, reaches nothing
  (the second run on a person's Mac, 13 November: a machine without a proxy could not connect to
  any site). So for every connection the connector asks the helper what the settings name now
  (`VMNetSystemProxy`, from `CFNetworkCopySystemProxySettings`, re-read at most every three
  seconds — a tool switched on or off while a machine runs is followed): a SOCKS proxy first (it
  carries a connection to any port), else the HTTPS one, by CONNECT. The proxy is asked for the
  name itself, as apps ask it. The settings' exceptions go without it — names and patterns
  (`*.example.com`, `.example.com`), and address ranges as macOS writes them (`192.168.0.0/16`,
  `169.254/16`, `10.*`, `127.0.0.1`) — and so by the rules above, which refuse a local address.
  An address that is not public is not asked of the proxy at all. **A proxy configuration file
  (PAC) or discovery on the network (WPAD) is not followed — and the machine then makes no
  connection at all**, as with a proxy that is down: the system takes such a file first, so the
  Mac's own apps go wherever it says, and a machine going out without the proxy instead would go
  out where they do not. The helper's log says so at start, and the machine's row says the Mac's
  proxy is set by a configuration file a machine cannot follow, and to choose a proxy for the
  machine (`Trouble.proxyConfigurationFile`). The name is **not looked up on this Mac first**: that told the
  Mac's resolver every name a guest opened — on a network where a proxy tool is used, often the
  very party the tool is there for, and something the Mac's own Safari does not do — and a
  resolver that answers a blocked name with a local address had the name refused that the proxy
  opens (found in review, 13 November). Only a name that is local by the way it is written — one
  label, `localhost`, anything under `.local`, an address written as a name — is not asked.
  Where a name asked of the proxy ends up is the proxy's decision, as it is for the Mac's own
  apps. **The limit of this**: a public name that the proxy tool itself sends straight to an
  address of the Mac's local network — a rule of the tool's ("direct" for some domains), or a
  resolver of its that answers a name with a local address — takes the machine's connection
  there, as it takes Safari's on the Mac. Nothing on this side can see that: the proxy resolves
  the name and makes the connection. Where that matters, give the machine a proxy of its own
  (with a proxy a machine has no way to this Mac's network at all), or keep such rules out of the
  tool.
- **Why a connection was not made** is kept as a kind and a count — `Trouble`: no address for the
  name, addresses that are not public, addresses that did not take the connection, the Mac's
  proxy not answering or refusing, the Mac's proxy set by a configuration file — never a name or
  an address. The helper writes the counts to
  its standard error every two seconds (the app passes its own lines on to the terminal it was
  started from and to the system's log), and when `VMNetworkTrouble.failuresBeforeSaying`
  connections have failed one after another with none made since, its `traffic` event carries
  the kind: the machine's row in the app says in words what is wrong, and the machine's window
  says there is no internet. The first connection made clears it. Before it is said, the helper
  asks whether a connection can be made at all (`canConnect`: to captive.apple.com, which every
  Mac asks for when it joins a network; by the same way as a guest's, at most once in half a
  minute, not counted in the report): a page's blocked trackers fail one after another on a Mac
  with a filtering resolver, and that is not a machine without internet.
- A thread per direction of a connection, blocking; at most `maximumConnections` at once. Each
  connection holds three of the helper's descriptors (the network's socket to the connector, the
  one the connector accepted, the one to the destination), and both the network and the connector
  count them so (`descriptorsPerConnection`): with a raised limit of 8192, 1024 connections. When
  `accept` fails for want of descriptors or memory, the connector leaves its listener for a
  quarter of a second instead of asking again at once in a loop.
- `DirectConnectorTests`: a connection both ways with megabytes and a half-close, a name resolved
  on this side, what is refused, a destination that is not there, stop and start; a private
  address taken only where it goes into a tunnel, which ranges are private, and the system's own
  answer about a route (with `VMNET_TUNNEL_PEER` set to the far end of a point-to-point interface
  that is up, checked against a real one — run so on Linux with a `tun` device); each kind of
  failure and that its note names nothing; a SOCKS and an HTTP proxy of the Mac's settings asked
  for the name, bytes right behind a proxy's answer, a proxy that refuses or is not there, the
  settings' exceptions (address ranges among them), a local name, an address written as a name
  and a local address not asked of the proxy, a configuration file keeping the machine closed,
  the settings' dictionary read; the sign-in (none, a wrong one, another connector's), the
  descriptors counted three to a connection, the Mac's own addresses (mapped and NAT64 ones too)
  refused, site-local and NAT64 addresses judged — and the whole way with the network: a guest gets its address, resolves a name, and loads a page
  through the connector byte for byte.

