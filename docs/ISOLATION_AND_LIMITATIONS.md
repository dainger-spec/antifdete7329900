# Isolation model and platform limitations

This document lists what is isolated, what is only approximated, and what is not
addressed. It also gives a way to verify each claim on your own machine. The code
comments marked `PLATFORM LIMITATION` / `FINGERPRINTING LIMITATION` point back here.

**Update 2026-10-25:** iOS/iPadOS profiles now apply aggressive document-start JS shims
(navigator, screen, canvas/WebGL noise, fonts, audio, connection). This is the practical
maximum on public WKWebView. It does **not** achieve engine-level iOS fidelity. See §2.

## 0. What is verified automatically

`PrivacyBrowser --self-test` runs headless against the real WebKit of the machine. CI runs it
on every push (macOS 15 runner) for both the sandboxed and the unsandboxed build, with a local
test proxy (`scripts/selftest_proxy.py`). Last observed results (macOS 15.7, 50/50 checks
in both builds):

| Claim | Self-test result |
|---|---|
| Sandbox active; vault inside the container | writes outside the container are denied; vault at `~/Library/Containers/<id>/Data/Library/Application Support/PrivacyBrowser` |
| WebKit data location (undocumented) | sandboxed: `Container/Data/Library/WebKit/WebsiteDataStore/<uuid>`; unsandboxed: `~/Library/WebKit/<bundle-id>/WebsiteDataStore/<uuid>`. One directory per store; no separate cache directory was observed |
| Seal → restore of website data | cookies, localStorage and IndexedDB survive; the archive holds no plaintext; plaintext is gone after seal; WebKit released the store after 1 s |
| Two running profiles isolated | localStorage, IndexedDB and cookies of A are invisible to B, for the same origin, at the same time |
| JS shims under JavaScriptCore | time zone (offset, `Intl`, local getters), fixed geolocation, WebRTC removed, WebRTC relay-only |
| HTTP CONNECT proxy | `http://` is tunnelled via `CONNECT`; an `.invalid` host loads, so it was resolved by the proxy |
| SOCKS5 proxy | the hostname is sent to the proxy (`ATYP=3`, remote DNS) |
| Fail-closed | with the proxy unreachable, loads fail ("Could not connect to the server") instead of going direct |
| Tabs, history, bookmarks | tab open/close/reopen/select, visits and titles recorded, bookmark toggle persisted encrypted |
| Window lifecycle (crash fix) | closing one of two windows keeps the profile running; closing the last reports "all closed" once, on a later run-loop turn; `shutDown()` twice is safe |
| Crash-recovery sealing | leftover website data from a crashed run is archived and deleted WITHOUT `WKWebsiteDataStore.remove(forIdentifier:)` (which aborted on an unknown id), then restores cleanly |
| Device generation → UA | a profile's generation UA reaches `navigator.userAgent`; an explicit custom UA overrides it |
| Container migration | an unsandboxed vault is moved into the container on the sandboxed build's first launch (separate CI step) |

Run it yourself: `build/PrivacyBrowser.app/Contents/MacOS/PrivacyBrowser --self-test`. For the
proxy checks, start `python3 scripts/selftest_proxy.py --http 18080 --socks 18081` first and set
`PB_SELFTEST_HTTP_PROXY_PORT=18080 PB_SELFTEST_SOCKS_PROXY_PORT=18081`. The self-test uses a
temporary vault and removes everything it creates.

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
| Device fingerprint (partial) | see §2 | JS shims reduce some signals; GPU/TLS/fonts still linkable |
| Downloads folder | Downloads go to `~/Downloads` in plaintext | Outside the encrypted storage |

## 2. Fingerprinting and "Apple device" consistency

**Short answer:** every profile runs on the macOS system WebKit. iOS/iPadOS profiles now
inject aggressive JS shims that override navigator properties, screen geometry, canvas/WebGL
(with noise), basic fonts, audio analyser, and `navigator.connection`. This is the practical
maximum with public APIs. It is **not** a genuine iPhone. GPU, TLS ClientHello, full font set,
touch behaviour, and many timing signals still identify the host Mac. Sites with strong
fingerprinting will still detect it.

### What is now spoofed via JS (iOS profiles)

| Attribute | Mechanism | Notes |
|---|---|---|
| User-Agent | native `customUserAgent` + generation | string only |
| navigator.platform / vendor / hardwareConcurrency / deviceMemory / maxTouchPoints / languages | JS defineProperty | main frame + hooked children |
| screen width/height / devicePixelRatio | JS | driven by DeviceModel if set |
| navigator.connection | JS | effectiveType / downlink |
| Canvas 2D getImageData | JS noise | deterministic-ish, detectable |
| WebGL UNMASKED_VENDOR / RENDERER | JS getParameter override | "Apple Inc." / "Apple GPU" |
| document.fonts.size | JS | crude |
| AudioContext analyser | JS noise on getFloatFrequencyData | minimal |
| Time zone / geolocation / WebRTC | existing shims | see below |

### What remains impossible with public APIs

FINGERPRINTING LIMITATION. Still requires private WebKit, modified engine, or different hardware:

