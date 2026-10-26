# Networking: per-profile egress and the single-exit tunnel

This document describes how a profile's traffic leaves the Mac, the platform limitation that the
TCP proxy alone does not cover UDP, and the optional per-profile tunnel that gives TCP and UDP a
single exit IP. It also has the manual test checklist, because the tunnel cannot run in CI.

## The two modes

| | TCP (HTTP/HTTPS over TCP) | UDP (QUIC/HTTP3, WebRTC) | Exit IP |
|---|---|---|---|
| **Proxy only** (default when a proxy is set) | through the proxy | **leaves through this Mac's real interface** | different for TCP and UDP |
| **Unified tunnel** (opt-in) | into the tunnel → exit | into the tunnel → exit, or dropped | one exit for both |
| No proxy, no tunnel | direct | direct | this Mac's IP (both) |

## Why the proxy alone is not enough — the platform limitation

`WKWebsiteDataStore.proxyConfigurations` (the `ProxyConfiguration` API, macOS 14+) proxies **TCP
only**. The system does not perform SOCKS5 UDP ASSOCIATE for it, and there is no public
per-data-store API to proxy UDP. So with a SOCKS5/HTTP proxy set:

- HTTP(S) over TCP goes through the proxy — the site sees the proxy's IP.
- **QUIC/HTTP3** (UDP 443) and **WebRTC** (STUN/TURN and media over UDP) are not proxied. They
  leave through this Mac's real interface and reveal its IP.

This is a property of the public API, not a bug in this app. To make UDP and TCP share one exit,
every packet of the profile must be captured below the socket layer and forwarded by a tunnel.

## The unified tunnel

Switched on per profile (**Профиль → Единый выход для TCP/UDP**). When on, the profile's traffic
is carried by a per-profile packet tunnel (`NEPacketTunnelProvider`, a macOS Network Extension),
and everything — TCP and UDP — leaves through one exit:

- **Exit = the profile's proxy**, when one is set. If the proxy is SOCKS5 (without TLS to the
  proxy), the tunnel carries UDP to the same exit (SOCKS5 UDP ASSOCIATE), so QUIC and WebRTC share
  the proxy's IP. If the proxy is HTTP CONNECT (or SOCKS over TLS, where we do not assume UDP
  works), the tunnel **drops** UDP rather than let it leak: QUIC falls back to TCP through the
  proxy, and WebRTC gets no candidates. UDP never reaches the real interface.
- **Exit = this Mac's interface**, when no proxy is set. The tunnel still captures TCP and UDP
  together, so the app presents one consistent source; the exit IP is this Mac's own IP.

### Fail-closed

If the tunnel is switched on but cannot run — the Network Extension is not present (see below), or
it fails to start — the profile gets **no network at all**. It never silently falls back to
proxy-only (which would leak UDP) or to a direct connection. `ProfileNetwork.egress(tunnelAvailable:)`
returns `nil` in that case and the launch is refused with an explanation.

### The datapath — what actually runs (`networkextension/Relay.swift`)

The provider receives the app's IPv4 packets from `NEPacketTunnelFlow` and forwards them; it no
longer drops everything. What it does, per protocol:

| Traffic | SOCKS5 exit (no TLS) | SOCKS5 over TLS / HTTP(S) CONNECT exit | Direct exit (no proxy) |
|---|---|---|---|
| **TCP** | SOCKS5 `CONNECT` per flow (user/password auth if set) | SOCKS5 `CONNECT` over TLS, or HTTP `CONNECT` (Basic auth if set, TLS to the proxy for `https`) | direct TCP from the provider |
| **UDP** | SOCKS5 `UDP ASSOCIATE`, one per app socket | **dropped** | direct UDP per 5-tuple |
| **DNS** to 10.111.0.1 | answered by the relay: forwarded as DNS-over-TCP to 1.1.1.1:53 **through the exit** | same | same (direct to 1.1.1.1) |
| IPv6, ICMP, IP fragments, multicast/broadcast | dropped | dropped | dropped |

How it works:

- **TCP** is terminated inside the provider by a small userspace TCP endpoint: the app's SYN is
  answered only **after** the upstream connection to the exit (including the proxy handshake) is
  up; if that fails or times out (15 s), the app gets a RST. Bytes are then copied both ways, with
  flow control in both directions, retransmission on timeout, FIN/RST propagation, and a 10-minute
  idle timeout. No window scaling, SACK or timestamps are negotiated — the link is in-memory, so
  this costs little. The target is always the destination **IP** (the packet does not carry the
  hostname); names are resolved through the exit by the DNS path below.
