# Handoff: Safari-parity work in progress

For the next agent picking this up. Everything below is pushed; nothing lives only in a
session.

## The task and the owner's rules

The task: make profiles look like real Safari to anti-fraud systems, in stages:
P1-1 → P0-3 → P1-2 → P1-3 → P1-4 → P2. For each stage, implement it, verify it in CI
(self-test), update the docs, push, and go straight on to the next stage. The owner writes
in Russian; report in Russian.

Rules from the owner:
- **No canvas or WebGL noise**: the project deliberately does not do it. Do not propose
  anything impossible on public WKWebView. Be concrete, with links to the code and docs.
- **Do not widen the scope.**
- **Reviews stay small.** Run 1–2 targeted checks per change (compile, self-test, one
  runtime scenario).
  - No more than 5 agents, and no more than 10–15 minutes per review.
  - Do not run near-duplicate verifications.
  - Agents are allowed.
- **Do not open PRs unless asked.** PR #1 (`claude/safari-parity-p0`) was opened by the
  owner, and merging is the owner's call.
- Commit messages carry no model names.

## Branches (stacked, each on the previous one)

| Branch | Stage | State |
|---|---|---|
| `claude/safari-parity-p0` | P0-1/P0-2: engine time zone, background tabs, etc. | done, PR #1 |
| `claude/safari-parity-p1-quota` | P1-1: Safari's storage quota in the data store | done, CI green (210/210) |
| `claude/safari-parity-p0-workers` | P0-3: shim into blob workers as one line, no eval (CSP / Trusted Types safe) | done, CI green (215/215) |
| `claude/safari-parity-p1-geolocation` | P1-2: geolocation denied by WebKit itself, the tab's UI delegate answers permission state | done, CI run 210 green (222/222) |
| `claude/safari-parity-p1-webrtc` | P1-3: WebRTC escape routes, plus the WebTransport leak fix | done, CI runs 213–215 green (236/236) |
| `claude/safari-parity-p1-ios` | P1-4: iPhone/iPad profiles; P2: TLS/HTTP2 parity, beacons, WebSocket and media through the proxy; P0-4: shim frames in `e.stack`; iOS fonts in the engine | done, CI run 230 green; PR #2 into the default branch (`main` does not exist), contains PR #1 |
| `claude/process-per-profile` | A process per profile, stage 1: design and a minimal end-to-end mode behind a setting (off by default) | done, CI run 243 green (294/294 in each build: 264 + 30 new; Safari reference 449 keys identical); stage 2 not started |

## P1-3 state (`claude/safari-parity-p1-webrtc`)

Done and seen working in CI runs 211 and 212:

- **WebTransport is off with a proxy.**
  - The leak check (run 209) measured WebKit sending WebTransport's QUIC around both
    proxy kinds, from the Mac's real IP.
  - A proxied profile now has the `_WKFeature` `WebTransportEnabled` switched off
    (`WebKitPreferences.setFeature` in `BrowserSession.makeWebViewConfiguration`).
  - The leak check now shows "no WebTransport (nothing to leak)" in every proxied profile.
- **The worker-hook gate fires only on peer connections:** `RTCPeerConnection` in a window,
  `RTCDataChannel` in a worker.
- **ReDoS fixed** in `PROLOGUE` and `AFTER_PROLOGUE` (`PrivacyScripts.swift`).
- **Popups are guarded** in the relay-only and tunnel modes:
  - `document.open` with three arguments is wrapped;
  - `window.open` calls `ReflectApply`;
  - fail-closed: `contained()` / `rtcContained()` close a popup the patch did not reach.
  - The self-test popup routes all show `relay:none`.
- **Shim tests** for all of this, with mutants confirmed caught (Node and Bun, page and
  worker form).

Regression found and handled in commit 39b06ee:
- Switching `WebRTCEncodedTransformEnabled` off through `_features` coincided with shared and
  service workers reporting WebKit's **default User-Agent** instead of the profile's. That
  happened in 4 of 8 profile runs; the time-zone scope checks in `engineTimeZone` failed.
