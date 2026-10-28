# Isolation model and platform limitations

This document lists what is isolated, what is only approximated, and what is not
addressed. It also gives a way to verify each claim on your own machine. The code
comments marked `PLATFORM LIMITATION` / `FINGERPRINTING LIMITATION` point back here.

## 0. What is verified automatically

`PrivacyBrowser --self-test` runs headless against the real WebKit of the machine. CI runs it
on every push (macOS 26 runner, built with the current Xcode) for both the sandboxed and the
unsandboxed build, with a local test proxy (`scripts/selftest_proxy.py`). Last observed results
(macOS 26.6.2, 236/236 checks in both builds):

| Claim | Self-test result |
|---|---|
| Vault key derivation | a PBKDF2 vault is re-wrapped under Argon2id (64 MiB, 3 passes, 4 lanes) in the release build and opens again; the time is logged |
| Sandbox active; vault inside the container | writes outside the container are denied; vault at `~/Library/Containers/<id>/Data/Library/Application Support/PrivacyBrowser` |
| WebKit data location (undocumented) | sandboxed: `Container/Data/Library/WebKit/WebsiteDataStore/<uuid>`; unsandboxed: `~/Library/WebKit/<bundle-id>/WebsiteDataStore/<uuid>`. One directory per store; no separate cache directory was observed |
| Seal → restore of website data | cookies, localStorage and IndexedDB survive; the archive holds no plaintext; plaintext is gone after seal; WebKit released the store after 1 s |
| Two running profiles isolated | localStorage, IndexedDB and cookies of A are invisible to B, for the same origin, at the same time |
| JS shims under JavaScriptCore | time zone (offset, `Intl`, local getters; in WebKit's shared pool, as without the engine override below), fixed geolocation, WebRTC removed, WebRTC relay-only |
| Time zone in the engine | where WebKit has the process pool's time zone override (the self-test logs which private pieces it found; macOS 26.6.2 has `_WKProcessPoolConfiguration.timeZoneOverride` and `-[WKProcessPool _initWithConfiguration:]`, not the newer `+_processPoolWithConfiguration:`), two profiles in different zones running at once each report their own zone in the page, a frame, workers made from a blob and loaded from a URL, and shared and service workers that answer; `Date` and `Intl` are the engine's own (no shim); each profile has a pool of its own, and its shared and service workers carry its own User-Agent (what the same workers report in WebKit's shared pool is logged) |
| Storage quota in the engine | where WebKit has `_WKWebsiteDataStoreConfiguration` (macOS 26.6.2 has it), a persistent profile's store is made with Safari's quota: the page, workers made from a blob and loaded from a URL, and the service worker report 82 463 372 084 (macOS generation) or 41 231 686 042 (iPhone generation), and the store opens again from the same directories. An ephemeral profile keeps WebKit's in-memory store; the shim reports Safari's figure in its pages and blob workers |
| WebRTC off (default) | switched off in the engine (`_peerConnectionEnabled` is false). Without the shim WebKit then leaves the encoded transforms, a setting of their own (`RTCEncodedAudioFrame`, `RTCEncodedVideoFrame`, `RTCRtpScriptTransform` in the window; those and `RTCRtpScriptTransformer`, `RTCTransformEvent`, `onrtctransform` in a dedicated worker); the shim removes the window's three, so the window has no `RTC*` interface at all, and a default profile installs no worker hook |
| WebRTC relay-only: escape routes | no worker (blob, URL, shared, service) has `RTCPeerConnection`; peer connections made from frames sandboxed without scripts (empty, `srcdoc`, a same-origin URL, by index or `contentWindow`), from an ordinary frame by index, and from popups (`window.open`, `document.open(url, name, features)`, and one opened after the page broke `Object.defineProperty`) are all relay-only with no host or srflx candidate against public STUN servers, where a plain WKWebView gathers a srflx one |
| HTTP CONNECT proxy | `http://` is tunnelled via `CONNECT`; an `.invalid` host loads, so it was resolved by the proxy |
| SOCKS5 proxy | the hostname is sent to the proxy (`ATYP=3`, remote DNS) |
| Fail-closed | with the proxy unreachable, loads fail ("Could not connect to the server") instead of going direct |
| Tabs, history, bookmarks | tab open/close/reopen/select, visits and titles recorded, bookmark toggle persisted encrypted |
| Background tabs | a page opened behind the shown tab (⌘-click) measures what the shown tab does: viewport, the window's outer size and position — not 0×0; a tab shown and then left behind still does after the window is resized and moved |
| Window lifecycle (crash fix) | closing one of two windows keeps the profile running; closing the last reports "all closed" once, on a later run-loop turn; `shutDown()` twice is safe |
| Crash-recovery sealing | leftover website data from a crashed run is archived and deleted WITHOUT `WKWebsiteDataStore.remove(forIdentifier:)` (which aborted on an unknown id), then restores cleanly |
| Device generation → UA | a profile's generation UA reaches `navigator.userAgent`; an explicit custom UA overrides it |
| Container migration | an unsandboxed vault is moved into the container on the sandboxed build's first launch (separate CI step) |
| Fingerprint surface | a macOS profile measures the same as a plain WKWebView on the same Mac (navigator, screen, canvas, WebGL, audio, fonts, feature list) except for `window.safari` and the Fullscreen API, which Safari has and a bare WKWebView lacks. An iPhone or iPad profile measures the same as a plain web view set up as that device's Safari (its pixel ratio, its feature set), `MediaSource` on an iPhone apart (removed by the shim, §2). It reports its device class's navigator and screen values, its pixel ratio is the engine's own (`devicePixelRatio` 3 or 2, the resolution media queries agreeing), and Fullscreen, MediaSource, Notification and `screen.orientation` are as Safari on that device has them. User-installed fonts are hidden from pages, as in Safari. CI also compares the macOS profile with the runner's real Safari (§2) |
| Error stacks | an error a page provokes in what the shim replaces (a wrong receiver for: the navigator, screen and orientation getters, `outerWidth`, `contentWindow`, `window.open`, `document.open`, `Function.prototype.toString`, a rejected `estimate()`) has the stack a plain web view gives, with no frame of the shim's, in a macOS, an iPhone and an iPad profile (CI run 221; before the fix each showed a `@user-script:` frame, run 220) |
| Remote workers' User-Agent | the profile's own in its shared and service workers, or WebKit's bare default where WebKit's race left a worker without one (§2), never another profile's. Fresh iPhone profiles, 6 per setting and pass, CI runs 218–221 (8 passes, 48 profiles per setting): WebKit's own in 12 as shipped, 14 with Notification on, 11 with encoded transforms off |
| Shims in workers and frames | a worker made from a blob runs in the profile's zone, stays strict and keeps its line numbers, also on a page whose CSP has no `'unsafe-eval'`, `connect-src 'self'` and a `report-uri`: the site receives no violation report beyond the page's own controls (a blocked image, which is reported; an eval in a worker of its own, which the CSP blocks there — macOS 26.6.2 reports a page's violations, not a worker's), and the worker still reports the profile's zone, strict mode and the page's line numbers; with Trusted Types required, a worker from a `TrustedScriptURL`, or under the page's default policy, starts from the page's own URL; a frame reached as `window[i]` right after insertion is patched; `permissions.query({name:'geolocation'})` returns the engine's own `PermissionStatus`, 'prompt' until the page asks |
| Geolocation (deny, the default) | WebKit's own, in a profile window: `getCurrentPosition` and `watchPosition` get the engine's `PERMISSION_DENIED` ("User denied Geolocation"), the answer of the tab's UI delegate; the engine's `PermissionStatus` reads 'prompt' until the page asks and 'denied' after, and one the page held from before is told (it reads 'denied' and fires 'change' once); the next page starts at 'prompt' and stays so when another tab of the site asks; every other permission reads as in a plain WKWebView |
| Proxy: IPv6, unresolvable host | an HTTP proxy on `[::1]` tunnels the load; a proxy whose host does not resolve fails closed |
| Proxy: WebRTC | a proxied profile whose stored setting is "unrestricted" has no `RTCPeerConnection` or `RTCDataChannel` while the packet tunnel cannot carry it (§5) |
| Proxy: WebTransport | a proxied profile has no `WebTransport` in the page or in its blob, URL, shared and service workers: it is off in the engine, since WebKit sends its QUIC around the proxy (the leak check measured it, §4); a profile without a proxy has it in all of them, as Safari. With and without the proxy the profile's shared and service workers report its own User-Agent (CI runs 213–215: 12/12) |
| Packet tunnel | a build without the network extension reports it (the tunnel sheet says what a signed build needs), and proxied profiles keep WebRTC off. The tunnel's TURN server and SOCKS5 relay are measured by the leak check instead ([TUNNEL.md](TUNNEL.md)) |
| Proxy: WebSocket and media | in an HTTP CONNECT and a SOCKS5 profile, a WebSocket, an HLS stream (playlist and segment) and an MP4 file that a `<video>` plays (AVFoundation, not WebKit's loader) all reach the proxy, from a page on a host only the proxy resolves; a profile without a proxy loads the same streams (the control). Measured in a shown window: WebKit loads no media for a page that is not visible (CI run 221) |
| Proxy: beacons | `navigator.sendBeacon`, also from `pagehide` as the page goes away, reaches the proxy |
| Proxy: dns-prefetch leak | an `<a ping>` (the load type WebKit gives dns-prefetch) reaches neither the proxy nor the network; a fetch to the same origin does |
| Proxy: 407 without credentials | the launch is refused ("needs credentials") and the data is sealed again; nothing opens, directly or otherwise |
| Proxy: `Accept-Language` | the header the proxy sees is the language the app decided at its first launch (`de-DE,de;q=0.9` in the self-test) |
| Time zone from the proxy | a profile with a proxy and *Time zone of the proxy's location* runs in the time zone the lookup through the proxy returned, cached per profile |
| Several SOCKS5 profiles at once | three profiles behind three SOCKS5 proxies, one with username/password authentication, are launched together through the app's launch path and load at the same time: each page arrives through its own proxy, by name, with its own credentials; after one stops the others keep loading through theirs; wrong or missing SOCKS5 credentials fail closed |
| Launch speed | with a location remembered for the proxy, a launch waits at most 1 s for a 4 s lookup (the lookup finishes in the background, and its new time zone is remembered and noted for the next launch); with nothing remembered it waits at most 3 s |
| Proxy exit IP | with *Warn when the proxy's IP changes* on, a changed exit IP (same proxy and credentials) is reported, the first launch and an unchanged IP are not; the option is off by default and then nothing is reported or stored, and turning it off, or replacing the proxy, while a lookup is under way leaves no new IP stored and nothing reported |
| Password AutoFill | in a profile window on the self-test proxy's sign-in pages: the page world has no `window.webkit` and no trace of the script; a password a page script wrote and submitted is not offered; a typed sign-in is offered (Save, saved with its user name), a new password for it as Update, nothing anywhere on the site after Never for This Website; a login field lists the site's saved login and choosing it fills both fields with `input` and `change` (and `:autofill` where WebKit allows the world); a filled-in login submitted again asks nothing; a sign-in by script (fields removed after the button's click) and a sign-up form (new password = confirmation) are offered; a frame of another site is offered none, a frame of the same site its logins under a header naming it. Synthesized key events do not reach the page on the CI runner, so typing is stood in for by marking the fields typed inside the isolated world (reported by the self-test); real clicks and keys are used where they arrive |
| Cookie import | a Netscape file with CRLF, comments, an HttpOnly line and damaged bytes: the five readable cookies are read, the four other lines reported (field count, public suffix, expired, damaged text); into a stopped profile they are queued encrypted (no cookie value in the file) and put into its store at launch before the start page is requested: the request carries the host-only, domain, HttpOnly and session cookies, not the Secure one or another path's over http; the store holds each with the file's attributes; a cut-off JSON export's complete entry goes into the running profile at once and the next request carries it; after a stop (sealed) and a launch the persistent imported cookies are back and the session cookie is not |
| Profile sync (two devices) | a second vault bootstrapped from a sync folder with the master password stands in for another Mac: a cookie imported into the stopped profile on A joins the synced cookies at its launch, a page's persistent cookie at its stop (its session cookie not); the folder holds no cookie name, value or domain; on B the start page's first request already carries both; B's change of one and deletion of the other reach A's store before its first page; settings changed on both, B's later: B's on both Macs, A's kept as `config.bin.conflict` |
| Session warm-up robot | through the app's launch path behind the self-test proxy, with short waits: a plan of three pages, a `javascript:` line (skipped) and a page the proxy closes unanswered (reported, the robot goes on) is visited in order in a new tab of the profile, each page taken as visited only once it has come (never before the proxy was asked for it), and an address that only jumps within the page shown at once (also when the page then rewrites the fragment); the requests carry the profile's User-Agent and the cookies the pages before set; at the proxy, each page's followed link comes at least the plan's time after the page, and the next page at least half that after the followed one; each page is scrolled (the pages see trusted scroll events); from each page only the plain same-site link is followed, with the page as Referer — never the sign-out, other-site, file or new-window links next to it; while the robot scrolls and clicks, each page's own world sees no `window.webkit` and no robot global; history and the pages' cookies are kept; Stop during a page ends the run before its next page is requested; closing its tab and a page's alert stop it; stopping the profile stops it first (while its store is still there), and the profile's data then seals as usual. Whether wheel and mouse events reached the page or the script fallback was used is reported |
| ⌘Q | `terminate:` returns at once; every profile is sealed in the normal run loop; the second `terminate:` exits; WebKit released the store (normal seal, not forced); the sealed data restores |
| Forced seal | a store WebKit keeps through every retry is archived and its plaintext deleted only when quitting; a marker makes the next launch discard later residue; the archive restores |

Run it yourself: `build/PrivacyBrowser.app/Contents/MacOS/PrivacyBrowser --self-test`. For the
proxy checks, start the self-test proxy as CI does,
`python3 scripts/selftest_proxy.py --http 18080 --socks 18081 --http-auth 18082 --http6 18083 --socks2 18084 --socks-auth 18085`,
and set `PB_SELFTEST_HTTP_PROXY_PORT=18080 PB_SELFTEST_SOCKS_PROXY_PORT=18081
PB_SELFTEST_HTTP_AUTH_PROXY_PORT=18082 PB_SELFTEST_HTTP6_PROXY_PORT=18083
PB_SELFTEST_SOCKS2_PROXY_PORT=18084 PB_SELFTEST_SOCKS_AUTH_PROXY_PORT=18085`. Without a variable
its checks (407, IPv6, several SOCKS5 profiles at once) are skipped and the count is lower. The
self-test uses a temporary vault and removes everything it creates.

## 1. Storage isolation between profiles

**Mechanism.** Each persistent profile uses `WKWebsiteDataStore(forIdentifier: <profile UUID>)`
(made from `_WKWebsiteDataStoreConfiguration` with the same identifier where WebKit has it: the
same directories, with Safari's storage quota, §2).
Each ephemeral profile uses `WKWebsiteDataStore.nonPersistent()`. Every `WKWebView` of a
profile gets that store: every tab of every window, and popups, because
`createWebViewWith` uses the configuration WebKit passes in, which inherits the opener's
store.

**Isolated per store, by WebKit:** cookies, localStorage, sessionStorage, IndexedDB,
Cache API, service worker registrations, the HTTP disk and memory cache, HSTS state,
media keys, the per-session credential store, and Intelligent Tracking Prevention
classification.

**WebKit's default data store stays closed.** No `WKWebView` of the app is made with a
`WKWebViewConfiguration` whose store is left unset: that store is WebKit's default, persistent
one. With it opened, a profile's session cookies outlived its stop and came back at its next
launch, and on a second vault of the same profile. The self-test opened it once, for a
measurement, and both cookie checks failed in CI runs 218 and 219. With the store closed again
they passed (run 220). How WebKit links the two was not found.

**Within one profile:** all tabs share the profile's storage, like tabs in any browser.
Background tabs keep running. WebKit may throttle timers in views that aren't in a window.

**Shared between profiles:**

| Shared | Why | Effect |
|---|---|---|
| WebKit networking process | WebKit runs one network process per app, with one session per data store inside it | Isolation is per session (logical), not per OS process |
| Device fingerprint | see §2 | Profiles can be linked by fingerprinting |
| Downloads folder | Downloads go to `~/Downloads` in plaintext | Outside the encrypted storage |

## 2. Fingerprinting and "Apple device" consistency

**Short answer:** every profile runs on the macOS system WebKit, so to a site it *is* Safari-on-a-Mac.
That is genuine, not emulated. What a profile can change is the small set of attributes
the profile *declares*. What it cannot change is what the engine and the hardware *measure*.
This project does not make a Mac look like an iPhone, and doesn't claim to.

### What the public WKWebView / WebKit APIs let a profile control

| Attribute | Mechanism | Reach |
|---|---|---|
| Storage (cookies, localStorage, IndexedDB, cache, service workers) | `WKWebsiteDataStore(forIdentifier:)` | native, complete |
| Egress IP and DNS | `proxyConfigurations` (SOCKS5 remote DNS, fail-closed) | native, verified |
| User-Agent string (HTTP header + `navigator.userAgent`) | `customUserAgent` | native; changes the string only |
| Time zone | the profile's own process pool with WebKit's time zone override (SPI, where present; `ProfileProcessPool`), else a JS shim (`Intl`, `Date` getters, offsets) | in the engine: every scope, workers included; the shim: blob workers covered, URL-loaded and service workers not |
| Geolocation | deny: WebKit's own, the state answered by the tab's UI delegate (private API); fixed coordinates: JS shim | deny: native; fixed: approximation |
| WebRTC exposure | off in the engine (private `WKPreferences` property, as Lockdown Mode) or a JS shim (relay-only) | native when off; approximation for relay-only |
| WebTransport | off in the engine in a proxied profile (one of WebKit's features, private API), on otherwise | native; with a proxy it differs from Safari, which has it (§4) |

Keep the declared attributes consistent with each other: a Safari UA, plus a time zone and
geolocation that match the proxy's exit location. An inconsistent combination, such as a
Chrome UA on WebKit or a Tokyo time zone behind a Paris exit, is itself distinctive.

### Version-aware profiles (device generations)

Projects like iStealth tie a profile to a specific OS version and swap the browser *core*
when Apple ships a new one. With public APIs we can do the version *tagging* but not the
core swap. A profile carries a **device generation** (`DeviceGeneration` /
`DeviceGenerations` in `BrowserCore`): a target Apple OS version — currently macOS 26,
iOS 26, iOS 27, iPadOS 26 — chosen with the **Device / version** picker in the editor and
stored in the profile (`deviceGenerationID`, encrypted like the rest).

What a generation actually does, and only this:

- supplies the self-declared `User-Agent` for that version (overridable with a custom UA): the
  string Safari sends there. Safari on iOS 26.1 and later freezes the OS token at `18_7` (as
  macOS Safari freezes `10_15_7`; WebKit bug 298260), so an iPhone profile sends
  `iPhone OS 18_7 … Version/26.6` (iOS 26) or `Version/27.0` (iOS 27); `iPhone OS 26_0`
  is a string no Safari sends. iPadOS Safari shows desktop websites by default, so the
  iPadOS profile sends the Mac's UA and `navigator.platform` "MacIntel", with the iPad's
  touch points and screen (which is how a page tells such an iPad from a Mac). A mobile
  generation of the engine's own release (iOS 26 and iPadOS 26 on a Mac whose Safari is 26.x)
  names that release as major.minor, `Version/26.6` with Safari 26.6.2, as the macOS one names
  the host's version. iOS 27 keeps its catalog string. The picker offers it only to a profile
  that already has it, with a note: its UA names a release the engine is not;
- for an iPhone or iPad, sets what WebKit lets a web view change:
  - the device's pixel ratio, 3 or 2 (`-[WKWebView _setOverrideDeviceScaleFactor:]`, private).
    `devicePixelRatio` and the resolution media queries are then the engine's own and agree;
  - Safari's feature set on that device, as MDN's browser-compat-data has it. Fullscreen: on an
    iPad only (`isElementFullscreenEnabled`). MediaSource: on an iPad only;
    `ManagedMediaSource` stays on both. macOS 26.6.2's WebKit keeps `MediaSource` with
    `_setMediaSourceEnabled:` off, so the shim removes it from the window and blob workers.
    Notification: on neither, outside a web app saved to the home screen (`NotificationsEnabled`,
    one of WebKit's features);
  - the window: the viewport Safari leaves a page on the device (§6), with `screen.orientation`
    held upright;
  - the device class's navigator and screen values (the shim);
- seeds per-profile defaults (e.g. WebRTC policy) when a new profile picks it;
- names a **behaviour set** (`behaviorSetID`) — the injected-script bundle. This is an
  extension point (`BehaviorSets` in the app layer). Today every generation resolves to the
  same WebKit shims, because with the current public API the observable behaviour does not
  differ by declared version. When a future WebKit ships behaviours worth matching (and the
  public API to do it), a new behaviour set is registered and new generations point at it,
  with no change to the profile format.

What it does **not** do, and cannot:

- It does not switch the real WebKit core. The engine is always the Mac's system WebKit;
  there is no public API to load an older or iOS WebKit build, and running a second engine
  is out of scope. So a profile tagged "iOS 26" renders with the host Mac's WebKit, whatever
  its real version.
- Only the macOS generation is engine-consistent, and only when its version equals the Mac's
  real Safari version (the editor still shows the string, which may differ from the host's).
  An iOS/iPadOS generation changes the UA, the pixel ratio, the window and the features listed
  above. Every other signal in the table below (GPU, fonts, touch and pointer, TLS, the
  navigator of a worker loaded from a URL) still says "desktop Mac". The editor lists them.

Compared with a deeply integrated product that ships and switches genuine per-version WebKit
cores, this is version *labelling*, not version *emulation*. It is honest about being
Safari on this Mac.

### Shared and service workers' User-Agent: a race of WebKit's

A profile's shared and service workers report the profile's User-Agent, except when WebKit has not
handed the worker its pages' one. Then the worker reports WebKit's bare default, `Mozilla/5.0
(Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko)`, without the
`Version/… Safari/…` every Safari sends. A page comparing its own `navigator.userAgent` with a
shared worker's sees the difference.

- **It is WebKit's.** The self-test counts it over fresh iPhone profiles, each in a pool of its
  own: 6 per setting and pass, 8 passes in CI runs 218–221. With the engine settings as shipped:
  12 of 48. With Notification left on: 14 of 48. With encoded transforms off: 11 of 48. The CI logs
  show it since run 193 too, in profiles without any engine switch of the app's. The cause in WebKit was not
  found. The self-test's checks accept the profile's User-Agent or WebKit's bare one, and fail on
  any other, such as another profile's.
- **Safari 26's WebKit (branches 7622–7624)** takes a shared worker's User-Agent from the worker
  process, never from the page that made it. `WebSharedWorkerContextManagerConnection::launchSharedWorker`
  tests `!initializationData.userAgent.isEmpty()` where it means `isEmpty()`. 7625 fixes it.
- **Profiles with different User-Agents running at once.** WebKit hands a pool's new User-Agent to
  every shared- and service-worker process of the app, whatever pool it belongs to
  (`WebProcessPool::updateRemoteWorkerUserAgent` over a static list). Such a process uses it for a
  shared worker on 7622–7624, which ignores its page's, and for a service worker whose clients'
  User-Agent it does not know yet. Profiles of one generation share one User-Agent, so for them it
  changes nothing.

### What remains impossible with public APIs

FINGERPRINTING LIMITATION. Each of the following would require private WebKit API, a
modified WebKit, or different hardware. None is attempted:

| Signal | Why a profile can't change it |
|---|---|
| Canvas 2D / WebGL pixels, WebGL renderer and vendor strings, extensions, limits | produced by the Mac's GPU and driver; WebKit exposes them as is |
| AudioContext output | the Mac's audio stack |
| Fonts (measured via text metrics) | macOS system fonts; iOS has a different font set. As in Safari, fonts the user installed are hidden from pages (the WebKit preference Safari sets, `_shouldAllowUserInstalledFonts`; it has no public API, so it is applied only when this WebKit has it, which the self-test checks) |
| Screen size, colour depth, `matchMedia` results | the real display. A mobile generation's pixel ratio is set per web view (private API, above), so its resolution media queries agree, and its window is the device's viewport, so `width`, `height` and `orientation` follow natively. `device-width`, `device-height`, colour depth and gamut stay the Mac's display |
| `navigator.platform`, `vendor`, `hardwareConcurrency`, `maxTouchPoints` | engine and hardware; `customUserAgent` changes only the UA string. macOS profiles keep the native values; iPhone/iPad profiles get their device class's values from the shim (detectable; in workers made from a blob too, not in workers loaded from a URL) |
| Touch and pointer behaviour, `ontouchstart`, the `pointer` and `hover` media queries, motion events | macOS WebKit is a desktop engine; there is no touch-input emulation API. `screen.orientation` reads the device upright (the shim) |
| `navigator.languages`, `Accept-Language` | one list per app run: WebKit reads it once, when its first process starts. The first profile launched picks it (its proxy's country, else the app's language); the shim never overrides `navigator.language(s)`, so header and script agree |
| Supported JS/CSS features, media codecs, WebKit version quirks | the installed macOS WebKit, which differs from iOS WebKit |
| TLS ClientHello, HTTP/2 settings, header order | Apple's macOS network stack |

**Why this project doesn't paper over these with JavaScript:** injected overrides for canvas,
WebGL, audio or fonts are unreliable. They don't reach workers, don't change server-side TLS
or HTTP signals, and leave measurable inconsistencies — fingerprinting pages flag the noise
itself ("Canvas: Spoofed", "Fingerprinting Resistance: Detected"). They also mainly serve
to defeat fraud and abuse detection, which is not a goal here. What the shims *do* replace
(time zone, geolocation, WebRTC, and the navigator/screen values of a mobile generation) is
replaced the way the engine defines it: accessors on the prototypes, strict methods with
only `length` and `name`, the native receiver errors, and a `Function.prototype.toString`
that prints them as native code even from a fresh iframe. A receiver the engine refuses gets
the engine's own error with the stack a direct call gives. The replacement returns the native
call in tail position, which JavaScriptCore runs without the replacement's frame (WebKit names
a user script's frames `@user-script:N`; CI run 220 found one in each such error, run 221 none).
So the replacement itself is not the thing a page notices; the inconsistencies listed above
still are. Errors that come from arguments (`window.open('http://[')`), and those of the
non-default shims (the time zone without the engine's override, fixed geolocation,
relay-only WebRTC), still carry the shim's frame. CI compares a macOS
profile's whole measured surface with this Mac's real Safari (`scripts/safari_reference.py`,
results below).
The honest options for real separation between identities are outside the browser:
- a separate macOS user account per identity (OS-level separation);
- a different Mac or VM per identity (different hardware fingerprint);
- for a genuine iPhone fingerprint, Safari on an actual iPhone.

### Measured against this Mac's Safari

Two CI steps compare a macOS profile with the runner's own Safari (macOS 26.6.2, Safari 26.6.2),
driving Safari through `safaridriver`:

- `scripts/safari_reference.py` runs `Resources/fingerprint_probe.js` in both: 434 keys identical,
  0 must-match keys differ.
- `scripts/live_compare.py` loads the same pages in Safari and in on-screen profile windows of the
  same outer size (`PrivacyBrowser --capture-sites`, `SiteCapture.swift`), once for a default profile
  and once with a time zone (Safari's own: in the engine where WebKit allows it, §6, else the shim's
  wrapper) and the WebRTC wrapper running on Safari's own values. Both JSON sets
  are kept in the `fingerprint-surfaces` artifact.

What is identical, key by key:

| Area | Result |
|---|---|
| Probe | UA (the profile declares the installed Safari's version), `navigator` (platform, vendor, hardwareConcurrency, `deviceMemory` undefined, maxTouchPoints, pdfViewerEnabled, the same five plugins and two MIME types — real Safari lists Chrome/Chromium/Edge PDF Viewer too, as the HTML spec requires — no own properties), language and `Intl` locale, screen and colour depth, pointer/touch media queries, time zone and offset, canvas pixels and PNG (the same data URL, byte for byte), canvas text, WebGL (vendor, renderer "Apple GPU", every extension and parameter), font metrics, `window.webkit`, the shape of `window.safari`, the toString text and shape of every native the shims touch |
| Window | `outerWidth/outerHeight`, `innerWidth/innerHeight`, `screenX/screenY`, `visualViewport`: the browser chrome is 52 px with one tab and 90 px with two, as in Safari 26 (unified toolbar; tab bar from the second tab, 38 px) |
| Network | request header set and order for navigations, `fetch` and XHR (31/31); TLS ClientHello (JA3, JA4, cipher and extension lists apart from the random GREASE values), HTTP/2 SETTINGS, WINDOW_UPDATE and pseudo-header order (Akamai fingerprint), TCP SYN — measured by tls.peet.ws |
| APIs | permission states (geolocation, notifications, camera, microphone, persistent-storage, screen-wake-lock, midi, clipboard), storage quota, speech voices, `Notification.permission`, share, Private Click Measurement, storage access, platform authenticator |

What a profile changed to get there (each was a difference before):

- **Window geometry.** A WKWebView reported `outerWidth = outerHeight = 0` and a screen position
  computed from an empty rectangle: WebKit asks the UI delegate for the window frame
  (`WKUIDelegatePrivate`, which Safari implements) and gets nothing otherwise. The tab now answers
  with its window's frame. The window itself is laid out like Safari's (see above); it used to add
  a title bar and an always-visible tab strip (~92 px).
- **Language.** Without a proxy country, websites saw the app's UI language (Russian), which
  `Localization.applyProcessLanguage` keeps in the app's own defaults; they now see this Mac's
  languages, read from the global domain, as Safari does.
- **Fonts.** A WKWebView lets pages use fonts the user installed; Safari shows them only the
  system's. The profile sets the WebKit preference Safari sets (private, applied only if present).
- **Storage quota.** WebKit gives an app that is not a browser a fixed 1000 MiB per origin — the
  small quota private-mode detectors look for. Safari reports 60 % of a *standard* 128 GB volume
  (WebKit reports a standard capacity rather than the real disk's, so the figure is 82 463 372 084
  on every Mac, a tenth of it in a third-party frame). A persistent profile's store now has that
  quota in WebKit itself (`SafariStorageQuota`: `_WKWebsiteDataStoreConfiguration` with a browser's
  ratios, 0.6 per origin and 0.8 in all, and the standard volume, 64 GB for an iPhone generation),
  so every scope reports it, URL-loaded and service workers included, and an origin can store as
  much as in Safari. An ephemeral profile's store has no volume to take a ratio of: there the shim
  reports Safari's figure in the page and its blob workers, and URL-loaded and service workers
  still report 1000 MiB.
- **Geolocation permission.** `permissions.query({name: 'geolocation'})` threw a TypeError (the shim
  built a fake status); it is now the engine's own `PermissionStatus`, 'prompt' until the page asks.
  A profile that denies geolocation (the default) now leaves it to WebKit, which denies the request
  and keeps the state per document; the tab's UI delegate answers as a user who said no, so a
  `PermissionStatus` the page held turns 'denied' with a 'change' event, as a fresh query in that
  document reads. No geolocation or permission function is replaced.
- **Wrappers under JavaScriptCore.** With relay-only WebRTC the wrapper added a
  `webkitRTCPeerConnection` Safari 26 no longer has and inherited from `Function.prototype` instead
  of `EventTarget`; both fixed. The shim tests run under JavaScriptCore (Bun) as well as V8.

What still differs, and why it cannot be changed from the app:

- **Apple Pay and Web Push.** `ApplePaySession`, `ApplePaySetup`, `MerchantValidationEvent`,
  `PaymentRequest` and `PushManager` exist only in Safari. WebKit enables them for an embedder only
  through private preferences, and they need Safari's entitlements to work; exposing objects that
  cannot work (and that WebKit disables anyway once a page has user scripts) would be worse.
  `Object.getOwnPropertyNames(window).length` follows (1044 in Safari, 1029 in a profile with
  WebRTC on, 1022 with the default policy that removes it).
- **WebRTC** is switched off by the default policy, and with a proxy unless the packet tunnel
  carries it (SOCKS5 only, relay candidates only; [TUNNEL.md](TUNNEL.md)). Without a proxy,
  `relayOnly` and `unrestricted` keep it.
- **The replacement `Date` and `Intl.DateTimeFormat`** (only where the time zone is the shim's: a
  WebKit without the process pool's time zone override, §6; on macOS 26.6.2 the live comparison's
  profile with a time zone has the engine's own, as Safari) list `length` and `name` before their
  statics: JavaScriptCore orders a script function's own properties that way whatever the
  definition order.
- **Media devices before permission.** On the CI runner Safari lists `audioinput,videoinput`, a
  profile `audioinput` only. WebKit hides a kind the app has no capture authorisation for (macOS
  privacy settings, per app); granting the app camera access once aligns it.
- **Advanced Fingerprinting Protection.** Safari can add noise to canvas readback for scripts it
  classifies as fingerprinting; there is no WKWebView switch for it. On the probe page (no such
  script) the pixels are identical.
- `navigator.webdriver` (true only under safaridriver) and the error-stack depth (WebDriver vs.
  `callAsyncJavaScript`) differ only in the comparison harness.

**deviceinfo.me** shows "Canvas: Spoofed" and "Fingerprinting Resistance: Detected" in a profile
and equally in Safari 26 on the same Mac: its canvas test accepts only PNG data URLs of 142, 150,
158 or 186 characters, and this WebKit's encoder writes 274 for the same five exact colours. The
row sets the resistance verdict (`me()` in its script). Nothing in the profile causes it, and
nothing a profile could do short of rewriting `toDataURL` (which would be a real lie) changes it.

So a page that fingerprints *feature support* can still tell "Safari" from "a WKWebView app on the
same Mac" by Apple Pay and Web Push, the same way it tells Safari from a Safari View Controller or
a Mail or Slack preview. It cannot tell two profiles of this app apart by any of this: they are the
same engine on the same Mac. What separates profiles is what they declare (table above) and their
storage and network (§1, §4).

## 3. Encryption at rest

| Data | At rest | While the app is unlocked | While the profile runs |
|---|---|---|---|
| Profile list (names) | encrypted (`index.bin`) | in memory | in memory |
| Profile settings (proxy credentials and so on) | encrypted (`config.bin`) | decrypted only during launch and edit | in memory |
| Saved passwords | encrypted (`passwords.bin`) | decrypted on demand | in memory |
| Imported cookies for a stopped profile | encrypted (`cookies-import.bin`) until its next launch puts them into the website data | — | in WebKit's cookie store (as the profile's other cookies) |
| Warm-up plan (addresses, search, times) | encrypted (`warmup.bin`, this Mac only, not synced) | decrypted when the sheet opens | — |
| Synced cookies (persistent cookies, with cookie sync on) | encrypted (`cookies.bin`; its local baseline `cookies-baseline.bin`) | encrypted | encrypted; written at launch and stop |
| History | encrypted (`history.bin`); ephemeral profiles: never written | encrypted | in memory, saved encrypted (debounced, ≤ 3 s) |
| Bookmarks | encrypted (`bookmarks.bin`) | encrypted | in memory, saved encrypted on every change |
| Sync target and token | encrypted (`settings.bin`, not synced) | in memory | — |
| WebKit website data | encrypted (`webdata.pbsa`) | encrypted | **plaintext on disk** in WebKit's directories |

**Why WebKit data is plaintext while a profile runs.** WebKit chooses the location of an
identifier-based data store itself and writes ordinary SQLite and LevelDB-style files
there. There is no public API to hand it a key, or to point the store at an encrypted
volume. `_WKWebsiteDataStoreConfiguration` can set directories, but it is private API.
The closest viable approach is to archive, encrypt and remove the data on stop, and
restore it on launch. `WebDataStoreVault` does this.

**Known gaps in that approach:**

1. *Directory discovery.* Apple doesn't document the layout. `WebKitDataLayout` finds
   directories by the profile UUID below the app's WebKit and Caches subtrees, and translates
   archive locations between the sandboxed and unsandboxed layouts. The self-test checks both
   on each CI run. If a future macOS stores per-identifier data elsewhere, that data won't be
   sealed, and the self-test's "plaintext removed after seal" check is meant to catch it.
   By hand: `find ~/Library -iname '<profile-uuid>'` while the profile is stopped should
   return nothing.
2. *No flush/close API.* WebKit tears a session down asynchronously after the last
   reference to its store is released. The vault waits, archives, then calls
   `WKWebsiteDataStore.remove(forIdentifier:)`, which fails while the store is still in
   use, and retries with backoff (1+2+3+5+8 s). A write that lands between the archive
   and the successful removal is lost. It is not leaked. If WebKit never releases the
   store, the app reports an error and the data stays in plaintext until the next stop
   or unlock.
3. *Crashes.* If the app crashes or is force-quit while a profile runs, the plaintext
   stays on disk until the next unlock, when `recoverUnsealedProfiles` seals it. Until
   then it is protected only by FileVault, the 0700 directory permissions, and (sandboxed)
   the container. History written in the last ≤ 3 s before a crash is lost.
4. *Deleted plaintext isn't securely erased.* APFS is copy-on-write on SSDs, so
   overwriting doesn't reliably erase data, and the code doesn't try. FileVault is the
   real protection for deleted blocks; enable it.
5. *Memory.* Swift and CryptoKit offer no guaranteed zeroisation. Keys of an unlocked
   vault live in process memory, and anyone who can read process memory (root, a
   debugger, a core dump) can recover them. What the app's own code holds is overwritten
   with `memset_s` once used — the password's bytes, derived keys, the unwrapped vault key
   and Argon2's 64 MiB of working memory — but copies inside `String`, `Data` and CryptoKit
   are out of its reach.

**KDF.** Argon2id (RFC 9106, version 1.3) with 64 MiB, 3 passes and 4 lanes — the RFC's second
recommended option — derives the key that unwraps the vault key. It is memory-hard: a GPU tries
far fewer guesses per second than against PBKDF2. CryptoKit and the macOS SDK have no Argon2, so
it is implemented in Swift in the core (`Argon2.swift`, no C dependency) and checked against the
RFC's test vector and the reference implementation's. A vault created before (PBKDF2-HMAC-SHA256,
600 000 iterations) is re-wrapped under Argon2id the next time the app unlocks it, with the
password that opened it; only the header (`vault.json`) changes, atomically. A header's Argon2id
costs are capped (2 GiB, 10 passes, 16 lanes), so a header fetched for sync cannot make the app
allocate without bound.

## 4. Network and proxy

**Native (enforced by WebKit for the data store):** `proxyConfigurations` covers HTTP(S),
WebSocket, fetch/XHR, media and service-worker loads of that store.
`allowFailover = false` makes it fail closed. Supported proxies are SOCKS5 and HTTP
CONNECT, optionally TLS to the proxy, with or without username/password, plus a
per-profile bypass list. The CONNECT tunnelling, remote DNS for SOCKS5, and fail-closed
behaviour are verified by the self-test (§0).

**TLS and HTTP/2 are the profile's own through the proxy.** The leak check loads tls.peet.ws in
each proxied profile through its proxy. The ClientHello (JA4 `t13d2013h2_a09f3c656075_7f0f34a4126d`
on macOS 26.6.2, the cipher and extension lists), the HTTP/2 SETTINGS and frames (Akamai) and the
header order and values equal those of the profile without a proxy (CI runs 218–221, both proxy
kinds and the relay profiles). The proxy only tunnels the connection. The TCP SYN the site sees is
the proxy's, by design. A difference fails the check.

**WebSocket and media go through the proxy too.** The self-test checks a WebSocket, an HLS stream
and an MP4 file that a `<video>` plays (AVFoundation, which does not use WebKit's own loader) in
an HTTP CONNECT and a SOCKS5 profile (§0).

**QUIC / HTTP/3 stays on the proxy.** With a data store proxy, WebKit's network stack does not
use HTTP/3: measured on every push by `scripts/leak_check.py`, which runs real forwarding
proxies on the CI Mac. cloudflare-quic.com answers a profile without a proxy over HTTP/3 and the
same requests through an HTTP CONNECT or SOCKS5 proxy over HTTP/2, each one seen by the proxy;
the SOCKS5 proxy was never asked for UDP. So QUIC needs no tunnel. WebRTC does: the packet
tunnel ([TUNNEL.md](TUNNEL.md)), below.

**App Transport Security:** `NSAllowsArbitraryLoadsInWebContent` lets the browser load
`http://` pages. The app's own URLSession traffic (HTTP sync) remains HTTPS-only.

**Not covered:**

| Path | Status | Mitigation |
|---|---|---|
| WebRTC (STUN, TURN over UDP or TCP, media) | Never proxied by WebKit: it opens these sockets itself, without the data store's proxy. STUN reveals the real public IP to the page (seen by the CI leak check); a TURN server sees it too | With a SOCKS5 proxy and the packet tunnel on: through the proxy's UDP ASSOCIATE, via a per-profile TURN relay ([TUNNEL.md](TUNNEL.md)). Otherwise WebRTC is **off** in a proxied profile, whatever its setting (§5) |
| WebTransport (QUIC streams and datagrams) | Never proxied by WebKit: a session opens its QUIC socket in the network process without the data store's proxy. Measured by the CI leak check (macOS 26.6.2): a page in a profile behind either proxy sent its datagrams from this Mac's address straight to the server | **Off** in a proxied profile: `WebTransportEnabled`, one of WebKit's features (`+[WKPreferences _features]`), is switched off for its pages and their workers. A profile without a proxy keeps it, as Safari, so with a proxy `WebTransport` is missing where Safari has it |
| DNS prefetch | `<link rel="dns-prefetch">` (also as a `Link:` header) makes the network process resolve the host through the system resolver — WebKit skips it only for a *system-wide* proxy, not for a data store's `proxyConfigurations` | A content rule list blocking `ping`-type loads is added to every proxied profile (`ContentRules`): WebKit runs dns-prefetch through it as a ping. It also blocks `<a ping>` click trackers. Beacons are fetches and unaffected: they go through the proxy, also when sent from `pagehide` as the page goes away. Verified by the self-test with an `<a ping>` and both kinds of beacon |
| Safe Browsing lookups | Made outside the data store's network session | Off by default (`safeBrowsingEnabled`) |
| `mailto:`, `tel:`, custom schemes | Would hand the URL to another app, outside the profile | Blocked by the navigation policy |
| Camera and microphone streams | Local capture; their WebRTC transport goes through the proxy only via the packet tunnel (SOCKS5), otherwise WebRTC is off with a proxy | Asks the user every time |
| Sync traffic | Goes from the app process through the system network, not the profile proxy | Folder transport makes no network requests; HTTP sync is HTTPS and carries only encrypted blobs |

**Proxy authentication:** credentials go into the data store's `ProxyConfiguration`
(`applyCredential`), which Network.framework sends when the proxy answers 407. WebKit does not
show the proxy's challenge to the app (it keeps it to itself; with no credentials to send the
page simply loads forever), so a profile without credentials cannot find out from a page that
its proxy wants them. The launch-time lookup through the proxy (§6, time zone from the proxy)
does see the 407: the launch is refused with a message when the lookup answers while the launch
waits for it; when it answers later (the launch stopped waiting, below), the profile is stopped with
the same message. Nothing opens directly either way. With that lookup switched off, a proxy that
wants credentials shows as pages that never load.

**SOCKS5 authentication** (RFC 1929 username/password): the credentials go into the same
`ProxyConfiguration` through `applyCredential` and are sent in the SOCKS5 handshake. SOCKS5 has
no 407: a proxy that rejects missing or wrong credentials makes every load fail (nothing goes
direct), but the launch does not learn why and is not refused, so the profile opens and its
pages show load errors. The self-test runs a SOCKS5 proxy that accepts only username/password
and checks that wrong or missing credentials fail closed against a real host.

**Several proxied profiles at once:** each profile has its own data store, and so its own network
session with its own proxy configuration and credentials. Its launch-time lookup has its own
URLSession too. Nothing about a proxy is shared between profiles. The self-test launches three
SOCKS5 profiles together and loads pages in all of them at the same time (§0). Two things are
process-wide, not per profile:
- the language websites see (§6), set by the first profile launched;
- the packet tunnel when it is on, which gives each profile its own relay
  ([TUNNEL.md](TUNNEL.md)).

**Launch and the lookup through the proxy:** the lookup (time zone, country, exit IP) runs while
the profile's data decrypts. A launch waits for it only when the profile takes its location
from the proxy (*Time zone of the proxy's location*, on by default; with *Override time zone*
the zone is the explicit one, but the lookup still runs and is waited for, for the country and
so the language): at most 3 s when nothing is remembered for that proxy yet, at most 1 s when a
location is. A location is remembered per proxy: kind, host, port and credentials (gateway
proxies pick the exit country or session from the username or password). Without an answer by then, the remembered location (or the
host's zone) is used and the lookup finishes in the background. Its answer is remembered for the
next launch. A time zone different from the one the profile runs in is noted, and applies from
the next launch (pages already open keep theirs). So is a language the proxy's country would
want when the first profile launched got no answer in time (§6). A late answer is dropped when
the profile was launched again since, or the app is locking or quitting. Several messages from
one launch are shown together (a message already shown is not repeated).

**Exit-IP warning** (per profile, off by default): the launch compares the proxy's exit IP, as
the lookup sees it, with the one seen at the previous launch through the same proxy and
credentials, and warns when it changed (a rotating or reassigned proxy). It needs the lookup,
which then runs even without the time-zone matching. The last IP is stored, encrypted with the
profile, only while the option is on: turning it off (or removing the proxy) deletes it when the
profile is saved. A lookup still under way when the option is turned off, or the proxy removed
or replaced, neither stores an IP nor warns.

**Verify the proxy by hand:** set a SOCKS5 proxy, for example `ssh -D 1080 host`, open
`https://ifconfig.me`, and confirm it shows the proxy's IP. Then stop the proxy and
reload: the page must fail, not show your own IP.

## 5. WebRTC

WebKit offers no public preference to disable WebRTC or set an IP-handling policy, and its
WebRTC sockets — STUN, TURN over UDP or TCP, media — never use a data store's proxy (WebKit's
network process opens them with plain Network.framework parameters). Its default hides local
IPs behind mDNS host candidates, but STUN still discovers the public IP. WKWebView on macOS 15
and 26 exposes a native `RTCPeerConnection` (observed by the self-test).

**With a proxy, WebRTC goes through the proxy or is off** (`ProfileConfiguration.webRTCRouting`),
whatever the profile's setting, because any other policy sends the page's ICE traffic from this
Mac's own address:

- **SOCKS5 proxy, packet tunnel on, WebRTC setting not Disabled**: the page's only ICE server is
  a TURN relay on a virtual address that the tunnel routes to the extension, under
  `iceTransportPolicy: "relay"`. The engine's WebRTC is on then, so the user script is what
  keeps the page on the relay; it is hardened against pages that tamper with built-ins, but it
  is page-level code ([TUNNEL.md](TUNNEL.md), "Enforcement is in the page"). The
  relay sends everything through the proxy's UDP ASSOCIATE, so the page, STUN servers and
  peers see the proxy's address. The page keeps seeing its own configuration. Its STUN servers
  are not contacted, and the urls that would name the relay (ICE events, `getStats()`) name
  the page's own server. Design, limits and signing: [TUNNEL.md](TUNNEL.md).
- **HTTP CONNECT proxy**: off. CONNECT cannot carry UDP.
- **Tunnel not built, not allowed, or not connected**: off, and both the profile editor and the
  launch say why. Without the tunnel, UDP would leave from this Mac's real IP.

The editor shows the setting as off (or "through the network extension") while a proxy is set,
and keeps the stored choice for when the proxy is removed.

The profile setting:

- `disabled` (default) switches WebRTC off in the engine (`WKPreferences._setPeerConnectionEnabled:`,
  a private property; Lockdown Mode turns off the same setting). That setting leaves the
  encoded-transform interfaces (`RTCRtpScriptTransform`, `RTCEncodedAudioFrame`,
  `RTCEncodedVideoFrame`; in a dedicated worker `RTCRtpScriptTransformer`, `RTCTransformEvent`
  and `onrtctransform`), which have a setting of their own, `WebRTCEncodedTransformEnabled`,
  also off in Lockdown Mode and one of WebKit's features on macOS 26.6.2. It stays on: with it
  switched off that way, shared and service workers reported WebKit's default User-Agent instead
  of the profile's in 4 of 8 profile runs (CI runs 211 and 212), against 0 of 12 with it on (runs
  213–215); WebTransport's switch, made the same way, showed nothing of the kind (12/12). The
  document-start user script
  removes those three from the window, as in an engine built without WebRTC; dedicated workers
  keep theirs, which do nothing without a peer connection. Where WebKit kept peer connections (it
  lacks the property), the script removes every `RTC*` interface from the window and from workers
  made from a blob too.
- `relayOnly` wraps the constructor and `setConfiguration` to force
  `iceTransportPolicy: "relay"`. No host or srflx candidate reaches the page or its peers, so
  peers see only the TURN server's address. The TURN server still sees your real IP, and so do
  the page's STUN servers: libwebrtc applies the relay policy to what it reports, and by its code
  still asks the configured STUN servers from this Mac's address (not measured here). Without a
  proxy that is the address the site already sees. With a proxy, only the tunnel's relay is used,
  and the page's STUN servers are dropped ([TUNNEL.md](TUNNEL.md)).
- `unrestricted` uses the WebKit default; never applied with a proxy.

**Limits of the shim (relay-only, and the fallback removal):** workers have no
RTCPeerConnection (WebKit exposes `RTCDataChannel` there, not the peer connection); the self-test
checks blob, URL, shared and service workers, so a WebKit that exposed it would turn CI red.
Where WebKit kept peer connections, the fallback removes the `RTC*` interfaces (and
`onrtctransform`) in workers made from a blob too; leftover encoded transforms alone are no reason
to rewrite workers. The script runs in every same-origin frame when its document starts, including
frames sandboxed without `allow-scripts` (nothing on WebKit's user-script path checks sandbox
flags), so a frame created by the page (`window.frames[i]`, `window[i]`) is already patched when
the page reaches it; `contentWindow`, `contentDocument` and `window.open` are hooked as well for a
window reached before its own copy ran. A new page's first, blank document runs no user script at
all, so a popup is patched by the opener's copy as `window.open` or `document.open(url, name,
features)` (three arguments open a window) returns it. That patch runs after the page's own
scripts, which may have broken the built-ins it uses, so the popup is handed over only if its
`RTCPeerConnection` is then one of the shim's (in the opener's registry or the popup's own copy's);
otherwise it is closed and the page gets null, as for a blocked popup. Checked on macOS 26.6.2:
a relay-only profile's peer connections made from frames sandboxed without scripts (empty,
`srcdoc`, a same-origin URL, reached by index or by `contentWindow`) and from an ordinary frame
reached by index are all relay-only and gather no host or srflx candidate against public STUN
servers, where a plain WKWebView gathers a srflx one. So are popups from `window.open` and from
`document.open(url, name, features)`, and one opened after the page broke `Object.defineProperty`
(it came patched). A cross-origin frame is patched by its own copy and cannot be inspected from
the page anyway.

## 6. Time zone, geolocation, user agent

| Setting | Implementation | Native? | Gaps |
|---|---|---|---|
| User agent | `WKWebView.customUserAgent`, with presets in the editor | yes (string only) | `navigator.platform`, vendor, feature set and TLS fingerprint still identify WebKit on macOS (§2). Use the *Safari on macOS* preset. An iPhone/iPad generation also gets the device's pixel ratio, window and feature set (§2); its GPU, fonts, touch and TLS stay the Mac's |
| Time zone | In the engine where WebKit allows it: each profile runs in a WebKit process pool of its own (`ProfileProcessPool`), whose configuration names the zone (`_WKProcessPoolConfiguration.timeZoneOverride`, SPI since macOS 13). WebKit hands it to every process the pool launches, which sets it process-wide before any script runs, so the page, its frames, dedicated, shared and service workers, `Date` and `Intl` (and `Temporal` where WebKit exposes it; macOS 26's does not) report it as the engine's own. The shim checks at document start, in each realm, that the engine reports the zone and then replaces nothing; a realm whose engine does not (a process the override did not reach) gets the shim below. Without the SPI, JS: `Intl.DateTimeFormat` default `timeZone`; `Date` local getters and setters, `getTimezoneOffset` (with the sub-minute offsets of historical dates), the local constructor forms `new Date(y, m, d, …)`, `Date.parse` and `new Date(string)` for strings without an offset, `toString`, `toDateString`, `toTimeString`, `toLocale*String`, `getYear`/`setYear`. A worker made from a blob of the page (how fingerprinting scripts make theirs) starts with the same shim: the blob is handed to the engine as [the page's directives, the shim as one line of code, the rest of the page's blob], so the worker keeps a blob: location, its relative URLs, CSP, strict mode and line numbers. The shim goes in as code, not through `eval`, and nothing is read back from the page's blob (where its directives end comes from the strings the page made the Blob of), so a page's CSP (no `'unsafe-eval'`, `connect-src` without `blob:`) and Trusted Types have nothing to block or report | in the engine where the SPI exists; otherwise no | Only without the SPI: workers loaded from a URL and service workers use the host zone (rewriting them would change their location). A worker made from a `TrustedScriptURL`, or while the page has a default Trusted Types policy, does too: only a policy of the page's can make the URL the shim's blob would need, and a default policy would be shown another URL than the page's. A blob the page did not make from strings (fetched, a `File`) gets the shim first, so a `'use strict'` at its start no longer applies. The page's first line moves right by the shim's length, and the worker's own URL (`location`, stack traces, error events) is that of the blob made with the shim, not the page's. JavaScriptCore lists the replacement `Date`'s and `Intl.DateTimeFormat`'s `length`/`name` before their statics (`Object.getOwnPropertyNames(Date)`), which no script function can avoid. `Intl.DateTimeFormat().format()` without an explicit zone follows the shim; other `Intl` constructors carry no zone |
| Geolocation | Deny (the default): WebKit itself. The tab's UI delegate answers the requests and permission queries WebKit sends it (`WKUIDelegatePrivate`, which Safari implements; `GeolocationPermission`) as a user who said no: every request is denied, so the page gets WebKit's own `PERMISSION_DENIED` ("User denied Geolocation") from the engine's own `getCurrentPosition`/`watchPosition`. A fresh `permissions.query({name:'geolocation'})` follows WebKit's own rule per document: 'prompt' until the document asks, 'denied' after, 'prompt' on the next page. A `PermissionStatus` the page already holds is told of the request and takes the tab's answer as it is ('denied' for the site that asked, until the tab shows another page), firing 'change'. Nothing is replaced. Every other permission is answered 'prompt', which WebKit reports when a delegate does not answer. Fixed coordinates: JS, answering as WebKit does for a user who allowed them; positions are instances of the real interfaces with no own properties (values from the prototype getters and `toJSON`), the `PermissionStatus` is the engine's own, 'prompt' until the page asks, then 'granted' | deny: yes (WebKit denies on the Mac by itself and keeps the per-document state; the delegate's answers, private API, keep a held `PermissionStatus` in step); fixed: no | The IP address (proxy) is what most sites actually use. The app has no `NSLocationUsageDescription` and no location entitlement, so CoreLocation can't be reached even if the shim is bypassed. The tab answers per site, not per document: a status a frame of the site's page holds turns 'denied' when the page asks, where a fresh query in that frame says 'prompt'. WebKit before macOS 26 reports a geolocation 'denied' as 'prompt' |
| Time zone from the proxy | At launch, a geolocation service (ipinfo.io, then geojs.io, ipwho.is) is asked *through the profile's proxy* where it exits; the profile runs in that zone. The last answer per proxy is used on later launches when the new lookup takes over 1 s (and when a lookup fails), that lookup finishing in the background; with nothing remembered the launch waits for it at most 3 s (§4) | — | A third-party request per launch (HTTPS, via the proxy only, no cookies). Off per profile with *Time zone of the proxy's location*; *Override time zone* replaces the zone but keeps the lookup, for the country (language). Without any answer the host zone is used; a time zone that changed applies from the next launch |
| Language | Process-wide: set before WebKit's first process from the first launched profile's proxy country (`WebContentLanguage`) | partly | WKWebView has no per-view `Accept-Language` / `navigator.languages` API; later profiles of the same run share the first one's language |

The shim logic is tested under Node (`scripts/test-shims.mjs`) against ICU, across
fixed-offset zones, DST transitions, 30-minute shifts and pre-1900 offsets, together with
the function-shape checks CreepJS runs (toString from the window and from a frame, own
keys, receiver errors), and with workers made from blobs: directives, line numbers, no
`eval` (a realm that forbids code from strings), Trusted Types, revoked URLs, built-ins a
page replaced. Every test also runs on the one-line form a worker's blob gets
(`SHIM_FORM=worker`). The key cases are also checked under JavaScriptCore by the self-test,
whose surface checks compare a macOS profile with a plain WKWebView key by key.

**Mobile generations (iPhone, iPad):** the browser window is the viewport Safari leaves a page
on the declared device: the screen less the status bar and Safari's own bars.
- **Sizes.** An iPhone (a 390 × 844 screen) gets 390 × 739; an iPad (820 × 1180) gets 820 × 1106.
  `innerWidth` is the screen's and `innerHeight` lower, as on the device. Equal sizes are what a
  desktop browser's device emulation shows.
- **These are estimates** (`PrivacyScripts.deviceViewportSize`). They are worked out from Safari
  26 on an iPhone 16 Pro, which leaves a page 754 of its 874 points in the compact tab layout; no
  390 × 844 iPhone or 820 × 1180 iPad was measured. `scripts/device_reference.py` measures a
  real device to replace them. Run it on the Mac and open the address it prints in Safari on the
  iPhone or iPad. It writes `scripts/reference/<name>.json` and prints the device's values next to
  the declared ones: screen, pixel ratio, viewport at load and after scrolling, media queries, and
  a worker's navigator.
- **Tabs.** A second tab adds the tab strip to the window, so the page keeps its viewport, as on
  the phone.
- **Other values.** `outerWidth`/`outerHeight` report the screen. The pixel ratio is the engine's
  own. The navigator/screen values are accessors on the prototypes.
- **Still the Mac's.** The media queries `device-width`, `pointer` and `hover`, touch events,
  fonts, GPU and TLS. CreepJS also compares the page's `navigator` with a worker's. A user script
  reaches that only in workers made from a blob.

## 7. History and bookmarks

- Recorded per profile, only for `http(s)` pages. User/password components and fragments
  are stripped before storing. Visits to the same URL are coalesced (count + last visit).
- Retention is per profile (default 90 days, cap 10 000 entries). Recording can be turned
  off; ephemeral profiles keep history in memory only.
- Same-document navigations (`history.pushState`) are recorded once WebKit has made them
  the current back/forward item. Provisional loads that never commit are not recorded.
- Bookmarks persist even for ephemeral profiles, because they are explicit user actions;
  they are encrypted like everything else.
- The Library window (bookmarks and history) is available only while the profile runs,
  because that is the only time the data is decrypted.

## 8. Passwords

Each profile has its own password vault (`passwords.bin`, AES-GCM under a key derived from the
profile key, §3). Safari's profiles share one set of passwords; here a login saved in one
profile is never offered in another. WKWebView on macOS 26 has no AutoFill API (Safari's
AutoFill and the system credential provider are not available to third-party web views), so
the browser does it itself, as close to Safari as that allows.

**What matches Safari**

| Safari | Here |
|---|---|
| After a sign-in: "Do you want to save your password for “site”?" — **Save Password / Not Now / Never for This Website** | The same question as a window sheet, after a submitted form, or after a click or Return when the sign-in fields leave the page (a sign-in by script). Navigation is not held up by it |
| A saved user name with a new password: **Update Password / Not Now** | The same; the same password again asks nothing |
| Change-password and sign-up forms (`autocomplete="new-password"`, two or three password fields) | The new password is the one saved, only when it equals its confirmation |
| Two-step sign-ins (user name, then password on the next page) | The user name of the first page is kept for 10 minutes for the password page of the same site |
| Nothing is filled without the user (Safari has asked for interaction since 2014) | Focusing a login field (or clicking it, or ↓) lists the site's saved logins under it; a login is filled only when chosen (click, or ↓/↑ and Return). A click in the list's first half second picks nothing (a page can focus a field just as the user clicks), Return only a row chosen with ↓/↑, and typing closes the list. Never on page load, never into hidden fields |
| Logins grouped by site; a saved login offered on other hosts of the same site | Registrable domain from the Public Suffix List (`login.example.co.uk` and `www.example.co.uk` share; `alice.github.io` and `bob.github.io` do not); the page's own host first, then the most recently used. The list shows the host of a login saved on another host |
| Filling fires `input`, then `change` (plain bubbling events) | The same events; React, Vue and Angular forms take the values |
| `autocomplete="off"` ignored for logins | Ignored |
| HTTP authentication sheet with **Remember this password** | The same; the next challenge is answered from the vault |
| Passwords app: locked until authenticated; search, view, copy, edit, delete; excluded websites | **⋯ → Passwords…**: locked until the master password is entered; the same operations, and the "Never" websites with **Remove** |
| AutoFill switch ("User names and passwords") | Per profile: **AutoFill user names and passwords** in the profile editor (on by default) |

**Where it differs, and why**

- **Detection is heuristic.** Without an AutoFill hook, a sign-in is a submitted form whose
  password the user typed (trusted `input` events), a form navigation (read during the policy
  decision, held for at most 0.3 s; `form.submit()` fires no `submit` event), or the password
  field leaving the page within 5 s of a click on a button or Return. A sign-in that does none
  of these (fields kept on the page after a fetch) is not offered; the toolbar's save button
  then saves what the fields hold. A failed sign-in is offered too, as Safari does at form
  submission.
- **What counts as typed.** Trusted `input` events: a page script that inserts text with
  `document.execCommand('insertText')` produces those too, so it can make a password look typed.
  The user still has to answer the question, which names the site.
- **Events are untrusted.** Values are set from the isolated world, so the `input`/`change`
  events have `isTrusted == false` (Safari's are trusted); a site that rejects untrusted
  events must be typed into. macOS 27 adds trusted events for AutoFill worlds; not used yet.
- **`:autofill` highlight and the key button** need a world with AutoFill scripting: public API
  from macOS 27, WebKit SPI from macOS 15.4 (`_WKContentWorldConfiguration.allowAutofill`,
  used only when present, as the private `WKPreferences` in §2). Without it the fields keep
  their own style. The self-test reports which world this WebKit gave.
- **Stricter than Safari:** a login saved on an https page is never offered on an http page
  (Chrome and Firefox refuse too; Safari offers it with a warning); ports must match.
- **Not implemented:** strong-password suggestions for sign-up forms, Touch ID before filling,
  "Recently Deleted", import/export, shared credentials between related domains, passkeys.
- **Frames.** A frame of another site is offered that site's logins only, under a header that
  names it; the frame's origin always comes from WebKit, never from the page. An opaque origin
  (sandboxed frame, `data:`) gets nothing. Placing the list under a field in a cross-origin
  frame uses the click into it.

**Isolation from pages.** The script runs in its own `WKContentWorld`, and its message handler
is registered only there: the page world has no `window.webkit` (as in Safari, checked against
a plain WKWebView and the runner's Safari, §2), cannot see or call the script, cannot post to
the handler, and cannot replace the prototypes it uses. A page script that writes a password and
submits the form is not offered for saving (self-test). Before writing a value the script checks
that the document is the one the user focused and that `location.origin` is the frame's.

**Storage.** Entries: origin, user name, password, note, changed and last-used dates. The
"Never" websites and the switch are in the profile's encrypted configuration. The password
manager asks for the master password (one Argon2id derivation) each time it is opened.

## 8a. Cookie import

**⋯ → Import Cookies…** imports a cookie export into one profile. Formats: JSON (an array, an
object with `cookies` as Playwright's `storageState` and the DevTools protocol write it, a single
object, or JSON Lines; field names of EditThisCookie, Cookie-Editor, Puppeteer, Playwright,
Selenium and of Chrome's and Firefox's cookie databases, matched without regard to case, `_` or
`-`) and Netscape `cookies.txt` (curl, wget, yt-dlp and extensions; `#HttpOnly_` lines).

**Damaged files.** Everything importable is imported, the rest is reported with its place in the
file and the reason, before anything is imported:
- Text: UTF-8 with or without BOM (also a BOM at the start of a later line, from files joined
  together), UTF-16 with a BOM or recognised by its zero bytes, UTF-32 with a BOM. Bytes that are
  not valid text spoil only the cookie they are in ("damaged bytes").
- Files of another kind are named instead of being read as text: a browser's SQLite cookie
  database, Safari's binary cookies, a Selenium pickle, an archive, a web page.
- Netscape: read line by line (CRLF too); an empty value without its tab and fields separated by
  spaces are accepted; a line without seven fields is reported (eight: a tab in the value).
- JSON: also inside a string (AdsPower, Multilogin), under a wrapper (`{"result": {"cookies":
  …}}`, `{"data": […]}`) and as JSON Lines. When the file does not parse as a whole, each cookie
  object it still holds is read on its own (trailing commas tolerated): a broken entry, a cut-off
  end or text around the JSON costs only what it touches; the report names the damaged line.
- Each cookie is checked as a browser checks it: name and value characters (`;`, `=` in a name,
  control characters), 4096 bytes for name and value, a valid ASCII domain that is not a public
  suffix for a domain cookie (`.com`, `.co.uk`, `.github.io`: Public Suffix List), a path starting
  under 1024 bytes (a missing or relative one is `/`), an expiry that can be read and is not past
  (seconds, milliseconds, microseconds, Chrome's 1601-based time — also in yt-dlp's cookies.txt —,
  HTTP dates and ISO 8601; the DevTools protocol's `null` for "never" is 400 days, the most a
  browser keeps one), and the `__Secure-`/`__Host-` rules. Spaces around a name or value are
  dropped. The same cookie (name, domain, path) twice: the later one is imported, the earlier one
  listed as replaced.
- Refused with their own reason: a Chrome database row with an encrypted value (it would otherwise
  arrive empty and overwrite the real cookie), and partitioned (CHIPS) cookies: WebKit has no
  public way to set one in its partition, and without it the cookie would reach more sites.

**Into which store, and when.** A running profile gets the cookies at once. WebKit's
`setCookie` reports nothing, so the store is read back afterwards and every cookie WebKit did not
keep (missing, or with another value) is listed. A cookie that is not HttpOnly cannot replace an
HttpOnly one in WebKit (it keeps the old one, silently), so the import deletes the old one first.
CFNetwork keeps new cookies in memory and writes them to disk later, so after an import, and when
any profile stops before its data is sealed, the cookie store is asked to write them now
(`WKHTTPCookieStore`'s `_flushCookiesToDiskWithCompletionHandler:`, WebKit's own call; used only
where this WebKit has it, as the private `WKPreferences` in §2). Without it, cookies set in the
last moments before a stop could miss the sealed archive; the self-test found exactly that for
imported cookies. A stopped profile's website data is sealed (§3), so its cookies are queued,
encrypted with the profile's key, and put into its store at its next launch, before its first page
loads (they then show in the start page's request); the queue is removed. Session cookies live
until the profile stops, as in the browser they came from; for an ephemeral profile all imported
cookies last for that run only.

**Limits.** Domains in Unicode (IDN) are refused rather than converted; a value in a legacy encoding
(Windows-1251, Latin-1) shows as damaged bytes; the queue itself is local to this Mac (with cookie
sync on, the cookies join the synced ones at the profile's next launch, §8b); a profile that is
starting or being encrypted asks to try again a moment later.

## 8b. Profile sync: cookies and settings

With sync set up (**More → Sync…**), a profile's settings, passwords, bookmarks, history and —
with **Sync cookies with other devices** on (the default; never for an ephemeral profile) — its
persistent cookies sync between Macs, encrypted with the profile's key inside the sync envelope
(the server or folder sees no cookie name, value or domain). Format and rules:
[SYNC_FORMAT.md](SYNC_FORMAT.md).

- **Cookies** merge cookie by cookie (name, domain, path): the newer change wins, deletions
  included, and both devices end with the same set. A device records what a run changed when
  the profile stops (before its data is sealed), and applies the synced cookies when it launches,
  before the first page loads; cookies imported into a stopped profile are recorded at that
  launch, after the synced ones went in. Session cookies never sync; partitioned (CHIPS) cookies
  neither (WebKit cannot set them in their partition elsewhere). Turning the switch off empties the
  synced cookies on every device at the next sync; the cookie stores keep what they hold.
- **Settings** changed on two devices: the newer edit wins (the time of the last change made in
  the editor or the passwords' "Never" list), and the other device's version is kept next to it
  as `config.bin.conflict`, encrypted. A difference only in what the browser stores for itself
  (the proxy's location found at a launch) is no conflict.
- **Not synced:** localStorage, IndexedDB, caches and service workers, so a site that keeps its
  sign-in there rather than in a cookie is signed in on one Mac only. Changes reach another Mac
  only through a sync with every profile stopped, and at its next launch of the profile; a
  profile running on two Macs at once diverges until each has stopped and synced (then the
  later change of each cookie wins — the one recorded at the later stop).

## 8c. Session warm-up robot

**⋯ → Warm Up…** visits a list of pages in one profile, one after the other, to give it a
browsing past (cookies, history, site preferences) before it is used: a search first if one is
given (the address bar's engine, DuckDuckGo), then the addresses in their order (http and https
only, at most 50; other lines are listed with the reason and skipped). For each page it:
- loads it in **its own tab of the profile** — the profile's data store, proxy (fail-closed as
  always), User-Agent, shims and AutoFill, exactly as when the user browses; the visits go into
  the profile's history and their cookies into its store (and sync with the profile's cookies);
- stays a **random time** between the plan's two times (5–15 s by default, 2–300 s allowed), then
  waits 1–3 s before the next page;
- **scrolls** now and then (about every four seconds, at most six times per page, never in the
  last second; mostly down, sometimes back up), in flicks of slowing wheel steps;
- optionally **follows one link** before leaving: a plain link in view (`WarmUpLinkPolicy`) — on
  the same site for the user's addresses, to another site from the search results — never one
  opening a new window or a download, one to a file (`.zip`, `.pdf`, …) or one whose text or
  address speaks of signing out, deleting, buying, paying, ordering, subscribing or downloading,
  nor one hidden (by its own or an ancestor's opacity or visibility) or covered by something
  else; each link is judged by itself, `<base target>` included; it stays on that page half as long.

Nothing is typed or submitted, and nothing is downloaded: while a run drives its tab, a response
the browser would save as a file fails as a load instead. A page that does not load is reported and skipped; one still
loading after 30 s is left as it is. A page counts as come once its own load has committed (or
ended, or — an address that only jumps within the page shown — the tab shows that page) and
nothing loads any more, not merely once the tab's address changed with nothing loading. The robot
asks for its first page while its new tab's blank load is still being decided, and WebKit drops
the pending address when it decides on that load, which can leave the tab with no address and
nothing loading until the page's own load starts. An earlier version could take that moment for
the page: the likely cause of an intermittent self-test failure in which a run's first page was
never scrolled.

**How it acts, and what a page can see.** The robot reads pages (scroll position, links) in a
content world of its own: it installs no script and no message handler, so the page world —
`window.webkit`, its globals, what `fingerprint_probe.js` measures — is the same as without it
(a one-shot `mousemove` listener it adds before a click lives in its world too).
While its window is the key window it scrolls with wheel events and clicks with mouse events
sent to the web view, as from a mouse with smooth scrolling (the click only after a trusted
pointer move was seen to reach that very link); these events are trusted. Otherwise — another app in
front, or a WebKit that does not take the events — it scrolls with `scrollBy` from its world
(the page sees the scrolling, with trusted `scroll` events, but no `wheel`) and clicks with the
link's `click()`, an **untrusted** click a page can tell apart. The sheet's run does not say which
was used; the self-test reports it. On the CI runner (macOS 26) the wheel events reached the pages
but synthesized pointer events did not, through any of the three ways tried (Quartz events and
AppKit events to the view, AppKit events to the window): there every followed link was clicked
with `click()`.

**User activation.** WebKit runs every script an app sends into a page as if the user had just
interacted (`callAsyncJavaScript` forces a user gesture), in any content world. The robot's reads
(scroll position, links) therefore mark the page as activated: `navigator.userActivation` reports
`hasBeenActive` even on a page the robot only scrolled with the wheel, where a visitor's would not
(wheel scrolling is no activation). It loads a page only while its tab is the one shown, because
a page loading in a tab out of sight is hidden (`document.visibilityState`) and cannot be scrolled
with the wheel, which is not how a visitor reads it; it waits meanwhile.

**Stopping.** Stop in the sheet; closing the robot's tab; stopping the profile (the robot is
stopped first, before the data store is released, and holds its tab only weakly, so the seal is
not held up); Lock and Quit (they stop every profile); a page that shows a dialog (alert, sign-in)
stops it and leaves the dialog to the user. The run goes on when the sheet is closed; the
profile list shows its progress.

**Limits.** No browsing intelligence: the order is the list's, the links are chosen at random
among the allowed ones in view, the timing is random within fixed ranges. Rhythm and paths are
still a robot's, and sites that profile behaviour (or ask for a CAPTCHA) can tell; a CAPTCHA or a
consent banner is neither answered nor clicked away. It does not sign in, fill forms, play media
or open new windows. Only one run per profile at a time; the plan (`warmup.bin`) stays on this
Mac.

## 9. App Sandbox

The default build (`scripts/build-app.sh`) is **sandboxed**. `SANDBOX=0` produces a
hardened-runtime build without the sandbox, for debugging. `build-app.sh` checks the
signature and fails if the sandbox state isn't what was requested.

**Entitlements** (`Resources/PrivacyBrowser.entitlements`):

| Entitlement | Needed for |
|---|---|
| `com.apple.security.app-sandbox` | the sandbox itself |
| `com.apple.security.network.client` | all WKWebView networking (WebKit's network process acts on the app's behalf), proxies, HTTP sync |
| `com.apple.security.device.camera`, `…device.audio-input` | `getUserMedia`, after the in-app prompt (also required under the hardened runtime) |
| `com.apple.security.files.user-selected.read-write` | `<input type=file>` uploads; choosing the sync folder (Powerbox) |
| `com.apple.security.files.downloads.read-write` | saving downloads to `~/Downloads` |
| `com.apple.security.files.bookmarks.app-scope` | remembering the sync folder across launches (security-scoped bookmark) |

Not requested: `network.server` (the app never listens), location, contacts, calendars,
printing, Apple Events, JIT (WebKit's JIT runs in Apple's own WebContent process).

**What changes inside the sandbox:**

- Every path comes from `FileManager.urls(for:in:)`, so the vault, WebKit data, caches and
  temporary files all live in `~/Library/Containers/<bundle-id>/Data/`.
  `PRIVACYBROWSER_VAULT_DIR` must point inside the container.
- WebKit omits the bundle ID from its data paths when the process has a container.
  `WebKitDataLayout` handles both layouts and translates archives sealed by the
  unsandboxed build.
- The container is another layer of protection for the plaintext WebKit data of running
  profiles: other sandboxed apps can't read it. Unsandboxed processes of the same user still
  can, subject to macOS's container privacy protection (TCC "App Data" prompts on macOS 14+).

**Migrating from an unsandboxed build:** `Contents/Resources/container-migration.plist`
makes macOS move `~/Library/Application Support/PrivacyBrowser` (and any unsealed WebKit
data left by a crash) into the container on the sandboxed build's first launch. This is
one-way, and happens only when the container doesn't exist yet. CI verifies it with a
separate bundle ID.
`WebDataStoreVault` then restores archives sealed by the old build at the sandboxed
locations.

## 10. Threat model summary

**Protects against:**

- Someone who gets a copy of the disk or a backup while the app is locked, or while the
  relevant profile is stopped. They see only ciphertext and `vault.json` (KDF parameters).
- Websites in one profile reading another profile's cookies, storage, history or bookmarks.
- Casual IP and location leaks: fail-closed proxy, WebRTC off, geolocation denied.
- A sync server or sync folder learning profile names, settings, passwords, history,
  bookmarks, cookies or browsing data.
- Other sandboxed apps reading the app's data (App Sandbox).

**Does not protect against:**

- Malware or root on the running machine (it can read memory and live plaintext).
- Device fingerprinting that links profiles through hardware or rendering
  characteristics (§2).
- Offline guessing of a weak master password by anyone holding `vault.json`.
- A sync server rolling back to an older complete snapshot (no signed manifest).

## 11. App lifecycle, appearance and language

**Window lifecycle.**
- Closing a profile's last window stops that profile and seals its website data. The app
  stays open, and the Profiles window comes back to the front.
- Only ⌘Q or **Lock** stops everything. Quitting with profiles running closes every window
  and seals every profile in the normal run loop, then quits (`QuitCoordinator`); sealing
  inside `terminate:` failed on ⌘Q because WebKit still held the focused page. A second ⌘Q
  during that wait doesn't start a second shutdown. If WebKit never lets go of a store, the
  quit forces the seal (archive + delete, `webdata.forced` marker) and logs it.
- Clicking the Dock icon with no window open shows the Profiles window again.

**Crash fix.** Earlier builds released a browser window's controller from inside
`windowWillClose`. That could free the `NSWindow` while AppKit was still closing it (a
use-after-free), and the resulting crash took the whole app down, so it looked as if closing a
profile window quit the app. The callback now runs on the next run-loop turn, and
`BrowserSession.shutDown()` is idempotent. The self-test's `lifecycle:` checks cover this.

**Appearance.** The app's own windows are always dark (Lumen's theme, `Theme.swift`): each
window the app draws gets the Dark Aqua appearance and its SwiftUI views the dark colour
scheme. `NSApp.appearance` is left unset, so web content keeps following the Mac's
light/dark setting, as in Safari: the container of a window's web views is given the
system's appearance explicitly, and again whenever the setting changes
(`WebContentAppearance`). Pages therefore get the `prefers-color-scheme`, form controls and
scroll bars Safari would give them. Earlier builds forced the light appearance on
everything, web content included, so on a Mac set to dark, pages saw light where Safari
reports dark. Web content is not restyled; pages render as their sites define them.

**Launch screen.** Setting up and unlocking the vault happen on a dark launch screen: the
mark, a title and the form. While the key is derived (Argon2id), the form gives way to a
progress line, and the Profiles window fades in once the vault is open. Lock fades back to
the same screen. Under Reduce Motion the screen and the start page appear without motion.

**Browser window.** The toolbar is flat: the window's dark colour under a transparent title
bar, with no glass behind its items (macOS 26 would add it). It holds the Lumen mark, the
navigation buttons, the address field and the profile chip. The chip shows the profile's
glyph and name and, through a proxy, the flag of the country its exit IP is in. That country
comes from this launch's lookup, else from the location remembered for the same proxy, and
it is updated when a lookup finishes after launch.
- An empty new tab (⌘T, or a window opened without an address) shows a start page:
  - the profile's favourites (its top-level bookmarks);
  - its last visited pages;
  - where its proxy exits.
- The start page is a native view laid over the tab, not web content. Pages never see it,
  and nothing is loaded for it: no favicons are fetched, and the tiles show the site's
  initial instead. The tab's web view stays blank underneath until something is opened, and
  popups, links and tabs opened with an address never show it.
- The toolbar keeps Safari's 52 pt and the tab strip its 38 pt, so the `outerHeight −
  innerHeight` that pages measure is unchanged. CI's comparison with this Mac's Safari
  checks it.

**Language.**
- The UI defaults to Russian, with English as the fallback. Strings live in
  `Resources/{ru,en}.lproj/Localizable.strings` (both languages complete), which
  `build-app.sh` copies into the app bundle.
- Lookups go through an explicitly chosen bundle (`Localization.swift`), so the language is
  deterministic within a launch. Setting `AppleLanguages` makes AppKit's own menus and
  panels follow too.
- `PRIVACYBROWSER_LANG=en` switches the UI to English.
- Run outside the app bundle (`swift run`, or Xcode's SwiftPM scheme), the strings tables
  are missing and keys are shown instead.
- Pluralisation is simplified ("Профилей: 3"); there is no `.stringsdict` yet.
- The UI language does **not** change what web pages see: `navigator.language` and
  `Accept-Language` follow the app's language list, and there is no per-profile override (§2).