- **UDP over SOCKS5**: each app UDP socket gets its own association (a TCP control connection plus
  a UDP socket to the proxy's relay address), so one socket talking to many peers (WebRTC/ICE)
  keeps one exit mapping. If the association fails or its control connection closes, that
  socket's datagrams are dropped. Replies whose source is not IPv4 cannot be mapped back and are
  dropped.
- **DNS**: `PacketTunnelProvider` keeps `NEDNSSettings(servers: ["10.111.0.1"])`; the relay answers
  that address itself. Each query is sent over TCP to 1.1.1.1:53 through the exit — this works for
  every exit kind, HTTP CONNECT included, so DNS never leaves through the real interface and the
  resolver sees the exit's IP. `AAAA` queries are answered locally with "no data" because the
  tunnel carries IPv4 only. Answers larger than the client's UDP size get the TC bit, and the
  client's DNS-over-TCP retry to 10.111.0.1:53 is relayed the same way. A failed lookup returns
  SERVFAIL. The resolver address is a constant (`Relay.dnsResolver`).
- **Fail-closed** holds per flow: a flow whose relay did not come up is reset (TCP) or dropped
  (UDP); nothing is ever re-sent outside the exit. The provider's own connections to the proxy are
  not routed into its tunnel (system behaviour for a packet-tunnel provider).

Known limits: IPv4 only (the tunnel installs no IPv6 route — see the checklist), no IP fragment
reassembly (large UDP datagrams that the app fragments are dropped), and no SOCKS5 UDP
fragmentation. The relay logs through `os.Logger` (subsystem `PrivacyBrowser.PacketTunnel`)
without credentials or destination addresses in public form.

### One tunnelled profile at a time

A `NEPacketTunnelProvider` captures the **whole app's** traffic, not one `WKWebView`'s. So only
one profile can use the tunnel at a time; a second profile that asks for the tunnel while another
holds it is refused (`TunnelCoordinator`). Profiles with no tunnel (direct, or proxy-only) are
unaffected and run alongside each other and alongside the one tunnelled profile — but note that a
proxy-only profile running next to a tunnelled one still sends its own UDP out directly.

## WebRTC

- **Tunnel on:** a page's WebRTC public IP is the exit IP (proxy exit, or this Mac for a direct
  exit). With a UDP-dropping exit, WebRTC simply gets no usable candidates.
- **Tunnel off, proxy set:** WebRTC over UDP bypasses the proxy and can reveal this Mac's real
  public IP. **Leave WebRTC disabled** (the per-profile default) unless the tunnel is on. The
  editor warns about this.
- The per-profile WebRTC setting (off / relay-only / unrestricted) is a JavaScript-level
  mitigation and is independent of the tunnel; it is not a substitute for the tunnel.

## Requirements to actually run the tunnel

The Network Extension is **off by default and not built by default**, because a packet tunnel
needs entitlements that only a provisioned build can carry:

- A paid Apple Developer account and an App ID with the **Packet Tunnel** capability
  (`com.apple.developer.networking.networkextension` = `packet-tunnel-provider`).
- A provisioning profile for both the app and the embedded extension; ad-hoc signing (the default
  `scripts/build-app.sh`) cannot load a Network Extension, so the toggle stays unavailable there.
- Build with the extension: `NE=1 TEAM_ID=XXXXXXXXXX SIGN_IDENTITY="Developer ID Application: …"
  scripts/build-app.sh`. This builds and embeds `PacketTunnel.appex` and signs both with the NE
  entitlement. Without `NE=1` the app is built exactly as before and the tunnel toggle reports
  "недоступно".

The provider source is in `networkextension/` and is deliberately **not** part of the Swift
package targets that CI builds, so `swift build`/`swift test` and the default `.app` build stay
green without any Apple Developer setup.

## Manual verification (needs a provisioned build and a real proxy)

CI cannot exercise the tunnel (no entitlement on the runner), so the datapath has only been
exercised off-device (packet parsing, TCP relay, SOCKS5/HTTP handshakes against stubs). Run this
checklist on a Mac with an `NE=1` build before relying on it. Watch the provider's log while you
do: `log stream --predicate 'subsystem == "PrivacyBrowser.PacketTunnel"'`.

1. Build with `NE=1` and your team id; grant the VPN configuration when macOS asks on first start.
2. Create a profile with a SOCKS5 proxy, switch **Единый выход для TCP/UDP** on, open it.
   - The toolbar tunnel status shows **up**.
3. Visit `https://browserleaks.com/webrtc`: the shown public IP is the **proxy's** IP, not your
   real one. `https://browserleaks.com/ip` agrees.
4. Visit a QUIC/HTTP3 site (e.g. `https://cloudflare-quic.com/`) with the dev tools network tab:
   either it is served over the proxy, or it falls back to HTTP/2 over TCP — it must **not** load
   over direct UDP. Confirm with a capture on the host: `sudo tcpdump -n 'udp and port 443'` shows
   no QUIC leaving your real interface for the profile's sites.
5. Switch the profile to an **HTTP CONNECT** proxy and repeat 3–4: WebRTC gets no candidates
   (no IP shown), QUIC falls back to TCP. Still no UDP on the real interface.
6. Turn the tunnel **off** (proxy-only): `browserleaks.com/webrtc` may now show your real IP —
   this is the documented limitation, and why WebRTC should stay disabled without the tunnel.
7. Stop the profile: the tunnel status goes **down** and the VPN configuration is torn down
   (check **System Settings → VPN**).
8. Fail-closed: point the proxy at a closed port with the tunnel on — pages must fail to load,
   never fall through to a direct connection. The log shows `tcp upstream failed`.
9. DNS: with the tunnel on and a SOCKS5 or HTTP proxy, `sudo tcpdump -n -i en0 port 53` shows no
   DNS from the profile; `https://browserleaks.com/dns` shows resolvers near the **exit**.
10. Proxy given by **hostname** (not IP): the tunnel still comes up and pages load (the provider
    resolves the proxy name outside its own tunnel).
11. Long transfers: download a large file (≥ 500 MB) and stream a video through each exit kind;
    the transfer completes without stalls, and closing the tab tears the flows down (log stops).
12. Direct exit (no proxy, tunnel on): pages load, `browserleaks.com/webrtc` shows this Mac's IP,
    and QUIC sites load over HTTP/3.
13. IPv6: on a network with IPv6, `https://test-ipv6.com/` shows no IPv6 connectivity for the
    profile. (The tunnel is IPv4-only and the relay answers AAAA with no data; IPv6 literals are
    not captured by the tunnel — report it if a page reaches one.)
