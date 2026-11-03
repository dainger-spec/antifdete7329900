# WebRTC through a profile's proxy: the relay and the network guard

WebKit sends a data store's HTTP(S), WebSocket and media loads through the store's proxy, but
opens its WebRTC sockets (STUN, TURN, media) itself, from this Mac's own address. Without help a
proxied profile has to run with WebRTC off (ISOLATION_AND_LIMITATIONS §5). Two pieces are that
help, and they are kept apart on purpose:

- **the relay** carries a profile's WebRTC: a TURN server on 127.0.0.1 inside the app
  (`WebRTCRelays`), one per running profile, whose every allocation leaves through that profile's
  SOCKS5 proxy (UDP ASSOCIATE). Sites and peers see the proxy's address;
- **the network guard** carries nothing: a content-filter system extension
  (`NetworkGuardExtension`) that holds the processes of such a profile to its proxy. Their
  connections — and what WebKit's processes and the system open on their behalf — may reach the
  proxy and this Mac (127.0.0.1) only; everything else is dropped.

A profile gets WebRTC through its proxy only when every condition holds (`WebRTCGate`); with the
first that does not, WebRTC is off in the engine (no `RTCPeerConnection` at all) and the person is
told why, in words, with what they can do.

| Traffic of a proxied profile | Path | How it is known |
|---|---|---|
| HTTP(S), WebSocket, fetch, media loads (TCP) | the data store's proxy (`proxyConfigurations`, fail-closed) | self-test, leak check |
| QUIC / HTTP/3 | not used: with a store proxy WebKit sends these requests as HTTP/2 through the proxy | leak check (cloudflare-quic.com) |
| DNS of pages | resolved by the proxy (SOCKS5 remote DNS, CONNECT host names) | self-test |
| WebRTC: STUN, TURN, media, data channels (UDP) | **the relay** on 127.0.0.1 → the profile's SOCKS5 UDP association; the page's own ICE servers are never contacted | self-test (a video call inside a capture of every packet of the runner), leak check, unit tests |
| A peer's candidate named by a host name (FQDN, mDNS `.local`) | dropped before the engine sees it: nothing is resolved | shim tests, self-test (no packet carries the name) |
| Anything else a held profile's process or WebKit's processes for it open | dropped by the network guard | unit tests of its rules; on a Mac: the check below |
| WebRTC with an HTTP CONNECT proxy, a proxy without UDP, a proxy whose UDP leaves from another address than its TCP, the guard not ready | off, said why | self-test (the controls: off, not direct) |

A page cannot send other UDP: WebRTC is the only UDP a web page can start.

## Status (3 November 2026): measured, and the layout changed — the app's own executable keeps library validation on

0.1.1 with the network guard (`NE=1`), signed with Developer ID and notarized by Apple, did not
start on the owner's Mac (macOS 27.0.1, build 26A434, J713): release.sh's release check ended with
`Killed: 9` (137), and the kernel's log said:

```
AMFI: When validating …/Lumen.app/Contents/MacOS/Lumen:
  Hardened Runtime relaxation entitlements disallowed on System Extensions
mac_vnode_check_signature: … code signature validation failed fatally
AMFI: hook..execve() killing env (pid 8697): Attempt to execute completely unsigned code
ASP: Security policy would not allow process
```

The app's executable was signed with `com.apple.application-identifier`,
`com.apple.developer.networking.networkextension` = `content-filter-provider-systemextension`,
`com.apple.developer.system-extension.install`, `com.apple.security.application-groups` and
`com.apple.security.cs.disable-library-validation`. CI could not have shown it: the kernel lets no ad
hoc signature carrying these rights start, so CI's `NE=check` build never has them, and the extension
is never loaded there ("What CI verifies").

The same day `scripts/amfi_matrix.py` measured on the owner's Mac which signature the kernel lets
start (the table below). The rule it found: **an executable holding
`com.apple.developer.networking.networkextension` and any relaxation of the hardened runtime of one
class — library validation off, unsigned executable memory, DYLD environment variables — is killed at
its start.** Neither the right to install a system extension nor the extension in the bundle has a
part in it; `allow-jit` is not of that class.

What changed (the decision below, "Where the relaxation lives"):