- The switch was reverted; encoded transforms stay on, and the shim removes them from the
  window.
- **The cause is not understood.** WebKit source was read
  (`WebProcessPool::establishRemoteWorkerContextConnectionToNetworkProcess`,
  `SWServer::serviceWorkerClientUserAgent`) without finding it.
- 39b06ee also adds to `webTransportWithAProxy` a check that shared and service workers
  report the profile's UA, with and without a proxy. Each profile runs in its own pool via
  the time zone Europe/Berlin.

**Result (CI runs 213–215, 39b06ee):** 236/236 in all six self-test runs.
- The remote-worker UA checks passed 24/24 in the time-zone test with the encoded-transform switch
  reverted (they had failed in 4 of 8 profile runs with it).
- The new check with WebTransport off passed 12/12, so that switch has no such effect.
- The leak check is green.
- The P1-3 docs carry these values.

## Full plan with status

This is the plan from the original analysis, in priority order, with what has happened to
each item since.

| Item | What | Status |
|---|---|---|
| P0-1 | A `WKProcessPool` per profile with `_WKProcessPoolConfiguration.timeZoneOverride`: a native time zone in the page, frames and every worker, and no service-worker User-Agent shared between profiles | done (`claude/safari-parity-p0`, PR #1) |
| P0-2 | Background tabs (⌘-click) measured 0×0 (`WKWebView(frame: .zero)`), like headless | done (PR #1) |
| P0-3 | The blob-worker bootstrap triggered CSP / Trusted Types violations (eval, sync XHR) that went to `report-uri` | done (`claude/safari-parity-p0-workers`) |
| P0-4 | Measurements: worker scopes, background tabs, quota in workers | mostly done. **Open:** check whether the shim's wrapper frames show up in `e.stack` |
| P1-1 | Native storage quota through `_WKWebsiteDataStoreConfiguration`. Safari reports 82 GB; WebKit gave 1000 MiB in URL and service workers | done (`claude/safari-parity-p1-quota`) |
| P1-2 | Geolocation denied by WebKit through `WKUIDelegatePrivate`, instead of about 20 replaced functions | done (`claude/safari-parity-p1-geolocation`) |
| P1-3 | WebRTC routes around relay-only (worker canary, sandboxed frames, popups), plus the WebTransport proxy leak | done |
| P1-4 | iPhone/iPad profiles: the device's pixel ratio, feature set, window and orientation | done (`claude/safari-parity-p1-ios`), see below |
| P2 | Measure TLS/HTTP2 through the proxy and gate those checks on it; "inert" WebRTC; small differences from Safari in the live comparison (`errorStack`, `windowOwnCount`); leak check for WebSocket and HLS | TLS/HTTP2 parity, beacons, WebSocket and media done; "inert" WebRTC not done on purpose; `errorStack`/`windowOwnCount` explained (below) |

Smaller open points from the analysis:
- **Blob-worker traces.** A shimmed blob worker's `location.href` and `ErrorEvent.filename`
  are the shim's new blob URL, not the page's.
- **Blobs from other frames.** A blob made in another same-origin frame is not tracked: each
  window has its own map.
- **`data:` URL workers** are not covered.
- **Out of scope for good:** Apple Pay, Web Push and `navigator.webdriver` cannot be fixed
  from WKWebView. The docs say so; leave them.
- **Merging is the owner's decision.** None of the stacked branches is merged yet.

## P1-4 and P2 state (`claude/safari-parity-p1-ios`)

What an iPhone or iPad profile gets (commits 273e529, 02612c6):
- **Pixel ratio in the engine:** `-[WKWebView _setOverrideDeviceScaleFactor:]` per tab (3 or
  2), so `devicePixelRatio` and the resolution media queries agree. The shim's getter is only
  the fallback for a WebKit without it (macOS 26.6.2 has it).
- **Safari's feature set there**, per MDN's browser-compat-data:
  - Fullscreen: iPad only (`isElementFullscreenEnabled`).
  - Notification: neither (`NotificationsEnabled` via `_features`).
  - MediaSource: iPad only. `_setMediaSourceEnabled:` does not hide it on macOS 26.6.2 (CI run
    217), so the shim removes it (`Device.missingInterfaces`). The self-test logs the engine's
    own answer from `WKContentWorld.defaultClient`.
- **The window is the device's viewport:** 390 × 739 (iPhone), 820 × 1106 (iPad). These are
  estimates from an iPhone 16 Pro's numbers (`PrivacyScripts.deviceViewportSize`); no real
  device was measured. A second tab grows the window by the tab strip.
- **Orientation:** `screen.orientation` portrait-primary, angle 0.
- **UA:** a mobile generation of the host's release names its major.minor (`Version/26.6`). The
  picker hides other releases (iOS 27) unless the profile already has one.

To do with a real device: run `python3 scripts/device_reference.py --name iphone-ios26` on a
Mac, open the printed URL in Safari on the iPhone, and replace the estimates in
`deviceViewportSize` (and `DECLARED` in the script) with what it measured.

**Remote workers' User-Agent: a WebKit race, not ours.**
- A fresh profile's shared and service workers sometimes report WebKit's bare default UA
  (`… (KHTML, like Gecko)`, no `Version/… Safari/…`).
- The "shared pool" INFO line shows it since CI run 193, before any engine switch of ours: 9 of
  32 self-test passes, mostly the first (sandboxed) one.
- WebKit source:
  - Safari 26 branches 7622–7624 have an inverted test in
    `WebSharedWorkerContextManagerConnection::launchSharedWorker`
    (`if (!initializationData.userAgent.isEmpty()) initializationData.userAgent = m_userAgent;`):
    a shared worker takes the worker process's UA, never its page's. Fixed in 7625.
  - `WebProcessPool::remoteWorkerProcesses()` is static: every pool's
    `updateRemoteWorkerUserAgent` reaches every remote-worker process of the app.
  - The race itself (why the process sometimes has no UA) was not found.
- The checks (time zone, WebTransport, surface) now:
  - accept the profile's UA or WebKit's bare default (logged);
  - fail on any other UA, such as another profile's.
- `remoteWorkerRace` counts the race over 6 fresh iPhone profiles each: as shipped, with
  Notification on, and with encoded transforms off.
  - Runs 218–221 (8 passes): 12, 14 and 11 of 48. The settings make no difference.
  - Runs 211–212 had blamed the encoded-transform switch (4 of 8 failing then). It stays reverted
    anyway.
  - After any new engine switch, compare these counts.

P2 (02612c6, 3529a37):
- **TLS/HTTP2 parity.** The leak check loads tls.peet.ws in each proxied profile through its
  proxy. JA4, ciphers, extensions, Akamai frames and header order and values must equal the
  profile's without a proxy, or it exits 1.
- **Beacons.** A `pagehide` beacon reaches the proxy (self-test).
- **WebSocket and media.** A WebSocket, an HLS stream (playlist and segment) and an MP4 in HTTP
  CONNECT and SOCKS5 profiles reach the proxy (CI run 221, with a no-proxy control). AVFoundation
  plays media, not WebKit's loader, so it had to be measured. It needs a shown window: WebKit
  loads no media for a page that is not visible.
- **WebKit's default data store.** It stays closed: with it opened (a `WKWebView` from
  `WKWebViewConfiguration()` whose store is left unset), session cookies outlived a profile's
  stop (runs 218–219, fixed 220). `BrowserSession.makeWebViewConfiguration` never leaves the
  store unset.
- **Not done on purpose.** "Inert" WebRTC would replace the engine's guarantee (no
  `RTCPeerConnection`) with a JS one. The original analysis advised against it.
