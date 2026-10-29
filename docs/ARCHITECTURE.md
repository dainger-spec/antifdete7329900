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
│  main.swift ── app, --self-test (headless WebKit checks), --capture-sites, migration modes  │
│  Localization (ru default, en fallback) · Theme (dark chrome; web content follows system)   │
│  BehaviorSets ── device-generation → injected-script bundle (extension point)               │
│  SwiftUI: Setup / Unlock / ProfileList / ProfileEditor / Passwords / SyncSettings / Library │
│        │                                                                                   │
│  AppModel ── lock state, vault, DeviceSettings (sync target), errors                       │
│        ├── ProxyListModel ── proxies.bin, checks (ProxyChecker → ProxyGeoLookup)           │
│        │                                                                                   │
│  ProfileManager ── launch / stop / delete / crash recovery                                 │
│        ├── TunnelManager ── packet tunnel: activation, VPN configuration, per-profile routes│
│        ├── WebDataStoreVault ── seal/unseal WebKit dirs (WebKitDataLayout + archive)       │
│        └── BrowserSession (one per running profile)                                        │
│              ├── WKWebsiteDataStore(forIdentifier:) + proxyConfigurations                  │
│              ├── WKUserContentController + PrivacyScripts (TZ / geo / WebRTC)              │
│              ├── ProfileLibrary ── HistoryStore + BookmarkStore (observable, debounced)    │
│              ├── LibraryWindowController ── bookmarks & history UI                         │
│              └── BrowserWindowController × n                                               │
│                    ├── TabStripView, BrowserChrome (profile chip, start page)              │
│                    └── BrowserTab × n ── WKWebView + navigation/UI/download delegates      │
└────────────────────────────────────────────────────────────────────────────────────────────┘
┌──────────────────────────────── BrowserCore (platform-independent) ────────────────────────┐
│  MasterVault / UnlockedVault ── Argon2id, key hierarchy; DeviceSettings (settings.bin)     │
│  ProfileRepository ── encrypted index + per-profile config, store factories                │
│  ProxyList / ProxyListImport ── proxy list, pasted-list reader, round-robin assignment     │
│  PasswordVault / HistoryStore / BookmarkStore ── per-profile encrypted documents           │
│  EncryptedChunkStream / EncryptedDirectoryArchive / WebKitDataLayout ── WebKit data seal   │
│  SyncCodec / SyncEngine ── encrypted sync client with per-record merges                    │
│  SyncTransport ── backend contract                                                         │
│     ├── LocalDirectorySyncTransport  (local-only)                                          │
│     └── HTTPSyncTransport            (server-ready client, docs/SYNC_SERVER_API.md)        │
└────────────────────────────────────────────────────────────────────────────────────────────┘
┌──────────── PacketTunnelExtension (system extension, NE=1 builds; docs/TUNNEL.md) ─────────┐
│  PacketTunnelProvider ── split tunnel (192.0.2.0/24 + a ULA /64), packets ↔ PacketRouter   │
│  TunnelTransport (macOS) ── SOCKS5UDPRelay (Network.framework), TURNUDPHost (CI harness)   │
│  TunnelCore (platform-independent) ── IPv4/IPv6 UDP packets, STUN/TURN codec, TURNServer,  │
│        SOCKS5 framing, PacketRouter (one TURN server per profile route), control messages  │
└────────────────────────────────────────────────────────────────────────────────────────────┘
```

`BrowserCore` has no dependency on AppKit or WebKit. It builds on Linux with
swift-crypto, which lets CI run the crypto and storage tests without a Mac. `TunnelCore`, the
tunnel's protocol code, builds there as well.

## Key hierarchy

```
master password
   │ Argon2id (RFC 9106): 64 MiB, 3 passes, 4 lanes, 16-byte random salt
   │ (vaults from before it: PBKDF2-HMAC-SHA256, 600 000 iterations, until their next unlock)
   ▼
KEK (key-encryption key, never stored)
   │ AES-256-GCM unwrap  (vault.json: wrappedMasterKey, AAD "vault-master-key:v1:<vaultID>")
   ▼
VMK (vault master key, random 256-bit)
   ├─ HKDF "profile-index"     → encrypts index.bin           (profile names, wrapped profile keys)
   ├─ HKDF "profile-key-wrap"  → wraps each profile key        (AAD "profile-key:v1:<uuid>")
   ├─ HKDF "sync-envelope"     → encrypts sync envelopes + sync-state.bin
   ├─ HKDF "sync-object-id"    → HMAC key for opaque sync object IDs
   ├─ HKDF "device-settings"   → settings.bin (sync target, token, last status; never synced)
   └─ HKDF "proxy-list"        → proxies.bin  (proxy list: settings, credentials, labels, last checks;
                                               AAD "proxy-list:v1:<vaultID>"; never synced)

