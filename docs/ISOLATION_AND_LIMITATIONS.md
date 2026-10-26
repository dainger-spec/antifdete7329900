# Isolation model and platform limitations

This document lists what is isolated, what is only approximated, and what is not
addressed. It also gives a way to verify each claim on your own machine. The code
comments marked `PLATFORM LIMITATION` / `FINGERPRINTING LIMITATION` point back here.

## 0. What is verified automatically

`PrivacyBrowser --self-test` runs headless against the real WebKit of the machine. CI runs it
on every push (macOS 26 runner, built with the current Xcode) for both the sandboxed and the
unsandboxed build, with a local test proxy (`scripts/selftest_proxy.py`). Last observed results
(macOS 26, 142/142 checks in both builds):

| Claim | Self-test result |
|---|---|
| Vault key derivation | a PBKDF2 vault is re-wrapped under Argon2id (64 MiB, 3 passes, 4 lanes) in the release build and opens again; the time is logged |
| Sandbox active; vault inside the container | writes outside the container are denied; vault at `~/Library/Containers/<id>/Data/Library/Application Support/PrivacyBrowser` |
| WebKit data location (undocumented) | sandboxed: `Container/Data/Library/WebKit/WebsiteDataStore/<uuid>`; unsandboxed: `~/Library/WebKit/<bundle-id>/WebsiteDataStore/<uuid>`. One directory per store; no separate cache directory was observed |
| Seal → restore of website data | cookies, localStorage and IndexedDB survive; the archive holds no plaintext; plaintext is gone after seal; WebKit released the store after 1 s |
| Two running profiles isolated | localStorage, IndexedDB and cookies of A are invisible to B, for the same origin, at the same time |
| JS shims under JavaScriptCore | time zone (offset, `Intl`, local getters), fixed geolocation, WebRTC removed, WebRTC relay-only |
| WebRTC off (default) | switched off in the engine (`_peerConnectionEnabled` is false): the window has no `RTC*` interface at all |
| HTTP CONNECT proxy | `http://` is tunnelled via `CONNECT`; an `.invalid` host loads, so it was resolved by the proxy |
| SOCKS5 proxy | the hostname is sent to the proxy (`ATYP=3`, remote DNS) |
| Fail-closed | with the proxy unreachable, loads fail ("Could not connect to the server") instead of going direct |
| Tabs, history, bookmarks | tab open/close/reopen/select, visits and titles recorded, bookmark toggle persisted encrypted |
| Window lifecycle (crash fix) | closing one of two windows keeps the profile running; closing the last reports "all closed" once, on a later run-loop turn; `shutDown()` twice is safe |
| Crash-recovery sealing | leftover website data from a crashed run is archived and deleted WITHOUT `WKWebsiteDataStore.remove(forIdentifier:)` (which aborted on an unknown id), then restores cleanly |
| Device generation → UA | a profile's generation UA reaches `navigator.userAgent`; an explicit custom UA overrides it |
| Container migration | an unsandboxed vault is moved into the container on the sandboxed build's first launch (separate CI step) |
| Fingerprint surface | a macOS profile measures the same as a plain WKWebView on the same Mac (navigator, screen, canvas, WebGL, audio, fonts, feature list) except for `window.safari` and the Fullscreen API, which Safari has and a bare WKWebView lacks; an iPhone profile reports its device class's navigator and screen values; user-installed fonts are hidden from pages, as in Safari. CI also compares the macOS profile with the runner's real Safari (§2) |
| Shims in workers and frames | a worker made from a blob runs in the profile's zone, stays strict and keeps its line numbers; a frame reached as `window[i]` right after insertion is patched; `permissions.query({name:'geolocation'})` returns the engine's own `PermissionStatus`, 'prompt' until the page asks |
| Proxy: IPv6, unresolvable host | an HTTP proxy on `[::1]` tunnels the load; a proxy whose host does not resolve fails closed |
| Proxy: WebRTC | a proxied profile whose stored setting is "unrestricted" has no `RTCPeerConnection` or `RTCDataChannel` while the packet tunnel cannot carry it (§5) |
| Packet tunnel | a build without the network extension reports it (the tunnel sheet says what a signed build needs), and proxied profiles keep WebRTC off. The tunnel's TURN server and SOCKS5 relay are measured by the leak check instead ([TUNNEL.md](TUNNEL.md)) |
| Proxy: dns-prefetch leak | an `<a ping>` (the load type WebKit gives dns-prefetch) reaches neither the proxy nor the network; a fetch to the same origin does |
| Proxy: 407 without credentials | the launch is refused ("needs credentials") and the data is sealed again; nothing opens, directly or otherwise |
| Proxy: `Accept-Language` | the header the proxy sees is the language the app decided at its first launch (`de-DE,de;q=0.9` in the self-test) |
| Time zone from the proxy | a profile with a proxy and *Time zone of the proxy's location* runs in the time zone the lookup through the proxy returned, cached per profile |
| Several SOCKS5 profiles at once | three profiles behind three SOCKS5 proxies, one with username/password authentication, are launched together through the app's launch path and load at the same time: each page arrives through its own proxy, by name, with its own credentials; after one stops the others keep loading through theirs; wrong or missing SOCKS5 credentials fail closed |
| Launch speed | with a location remembered for the proxy, a launch waits at most 1 s for a 4 s lookup (the lookup finishes in the background, and its new time zone is remembered and noted for the next launch); with nothing remembered it waits at most 3 s |
| Proxy exit IP | with *Warn when the proxy's IP changes* on, a changed exit IP (same proxy and credentials) is reported, the first launch and an unchanged IP are not; the option is off by default and then nothing is reported or stored, and turning it off while a lookup is under way leaves no IP stored and nothing reported |
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

