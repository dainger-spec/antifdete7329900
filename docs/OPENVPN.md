# OpenVPN connections: a profile through a provider's .ovpn

Many mobile-proxy sellers deliver access as an OpenVPN configuration (`.ovpn`) rather than a proxy
address. Lumen takes such a file as an entry of the proxy list, and a profile given it goes
through that VPN and nothing else — without root, without a system VPN, and without changing
anything of this Mac's network.

## Where it is added (0.1.19)

Until 0.1.18 the file was taken only from the Proxies section's ⋯ → Add OpenVPN…, which the owner
did not find. Now every way in leads to the same sheet (`OpenVPNImportView`):

- **Proxies → Add → OpenVPN**: Add is the section's main button; its choices (a proxy, a
  link, OpenVPN, a list — `ProxyAddChoicesView`) say what each takes. The empty list shows the first
  three as tiles (`ProxyEmptyState`).
- **Add's sheet** (a proxy line or a link): Choose .ovpn File…, or a `.ovpn` dropped on the sheet,
  turns it into the OpenVPN sheet with the file read (`ProxyAddSheet`). A `.ovpn`'s text pasted into
  any proxy field is said to be one (`ProxyLine.looksLikeOpenVPN`).
- **A profile's settings → Connection → Add to List…**: the same choices; what is added is chosen
  for the profile.
- **Settings → Proxies → Add a proxy, a link or OpenVPN → Add…**: the section, with Add's choices
  open. The Settings search finds "OpenVPN" (and the links' names) there.
- **A `.ovpn` opened with Lumen in the Finder**: `Info.plist` declares the extension as a document
  type, role Viewer, rank Alternate — an OpenVPN client the person has stays the default; Lumen
  takes a double-click only where nothing else claims the extension, and is offered under Open With.
  `AppDelegate.application(_:open:)` opens the section's OpenVPN sheet with the file (after the
  master password if the vault is locked). Nothing in the signature or entitlements changes: the
  sandboxed development build reads the file through the grant the open gives it.

## Status (17 November 2026): works end to end on macOS 26, and on Linux

- **With links, through the one launch step (0.1.18's tree), scratch run 44034707092 on macOS
  26.7.2** (`claude/features-check`, the OpenVPN job as `full.yml` runs it): every step below passed
  again with the tunnel started, handed over and held as a link's relay is (`LocalRelays`; the
  profile's process held to the port by "tcp-relay-only"): the wrong password refused and said, both
  pages seen from 10.8.0.2, the port's credentials, the server killed (nothing loaded, the profile
  stopped and said so, nothing left), and a capture of 1898 packets outside loopback with none of the
  profile's process, of LumenTunnel or of openvpn around the tunnel (65 of the forwarder to the
  server, the question inside the tunnel). The same run made the release dry run with OpenVPN built by
  `scripts/build-openvpn.sh` from Xcode's tools alone (PATH cut to `/usr/bin:/bin:/usr/sbin:/sbin`:
  no CMake, pkg-config or Homebrew), and run 44040505149 built it so again once its version stopped
  naming Lumen's git checkout.
- **macOS 26.7.2, CI run 44011508202** (`scripts/openvpn_macos_e2e.sh`, the app built for release
  with `OVPN=1`): a wrong password refused and said ("The VPN server refused the user name or
  password"), nothing left running; a page named only by the tunnel's DNS server, and one by address,
  loaded in a profile started as a person's is (its own process, Safari's window) and seen by the
  server from the tunnel's address 10.8.0.2; the profile's port refused a client without credentials
  and one with wrong ones; the server killed: nothing loaded, the profile was stopped with its
  message, no OpenVPN or LumenTunnel left; the pktap capture of the whole run (1285 packets outside
  loopback): none of the profile's process, of LumenTunnel or of the client's openvpn, the one DNS
  question for the name inside the tunnel, the forwarder's 66 packets to the server. The run before it
  (44010349410, a debug build) passed the same four steps; its capture (23295 packets, with a Safari
  the runner already ran) showed the same.
- **Linux** (`scripts/openvpn_linux_e2e.sh`, Ubuntu 26.04, OpenVPN 2.7.0, root for the server only):
  all five checks, and 32 MB through the tunnel intact in 0.31 s (loopback).
- **Sizes** (arm64, signed): `openvpn` 1.58 MB, `LumenTunnel` 0.65 MB.