- the app's own executable, `Contents/MacOS/Lumen`, keeps library validation on, in every build; it
  keeps the network guard's rights. `Contents/MacOS/LumenProfile` has library validation off and none
  of those rights. Safari's frameworks were only ever loaded there: in a profile's process
  (`SafariChromeHost.prepareForChildProcess`) and in the checks that run Safari's code;
- build-app.sh refuses, and removes, a build in which one executable holds a relaxation beside the
  right, read from every executable's signature (`scripts/relaxation_check.sh`, with the measured
  list; `allow-jit` is not on it). release.sh reads it again before notarizing, and requires the app's
  own executable to keep library validation on;
- release.sh's step 1b stays: before anything is sent to Apple's notary, the kernel must let the app's
  executable and LumenProfile, as signed, start (`scripts/start_check.sh`). It fails a build the
  kernel kills at its start whatever the reason — a process killed at `execve` never answers its
  probe. The matrix asked each copy that same question (`--keychain-probe`, one line or none), and
  every copy holding a relaxation beside the right gave none; running the start check itself on those
  copies is in the hardware checklist (step 0).

Not yet shown, and what shows it: the rebuilt 0.1.1 with this layout through release.sh, the
extension installed on the owner's Mac, and the hardware checklist below. Whether the app's
executable, without library validation off, configures the filter through `NEFilterManager` is
answered there, by step 1: it keeps the provider right, and the guard reaches "Working" only after
that process loaded the filter's configuration and, at the first install, saved it
(`NetworkGuard.configureFilter`; a failure there is logged as `filter configuration: …` and leaves
the guard off). If the app's executable turns out unable to do something it needs to without library
validation off, the measured fallback is `app-dlv-no-provider` — the relaxation kept, the provider
right taken off the app's executable — which started too; whether the filter can then still be
configured is measured only if that fallback is ever needed.

## What the kernel kills (measured 3 November 2026)

On the owner's Mac — macOS 27.0.1 (26A434) — `scripts/amfi_matrix.py` took the NE=1 0.1.1 release
release.sh had signed, and made copies of it, each with the app's executable (`Contents/MacOS/Lumen`)
signed again with the team's Developer ID and one thing changed; LumenProfile, the updater's helper
and the extension stayed as signed. For each copy: does the kernel let the app's executable start (it
answers `--keychain-probe` on one line and ends, or it is killed at its start), does LumenProfile
start and load Safari's frameworks (`--check-safari-chrome`), and where both do, the release check.
Every copy kept the application identifier, the app group and the team, which were not in question.
"Killed" and "started" are the owner's report of that run.

| Copy | The app's executable signed with (besides camera and microphone) | Extension in the bundle | The app's executable | What it proves |
|---|---|---|---|---|
| `shipped` — 0.1.1 as released | library validation off; the provider right; `system-extension.install`; application identifier, app group, team | yes | **killed** — the kernel's log above | the failure itself |
| `app-dlv-no-install` | library validation off; the provider right; **no** `system-extension.install` | yes | **killed** | the right to install a system extension has no part in it |
| `bundle-no-extension` | as shipped | **no** — `Contents/Library/SystemExtensions` taken out | **killed** | the extension in the bundle has no part in it |
| `app-unsigned-memory` | **`allow-unsigned-executable-memory` instead of** library validation off; the provider right; install | yes | **killed** | the rule is a class of relaxations, not library validation alone |
| `app-dyld-env` | **`allow-dyld-environment-variables` instead**; the provider right; install | yes | **killed** | the same |
| `app-jit` | **`allow-jit` instead**; the provider right; install | yes | started | `allow-jit` is not of that class |
| `app-dlv-no-provider` | library validation off; install; **no** provider right | yes | started | without the provider right a relaxation is let through — the fallback |
| `app-no-dlv` | the provider right; install; **no relaxation** | yes | started; LumenProfile started and loaded Safari's frameworks; **the release check passed** — the keychain between profiles: profiles A and B `refused (1100)` by both securityd services, the control outside a profile's sandbox wrote its item and read it back | **the layout chosen** |

The control `resigned` (signed again with the same entitlements: it must end as `shipped`, or the
table says nothing) and the copies `app-dlv-neither` and `bundle-no-extension-neither` are not in the
summary the owner sent; the report itself (`build/amfi-matrix/report.md`, with the kernel's lines
for each copy) stays on the owner's Mac. The copies other than `shipped` are notarized only when the
matrix is run with `--notary-profile`.

