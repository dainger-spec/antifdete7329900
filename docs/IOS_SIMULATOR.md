# iPhone profiles on Apple's iOS Simulator — reconnaissance

Status, 2026-10-29: **not in the product, not decided.** One question decides it, and
`scripts/ios_simulator_spike.sh` answers it by measurement on a Mac with Xcode (the CI runner of
this repository is not asked to: see [Running it](#running-it)). Until that run, everything below
that the script does not measure is marked **assumption**.

## The question

Can the traffic of **one** simulated device be sent into the proxy of **its** profile, while another
device goes through another proxy? If not, the feature is not built at all: an iPhone profile
without its own proxy has no place in this product.

Why the simulator: today an iPhone or iPad profile is our WKWebView on the Mac with an iPhone's
User-Agent, navigator and screen values (README, "iOS fidelity remains UA-level": TLS, GPU, fonts and
touch are the Mac's). The simulator runs Apple's iOS user space on the Mac — MobileSafari, iOS's
WebKit, iOS's fonts, touch input — which is much closer to an iPhone. What stays the Mac's in a
simulator (assumption, to be measured separately if the feature goes ahead): the kernel and its
TCP/IP stack, the GPU behind Metal, the CPU's core count and timing.

## What a competitor shows (the owner's observations, not verified here)

- BlackBird runs its iPhone profiles on the real iOS Simulator: its own setup dialog requires Xcode
  on the customer's Mac and downloads the iOS 26.5 runtime (8.52 GB) from Apple.
- It installs a system extension, `cc.blckbrd.BlackBirdMac.netproxy`, with the entitlements
  `app-proxy-provider-systemextension`, `dns-proxy-systemextension` and
  `content-filter-provider-systemextension`; its main app has
  `com.apple.security.cs.allow-dyld-environment-variables`.
- Reading (inference, not fact): a transparent or app proxy on the Mac takes the devices' flows,
  DNS is proxied too, and the content filter may be the fail-closed backstop — option C below. The
  DYLD entitlement only lets their own process accept `DYLD_*` variables; it does not by itself show
  that they inject into MobileSafari (option B).

## How a simulated device reaches the network

- A booted device is a tree of ordinary macOS processes under the device's `launchd_sim`:
  SpringBoard, MobileSafari, WebKit's WebContent and Networking processes, iOS's daemons — built for
  the simulator platform, running on the Mac's kernel. **There is no network interface per device**:
  every device and the Mac itself share the Mac's interfaces, addresses and routes. So a device
  cannot be routed by interface or address, only by process.
- A device reaches the Mac's loopback (`127.0.0.1`): the spike serves its test pages there.
- Proxy settings: the simulator follows the Mac's own system proxy settings — **assumption** (what
  proxy tools such as Charles and Proxyman document; not measured here: the spike changes no system
  setting). That is one proxy for every device and for the Mac's own apps: not per device.
- No setting per device (**assumptions**): the simulator's Settings app has no Wi-Fi page and so no
  per-network proxy; `simctl` has no proxy option (the spike prints `simctl help launch`'s
  `--setenv`, if any); Network Extension providers do not run inside the simulator (Apple's
  documentation).

## The options

| | Option | Covers | Checked by the spike | Cost and risk |
|---|---|---|---|---|
| A | Environment variables at Safari's launch (`SIMCTL_CHILD_*`) | if it worked: what reads them | step 6 — measured | none; expected not to work |
| B | A library injected into MobileSafari (`DYLD_INSERT_LIBRARIES`) that gives Safari's data store the proxy | Safari's page loads, names resolved by the proxy | steps 7–8 — measured, two devices at once | medium build, fragile, the rest of the device stays outside |
| C | A system network extension on the Mac (transparent proxy, DNS proxy, content filter) | everything every device does | step 5 — only its precondition | large: weeks, signing, entitlements, user approval |
| D | The Mac's system proxy | everything, but one proxy for all | not measured | not per device: out |
| E | A proxy inside the device (Settings, a configuration profile, an NE provider in the device) | — | no | not available (assumptions) |

### A. Environment variables at launch

`xcrun simctl launch` passes `SIMCTL_CHILD_<NAME>=value` from its own environment to the app it
launches, without the prefix (documented in `simctl help launch`). The spike relaunches Safari with
`http_proxy`, `HTTP_PROXY`, `https_proxy`, `HTTPS_PROXY`, `all_proxy` and `ALL_PROXY` pointing at the
self-test proxy, confirms they are in Safari's environment (`ps -E`), opens
`http://env-<run>.pbspike.invalid/` and asks the proxy whether it saw that name.

Expected: **no** (assumption). Apple's networking (CFNetwork, Network.framework) does not read these
variables — command-line tools such as curl do — and WebKit loads pages in its own Networking
process, an XPC service that does not take Safari's environment. It costs nothing to ask.

### B. A library injected into MobileSafari

The spike builds, in a temporary folder, a dylib for the simulator (`clang` from the iOS simulator
SDK, ad-hoc signed) and relaunches Safari with `SIMCTL_CHILD_DYLD_INSERT_LIBRARIES` naming it. The
dylib replaces `-[WKWebView initWithFrame:configuration:]` and `-[WKWebView
_initializeWithConfiguration:]` and, before each web view is built, sets its configuration's data
store's `proxyConfigurations` (iOS 17+) to an HTTP CONNECT or a SOCKS5 proxy (`nw_proxy_config_*`)
named in Safari's environment. It is the API and the layer the Mac app holds Safari's chrome to its
profile's proxy with (`ProfileNetworkGuard`): on macOS 27 the initializer was measured to be the one
place every content web view passes (docs/LEAK_AUDIT.md, item 1). The proxy is chosen per Safari
launch, and every device has its own Safari process — so per device.

The spike measures, in order: whether the dylib loads at all (it reports to the page server and to
the device's log); whether a page under a name that resolves nowhere (`inj-<run>.pbspike.invalid`)
then reaches the self-test proxy — it can load in no other way; and, if so, two devices at once —
device A through the HTTP CONNECT side, device B through the SOCKS5 side — each page through its own
proxy and never the other's.

What B leaves outside, even when it works:

- MobileSafari's own requests that are not page loads (Safe Browsing, search suggestions, icons
  and other services; the same kind as on the Mac, docs/LEAK_AUDIT.md item 8) — **assumption**;
- the device's daemons (iOS's own services), which leave from the Mac's address — the spike prints a
  snapshot of the device's processes holding connections past loopback;
- WebRTC (UDP), which WebKit opens itself: to be turned off by the same dylib, as on the Mac.

Risks: whether dyld in the simulator honours `DYLD_INSERT_LIBRARIES` for Apple's own MobileSafari
(library validation) is unknown until the spike runs, and any Xcode can close it; MobileSafari's
internals change per iOS version (the hooks sit on WebKit's API, the stable layer, but Safari may
build web views another way); one dylib per simulator architecture. Fail-closed — no page, ever,
from the Mac's address — needs more than the dylib: a device whose Safari was started without it
(SpringBoard relaunches Safari after a crash, without our variables) would browse directly. That
gap is what C closes.

Effort if the spike says yes (estimate): a working prototype — device lifecycle per profile, the
dylib, launch, the proxy per device — 1–2 weeks; fail-closed hardening (Safari relaunched without
the dylib, WebRTC, Safari's own services, the daemons) 2–4 weeks, part of which needs C anyway;
then maintenance with every iOS runtime.

### C. A system network extension on the Mac

A transparent proxy provider (`NETransparentProxyProvider`, or `NEAppProxyProvider` in transparent
mode) as a system extension sees each new TCP or UDP flow on the Mac together with the process that
opened it (`NEAppProxyFlow.metaData`: the source's audit token and signing identifier). A flow from a
process of device A — a process under A's `launchd_sim`, or one with A's files open
(`…/CoreSimulator/Devices/<UDID>/`) — goes to A's proxy; device B's to B's; everything else passes.
Names: a DNS proxy provider for the devices' DNS, or the flow's hostname where it carries one
(`remoteHostname`) — **assumption**: not every flow carries one, so the DNS proxy is needed for
fail-closed. A content filter drops whatever a device sends that did not go through its proxy.

This is the only option that covers everything a device does, Safari's pages and iOS's daemons
alike. The spike measures only its precondition (step 5): when Safari in device A opens a page on
the Mac's loopback, which host process holds that connection, and whether it is one of device A's —
if a device's connections could not be told apart by their process, C could not work either.

Cost: the largest. A Developer ID-signed, notarized app with the Network Extension entitlements
above (a paid Apple Developer team), the user's approval in System Settings, an always-on component
that sees all of the Mac's traffic (a trust and privacy burden for the customer), 4–8 weeks
(estimate) before the leak tests. The repository already builds a packet-tunnel system extension
(docs/TUNNEL.md) — another provider type, the same signing and activation — which has not yet run
on a Mac.

### D. The Mac's system proxy, and E. what is not available

D: the simulator uses the Mac's proxy (assumption): one proxy for all devices and the Mac's own
apps. Out — it is not per device, and the spike does not change system settings to show it.

E (assumptions): no Wi-Fi proxy setting inside the simulator; a configuration profile with a global
HTTP proxy needs a supervised device on iOS and was not tried in the simulator; Network Extension
providers do not run inside the simulator; macOS has no network namespaces, and a macOS user per
device would need a login session per device.

## What a booted device costs

| | Figure | Source |
|---|---|---|
| Disk, once | Xcode (10+ GB) and an iOS runtime (8–9 GB; BlackBird's dialog: 8.52 GB for iOS 26.5), from Apple | owner's observation; Apple's download sizes vary per version |
| Disk, per device | a data folder that grows with use (hundreds of MB) | assumption |
| Memory, per device | 1–2 GB with Safari and a page open | **assumption**; the spike measures it |
| Boot | tens of seconds per device | the spike prints it |
| CPU and GPU | idle devices little; every device shown in Simulator.app renders through Metal | assumption |

The spike measures memory two ways and prints both: the physical footprint (top's `MEM`, summed over
every process of the device — the figure to plan with) and the resident size (`RSS`, which counts the
simulator's shared libraries again in every process, so it overstates). It also prints how many
devices would fit at the measured footprint, leaving 6 GB to macOS, our app and Simulator.app.

At 1.5 GB per device (assumption), the same rule gives: MacBook Air with 8 GB — 1 device; 16 GB —
6; 24 GB — 12; 32 GB — 17. That is booted devices; a device that is shut down costs only disk, so
profiles beyond that would be started and stopped as they are used.

## What does not carry over

Our features live in our own process, around our own WKWebView. In the simulator the browser is
Apple's MobileSafari, in another process, with its own data:

| Feature | Today (macOS profile) | In MobileSafari | How it could be rebuilt | Estimate |
|---|---|---|---|---|
| Warm-up robot | our WKWebView: pages, scripts in an isolated world, real wheel events | nothing of ours runs there | the B dylib runs the robot's scripts in Safari's web views; or Web Inspector's remote protocol (the simulator's `webinspectord_sim`, what Safari's Develop menu uses) drives pages from outside; or XCUITest drives Safari's UI | 2–5 weeks |
| Cookie import and export | the profile's WKHTTPCookieStore | Safari's data store, in the device's data folder | the dylib's access to Safari's cookie store; or Safari's cookie files of a stopped device (format and location per iOS: assumption) | 1–2 weeks |
| Password AutoFill | our user script and our vault | Safari's own AutoFill, on the device's keychain | the dylib's user script and a channel to our vault (as `ProfileChannel`) | 2–3 weeks |
| Time zone, geolocation, language | our scripts and the process's settings | the device's own settings | per device: language and region in the device's preferences (`simctl spawn … defaults write`), location by `xcrun simctl location`; time zone — not known yet (assumption) | days to 2 weeks |
| Encryption at rest, sync, export | our sealed WebKit folders, our archive | the device's folder, in plaintext while it exists | seal the device's folder when it stops, with the existing archive code | 1–2 weeks |
| Leak tests | self-test, egress capture, disk trace | none yet | the egress capture already tells processes apart; a CI job with the simulator | 1–2 weeks |

Together: 2–4 months of work on top of whichever routing option, with upkeep for every iOS runtime.
What it buys: an iPhone that is iOS's own WebKit, fonts and touch, not our Mac WKWebView dressed as
one.

## Licence

Xcode and its simulator come under the Xcode and Apple SDKs Agreement, which licenses them to
develop and test apps. Whether a commercial product may run the iOS Simulator as its customers'
browser is a question for a lawyer, not settled here — a competitor doing it says nothing about
whether it is allowed.

## Running it

```sh
scripts/ios_simulator_spike.sh            # says what it will do, asks, then runs (5–10 minutes)
scripts/ios_simulator_spike.sh --show     # the same, with Simulator.app open to watch the devices
scripts/ios_simulator_spike.sh --one      # one device only (less memory; no per-device proof)
scripts/ios_simulator_spike.sh --keep     # keep the devices it made, to look at them afterwards
```

It needs Xcode with an iOS simulator runtime (iOS 17 or later for B) and changes no system setting:
it starts the self-test proxy and a page server on 127.0.0.1, creates and boots up to two devices
named "PB spike …", builds the dylib in a temporary folder, and deletes the devices at the end. It
never downloads a runtime — without one it stops and says how to get it. The pages it opens go
nowhere but this Mac (names under `.invalid`, which only the proxy answers, and loopback); a booted
device's own iOS services may reach Apple, as in any simulator — the snapshot at the end lists them. Everything it prints is
also written to `ios-simulator-spike-<run>.txt` in the current folder: that file is the result to
send back.

How to read its last lines:

- **YES — measured** (two devices, each through its own proxy): B works for Safari's pages. The
  feature is possible; what is left is to measure and close the device's other traffic (C as the
  backstop) before anything ships.
- **YES FOR ONE DEVICE**: run it again without `--one`.
- **YES — environment variables**: unexpected, and the cheapest path; to be confirmed with two
  devices like B.
- **NOT WITHOUT A SYSTEM EXTENSION**: nothing inside the device took a proxy, but a device's
  connections can be told apart by process: only C remains, and its cost decides.
- **NO**: the feature is dropped, as decided.

GitHub's macOS runners come with Xcode and iOS simulators (assumption about the current image), so
the spike could also run as a manual CI job; that is a change to `.github/`, made only if asked.