Not shown on a Mac yet: WebRTC through the tunnel with the network guard installed (CI cannot load
the guard; the UDP association it uses is shown on Linux and in the unit tests), a TCP server
through the forwarder end to end (the forwarder's TCP is unit-tested), IPv6 inside the tunnel, and a
real provider's mobile network (loss, reconnections).

## The shape: a relay started by the app, an authenticated SOCKS5 port on 127.0.0.1

At a profile's launch the app starts the profile's tunnel, whose local port is, to the profile,
SOCKS5 on 127.0.0.1 with a user name and password made for that launch alone. Everything a proxied
profile has therefore holds unchanged — its process held to its proxy (ProfileNetworkGuard, the
network guard), pages resolved by the proxy, WebRTC through the relay (docs/TUNNEL.md), the exit's
location. It is the shape of a link's Xray relay (VLESS, VMess, Trojan, Shadowsocks), and the two share
one launch step (`LocalRelays`; docs/TUNNEL.md, "Relays"): the tunnel is started before anything asks
the proxy; its route (port and login) is registered in `ProxyRoutes` under a digest of the
configuration and login, and handed to the profile's process after its grant; the stored proxy stays
the OpenVPN connection, and whatever connects through it is given the route, or a proxy that does not
exist; the profile's process is held by the kernel to TCP to that port alone ("tcp-relay-only");
a tunnel gone for good stops the profile.

```
 profile's process (LumenProfile)              the app (Lumen)
   WebKit ── SOCKS5, the launch's ──┐            OpenVPNTunnels: per launch, per profile
   credentials                      │              ├─ LoopbackForwarders: 127.0.0.1:F → server:1194 (one address, fixed)
                                    ▼              └─ posix_spawn: sandbox-exec -p <loopback only> openvpn --config stdin
 ┌──────────── sandbox: every network operation refused but on loopback ─────────────┐
 │ LumenTunnel (OpenVPN's tun: --dev-node unix:)      openvpn 2.7 (unprivileged)      │
 │   127.0.0.1:P  SOCKS5 server ◄── packets ──► AF_UNIX socket pair ◄──► UDP/TCP to   │
 │   lwIP: TCP, UDP, the resolver                      (one IP packet per datagram)   │
 │   DNS: the pushed servers, inside the tunnel        remote 127.0.0.1:F (forwarder) │
 └───────────────────────────────────────────────────────────────────────────────────┘
```

- **openvpn** (`Contents/MacOS/openvpn`): OpenVPN 2.7.9, built unmodified from its release tarball
  with mbed TLS 3.6.5, LZO 2.10 and LZ4 1.10.0 (`scripts/build-openvpn.sh`, every source pinned by
  SHA-256). OpenVPN 2.7's AF_UNIX tun (`--dev-node unix:<program>`) is what lets it run without
  root: instead of a utun device it makes a datagram socket pair and starts the program named with
  the other end, one IP packet per datagram. No patch.
- **LumenTunnel** (`Contents/MacOS/LumenTunnel`, `Sources/LumenTunnel`, `Sources/OpenVPNStack`):
  that program. A user-space TCP/IP stack (lwIP 2.2.1, BSD, vendored unchanged in `Sources/CLwIP`)
  on the packet socket, and the profile's SOCKS5 server (RFC 1928, user name and password RFC 1929;
  CONNECT and UDP ASSOCIATE; BIND refused) on the listening socket the app passes down. Names are
  looked up at the DNS servers the VPN pushed, through the tunnel.