**Mechanism.** Each persistent profile uses `WKWebsiteDataStore(forIdentifier: <profile UUID>)`.
Each ephemeral profile uses `WKWebsiteDataStore.nonPersistent()`. Every `WKWebView` of a
profile gets that store: every tab of every window, and popups, because
`createWebViewWith` uses the configuration WebKit passes in, which inherits the opener's
store.

**Isolated per store, by WebKit:** cookies, localStorage, sessionStorage, IndexedDB,
Cache API, service worker registrations, the HTTP disk and memory cache, HSTS state,
media keys, the per-session credential store, and Intelligent Tracking Prevention
classification.

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
| Time zone | JS shim (`Intl`, `Date` getters, offsets) | approximation; blob workers covered, URL-loaded and service workers not |
| Geolocation | JS shim (deny / fixed coordinates) | approximation |
| WebRTC exposure | off in the engine (private `WKPreferences` property, as Lockdown Mode) or a JS shim (relay-only) | native when off; approximation for relay-only |

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
  touch points and screen (which is how a page tells such an iPad from a Mac);
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
  The iOS/iPadOS generations change the UA string while every measured signal in the table
  below still says "desktop Mac" — the editor flags this.

Compared with a deeply integrated product that ships and switches genuine per-version WebKit
cores, this is version *labelling*, not version *emulation*. It is honest about being
Safari on this Mac.

### What remains impossible with public APIs

FINGERPRINTING LIMITATION. Each of the following would require private WebKit API, a
modified WebKit, or different hardware. None is attempted:

| Signal | Why a profile can't change it |
|---|---|
| Canvas 2D / WebGL pixels, WebGL renderer and vendor strings, extensions, limits | produced by the Mac's GPU and driver; WebKit exposes them as is |
| AudioContext output | the Mac's audio stack |
| Fonts (measured via text metrics) | macOS system fonts; iOS has a different font set. As in Safari, fonts the user installed are hidden from pages (the WebKit preference Safari sets, `_shouldAllowUserInstalledFonts`; it has no public API, so it is applied only when this WebKit has it, which the self-test checks) |
| Screen size, colour depth, device pixel ratio, `matchMedia` results | the real display; no per-view override |
| `navigator.platform`, `vendor`, `hardwareConcurrency`, `maxTouchPoints` | engine and hardware; `customUserAgent` changes only the UA string. macOS profiles keep the native values; iPhone/iPad profiles get their device class's values from the shim (detectable, not in workers) |
| Touch and pointer behaviour, `ontouchstart`, orientation and motion events | macOS WebKit is a desktop engine; there is no touch-input emulation API |
| `navigator.languages`, `Accept-Language` | one list per app run: WebKit reads it once, when its first process starts. The first profile launched picks it (its proxy's country, else the app's language); the shim never overrides `navigator.language(s)`, so header and script agree |
| Supported JS/CSS features, media codecs, WebKit version quirks | the installed macOS WebKit, which differs from iOS WebKit |
| TLS ClientHello, HTTP/2 settings, header order | Apple's macOS network stack |