profile key (random 256-bit per profile, stored only wrapped)
   ├─ directly                 → config.bin                    (AAD "profile-config:v1:<uuid>")
   ├─ HKDF "passwords"         → passwords.bin                 (AAD "passwords:v1:<uuid>")
   ├─ HKDF "history"           → history.bin                   (AAD "history:v1:<uuid>")
   ├─ HKDF "bookmarks"         → bookmarks.bin                 (AAD "bookmarks:v1:<uuid>")
   ├─ HKDF "cookie-import"     → cookies-import.bin            (AAD "cookie-import:v1:<uuid>")
   ├─ HKDF "cookies"           → cookies.bin                   (AAD "cookies:v1:<uuid>")
   ├─ HKDF "cookie-baseline"   → cookies-baseline.bin          (AAD "cookie-baseline:v1:<uuid>")
   ├─ HKDF "warm-up"           → warmup.bin                    (AAD "warm-up:v1:<uuid>")
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
  proxies.bin                     AES-GCM(proxy-list key, ProxyList JSON)             [after the first proxy is added; this Mac only]
  sync-state.bin                  AES-GCM(sync key, per-object revision + hash)        [only after sync]
  profiles/<uuid>/
    config.bin                    AES-GCM(profile key, ProfileConfiguration JSON)
    passwords.bin                 AES-GCM(password key, [PasswordEntry] JSON: origin, user name, password, note, dates)
    cookies-import.bin            AES-GCM(cookie-import key, [ImportedCookie] JSON)   [only while imported cookies wait for the next launch]
    cookies.bin                   AES-GCM(cookies key, CookieJarDocument JSON)        [persistent cookies, synced; with cookie sync on]
    cookies-baseline.bin          AES-GCM(cookie-baseline key, CookieBaseline JSON)   [this Mac only: the store at the last record or apply]
    warmup.bin                    AES-GCM(warm-up key, WarmUpPlan JSON)               [this Mac only: the last warm-up plan]
    config.bin.conflict, passwords.bin.conflict   the other device's version after a sync conflict (encrypted as the file)
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
(`ProfileLibrary`), and cookies imported while the profile was stopped (`cookies-import.bin`) go
into its cookie store before the first window opens (`CookieImporter` reads and checks export
files in BrowserCore; `CookieStoreImport` sets them, reads the store back to find refused ones,
and has the store write its cookies to disk). Stopping a profile also has its cookie store write
to disk before the data is sealed.

With cookie sync on (the profile's default), the store and the synced cookies (`cookies.bin`,
`CookieJarDocument`) meet at both ends of a run (`CookieStoreSync`, `ProfileManager`): at launch,
before the queued imports and the first window, the synced document — merged by sync with the
other devices' — is applied to the store, and the imported cookies are then recorded into it;
at stop, before the seal, what the run changed in the store since the launch (the local
`cookies-baseline.bin`) is recorded as changes of that time. Sync itself never touches a live
store: it runs only while no profile does. See SYNC_FORMAT.md § Cookies. History changes are saved encrypted after a 3 s debounce, off the main
thread; `BrowserSession.shutDown()` flushes them synchronously before the data store is
released.

## Password AutoFill

```
page frame (any origin)                     app (main thread)
┌──────────────────────────────┐   focus    ┌─────────────────────────────────────────────┐
│ world "PrivacyBrowser.       │──────────▶ │ PasswordAutoFillHandler (session)            │
│  Passwords" (isolated):      │   submit   │   origin = frameInfo.securityOrigin          │
│  PasswordAutoFillScript      │──────────▶ │   → BrowserTab.passwords (TabPasswordAutoFill)│
│  · typed-field tracking      │  username  │      · candidates: PasswordMatching (site)   │
│  · submit / click / Return   │──────────▶ │      · AutoFillPanel under the field         │
│  · fill(token, field, …)  ◀──┼────────────│      · Save / Update / Never sheet            │
└──────────────────────────────┘ callAsync  │      · PasswordVault, ProfilePasswordSettings │
page world: no window.webkit,    JavaScript └─────────────────────────────────────────────┘
no access to the script
```

- The script and its message handler live in their own `WKContentWorld` (with AutoFill
  scripting where WebKit offers it: `:autofill` marking and the key button), registered only
  there, so the page world is what a plain WKWebView's (and Safari's) is.
- A frame's origin always comes from WebKit (`WKScriptMessage.frameInfo.securityOrigin`);
  logins are offered and filled by `PasswordMatching` (registrable domain via the Public Suffix
  List, same port, never an https login on an http page). The script checks the document token
  and `location.origin` again before it writes a value.
