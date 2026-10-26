# PacketTunnel — the per-profile single-exit tunnel

This directory holds the macOS **Network Extension** that gives a profile one exit IP for TCP and
UDP (see `../docs/NETWORK.md`). It is **not** part of the Swift package: `swift build`,
`swift test` and the default `scripts/build-app.sh` never compile it, so CI and the ordinary
ad-hoc `.app` build stay green with no Apple Developer setup.

It is built and embedded only with `NE=1`:

```bash
NE=1 TEAM_ID=XXXXXXXXXX SIGN_IDENTITY="Developer ID Application: You (TEAMID)" \
  scripts/build-app.sh
```

That requires a paid Apple Developer account, an App ID with the **Packet Tunnel** capability
(`com.apple.developer.networking.networkextension` = `packet-tunnel-provider`) for both the app
and `…​.PacketTunnel`, and matching provisioning profiles. Without it, macOS refuses to load the
extension and the app's "Единый выход для TCP/UDP" toggle stays unavailable — by design.

## Files

- `PacketTunnelProvider.swift` — the `NEPacketTunnelProvider` subclass. Reads the profile's
  `TunnelConfiguration` from `providerConfiguration`, sets up the tunnel's network settings, and
  hands the packet flow to `Relay`. The proxy password is read from the keychain
  via the protocol's `passwordReference`, never from the configuration dictionary.
- `Relay.swift` — the datapath: forwards captured TCP, UDP and DNS to the exit (the profile's
  proxy, or this Mac's interface), dropping UDP when the exit proxy cannot carry it.
- `offline-tests/` — stand-ins for the Apple APIs plus scenario tests that drive `Relay` with
  hand-built packets; `offline-tests/run.sh` type-checks the provider and runs them with plain
  `swiftc` (Linux or macOS). Not a substitute for the `NE=1` build and the hardware checklist.
- `Info.plist` — the extension's `NSExtension` declaration (`com.apple.networkextension.packet-tunnel`).
- `PacketTunnel.entitlements` — the `packet-tunnel-provider` entitlement and the app-group used to
  share the keychain item with the container app.

## Status — honest

**Control plane: complete.** Configuration decode, tunnel network settings, keychain password
read, start/stop, and fail-closed start are done.

**Datapath (`Relay.swift`): forwards real traffic.** TCP is terminated in a small userspace TCP
endpoint and relayed per flow over SOCKS5 `CONNECT` / HTTP `CONNECT` (TLS to the proxy if
configured) or directly; WebKit's own connections to the proxy are passed through raw (one hop);
UDP goes over SOCKS5 `UDP ASSOCIATE` (SOCKS5 without TLS), directly (no proxy), or is dropped (HTTP
CONNECT / SOCKS over TLS); DNS to the tunnel resolver 10.111.0.1 is answered by forwarding over TCP
through the exit; IPv6 is captured and refused. The provider resolves the proxy's address before
the tunnel takes over DNS. A flow whose relay does not come up is reset or dropped — never sent in
the clear. Details, limits and the **verification status** are in `../docs/NETWORK.md`: it has
been exercised off-device only, so **run the manual checklist there on a Mac with `NE=1`** before
relying on it. The code has no dependency on `BrowserCore`, so the extension stays
well under the memory limit the system gives a packet-tunnel provider.