**Why this project doesn't paper over these with JavaScript:** injected overrides for canvas,
WebGL, audio or fonts are unreliable. They don't reach workers, don't change server-side TLS
or HTTP signals, and leave measurable inconsistencies — fingerprinting pages flag the noise
itself ("Canvas: Spoofed", "Fingerprinting Resistance: Detected"). They also mainly serve
to defeat fraud and abuse detection, which is not a goal here. What the shims *do* replace
(time zone, geolocation, WebRTC, and the navigator/screen values of a mobile generation) is
replaced the way the engine defines it — accessors on the prototypes, strict methods with
only `length` and `name`, the native receiver errors, and a `Function.prototype.toString`
that prints them as native code even from a fresh iframe — so the replacement itself is not
the thing a page notices; the inconsistencies listed above still are. CI compares a macOS
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
  and once with the time-zone and WebRTC wrappers running on Safari's own values. Both JSON sets
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
  on every Mac, a tenth of it in a third-party frame); `estimate()` now reports the same.
- **Geolocation permission.** `permissions.query({name: 'geolocation'})` threw a TypeError (the shim
  built a fake status); it is now the engine's own `PermissionStatus`, 'prompt' until the page asks.
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
- **The replacement `Date` and `Intl.DateTimeFormat`** (only with a time zone set) list `length`
  and `name` before their statics: JavaScriptCore orders a script function's own properties that
  way whatever the definition order.
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
| DNS prefetch | `<link rel="dns-prefetch">` (also as a `Link:` header) makes the network process resolve the host through the system resolver — WebKit skips it only for a *system-wide* proxy, not for a data store's `proxyConfigurations` | A content rule list blocking `ping`-type loads is added to every proxied profile (`ContentRules`): WebKit runs dns-prefetch through it as a ping. It also blocks `<a ping>` click trackers; beacons are fetches and unaffected. Verified by the self-test with an `<a ping>` |
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
profile is saved, and a lookup still under way then neither stores an IP nor warns.

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
  a private property; Lockdown Mode turns off the same setting): no `RTC*` interface exists
  in any frame. Where WebKit lacks that property, the document-start user script removes
  every `RTC*` interface from the window instead, as in an engine built without WebRTC.
- `relayOnly` wraps the constructor and `setConfiguration` to force
  `iceTransportPolicy: "relay"`. No host or srflx candidates are gathered, so peers see
  only the TURN server's address. The TURN server still sees your real IP. With a proxy,
  only the tunnel's relay is used.
- `unrestricted` uses the WebKit default; never applied with a proxy.

**Limits of the shim (relay-only, and the fallback removal):** it isn't applied in workers, which have no RTCPeerConnection
anyway. The script runs in every same-origin frame when its document starts, so a frame
created by the page (`window.frames[i]`, `window[i]`) is already patched when the page
reaches it; `contentWindow`, `contentDocument` and `window.open` are hooked as well for a
window reached before its own copy ran. A cross-origin frame is patched by its own copy and
cannot be inspected from the page anyway.

## 6. Time zone, geolocation, user agent

