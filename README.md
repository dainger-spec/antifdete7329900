# PrivacyBrowser — multi-profile WebKit browser prototype for macOS

A Swift/SwiftUI + AppKit browser that runs several isolated profiles at once on the
system WebKit engine (`WKWebView`). Each profile has its own website data store, proxy,
user agent, time zone, geolocation and WebRTC policy. Profile metadata, settings and
passwords are encrypted at rest with a key derived from a master password, and each
profile's WebKit data is decrypted only while that profile is running.

This is a prototype: the security-critical core is tested, but the app has not had a
security review, and parts of it are approximations limited by what WebKit exposes. The
tables below say which parts are which.

- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md): components, key hierarchy, on-disk layout, lifecycles
- [docs/ISOLATION_AND_LIMITATIONS.md](docs/ISOLATION_AND_LIMITATIONS.md): what is isolated, what leaks, how to verify it
- [docs/SYNC_FORMAT.md](docs/SYNC_FORMAT.md): sync wire format and backend contract

## Requirements

- macOS 14 Sonoma or later. Two APIs the design depends on were added in macOS 14:
  `WKWebsiteDataStore(forIdentifier:)` (persistent per-profile stores) and
  `WKWebsiteDataStore.proxyConfigurations` (per-profile proxies).
- Xcode 15 or later, or the matching Command Line Tools (Swift 5.9+).

## Build and run

```bash
# Build an ad-hoc-signed .app bundle into ./build
scripts/build-app.sh
open build/PrivacyBrowser.app

# Optional: your own bundle ID / signing identity
BUNDLE_ID=org.example.PrivacyBrowser SIGN_IDENTITY="Developer ID Application: …" scripts/build-app.sh
```

Run the app from the `.app` bundle. WebKit names its storage directories after the
bundle identifier, and a stable identifier keeps them in a predictable place.
`swift run PrivacyBrowser` works for quick UI checks, but WebKit then falls back to the
process name.

To work in Xcode, run `open Package.swift`, select the `PrivacyBrowser` scheme, and run it.

Tests:

```bash
swift test                                        # core: crypto, vault, profiles, archive, sync
TZ=America/New_York node scripts/test-shims.mjs   # JS shims (needs Node 18+)
```

The core (`BrowserCore`) also builds and tests on Linux, using swift-crypto in place of
CryptoKit. CI (`.github/workflows/ci.yml`) runs the core tests on Linux and macOS, runs
the shim tests, and builds the `.app` on a macOS runner.

To keep data out of your real vault while developing, set
`PRIVACYBROWSER_VAULT_DIR=/tmp/pb-dev` in the scheme's environment.

## Using it

1. On first launch, create a master password. It cannot be recovered.
2. Use **＋** to create a profile and set its start URL, proxy, user agent, time zone,
   geolocation, WebRTC policy, and whether it is ephemeral.
3. **Launch** opens a window for the profile. Profiles can run side by side; each window
   shows its profile's name in the title and the toolbar.
4. **Stop**, or closing the profile's last window, encrypts its website data and removes
   the plaintext. **Lock** stops every profile and forgets all keys. Quitting does the same.
5. Passwords: 🔑 fills a saved login on the current page, and the save button stores what
   you typed into the page. Saved passwords also answer HTTP Basic/Digest auth. You can
   manage them under **⋯ → Passwords…**.
6. Sync (optional): **More → Sync with Folder…** syncs encrypted blobs with a folder.
   Stop all profiles first.

Settings changes apply the next time the profile launches.

## What is implemented and how

### Fully implemented with native or system APIs

