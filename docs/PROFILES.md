# Profiles, snapshots, cookies and fail-closed networking

This is the design and current state of the profile system. The logic lives in
`vm/controller-app/Sources/VMControllerCore/` (built and unit-tested on Linux
and macOS); the app and CLI drive it.

## Profiles on snapshots

A **profile is one Tart VM**, cloned from a base image, with its own persistent
disk, proxy, cookies and settings. The profile list is a JSON file
(`ProfileStore`) at `~/Library/Application Support/VMLauncher/profiles.json`,
written atomically. Each profile stores: `id`, `name`, `proxy`, `lastURL`,
`baseImage`, `clipboardShared`, `cookieCount`, timestamps
(`Sources/VMControllerCore/Profile.swift`).

### The snapshot model — and what Tart actually offers

Tart has **no `snapshot` command**. Two facts give us snapshots anyway:

1. `tart clone <src> <dst>` makes a full, independent copy of a VM.
2. A VM's disk **persists across `run`/`stop`** — stopping a VM keeps whatever
   changed on its disk.

So the lifecycle maps as (`ProfilePlan`):

| Action | Tart | Why |
|---|---|---|
| **Create profile** | `tart clone <base> pb-<name>-<id>` | the clone is the profile; its disk is the "snapshot" |
| **Run** | `tart run pb-<name>-<id> …` | boots from the profile's persistent disk = its last state |
| **Close** | `tart stop pb-<name>-<id>` | disk already holds the new state — the save is automatic, no command needed |
| **Delete** | `tart delete pb-<name>-<id>` | removes the VM (and any backups) |
| **Restore point** (optional) | `tart clone pb-<name>-<id> pb-<name>-<id>--<label>` | an explicit rollback copy |

"Snapshot on close" is therefore **inherent**, not a separate step: because the
disk persists, closing the VM *is* saving the snapshot. An explicit restore
point is an extra clone (`ProfilePlan.backup`).

## Fail-closed networking

**Goal: a profile's VM reaches the internet only through its proxy; with no
proxy it has no internet at all** — it fails closed, never open.

Mechanism: Tart's **softnet** backend with an egress allowlist.

- **Proxy set (an IP):** `--net-softnet --net-softnet-allow <proxy-ip>/32`.
  The VM can open connections only to the proxy; everything else is dropped at
  the host. All real traffic goes through the proxy.
- **No proxy / unresolved hostname proxy:** `--net-softnet --net-softnet-allow
  127.0.0.1/32` — loopback only, i.e. **no route off the host**. The VM boots
  and the agent is still reachable over the SSH tunnel (that's host→guest, not
  guest egress), but the VM itself cannot reach the internet.

`NetworkPolicy.failClosed(proxy:)` encodes this (tested): IP proxy →
`proxyOnly`, everything else → `isolated`. The controller takes
`TART_NET=softnet` + `SOFTNET_ALLOW=<cidr>`.

### DNS and WebRTC leaks

- **DNS:** with softnet dropping all non-allowlisted egress, the VM cannot reach
  any DNS server directly — not even port 53 to a public resolver — so there is
  no plaintext DNS leak around the proxy. Name resolution must happen **at the
  proxy**: use a `socks5h://` proxy (SOCKS5 with remote DNS) or an HTTP proxy,
  which resolve on the proxy side. A `socks5://` (local-DNS) proxy would try to
  resolve in the VM and simply fail to connect — fail-closed, not leak.
- **WebRTC:** WebRTC can reveal IPs via STUN/TURN. Under softnet those STUN
  packets go nowhere unless the STUN server is the proxy, so they cannot leak
  the host's real address past the proxy. Defense in depth (planned): the agent
  can also disable WebRTC ICE in Safari (`defaults`/WebKit pref) per profile.

### Why this is a guarantee, not a setting in the guest

The allowlist is enforced on the **host**, by softnet, outside the guest. Even
if something in the VM is misconfigured, it still cannot send a packet past the
allowlist. Bridged/NAT modes (`TART_NET=bridged|shared`) are **not** fail-closed
and are for development only.

> Requires the softnet helper (`brew install cirruslabs/cli/softnet`) and that
> Tart build's softnet support. This has not been run end-to-end here (no Apple
> Silicon Mac); the argv and policy are unit-tested, the live behavior is to be
> verified on hardware.

## Cookies per profile

`CookieImport` parses the two formats people have — Netscape `cookies.txt`
(curl/wget/extensions) and JSON arrays (EditThisCookie, Cookie-Editor) — into a
normalized `[Cookie]` and serializes the JSON the agent consumes. Stored per
profile at `…/VMLauncher/profiles/<id>/cookies.json`. Parsing, formats and
round-trip are unit-tested.

**Applying them in Safari is not done yet.** Safari keeps cookies in a binary
store (`~/Library/Cookies/Cookies.binarycookies`) under the app sandbox, so the
agent will apply them by writing that store (or via a small WebKit helper)
before launch, then starting Safari. That step needs a Mac to build and verify
and is the next cookie task.

## Roadmap (the rest of the backlog)

Done here (core, tested on Linux/macOS CI):

- [x] Profile model + JSON store (name, proxy, lastURL, clipboard, cookies, base)
- [x] Snapshot lifecycle → exact `tart` argv (`ProfilePlan`)
- [x] Fail-closed network policy + `TART_NET=softnet`/`SOFTNET_ALLOW` in the controller
- [x] Cookie import parser (Netscape + JSON) + per-profile storage
- [x] `VMController profiles list|add|remove` CLI over the store
- [x] Clipboard shared = off by default in the model

Next (need macOS to build/verify the UI and guest bits):

- [ ] Agent applies cookies in Safari; agent installed once + LaunchAgent
      survives reboot (verify); controller skips reinstall when present
- [ ] Menu-bar app: profile list, click-to-launch, running-VM count
- [ ] Logging to a host file + "Show log" button + clear VM-crash messages
- [ ] Export/import a profile as one archive (snapshot + settings), Mac-portable
- [ ] Base-image update: check, background download, migrate/warn
- [ ] Resource display: RAM of running VMs, disk per profile, low-RAM warning
- [ ] Onboarding + splash: Tart/image check cached between runs, progress with
      benefit cards, cancel; fast path when the image already exists
- [ ] Native light macOS UI pass (System Settings style, SF Pro)
- [ ] Per-profile clipboard toggle surfaced in the UI

These are tracked so the UI work builds on this foundation rather than
re-deriving it.