- **The forwarders** (`Sources/OpenVPNLink/LoopbackForwarders.swift`, in the app's process): each
  server of the configuration is a loopback port that carries what it is sent to that server's one
  address, and nowhere else.

## Leaks: what holds each part, and how it is known

| Property | What holds it | Shown by |
|---|---|---|
| The profile's process reaches only the local port | everything that connects through the profile's proxy is given the port (`ProxyRoutes`): ProfileNetworkGuard's three locks hold the process to it, and its sandbox closes UDP and closes TCP but to that port ("tcp-relay-only", as a link's profile); the network guard, where installed, holds it to 127.0.0.1 | macOS e2e (pktap capture: no packet of the profile's process or made for it leaves loopback) |
| OpenVPN reaches only the VPN server | `sandbox-exec` with `(deny network*)` but loopback; its configuration names no server but the forwarders' loopback ports; each forwarder's target is one address resolved before OpenVPN starts | macOS e2e (no openvpn or LumenTunnel packet outside loopback); `LoopbackForwardersTests` (only the first local sender, only the one target) |
| LumenTunnel reaches nothing but the tunnel | it runs inside OpenVPN's sandbox (it is OpenVPN's child); it opens no socket of its own but on 127.0.0.1, and refuses to start on a listener that is not on 127.0.0.1 | macOS e2e capture; `TunnelListener.check` |
| DNS inside the tunnel | the profile's names reach LumenTunnel as SOCKS5 host names (WebKit does not resolve with a proxy); LumenTunnel asks the pushed servers (`dns_server_*`, `dhcp-option DNS`) over lwIP's UDP — through the tunnel; when none is pushed, 1.1.1.1 and 8.8.8.8, still through the tunnel. This Mac's resolver is never asked: OpenVPN's sandbox refuses mDNSResponder, and nothing in LumenTunnel calls it | Linux e2e (the name known only to the tunnel's DNS server loads; the DNS server sees the question from the tunnel's address; tcpdump on every interface sees it nowhere else); macOS e2e (capture: no question for the name outside the tunnel); `ScriptedPeerTests`, `KernelInteropTests` |
| Pushed routes, redirect-gateway, DNS changes | irrelevant: nothing system-wide changes. The configuration given to OpenVPN has `route-noexec`, `ifconfig-noexec` and `pull-filter ignore "route"`/`"redirect-gateway"`; the AF_UNIX tun has no interface to configure; OpenVPN 2.7 runs no dns-updown script with it; no script directive is accepted from a `.ovpn` | the e2e servers push `redirect-gateway def1` and a route; the Mac's routes are untouched |
| The port needs the launch's credentials | a user name and 128-bit password made at each launch; LumenTunnel gets only their SHA-256 (`LUMEN_SOCKS_VERIFIER`) — no process's environment or OpenVPN's configuration holds what opens the port; no method but user name and password is offered | both e2e (no credentials and wrong credentials refused); `ScriptedPeerTests` |
| The profile's own process learns the port | after its grant on standard input, in the routes' record a link's relay is handed over with (`ProxyRoutes`, `LocalRelays.routes`), never from its environment or arguments; a profile whose proxy is an OpenVPN connection does not start without it | `LocalRelayTests` (the record, the key, nothing reached without a route) |
| Fail closed | while the tunnel is down there is no LumenTunnel and nothing behind the port: connections wait or are refused, nothing goes around; a tunnel not back within 45 s stops the profile, said; one that does not come up at a launch stops the launch, said; a stopped profile stops its tunnel | Linux e2e (server killed: nothing loads, LumenTunnel gone); macOS e2e (server killed: nothing loads, the profile stopped and said so, no OpenVPN or LumenTunnel left) |
| Nothing left behind | OpenVPN and LumenTunnel in a process group of their own, ended together; LumenTunnel watches a lifeline pipe only the app holds and ends OpenVPN when the app is gone; OpenVPN processes a crashed run left are ended at the next start | macOS e2e (after the refused launch and after the stop, no process left) |

## A Mac's packets (0.1.20)

The VPN server forwards the tunnel's packets as they are, so the IP and TCP headers a site sees are
the ones LumenTunnel's stack wrote — and tools that tell a system by them (p0f, and the sites that
show its verdict beside the user agent) read lwIP's, not macOS's, where Safari on a Mac with the same
`.ovpn` shows macOS's. Up to 0.1.19 that was: options `mss,nop,nop,ts,nop,ws 3,nop,nop,sok`, no DF,
IP identifiers counting up, one timestamp clock for every connection, local ports counting up, IPv6
flow label 0. Since 0.1.20 each packet out passes `lumen_net_shape` (`Sources/CLwIP/lumen_lwip.c`),
after lwIP wrote it (lwIP itself is unchanged), and leaves as XNU's would:

