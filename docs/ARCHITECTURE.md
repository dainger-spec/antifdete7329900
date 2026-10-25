# Architecture

## Engine choice

The browser is built on **WKWebView (system WebKit)**, not Chromium or Electron:

- macOS 14 added the two APIs a multi-profile browser needs: persistent, separately
  identified data stores (`WKWebsiteDataStore(forIdentifier:)`) and per-store proxies
  (`WKWebsiteDataStore.proxyConfigurations`).
- Electron is Chromium-based, so "Electron + WKWebView" isn't a real combination.
  Embedding Chromium (CEF) would give finer engine control, such as Chromium's
  `--force-webrtc-ip-handling-policy` flag, at the cost of shipping and patching a second
  engine. Where WebKit's public API falls short, this project documents the gap and uses
  the closest viable workaround instead of using private API.

No private WebKit API is used. Places where private API would help (custom data store
directories, disabling WebRTC at engine level) are noted in comments and in
[ISOLATION_AND_LIMITATIONS.md](ISOLATION_AND_LIMITATIONS.md).

## Components

```
┌──────────────────────────────── PrivacyBrowser (macOS app) ────────────────────────────────┐
│  main.swift ── app, or --self-test (headless WebKit checks) / migration check modes         │
│  Localization (ru default, en fallback) · Theme (forced light appearance)                   │
│  BehaviorSets ── device-generation → injected-script bundle (extension point)               │
│  SwiftUI: Setup / Unlock / ProfileList / ProfileEditor / Passwords / SyncSettings / Library │
│        │                                                                                   │
│  AppModel ── lock state, vault, DeviceSettings (sync target), errors                       │
│        │                                                                                   │
│  ProfileManager ── launch / stop / delete / crash recovery                                 │
│        ├── WebDataStoreVault ── seal/unseal WebKit dirs (WebKitDataLayout + archive)       │
│        └── BrowserSession (one per running profile)                                        │
│              ├── WKWebsiteDataStore(forIdentifier:) + proxyConfigurations                  │
│              ├── WKUserContentController + PrivacyScripts (TZ / geo / WebRTC)              │
│              ├── ProfileLibrary ── HistoryStore + BookmarkStore (observable, debounced)    │
│              ├── LibraryWindowController ── bookmarks & history UI                         │
│              └── BrowserWindowController × n                                               │
│                    ├── TabStripView                                                        │
│                    └── BrowserTab × n ── WKWebView + navigation/UI/download delegates      │
└────────────────────────────────────────────────────────────────────────────────────────────┘
┌──────────────────────────────── BrowserCore (platform-independent) ────────────────────────┐
│  MasterVault / UnlockedVault ── PBKDF2, key hierarchy;  DeviceSettings (settings.bin)      │
│  ProfileRepository ── encrypted index + per-profile config, store factories                │
│  PasswordVault / HistoryStore / BookmarkStore ── per-profile encrypted documents           │
│  EncryptedChunkStream / EncryptedDirectoryArchive / WebKitDataLayout ── WebKit data seal   │
│  SyncCodec / SyncEngine ── encrypted sync client with per-record merges                    │
│  SyncTransport ── backend contract                                                         │
│     ├── LocalDirectorySyncTransport  (local-only)                                          │
│     └── HTTPSyncTransport            (server-ready client, docs/SYNC_SERVER_API.md)        │
└────────────────────────────────────────────────────────────────────────────────────────────┘
```

`BrowserCore` has no dependency on AppKit or WebKit. It builds on Linux with
swift-crypto, which lets CI run the crypto and storage tests without a Mac.

## Key hierarchy

```
master password
   │ PBKDF2-HMAC-SHA256, 600 000 iterations, 16-byte random salt
   ▼
KEK (key-encryption key, never stored)
   │ AES-256-GCM unwrap  (vault.json: wrappedMasterKey, AAD "vault-master-key:v1:<vaultID>")
   ▼
VMK (vault master key, random 256-bit)
   ├─ HKDF "profile-index"     → encrypts index.bin           (profile names, wrapped profile keys)
   ├─ HKDF "profile-key-wrap"  → wraps each profile key        (AAD "profile-key:v1:<uuid>")
   ├─ HKDF "sync-envelope"     → encrypts sync envelopes + sync-state.bin
   ├─ HKDF "sync-object-id"    → HMAC key for opaque sync object IDs
   └─ HKDF "device-settings"   → settings.bin (sync target, token, last status; never synced)

profile key (random 256-bit per profile, stored only wrapped)
   ├─ directly                 → config.bin                    (AAD "profile-config:v1:<uuid>")
   ├─ HKDF "passwords"         → passwords.bin                 (AAD "passwords:v1:<uuid>")
   ├─ HKDF "history"           → history.bin                   (AAD "history:v1:<uuid>")
   ├─ HKDF "bookmarks"         → bookmarks.bin                 (AAD "bookmarks:v1:<uuid>")
   └─ HKDF "webdata-archive", salt = random per archive → webdata.pbsa chunk key
```

