# Isolation model and platform limitations

This document lists what is isolated, what is only approximated, and what is not
addressed. It also gives a way to verify each claim on your own machine. The code
comments marked `PLATFORM LIMITATION` / `FINGERPRINTING LIMITATION` point back here.

## 0. What is verified automatically

`PrivacyBrowser --self-test` runs headless against the real WebKit of the machine. CI runs it
on every push (macOS 15 runner) for both the sandboxed and the unsandboxed build, with a local
test proxy (`scripts/selftest_proxy.py`). Last observed results (macOS 15.7, 38/38 checks
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
| Device fingerprint | see §2 | Profiles can be linked by fingerprinting |
| Downloads folder | Downloads go to `~/Downloads` in plaintext | Outside the encrypted storage |

## 2. Fingerprinting (not addressed)

FINGERPRINTING LIMITATION: WKWebView has no public API to change what the rendering engine
and the hardware reveal, and this project doesn't use private API or attempt to spoof
these. Every profile therefore presents the same device to a site that measures it:

| Surface | Same in all profiles because |
|---|---|
| Canvas 2D / WebGL rendering, WebGL renderer and vendor strings, supported extensions | GPU and driver of the Mac; WebKit exposes them as is |
| AudioContext output | audio stack of the Mac |
| Installed fonts (measured via text metrics) | system fonts; WebKit restricts the list somewhat, but uniformly |
| Screen size, colour depth, device pixel ratio | the real display |
| `navigator.hardwareConcurrency`, `deviceMemory`, `platform`, `vendor`, `maxTouchPoints` | engine and hardware; `customUserAgent` changes only the UA string |
| Languages (`navigator.languages`, `Accept-Language`) | system language settings; no per-view API |
| Supported JS/CSS features, media codecs | the installed WebKit version |
| TLS ClientHello, HTTP/2 settings, header order | Apple's network stack (Network.framework) |

What *is* per profile: storage, IP (proxy), user-agent string, time zone (JS-level), geolocation
(JS-level), WebRTC exposure (JS-level). Choose these consistently: a Safari UA, plus a time
zone and geolocation that match the proxy's location. An inconsistent combination, such as
a Chrome UA on WebKit, or a Tokyo time zone behind a Paris exit, is itself distinctive.

Mitigations that are possible but not implemented: a separate macOS user account per
identity (OS-level separation), or a different machine or VM per identity (different
hardware fingerprint).

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
| User agent | `WKWebView.customUserAgent` | yes | `navigator.platform`, vendor, feature set and TLS fingerprint still identify WebKit on macOS (§2). Use a Safari UA |
| Time zone | JS: `Intl.DateTimeFormat` default `timeZone`, `Date` local getters, `getTimezoneOffset`, `toString`, `toDateString`, `toTimeString`, `toLocale*String` | no | Workers use the host zone. `new Date(y, m, d, …)`, local setters (`setHours` …) and `Date.parse` of strings without an offset use the host zone. Detectable |
| Geolocation | JS: `navigator.geolocation` returns PERMISSION_DENIED, or fixed coordinates; `permissions.query({name:'geolocation'})` agrees | no | Detectable. The IP address (proxy) is what most sites actually use. The app has no `NSLocationUsageDescription` and no location entitlement, so CoreLocation can't be reached even if the shim is bypassed |
| Language | not implemented | — | WKWebView has no per-view `Accept-Language` / `navigator.languages` API |

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
