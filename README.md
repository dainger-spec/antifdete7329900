# PrivacyBrowser — multi-profile WebKit browser prototype for macOS

A Swift/SwiftUI + AppKit browser that runs several isolated profiles at once on the
system WebKit engine (`WKWebView`), with tabs, per-profile history and bookmarks, and the
App Sandbox enabled. Each profile has its own website data store, proxy, user agent, time
zone, geolocation and WebRTC policy. Everything the app stores is encrypted at rest with
a key derived from a master password. That covers profile list, settings, passwords,
history, bookmarks and sync settings. A profile's WebKit website data is decrypted only
while that profile is running.

The UI is in **Russian by default** (English fallback) and uses Lumen's **dark theme**: flat
near-black surfaces, hairline borders, one restrained blue accent. A browser window shows its
profile as a chip in the toolbar (glyph, name, and the flag of the country its proxy exits in),
and an empty tab shows a native start page with the profile's favourites and recent pages.
Web pages are not themed; they follow the Mac's light/dark setting as they do in Safari.

This is a prototype. The core has unit tests, and the app is checked end-to-end against
real WebKit in CI. It has not had a security review, and some features are
approximations limited by what WebKit exposes. The tables below say which parts are which.

**Fingerprint note (2026-10-26):** no canvas, WebGL, audio or font noise — noise is exactly what fingerprinting tests detect. macOS profiles override no navigator or screen value and declare this Mac's real Safari version; iPhone/iPad profiles only get their device class's navigator/screen values. A profile with a proxy runs in the time zone of the proxy's exit IP — set in the engine through a WebKit process pool of the profile's own where WebKit allows it (every worker included), otherwise by a shim (workers created from a blob too) — and the first profile launched sets the language websites see (otherwise this Mac's languages, as in Safari). The window reports Safari's geometry (real outer size, 52/90 px of chrome; background tabs too), user-installed fonts are hidden and the storage quota is Safari's (in WebKit itself for saved profiles, every worker included). CI measures a profile against the runner's real Safari, page by page, including TLS/HTTP2 and header order: what still differs is Apple Pay/Web Push (Safari-only) and the profile's own privacy choices ([§2](docs/ISOLATION_AND_LIMITATIONS.md#measured-against-this-macs-safari)). deviceinfo.me's "Canvas: Spoofed" / "Fingerprinting Resistance: Detected" appear in real Safari 26 as well (its PNG-length list predates this WebKit). iOS fidelity remains UA-level (TLS, GPU, fonts, touch are the Mac's).

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
- **Appearance:** the app's own windows are always dark (Lumen's theme). Web content follows
  the system's light/dark setting, as in Safari, so pages see the `prefers-color-scheme`
  Safari would give them.
- **Design review:** `PrivacyBrowser --render-ui-snapshots <folder>` renders the screens with
  sample data into PNG files (CI uploads them as the `ui-snapshots` artifact).
- **App icon:** `build-app.sh` has the app draw its icon from the Lumen mark
  (`--render-app-icon <folder>.iconset`) and packs it with `iconutil` into
  `Contents/Resources/AppIcon.icns`. A bare `swift run` sets the same icon in the Dock at launch.

### Tests

```bash
swift test                                        # core tests (also run on Linux in CI)
TZ=America/New_York node scripts/test-shims.mjs   # JS shim logic and CreepJS-style shape checks (Node 18+)
TZ=America/New_York bun scripts/test-shims.mjs    # the same under JavaScriptCore, Safari's engine
TZ=America/New_York SHIM_FORM=worker node scripts/test-shims.mjs   # on the one-line form a blob worker gets

# End-to-end against the real WebKit of this Mac (headless, temporary vault, cleans up):
python3 scripts/selftest_proxy.py --http 18080 --socks 18081 --http-auth 18082 --http6 18083 \
  --socks2 18084 --socks-auth 18085 &
PB_SELFTEST_HTTP_PROXY_PORT=18080 PB_SELFTEST_SOCKS_PROXY_PORT=18081 \
PB_SELFTEST_HTTP_AUTH_PROXY_PORT=18082 PB_SELFTEST_HTTP6_PROXY_PORT=18083 \
PB_SELFTEST_SOCKS2_PROXY_PORT=18084 PB_SELFTEST_SOCKS_AUTH_PROXY_PORT=18085 \
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
- `--self-test` for both the sandboxed and the unsandboxed build: 215 checks, covering WebKit
  data location, seal/restore of cookies, localStorage and IndexedDB, live isolation between
  profiles, shims under JavaScriptCore, the fingerprint surface against a plain WKWebView,
  HTTP CONNECT (IPv4 and IPv6), SOCKS5 and authenticated proxies, fail-closed, three SOCKS5
  profiles launched and loading at once, the ping-load blocker, the proxy-location time zone,
  launches that wait only briefly on the lookup through the proxy, the exit-IP warning, password
  AutoFill (save, update, never, suggestions and fill, sign-in by script, sign-up, frames of
  another and of the same site, nothing for a password a page script wrote), cookie import
  (a damaged Netscape file, queued for a stopped profile and applied before its first page,
  a cut-off JSON into a running one, persistence across stop and launch), profile sync between
  two vaults (cookies recorded at stop and launch, applied before the first page on the other
  device, a change and a deletion coming back, settings newer-wins with a conflict copy), the
  session warm-up robot (pages in order through the proxy with the profile's cookies and
  User-Agent, time on each page measured at the proxy, scrolling, only the safe link followed,
  nothing in the page world while it acts, Stop, tab closed, a page dialog, the profile stopped
  mid-run), tabs, history,
  bookmarks, background tabs that measure their window as the shown tab does, the time zone in
  the engine where WebKit has the override (two profiles in different zones at once, in the page,
  frames and every kind of worker), Safari's storage quota in a saved profile's store (the page,
  every kind of worker), blob workers under a strict CSP and under Trusted Types (no violation
  report beyond the page's own), the device-generation UA path, crash-recovery sealing, dialogs, Lock during launch, ⌘Q and
  the forced seal, and the window-lifecycle regression;
- the surface comparison with the runner's real Safari (`scripts/safari_reference.py`): every
  key that measures the engine or the Mac is identical; what differs is the set of features
  Safari alone enables (listed in `docs/ISOLATION_AND_LIMITATIONS.md` §2);
- the live comparison (`scripts/live_compare.py`, report only): the same pages in Safari and in
  profile windows of the same size — window geometry with one and two tabs, request header order,
  permission states and storage quota, TLS/JA3/JA4 and HTTP/2 via tls.peet.ws;
- the leak check (`scripts/leak_check.py`): profiles behind real forwarding proxies on the
  runner, and one without a proxy as the control. QUIC/HTTP/3 stays on the proxy (HTTP/2 through
  it, HTTP/3 without it); WebRTC is off in proxied profiles without the tunnel. Through the
  tunnel's relay (run on the runner, since CI cannot load the extension), a page gets relay
  candidates at the proxy's address only, and a data channel through the proxy. Fails on any
  request seen going around a proxy;
- a container-migration check.

## Using it

1. On first launch, create a master password. It cannot be recovered.
2. Use **＋** to create a profile and set its device/version, start URL, proxy (optionally
   with a warning when the proxy's exit IP changes between launches), user agent, time zone,
   geolocation, WebRTC policy, history recording and retention, and whether it is ephemeral.
   Changes apply at the next launch. The **Device / version** picker tags the
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
6. **Passwords** (as Safari's AutoFill, per profile):
   - After you sign in, the window asks **Save Password / Not Now / Never for This Website**
     (or **Update Password** for a new password of a saved user name).
   - Clicking into a login field lists the site's saved logins under it; ↓/↑ and Return or a
     click fill one. Nothing is filled before you choose. 🔑 in the toolbar lists them too.
   - HTTP Basic/Digest sign-ins can be remembered (**Remember this password**) and are answered
     from the vault afterwards.
   - **⋯ → Passwords…** (master password first) shows, edits, adds and deletes saved passwords,
     and the websites they are never saved for. **⋯ → Edit…** → **AutoFill user names and passwords**
     turns it off for a profile.
7. **Cookies:** **⋯ → Import Cookies…** reads a JSON or Netscape `cookies.txt` export, shows
   what can be imported and why the rest cannot (with line numbers), then imports into that
   profile: at once when it runs, otherwise when it next starts.
8. **Warm-up:** **⋯ → Warm Up…** takes web addresses (one per line) and an optional search,
   starts the profile if it is stopped, and visits the pages one after the other in a tab of
   it: a random time on each page, scrolling, and if asked one plain link followed. **Stop**
   in the sheet, closing the robot's tab or stopping the profile ends it.
9. **Stop**, or closing the last window, saves history and encrypts the profile's website
   data. **Lock** stops every profile and forgets the keys. Quitting (⌘Q) does the same,
   and waits until every profile is sealed.
10. **Sync (optional):** **More → Sync…** offers a folder (local-only) or a server (client
   for the documented API; no server is included). Stop all profiles before syncing. A
   profile's settings, passwords, bookmarks, history and persistent cookies sync, encrypted;
   another Mac gets the cookies at its next launch of the profile, before the first page
   (**⋯ → Edit…** → **Sync cookies with other devices** turns that off for a profile).

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
| Per-profile proxy (SOCKS5, HTTP CONNECT, HTTPS-to-proxy, auth, bypass list) | `WKWebsiteDataStore.proxyConfigurations`, `allowFailover = false`. **CONNECT tunnelling, SOCKS5 remote DNS, SOCKS5 and HTTP proxy authentication, and fail-closed verified by the self-test** |
| Several proxied profiles at once | Each profile's data store has its own proxy and credentials. **Three SOCKS5 profiles (one with authentication) launched together and loading at once, each through its own proxy, verified by the self-test** |
| Fast launch with a proxy | The lookup through the proxy (time zone, exit IP) holds a launch at most 1 s when a location is remembered for that proxy (the lookup finishes in the background), at most 3 s with nothing remembered. **Verified by the self-test** |
| Proxy exit-IP warning | Per profile, off by default: a warning when the proxy's exit IP differs from the previous launch's (same proxy and credentials); the IP is stored only while the option is on |
| Version-aware profiles | **Device / version** picker (`DeviceGeneration`): macOS 26 / iOS 26 / iOS 27 / iPadOS 26. Sets the self-declared `User-Agent` and defaults, and names a behaviour set. The macOS UA names the host's Safari version; iOS profiles additionally get navigator/screen values. Does **not** switch the real WebKit core. |
| Per-profile user agent | `WKWebView.customUserAgent` (an explicit UA overrides the generation) |
| Russian / English UI | `Localizable.strings` (ru default, en fallback), deterministic bundle lookup |
| Stable window lifecycle | closing a profile window never quits or crashes the app (use-after-free fixed); verified by the self-test |
| Encryption at rest of everything the app writes | AES-256-GCM; Argon2id (64 MiB, t=3, p=4; older PBKDF2 vaults upgraded on unlock) → vault key → HKDF per purpose |
| Password storage under a key derived from the user's password | Per-profile vault (`passwords.bin`, AES-GCM under a key derived from the profile key); the manager asks for the master password before it shows anything |
| Password AutoFill, Safari's behaviour | Save / Update / Never after a sign-in the user typed; suggestions under login fields of the site (registrable domain, Public Suffix List), filled only on choice, with `input` and `change` as Safari; two-step sign-ins, sign-ins by script, sign-up forms; no https login on an http page; never into hidden fields or a frame of another site. **Checked by the self-test** in a profile window (save, update, never, suggestions and fill, sign-in by script, sign-up, frames); on the CI runner, where synthesized key events do not reach the page, typing is stood in for by marking the fields typed inside the isolated world |
| Cookie import into a profile | **⋯ → Import Cookies…**: JSON (EditThisCookie, Cookie-Editor, Puppeteer/DevTools, Playwright, Selenium, Chrome and Firefox database exports, JSON Lines) and Netscape `cookies.txt`. Damaged files import whatever is readable (bad bytes, a broken or cut-off JSON entry or a malformed line cost only that cookie); the report lists every other entry with its line and reason (public-suffix domain, expired, `__Host-` rules, …). A running profile gets them at once (and the store is read back for any WebKit refused), a stopped one at its next launch before the first page loads (queued encrypted). **Checked by the self-test** end to end through the proxy |
| App Sandbox | Default build; entitlements in `Resources/PrivacyBrowser.entitlements` (documented in the limitations doc, §9); container migration. **Sandbox enforcement and migration verified in CI** |
| Encrypted sync client | Engine with CAS writes, per-record merges for bookmarks and history, tombstones; folder transport; HTTP transport for a documented API |
| Session warm-up ("cookie robot") | **⋯ → Warm Up…**: the pages of a list (and a search first, if given) visited one after the other in a tab of the profile — its proxy, cookies, User-Agent and scripts, as when browsing — with a random time on each page (5–15 s by default), trackpad-like scrolling, and optionally one plain link followed (same site; from the search, a result; never sign-out, purchase, deletion, download or new-window links). Waits while its tab is not shown; stops on Stop, when its tab closes, when a page shows a dialog and when the profile stops. Scrolls with real wheel events while its window is key, otherwise from an isolated script world; clicks with real pointer events when they reach the link, otherwise with an (untrusted) script click — on the CI runner pointer events did not reach pages, so clicks there were script clicks; nothing is added to the page world, and nothing is downloaded. **Checked by the self-test** through the proxy (order, cookies and User-Agent on the requests, Referer of the followed link, links refused, the stop cases, sealing after a stop mid-run) |
| Profile sync: cookies and settings | A profile's persistent cookies sync as `cookies.bin` (encrypted with the profile key), merged cookie by cookie — the newer change wins, deletions included; recorded when the profile stops, applied at its next launch before the first page loads, imported cookies joining at that launch. Settings changed on two Macs: the newer edit wins, the other kept as `config.bin.conflict`. Session and partitioned cookies, and ephemeral profiles, never sync ([docs/SYNC_FORMAT.md](docs/SYNC_FORMAT.md)). **Checked by the self-test** with a second vault set up from the sync folder, and by unit tests |

### Approximated (the platform offers no native API)

| Feature | How | Main gaps |
|---|---|---|
| WebKit data encrypted while a profile is not running | Archive, encrypt, then `remove(forIdentifier:)` on stop; restore on launch. Directories found by UUID (`WebKitDataLayout`), layout checked in CI | Plaintext on disk while the profile runs; a crash leaves plaintext until the next unlock; no "flush" API (last-moment writes can be lost, not leaked) |
| Time zone | In the engine where WebKit allows it: the profile's own process pool with WebKit's time zone override (SPI) — the page, frames and every worker (from a URL, shared, service) report the zone as the engine's own. Otherwise a JS shim (`Intl`, `Date` getters, offsets, string forms, local constructors, setters, `Date.parse`), also in workers created from a blob. By default the proxy's exit-IP zone, looked up through the proxy at launch | Private API, used only where present; with the shim, workers loaded from a URL and service workers keep the host zone; the lookup is a third-party request |
| Geolocation | Deny (default): WebKit's own denial and permission state, answered by the tab's UI delegate (private API, where present). Fixed coordinates: JS shim | Fixed coordinates are detectable; the IP address reveals location unless the proxy matches |
| WebRTC leak reduction | Off in the engine (default) via a private `WKPreferences` property, JS removal as the fallback; or a JS shim forcing relay-only | Relay-only shows the TURN server this Mac's IP |
| WebRTC through a profile's SOCKS5 proxy | Packet-tunnel system extension (`NE=1` builds): a TURN relay per profile on a virtual address, relaying through the proxy's UDP ASSOCIATE; several profiles with different proxies at once; IPv4 and IPv6 ([docs/TUNNEL.md](docs/TUNNEL.md)). Without it, or with an HTTP proxy, WebRTC is off in proxied profiles, with a warning | Needs a paid Apple Developer team and user approval; the extension itself has not run on a real Mac yet (CI cannot load it); relay-only is enforced by the page script, not the engine; starting it disconnects another VPN app's tunnel; relay candidates only; the proxy must relay UDP |
| Navigator / screen (iPhone/iPad profiles) | Document-start JS getters on the prototypes (blob workers too) | URL-loaded workers keep the Mac's values; GPU/TLS/fonts/canvas still the Mac's |
| Website language (`Accept-Language`, `navigator.language`) | Set once per app run, before WebKit starts, from the first launched profile's proxy country | WebKit has one language list per process: later profiles share it |
| Password AutoFill | A user script in its own content world (invisible to pages; no `window.webkit` in the page world), a native suggestion list and Safari's save questions | WKWebView on macOS 26 has no AutoFill API: sign-ins are recognised by heuristics (a submitted form, or the fields leaving after a click), filled values fire untrusted `input`/`change` events, and `:autofill` (Safari's highlight) and WebKit's key button need a WebKit with AutoFill scripting; no strong-password suggestions or Touch ID; passwords are per profile (Safari profiles share them) |

### Not implemented / limited

- True engine-level iOS WebKit (private APIs or bundled core required). TLS ClientHello, real GPU renderer, full font set, touch behavior remain Mac.
- Per-profile `Accept-Language` header (JS navigator.language is spoofed).
- Sync server (only the client and its API spec), syncing of WebKit website data other than
  cookies (localStorage, IndexedDB, caches), and per-entry merging of passwords (concurrent
  edits keep the remote version plus a `.conflict` copy). Synced data reaches a running profile
  only at its next launch.
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
    Passwords/                     PasswordVault, PasswordMatching (site rules), PublicSuffixList
    Cookies/                       CookieImporter (JSON and Netscape readers, checks, report), CookieJar (synced cookies, merge)
    WarmUp/                        WarmUpPlan (pages, timing, which links), WebAddress (typed text → address or search)
    Library/                       HistoryStore, BookmarkStore (mergeable, tombstones)
    Archive/                       encrypted chunk stream, directory archiver, WebKitDataLayout
    Sync/                          envelope/codec, engine, SyncTransport contract
      Transports/                  LocalDirectorySyncTransport (local-only), HTTPSyncTransport (server-ready)
    Support/                       errors, atomic 0600 writes, encrypted document files
  PrivacyBrowser/                  macOS app (SwiftUI + AppKit + WebKit)
    App/                           main.swift, PrivacyBrowserApp, AppModel, AppEnvironment, SelfTest, SiteCapture
    Browser/                       ProfileManager, BrowserSession, BrowserWindowController, BrowserTab,
                                   TabStripView, ProfileLibrary, LibraryWindowController, PasswordAutoFill
                                   (+ PasswordAutoFillScript, AutoFillPanel), WarmUpRobot,
                                   WebDataStoreVault, ProxyConfigurationFactory, PrivacyScripts
    UI/                            setup/unlock, profile list, editor, passwords, library, sync settings, warm-up
Tests/BrowserCoreTests/            XCTest suite (incl. stub sync server)
Resources/                         Info.plist, entitlements (sandboxed / not), container-migration.plist
scripts/                           build-app.sh, test-shims.mjs, selftest_proxy.py, safari_reference.py,
                                   update_public_suffix_list.py,
                                   live_compare.py + live_sites/ (pages measured in Safari and in profiles),
                                   leak_check.py (QUIC/WebRTC around a proxy)
docs/                              architecture, isolation and limitations, sync format, sync server API
```