- **Live-compare differences that stay.**
  - `errorStack` and `webdriver` come from the harness (safaridriver against our capture).
  - `windowOwnCount` follows from Apple Pay, Web Push and WebRTC, which WKWebView cannot match.

P0-4's open point, the shim's frames in `e.stack`, is fixed (e860267). CI run 220 found a `@user-script:` frame in each provoked error; run 221 finds none in the macOS, iPhone and iPad profiles:
- **What leaked.** A replacement that called the native first to check its receiver left its
  frame (`user-script:N`, as WebKit names it) in the native's error. That held in every profile:
  the `contentWindow`/`contentDocument` getters, `window.open` and `document.open`.
- **The fix.** A receiver the native refuses now gets the native call in tail position; the shim
  is strict, and JavaScriptCore drops the caller's frame for it (`refused()` in `PrivacyScripts`).
- **Tests.** A shim test checks it under Bun (JavaScriptCore; V8 has no proper tail calls).
  The self-test compares the stacks with a plain web view's.
- **Still with a frame.** Errors from arguments (`window.open('http://[')`), and the shims of
  non-default modes: the time-zone shim, fixed geolocation, relay-only WebRTC.

## iOS signals and language (the owner's follow-up)

The owner's request after P2: iPhone profiles are still told apart by TLS, GPU, fonts, touch and
codecs, and the language (`Accept-Language`, `navigator.languages`) is set by the first profile
for the whole run. Say what can be fixed and what WKWebView cannot do, with references. The
answer is in `docs/ISOLATION_AND_LIMITATIONS.md`: §2 *iPhone and iPad profiles against the device*
(one row per signal) and §6 *Language: one per app run* (WebKit's code).

Done:
- **Fonts, in the engine.** `WKContextSetFontAllowList` (C SPI, looked up with `dlsym`) gives
  an iPhone or iPad profile's pool a font allowlist: every family of this Mac with a face iOS does
  not lack, by Apple's font list (`scripts/ios_fonts.py` → `Sources/BrowserCore/Profiles/IOSFonts.swift`,
  `DeviceFonts`, `DeviceFontRestriction`). `cursive` is Snell Roundhand
  (`WKPreferencesSetCursiveFontFamily`). Self-test: families only a Mac has are not found in an
  iPhone and an iPad profile, ones both systems have are. Regenerate the list when Apple's page
  changes: `python3 scripts/ios_fonts.py`.