What it does not say: anything about macOS other than 27.0.1, nor about relaxations it did not try —
`disable-executable-page-protection` and `debugger` are refused beside the right all the same
(`scripts/relaxation_check.sh`: refusing costs nothing, letting one through would be a guess).

What CI shows of it (it cannot sign with Developer ID): the relaxation check lets the builds made
there through, refuses a copy of the release's app for each relaxation beside the right — and the
right given to LumenProfile — and lets through the right alone and `allow-jit` beside it; build-app.sh
refuses a build signed as 0.1.1's app was and leaves no bundle; and the start check fails a copy
whose app's executable has its signature taken off — the kernel of Apple silicon runs no unsigned
code, "Attempt to execute completely unsigned code", the line that ended 0.1.1. What CI's kernel does
with 0.1.1's pairing signed ad hoc is measured there and said, not checked: CI has no Developer ID and
no provisioning profile, and its kernel started an ad hoc copy carrying an application identifier (CI
run 666) — the start check's earlier control, which therefore could not fail and was replaced. The
start check's verdict on the pairing as signed by Developer ID is taken on the owner's Mac (the
hardware checklist's step 0). Before it was committed, the relaxation step was run against four
broken versions of the check — one
that lets everything through, one that refuses everything, one that reads the right under a wrong
name, one with `allow-jit` on its list — with stand-ins for codesign and PlistBuddy: each turned it
red.

## The decisions (2 November 2026)

**Which of the three kinds of network extension: a content filter.** A packet tunnel and an app
proxy both *carry* traffic: whatever they are handed, they send somewhere. A mistake in either
can send a profile's packets around its proxy — and an extension able to carry traffic around the
proxy is worse than no WebRTC. A content filter (`NEFilterDataProvider`) can only let a flow
through or drop it. Ours is sandboxed and has no `network.client` or `network.server`
entitlement, so it cannot open a connection of its own (scripts/build-app.sh refuses a build that
gives it one). The carrying is the relay's, in the app's own process, where it is ordinary code
with ordinary tests. The tunnel, besides, was a VPN: only one runs at a time on macOS (starting
it stopped WireGuard, Tailscale, …), macOS showed a VPN while it ran, and Apple's DTS calls a
packet tunnel without a VPN server unsupported. A filter runs beside any VPN.

**Inside our bundle, not an app beside it.** The extension is
`Contents/Library/SystemExtensions/<id>.systemextension` inside Lumen.app: macOS lets only the app
that contains a system extension install it, the app must be in /Applications, and when Lumen is
moved to the Trash macOS removes its extension. One signature, one notarization, one update: the
updater replaces Lumen.app and the extension with it.

**Where the relaxation lives: chosen by the measurement of 3 November, not by taste.** 0.1.1 was
killed at its start because its app's executable held library validation off beside the provider
right ("What the kernel kills"). The ways out, each with what was measured:

- **Library validation off for LumenProfile alone; the app's executable keeps it on and keeps its
  rights (`app-no-dlv`) — chosen.** Measured: it starts, LumenProfile starts and loads Safari's
  frameworks, and the release check passes, the keychain between profiles included. Nothing changes
  for a person: one app, one install, one update. It costs nothing in the code: Safari's frameworks
  were only ever loaded in LumenProfile's processes.
- **The relaxation kept, the provider right taken off the app's executable (`app-dlv-no-provider`) —
  the fallback.** Measured: it starts. Not chosen: the app's executable is what configures the filter
  (`NEFilterManager`), and whether it can without the right is not measured; it is measured only if
  `app-no-dlv` turns out unable to do something it needs to.
- **An app of its own beside Lumen.app for the extension — rejected: not needed.** It was the way out
  if every layout inside our bundle was killed; the measurement found one that is not. It would have
  been a second thing to install, update and trust, with its own notarization and its own approval in
  System Settings.
- **`allow-jit` instead of library validation off — not a way out.** Measured: let through beside the
  right, but Safari's frameworks need library validation off, not JIT. Listed for what it showed: the
  rule is a class of relaxations, and `allow-jit` is not in it.
- **No system extension at all** — a proxied profile keeps WebRTC off, as every release without
  `NE=1` does. Not needed either.

**How UDP support of the proxy is known before the profile gets WebRTC.** At the launch, while the
profile's process waits (it builds no web view before the answer, up to 40 s), the manager asks
the proxy the way the relay will use it: a SOCKS5 UDP ASSOCIATE, then a STUN Binding through the
association (`ProxyUDPCheck`). Only an answer through the association counts as support. Without
one the profile starts with WebRTC off and the launch says: "the proxy does not pass UDP (UDP
ASSOCIATE refused, or nothing came back through it); WebRTC needs a SOCKS5 proxy with UDP". If the
check could not finish, it says that instead. An HTTP CONNECT proxy is refused without asking:
it cannot carry UDP.