- A save is offered only for a password field that received trusted user input; the question
  is a sheet on the window (`BrowserTab.presentAlert`, answered "Not Now" when the tab closes).
  A form navigation (`WKNavigationType.formSubmitted`) is held for at most 0.3 s while the
  script reads the typed password (for `form.submit()`, which fires no `submit` event).
- "Never for This Website" and the on/off switch are in `ProfileConfiguration`
  (`passwordNeverSaveSites`, `passwordAutoFill`), read afresh for each decision, so edits apply
  to a running profile.

Quitting with profiles running seals them all before the process exits (`QuitCoordinator`):
the first `terminate:` is cancelled, windows close and profiles seal in the normal run loop,
and `terminate:` is sent again once nothing is left. Sealing inside `terminate:`
(`.terminateLater`) failed on ⌘Q: WebKit re-sends an unhandled key equivalent while it retains
the web view, so the profile's data store stayed in use for as long as `terminate:` waited.
Only a logout, restart or shutdown still waits inside `terminate:` (cancelling it would cancel
the logout). If WebKit still holds a store after every attempt, the quit forces the seal and
leaves a `webdata.forced` marker so that whatever WebKit writes before the exit is discarded at
the next launch or unlock instead of being taken for newer data.

## Session warm-up

```
WarmUpView (sheet) ── AppModel.startWarmUp: save plan (warmup.bin), launch the profile if stopped
        │
        ▼
ProfileManager.warmUpRobot(for:) ── one WarmUpRobot per profile; stop(id) stops it first
        │  start(plan, in: session): a new selected tab in the front window
        ▼
WarmUpRobot (main actor, one Task per run; tab and session held weakly)
   for each WarmUpPlan page (BrowserCore: pages(), WarmUpTiming, WarmUpLinkPolicy):
     wait until its tab is shown → tab.load(url) → wait for that navigation (committed, ended,
       or a jump within the page asked for) with nothing loading; failedNavigations
     → stay WarmUpTiming.dwell: wheel gestures (native NSEvent from CGEvent, else scrollBy)
     → follow one allowed link (mouse events once a trusted move reached it, else click())
     → pause
   reads pages only in WKContentWorld "PrivacyBrowser.WarmUp" (callAsyncJavaScript)
```

The robot never replaces the tab's delegates (they authenticate the proxy, record history and
handle downloads); it watches the tab instead, and sets the tab's `refusesDownloads` for the run
(a response the tab would save fails as a load). Its writes to a visit check that the run is
still the current one, and its scripts end at once on Stop, so a run stopped mid-await never
touches the next run's state. It ends itself when its tab's `host` is gone, the
session's data store is gone, or the tab has a dialog waiting. ISOLATION_AND_LIMITATIONS.md §8c.

## Proxy list and several profiles at once

```
ProxyListView (sheet, ⋯ → Proxies…) ── ProxyListModel (AppModel.proxyList, made at unlock, dropped at lock)
   │  Import…   ProxyImportView: ProxyListImport.read(text) → report per line → ProxyList.add (dedupe, limit)
   │  Check     ProxyChecker.checkAll: ≤ 8 at a time, each ProxyGeoLookup.lookUp through the proxy
   │            (ProxyConfigurationFactory, allowFailover = false) → ProxyCheckResult → ProxyList.record
   │  Assign…   ProxyAssignView: ProxyList.rotation(of: proxies, over: profiles) → AppModel.assignProxies
   │            → ProfileRepository.assign → ProfileConfiguration.assigning (savingEdit of the proxy alone)
   └─ every change saved at once (proxies.bin); check results when the run ends or is stopped

ProfilesScreen ── ProfileSelection (click / ⌘-click / ⇧-click) ── ProfileBulkBar (2 or more selected)
   └─ ProfileActions.launchSeveral / stopSeveral / warmUpSeveral (hook) / assignProxies / deleteSeveral
```

- The list (`ProxyList`, BrowserCore) is a vault-level document like `settings.bin`, under its own
  HKDF key; entries that a later build wrote and this one cannot read are left out rather than
  costing the whole list, and an unreadable list is shown empty and never written over.
- A check is the launch's lookup (`ProxyGeoLookup`), so it goes through exactly the configuration a
  profile's data store would get. It is alive when a service's answer came back through the proxy,
  dead otherwise (no answer, or a 407 without credentials); a proxy whose settings cannot be applied
  is not checked at all. Results carry the exit IP, country, time zone and latency (the first
  answering request: connection to the proxy, tunnel, TLS and reply).
- Assigning writes each profile's configuration as the editor would change its proxy alone: the
  newer-wins time for sync moves only when the proxy changes; the location found through the old
  proxy goes (it is about another proxy), and the check's location of the new one is remembered,
  its exit IP only while the profile asks to be warned of changes. Rotation is round-robin in list
  order. Running profiles get their new proxy at their next launch.
