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

**About the iOS/iPadOS profiles:** they are labelling, not emulation. The generation sets an
iPhone/iPad User-Agent and a JavaScript *device shim* that changes the values a page *reads*
(`navigator.platform`, touch points, screen geometry, a canvas read-back, the WebGL vendor
strings). Everything the engine and hardware *measure* — GPU output, fonts, touch events,
codecs, TLS — is still this Mac, and the shim itself is detectable. macOS profiles get no
shim at all. Details and the exact list in
[docs/ISOLATION_AND_LIMITATIONS.md §2](docs/ISOLATION_AND_LIMITATIONS.md).

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
swift test                                        # core: 36 tests (also run on Linux in CI)
TZ=America/New_York node scripts/test-shims.mjs   # JS shim logic (Node 18+)

# End-to-end against the real WebKit of this Mac (headless, temporary vault, cleans up):
python3 scripts/selftest_proxy.py --http 18080 --socks 18081 &
PB_SELFTEST_HTTP_PROXY_PORT=18080 PB_SELFTEST_SOCKS_PROXY_PORT=18081 \
  build/PrivacyBrowser.app/Contents/MacOS/PrivacyBrowser --self-test
```

CI (`.github/workflows/ci.yml`) runs on every push:
- the core tests on Linux and macOS, and the shim tests;
- `--self-test` for both the sandboxed and the unsandboxed build: 54 checks, covering WebKit
  data location, seal/restore of cookies, localStorage and IndexedDB, live isolation between
  profiles, shims under JavaScriptCore, HTTP CONNECT and SOCKS5 proxies, fail-closed, tabs,
  history, bookmarks, the device-generation UA path, crash-recovery sealing, and the
  window-lifecycle (close/quit crash) regression;
- a container-migration check.

## Using it

1. On first launch, create a master password. It cannot be recovered.
2. Use **＋** to create a profile and set its device/version, start URL, proxy, user agent,
   time zone, geolocation, WebRTC policy, history recording and retention, and whether it is
   ephemeral. Changes apply at the next launch. The **Device / version** picker tags the
   profile with a target Apple OS version (macOS 26, iOS 26/27, iPadOS 26). iOS/iPadOS
   generations can also pick a **Device model** (iPhone 15/16/16 Pro/SE, iPad Pro 11"/Air),
   which drives the device shim's declared screen and hardware values (see the note above).
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
| Version-aware profiles | **Device / version** picker (`DeviceGeneration`) + **Device model** (`DeviceModel`): macOS 26 / iOS 26 / iOS 27 / iPadOS 26. Sets the self-declared `User-Agent` and defaults, names a behaviour set; iOS/iPadOS generations add the JS device shim (declared values only). Does **not** switch the real WebKit core; macOS profiles stay fully native |
| Per-profile user agent | `WKWebView.customUserAgent` (an explicit UA overrides the generation) |
| Russian / English UI | `Localizable.strings` (ru default, en fallback), deterministic bundle lookup |
| Stable window lifecycle | closing a profile window never quits or crashes the app (use-after-free fixed); verified by the self-test |
| Encryption at rest of everything the app writes | AES-256-GCM; PBKDF2-HMAC-SHA256 (600k) → vault key → HKDF per purpose |
| Password storage under a key derived from the user's password | Per-profile vault; explicit fill/save; HTTP auth |
| App Sandbox | Default build; entitlements in `Resources/PrivacyBrowser.entitlements` (documented in the limitations doc, §9); container migration. **Sandbox enforcement and migration verified in CI** |
| Encrypted sync client | Engine with CAS writes, per-record merges for bookmarks and history, tombstones; folder transport; HTTP transport for a documented API |

### Approximated (the platform offers no native API)

| Feature | How | Main gaps |
|---|---|---|
| WebKit data encrypted while a profile is not running | Archive, encrypt, then `remove(forIdentifier:)` on stop; restore on launch. Directories found by UUID (`WebKitDataLayout`), layout checked in CI | Plaintext on disk while the profile runs; a crash leaves plaintext until the next unlock; no "flush" API (last-moment writes can be lost, not leaked) |
| Time zone | JS shim (`Intl`, `Date` getters, offsets, string forms) | Not in workers; local-component constructors, setters and `Date.parse` use the host zone; detectable |
| Geolocation | JS shim: deny (default) or fixed coordinates | Detectable; the IP address reveals location unless the proxy matches |
| WebRTC leak reduction | JS shim: remove `RTCPeerConnection` (default) or force relay-only | No engine switch; WebRTC UDP never uses the proxy; `window.frames[i]` gap |
| Declared device (iOS/iPadOS profiles) | JS device shim: `navigator.platform`/`maxTouchPoints`/`hardwareConcurrency`, `screen`, `devicePixelRatio`, `ontouchstart`, per-profile canvas `getImageData` noise, WebGL vendor/renderer strings | Not in workers; detectable (`toDataURL` vs `getImageData`, viewport vs screen); GPU, fonts, touch, codecs, TLS still Mac; no `deviceMemory`/`connection`/`languages` on purpose |
| Password autofill | Explicit buttons in an isolated JS world | No automatic form detection; main frame only |

### Not implemented / limited

- **Device emulation:** no engine-level iOS WebKit (would need private APIs or a bundled core).
  Rendered canvas/WebGL pixels, audio, fonts, touch behaviour, codecs and the TLS fingerprint
  are the host Mac's in every profile; two profiles of this app share them and can be linked.
  See §2 of the limitations doc for exactly what the iOS device shim does and doesn't change.
- Per-profile `Accept-Language` / `navigator.language` (no WKWebView API; deliberately not
  half-spoofed in JS).
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
    Crypto/                        AEAD (AES-GCM), PBKDF2, HKDF helpers
    Vault/                         MasterVault (key hierarchy), DeviceSettings
    Profiles/                      ProfileConfiguration, ProfileRepository
    Passwords/                     PasswordVault
    Library/                       HistoryStore, BookmarkStore (mergeable, tombstones)
    Archive/                       encrypted chunk stream, directory archiver, WebKitDataLayout
    Sync/                          envelope/codec, engine, SyncTransport contract
      Transports/                  LocalDirectorySyncTransport (local-only), HTTPSyncTransport (server-ready)
    Support/                       errors, atomic 0600 writes, encrypted document files
  PrivacyBrowser/                  macOS app (SwiftUI + AppKit + WebKit)
    App/                           main.swift, PrivacyBrowserApp, AppModel, AppEnvironment, SelfTest
    Browser/                       ProfileManager, BrowserSession, BrowserWindowController, BrowserTab,
                                   TabStripView, ProfileLibrary, LibraryWindowController, PasswordAutofill,
                                   WebDataStoreVault, ProxyConfigurationFactory, PrivacyScripts
    UI/                            setup/unlock, profile list, editor, library, sync settings
Tests/BrowserCoreTests/            XCTest suite (incl. stub sync server)
Resources/                         Info.plist, entitlements (sandboxed / not), container-migration.plist
scripts/                           build-app.sh, test-shims.mjs, selftest_proxy.py
docs/                              architecture, isolation and limitations, sync format, sync server API
```