All HKDF derivations use the vault ID (or profile ID) as salt. Every ciphertext's AAD
names its purpose and owner, so moving a ciphertext into another file or profile makes
decryption fail.

Changing the master password re-wraps only the VMK. A new device unlocks with the same
password because `vault.json` (salt, KDF parameters and wrapped VMK) is synced in
plaintext.

## On-disk layout

All paths are relative to the app's Library directory: `~/Library` for the unsandboxed
build, `~/Library/Containers/<bundle-id>/Data/Library` for the sandboxed (default) build.

```
Application Support/PrivacyBrowser/      (0700)
  vault.json                      plaintext: format, vaultID, KDF params, wrapped VMK
  index.bin                       AES-GCM(index key, ProfileIndex JSON)
  settings.bin                    AES-GCM(device-settings key, DeviceSettings JSON)   [after configuring sync]
  sync-state.bin                  AES-GCM(sync key, per-object revision + hash)        [only after sync]
  profiles/<uuid>/
    config.bin                    AES-GCM(profile key, ProfileConfiguration JSON)
    passwords.bin                 AES-GCM(password key, [PasswordEntry] JSON)
    history.bin                   AES-GCM(history key, HistoryDocument JSON)          [not for ephemeral profiles]
    bookmarks.bin                 AES-GCM(bookmarks key, BookmarkDocument JSON)
    webdata.pbsa                  streaming encrypted archive of WebKit's data dirs

WebKit/<bundle-id>/WebsiteDataStore/<uuid>/   unsandboxed  ┐ WebKit-owned plaintext; exists only
WebKit/WebsiteDataStore/<uuid>/               sandboxed    ┘ while the profile runs (observed layout)
```

Every file is written with mode 0600 through a temp file and `rename(2)`, so a crash
never leaves a half-written ciphertext.

### `webdata.pbsa` format

```
header  = "PBSA" | version u8 | chunkSize u32 | salt[32]
chunk*  = len u32 | ciphertext | tag[16]
key     = HKDF-SHA256(profileKey, salt, "webdata-archive")
nonce_i = 0x00000000 || u64(i)            AAD_i = header || u64(i) || final u8
```

The plaintext is a record stream (`kind | path | mode | [size | bytes]`). Files are
streamed in 1 MiB chunks, so memory use stays bounded. Readers reject truncation, data
after the final chunk, reordered chunks, unsafe paths (`..`, absolute, NUL) and symlinks.
Extraction goes to a staging directory, and nothing reaches its destination until the
whole archive has authenticated.

## Profile lifecycle

```
            ┌────────────── unlock (master password) ──────────────┐
            │ index decrypted → names visible; configs still sealed │
            └───────────────────────────┬───────────────────────────┘
                                        │ crash recovery: any WebKit dir named <uuid>
                                        │ of a non-running profile is sealed now
              launch                    ▼                     stop / last window closed / lock / quit
  ┌───────────────────────────────────────────┐      ┌──────────────────────────────────────────────┐
  │ unwrap profile key                        │      │ close windows, tear down web views           │
  │ decrypt config.bin, open PasswordVault    │      │ drop WKWebsiteDataStore reference            │
  │ unseal webdata.pbsa → WebKit dirs         │ ───▶ │ wait → archive+encrypt dirs → webdata.pbsa   │
  │ WKWebsiteDataStore(forIdentifier: uuid)   │      │ WKWebsiteDataStore.remove(forIdentifier:)    │
  │   .proxyConfigurations = [proxy]          │      │   (fails while in use → retry with backoff)  │
  │ user scripts (TZ / geo / WebRTC)          │      │ sweep leftovers, drop profile key            │
  │ window → start URL                        │      └──────────────────────────────────────────────┘
  └───────────────────────────────────────────┘
```

Ephemeral profiles skip the seal/unseal steps because `nonPersistent()` stores write
nothing to disk; their history is memory-only.

At launch the profile key also opens the password vault, the history and the bookmarks
(`ProfileLibrary`). History changes are saved encrypted after a 3 s debounce, off the main
thread; `BrowserSession.shutDown()` flushes them synchronously before the data store is
released.

