# The network of a virtual machine profile

A virtual machine profile runs a macOS guest with Apple's Virtualization.framework. The guest has
one network card, and that card is one end of a datagram socket (`VZFileHandleNetworkDeviceAttachment`:
each datagram is one Ethernet frame). `VMNetCore` is the other end: a network stack in Lumen's own
process that **is** the guest's whole network.

Everything the guest sends to the internet leaves through the profile's proxy — SOCKS5 or HTTP
CONNECT — and through nothing else. This is not a rule that is enforced on a network that could do
otherwise: there is no route, no NAT and no bridge to this Mac's network at all. The only sockets
the stack ever opens are connections to the proxy and, for UDP, sockets to the relay the proxy
names (SOCKS5 UDP ASSOCIATE). What the proxy cannot carry does not leave.

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
| a question for the time (NTP, port 123) — to **any** address | answers it itself with this Mac's clock, "from" the server asked; nothing leaves (`TimeResponder`) |
| any other UDP (QUIC, STUN, WebRTC, …) | where the run carries UDP (a SOCKS5 proxy that carried it in the check before the start, `relaysUDP`): sends it through the proxy's own UDP relay and shows the answers "from" where the guest sent (below). Otherwise drops it and answers "port unreachable" at once, so that the guest gives up now instead of after a timeout. Broadcasts and multicast are never relayed and never answered |
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
  never learns an IPv6 address, and learns that a site speaks HTTP/3 only from the site itself.
  **HTTPS and SVCB stay "no such record" on purpose**, with UDP carried or not: the real record
  cannot be known without the query leaving this Mac (it never does — the proxy is asked for
  names in connections, not in DNS); a record made up here would claim HTTP/3 for every name,
  sending QUIC to sites that do not speak it, and could carry neither the site's ECH keys nor its
  real ports. A browser learns HTTP/3 from the site's `Alt-Svc` header over TCP (Safari and Chrome
  both do), and the QUIC that follows goes to the same name — the same fake address, so the relay
  is asked for the name — or to a name the header gives, which the guest asks here like any other.
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

### UDP: through the proxy's own relay

HTTP/3 (QUIC) and WebRTC are UDP. With `VMNetConfiguration.relaysUDP` on and a SOCKS5 proxy, the
guest's datagrams go through the proxy's UDP relay (RFC 1928 §7: UDP ASSOCIATE, with the sign-in
of RFC 1929 on its TCP connection); a site sees the proxy's address in WebRTC, as in its pages.
The app turns it on for a run only where the check before the start found that the proxy carries
UDP from the address its pages leave from (`VMUDPRoute`, below); off, or with an HTTP CONNECT
proxy, or none, UDP is answered "port unreachable" as before. **There is never a direct path.**

- **One association per address and port the guest sends from**, whatever it sends to — so one
  relay port at the proxy per guest port, as a home router's NAT keeps it, and a WebRTC peer that
  learned the relay's address (a server-reflexive candidate) reaches that port. It is made as a
  connection is — the proxy's address, a TCP connection, the greeting and sign-in, then UDP
  ASSOCIATE with an address of all zeros — and lives as long as that TCP connection: when the
  proxy closes it, the association ends, and the guest's next datagram makes a new one. The
  datagrams that come while it is being made wait for it (at most 32, 64 KiB).
- **Where a datagram may go is decided as for a connection** (`DestinationPolicy`): to a fake
  address, the relay is asked for its **name** (address type 3), and the proxy resolves it; to a
  public address, for the address. A private, loopback, link-local, carrier-NAT, multicast,
  reserved or own-network address, a fake address nobody was given, port 0 and a blocked name are
  answered "port unreachable", and the proxy never hears of them. DNS (53) and the time (123) are
  answered here and never relayed, whatever the address; nor are DHCP, NetBIOS, SSDP, mDNS and
  LLMNR (67, 68, 137, 138, 1900, 5353, 5355). Broadcasts and multicast never leave.
- **An answer is shown from exactly where the guest sent.** Each association remembers the
  destinations the guest sent to (64, the one unused the longest forgotten): an answer from an
  address the guest wrote is from that address; a name's first answer teaches the address the
  proxy answers it from (or the relay names the name), and is shown from the fake address and
  port the guest used. An answer from anywhere the guest sent nothing, one with a header that is
  not SOCKS5's, a fragment (FRAG ≠ 0, which is not reassembled), and one larger than the guest's
  network takes (1472 bytes of payload) are dropped. The relay's socket is connected to the relay,
  so a datagram from any other address does not even reach the stack.
- **Where the relay is**: the address and port the proxy names (BND.ADDR, BND.PORT) — the proxy's
  own address where it names 0.0.0.0, itself, or an address that is not public (a proxy behind
  NAT names its address inside its own network): nothing of this Mac's is sent to a local network
  on a proxy's word. A relay named by a name, or on port 0, fails the association.