| Feature | How |
|---|---|
| Per-profile storage isolation (cookies, localStorage, IndexedDB, Cache API, service workers, HTTP cache, HSTS, credentials) | `WKWebsiteDataStore(forIdentifier: profileUUID)`; every web view and popup of a profile uses that store |
| Ephemeral profiles | `WKWebsiteDataStore.nonPersistent()` |
| Several profiles running at once | One `BrowserSession` (data store + windows) per running profile |
| Create / edit / delete / launch / stop profiles | `ProfileRepository` (core) + `ProfileManager` (app) |
| Per-profile proxy (SOCKS5, HTTP CONNECT, HTTPS-to-proxy, auth, bypass list) | `WKWebsiteDataStore.proxyConfigurations` with Network.framework `ProxyConfiguration`, `allowFailover = false` (fail-closed) |
| Per-profile user agent | `WKWebView.customUserAgent` (HTTP header and `navigator.userAgent`) |
| Encrypted profile metadata and settings | AES-256-GCM, keys derived from the master password via PBKDF2-HMAC-SHA256 (600k iterations) and HKDF |
| Password storage encrypted with a key derived from the user's password | Per-profile vault, HKDF(profile key), which is reachable only through the master password |
| Master password change without re-encrypting data | Only the wrapped vault key is re-encrypted |
| Encrypted sync client: data format, codec, engine, and a folder-based transport | `SyncEnvelope` / `SyncCodec` / `SyncEngine` / `LocalDirectorySyncTransport` |
| Safe Browsing off by default (its lookups bypass the proxy) | `WKPreferences.isFraudulentWebsiteWarningEnabled` |
| Non-web URL schemes blocked (they would leave the profile) | Navigation policy |

### Approximated (the platform offers no native API)

| Feature | How | Main gaps |
|---|---|---|
| WebKit data encrypted while a profile is not running | On stop: archive and encrypt WebKit's directories, then `WKWebsiteDataStore.remove(forIdentifier:)`. On launch: decrypt and restore | Plaintext on disk while the profile runs; a crash leaves plaintext until the next unlock; the directory layout is undocumented (found by UUID name); there is no "flush" API, so a write in the last moments before removal can be lost |
| Time zone | JS shim: `Intl` default zone, `Date` getters, `getTimezoneOffset`, `toString` and `toLocale*String` | Not applied in workers; local-component `Date` constructors, setters and `Date.parse` use the host zone; detectable |
| Geolocation | JS shim: deny, or fixed coordinates; `permissions.query` matches | Detectable; the IP address still reveals approximate location unless the proxy matches |
| WebRTC leak reduction | JS shim: remove `RTCPeerConnection` (default), or force `iceTransportPolicy: "relay"` | WebKit has no public switch to disable WebRTC; WebRTC UDP never uses the proxy; frames reached via `window.frames[i]` may be unpatched |
| Password autofill | Explicit fill/save buttons that run in an isolated JS content world | No automatic form detection; main frame only; WKWebView has no AutoFill integration |

### Not implemented

- Sync backend server (only the interface and the folder transport), and syncing of the
  WebKit data archives.
- Changing hardware/rendering characteristics (canvas, WebGL, fonts, screen, audio). All
  profiles share the host's values.
- Per-profile `Accept-Language` / `navigator.language`. WKWebView has no public API for it.
- Tabs, history UI, bookmarks, extensions, and content blocking (`WKContentRuleList`
  would be the native route).
- App Sandbox. See the limitations doc.

## Project layout

```
Package.swift
Sources/
  BrowserCore/                 platform-independent, unit-tested
    Crypto/                    AEAD (AES-GCM), PBKDF2, HKDF helpers
    Vault/MasterVault.swift    master password → vault key; key hierarchy
    Profiles/                  ProfileConfiguration, ProfileRepository (encrypted index/config)
    Passwords/                 PasswordVault
    Archive/                   streaming encrypted chunk format + directory archiver
    Sync/                      envelope/codec, transport protocol + folder transport, engine
    Support/                   errors, atomic 0600 file writes
  PrivacyBrowser/              macOS app (SwiftUI + AppKit + WebKit)
    App/                       @main app, AppModel (lock state), AppDelegate (seal on quit)
    Browser/                   ProfileManager, BrowserSession, BrowserWindowController,
                               WebDataStoreVault, ProxyConfigurationFactory, PrivacyScripts
    UI/                        setup/unlock, profile list, editor, passwords
Tests/BrowserCoreTests/        XCTest suite for the core
Resources/                     Info.plist template, entitlements
scripts/                       build-app.sh, test-shims.mjs
docs/                          architecture, isolation and limitations, sync format
```