The app delays termination (`applicationShouldTerminate` → `.terminateLater`) until
every running profile is sealed.

## Tabs

`BrowserWindowController` owns the tab model (`[BrowserTab]`, selected index, recently closed
URLs) and a custom `TabStripView`. AppKit window tabbing is disabled, because it would let
windows be merged and needs one `NSWindow` per tab.

- `BrowserTab` owns one `WKWebView` and is its navigation, UI and download delegate. It talks
  to its window through the `BrowserTabHost` protocol: state changes, new-tab requests,
  close requests, attention for dialogs.
- The selected tab's web view is the only one in the view hierarchy; others stay alive
  off-screen.
- `window.open` / `target=_blank` become tabs created from the configuration WebKit supplies.
  ⌘-click and middle-click open background tabs with the profile's standard configuration.
- ⌘W closes the tab: `BrowserWindow.performClose` intercepts menu-initiated closes. The
  window's close button still closes the window. Shortcuts: ⌘T, ⇧⌘T, ⌃⇥ / ⌃⇧⇥, ⌘1–⌘9, ⌘L,
  ⌘D, ⌘Y, ⌥⌘B.
- History is recorded at `didCommit` and for same-document navigations, once WebKit has
  made the URL the current back/forward item. Titles arrive later via KVO.

## Version-aware generations

A profile targets an Apple OS generation (`DeviceGeneration` / `DeviceGenerations` in
`BrowserCore`), stored as `ProfileConfiguration.deviceGenerationID` (tolerant decode; old
configs read as the default generation).

- `ProfileConfiguration.effectiveUserAgent` = explicit `userAgent` override, else the
  generation's UA, else the WebKit default. `BrowserSession` applies it to every tab and
  routes the injected scripts through `BehaviorSets` keyed by the generation's `behaviorSetID`.
- `BehaviorSets` (app layer) is the extension point for future WebKit versions: today all
  generations map to the current `PrivacyScripts` shims. Adding a new behaviour set and a new
  generation that points at it needs no change to the profile format or call sites.
- iOS/iPadOS generations may carry a `deviceModelID` (`DeviceModels`: screen geometry, touch
  points, core count). `ProfileConfiguration.deviceModel` resolves it only when the model's
  platform matches the generation, so a stale id from a switched generation is ignored.
  `PrivacyScripts.shimConfiguration` turns the generation + model into the `isIOS`/`device`
  part of the shim config; macOS generations produce no device shim.
- This is version *labelling* (self-declared UA, defaults, declared device values), not core
  switching. Public APIs cannot load a different WebKit build; see ISOLATION_AND_LIMITATIONS §2.

## Testing

| Layer | How | Where it runs |
|---|---|---|
| Core (crypto, vault, profiles, archive, layout, history, bookmarks, sync, HTTP transport, UA presets) | XCTest, 36 tests | Linux (swift-crypto) and macOS (CryptoKit), every push |
| JS shims (logic) | Node + ICU (`scripts/test-shims.mjs`) | Linux, every push |
| App against real WebKit, sandboxed and unsandboxed | `PrivacyBrowser --self-test` with `scripts/selftest_proxy.py` | macOS 15 runner, every push |
| App Sandbox container migration | `--selftest-write-vault` / `--selftest-read-vault` | macOS 15 runner, every push |
| Interactive UI (tab strip drawing, menus, sheets) | manual | — |

## Window lifecycle

- Closing a profile's last browser window → `BrowserSession.onAllWindowsClosed` →
  `ProfileManager` brings the Profiles window forward (`AppModel.activateProfilesWindow`) and
  stops and seals the profile in the background.
- `windowWillClose` never drops the last reference to its own controller synchronously. The
  session callback is posted to the next main run-loop turn, because releasing an
  `NSWindow` while AppKit is still closing it is a use-after-free (the earlier crash on close
  and quit).
- `BrowserSession.shutDown()` is idempotent, and `applicationShouldTerminate` ignores a second
  ⌘Q while sealing is in progress. `applicationShouldTerminateAfterLastWindowClosed`
  returns `false`.

## Concurrency

- UI, `ProfileManager`, `BrowserSession`, window controllers and `WebDataStoreVault` are
  `@MainActor`. That matches WebKit's main-thread requirement.
- PBKDF2 and archive I/O run on detached tasks, so the UI stays responsive.
- `ProfileRepository` and `PasswordVault` serialise mutations with a lock. While a profile
  runs, the manager hands out that session's `PasswordVault` instance, so each file has
  only one writer.