**One address: the proxy's UDP must leave from where its TCP does.** A site sees the pages come
from the proxy's TCP exit and WebRTC from its UDP egress; two different addresses tell it the
profile goes through a proxy — worse than no WebRTC. So at the same time as the UDP check the
manager asks where the proxy's TCP leaves from (`ProxyExitLookup`): Cloudflare's trace
(`https://1.1.1.1/cdn-cgi/trace`, then `1.0.0.1`) through the proxy only — whatever the profile's
bypass list says — by address, so nothing is resolved and the answer can only be the IPv4 exit;
Cloudflare's STUN server is asked by the UDP check already, so no other party learns of the
launch. The relay only when the STUN answer's address and the trace's are the same; every
allocation of the relay is then held to that address (`TunnelRoute.exit`): a proxy that sends a
later association's UDP from elsewhere — a pool, a rotation since the launch — gets no relayed
address for it (403), and an IPv6 relay next to an IPv4 exit none either. Different addresses:
"its proxy sends UDP out from another address than its TCP"; no exit found: "the address its
proxy leaves from could not be found out", and if it repeats, that the proxy does not let the
check through.

**When and how the permission is asked: once, explained first, never by itself.** Nothing is
asked at the app's start. Installing starts only from Settings › WebRTC through proxies (the
editor and the launch message point there), with **Install…**. Lumen first says what macOS is
about to ask and why (`guard.explain.*`): (1) "System Extension Blocked" — turn on "Lumen network
guard" in System Settings › General › Login Items & Extensions › Network Extensions, which only an
administrator can; (2) "Lumen would like to filter network content" — Allow. Then macOS asks, once.
The page then follows the state (`NetworkGuard`): awaiting approval (where to click), off (Turn
On), a restart needed, /Applications needed, an administrator needed, management (MDM) forbids it,
the configuration declined — each said with who can do what.

**Updates.** The extension's `CFBundleVersion` is new with every build. At each start the app
compares the enabled extension's version with its own bundled one; when they differ (the app was
updated) it asks macOS to activate its own, which replaces the old one without a new approval
(same team, same identifier). The app answers only an extension of its own version: until the
replacement is done the guard is "not answering" and WebRTC stays off for new launches. An
update of Lumen quits it first, so no profile is held across it. The extension never updates by
itself: it comes only inside Lumen.app.

## Architecture

```
 profile process (pid P, SOCKS5 proxy X)          manager process (Lumen)
 ───────────────────────────────────────          ──────────────────────────────────────────────
 page: RTCPeerConnection                           WebRTCRelays: TURNUDPHost on 127.0.0.1:port
   iceServers := [turn:127.0.0.1:port] (only)        per-launch username/password, 401 otherwise
   iceTransportPolicy := relay                       allocation → SOCKS5 UDP ASSOCIATE @ X
   (user script; the page sees its own config)       │                       (TCP control + UDP)
        │                                            ▼
 WebKit network process (for P)                    the proxy X ─────────► peers, STUN servers
   TURN client ──── UDP to 127.0.0.1:port ───────► (their only route)

 every new flow of the Mac ─► NetworkGuardExtension (content filter, root, sandboxed, no network)
                               flow counted for a held pid (P)? → its rules: loopback, X, DNS for
                               X's own name — else drop.   Anything else → allow, unread.
```

- **Every profile runs in a process of its own** (`ProfileProcess`), and WebKit gives each process
  its own network process. The guard tells profiles apart by the process each flow is counted for
  (the flow's *source application*: for WebKit's network process and for the system's resolver,
  the process they work for), so it holds exactly one profile's flows.
- **The relay is in the manager**, not in the profile's process: a profile process with a proxy has
  the kernel refuse it every UDP datagram (`ProfileNetworkGuard.closeTheProcess`), and stays so.
  On 127.0.0.1 nothing outside this Mac can reach the relay; any process of this Mac can, and needs
  the launch's own credentials (401 otherwise). Measured with WebKit's own TURN client (CI runs 609,
  610, 612, macOS 26.6.2 and 27.0.1): relay candidates only, at the proxy's address; a data channel
  and a video call through the proxy; 0 packets of the app outside loopback but to the proxy.
