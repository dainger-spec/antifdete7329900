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

**Fingerprint note (2026-10-26):** no canvas, WebGL, audio or font noise — noise is exactly what fingerprinting tests detect. macOS profiles override no navigator or screen value and declare this Mac's real Safari version; iPhone/iPad profiles only get their device class's navigator/screen values. A profile with a proxy runs in the time zone of the proxy's exit IP (also in workers created from a blob), and the first profile launched sets the language websites see (otherwise this Mac's languages, as in Safari). The window reports Safari's geometry (real outer size, 52/90 px of chrome), user-installed fonts are hidden and the storage quota is Safari's. CI measures a profile against the runner's real Safari, page by page, including TLS/HTTP2 and header order: what still differs is Apple Pay/Web Push (Safari-only) and the profile's own privacy choices ([§2](docs/ISOLATION_AND_LIMITATIONS.md#measured-against-this-macs-safari)). deviceinfo.me's "Canvas: Spoofed" / "Fingerprinting Resistance: Detected" appear in real Safari 26 as well (its PNG-length list predates this WebKit). iOS fidelity remains UA-level (TLS, GPU, fonts, touch are the Mac's).

- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md): components, key hierarchy, on-disk layout, lifecycles, tabs, testing
- [docs/ISOLATION_AND_LIMITATIONS.md](docs/ISOLATION_AND_LIMITATIONS.md): what is isolated, what leaks, fingerprinting, App Sandbox, verified results
- [docs/LEAK_AUDIT.md](docs/LEAK_AUDIT.md): the leak audit's short list — each channel, why it is reachable, what proves it, its state
- [docs/SYNC_FORMAT.md](docs/SYNC_FORMAT.md): sync wire format, merge rules, what is server-ready vs. local-only
- [docs/SYNC_SERVER_API.md](docs/SYNC_SERVER_API.md): HTTP contract for a future sync server
- [docs/AUTOMATION_API.md](docs/AUTOMATION_API.md): the local automation API and `scripts/pbctl`
- [docs/UPDATES.md](docs/UPDATES.md): automatic updates — why our own updater rather than Sparkle, installing only after every profile is sealed, what each file on disk may hold across versions, the privacy of the check (design; implemented step by step)

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
- **From a sandboxed build to an unsandboxed one** (which hosts Safari's chrome): an unsandboxed
  build that has no vault yet takes over the one a sandboxed build of the same bundle identifier left
  in its container, once, at its first start (moved, never copied; not while the other runs).
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

# End-to-end against the real WebKit of this Mac (headless, temporary vault, cleans up):
python3 scripts/selftest_proxy.py --http 18080 --socks 18081 --http-auth 18082 --http6 18083 \
  --socks2 18084 --socks-auth 18085 --silent 18088 &
PB_SELFTEST_HTTP_PROXY_PORT=18080 PB_SELFTEST_SOCKS_PROXY_PORT=18081 \
PB_SELFTEST_HTTP_AUTH_PROXY_PORT=18082 PB_SELFTEST_HTTP6_PROXY_PORT=18083 \
PB_SELFTEST_SOCKS2_PROXY_PORT=18084 PB_SELFTEST_SOCKS_AUTH_PROXY_PORT=18085 \
PB_SELFTEST_SILENT_PROXY_PORT=18088 \
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
- `--self-test` for both the sandboxed and the unsandboxed build, covering WebKit
  data location, seal/restore of cookies, localStorage and IndexedDB, live isolation between
  profiles, shims under JavaScriptCore, the fingerprint surface against a plain WKWebView,
  HTTP CONNECT (IPv4 and IPv6), SOCKS5 and authenticated proxies, fail-closed, three SOCKS5
  profiles launched and loading at once, the ping-load blocker, the proxy-location time zone,
  launches that wait only briefly on the lookup through the proxy, the exit-IP warning, the proxy
  list's checker (every listener of the self-test proxy told apart step by step — HTTP and SOCKS5
  found whatever type is listed, the login not needed, missing, wrong or taken, IPv6, a port that
  takes the connection and never answers, a closed port, a host that does not exist; through a
  working proxy its exit IP, country, city, network and median latency; dead through an
  unreachable one, with nothing gone around it; several at a time, kept encrypted, a line without
  a scheme given the type found and a wrong type corrected; a profile given a checked proxy; a
  profile started with a silent proxy saying why, and Check from there — all of it, but the host
  that does not exist, inside a packet capture that fails on anything of the app's past
  loopback), password
  AutoFill (save, update, never, suggestions and fill, sign-in by script, sign-up, frames of
  another and of the same site, nothing for a password a page script wrote), cookie import
  (a damaged Netscape file, queued for a stopped profile and applied before its first page,
  a cut-off JSON into a running one, persistence across stop and launch), profile sync between
  two vaults (cookies recorded at stop and launch, applied before the first page on the other
  device, a change and a deletion coming back, settings newer-wins with a conflict copy), the
  session warm-up robot (pages in order through the proxy with the profile's cookies and
  User-Agent, time on each page measured at the proxy, scrolling, only the safe link followed,
  nothing in the page world while it acts, Stop, tab closed, a page dialog, the profile stopped
  mid-run; a queue of two profiles warmed one after the other, each started without a window and
  sealed again before the next, and each run's cookies per site), a proxied profile in its own
  process with Safari's chrome on a leak page (every kind of request through the proxy, the
  process's own report), profile export and import, tabs, history,
  bookmarks, the
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
  it, HTTP/3 without it); WebRTC is off in proxied profiles without the tunnel. Through the
  tunnel's relay (run on the runner, since CI cannot load the extension), a page gets relay
  candidates at the proxy's address only, and a data channel through the proxy. Fails on any
  request seen going around a proxy;
- around the unsandboxed self-test, a capture of every packet leaving the runner with its process
  (`scripts/egress_check.py`) and of every file the app and WebKit write (`scripts/disk_check.py`):
  nothing of a profile may leave outside its proxy, or land where the real Safari keeps its data;
- `--check-safari-chrome`: the private Safari classes and methods the hosted chrome relies on
  (loaded in a temporary home, held to a closed proxy, as in a profile's process);
- `scripts/check_localization.py`: ru and en hold the same keys, and no UI text is written into the code;
- `scripts/check_log_privacy.py`: nothing of the user's is written to the system log in clear;
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
8. **Warm-up:** **⋯ → Warm Up…** takes a ready-made list (general, by interest, or by
   country: 26 countries), one put together for the proxy's country, or web addresses of your
   own; starts the profile without a window if it is stopped, and visits the pages one after
   the other in a hidden window of it: a random time on each page, scrolling, and if asked one
   plain link followed. **Stop** in the sheet, closing the robot's tab or stopping the profile
   ends it. When the run is over the sheet lists the profile's cookies per site and how many
   the run added. **Repeat on a schedule** runs the same plan every N hours while the app is
   unlocked (never in a profile that is open; it is tried again 10 minutes later).
   **More → Warm Up Several Profiles…** warms the ticked profiles one after the other with one
   plan, each stopped and encrypted again before the next starts; the rest of the queue can be
   cancelled.
9. **Stop**, or closing the last window, saves history and encrypts the profile's website
   data. **Lock** stops every profile and forgets the keys. Quitting (⌘Q) does the same,
   and waits until every profile is sealed.
10. **Sync (optional):** **More → Sync…** offers a folder (local-only) or a server (client
   for the documented API; no server is included). Stop all profiles before syncing. A
   profile's settings, passwords, bookmarks, history and persistent cookies sync, encrypted;
   another Mac gets the cookies at its next launch of the profile, before the first page
   (**⋯ → Edit…** → **Sync cookies with other devices** turns that off for a profile).
11. **Proxies:** **More → Proxies…** keeps a list of proxies, encrypted in the vault (this Mac
   only, not synced):
   - **Import…** takes a pasted list or a text file, one proxy per line: `host:port`,
     `host:port:user:pass`, `user:pass@host:port` or `socks5://` / `http://` / `https://user:pass@host:port`
     (` # Berlin 1` after a proxy names it). A line without a scheme gets its type from the first
     check (**Found by Check**, the default; until then it is given to no profile), or the type
     chosen in the sheet. Lines that cannot be read are listed with their number and why before
     anything is added; a proxy already listed (the same host, port and user name) is not added
     twice. The proxies typed into profiles before the list existed are in it from the first unlock.
   - **Check All / Check Selected** checks each proxy *through itself*, step by step: its name, a
     connection, a SOCKS5 and an HTTP handshake at once (the type is found, not assumed), the
     login, a tunnel, then a geolocation service asked through it — exit IP, country (flag), city,
     network, and the median of three tunnels' latency. Each way of failing has its own status,
     symbol and colour, and the selected proxy's report says which step failed, in words, with
     what to do: host not found, connection refused, no connection, **silent after connecting**
     (an IP whitelist without this Mac's address, or a dead back end), login needed or rejected,
     this Mac refused (403), no way out to the site. A check never goes direct. Checks run only
     when asked.
   - **Edit…** changes a proxy; the profiles that use it as it is in the list follow (a profile
     whose own copy was changed since keeps it). **Export…** writes the list for Import, after
     saying that the user names and passwords will be in the file in plaintext (owner-only file).
   - **Assign to Profiles…** gives the selected proxies to the profiles ticked: with one proxy all
     of them get it, with several they get them in turn (round-robin). A running profile uses its
     new proxy from its next launch. In the profile editor, **Choose from List…** fills the proxy
     fields from the list. The list shows how many profiles use each proxy.
   - A profile started with a proxy that does not work says so in the Profiles window — which
     profile, what the same probe found, what to do — with **Check Proxy** and **Show in Proxies**.
12. **Several profiles at once:** ⌘-click (or ⇧-click for a range) selects rows of the Profiles
   list; with two or more selected, a bar above the list launches, stops, warms up, assigns
   proxies to or deletes them all (deleting asks once, naming how many).

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
| Session warm-up ("cookie robot") | **⋯ → Warm Up…**: the pages of a list (and a search first, if given) visited one after the other in a tab of the profile — its proxy, cookies, User-Agent and scripts, as when browsing — with a random time on each page (5–15 s by default), trackpad-like scrolling, and optionally one plain link followed (same site; from the search, a result; never sign-out, purchase, deletion, download or new-window links). Waits while its tab is not shown; stops on Stop, when its tab closes, when a page shows a dialog and when the profile stops. Scrolls with real wheel events while its window is key, otherwise from an isolated script world; clicks with real pointer events when they reach the link, otherwise with an (untrusted) script click — on the CI runner pointer events did not reach pages, so clicks there were script clicks; nothing is added to the page world, and nothing is downloaded. After a run, the profile's cookies per site (registrable domain, Public Suffix List) and which of them the run added, counted in the profile's own cookie store where the robot ran (its own process included) and reported with the run's status. **More → Warm Up Several Profiles…**: a queue — the ticked profiles one after the other with one plan, each started without a window if stopped and stopped and sealed again before the next, "profile n of N", the rest cancellable. **Repeat on a schedule** (per profile, encrypted `warmup-schedule.bin`, this Mac only, not exported): every N hours with the saved plan while the app is unlocked, through the same queue (one run at a time); a profile that is running is left alone and tried again 10 minutes later; a Mac that slept runs it once, not once per missed interval. **Checked by the self-test** through the proxy (order, cookies and User-Agent on the requests, Referer of the followed link, links refused, the stop cases, sealing after a stop mid-run; a queue of two profiles never running at once, each without a window and sealed before the next; the per-site report against a cookie the profile already had); due times, postponing and the queue's order by unit tests |
| A profile in its own process, with Safari's own window (unsandboxed build) | On by default in the unsandboxed build (`PB_PROFILE_PROCESS=0` or `defaults write <bundle id> PBProfileProcess -bool NO` switches back to one process, our own windows). One process per profile (`ProfileProcess`; only its own profile's key, on its stdin — never the vault's master key), its language, locale and time zone native to it, its window Safari's chrome hosted from Safari's frameworks. The whole process is held to the profile's proxy (`ProfileNetworkGuard`): every web view on the profile's store at its initializers, every other store closed, the process's own connections through the proxy, privacy preferences pinned (workers included), certificates checked without this Mac fetching for them, Safari's and the system's services that would fetch from another process or keep the browsing refused, Handoff off; the kernel refuses the process UDP (with a proxy) and the real Safari's folders, which Safari's frameworks would otherwise use as the profile's ([ISOLATION_AND_LIMITATIONS.md §4a](docs/ISOLATION_AND_LIMITATIONS.md)). **Checked on every push**: a leak page in Safari's chrome (every request reaches the proxy, `.local` included, and none reaches this Mac's own loopback (refused: the system never proxies it); no WebRTC or WebTransport, in workers either; a certificate that needs a fetch refused), the process's own report, and a capture of every packet and every file written around it — nothing may leave the machine outside the proxy or be written where the real Safari keeps its data. `--check-safari-chrome` lists the private pieces a macOS update removed |
| Automation API and `pbctl` | **⋯ → Automation API…** (off by default; the build without the App Sandbox): scripts on this Mac list, start (with a window or out of sight), open pages in and stop profiles, and read and write their cookies (Playwright, Netscape, extension JSON) — through the same code as the app's buttons, so a script's profile has its proxy, its process and its sealing. HTTP on 127.0.0.1 only, a 43-character token, requests from web pages (`Origin`, `Sec-Fetch-*`) and rebinding names (`Host`) refused, never a proxy's credentials in an answer; `scripts/pbctl` on the command line ([docs/AUTOMATION_API.md](docs/AUTOMATION_API.md)). It does not drive pages: WebKit's embedded views have no CDP for Puppeteer or Playwright to attach to. **Checked by the self-test** on a real listener (refusals, a hidden start, cookies in and out, stop) and by unit tests |
| Profile export and import | **⋯ → Export Profile…** / **Import Profile…**: a profile whole — settings and proxy, passwords, history, bookmarks, warm-up plan, cookies and website data, Safari's state — in one `.pbprofile` file under a password of its own (Argon2id), for another Mac, a backup or a colleague. Nothing is written in plaintext on either side (the website data is re-encrypted from archive to archive in memory); an import is always a new profile. **Checked by the self-test** (a cookie of the original is sent by the imported profile's first request) and by unit tests |
| Profile sync: cookies and settings | A profile's persistent cookies sync as `cookies.bin` (encrypted with the profile key), merged cookie by cookie — the newer change wins, deletions included; recorded when the profile stops, applied at its next launch before the first page loads, imported cookies joining at that launch. Settings changed on two Macs: the newer edit wins, the other kept as `config.bin.conflict`. Session and partitioned cookies, and ephemeral profiles, never sync ([docs/SYNC_FORMAT.md](docs/SYNC_FORMAT.md)). **Checked by the self-test** with a second vault set up from the sync folder, and by unit tests |
| Proxy manager: import, stepwise check, edit, export, assign, rotate | **⋯ (header) → Proxies…**: a list kept encrypted in the vault (`proxies.bin`, this Mac only); each profile keeps its own copy of its proxy, linked to the list by host, port and user name — profiles' proxies are taken into the list once, an edit in the list reaches the profiles that use it as it is, and a missing entry never leaves a profile without its proxy. Import reads pasted lines or a text file — `host:port`, `host:port:user:pass`, `user:pass@host:port`, `socks5://` / `http://` / `https://user:pass@host:port`, ` # label` — reports every line it could not read with its number and why, and leaves the type of a line without a scheme to the first check (`ProxyListImport`). The check (`ProxyProbe`, POSIX sockets, only to the proxy) resolves the name, connects, tries a SOCKS5 and an HTTP handshake at once, logs in, opens a tunnel (the target named to the proxy), then asks the geolocation services through the proxy (`allowFailover = false`): exit IP, country, city, network, median latency of three tunnels. Distinct states, each with its own symbol and colour, a report step by step with advice: host not found, DNS failed, refused, unreachable, no connection, **silent after connecting**, closes at once, not a proxy, login needed or rejected, refuses this Mac, no way out, no answer through it. A profile whose proxy does not work at its launch says why, with Check. Edit (profiles follow), export (plaintext warning, 0600 file), assign one to many or round-robin. **Checked by the self-test** against every listener of the self-test proxy (HTTP, SOCKS5, both with a login none/wrong/right, IPv6, silent, closed, unknown host), end to end with exit details, inside a packet capture that fails on any packet of the app past loopback; the probe's verdicts against scripted servers, parsing, the link and migration by unit tests |
| Several profiles at once | ⌘-click and ⇧-click select rows of the Profiles list; with two or more, a bar acts on all of them: Launch (the stopped ones, one after the other), Stop (the running ones, sealed together), Warm Up (opens the warm-up for the first; a hook for a queue), Assign Proxy (from the list, one or in turn), Delete (one confirmation naming the count) |

### Approximated (the platform offers no native API)

| Feature | How | Main gaps |
|---|---|---|
| WebKit data encrypted while a profile is not running | Archive, encrypt, then `remove(forIdentifier:)` on stop; restore on launch. Directories found by UUID (`WebKitDataLayout`), layout checked in CI | Plaintext on disk while the profile runs; a crash leaves plaintext until the next unlock; no "flush" API (last-moment writes can be lost, not leaked) |
| Time zone | JS shim (`Intl`, `Date` getters, offsets, string forms, local constructors, setters, `Date.parse`), also in workers created from a blob; by default the proxy's exit-IP zone, looked up through the proxy at launch | Workers loaded from a URL and service workers keep the host zone; the lookup is a third-party request |
| Geolocation | JS shim: deny (default) or fixed coordinates | Detectable; the IP address reveals location unless the proxy matches |
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
- The proxy list is this Mac's only (profiles carry their own copy of a proxy, which syncs); its
  checks ask third-party geolocation services (through the proxy, only when asked), and a launch
  with a proxy probes it (handshake and one tunnel, to the start page's site or the first
  geolocation service, through the proxy). Warming up
  several profiles at once opens the warm-up of the first; there is no warm-up queue yet.

## Project layout

```
Package.swift
Sources/
  BrowserCore/                     platform-independent, unit-tested (macOS + Linux)
    Crypto/                        AEAD (AES-GCM), Argon2id + BLAKE2b, PBKDF2, HKDF helpers
    Vault/                         MasterVault (key hierarchy), DeviceSettings
    Profiles/                      ProfileConfiguration, ProfileRepository
    Proxies/                       ProxyList (encrypted list, check results, rotation, the profiles' link), ProxyListImport
                                   (pasted lines, report), ProxyProbe + ProbeSocket (the stepwise check), ProxyDiagnosis,
                                   ProxyExitDetails, assignment
    Passwords/                     PasswordVault, PasswordMatching (site rules), PublicSuffixList
    Cookies/                       CookieImporter (JSON and Netscape readers, checks, report), CookieJar (synced cookies, merge)
    WarmUp/                        WarmUpPlan (pages, timing, which links), WebAddress (typed text → address or search),
                                   presets and choice, WarmUpQueue, WarmUpSchedule (what is due), WarmUpCookieReport (per site)
    Library/                       HistoryStore, BookmarkStore (mergeable, tombstones)
    Archive/                       encrypted chunk stream, directory archiver, WebKitDataLayout
    Sync/                          envelope/codec, engine, SyncTransport contract
      Transports/                  LocalDirectorySyncTransport (local-only), HTTPSyncTransport (server-ready)
    Support/                       errors, atomic 0600 writes, encrypted document files
  PrivacyBrowser/                  macOS app (SwiftUI + AppKit + WebKit)
    App/                           main.swift, PrivacyBrowserApp, AppModel (+Proxies), ProxyListModel, AppEnvironment,
                                   SelfTest, SiteCapture, WarmUpCoordinator (warm-up queue and schedule)
    Browser/                       ProfileManager, BrowserSession, BrowserWindowController, BrowserTab,
                                   TabStripView, ProfileLibrary, LibraryWindowController, PasswordAutoFill
                                   (+ PasswordAutoFillScript, AutoFillPanel), WarmUpRobot,
                                   WebDataStoreVault, ProxyConfigurationFactory, ProxyGeoLookup, ProxyChecker,
                                   PrivacyScripts, ProfileNetworkGuard, ServerTrust, SafariPaths, HandOffs
    UI/                            setup/unlock, profile list (+ bulk bar), editor, passwords, library, sync settings,
                                   warm-up (one profile, and several in a queue), proxies (list, report, edit, export,
                                   import, assign, a launch's proxy problem),
                                   profile export/import, cookie export
Tests/BrowserCoreTests/            XCTest suite (incl. stub sync server)
Resources/                         Info.plist, entitlements (sandboxed / not), container-migration.plist
scripts/                           build-app.sh, test-shims.mjs, selftest_proxy.py, safari_reference.py,
                                   update_public_suffix_list.py,
                                   live_compare.py + live_sites/ (pages measured in Safari and in profiles),
                                   leak_check.py (QUIC/WebRTC around a proxy)
docs/                              architecture, isolation and limitations, sync format, sync server API
```
