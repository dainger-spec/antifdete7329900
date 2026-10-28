# WebRTC through a profile's proxy: the packet tunnel

WebKit sends a data store's HTTP(S), WebSocket and media loads through the store's proxy, but
opens its WebRTC sockets (STUN, TURN, media) itself, from this Mac's own address. Without help,
a proxied profile therefore has to run with WebRTC off (ISOLATION_AND_LIMITATIONS §5). The
packet tunnel, a Network Extension, is that help. With it, the WebRTC of a profile with a SOCKS5
proxy leaves through that proxy's UDP ASSOCIATE, so sites, STUN servers and peers see the proxy's
address.

| Traffic of a proxied profile | Path | How it is known |
|---|---|---|
| HTTP(S), WebSocket, fetch, media loads (TCP) | the data store's proxy (`proxyConfigurations`, fail-closed) | self-test, leak check |
| QUIC / HTTP/3 | not used: with a store proxy WebKit sends these requests as HTTP/2 through the proxy | leak check (cloudflare-quic.com) |
| DNS | resolved by the proxy (SOCKS5 remote DNS, CONNECT host names) | self-test |
| WebRTC: STUN, TURN, media, data channels (UDP) | **the tunnel**: a TURN relay on a virtual address, which relays through the profile's SOCKS5 UDP association (only for a profile whose WebRTC setting is not Disabled, the default) | unit tests, leak check (relay harness; utun harness where sudo works); the extension itself has not run on a Mac yet (checklist below) |
| WebRTC with an HTTP CONNECT proxy | off: CONNECT cannot carry UDP | self-test |
| WebRTC with the tunnel off or not built | off, with a warning (UDP would leave from this Mac's address) | self-test |

A page cannot send other UDP: WebRTC is the only UDP a web page can start.

## Architecture

```
 page (profile A, SOCKS5 proxy PA)                    PacketTunnelExtension (system extension)
 ─────────────────────────────────                    ────────────────────────────────────────
 RTCPeerConnection                                     NEPacketTunnelProvider
   iceServers := [turn:192.0.2.10:3478,                  routes: 192.0.2.0/24, fd6b:3a1c:94e2:1::/64
                  turn:[fd6b:3a1c:94e2:1::a]:3478]       (enforced; nothing else, no DNS)
   iceTransportPolicy := relay                           │
        │  (user script; the page sees its own config)   PacketRouter ── by destination address
        ▼                                                 ├─ 192.0.2.10 / …::a → TURNServer(route A)
 WebKit networking process (libwebrtc)                    │                       └─ allocation → SOCKS5 UDP ASSOCIATE @ PA
   TURN client, socket bound to en0's address            └─ 192.0.2.11 / …::b → TURNServer(route B)
        │                                                                         └─ allocation → SOCKS5 UDP ASSOCIATE @ PB
        ▼  enforced route
 utun ──── IP packets ────────────────────────────────▶ readPackets / writePackets
```

- **Why a relay and not "route the profile through the tunnel".** All WKWebView profiles share
  one WebKit networking process, so a packet cannot be traced back to a profile by its source.
  Per-app VPN would not help either: it works per app, and WebKit's processes serve every
  profile. So the tunnel routes only a virtual subnet. Each running profile gets its own TURN
  server address there (slot *n* → `192.0.2.(10+n)` and `fd6b:3a1c:94e2:1::(10+n)`) with its
  own random credentials. Its pages are given that relay as their only ICE server, with
  `iceTransportPolicy: "relay"`. Every packet that reaches a relay address therefore belongs to
  one profile, and leaves through that profile's proxy.
- **Several profiles at once.** Each route has its own TURN server, credentials and proxy.
  Every allocation opens its own SOCKS5 UDP association (a TCP control connection plus a UDP
  flow), so profiles behind different proxies relay side by side (`PacketRouterTests`). Up to
  240 routes; 64 allocations per route.
- **The tunnel carries nothing else.** The routes are the TEST-NET-1 /24 (RFC 5737, never
  routed on the Internet) and a random unique-local /64. There are no DNS settings and no
  default route, so other apps, DNS, and the profiles' own TCP to their proxies stay on the
  normal network. It is not 198.18.0.0/15: sing-box, Clash and Surge hand out fake IPs from
  that range, and a more specific route of ours would take some of their traffic.
- **Routing WebKit's sockets into the tunnel.** If libwebrtc bound its TURN socket to the
  default interface's address, XNU would keep the packets on that interface whatever the routing
  table says (DTS: a flow bound to an interface's address goes over that interface). That is
  not what happens. With ordinary routes into a utun interface (the leak check's utun harness,
  macOS 26.6), WebKit's TURN traffic to the relays arrived from the utun's own addresses
  (`192.0.2.1`, `fd6b:3a1c:94e2:1::1`): libwebrtc gathered on the tunnel interface, for IPv4
  and IPv6. `NEVPNProtocol.enforceRoutes = true` stays as a second line. It is documented to
  supersede "scoping operations by apps" for the included routes, here only these two subnets
  (`includeAllNetworks` stays off).
- **TURN for libwebrtc** (`TunnelCore/TURNServer.swift`, RFC 8656 subset). It speaks UDP
  allocations, long-term credentials (HMAC-SHA1, MD5 key) and stateless nonces. Allocate is
  idempotent per 5-tuple. It also handles Refresh, CreatePermission and ChannelBind, Send and
  Data indications, and ChannelData. These behaviours of WebKit's libwebrtc decide the details:
  - The first Allocate goes out without credentials and needs a 401 carrying REALM and NONCE.
  - A 401 or 438 on the authenticated Allocate is fatal.
  - Every authenticated success must carry MESSAGE-INTEGRITY.
  - An Allocate success needs XOR-RELAYED-ADDRESS, XOR-MAPPED-ADDRESS and LIFETIME.
  - REQUESTED-ADDRESS-FAMILY is never sent. An allocation therefore takes the family of the
    relay address it was sent to.
  - The TURN server is also asked as a STUN server, without credentials, from the socket of the
    allocation (Bindings for about 45 s, until libwebrtc drops that port under the relay
    policy). A Binding is answered only on a 5-tuple that holds an allocation, with its relayed
    address: the proxy's egress, **never the client's own address**. Until the allocation is
    ready the Binding goes unanswered and a retransmission gets the answer. A 5-tuple whose
    Allocate failed gets 500, so gathering completes at once. Any other 5-tuple gets nothing:
    the relay addresses are reachable by every process on the Mac, and an unauthenticated
    answer would tell them a profile's proxy address.
  - The Allocate's mapped address is the egress too. Under the relay policy libwebrtc prints a
    relay candidate's related address as `0.0.0.0 0` (IPv4) or `:: 0` (IPv6). If the policy
    were ever widened, it would show the egress, not this Mac's address.
- **The proxy's egress** is found per allocation with a STUN Binding sent through its
  association to public STUN servers. Their names are resolved by the proxy. For IPv6 the
  servers are IPv6 literals, so the answer is an IPv6 egress.
- **Peers are Internet addresses only.** CreatePermission and ChannelBind are refused (403)
  for loopback, link-local, private, shared (CGNAT), multicast and reserved addresses, the
  relays themselves, and IPv6 forms of IPv4 addresses. Those would be reached on the proxy's
  side. libwebrtc drops only that peer's candidate pair.
- **IPv4 and IPv6.** Packets of both families are parsed and built (`IPPacket`; the IPv4
  header checksum and the mandatory IPv6 UDP checksum are checked). There is a relay address
  and an allocation per family, and the SOCKS5 framing covers both. A proxy without IPv6 egress
  fails only the IPv6 allocation: the probe through the proxy gets no answer, and after about
  6 s the Allocate is answered 508 (its Bindings get 500). The IPv4 relay keeps working.
- **Control.** The app registers a route per profile launch over `sendProviderMessage` (JSON,
  `TunnelControlMessage`). Only the app that owns the VPN configuration can send these. It
  registers again whenever the tunnel reconnects, and unregisters on stop. The tunnel starts on
  demand and stops when no route is left. A tunnel nothing uses, left by a quit, a crash or a
  force quit, is stopped at the next launch. While it has routes the app sends a status message
  every minute. After 10 minutes without one (uptime, so sleep does not count) the extension
  drops its routes and stops. Apple DTS recommends XPC through `NEMachServiceName` for richer
  app↔system-extension traffic. Provider messages are enough here, because routes only need to
  reach a connected tunnel.
- **Updates.** macOS replaces an installed system extension only on an activation request.
  At launch the app compares the enabled extension's `CFBundleVersion` (a new one per build)
  with its own bundled one, and requests activation when they differ. A same-team replacement
  needs no new approval.
- **The proxy connections bypass the tunnel.** NECP keeps the provider process's own sockets
  out of its tunnel, and the proxies are not in the routed subnets anyway. A proxy configured
  inside them is refused.

### What a page sees

- `getConfiguration()` returns the page's own `iceServers` and policy. The engine still
  validates them and throws its own errors, through a closed peer connection that is made from
  them and never gathers (no candidate pool).
- Candidates are of type `relay` only, at the proxy's egress address. libwebrtc prints their
  related address as `0.0.0.0 0` (`:: 0` for IPv6) under the relay policy.
- `RTCPeerConnectionIceEvent.url` and the `url` of candidate entries in `getStats()` would name
  the virtual relay. The user script replaces it with the page's own server, in libwebrtc's form
  (`turn:host:3478?transport=udp`, `stun:host:3478`). With no such server configured, it returns
  `null` or leaves the field out.
- STUN servers the page configured are not contacted: libwebrtc would reach them from the
  physical interface even under the relay policy, so they are dropped from the engine's
  configuration.
- This differs from Safari without a proxy, which would show mDNS host and srflx candidates.
  A page can tell that the profile uses a relay-only policy, as with any TURN-only setup.

### Enforcement is in the page, not in the engine

With the tunnel the engine's WebRTC is on. WKWebView has no setting that forces relay-only or
limits ICE servers, so the document-start user script is what keeps a page on the relay. If it
were defeated, libwebrtc would reach the page's STUN servers from the physical interface, and
the real address would leak. The script is hardened for this:
- it uses only built-ins it captured before any page script ran;
- it gives the engine null-prototype objects with own data properties and its own iterators;
- it never hands the native constructor or methods to anything the page can replace.

Shim tests attack it by replacing `Reflect`, `Function.prototype.call`/`apply`,
`Object.assign`/`create`/`defineProperty`, the `Array` iterator and `slice`, and `WeakMap` and
`Promise` methods, and by putting accessors on `Object.prototype`. Each attack must leave the
engine with the relay alone, relay-only, and the native functions out of reach.

It remains page-level code. Workers have no RTCPeerConnection, and frames sandboxed without
`allow-scripts` get the script too (WebKit runs user scripts in them). The self-test makes peer
connections from such frames, reached by index or by `contentWindow`, and finds them relay-only
with no host or srflx candidate; it also checks that no worker has RTCPeerConnection
([ISOLATION_AND_LIMITATIONS.md](ISOLATION_AND_LIMITATIONS.md) §5). A popup's first, blank
document runs no user script: the opener's copy patches the popup as `window.open` (or
`document.open` with three arguments) returns it, and closes it when that patch did not take, so
the page gets null. The self-test opens both kinds, and one after the page broke
`Object.defineProperty`. Another way to run script in a window of the page before its copy runs,
or a WebKit change in how a configuration is read, would not be covered. WebKit offers no engine-level backstop short of WebRTC off: no setting forces
relay-only, restricts the interfaces or sockets WebRTC uses, or proxies its UDP or TURN
(read in WebKit's source, 2026). Without a proxy, or
with the default WebRTC setting (Disabled), WebRTC is off in the engine and none of this
applies. A network-level backstop would need a content filter (`NEFilterDataProvider`, another
system extension and approval) that drops UDP from this app's WebKit process except to the
relay subnets. It is not built.

The tunnel carries WebRTC only. WebTransport, whose QUIC WebKit also opens without the data
store's proxy (measured by the leak check), is off in every proxied profile
([ISOLATION_AND_LIMITATIONS.md](ISOLATION_AND_LIMITATIONS.md) §4).

## Requirements and real limitations

- **A paid Apple Developer Program team.** The packet-tunnel and system-extension-install
  entitlements are restricted: provisioning profiles must allow them for the app and for the
  extension. Developer ID profiles support both. The free tier supports neither, and ad-hoc
  signing cannot load the extension. Apple needs no separate request. A default build
  (`scripts/build-app.sh`) claims none of these entitlements and has no extension. The tunnel
  sheet says so, and proxied profiles keep WebRTC off.
- **User approval, twice, by an administrator.** The first approval is for the system
  extension: System Settings → General → Login Items & Extensions → Network Extensions (ⓘ) →
  on. On macOS 14 it is Privacy & Security → Allow. The second is the "add VPN configurations"
  prompt. **Open System Settings** uses `SMAppService.openSystemSettingsLoginItems()` on
  macOS 15+, and the Privacy & Security URL on 14. Installing a system extension needs an
  administrator, and the app must run from /Applications. CI runners cannot approve extensions
  (that needs user-approved MDM), so CI compiles and lays out the extension but does not load
  it.
- **Per-app VPN.** Apple's routing documentation describes per-app VPN on macOS for
  MDM-managed apps (`com.apple.vpn.managed.applayer`). TN3134 (2025) lists a managed-device
  requirement only for iOS and visionOS, and DTS has shown `NETunnelProviderManager.forPerAppVPN()`
  with `NEAppRule` on macOS. None of this is tested here. It would not separate profiles in any
  case: the rule matches an app, and WebKit's processes serve every profile.
  `NEPacket.metadata` is filled in only in per-app mode. Hence the destination-address design
  above.
- **The tunnel is system-wide.** Any process of any user on the Mac that sends to
  192.0.2.0/24 or fd6b:3a1c:94e2:1::/64 enters the tunnel. Only the relay addresses answer:
  - TURN requests need the per-launch credentials that the app gives its own pages (401
    otherwise), so nothing else can use a relay as an open UDP relay through the proxy;
  - a STUN Binding is answered only on an allocation's own 5-tuple, so it tells nothing to
    anyone else.

  While the tunnel runs, macOS shows a VPN.
- **One packet-tunnel VPN at a time.** WireGuard, Tailscale and most VPN apps are packet
  tunnels as well. Starting this tunnel disconnects theirs. That happens on the first launch of a
  profile with a SOCKS5 proxy and a WebRTC setting other than Disabled. Starting theirs stops
  this one and switches its configuration off, and the sheet then asks for **Enable** again. A
  personal VPN (IKEv2 via NEVPNManager) can run alongside.
- **When the tunnel stops under a running profile**, its relays become unreachable and WebRTC
  fails. The page and its peers never see this Mac's address: the policy is relay-only, and
  nothing answers without the per-launch password. The packets to the relay addresses then
  follow the default route instead: out of the physical interface from this Mac's address
  toward TEST-NET-1 (not routed on the Internet), or into another VPN. They carry the
  per-launch username and the realm `privacybrowser.relay` in clear.
- **The proxy must relay UDP.** SOCKS5 without TLS, with UDP ASSOCIATE. Many SOCKS5 services,
  and `ssh -D`, do not support it. The allocation then fails (508) and the page gets no
  candidates. An HTTP CONNECT proxy cannot carry UDP at all. The advertised relay port assumes
  the proxy maps an association to one external port for every destination
  (endpoint-independent). If it does not, ICE still connects through peer-reflexive
  candidates.
- **Apple does not support this use.** TN3120 says not to use a packet tunnel provider to host
  a network listener or proxy server (this extension terminates a TURN relay per profile), nor
  to claim some traffic and proxy it out elsewhere. DTS added in 2026 that a packet tunnel
  without a VPN server is unsupported. Developer ID needs no App Review, so nothing blocks
  shipping it, but OS updates may change behaviour without notice.
  The transparent-proxy provider (`NETransparentProxyProvider`) is the supported way to claim
  flows by destination. Apple DTS observed it running alongside a packet-tunnel VPN. It is the
  route to take if VPN coexistence matters more.
- **Not yet run on a Mac: the extension itself.** CI cannot load a system extension. These
  parts are compiled but have never run:
  - activation and approval, and saving and starting the VPN configuration;
  - provider messages, and the provider's packet I/O (`packetFlow`);
  - IPv6 through the tunnel, re-registration on reconnect, and VPN coexistence;
  - two profiles at once through the real extension;
  - and whether the extension's utun is gathered on as the raw utun was.

  CI runs the protocol code, the SOCKS5 relay against real WebKit, and (where `sudo` works) the
  extension's router on a raw utun interface (below). If a real tunnel were not gathered on,
  `defaults write <bundle id> PBTunnelAllInterfaces -bool YES` has libwebrtc gather on every
  interface, the tunnel's own included. It uses WebKit's `_enumeratingAllNetworkInterfacesEnabled`,
  and only for profiles whose WebRTC goes through the tunnel. This opens more allocations.

## Building it

1. In the developer account, create two App IDs:
   - the app (`$BUNDLE_ID`): Network Extensions, System Extension and App Groups;
   - the extension (`$BUNDLE_ID.PacketTunnel`): Network Extensions and App Groups.

   Both use the app group `$TEAM_ID.$BUNDLE_ID`.
2. Create a Developer ID provisioning profile for each, for the Developer ID Application
   certificate. For testing on a registered Mac, use Development profiles and an Apple
   Development identity with `NE_SIGNING=development`; the entitlement value is then
   `packet-tunnel-provider` instead of `packet-tunnel-provider-systemextension`.
3. Build:
   ```sh
   NE=1 TEAM_ID=ABCDE12345 BUNDLE_ID=com.example.PrivacyBrowser \
     SIGN_IDENTITY="Developer ID Application: Name (ABCDE12345)" \
     APP_PROFILE=app.provisionprofile EXTENSION_PROFILE=tunnel.provisionprofile \
     scripts/build-app.sh
   ```
   This builds the `PacketTunnelExtension` product and lays it out as
   `Contents/Library/SystemExtensions/$BUNDLE_ID.PacketTunnel.systemextension` (Info.plist with
   `NSSystemExtensionUsageDescription`, `NEMachServiceName` under the app group,
   `NEProviderClasses` → `PacketTunnelExtension.PacketTunnelProvider`, and a new
   `CFBundleVersion` per build). It embeds both profiles, signs the extension, then signs the app
   with the extra entitlements (hardened runtime, secure timestamp).
4. Notarize and staple:
   ```sh
   ditto -c -k --keepParent build/PrivacyBrowser.app PrivacyBrowser.zip
   xcrun notarytool submit PrivacyBrowser.zip --keychain-profile <profile> --wait
   xcrun stapler staple build/PrivacyBrowser.app
   ```
5. Copy the app to /Applications and open it. In the Profiles window, choose More (⋯) →
   WebRTC through proxies (network extension)…, press **Enable**, and approve both prompts.
   **Open System Settings** goes to the page where the extension is switched on.

`NE=check scripts/build-app.sh` is what CI runs. It builds the extension unsigned beside the
app, lints its plists and checks that the class named in `NEProviderClasses` is in the binary.

## What CI verifies

- `TunnelCore` (every push, Linux and macOS):
  - the STUN codec against RFC 5769's vectors (integrity, fingerprint, XOR addresses), and the
    IPv4/IPv6 UDP packets against independent vectors;
  - SOCKS5 framing;
  - the TURN flows as libwebrtc drives them: 401 challenge, idempotent Allocate, egress in
    Allocate and in Bindings on the allocation's 5-tuple, nothing to other 5-tuples, failing
    proxies, permissions and channels (unpadded ChannelData), oversized datagrams, refresh and
    expiry, the peer policy, the IPv6 family;
  - two profiles with different proxies through one router.
- The extension and the app compile against the macOS SDK, and the bundle layout is checked
  (`NE=check`).
- `scripts/leak_check.py` runs a profile behind a real SOCKS5 proxy with UDP ASSOCIATE (the
  script's own) through the same `TURNServer` and `SOCKS5UDPRelay` code as the extension. The
  TURN server listens on a UDP socket of the runner instead of a virtual address
  (`TURNUDPHost`, `--capture-sites` profile option `"relay": "harness"`). It checks that the
  page's candidates are relays at the proxy's address, that no srflx or host candidate appears,
  that the proxy saw the UDP, and that a data channel between two connections carries a
  message.
- Where passwordless `sudo` works (the CI runner), `PrivacyBrowser --utun-relay` opens a utun
  interface as root without the Network Extension (`UTunDevice`). It routes the relay subnets
  into it and serves two routes, each with its own UDP-capable proxy, with the extension's own
  `PacketRouter`, on real IP packets from real WebKit. One profile keeps WebKit's default network
  selection and the other gathers on every interface (`PBTunnelAllInterfaces`). Measured on
  macOS 26.6, both profiles got:
  - relay candidates at the proxy's address, and a data channel delivered through the proxy;
  - their TURN traffic from the utun's own addresses;
  - IPv6 allocations that reached the router and failed cleanly (the runner has no IPv6 egress).

  Whether they get candidates is reported. A srflx or host candidate, or the relay's url shown
  to a page, fails the run as for every proxied profile.
- The shim tests: the page's configuration, ICE event urls and `getStats()` urls, and the
  tampering attacks above.

## Hardware checklist (a signed build on a real Mac)

1. Enable the tunnel. The sheet shows "On". `systemextensionsctl list` shows the extension
   activated and enabled.
2. Run a SOCKS5 proxy with UDP on another host (Dante, sing-box, or 3proxy with UDP enabled).
   Then launch a profile behind it whose WebRTC setting is Relay only or Unrestricted. The
   default, Disabled, keeps WebRTC off and never starts the tunnel. The tunnel connects (VPN
   icon), and `log stream --level info --predicate 'subsystem == "PrivacyBrowser.PacketTunnel"'`
   shows the route.
3. Run `sudo tcpdump -ni en0 'udp and not port 53'` and `sudo tcpdump -ni utunN`. Open a
   WebRTC leak test page (browserleaks.com/webrtc). Check that:
   - no UDP from WebKit leaves en0, except to the proxy's UDP relay port;
   - utun shows the TURN exchange with 192.0.2.10:3478;
   - the page shows relay candidates at the proxy's address only.
4. If TURN packets show on en0 toward 192.0.2.x instead (not seen with the raw utun in CI), the
   tunnel interface was not gathered on and the enforced routes did not catch the sockets. Try
   `PBTunnelAllInterfaces` (above) and repeat.
5. IPv6: with an IPv6 default route and a proxy with IPv6 egress, a second relay candidate
   with the proxy's IPv6 address appears.
6. Two profiles behind different proxies at once, both with WebRTC not Disabled. Each page
   shows its own proxy's addresses, and a call between them connects.
7. Start another VPN app. This tunnel stops, and WebRTC in the running profile fails without
   showing this Mac's address. The sheet shows the configuration off. **Enable** takes over
   again, and disconnects the other VPN.
8. Update: build again (a new `CFBundleVersion`), copy to /Applications and launch.
   `systemextensionsctl list` shows the new version activated without a new approval.
9. Quit the app with a proxied profile running: the VPN indicator goes away. Force-quit it
   instead: the tunnel stops within about 10 minutes, or at the next launch.
10. Turn the extension off in System Settings. The sheet shows the warning, and a proxied
    profile launches with WebRTC off.