| Setting | Implementation | Native? | Gaps |
|---|---|---|---|
| User agent | `WKWebView.customUserAgent`, with presets in the editor | yes (string only) | `navigator.platform`, vendor, feature set and TLS fingerprint still identify WebKit on macOS (§2). Use the *Safari on macOS* preset; iPhone/iPad presets are UA-only and inconsistent |
| Time zone | JS: `Intl.DateTimeFormat` default `timeZone`; `Date` local getters and setters, `getTimezoneOffset` (with the sub-minute offsets of historical dates), the local constructor forms `new Date(y, m, d, …)`, `Date.parse` and `new Date(string)` for strings without an offset, `toString`, `toDateString`, `toTimeString`, `toLocale*String`, `getYear`/`setYear`. A worker made from a blob of the page (how fingerprinting scripts make theirs) starts with the same shim: the blob is handed to the engine as [shim, page's blob], so the worker keeps its blob: location, relative URLs, CSP, strict mode and line numbers | no | Workers loaded from a URL and service workers use the host zone (rewriting them would change their location); under a CSP without `'unsafe-eval'` a blob worker does too. JavaScriptCore lists the replacement `Date`'s and `Intl.DateTimeFormat`'s `length`/`name` before their statics (`Object.getOwnPropertyNames(Date)`), which no script function can avoid. `Intl.DateTimeFormat().format()` without an explicit zone follows the shim; other `Intl` constructors carry no zone |
| Geolocation | JS: `navigator.geolocation` answers as WebKit does for a user who said no ("User denied Geolocation") or who allowed the fixed coordinates; positions and errors are instances of the real interfaces with no own properties (values from the prototype getters and `toJSON`); `permissions.query({name:'geolocation'})` returns the engine's own `PermissionStatus`, 'prompt' until the page asks (WebKit's `hasBeenRequested`), then 'denied'/'granted' | no | The IP address (proxy) is what most sites actually use. The app has no `NSLocationUsageDescription` and no location entitlement, so CoreLocation can't be reached even if the shim is bypassed |
| Time zone from the proxy | At launch, a geolocation service (ipinfo.io, then geojs.io, ipwho.is) is asked *through the profile's proxy* where it exits; the profile runs in that zone. The last answer per proxy is used on later launches when the new lookup takes over 1 s (and when a lookup fails), that lookup finishing in the background; with nothing remembered the launch waits for it at most 3 s (§4) | — | A third-party request per launch (HTTPS, via the proxy only, no cookies). Off per profile with *Time zone of the proxy's location*; *Override time zone* replaces the zone but keeps the lookup, for the country (language). Without any answer the host zone is used; a time zone that changed applies from the next launch |
| Language | Process-wide: set before WebKit's first process from the first launched profile's proxy country (`WebContentLanguage`) | partly | WKWebView has no per-view `Accept-Language` / `navigator.languages` API; later profiles of the same run share the first one's language |

The shim logic is tested under Node (`scripts/test-shims.mjs`) against ICU, across
fixed-offset zones, DST transitions, 30-minute shifts and pre-1900 offsets, together with
the function-shape checks CreepJS runs (toString from the window and from a frame, own
keys, receiver errors). The key cases are also checked under JavaScriptCore by the self-test,
whose surface checks compare a macOS profile with a plain WKWebView key by key.

**Mobile generations (iPhone, iPad):** the browser window is the declared device's screen
(content size and maximum size), `outerWidth`/`outerHeight` report it, and the
navigator/screen values are accessors on the prototypes. CSS media queries
(`device-width`), touch events, fonts, GPU and TLS still say "Mac"; CreepJS also compares
the page's `navigator` with a worker's, which a user script cannot reach.

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

WKWebView has no AutoFill integration: neither Safari's AutoFill nor the system
credential provider is available to third-party WKWebView hosts on macOS. The prototype
offers:

- **Fill:** an explicit button. It runs in the isolated `.defaultClient` JS world, so page
  scripts can't intercept the function or the prototypes it uses. Before filling, it
  checks that `location.origin` equals the entry's origin. Main frame only.
- **Save:** an explicit button that reads the typed values, with a confirmation dialog.
- **HTTP Basic/Digest:** answered from the vault on the first challenge, with a prompt
  after that.

Origins are matched exactly (scheme, host and port) without subdomain matching, so
credentials are never offered to a different site.

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
  bookmarks or browsing data.
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

**Appearance.** The app forces the light (Aqua) appearance, regardless of the system setting:
`NSApp.appearance` plus `.preferredColorScheme(.light)`. Web content is not restyled; pages
render as their sites define them.

**Language.**
- The UI defaults to Russian, with English as the fallback. Strings live in
  `Resources/{ru,en}.lproj/Localizable.strings` (206 keys, both languages complete), which
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