| | XNU (macOS 26) | LumenTunnel since 0.1.20 |
|---|---|---|
| SYN options | `mss 1460, nop, wscale 6, nop, nop, TS, sackOK, eol` (24 bytes) | the same, in that order (`TCP_RCV_SCALE` 6, so the scale said is the one used) |
| SYN window | 65535 | 65535 |
| TTL / hop limit | 64 | 64 |
| DF on TCP | yes (path MTU discovery) | yes |
| IPv4 identifier | random (`ip_randomid`) | random, on every packet that is not a fragment |
| TCP timestamps | 1 kHz, from an offset of each connection's own (`tcp_ts_offset`) | 1 kHz, offset by a keyed hash (SipHash, a key per process) of the connection's addresses and ports |
| local ports | random in 49152–65535 | random in 49152–65535 (TCP and UDP, the resolver's questions too) |
| IPv6 flow label | of each connection (`auto_flowlabel`) | the same hash, 20 bits |

Nothing here changes what a packet means: lwIP reads no timestamp echo back, the reordered options
are the same four, and each checksum is made again. The MSS is the interface's (`tun-mtu`, 1500 by
default: 1460, 1440 over IPv6) — what a Mac's utun with the same configuration says; OpenVPN's own
`mssfix` then lowers it on the way out for both, as it would on a Mac. Not matched: ECN, which XNU
asks for on some connections only, by its own heuristics; the way a window grows after the
handshake. Tested: `ScriptedPeerTests.testASynLeavesTheTunnelInAMacsShape` (each field of two SYNs,
and that a connection in that shape carries).

## The configuration

`OpenVPNConfiguration` (BrowserCore) reads a `.ovpn` once, at import: as OpenVPN reads it (quotes,
comments, `--` prefixes, inline blocks, `<connection>` entries, CRLF), and **refused whole** when
anything in it is unknown — never passed on unread. Files it names (`ca ca.crt`) are taken from
beside the `.ovpn` at import (`inlining`), or refused.

- **Kept**, passed to OpenVPN as written: a client's TLS and data-channel options (ca, cert, key,
  extra-certs, tls-auth, tls-crypt, tls-crypt-v2, key-direction, crl-verify, cipher, data-ciphers,
  auth, tls-cipher, tls-version-min/max, remote-cert-tls/ku/eku, verify-x509-name, peer-fingerprint,
  …), keepalive and timers, compression (`comp-lzo`, `compress`: decompressed on the way in, never
  compressed on the way out — `allow-compression asym`), MTU options, `dhcp-option`, `dns`,
  `pull-filter`, `auth-user-pass`.
- **Left out, and said** at import: what concerns this Mac (routes, redirect-gateway, DNS scripts,
  up/down scripts, user/group, logs, daemon, persist-tun, resolv-retry, management, …).
- **Mapped, and said**: `ns-cert-type server` (absent from OpenVPN with mbed TLS) is checked as
  `remote-cert-tls server`; a cipher mbed TLS lacks (BF-CBC, CAST5, DES, …) is dropped from the
  lists — the server must offer another; OpenSSL's own cipher-list syntax (`DEFAULT:@SECLEVEL=0`)
  is left out; credentials in an `<auth-user-pass>` block go to the entry's fields.
- **Refused, with why** (en and ru, `openvpn.problem.*`, `openvpn.reason.*`): a server's
  configuration; tap; another proxy in front (`http-proxy`, `socks-proxy`); a one-time code
  (`static-challenge`); PKCS#12, PKCS#11, the system's store, an external key; the static-key mode
  (`secret`); a device named (`dev-node`, `lladdr`); an encrypted private key; a file not inline;
  an unknown directive; no server; no CA.

At a launch OpenVPN is given, on its standard input: `client`, `dev tun`,
`dev-node unix:<LumenTunnel>`, `script-security 2` (for that program alone), `route-noexec`,
`ifconfig-noexec`, `auth-retry none`, the kept directives, one `<connection>` per server with
`remote 127.0.0.1 <forwarder> udp4|tcp4-client`, the launch's `setenv LUMEN_*` and the inline
credentials. The private key and the password never touch the disk there.

The entry: `ProxySettings.openVPN` holds the configuration in normal form; `host` and `port` are the
first server's, `kind` SOCKS5 (what the profile is given), `username` and `password` its
auth-user-pass — kept encrypted as every proxy's, in the profile's settings and the proxy list. Such a
profile's settings are written in format 2, the proxy list holding one in format 4, a profile export
in format 4 (docs/UPDATES.md §4) — the numbers a link's take too: Lumen 0.1.17 and earlier refuse
them as a newer version's, rather than read the connection as a SOCKS5 proxy at the VPN server's
address and write it back without its configuration. Two configurations of one server and login are
told apart in the list by a fingerprint of the configuration, and so is where each exits
(`ProxyLocation.endpoint`): the place found at one launch is remembered for the next, as a proxy's.

## Licensing: what ships