- **TLS:** no change needed. Safari 26 on iOS sends the same ClientHello (Scrapfly's JA4
  database, linked in §2).
- **Measuring tools.** The probe has `codecs`, `touchShape`, `fontFamilies` and `windowNames`.
  `scripts/device_reference.py` captures a device's JA4 and HTTP/2 frames on its own listener and
  compares a device reference with a profile's surface (`--compare`). Checked locally against
  curl: the values tls.peet.ws gives for the same curl.
- `scripts/safari_reference.py` requires `codecs.*`, `touchShape.*` and `fontFamilies.*` to match
  Safari on the Mac.

Open, and why:
- **A device measurement.** Nothing below can be settled without one: the owner runs
  `device_reference.py` once on an iPhone (and an iPad), then `--compare` against
  `surface-iphone.json` from the CI artifact `fingerprint-surfaces`.
- **Touch interfaces** (`TouchEvent`, `Touch`, `TouchList`, `ontouchstart`,
  `document.createEvent('TouchEvent')`, `DeviceMotionEvent.requestPermission`): a shim can add
  them, the way it gives the navigator values, once the device shows their exact shape (iOS
  builds them from sources Apple does not publish). Touch *events* are impossible.
- **Codecs:** answers can only be taken away (as `MediaSource` is), from a device's measurement.
- **WebGL extensions and limits:** matching them means rewriting WebGL's answers
  (deterministic, not noise). Waiting for the owner's decision, since WebGL is kept native.