- **The order at a launch** (`ProfileManager.decideWebRTC`): the guard's state (once asking macOS
  is over) → the proxy's UDP (above) → the gate → the guard holds the process (pid P) → the relay
  starts → the process is told; any step that fails is WebRTC off, said once. When the process
  ends the guard releases it by itself (the kernel tells it the process exited); the app releases
  it too.

### The relay: TURN for libwebrtc

`TunnelCore/TURNServer.swift` (RFC 8656 subset): UDP allocations, long-term credentials
(HMAC-SHA1, MD5 key), stateless nonces, idempotent Allocate per 5-tuple, Refresh,
CreatePermission, ChannelBind, Send/Data indications, ChannelData. What libwebrtc needs:

- the first Allocate goes out without credentials and needs a 401 carrying REALM and NONCE; a 401
  or 438 on the authenticated Allocate is fatal; every authenticated success carries
  MESSAGE-INTEGRITY; an Allocate success needs XOR-RELAYED-ADDRESS, XOR-MAPPED-ADDRESS and
  LIFETIME; REQUESTED-ADDRESS-FAMILY is never sent;
- the TURN server is also asked as a STUN server from the allocation's socket. A Binding is
  answered only on a 5-tuple that holds an allocation, with its relayed address — the proxy's
  egress, **never the client's own address**. A 5-tuple whose Allocate failed gets 500; any other
  gets nothing (an unauthenticated answer would tell any local process a profile's proxy address);
- the proxy's egress is found per allocation with a STUN Binding through its association; the STUN
  servers' names are resolved by the proxy;
- the egress is the relayed address only when it is the proxy's TCP exit the launch found
  (`TunnelRoute.exit`, "One address" above); any other — another address of a pool, an IPv6
  egress next to an IPv4 exit, a route without a known exit — gets 403 and its association closed;
- peers are Internet addresses only: CreatePermission and ChannelBind are refused (403) for
  loopback, link-local, private, shared (CGNAT), multicast, reserved and documentation addresses
  and IPv6 forms of IPv4 ones — those would be reached on the proxy's side.

### The network guard

`Sources/NetworkGuardExtension` (the filter and its Mach service), `Sources/NetworkGuardCore`
(its rules, platform-independent, tested on Linux and macOS: `GuardPolicyTests`).

- **What it sees.** A content filter is asked about every new socket flow of the Mac
  (`NEFilterSettings(rules: [], defaultAction: .filterData)`: a rule can name networks and ports,
  not processes). A flow counted for a process the app did not register — any other app, Lumen's
  own updates, account and sync, a profile without WebRTC — is let through at once, unread, and
  not noted anywhere. That the filter sees the start of each new flow (address, app) is what macOS's
  "filter network content" prompt means; the guard keeps none of it.
- **The rules for a held process** (`GuardPolicy.verdict`): loopback (the relay, this Mac's own
  services); the proxy, by the name the flow was opened by with its port, or by an address the app
  resolved for it (any port: a proxy's UDP relay port is its own); DNS over UDP only when every
  question asks for the proxy's own name (each datagram looked into); everything else — another
  host, the local network, multicast, DNS over TCP, a flow whose remote end is not known, another
  transport — is dropped.
- **Who may ask it.** The app reaches it through its Mach service (`NEMachServiceName`, under the
  team's app group) with XPC; the extension lets in only Lumen of its own team
  (`setCodeSigningRequirement`), and holds only processes whose code is Lumen of that team. The app
  talks only to an extension with its identifier and its own team.
- **When it goes away** (crashed, switched off in System Settings, replaced): the app notices at
  once (the XPC connection is interrupted; the configuration's change notification; while it holds
  anything, it asks every 5 s whether the filter still runs). The relays of held profiles stop at
  once and those profiles are stopped (sealed as on any stop), with a message saying why. A
  restarted extension is given every hold again; one it does not take back stops its profile.

### Attribution: the check on each Mac

The guard holds a profile only if macOS counts WebKit's flows for the profile's process. That is
a property of macOS and WebKit, so it is checked, not assumed: once per macOS build, WebKit
version and guard version (`NetworkGuard.prove`). A probe process of this app (`Lumen
--guard-probe`, nothing of the person's in it) is held to a proxy that is not there; then one of
its pages asks a STUN server at a documentation address (203.0.113.1, TEST-NET-3, never routed)
with WebKit's own WebRTC. The guard must report that flow as opened by another process for the
probe, and dropped (`GuardProof.holds`). Until it has, the guard is "not yet checked on this Mac"
and WebRTC stays off in proxied profiles; a failed check is said as such, with Check Again. CI
cannot load the extension, but it runs the same probe inside a capture: every packet of the
probe's request must be sent by another process and counted for the probe's pid
(`scripts/guard_probe_check.py`, with its own control).

### What a page sees

- `getConfiguration()` returns the page's own `iceServers` and policy. The engine still
  validates them and throws its own errors, through a closed peer connection made from them that
  never gathers.
- Candidates are of type `relay` only, at the proxy's egress address. libwebrtc prints their
  related address as `0.0.0.0 0` (`:: 0` for IPv6).
- `RTCPeerConnectionIceEvent.url` and the `url` of candidate entries in `getStats()` would name the
  relay (127.0.0.1); the user script replaces it with the page's own server, in libwebrtc's form,
  or `null` / no field when it configured none.
- STUN servers the page configured are not contacted.
- A peer's candidate named by a host name (in `addIceCandidate`, or an `a=candidate` line of a
  remote description) is dropped before the engine sees it, and the page is told success, as for
  a candidate the engine could not reach. Through the relay a peer is reached by its address
  alone; resolving the name would ask this Mac's resolver, outside the proxy.
- This differs from Safari without a proxy (mDNS host and srflx candidates). A page can tell the
  profile uses a relay-only policy, as with any TURN-only setup.

### Enforcement: the page first, the guard behind it

WKWebView has no setting that forces relay-only or limits ICE servers, so the document-start
user script keeps a page on the relay. It uses only built-ins captured before any page script
ran, gives the engine null-prototype objects with own data properties, reads each value of the
page once and gives the engine that copy, and never hands the native constructor or methods to
anything the page can replace (the shim tests attack it: replaced `Reflect`, `call`/`apply`,
`Object.*`, iterators, `WeakMap`/`Promise` methods, accessors on `Object.prototype`, getters and
`toString`s that answer differently each time). It remains page-level code; that is why the guard
exists. If the script were defeated, libwebrtc would try the page's servers and peers directly —
the guard drops each of those flows, because they are counted for the held profile.

## Fail closed: what each state does

| State | WebRTC in a proxied profile | What is said |
|---|---|---|
| A build without the guard (no `NE=1`) | off | "this version has no network guard" (release) / how the developer builds it |
| Not installed, awaiting approval, off, a restart needed | off | the state and the next step |
| Installed, not answering (updating, crashed) | off; held profiles are stopped | "not answering", Check Again; a stopped profile says why |
| Installed, not checked on this Mac / check failed | off | "being checked" / "the check failed", Check Again |
| Ready, HTTP proxy | off | "an HTTP proxy cannot carry UDP" |
| Ready, SOCKS5 without UDP / UDP unknown | off | "the proxy does not pass UDP" / "could not find out" |
| Ready, the proxy's UDP leaves from another address than its TCP | off | "its proxy sends UDP out from another address than its TCP" |
| Ready, the proxy's TCP exit could not be found out | off | "the address its proxy leaves from could not be found out" |
| Running, a later association of the proxy leaves from another address | that allocation refused (403): no relayed address, nothing sent | nothing new: the call fails as with a dead proxy |
| Ready, the guard does not take the process, the relay does not start | off | "the guard did not take the profile's process, or its relay did not start" |
| Ready, all of it holds | through the relay and the proxy | the editor and the inspector say so |
| The sandboxed build (profiles inside the app's process) | off | "only for a profile in its own process" |

## Requirements and real limits

- **The team's Network Extensions capability** with the content-filter entitlement
  (`content-filter-provider-systemextension` for Developer ID, `content-filter-provider` for
  development), and the System Extension capability for the app; provisioning profiles for both.
  Granted since 31 October 2026. A default build (`scripts/build-app.sh`) claims none of these and
  has no guard; proxied profiles keep WebRTC off and say so.
- **An administrator's approval, once**, and Lumen in /Applications.
- **CI cannot load the extension** (macOS needs the approval; runners have no MDM). CI builds and
  lays it out (`NE=check`), tests its rules, runs the relay and the whole call with the self-test
  standing in for the guard, and runs the probe inside a capture. The extension itself — its
  activation, its filter on a real flow, the check above, a crash under a held profile — runs only
  on a real Mac with a signed build (the checklist below).
- **The proxy must relay UDP.** SOCKS5 without TLS, with UDP ASSOCIATE; many SOCKS5 services, and
  `ssh -D`, do not. TURN over TCP and TLS are not carried (UDP only).
- **…from the address its TCP leaves from.** Providers that send UDP out of another pool or
  another address than TCP, or rotate the exit per connection, get no WebRTC: the launch says so,
  and an allocation whose association leaves from elsewhere is refused while the profile runs. A
  proxy that blocks requests to 1.1.1.1 and 1.0.0.1 gives no exit to compare with: no WebRTC
  either. An IPv6 egress is never relayed (the exit is the IPv4 one).
- **What the filter sees.** The start of every new flow of the Mac passes through it (it lets all
  but a held profile's through at once). If the extension were not running at all, macOS would let
  flows through: that is why the app stops held profiles the moment it stops answering, and why
  the page-level enforcement stays in front.
- **A crash of the extension** leaves, until the app reacts (milliseconds), a held profile's flows
  unfiltered; its relay stops and the profile is stopped. The page-level enforcement holds in that
  time.
- **Loopback is allowed** to a held profile (the relay is there). A page that defeated the user
  script could reach this Mac's own services on 127.0.0.1; it could not reach the Internet.
- **The keychain stays the app's.** The application identifier and app group an `NE=1` build
  carries open the data-protection keychain to the process that holds them. A profile's process is
  refused securityd by its own sandbox, whatever it holds — neither that keychain nor the account's
  login keychain — and is started from `Contents/MacOS/LumenProfile`, signed without them; the app
  refuses to start one from an executable that has them (docs/IDENTITY.md, "The keychain"; closed
  2–3 November, shown by the self-test and by the release check on the signed build).

## Building it

1. The App IDs (docs/IDENTITY.md): the app (`io.lumenbrowser.Lumen`: Network Extensions, System
   Extension, App Groups) and the extension (`io.lumenbrowser.Lumen.PacketTunnel` — registered on
   31 October under that name, kept: Network Extensions, App Groups). Both use the app group
   `$TEAM_ID.$BUNDLE_ID`.
2. Developer ID provisioning profiles for both (or Development ones with
   `NE_SIGNING=development`).
3. Build:
   ```sh
   NE=1 TEAM_ID=ABCDE12345 SIGN_IDENTITY="Developer ID Application: Name (ABCDE12345)" \
     APP_PROFILE=app.provisionprofile EXTENSION_PROFILE=guard.provisionprofile \
     scripts/build-app.sh
   ```
   It builds `NetworkGuardExtension`, lays it out as
   `Contents/Library/SystemExtensions/$EXTENSION_ID.systemextension` (Info.plist with
   `NEProviderClasses` → `com.apple.networkextension.filter-data` only, `NEMachServiceName`
   `$APP_GROUP.guard`, `PBGuardAppIdentifier`, a new `CFBundleVersion`), checks that the class is in
   the binary and that its entitlements give it no network, signs it, then the app.
4. Notarize and staple (docs/UPDATES.md §6), copy to /Applications, open Settings › WebRTC through
   proxies, Install….

## What CI verifies

- `NetworkGuardCoreTests` (Linux, macOS): every rule — loopback, the proxy by name and address,
  STUN, TURN/TCP, the local network, mDNS, DNS questions (the proxy's name only), malformed DNS,
  audit tokens, the ledger, the check's verdict.
- `TunnelCoreTests`: the STUN codec against RFC 5769, SOCKS5 framing, the TURN flows as libwebrtc
  drives them, the peer policy, IPv6.
- `WebRTCGateTests`: every combination of setting, proxy, process, guard state and UDP answer
  (the same address, another one, the exit unknown).
- `TURNServerTests`, one address: the exit's address on another port is relayed; another address,
  no exit, an IPv6 egress next to an IPv4 exit get 403, no allocation, the association closed;
  the trace's parser.
- The shim tests: the page's configuration, urls, tampering, named candidates.
- `NE=check`: the extension compiles, its plists lint, the provider is the filter alone, its
  entitlements give it no network.
- The layout the kernel lets start ("What the kernel kills"): in the builds made there the app's own
  executable keeps library validation on and LumenProfile has it off; `scripts/relaxation_check.sh`
  lets them through, refuses copies of the release's app holding each relaxation beside the provider
  right (and LumenProfile given the right), and lets through the right alone and `allow-jit` beside it;
  build-app.sh refuses a build signed as 0.1.1's app was and leaves no bundle behind; the start check
  fails a copy whose app's executable is unsigned (the kernel of Apple silicon runs no unsigned code),
  and what CI's kernel does with 0.1.1's pairing signed ad hoc is measured and said.
- The self-test, inside a capture of every packet of the runner: a profile with a SOCKS5 proxy
  with UDP, in its own process, makes a real video call between two peer connections through the
  relay and the proxy (relay candidates at the proxy's address only, frames decoded on the far
  side, the proxy's associations carried it); its peer's named candidates are taken and no packet
  carries their names; the control: the same profile without the guard has no RTCPeerConnection
  at all (not direct WebRTC), and says why. One address: the gate's comparison against the proxy's
  UDP with its trace saying the same exit (relay, held to it), another one, none (no relay); and a
  launch whose proxy's UDP leaves from elsewhere has no RTCPeerConnection and says why. A profile
  without a proxy sends a STUN request on purpose, which the capture must see (the capture's own
  control).
- `scripts/guard_probe_check.py`: the probe's request is counted for the probe (and the check
  fails with a pid that is not the probe's).

## Hardware checklist (a signed build on a real Mac)

0. The build: `NE=1 scripts/release.sh` passes — the relaxation check, the start check (step 1b),
   notarization, `--check-safari-chrome` and the release check (step 2b). The start check run by hand
   on the matrix's copies (`build/amfi-matrix/<copy>/Lumen.app/Contents/MacOS/Lumen`) fails every copy
   holding a relaxation beside the right, with the kernel's lines, and passes `app-no-dlv`, `app-jit`
   and `app-dlv-no-provider`.
1. Settings › WebRTC through proxies › Install…: the explanation, then macOS's two questions.
   `systemextensionsctl list` shows the guard activated and enabled; the page shows "Being checked"
   and then "Working". This answers whether the app's executable — the provider right, library
   validation on — configures the filter (`NEFilterManager`): "Working" comes only after it did; a
   failure is logged as `filter configuration: …` (`log stream --predicate 'subsystem ==
   "PrivacyBrowser" AND category == "NetworkGuard"'`).
2. `log stream --predicate 'subsystem == "PrivacyBrowser.NetworkGuard"'` shows the probe held,
   its flow dropped, and the check proven.
3. A SOCKS5 proxy with UDP on another host (Dante, sing-box, 3proxy). A profile behind it with
   WebRTC not Disabled: browserleaks.com/webrtc shows relay candidates at the proxy's address only.
   `sudo tcpdump -ni en0 'udp and not port 53'`: no UDP of Lumen's or WebKit's but to the proxy.
4. A video call (meet.jit.si) between that profile and another device: it connects; the other
   side sees the proxy's address.
5. A profile behind a SOCKS5 proxy without UDP (`ssh -D`): WebRTC off, the launch says why.
6. Two profiles behind different proxies at once, each with its own proxy's address.
7. Switch the guard off in System Settings with a profile running: the profile stops and says why;
   a new launch has WebRTC off.
8. Update: a new build to /Applications, launched: `systemextensionsctl list` shows the new
   version, no new approval; the check runs again once.
9. Another VPN app on (WireGuard, Tailscale): it keeps running; step 3 again.

## History: the packet tunnel (until 2 November 2026)

The first design carried WebRTC in a packet-tunnel system extension: a TURN relay per profile on a
virtual address (TEST-NET-1 /24, a unique-local /64), routed into the tunnel, relaying through the
profile's proxy. It was never run on a Mac. It was replaced because it carried traffic (a mistake
could send it around the proxy), was a VPN (one at a time; a VPN icon; unsupported by Apple
without a VPN server), relied on libwebrtc gathering on the tunnel's interface (measured only with
a raw utun in CI), and could not tell profiles apart by process — the reason the relay addresses
existed. Each profile now has its own process, so the guard can hold it by process, and the relay
needs no virtual address: 127.0.0.1 is enough.