| Signal | Why it still leaks |
|---|---|
| Real canvas/WebGL pixels, extensions, limits, timing | Mac GPU + driver; noise is detectable |
| Full font metrics / list | macOS fonts differ from iOS |
| TLS ClientHello, HTTP/2 settings, header order | system network stack |
| Touch / orientation / motion events | desktop engine |
| Supported JS/CSS features, codecs | host WebKit version |
| Workers | user scripts not injected |

Compared with products that claim engine-level iOS cores, this is still labelling + JS
overrides, not emulation. The honest options for stronger separation remain outside the
browser (separate user accounts, VMs, or real devices).

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
   debugger, a core dump) can recover them.

**KDF.** PBKDF2-HMAC-SHA256 with 600 000 iterations is the strongest password KDF in the
macOS SDK. A memory-hard KDF such as Argon2id would resist GPU attacks better; it can be
added behind `KDFParameters.algorithm` using libsodium without changing the file formats.

## 4. Network and proxy

**Native (enforced by WebKit for the data store):** `proxyConfigurations` covers HTTP(S),
WebSocket, fetch/XHR, media and service-worker loads of that store.
`allowFailover = false` makes it fail closed. Supported proxies are SOCKS5 and HTTP
CONNECT, optionally TLS to the proxy, with or without username/password, plus a
per-profile bypass list. The CONNECT tunnelling, remote DNS for SOCKS5, and fail-closed
behaviour are verified by the self-test (§0).

**App Transport Security:** `NSAllowsArbitraryLoadsInWebContent` lets the browser load
`http://` pages. The app's own URLSession traffic (HTTP sync) remains HTTPS-only.

**Not covered:**

| Path | Status | Mitigation |
|---|---|---|
| WebRTC UDP (STUN/TURN, media) | Never proxied; STUN reveals the real public IP | WebRTC policy (see §5); the default is **disabled** |
| DNS prefetch | WebKit may resolve link hostnames via the system resolver before navigation; WKWebView has no public switch to disable it | Verify with `sudo tcpdump -n -i any port 53` while browsing through a proxy |
| Safe Browsing lookups | Made outside the data store's network session | Off by default (`safeBrowsingEnabled`) |
| `mailto:`, `tel:`, custom schemes | Would hand the URL to another app, outside the profile | Blocked by the navigation policy |
| Camera and microphone streams | Local capture; WebRTC transport isn't proxied | Asks the user every time |
| Sync traffic | Goes from the app process through the system network, not the profile proxy | Folder transport makes no network requests; HTTP sync is HTTPS and carries only encrypted blobs |

**Verify the proxy by hand:** set a SOCKS5 proxy, for example `ssh -D 1080 host`, open
`https://ifconfig.me`, and confirm it shows the proxy's IP. Then stop the proxy and
reload: the page must fail, not show your own IP.

## 5. WebRTC

WebKit offers no public preference to disable WebRTC or set an IP-handling policy. Its
default already hides local IPs behind mDNS host candidates, but STUN still discovers the
public IP over UDP, outside the proxy. WKWebView on macOS 15 exposes a native
`RTCPeerConnection` (observed by the self-test).

The profile setting is enforced by a document-start user script in every frame:

- `disabled` (default) removes `RTCPeerConnection`, `webkitRTCPeerConnection`,
  `RTCDataChannel` and related constructors, and makes them non-configurable.
- `relayOnly` wraps the constructor and `setConfiguration` to force
  `iceTransportPolicy: "relay"`. No host or srflx candidates are gathered, so peers see
  only the TURN server's address. The TURN server still sees your real IP, because TURN
  over UDP isn't proxied.
- `unrestricted` uses the WebKit default.

**Limits of the shim:** it isn't applied in workers, which have no RTCPeerConnection
anyway. A frame reached through `window.frames[i]` or `window[i]` before WebKit injects
the script into it can expose an unpatched constructor; `contentWindow`,
`contentDocument` and `window.open` are hooked. It is also detectable.

## 6. Time zone, geolocation, user agent

| Setting | Implementation | Native? | Gaps |
|---|---|---|---|
| User agent | `WKWebView.customUserAgent`, with presets in the editor | yes (string only) | Other signals still Mac unless JS shims cover them |
| Time zone | JS: `Intl.DateTimeFormat` default `timeZone`, `Date` local getters, `getTimezoneOffset`, `toString`, `toDateString`, `toTimeString`, `toLocale*String` | no | Workers use the host zone. `new Date(y, m, d, …)`, local setters (`setHours` …) and `Date.parse` of strings without an offset use the host zone. Detectable |
| Geolocation | JS: `navigator.geolocation` returns PERMISSION_DENIED, or fixed coordinates; `permissions.query({name:'geolocation'})` agrees | no | Detectable. The IP address (proxy) is what most sites actually use. The app has no `NSLocationUsageDescription` and no location entitlement, so CoreLocation can't be reached even if the shim is bypassed |
| Language | JS navigator.language / languages | no | Accept-Language header still system |

The shim logic is tested under Node (`scripts/test-shims.mjs`) against ICU, across
fixed-offset zones, DST transitions and 30-minute shifts. The key cases are also checked
under JavaScriptCore by the self-test.

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
hardened-runtime build without the sandbox, for debugging. See entitlements and
container migration details in the original source.
