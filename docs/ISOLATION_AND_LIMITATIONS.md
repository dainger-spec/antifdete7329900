# Isolation model and platform limitations

This document lists what is isolated, what is only approximated, and what is not
addressed. It also gives a way to verify each claim on your own machine. The code
comments marked `PLATFORM LIMITATION` point back to the sections here.

## 1. Storage isolation between profiles

**Mechanism.** Each persistent profile uses `WKWebsiteDataStore(forIdentifier: <profile UUID>)`.
Each ephemeral profile uses `WKWebsiteDataStore.nonPersistent()`. Every `WKWebView` of a
profile gets that store, including popups, because `createWebViewWith` uses the
configuration WebKit passes in, which inherits the opener's store.

**Isolated per store, by WebKit:** cookies, localStorage, sessionStorage, IndexedDB,
Cache API, service worker registrations, the HTTP disk and memory cache, HSTS state,
media keys, the per-session credential store, and Intelligent Tracking Prevention
classification.

**Shared between profiles (platform limitations):**

| Shared | Why | Effect |
|---|---|---|
| WebKit networking process | WebKit runs one network process per app, with one session per data store inside it | Isolation is per session (logical), not per OS process |
| Host fingerprint surface: fonts, screen size, GPU / WebGL renderer, canvas and audio rendering, `hardwareConcurrency`, `deviceMemory`, languages | WKWebView has no public API to change them | Sites that fingerprint the device can link profiles to each other |
| TLS / HTTP2 fingerprint | System network stack | Same for all profiles; always identifies Apple's stack |
| Downloads folder | Downloads go to `~/Downloads` in plaintext | Outside the encrypted storage |

**Verify:** run two profiles. In profile A, open a site and set a cookie
(`document.cookie="x=1"`). In profile B, open the same site and run `document.cookie` in
Web Inspector. You should get an empty string. To use Web Inspector, run
`defaults write <bundle-id> WebKitDeveloperExtras -bool true`, or set
`webView.isInspectable = true` in a debug build.

## 2. Encryption at rest

| Data | At rest | While the app is unlocked | While the profile runs |
|---|---|---|---|
| Profile list (names) | encrypted (`index.bin`) | in memory | in memory |
| Profile settings (proxy credentials and so on) | encrypted (`config.bin`) | decrypted only during launch and edit | in memory |
| Saved passwords | encrypted (`passwords.bin`) | decrypted on demand | in memory |
| WebKit website data | encrypted (`webdata.pbsa`) | encrypted | **plaintext on disk** in WebKit's directories |

**Why WebKit data is plaintext while a profile runs.** WebKit chooses the location of an
identifier-based data store itself and writes ordinary SQLite and LevelDB-style files
there. There is no public API to hand it a key, or to point the store at an encrypted
volume. `_WKWebsiteDataStoreConfiguration` can set directories, but it is private API.
The closest viable approach is to archive, encrypt and remove the data on stop, and
restore it on launch. `WebDataStoreVault` does this.

**Known gaps in that approach:**

1. *Directory discovery.* Apple doesn't document the layout. The vault searches the
   app's WebKit and Caches subtrees for directories named after the profile UUID; WebKit
   names them that way. If a future macOS stores per-identifier data somewhere else, that
   data won't be sealed. Check with:
   `find ~/Library -iname '<profile-uuid>' 2>/dev/null` while the profile is stopped.
   It should return nothing.
2. *No flush/close API.* WebKit tears a session down asynchronously after the last
   reference to its store is released. The vault waits, archives, then calls
   `WKWebsiteDataStore.remove(forIdentifier:)`, which fails while the store is still in
   use, and retries with backoff (1+2+3+5+8 s). A write that lands between the archive
   and the successful removal is lost. It is not leaked. If WebKit never releases the
   store, the app reports an error and the data stays in plaintext until the next stop
   or unlock.
3. *Crashes.* If the app crashes or is force-quit while a profile runs, the plaintext
   stays on disk until the next unlock, when `recoverUnsealedProfiles` seals it. Until
   then it is protected only by FileVault and the 0700 directory permissions.
4. *Deleted plaintext isn't securely erased.* APFS is copy-on-write on SSDs, so
   overwriting doesn't reliably erase data, and the code doesn't try. FileVault is the
   real protection for deleted blocks; enable it.
5. *Memory.* Swift and CryptoKit offer no guaranteed zeroisation. Keys of an unlocked
   vault live in process memory, and anyone who can read process memory (root, a
   debugger, a core dump) can recover them.

**KDF.** PBKDF2-HMAC-SHA256 with 600 000 iterations is the strongest password KDF in the
macOS SDK. A memory-hard KDF such as Argon2id would resist GPU attacks better; it can be
added behind `KDFParameters.algorithm` using libsodium without changing the file formats.

## 3. Network and proxy