- **OpenVPN** (GPL-2.0): a separate program the app starts, not linked into it. Shipped with
  `Contents/Resources/ThirdParty/OpenVPN/OpenVPN-COPYING.txt` and `OpenVPN-COPYRIGHT.GPL.txt`, and
  `SOURCES.txt`: the four source tarballs, their addresses and SHA-256, the build script, the
  statement that OpenVPN is unmodified (there is no patch to publish), and a written offer of the
  sources for three years. The OpenVPN 3 core (AGPL) is not used.
- **mbed TLS** (Apache-2.0 OR GPL-2.0-or-later, used under GPL-2.0-or-later so that it combines
  with OpenVPN's GPL-2.0), **LZO** (GPL-2.0-or-later), **LZ4** (BSD-2-Clause): linked into openvpn;
  their licenses in the same folder.
- **lwIP** (BSD-3-Clause): in LumenTunnel; its license in the same folder
  (`lwIP-COPYING.txt`) and in `Sources/CLwIP/lwip/COPYING`.
- PPTP is not supported: it is insecure.

What remains for a release: publishing the source tarballs next to each release's download
(release.sh does not upload them yet), which makes the written offer unnecessary.

## Building it

```sh
scripts/build-openvpn.sh                     # build/openvpn/openvpn and its licenses (reused when built)
OVPN=1 SANDBOX=0 scripts/build-app.sh        # the app with openvpn and LumenTunnel
scripts/release.sh …                         # a release: with them unless OVPN=0
```

`scripts/build-openvpn.sh` needs only what Xcode's command line tools put on a Mac (curl, shasum,
tar, make, clang, ar, lipo, strip, otool): every tarball carries its own configure script or Makefile
— mbed TLS's with its generated files, built with its own Makefile — and each library's flags are
given to OpenVPN's configure directly, so neither CMake, autotools, pkg-config nor Homebrew is used.
The full pipeline's release dry run builds it with PATH cut to `/usr/bin:/bin:/usr/sbin:/sbin`.
Without `OVPN=1` the app has neither program: the OpenVPN sheet says this build has none, and a profile
given an OpenVPN connection does not start, said. The sandboxed development build cannot run one
either (profiles there are not in their own process).

## What is tested

- `OpenVPNConfigurationTests` (Linux, macOS): the parser — the typical provider file, `<connection>`
  entries, proto and port defaults, quotes and comments, CRLF, every refusal with its reason, files
  inline from beside the file, the missing pieces, encrypted keys, bad servers, ns-cert-type,
  ciphers, OpenSSL cipher lists, inline credentials, and what OpenVPN is given (only the forwarders'
  ports, nothing of the Mac touched, a path with spaces quoted, credentials that would break their
  block refused).
- `OpenVPNStackTests` (Linux, macOS): the SOCKS5 and DNS codecs; the tunnel's settings from
  OpenVPN's environment; `ScriptedPeerTests` — the server against a scripted far side, without root;
  `LoopbackForwardersTests`; `KernelInteropTests` (root, a TUN device: Linux's own TCP plays the far
  side — 8 MB down and 4 MB up intact, the name asked from the tunnel's address, a reset refused).
- `scripts/openvpn_linux_e2e.sh` (Linux, root, OpenVPN 2.7): a real server and the real client
  unprivileged with LumenTunnel — the page known only to the tunnel's DNS, DNS only through the
  tunnel (tcpdump), credentials, a UDP association, fail closed.
- `scripts/openvpn_macos_e2e.sh` (macOS, CI): the app built with `OVPN=1`, a server on the runner,
  the profile started as a person's is and driven over WebDriver — a wrong password refused and
  said, pages through the tunnel seen from the tunnel's address, the port's credentials, the server
  killed (nothing loads, the profile stopped and said so, nothing left), and a pktap capture of the
  whole run with its controls.

## Limits

- IPv4 and IPv6 inside the tunnel; tun only (tap refused).
- DNS over UDP to the pushed servers, A then AAAA; no TCP fallback for a truncated answer with no
  address in it (the next server is asked). DNS-over-TLS/HTTPS servers pushed with `--dns` are asked
  as plain DNS at their address.
- An encrypted private key must be decrypted first; PKCS#12 and smart cards are not supported.
- The servers' names are resolved by this Mac's resolver at the launch (the VPN server's own name,
  never a page's); a server that moves to another address mid-session is reached again at the next
  launch.
- While OpenVPN reconnects (up to 45 s) pages do not load; past that the profile is stopped.
- Virtual machines are not given OpenVPN connections yet (a link's relay, they are).
- Virtual machines are not given OpenVPN connections.
