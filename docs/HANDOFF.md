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
| `claude/safari-parity-p1-webrtc` | P1-3: WebRTC escape routes, plus the WebTransport leak fix | **last commit 39b06ee, CI not yet checked** |

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

**First thing to do:** read the CI result for 39b06ee (macOS job, self-test step):
1. **Time-zone checks** ("a shared/service worker runs in the profile's zone, with its own
   profile's User-Agent") must pass in both builds.
   - If they still fail, the cause is not the encoded-transform switch. Look at the other
     changes in 1749618.
2. **"WebTransport (with a proxy): shared and service workers report the profile's
   User-Agent"**.
   - If it fails, the `WebTransportEnabled` switch has the same side effect and a different
     mechanism is needed. A JS-only removal would leave URL and service workers able to
     leak.
3. **Expected count: 236 checks.** The leak check must be green.

Then finish the P1-3 docs:
- in `docs/ISOLATION_AND_LIMITATIONS.md`: the §0 header count, and §0 rows for the WebRTC
  escape routes (workers, sandboxed frames, popups);
- the README check count;
- remove the "follow once CI has run" note.

## Next: P1-4 (iPhone/iPad profiles)

The current iPhone profile sets JS getters only (`patchDevice`: platform, maxTouchPoints,
screen 390×844, devicePixelRatio 3). The window stays a desktop one, so
`innerWidth > screen.width`, an obvious contradiction.

Engine levers found in WebKit's source (all private API):
- **`-[WKWebView _setOverrideDeviceScaleFactor:]`**: a native DPR, so `matchMedia`
  resolution and canvas agree. Then drop the JS `devicePixelRatio` getter.
- **`-[WKWebView _setLayoutMode:]`** with `_WKLayoutModeDynamicSizeComputedFromViewScale`,
  plus `_setViewScale:` (or `_setFixedLayoutSize:`): a native layout width of 390, so
  `innerWidth` matches.
- **`-[WKPreferences _setMediaSourceEnabled:NO]`**: an iPhone has no `MediaSource`. Keep
  `_setManagedMediaSourceEnabled:` on.
- **`WKPreferences.isElementFullscreenEnabled = false`** on iPhone.
- **`NotificationsEnabled`** via `_features`: iOS has no `Notification`.
- iOS defaults are in WebKit's `UnifiedWebPreferences.yaml`, under
  `PLATFORM(IOS_FAMILY)` keys.

**Caution:** after each engine preference change, check that the remote-worker UA checks
(time-zone test, iPhone profile "Asia/Tokyo") stay green. See the regression above.

## P2 (later)

TLS/HTTP2 through the proxy, inert WebRTC, minor surface differences. Also worth adding to
the leak check: WebSocket and HLS media through the proxy.

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
- CI logs: the GitHub MCP `get_job_logs` (`return_content=false`), then `curl` the URL.
  The macOS job holds the self-test and the leak check.