- The Profiles list's selection lives in the screen (`ProfileSelection`): a plain click selects one
  row, ⌘-click toggles, ⇧-click extends in display order; rows the filter or search hides are never
  acted on. Warm-up of several profiles goes through `ProfileActions.warmUpSeveral`, which today
  opens the warm-up of the first: the hook a warm-up queue takes.

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
- This is version *labelling* (self-declared UA + defaults), not core switching. Public APIs
  cannot load a different WebKit build; see ISOLATION_AND_LIMITATIONS §2.

## Testing

| Layer | How | Where it runs |
|---|---|---|
| Core (crypto, vault, profiles, archive, layout, history, bookmarks, passwords, cookie import, sync incl. cookies and settings conflicts, warm-up plans and link rules, HTTP transport, UA presets, proxy location, proxy list: pasted-list reader, storage, rotation and assignment) | XCTest, 155 tests | Linux (swift-crypto) and macOS (CryptoKit), every push |
| Tunnel protocols (STUN/TURN against RFC 5769 vectors, IPv4/IPv6 UDP packets, SOCKS5 framing, TURN flows as libwebrtc drives them, peer policy, several profiles through one router) | XCTest, 32 tests | Linux and macOS, every push |
| Packet-tunnel extension | builds against the macOS SDK and is laid out as a system extension, plists linted, provider class checked (`NE=check scripts/build-app.sh`); it cannot be loaded on a CI runner. Its router runs on a raw utun interface opened as root (`--utun-relay`, `UTunDevice`) against real WebKit, inside the leak check | macOS 26 runner, every push |
| JS shims (logic, CreepJS-style shape checks) | `scripts/test-shims.mjs` under Node (V8 + ICU) and under Bun (JavaScriptCore, Safari's engine: own-property order, error messages) | Linux, every push |
| App against real WebKit, sandboxed and unsandboxed | `PrivacyBrowser --self-test` with `scripts/selftest_proxy.py` | macOS 26 runner, every push |
| Measured surface of a macOS profile vs. the runner's real Safari | `scripts/safari_reference.py` (safaridriver) with `Resources/fingerprint_probe.js` | macOS 26 runner, every push |
| The same pages in Safari and in on-screen profile windows of the same size: probe, window geometry (1 and 2 tabs), request header order, permissions/quota/devices, TLS + HTTP/2 (tls.peet.ws) | `scripts/live_compare.py` + `PrivacyBrowser --capture-sites` (`SiteCapture.swift`, pages in `scripts/live_sites/`) | macOS 26 runner, every push (report only: third-party sites change) |
| Nothing goes around a profile's proxy: QUIC/HTTP/3 (cloudflare-quic.com) and WebRTC (public STUN) behind real HTTP CONNECT and SOCKS5 forwarding proxies, a profile without a proxy as the control; WebRTC through the tunnel's TURN server and SOCKS5 relay (run on a UDP socket of the runner) to a proxy with UDP ASSOCIATE: relay candidates at the proxy's address, a data channel delivered through it, no relay address shown to the page | `scripts/leak_check.py` + `--capture-sites` | macOS 26 runner, every push (fails on a request seen going around a proxy, or the relay's address shown to a page) |
| App Sandbox container migration | `--selftest-write-vault` / `--selftest-read-vault` | macOS 26 runner, every push |
| Interactive UI (tab strip drawing, menus, sheets) | manual | — |

## Window lifecycle

- Closing a profile's last browser window → `BrowserSession.onAllWindowsClosed` →
  `ProfileManager` brings the Profiles window forward (`AppModel.activateProfilesWindow`) and
  stops and seals the profile in the background.
- `windowWillClose` never drops the last reference to its own controller synchronously. The
  session callback is posted to the next main run-loop turn, because releasing an
  `NSWindow` while AppKit is still closing it is a use-after-free (the earlier crash on close
  and quit).
- `BrowserSession.shutDown()` is idempotent, and a second ⌘Q while sealing joins the quit
  under way (`QuitCoordinator`). `applicationShouldTerminateAfterLastWindowClosed` returns
  `false`. Browser windows are not restorable, so AppKit never writes their titles (the
  profile names) to Saved Application State.

## Concurrency

- UI, `ProfileManager`, `BrowserSession`, window controllers and `WebDataStoreVault` are
  `@MainActor`. That matches WebKit's main-thread requirement.
- Key derivation (Argon2id) and archive I/O run on detached tasks, so the UI stays responsive.
- `ProfileRepository` and `PasswordVault` serialise mutations with a lock. While a profile
  runs (and from the moment its launch opened the vault), the manager hands out that
  session's `PasswordVault` instance, so each file has only one writer. The vault posts
  `didChangeNotification` after a write, so the password manager shows what the browser saved.