- **A proxy that refuses UDP ASSOCIATE** (7, not supported; 2, not allowed) is not asked again in
  the run: what waited, and what comes, is answered "port unreachable", and the log says so once.
  An association that fails otherwise (no answer within 10 s, not reached, not understood) answers
  what waited for it with "port unreachable"; failures one after another make the next attempt wait
  longer (a quarter of a second, doubling, at most 30 s).
- **Limits**: 128 associations at once (an eighth of the connections, so fewer where the process
  has few descriptors; each holds two), 32 new ones a second (64 at once); an association on which
  nothing moved for two minutes is closed (one quiet for half a minute makes room for a new one when
  the table is full). The relay's datagrams wait in its socket while the guest's wire is full, and
  are lost past that, as on any congested path.
- **The counters** add datagrams and bytes each way and associations opened, failed and open;
  the log says whether UDP is carried in the run, and the reasons for what was refused, as counts
  — never a name or an address.

**The check before the start** (the app, `VMCenter.checkProxy`): the Proxies section's own check of a
SOCKS5 proxy's UDP (`ProxyChecker.udp`) — one UDP association, a STUN Binding through it to a STUN
server named so that the proxy resolves it, then where the proxy's UDP leaves from (the STUN
answer) against where its pages leave from (Cloudflare's trace through the proxy). Only the proxy
is talked to. UDP is on for that run only when both are the same address
(`VMUDPRoute.throughProxy`); a proxy that refuses, carries nothing, sends UDP out from another
address (a site would see two), or could not be checked leaves it off, and the machine's row says
which. It runs beside the lookup of where the proxy comes out: a proxy that answers costs a second
or two, one that takes the association and carries nothing up to nine.

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
and open now, DNS queries and how many were blocked, datagrams dropped, questions for the time,
and the UDP carried (datagrams and bytes each way, associations). `VMNetConfiguration.relaysUDP`
turns the guest's UDP through the proxy's relay on (above); it is off unless set.

### Where a machine connects, and blocking a host as it runs

`hosts()` is what went to and from each host the guest asked for, the one seen last first
(`VMNetHost`: connections, how many are open, bytes each way, how often it was refused as
blocked; at most 400 hosts, the one unseen the longest forgotten first). `block(host:)` blocks
a name and everything under it from now on: its questions are answered "no such name", a
connection to the address the guest still holds for it is refused, and those open are reset.
The app shows the list in a running machine's "Network…" panel and asks for it only while the
panel is open (`hosts on` / `hosts off` to the helper, a `hosts` event every two seconds); a
host blocked there is written into the profile's own list too.

This **is** the person's browsing. It lives in the helper's memory and the panel's, and nowhere
else: no log line carries a name (the log's rule above holds — the tests look), and nothing is
written to disk.

### A network that goes on after a wake

`knownNames()` — after `stop()` — is every name the guest was given a stand-in address for, with
it; `VMNetConfiguration.knownNames` hands them to the next run, which gives the same names the
same addresses (`FakeAddressPool(restoring:)`: what is no entry of a pool is left out, fresh
addresses go on after the highest known, and the ones below it that nobody has are given out
before any is used twice). A machine woken from a saved state (docs/VM.md, "Instant wake")
still holds those addresses — in its resolver's cache, in connections it is about to open.

## Limits

- **IPv4 only.** TCP through the proxy; UDP through the proxy's relay where the run carries it,
  and not at all where it does not (no QUIC/HTTP/3, no WebRTC media then); no IPv6, no ICMP beyond
  the router's ping and "port unreachable". The guest's IP fragments are dropped, and no answer
  larger than its network's MTU is delivered (no fragments are made for it). The guest's clock is this Mac's: set from the virtual Mac's as it
  starts, and told again whenever it asks (NTP is answered here, by this Mac's clock) — which is
  what sets a machine woken from a saved state right, and one that stood still while this Mac
  slept (the helper has its boot script ask at both, docs/VM.md).
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
| `ProxyHandshake.swift` | SOCKS5 (RFC 1928, 1929) CONNECT and UDP ASSOCIATE, and HTTP CONNECT, as bytes in and bytes out |
| `UDPRelay.swift` | the guest's UDP through the relay as data: the datagram header, where the relay is, which destination an answer is from, what is never relayed |
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

UDP (`UDPRelayTests`, `UDPRelayLoopTests`, `DirectConnectorUDPTests`): UDP ASSOCIATE byte by byte,
with and without a sign-in, refused and in pieces; the datagram header both ways, fragments,
malformed headers and noise; where the relay is (unspecified, the proxy's own, public, private,
IPv6, a name); which destination an answer is from (an address, a name's first answer, two names
on one port, a fake address given to another name, blocked names, the limits); what the link layer
hands over and what it never does (DNS, the time, the local ports, broadcasts, multicast). Then
over real sockets with a SOCKS5 relay double: by name and by address, one association per guest
port, DNS and the time kept here, private destinations and blocked names refused and never seen
by the proxy, a proxy that refuses UDP (not asked again), stalls or is not there, answers from
another socket, fragments and answers from nowhere dropped, an answer too large for the guest,
noise from the guest, the proxy ending an association, a quiet one closed, the limits, no
descriptor left after `stop()`, and a log that names nothing. Run on Linux with Swift 6.1.3
(16 November): all 239 tests of VMNetCore pass, 48 of them new for UDP.

**Interop** (`scripts/vmnet_interop.sh`, Linux, in a privileged container). A scripted guest proves
the code agrees with its author; this proves it agrees with a real TCP/IP stack. The stack is put
on a TAP device whose interface lives in a network namespace, so Linux's kernel is the guest:
`udhcpc` takes a lease, `ping` and `dig` ask the router (and `8.8.8.8`), and `curl` downloads 64 MB
and uploads 32 MB through a SOCKS5 and an HTTP CONNECT test double, compared by SHA-256. Also: 64
parallel downloads and uploads, a thousand short connections, half-close, a reader and an origin
that are slow, transfers cut off in the middle, refused names and addresses, UDP answered
"unreachable" without the relay, a wire that loses 1 % of its frames each way, no proxy at all,
and that the stack uses no CPU when nothing happens. With the relay on (`--relay-udp`), the SOCKS5
double does UDP ASSOCIATE and relays to an echo, a STUN server and an HTTP/3 server on loopback:
an echo by name (asked of the relay as the name, answered from the fake address) and by address,
DNS and the time still answered here and never relayed, private and reserved addresses refused
and never relayed, a STUN Binding by name whose mapped address is the relay's own egress, an
HTTP/3 download over QUIC by name compared by SHA-256 (aioquic, the test's own), a proxy that
refuses UDP ASSOCIATE (unreachable at once, asked once, its TCP still working), UDP through a
proxy with a sign-in, and an HTTP CONNECT proxy with the relay asked for (nothing relayed). One
PASS or FAIL line per check and the throughput of the large download (some hundreds of MB/s on a
build machine, the test doubles included).

```
docker run --rm --privileged -v "$PWD":/src -w /src swift:6.0-noble bash -c \
  'apt-get update && apt-get install -y python3 python3-venv curl iproute2 iputils-ping dnsutils udhcpc \
   && python3 -m venv /opt/quic && /opt/quic/bin/pip install aioquic \
   && VMNET_INTEROP_QUIC_PYTHON=/opt/quic/bin/python scripts/vmnet_interop.sh'
```

Run on 16 November in an Ubuntu 26.04 root (Swift 6.1.3, aioquic 1.8.0) on a Linux kernel without
IPv6: every check passed, the 64 MB download at 572 MB/s, the 4 MB over QUIC in half a second.
**CI** runs the unit tests (`swift test` in `core-linux` and `macos-checks`, ci.yml), not the
interop, which needs a privileged container.

The interop is what found that data ahead of a gap has to be kept: answered with duplicate
acknowledgements and then dropped, it made Linux take the wire for one that reorders packets and
stop retransmitting on duplicates.

**Not tested here**: the code on macOS (CI compiles and runs the unit tests there), a macOS guest's
own TCP, QUIC and WebRTC — the interop's guest is Linux, its HTTP/3 aioquic's — and a real
provider's relay: the doubles relay as RFC 1928 says. What a site sees (detectme.pro's "UDP",
"HTTP/3", "WebRTC"; browserleaks.com/webrtc; cloudflare-quic.com) is checked on a Mac with a
machine and a SOCKS5 proxy that carries UDP.

## Without a proxy: the direct connector

A machine with no proxy does not get Apple's NAT (`VZNATNetworkDeviceAttachment`): it gets the
same network, with `VMNetDirectConnector` for its "proxy" — a SOCKS5 server on a loopback port of
the system's choosing, in the same process, that makes each connection as the process's own
ordinary socket. The guest's traffic then goes wherever any app's on this Mac goes: through its
VPN, by its routes. Behind Apple's NAT a guest's packets go by a network of the system's own, and
on a Mac that runs a VPN or a proxy tool they went nowhere.

- CONNECT, and UDP ASSOCIATE (below), and only with a sign-in (RFC 1929): a user name and password of 16 random bytes
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
- **UDP** (HTTP/3, WebRTC): the app turns the machine's UDP on (`VMUDPRoute.direct`), and the
  connector takes UDP ASSOCIATE. The network's datagrams come in on a loopback socket (the first
  one's sender is the association's; no other is heard) and go out from one socket of this process
  per address family — one port for every destination of a guest port. The rules are a
  connection's: a name that is local by the way it is written is not looked up; a name's
  addresses are taken when public, or private ones this Mac sends into a tunnel; an address the
  guest wrote only when public; never the Mac's own or a network it is on. An answer is taken only
  from where a datagram went. A site sees the address it sees for the machine's TCP. **Not while
  this Mac's network settings name a proxy** (a tool in "system proxy" mode, or a configuration
  file): that proxy is not asked for UDP, and UDP around it would leave from where the Mac's apps
  do not, so the association is refused (2) and the machine's network asks no more in the run;
  its row says HTTP/3 and WebRTC are off while the Mac's settings name a proxy. Tested by
  `DirectConnectorUDPTests`.
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