**Native (enforced by WebKit for the data store):** `proxyConfigurations` covers HTTP(S),
WebSocket, fetch/XHR, media and service-worker loads of that store.
`allowFailover = false` makes it fail closed: if the proxy is down, loads fail instead of
going direct. Supported proxies are SOCKS5 and HTTP CONNECT, optionally TLS to the proxy,
with or without username/password, plus a per-profile bypass list.

**Not covered:**

| Path | Status | Mitigation |
|---|---|---|
| WebRTC UDP (STUN/TURN, media) | Never proxied; STUN reveals the real public IP | WebRTC policy (see §4); the default is **disabled** |
| DNS | With CONNECT or SOCKS5, the hostname goes to the proxy (remote resolution). WebKit's DNS *prefetch* of link hostnames may use the system resolver, and WKWebView has no public switch to turn prefetch off | Verify with `sudo tcpdump -n -i any port 53` while browsing through a proxy |
| Safe Browsing lookups | Made outside the data store's network session | Off by default (`safeBrowsingEnabled`) |
| `mailto:`, `tel:`, custom schemes | Would hand the URL to another app, outside the profile | Blocked by the navigation policy |
| Camera and microphone streams | Local capture; WebRTC transport isn't proxied | Asks the user every time |
| App's own sync traffic | Uses the system network | The folder transport makes no network requests |

**Verify the proxy:** set a SOCKS5 proxy, for example `ssh -D 1080 host`, open
`https://ifconfig.me`, and confirm it shows the proxy's IP. Then stop the proxy and
reload: the page must fail, not show your own IP.

## 4. WebRTC

WebKit offers no public preference to disable WebRTC or set an IP-handling policy. Its
default already hides local IPs behind mDNS host candidates, but STUN still discovers the
public IP over UDP, outside the proxy.

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

**Verify:** run `typeof RTCPeerConnection` in the console; it returns `"undefined"` when
disabled. A WebRTC leak test page should show no candidates (disabled) or only `relay`
candidates (relayOnly).

## 5. Time zone, geolocation, user agent

| Setting | Implementation | Native? | Gaps |
|---|---|---|---|
| User agent | `WKWebView.customUserAgent` | yes | `navigator.platform`, vendor, feature set and TLS fingerprint still identify WebKit on macOS. Claiming another engine makes the browser *more* distinctive. Use a Safari UA (optionally another version) |
| Time zone | JS: `Intl.DateTimeFormat` default `timeZone`, `Date` local getters, `getTimezoneOffset`, `toString`, `toDateString`, `toTimeString`, `toLocale*String` | no | Workers use the host zone. `new Date(y, m, d, …)`, local setters (`setHours` …) and `Date.parse` of strings without an offset use the host zone. Detectable. CSS and HTTP carry no time zone |
| Geolocation | JS: `navigator.geolocation` returns PERMISSION_DENIED, or fixed coordinates; `permissions.query({name:'geolocation'})` agrees | no | Detectable. The IP address (proxy) is what most sites actually use; pick a matching proxy. The app has no `NSLocationUsageDescription`, so CoreLocation can't be reached even if the shim is bypassed |
| Language | not implemented | — | WKWebView has no per-view `Accept-Language` / `navigator.languages` API |

The shim logic is tested under Node (`scripts/test-shims.mjs`) against ICU, across
fixed-offset zones, DST transitions and 30-minute shifts. That tests the logic, not
JavaScriptCore itself, so check in the browser too: in a profile with time zone
`Asia/Tokyo`, `new Date().getTimezoneOffset()` should be `-540`, and
`Intl.DateTimeFormat().resolvedOptions().timeZone` should be `"Asia/Tokyo"`.

## 6. Passwords

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

## 7. App Sandbox

The prototype runs with the hardened runtime and **without** App Sandbox, so `build-app.sh`
needs no provisioning. Sandboxing is possible: it needs the
`com.apple.security.network.client`, `device.camera`, `device.audio-input` and
`files.user-selected.read-write` entitlements (the last for the sync folder and
downloads). The code resolves all paths through `FileManager.urls(for:in:)`, so they move
into the container automatically, and `WebDataStoreVault` already searches the sandboxed
layout (`Library/WebKit/WebsiteDataStore/<uuid>`). This hasn't been tested.

## 8. Threat model summary

**Protects against:**

- Someone who gets a copy of the disk or a backup while the app is locked, or while the
  relevant profile is stopped. They see only ciphertext and `vault.json` (KDF parameters).
- Websites in one profile reading another profile's cookies or storage.
- Casual IP and location leaks: fail-closed proxy, WebRTC off, geolocation denied.
- A sync server learning profile names, settings, passwords or browsing data.

**Does not protect against:**

- Malware or root on the running machine (it can read memory and live plaintext).
- Device fingerprinting that links profiles through hardware or rendering
  characteristics.
- Offline guessing of a weak master password by anyone holding `vault.json`.
- A sync server rolling back to an older complete snapshot (no signed manifest).
