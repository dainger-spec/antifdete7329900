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
  forwards captured TCP and UDP to the exit (the profile's proxy, or this Mac's interface),
  dropping UDP when the exit proxy cannot carry it. The proxy password is read from the keychain
  via the protocol's `passwordReference`, never from the configuration dictionary.
- `Info.plist` — the extension's `NSExtension` declaration (`com.apple.networkextension.packet-tunnel`).
- `PacketTunnel.entitlements` — the `packet-tunnel-provider` entitlement and the app-group used to
  share the keychain item with the container app.

## Status — honest

**Control plane: complete.** Configuration decode, tunnel network settings, keychain password
read, start/stop, and fail-closed start are done.

**Datapath (`Relay.swift`): a fail-closed scaffold, not yet a working forwarder.** The read loop
and the UDP-drop policy are in place, but the TCP/IP flow reassembly and the SOCKS5/HTTP relay
(including SOCKS5 UDP ASSOCIATE) are **not implemented** — they need a userspace stack and must be
built and tested on real hardware, which CI cannot do. Until a flow's relay is wired, its packets
are **dropped, never forwarded in the clear**, so the fail-closed guarantee holds: with the tunnel
on and the datapath incomplete, a profile gets no traffic rather than a leak. Do not treat the
tunnel as functional for real browsing yet; the model, control plane, UI and docs around it are
complete, and the datapath is the remaining work, called out in `Relay.swift` and
`../docs/NETWORK.md`. The code has no dependency on `BrowserCore`, so the extension stays well
under the memory limit the system gives a packet-tunnel provider.