- **HTTP/2:** cannot be changed (CFNetwork). Only measured.
- **Language per profile:** needs an app process per profile. Stage 1 is on
  `claude/process-per-profile` (below); in the one-process mode the launch warning
  `launch.languageFixed` stays.

## A process per profile (`claude/process-per-profile`)

The owner's request: the language per profile through a separate app process per profile.
Stage 1 is the design (`docs/PROCESS_PER_PROFILE.md`) and a minimal end-to-end mode behind a
device setting, off by default. **Stage 2 is not to be started** without the owner.

- **Launch:** `ProfileProcessHost` (launcher) opens the app's own bundle again through
  `NSWorkspace.openApplication` with `createsNewApplicationInstance`. `main.swift` asks
  `ProfileProcessClient.assignment()` first; an instance a launcher started runs
  `ProfileProcessApp` (one profile, its own menus and Dock tile) instead of the SwiftUI app.
- **Channel:** `ProfileProcessChannel.swift`: a Unix socket in the container's temporary
  directory (0600), length-prefixed JSON, peers checked by audit token and code requirement on
  both ends; the key is handed over once per launch token, to the process LaunchServices started.
- **Launcher side of a launch:** `ProfileManager.launchInOwnProcess` (lookup through the proxy,
  then `start` with the effective configuration, language and locale), `stopProcess`,
  `profileProcessExited` (seals what a crashed process left: `recoverProfileData`).
- **Profile side:** `ProfileProcessRuntime` (decrypt, `WebContentLanguage.decide(language,
  locale:)`, `BrowserSession` over `SingleProfileFiles`, seal on stop, last window, ⌘Q, and when the
  launcher goes away).
- **Off in a profile's process (stage 2):** AutoFill, the packet tunnel, cookie import while it
  runs, sync of running profiles, warm-up, the launcher's Library for it.
- **Self-test:** the group *process per profile* (both builds), with the self-test proxy's
  `--socks-jp` listener (answers lookups as Japan) next to `--socks2` (Germany). Results of CI run
  243 and the stage-2 list: `docs/PROCESS_PER_PROFILE.md`.
- **WebKit reports `ja` for `ja-JP`** (`[NSLocale minimizedLanguagesFromLanguages:]`, as in Safari);
  `WebContentLanguage.reported` gives what it makes of a language, and the checks expect that.
- **Another session works on `claude/safari-parity-p1-ios`** (PR #2: the device reference in
  Safari on CI). This branch starts at `c025ece`; rebase it once PR #2 is merged.

## What is left

- Measure a real iPhone and iPad with `scripts/device_reference.py`; replace the viewport
  estimates; then the touch interfaces and the codec answers above, and the owner's decisions on
  WebGL and on a process per language.
- The remaining frames above, if a site is seen to look for them.
- Smaller points from the analysis (below the plan table) are still open.

## Where things are

- Shim: `Sources/PrivacyBrowser/Browser/PrivacyScripts.swift`, a raw string; the JS is
  tested by `scripts/test-shims.mjs`.
  - Run the tests: `TZ=America/New_York node scripts/test-shims.mjs`.
  - Also with `SHIM_FORM=worker`, and with `bun` (at `~/.bun/bin/bun`).
- Engine settings: `Sources/PrivacyBrowser/Browser/BrowserSession.swift`
  (`makeWebViewConfiguration`, `WebKitPreferences`).
- Self-test: `Sources/PrivacyBrowser/App/SelfTest.swift`.
  - It runs only on the macOS CI runner; Swift cannot be compiled on Linux here.
  - Its test pages come from `scripts/selftest_proxy.py`.
- Leak check: `scripts/leak_check.py`.
- A real device's Safari: `scripts/device_reference.py` (HTTPS page on this Mac; results in `scripts/reference/`).
- CI logs: the GitHub MCP `get_job_logs` (`return_content=false`), then `curl` the URL.
  The macOS job holds the self-test and the leak check.
