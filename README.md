# PrivacyBrowser — multi-profile WebKit browser prototype for macOS

A Swift/SwiftUI + AppKit browser that runs several isolated profiles at once on the
system WebKit engine (`WKWebView`), with tabs, per-profile history and bookmarks, and the
App Sandbox enabled. Each profile has its own website data store, proxy, user agent, time
zone, geolocation and WebRTC policy. Everything the app stores is encrypted at rest with
a key derived from a master password. That covers profile list, settings, passwords,
history, bookmarks and sync settings. A profile's WebKit website data is decrypted only
while that profile is running.

The UI is in **Russian by default** (English fallback) and uses a clean **light theme**.

This is a prototype. The core has unit tests, and the app is checked end-to-end against
real WebKit in CI. It has not had a security review, and some features are
approximations limited by what WebKit exposes. The tables below say which parts are which.

**Fingerprint note (2026-10-26):** no canvas, WebGL, audio or font noise — noise is exactly what fingerprinting tests detect. macOS profiles override no navigator or screen value and declare this Mac's real Safari version; iPhone/iPad profiles only get their device class's navigator/screen values. A profile with a proxy runs in the time zone of the proxy's exit IP (also in workers created from a blob), and the first profile launched sets the language websites see (otherwise this Mac's languages, as in Safari). The window reports Safari's geometry (real outer size, 52/90 px of chrome), user-installed fonts are hidden and the storage quota is Safari's. CI measures a profile against the runner's real Safari, page by page, including TLS/HTTP2 and header order: what still differs is Apple Pay/Web Push (Safari-only) and the profile's own privacy choices ([§2](docs/ISOLATION_AND_LIMITATIONS.md#measured-against-this-macs-safari)). deviceinfo.me's "Canvas: Spoofed" / "Fingerprinting Resistance: Detected" appear in real Safari 26 as well (its PNG-length list predates this WebKit). iOS fidelity remains UA-level (TLS, GPU, fonts, touch are the Mac's).

- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md): components, key hierarchy, on-disk layout, lifecycles, tabs, testing
- [docs/ISOLATION_AND_LIMITATIONS.md](docs/ISOLATION_AND_LIMITATIONS.md): what is isolated, what leaks, fingerprinting, App Sandbox, verified results
- [docs/SYNC_FORMAT.md](docs/SYNC_FORMAT.md): sync wire format, merge rules, what is server-ready vs. local-only
- [docs/SYNC_SERVER_API.md](docs/SYNC_SERVER_API.md): HTTP contract for a future sync server

## Requirements

- macOS 14 Sonoma or later. The design depends on two APIs added in macOS 14:
  `WKWebsiteDataStore(forIdentifier:)` and `WKWebsiteDataStore.proxyConfigurations`.
- Xcode 15 or later, or the matching Command Line Tools (Swift 5.9+).

## Build and run

```bash
scripts/build-app.sh                  # sandboxed release build → build/PrivacyBrowser.app
open build/PrivacyBrowser.app

SANDBOX=0 scripts/build-app.sh        # hardened runtime without App Sandbox (debugging)
APP_DIR=build/other scripts/build-app.sh
BUNDLE_ID=org.example.PrivacyBrowser SIGN_IDENTITY="Developer ID Application: …" scripts/build-app.sh
```

- The default build is **sandboxed**. Its data lives in
  `~/Library/Containers/<bundle-id>/Data/`. `build-app.sh` checks the signature and fails if
  the sandbox entitlement doesn't match `SANDBOX`.
- **Upgrading from an earlier unsandboxed build:** on the sandboxed build's first launch,
  macOS moves `~/Library/Application Support/PrivacyBrowser` into the container
  (`container-migration.plist`). The move is one-way. Archives sealed by the old build
  restore at the sandboxed locations. Quit the old build normally first, so every profile
  is sealed.
- Ad-hoc signing (the default) is enough to run locally. To distribute, sign with a
  Developer ID and notarize.
- Run the `.app`, not `swift run`. WebKit names its storage directories after the bundle
  identifier, and the sandbox needs a signed bundle. For Xcode, run `open Package.swift`
  and select the `PrivacyBrowser` scheme. That scheme runs unsandboxed.
- `PRIVACYBROWSER_VAULT_DIR=/path` uses a different vault, for development. In the sandbox
  the path must be inside the container.
- **Language:** the UI starts in Russian. `PRIVACYBROWSER_LANG=en` switches it to English.
  The strings tables (`Resources/{ru,en}.lproj`) are copied into the bundle by
  `build-app.sh`, so `swift run` and the Xcode SwiftPM scheme show raw keys instead.
- **Appearance:** the app always uses the light (Aqua) appearance, whatever the system
  setting.

### Tests

```bash
swift test                                        # core tests (also run on Linux in CI)
TZ=America/New_York node scripts/test-shims.mjs   # JS shim logic and CreepJS-style shape checks (Node 18+)
TZ=America/New_York bun scripts/test-shims.mjs    # the same under JavaScriptCore, Safari's engine

# End-to-end against the real WebKit of this Mac (headless, temporary vault, cleans up):
python3 scripts/selftest_proxy.py --http 18080 --socks 18081 --http-auth 18082 --http6 18083 &
PB_SELFTEST_HTTP_PROXY_PORT=18080 PB_SELFTEST_SOCKS_PROXY_PORT=18081 \
PB_SELFTEST_HTTP_AUTH_PROXY_PORT=18082 PB_SELFTEST_HTTP6_PROXY_PORT=18083 \
PB_SELFTEST_SURFACE_OUT=build/surface \
  build/PrivacyBrowser.app/Contents/MacOS/PrivacyBrowser --self-test

# What a page measures in a macOS profile vs. this Mac's real Safari (needs `sudo safaridriver --enable` once):
python3 scripts/safari_reference.py --compare build/surface/surface-macos.json
# The same pages in Safari and in on-screen profile windows: geometry, headers, APIs, TLS/HTTP2 (unsandboxed build):
python3 scripts/live_compare.py --app build/unsandboxed/PrivacyBrowser.app --out build/live
# Does QUIC or WebRTC go around a profile's proxy? (forwarding proxies on this Mac; unsandboxed build):
python3 scripts/leak_check.py --app build/unsandboxed/PrivacyBrowser.app --out build/leaks
```

CI (`.github/workflows/ci.yml`) runs on every push:
- the core tests on Linux and macOS, and the shim tests;
- `--self-test` for both the sandboxed and the unsandboxed build: 128 checks, covering WebKit
  data location, seal/restore of cookies, localStorage and IndexedDB, live isolation between
  profiles, shims under JavaScriptCore, the fingerprint surface against a plain WKWebView,
  HTTP CONNECT (IPv4 and IPv6), SOCKS5 and authenticated proxies, fail-closed, the
  ping-load blocker, the proxy-location time zone, tabs, history, bookmarks, the
  device-generation UA path, crash-recovery sealing, dialogs, Lock during launch, ⌘Q and
  the forced seal, and the window-lifecycle regression;
- the surface comparison with the runner's real Safari (`scripts/safari_reference.py`): every
  key that measures the engine or the Mac is identical; what differs is the set of features
  Safari alone enables (listed in `docs/ISOLATION_AND_LIMITATIONS.md` §2);
- the live comparison (`scripts/live_compare.py`, report only): the same pages in Safari and in
  profile windows of the same size — window geometry with one and two tabs, request header order,
  permission states and storage quota, TLS/JA3/JA4 and HTTP/2 via tls.peet.ws;
- the leak check (`scripts/leak_check.py`): profiles behind real forwarding proxies on the
  runner, and one without a proxy as the control. QUIC/HTTP/3 stays on the proxy (HTTP/2 through
  it, HTTP/3 without it); WebRTC is off in proxied profiles. Fails on any request seen going
  around a proxy;
- a container-migration check.

## Using it

1. On first launch, create a master password. It cannot be recovered.
2. Use **＋** to create a profile and set its device/version, start URL, proxy, user agent,
   time zone, geolocation, WebRTC policy, history recording and retention, and whether it is
   ephemeral. Changes apply at the next launch. The **Device / version** picker tags the
   profile with a target Apple OS version (macOS 26, iOS 26/27, iPadOS 26); iOS profiles also
   get their device class's navigator/screen values (see note above).
3. **Launch** opens a window for the profile. Profiles run side by side, and every window
   and tab is labelled with its profile. Closing a profile's last window stops that profile
   and returns you to the Profiles window; the app stays open.
4. **Tabs:**
   - ⌘T opens a new tab, ⌘W closes one, ⇧⌘T reopens the last closed tab.
   - ⌃⇥ and ⌃⇧⇥ move between tabs, ⌘1–⌘9 jump to one.
   - ⌘-click or middle-click opens a link in a background tab. Popups open as tabs.
5. **Bookmarks and history:**
   - ☆ or ⌘D bookmarks the page (click again to remove).
   - The 📖 menu opens bookmarks.
   - ⌘Y opens the Library window: searchable history grouped by day, with Clear (last hour,
     today, all), and bookmark management (add, edit, folders, drag to reorder, delete).
6. **Passwords:** 🔑 fills a saved login and the save button stores what you typed. Saved
   passwords also answer HTTP Basic/Digest. Manage them under **⋯ → Passwords…**.
7. **Stop**, or closing the last window, saves history and encrypts the profile's website
   data. **Lock** stops every profile and forgets the keys. Quitting (⌘Q) does the same,
   and waits until every profile is sealed.
8. **Sync (optional):** **More → Sync…** offers a folder (local-only) or a server (client
   for the documented API; no server is included). Stop all profiles before syncing.

## What is implemented, and how

### Fully implemented with native or system APIs

| Feature | How |
|---|---|
| Per-profile storage isolation (cookies, localStorage, IndexedDB, Cache API, service workers, HTTP cache, HSTS, credentials) | `WKWebsiteDataStore(forIdentifier: profileUUID)`, shared by every tab and popup of the profile. **Verified live by the self-test** |
| Ephemeral profiles | `WKWebsiteDataStore.nonPersistent()`; history kept in memory only |
| Several profiles running at once | One `BrowserSession` per running profile |
| Multi-tab windows | `BrowserTab` (one `WKWebView` each) + custom `TabStripView`; popups and ⌘-click open tabs; standard shortcuts |
| Per-profile history | Encrypted `HistoryStore`: coalesced per URL, search, clear ranges, retention, cap; records committed and same-document navigations; credentials and fragments stripped |
| Per-profile bookmarks | Encrypted `BookmarkStore`: folders, ordering, edit; star toggle, bookmarks menu, Library window |
| Per-profile proxy (SOCKS5, HTTP CONNECT, HTTPS-to-proxy, auth, bypass list) | `WKWebsiteDataStore.proxyConfigurations`, `allowFailover = false`. **CONNECT tunnelling, SOCKS5 remote DNS and fail-closed verified by the self-test** |
| Version-aware profiles | **Device / version** picker (`DeviceGeneration`): macOS 26 / iOS 26 / iOS 27 / iPadOS 26. Sets the self-declared `User-Agent` and defaults, and names a behaviour set. The macOS UA names the host's Safari version; iOS profiles additionally get navigator/screen values. Does **not** switch the real WebKit core. |
| Per-profile user agent | `WKWebView.customUserAgent` (an explicit UA overrides the generation) |
| Russian / English UI | `Localizable.strings` (ru default, en fallback), deterministic bundle lookup |
| Stable window lifecycle | closing a profile window never quits or crashes the app (use-after-free fixed); verified by the self-test |
| Encryption at rest of everything the app writes | AES-256-GCM; Argon2id (64 MiB, t=3, p=4; older PBKDF2 vaults upgraded on unlock) → vault key → HKDF per purpose |
| Password storage under a key derived from the user's password | Per-profile vault; explicit fill/save; HTTP auth |
| App Sandbox | Default build; entitlements in `Resources/PrivacyBrowser.entitlements` (documented in the limitations doc, §9); container migration. **Sandbox enforcement and migration verified in CI** |
| Encrypted sync client | Engine with CAS writes, per-record merges for bookmarks and history, tombstones; folder transport; HTTP transport for a documented API |

### Approximated (the platform offers no native API)

| Feature | How | Main gaps |
|---|---|---|
| WebKit data encrypted while a profile is not running | Archive, encrypt, then `remove(forIdentifier:)` on stop; restore on launch. Directories found by UUID (`WebKitDataLayout`), layout checked in CI | Plaintext on disk while the profile runs; a crash leaves plaintext until the next unlock; no "flush" API (last-moment writes can be lost, not leaked) |
| Time zone | JS shim (`Intl`, `Date` getters, offsets, string forms, local constructors, setters, `Date.parse`), also in workers created from a blob; by default the proxy's exit-IP zone, looked up through the proxy at launch | Workers loaded from a URL and service workers keep the host zone; the lookup is a third-party request |
| Geolocation | JS shim: deny (default) or fixed coordinates | Detectable; the IP address reveals location unless the proxy matches |
| WebRTC leak reduction | Off in the engine (default, and always with a proxy) via a private `WKPreferences` property, JS removal as the fallback; or a JS shim forcing relay-only | WebKit never sends WebRTC through a proxy, so a proxied profile has none; relay-only shows the TURN server this Mac's IP |
| Navigator / screen (iPhone/iPad profiles) | Document-start JS getters on the prototypes (blob workers too) | URL-loaded workers keep the Mac's values; GPU/TLS/fonts/canvas still the Mac's |
| Website language (`Accept-Language`, `navigator.language`) | Set once per app run, before WebKit starts, from the first launched profile's proxy country | WebKit has one language list per process: later profiles share it |
| Password autofill | Explicit buttons in an isolated JS world | No automatic form detection; main frame only |

### Not implemented / limited

- True engine-level iOS WebKit (private APIs or bundled core required). TLS ClientHello, real GPU renderer, full font set, touch behavior remain Mac.
- Per-profile `Accept-Language` header (JS navigator.language is spoofed).
- Sync server (only the client and its API spec), syncing of WebKit website data, and
  per-entry merging of passwords (concurrent edits keep the remote version plus a
  `.conflict` copy).
- Session restore, tab drag-and-drop between windows, find-in-page, extensions, and
  content blocking (`WKContentRuleList` would be the native route).

## Project layout

```
Package.swift
Sources/
  BrowserCore/                     platform-independent, unit-tested (macOS + Linux)
    Crypto/                        AEAD (AES-GCM), Argon2id + BLAKE2b, PBKDF2, HKDF helpers
    Vault/                         MasterVault (key hierarchy), DeviceSettings
    Profiles/                      ProfileConfiguration, ProfileRepository
    Passwords/                     PasswordVault
    Library/                       HistoryStore, BookmarkStore (mergeable, tombstones)
    Archive/                       encrypted chunk stream, directory archiver, WebKitDataLayout
    Sync/                          envelope/codec, engine, SyncTransport contract
      Transports/                  LocalDirectorySyncTransport (local-only), HTTPSyncTransport (server-ready)
    Support/                       errors, atomic 0600 writes, encrypted document files
  PrivacyBrowser/                  macOS app (SwiftUI + AppKit + WebKit)
    App/                           main.swift, PrivacyBrowserApp, AppModel, AppEnvironment, SelfTest, SiteCapture
    Browser/                       ProfileManager, BrowserSession, BrowserWindowController, BrowserTab,
                                   TabStripView, ProfileLibrary, LibraryWindowController, PasswordAutofill,
                                   WebDataStoreVault, ProxyConfigurationFactory, PrivacyScripts
    UI/                            setup/unlock, profile list, editor, library, sync settings
Tests/BrowserCoreTests/            XCTest suite (incl. stub sync server)
Resources/                         Info.plist, entitlements (sandboxed / not), container-migration.plist
scripts/                           build-app.sh, test-shims.mjs, selftest_proxy.py, safari_reference.py,
                                   live_compare.py + live_sites/ (pages measured in Safari and in profiles),
                                   leak_check.py (QUIC/WebRTC around a proxy)
docs/                              architecture, isolation and limitations, sync format, sync server API
```
