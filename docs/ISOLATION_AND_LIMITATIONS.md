# Isolation model and platform limitations

This document lists what is isolated, what is only approximated, and what is not
addressed. It also gives a way to verify each claim on your own machine. The code
comments marked `PLATFORM LIMITATION` / `FINGERPRINTING LIMITATION` point back here.

## 0. What is verified automatically

`Lumen --self-test` runs headless against the real WebKit of the machine. CI runs it
on every push (macOS 26 runner, built with the current Xcode) for both the sandboxed and the
unsandboxed build, with a local test proxy (`scripts/selftest_proxy.py`). Last observed results
(macOS 26: every check passed in both builds; CI prints the count, 188 at commit 854c87e, more
since):

| Claim | Self-test result |
|---|---|
| Vault key derivation | a PBKDF2 vault is re-wrapped under Argon2id (64 MiB, 3 passes, 4 lanes) in the release build and opens again; the time is logged |
| Sandbox active; vault inside the container | writes outside the container are denied; vault at `~/Library/Containers/<id>/Data/Library/Application Support/PrivacyBrowser` |
| WebKit data location (undocumented) | sandboxed: `Container/Data/Library/WebKit/WebsiteDataStore/<uuid>`; unsandboxed: `~/Library/WebKit/<bundle-id>/WebsiteDataStore/<uuid>`. One directory per store; no separate cache directory was observed |
| Seal → restore of website data | cookies, localStorage and IndexedDB survive; the archive holds no plaintext; plaintext is gone after seal; WebKit released the store after 1 s |
| Two running profiles isolated | localStorage, IndexedDB and cookies of A are invisible to B, for the same origin, at the same time |
| JS shims under JavaScriptCore | time zone (offset, `Intl`, local getters), fixed geolocation, WebRTC removed, WebRTC relay-only |
| WebRTC off (default) | switched off in the engine (`_peerConnectionEnabled` is false): the window has no `RTC*` interface at all |
| HTTP CONNECT proxy | `http://` is tunnelled via `CONNECT`; an `.invalid` host loads, so it was resolved by the proxy |
| SOCKS5 proxy | the hostname is sent to the proxy (`ATYP=3`, remote DNS) |
| Fail-closed | with the proxy unreachable, loads fail ("Could not connect to the server") instead of going direct |
| Tabs, history, bookmarks | tab open/close/reopen/select, visits and titles recorded, bookmark toggle persisted encrypted |
| Window lifecycle (crash fix) | closing one of two windows keeps the profile running; closing the last reports "all closed" once, on a later run-loop turn; `shutDown()` twice is safe |
| Crash-recovery sealing | leftover website data from a crashed run is archived and deleted WITHOUT `WKWebsiteDataStore.remove(forIdentifier:)` (which aborted on an unknown id), then restores cleanly |
| Device generation → UA | a profile's generation UA reaches `navigator.userAgent`; an explicit custom UA overrides it |
| Container migration | an unsandboxed vault is moved into the container on the sandboxed build's first launch (separate CI step) |
| Fingerprint surface | a macOS profile measures the same as a plain WKWebView on the same Mac (navigator, screen, canvas, WebGL, audio, fonts, feature list) except for the Fullscreen API, which Safari has and a bare WKWebView lacks, and `window.safari` where the Safari it names has one (up to Safari 27.1; Safari 27.2 has none); every profile has `window.browser`, WebKit's own WebPageNamespace (`runtime.sendMessage`, `runtime.connect`), as Safari gives every page on the Mac (27.0.1 and 27.2, with no extension installed) and on an iPhone — from an extension controller with no extension in the profile's web views, not a script; an iPhone or iPad view measures the same, under its device's User-Agent, and never has `window.safari` — no iPhone or iPad does; user-installed fonts are hidden from pages, as in Safari. CI also compares the macOS profile with the runner's real Safari (§2) |
| Shims in workers and frames | a worker made from a blob runs the page's substitutions — the time zone, an iPhone's platform, the storage quota — with the profile's time zone or this Mac's alike (it answers the storage quota and the time zone as its page does), stays strict and keeps its line numbers; workers are hooked whenever any substitution that reaches them is on, and only then (until 8 November only with a time zone set, so a profile with this Mac's zone gave its workers the app's quota beside Safari's on the page); a frame reached as `window[i]` right after insertion is patched; `permissions.query({name:'geolocation'})` returns the engine's own `PermissionStatus`, 'prompt' until the page asks |
| Proxy: IPv6, unresolvable host | an HTTP proxy on `[::1]` tunnels the load; a proxy whose host does not resolve fails closed |
| Proxy: WebRTC | a proxied profile whose stored setting is "unrestricted" has no `RTCPeerConnection` or `RTCDataChannel` while the network guard is not ready (§5), and says why; with the self-test standing in for the guard, the same profile makes a video call through the relay and its proxy, inside the capture of every packet ([TUNNEL.md](TUNNEL.md)) |
| Network guard | a build without it says so, and proxied profiles keep WebRTC off; the guard's rules are unit-tested, and its check's probe runs inside a capture ([TUNNEL.md](TUNNEL.md)) |
| Proxy: dns-prefetch leak | an `<a ping>` (the load type WebKit gives dns-prefetch) reaches neither the proxy nor the network; a fetch to the same origin does; the control, the same click in a plain web view without the rule list, does reach the proxy (else the check is a SKIP) |
| Safari's chrome, in a profile's own process | through the app's launch path, a proxied profile whose window is Safari's chrome loads the self-test proxy's leak page: its page load, a fetch to an IPv4 and an IPv6 literal, to a host name, an https request, a WebSocket, a worker's fetch, an image and a frame of another site all reach the proxy; `<a ping>` does not (where the page says it clicked it, and this WebKit's plain web view sends one without the rule list); a fetch to a `.local` name goes to the proxy like any other; this Mac itself — `127.0.0.1`, `localhost`, `::1`, `0.0.0.0`, from the page, a frame and a worker — is refused (the system never sends loopback through a proxy: measured in CI run 382, those fetches reached a listener on the runner directly), and nothing reaches the loopback canary (which must list the self-test's own direct connection, its control); an HTTPS image whose certificate needs a fetch reaches the proxy and its certificate is refused; `RTCPeerConnection` exists in neither the page, a frame of another site nor an about:blank frame, `WebTransport` in neither; on loopback (a secure context) the leak page's secure half, opened as a page of this Mac (loaded from it directly, as any page on this Mac is), has neither in the page and no `WebTransport` in a dedicated, a shared or a service worker; the profile's process reports every web view on its store with its proxy, none with WebRTC or with a feature that leaves the proxy, no setter that turns them on again, WebKit's default store closed, UDP and the real Safari's places closed to it by the kernel, its certificate checks made without fetching, and its own three probe requests at the proxy as one CONNECT each; a cookie imported while it runs is sent by the next window's first request; a second window loads through the proxy too. Around it, the egress capture and the file-system trace (§4a) |
| Nothing handed outside the profile | in a profile's tab of ours: no link preview, even when asked for; no Services requestor for the selection; the context menu keeps Copy and the link items and loses Search with Google, Look Up, Translate, Share, Quick Note, Writing Tools and Services; WebKit's directories of this app are excluded from Time Machine (the build without the sandbox; a SKIP in the sandboxed one) |
| Certificates with a proxy | the self-test proxy answers every TLS handshake in its tunnels with a certificate whose chain is complete only for a client that fetches the intermediate from the address the certificate names (`pbaiacanary.leak.example.com`): in a proxied profile's tab the certificate is checked without a fetch and refused at the handshake, through the proxy; the same kind of certificate (`pbaiacontrol`) loaded without a proxy is the control, which the system does fetch and the capture must see (§4a) |
| Profile export and import | a profile whose sealed WebKit store holds a cookie is exported to a `.pbprofile` file (in which neither the cookie nor the profile's name is readable; a wrong password opens nothing), imported as a new profile, and the new profile's first request carries the cookie |
| Proxy: 407 without credentials | the launch is refused ("needs credentials") and the data is sealed again; nothing opens, directly or otherwise |
| Proxy: `Accept-Language` | the header the proxy sees is the language the app decided at its first launch (`de-DE,de;q=0.9` in the self-test) |
| Time zone from the proxy | a profile with a proxy and *Time zone of the proxy's location* runs in the time zone the lookup through the proxy returned, cached per profile |
| Several SOCKS5 profiles at once | three profiles behind three SOCKS5 proxies, one with username/password authentication, are launched together through the app's launch path and load at the same time: each page arrives through its own proxy, by name, with its own credentials; after one stops the others keep loading through theirs; wrong or missing SOCKS5 credentials fail closed |
| Launch speed | with a location remembered for the proxy, a launch waits at most 1 s for a 4 s lookup (the lookup finishes in the background, and its new time zone is remembered and noted for the next launch); with nothing remembered it waits at most 3 s |
| Proxy list checker | observed in CI run 394, both builds (the end-to-end check through the HTTP proxy with a login: run 395): the probe tells every listener of the self-test proxy apart — HTTP CONNECT listed as SOCKS5 and SOCKS5 listed as HTTP each found as what it is, the login of the HTTP and the SOCKS5 proxy not given (needs a login), wrong (rejected) and right (taken), the IPv6 listener, a listener that takes the connection and never answers (silent), a closed port (refused), a host name that does not exist (host not found); end to end through a working proxy listed with the wrong type, the exit IP, country, time zone, city and network the stand-in service gave and the probe's median latency, and the exit IP, country and city through every other listener that works (SOCKS5, both with their login, IPv6); through an unreachable proxy, and one whose host does not resolve, it is dead, and a real website among the services, which a direct request would reach, did not answer either (the unreachable proxy's check connected to nothing else, as the URL loading system reports it — shown only where the same report listed the working proxy's connection); a proxy answering 407 to a check without credentials is dead for that reason; settings that cannot be applied are not checked (no request); the list's model checks several at a time and keeps the results encrypted, gives a line without a scheme the type found and corrects a wrong one; a profile given a checked proxy knows where it exits before its first launch; a profile started with the silent proxy says why (silent), one with a working proxy says nothing, and Check from there is the list's check. All of it but the unknown host runs in an egress window: the capture fails on any packet of the app past loopback, and on a DNS question for the service's name, which carries the run id (the unknown host's name is the control that says whether such a question for a `.invalid` name reaches the network at all) |
| Proxy exit IP | with *Warn when the proxy's IP changes* on, a changed exit IP (same proxy and credentials) is reported, the first launch and an unchanged IP are not; the option is off by default and then nothing is reported or stored, and turning it off, or replacing the proxy, while a lookup is under way leaves no new IP stored and nothing reported |
| Password AutoFill | in a profile window on the self-test proxy's sign-in pages: the page world has no `window.webkit` and no trace of the script; a password a page script wrote and submitted is not offered; a typed sign-in is offered (Save, saved with its user name), a new password for it as Update, nothing anywhere on the site after Never for This Website; a login field lists the site's saved login and choosing it fills both fields with `input` and `change` (and `:autofill` where WebKit allows the world); a filled-in login submitted again asks nothing; a sign-in by script (fields removed after the button's click) and a sign-up form (new password = confirmation) are offered; a frame of another site is offered none, a frame of the same site its logins under a header naming it. On the CI runner synthesized mouse events do not reach the page (the warm-up's clicks do not either), so a click never focuses a field there, and typing is stood in for by marking the fields typed inside the isolated world — a SKIP line, "a person's own clicks and keys reach the sign-in page", expected on the runner; key events sent to a field that already has the focus do reach it (Paste as Typed's check, CI run 426); real clicks and keys are used where they arrive |
| Cookie import | a Netscape file with CRLF, comments, an HttpOnly line and damaged bytes: the five readable cookies are read, the four other lines reported (field count, public suffix, expired, damaged text); into a stopped profile they are queued encrypted (no cookie value in the file) and put into its store at launch before the start page is requested: the request carries the host-only, domain, HttpOnly and session cookies, not the Secure one or another path's over http; the store holds each with the file's attributes; a cut-off JSON export's complete entry goes into the running profile at once and the next request carries it; after a stop (sealed) and a launch the persistent imported cookies are back and the session cookie is not; a stopped profile's session cookie does not come back at its next launch, with no other profile running and while another keeps running |
| Profile sync (two devices) | a second vault bootstrapped from a sync folder with the master password stands in for another Mac: a cookie imported into the stopped profile on A joins the synced cookies at its launch, a page's persistent cookie at its stop (its session cookie not); the folder holds no cookie name, value or domain; on B the start page's first request already carries both; B's change of one and deletion of the other reach A's store before its first page; settings changed on both, B's later: B's on both Macs, A's kept as `config.bin.conflict` |
| Session warm-up robot | through the app's launch path behind the self-test proxy, with short waits: a plan of three pages, a `javascript:` line (skipped) and a page the proxy closes unanswered (reported, the robot goes on) is visited in order in a new tab of the profile, each page taken as visited only once it has come (never before the proxy was asked for it), and an address that only jumps within the page shown at once (also when the page then rewrites the fragment); the requests carry the profile's User-Agent and the cookies the pages before set; at the proxy, each page's followed link comes at least the plan's time after the page, and the next page at least half that after the followed one; each page is scrolled (the pages see trusted scroll events); from each page only the plain same-site link is followed, with the page as Referer — never the sign-out, other-site, file or new-window links next to it; while the robot scrolls and clicks, each page's own world sees no `window.webkit` and no robot global; history and the pages' cookies are kept; Stop during a page ends the run before its next page is requested; closing its tab and a page's alert stop it; stopping the profile stops it first (while its store is still there), and the profile's data then seals as usual. Whether wheel and mouse events reached the page or the script fallback was used is reported |
| Warm-up queue and report | two stopped profiles queued with one plan through `WarmUpCoordinator` behind the self-test proxy: they run one after the other and never both at once, each without a window of its own, and each is stopped and sealed before the next starts; the report of each run counts the profile's cookies per site (registrable domain) — two sites with one new cookie each for the first, and for the second, which already held a cookie of the site it visits, two cookies there of which one is new; a run from the queue counts as the profile's last run for its schedule, stored encrypted |
| Paste as Typed | in a profile window, with a page's field focused: the palette's search finds what is typed; a page with no field focused gets nothing and is told so; a window without the keyboard gets nothing. Where this machine delivers synthesized key events to a page — a control key, sent as the password checks send theirs, arrives — the text arrives as typed: a trusted `keydown` per character on its own key (`H` on `KeyH`, `М` on `KeyV`), `Shift` down and up around capitals, `input` and `keyup`. Where the control does not arrive, or the window has no keyboard, the typing checks are SKIP lines, counted and named in the summary (the run ends INCOMPLETE). On the CI runner (macOS 26.6, run 426) the window was the key window and the control arrived: the typing was checked in full. In Safari's own window (a profile's process) the item is checked to be in Safari's Edit menu |
| What sites see | the snapshot's listener on 127.0.0.1 serves its own page and refuses another token and a name that is not this Mac's; a profile's window (no proxy, its local requests protected) measures navigator, screen, the window, the request headers in their order, a ClientHello (JA3, JA4) and the APIs, and its ClientHello is a plain WebKit view's; the page is not in the profile's history and its window closes. Separate CI steps take a new profile's snapshot next to the runner's real Safari: with the sandboxed build in this app's window, and with the build without the App Sandbox in Safari's window, with an HTTP proxy and without one (§2, *What sites see*) |
| ⌘Q | `terminate:` returns at once; every profile is sealed in the normal run loop; the second `terminate:` exits; WebKit released the store (normal seal, not forced); the sealed data restores |
| Forced seal | a store WebKit keeps through every retry is archived and its plaintext deleted only when quitting; a marker makes the next launch discard later residue; the archive restores |

Run it yourself: `build/Lumen.app/Contents/MacOS/Lumen --self-test`. For the
proxy checks, start the self-test proxy as CI does,
`python3 scripts/selftest_proxy.py --http 18080 --socks 18081 --http-auth 18082 --http6 18083 --socks2 18084 --socks-auth 18085 --tls-control 18086 --canary 18087 --silent 18088`,
and set `PB_SELFTEST_HTTP_PROXY_PORT=18080 PB_SELFTEST_SOCKS_PROXY_PORT=18081
PB_SELFTEST_HTTP_AUTH_PROXY_PORT=18082 PB_SELFTEST_HTTP6_PROXY_PORT=18083
PB_SELFTEST_SOCKS2_PROXY_PORT=18084 PB_SELFTEST_SOCKS_AUTH_PROXY_PORT=18085
PB_SELFTEST_TLS_CONTROL_PORT=18086 PB_SELFTEST_CANARY_PORT=18087 PB_SELFTEST_SILENT_PROXY_PORT=18088`.
Without a variable its checks (407, IPv6, several SOCKS5 profiles at once, the certificate control,
the loopback canary, the silent proxy) are skipped — each one said, as below. The self-test uses a
temporary vault and removes everything it creates.

**A check that could not be made is never a pass, and never quiet.** Where a check cannot be made
here — a listener of the self-test proxy not started, no keyboard for the self-test's window, a
WebKit without the feature, the sandboxed build that cannot host Safari's frameworks — it prints a
line of its own, `SKIP <check> — <why> (on this machine | in this build)`, is counted, and is named
again at the end, after the summary:

    SELFTEST INCOMPLETE: 398 passed, 0 failed, 3 skipped (3 on this machine, 0 in this build)
    SELFTEST SKIPPED (on this machine): paste as typed: … — this Mac gives the self-test's window no keyboard …

A run with a check skipped on this machine ends `INCOMPLETE`, not `PASSED` (exit code 0: nothing
failed, but not everything was shown); with failures it ends `FAILED`; one skipped only in this
build (by design: the sandboxed build) still ends `PASSED`, its skips listed. With
`PB_SELFTEST_STRICT=1`, as CI runs it, a check skipped on this machine fails the run, but for those
`PB_SELFTEST_EXPECTED_SKIPS` names (`.github/workflows/ci.yml`: what a GitHub runner cannot do — a
person's own keys reaching a page, which the AutoFill checks then stand in for, and the touch icon
and OpenSearch description Safari does not fetch there); each of those is still a SKIP line, and
every skip is a warning on the CI job and a line in its summary.

A check that something did *not* happen — no ping, no connection, no XPC service, nothing written —
is only as good as what watched for it. Each such check shows first that its observer saw its own
control, or it is skipped: the ping checks, the same click in a plain web view without the rule
list, whose ping must reach the proxy; the loopback canary, a connection of the self-test's own
that the canary listener must list; the XPC watch, the profile's own web content process starting;
the proxy checker's "connected to nothing but it", the working proxy's connection in the same
report; the profile's process's report, an answer and not a missing value (a `nil` is a skip). In
CI the same holds for the scripts around the self-test: the egress capture fails as SKIPPED when a
control of its was never seen or there is nothing to look in (each build now has certificate names
of its own: up to run 523 the intermediate the sandboxed build fetched stayed in this Mac's cache,
and the capture around the unsandboxed build never saw the control on macOS 26); so do the file
trace (§4a, its cfprefsd canary), the menu walk and the comparison with the real Safari; the
QUIC/WebRTC leak check, which depends on sites on the internet, lists what it could not show as
SKIPPED and goes on.

The capture, the file trace and the crash-report search tell the app's processes by their name,
which is the executable's (a profile's own process runs the same one). None of them has it written
in: the capture and the trace take it from the self-test's `INFO egress-process <name> <pid>`, the
menu walk from the app's Info.plist. And each shows that the name finds the app before it is
believed: a control packet of the capture must carry it (the proxy checker's question, asked for the
self-test's own process), the trace must name writes by it, and the crash-report search must find
the report of the self-test's deliberate crash (its exception check, on the queue
`PBExceptionCheck.background`). Otherwise each is SKIPPED and fails: a renamed executable that one
of them was not told about would have made it look at nothing, and pass.

## 1. Storage isolation between profiles

**Mechanism.** Each persistent profile uses `WKWebsiteDataStore(forIdentifier: <profile UUID>)`.
Each ephemeral profile uses `WKWebsiteDataStore.nonPersistent()`. Every `WKWebView` of a
profile gets that store: every tab of every window, and popups, because
`createWebViewWith` uses the configuration WebKit passes in, which inherits the opener's
store.

**Isolated per store, by WebKit:** cookies, localStorage, sessionStorage, IndexedDB,
Cache API, service worker registrations, the HTTP disk and memory cache, HSTS state,
media keys, the per-session credential store, and Intelligent Tracking Prevention
classification.

**Within one profile:** all tabs share the profile's storage, like tabs in any browser.
Background tabs keep running. WebKit may throttle timers in views that aren't in a window.

**Shared between profiles:**

| Shared | Why | Effect |
|---|---|---|
| WebKit networking process | WebKit runs one network process per app, with one session per data store inside it | Isolation is per session (logical), not per OS process |
| Device fingerprint | see §2 | Profiles can be linked by fingerprinting |
| Downloads folder | Downloads go to `~/Downloads` in plaintext — or the folder Settings → Downloads names, or where the save panel is told (asking each time) | Outside the encrypted storage |

## 2. Fingerprinting and "Apple device" consistency

**Short answer:** every profile runs on the macOS system WebKit, so to a site it *is* Safari-on-a-Mac.
That is genuine, not emulated. What a profile can change is the small set of attributes
the profile *declares*. What it cannot change is what the engine and the hardware *measure*.
This project does not make a Mac look like an iPhone, and doesn't claim to.

### Parity with Safari: the project's rule

How a profile is brought closer to this Mac's Safari — which interfaces a page finds in it, and
what they answer — is decided by one rule, for every change, not case by case:

1. **WebKit's own code, never JavaScript objects.** A difference is closed only by turning on
   what WebKit itself implements: a WebKit preference or feature, as Safari sets it. Nothing is
   written in JavaScript to stand in for an interface a profile lacks — no `ApplePaySession`,
   `PaymentRequest`, `PushManager` or `RTCPeerConnection` made by a script, however faithful its
   shape.
2. **Only when its answers are a real Safari's.** What is turned on must answer as Safari answers
   in some real state of a real Mac: every call a page can make, its result, the type and text of
   its error, in the page, in frames and in workers. An interface that is there and answers what
   no Safari answers is not turned on — a page that calls it finds it as easily as one that finds
   it missing. What cannot be measured stays off.
3. **Nothing changes from profile to profile by chance.** What is turned on for parity is the
   same in every profile and on every run; none of it is drawn at random. Profiles differ in what
   the user sets for them (the table below), not in what parity turns on.
4. **Counts and property lists are never edited.** `Object.getOwnPropertyNames(window)` and its
   length, the properties of a prototype or of `navigator`, the keys of any object: none is
   hidden, added to or reordered. They follow from what WebKit has turned on, and from nothing
   else.

A difference that cannot be closed this way stays, and is listed (*What still differs*, below).
The rule is about parity — what a profile has of Safari's. It does not cover the attributes a
profile declares (time zone, geolocation, relay-only WebRTC: the table below), whose wrappers are described where they are, and it lets no
wrapper of that kind be added for parity's sake. Noise — values made to change, in canvas, WebGL,
audio or anything else — is not parity and is not added (*What remains impossible with public
APIs*). A change under this rule is described against it and decided before it is written, and
CI measures it against the runner's real Safari (*What sites see*, *Measured against this Mac's
Safari*).

**Where the code does not follow it yet** (found when the rule was written down; each waits for a
decision before anything changes):

- `window.safari`: a macOS profile's privacy script makes Safari's `window.safari` — its
  `pushNotification` object, `permission()` and `requestPermission()` — in JavaScript when a page
  has none (`patchSafariObject` in `PrivacyScripts`): a stand-in for an object of Safari's, and one
  of the window's own properties (rules 1 and 4). Only where the Safari the profile names gives
  pages one: measured in a plain Safari window, Safari 27.0.1 does and Safari 27.2 does not
  (`scripts/window_safari_check.py`; 27.1 unmeasured, counted with 27.0). Until 8 November every
  profile had it, the iPhone and iPad views too — a mark no real browser gave: the owner's iPhone
  has none, nor his Mac's Safari.
- The storage quota of an ephemeral profile: the same script wraps `navigator.storage.estimate()`
  to answer Safari's quota (`patchStorageQuota`) where WebKit answers an app's 1000 MiB (rule 1).
  A persistent profile no longer needs it: its store is made with a browser's ratios and WebKit
  answers Safari's figure itself (`BrowserStorageQuota`; the script leaves any larger figure alone).

**WebKit's behaviors that follow the SDK.** WebKit turns some of its features on for an app only
when the app's executable declares a recent enough SDK (`linkedOnOrAfterSDKWithBehavior`), and for
Safari always (WTF's `computeSDKAlignedBehaviors` returns every one when the process is Safari);
AppKit and the other frameworks follow the declared SDK too. Xcode 27's SwiftPM gives the linker the
deployment target as the SDK (`-platform_version macos 14.0.0 14.0.0`; Xcode 26's gives its SDK,
26.5), so a build made with Xcode 27 declares "sdk 14.0" — measured on the owner's build with Xcode
27.1 — and its pages lacked what Safari's have, on macOS 27 (CI run 448, `scripts/sdk_check.sh`)
and on macOS 26 alike (run 500, a copy declaring 14.0): by the window's own properties,
`trustedTypes` and the five Trusted Types interfaces; and they had `MutationEvent`, which Safari no
longer has, mutation events fired, and `new FontFaceSet([])` constructed where Safari's throws.

**A profile's web views have the features the SDK's behaviors change as Safari has them.** Of
WebKit's 600-odd features, the behaviors change four for a build declaring 14.0, on macOS 26 and
27 alike (runs 495, 497 and 500: every feature's default as built and with every behavior on):
Trusted Types, on in Safari; DOM mutation events, the legacy `FontFaceSet` constructor and the
near-suspended assertions on background web content processes, off in Safari. `SafariEngineFeatures`
sets the four one by one with WebKit's own switches, in every web view of a profile — ours, those
Safari's chrome builds and the service workers' (`applyPrivacyPreferences`). Measured against the
real Safari 26.6.2 and 27.0.1 with one page from a local server (runs 497 and 500): with the four set,
a page sees what it sees with every behavior on — the same window names, Trusted Types policies that
make a `TrustedHTML`, no `MutationEvent` and no mutation event fired, an illegal `FontFaceSet`
constructor — and differs from Safari's only by the names Safari's entitlements and Safari itself
bring (Apple Pay and payment requests, push, `DigitalCredential`, `MediaSessionCoordinator`,
`browser`, `safari`). And this Mac asked for no certificate outside the proxy: in run 497 the AIA
canary went unasked for twice with the four set, its control seen, and was asked for with every
behavior on. Only on the macOS versions measured (26 and 27); on another WebKit's defaults are left
as they are. CI fails the macOS 26 build when a feature the behaviors change is not set as Safari
has it, or a page in a profile's web view differs from one with every behavior on — for the build
as made and for a copy declaring 14.0, the releases' SDK (`scripts/engine_features_check.py`) — and
reports the same on macOS 27.

**The executables declare the SDK SwiftPM writes, not macOS 27's, and the app does not use
`+[WKProcessPool _setLinkedOnOrAfterEverything]`** (WebKit's own switch for every behavior, made for
Safari). On macOS 27, from macOS 15's SDK on, a profile with a proxy has this Mac fetch a
certificate's missing intermediate outside the proxy: the self-test's AIA canary — the address a
certificate names for its missing intermediate — was resolved by this Mac, caught by the egress
capture, in run 448 with the switch and in run 450 with the executables declaring macOS 27's SDK
(runs 447 and 449, declaring 14.0, were clean). Run 451 measured it per SDK WebKit gates its
behaviors on (`scripts/aia_variants.py`: the certificate check alone, each variant with certificates
of its own naming addresses no earlier variant used, and its control — a profile without a proxy,
for which the system does fetch — seen in every one): **clean with 14.0, 14.2 and 14.4; the canary
fetched with 15.0, 15.2, 15.4, 15.5, 26.1, 26.5, 26.6 and 27.0**, and with the switch. 26.5 is what
a build made with Xcode 26 declares: such a build leaks on macOS 27. Builds made with Xcode 27
declare 14.0 (its SwiftPM writes the deployment target), and `scripts/release.sh` refuses to release
a build that declares 15.0 or newer. CI's macOS 27 job fails the build when this Mac asks for the
self-test's certificate canaries (`scripts/certificate_leak_check.py`), the one thing that job fails
on: a change that had every build fetch (run 458, below) went through while it failed nothing. CI's
macOS 26 job builds with Xcode 26, whose executables declare 26.5: it runs the self-test of the
build without the App Sandbox — the one inside its capture and file trace — as a copy declaring
14.0, as a release does, and measures the build as made in a step of its own (which reports the
fetch every run). Up to run 524 its self-test ran the 26.5 build, and its capture, which until then
could not see such a fetch on macOS 26 (§0: the sandboxed build had fetched the intermediate first,
and this Mac kept it), passed; run 524, with names of its own for each build, saw the 26.5 build's
fetch and failed. The sandboxed build's self-test there still runs as made (26.5): a re-signed copy
would be another app to its container. The
capture names this app, not WebKit's network process, as the one the fetch was made for. How it
comes about was measured in runs 491 and 492 (measurement branch `claude/measure-sdk-trust`): not
WebKit's network loader — its switch, `CFNetworkNetworkLoaderEnabled`, set either way, changed
nothing — and not past the profile's own answer: with every behavior on, the server-trust
challenge still reaches the profile, which answers it (cancel, the trust evaluated without
fetching, `ServerTrust`), and some 3 ms after that answer this Mac asks for the canary on behalf of
this app's process, about 25 ms before the load's provisional failure, whether or not anything
reads the error. With every behavior on, that error carries the server's trust and its certificate
chain (as built it carries neither), which points to WebKit building the chain in this process from
a trust allowed to fetch — the timing and the error say so; the call itself was not traced. No
setting of the session or of the data store forbids that fetch
(`_WKWebsiteDataStoreConfiguration` has none; this app's own `NSURLSessionConfiguration` has
`_usesNWLoader` and `_alwaysPerformDefaultTrustEvaluation` off). So the executables keep declaring
14.0, and the page-visible features are set one by one (above). A first try at telling it from
inside this process — reading, as a certificate's question came, whether its trust had been
evaluated and whether it might fetch — had the trust evaluated by that reading itself, fetching
allowed: in run 458 every variant leaked, 14.0 included, and the self-test's capture caught the
canary; the reading was taken out (runs 451 and 454, without it, had 14.x clean). Nothing reads a
trust before its fetching is off (`ServerTrust`). The first version of that measurement
reused one name for every variant and read clean where the full self-test leaked (run 450): in its
variants not even the control was asked for. On macOS 26 the capture has not seen the system fetch
for the control in any of the eight runs read, so there the check cannot tell: whether a build
declaring 26.5 fetches on macOS 26 is not known. CI shows what follows the SDK on each runner: the
app as built and a copy declaring another SDK, by the window's own properties and the screen, with
the app's screens rendered from both (`--sdk-check`, `scripts/sdk_check.sh`); and which SDK SwiftPM
writes, built four ways (`scripts/swiftpm_sdk_probe.sh`).

`DigitalCredential` and `MediaSessionCoordinator` do not follow the SDK: WebKit turns them on only
for a process with an entitlement Apple grants (`com.apple.developer.web-browser`,
`com.apple.developer.group-session.urlactivity`). Nor, by CI's measure, does the screen's
available height: the visible frame AppKit gives WebKit (`screen.availHeight`) moved its bottom edge,
where the Dock is, by 3 points between runs of the same build, whatever the SDK declared, and was the
same for every SDK once it had moved (CI run 448, macOS 26 and 27).

### What the public WKWebView / WebKit APIs let a profile control

| Attribute | Mechanism | Reach |
|---|---|---|
| Storage (cookies, localStorage, IndexedDB, cache, service workers) | `WKWebsiteDataStore(forIdentifier:)` | native, complete |
| Egress IP and DNS | `proxyConfigurations` (SOCKS5 remote DNS, fail-closed) | native, verified |
| User-Agent string (HTTP header + `navigator.userAgent`) | `customUserAgent` | native; changes the string only |
| Time zone | JS shim (`Intl`, `Date` getters, offsets) | approximation; blob workers covered, URL-loaded and service workers not |
| Geolocation | In a profile's own process (the released build): the engine itself (`NativeGeolocation` — WebKit's geolocation provider and its permission question), no script in the page. Elsewhere: JS shim (deny / fixed coordinates) | engine-level in Safari's window; approximation in the app's own windows |
| WebRTC exposure | off in the engine (private `WKPreferences` property, as Lockdown Mode) or a JS shim (relay-only) | native when off; approximation for relay-only |

Keep the declared attributes consistent with each other: a Safari UA, plus a time zone and
geolocation that match the proxy's exit location. An inconsistent combination, such as a
Chrome UA on WebKit or a Tokyo time zone behind a Paris exit, is itself distinctive.

### Version-aware profiles (device generations)

Projects like iStealth tie a profile to a specific OS version and swap the browser *core*
when Apple ships a new one. With public APIs we can do the version *tagging* but not the
core swap. A profile carries a **device generation** (`DeviceGeneration` /
`DeviceGenerations` in `BrowserCore`): a target Apple OS version — currently macOS 26,
iOS 26, iOS 27, iPadOS 26 — chosen with the **View for websites** picker in the editor and
stored in the profile (`deviceGenerationID`, encrypted like the rest).

What a generation actually does, and only this:

- supplies the self-declared `User-Agent` for that version (overridable with a custom UA): the
  string Safari sends there. Safari on iOS 26.1 and later freezes the OS token at `18_7` (as
  macOS Safari freezes `10_15_7`; WebKit bug 298260), so an iPhone profile sends
  `iPhone OS 18_7 … Version/26.6` (iOS 26) or `Version/27.0` (iOS 27); `iPhone OS 26_0`
  is a string no Safari sends. iPadOS Safari shows desktop websites by default, so the
  iPad view sends the Mac's UA;
- for the iPhone and iPad views, sizes the window to that device's screen — and nothing else.
  A **mobile view** (as the editor names it) is Safari on this Mac under that device's
  User-Agent, which is a real state, Safari's own Develop › User Agent: `navigator.platform`,
  the touch points, the screen and every other value a page measures stay this Mac's (the
  owner's decision, 31 October). Until then an iPhone profile was also told `platform`
  "iPhone", five touch points and a phone's screen: a page told it was on a phone without
  touch events registered its handlers on `touchstart` and never got one, and the mix matched
  no device at all. The editor says what a mobile view is next to the choice, and What Sites See
  says it has no reference for one, with what it cannot see of the real device (touch, fonts,
  graphics, audio, motion sensors, the screen) instead of "the same";
- seeds per-profile defaults (e.g. WebRTC policy) when a new profile picks it;
- names a **behaviour set** (`behaviorSetID`) — the injected-script bundle. This is an
  extension point (`BehaviorSets` in the app layer). Today every generation resolves to the
  same WebKit shims, because with the current public API the observable behaviour does not
  differ by declared version. When a future WebKit ships behaviours worth matching (and the
  public API to do it), a new behaviour set is registered and new generations point at it,
  with no change to the profile format.

What it does **not** do, and cannot:

- It does not switch the real WebKit core. The engine is always the Mac's system WebKit;
  there is no public API to load an older or iOS WebKit build, and running a second engine
  is out of scope. So a profile tagged "iOS 26" renders with the host Mac's WebKit, whatever
  its real version.
- Only the macOS generation is engine-consistent, and only when its version equals the Mac's
  real Safari version (the editor still shows the string, which may differ from the host's).
  A macOS profile may name another Safari version in its User-Agent (editor → Identity →
  **Safari version in the User-Agent**: Auto, which follows this Mac's Safari, or a recent
  release, `ProfileConfiguration.safariVersion`): only "Version/…" in the header and in
  `navigator.userAgent` changes (checked by the self-test in a page), never the engine. The
  editor says so beside the choice, and marks a version of another major release than this
  Mac's as risky — what a page measures (features, CSS, JavaScript) is still the engine's.
  The iPhone and iPad views change the UA string while every measured signal in the table
  below says "desktop Mac" — the editor says so in as many words.

Compared with a deeply integrated product that ships and switches genuine per-version WebKit
cores, this is version *labelling*, not version *emulation*. It is honest about being
Safari on this Mac.

### What sites see (a profile next to this Mac's Safari)

A profile's ⋯ menu, its inspector (**Check the profile**) and the command palette open the
profile's check (docs/ARCHITECTURE.md, "The profile's check"); the sheet's second tab, **All
signals**, is this snapshot, and the profile editor's **What Sites See…** opens it alone. On its
button, one page of this Mac opens in a new window of the profile — and only on the person's **Compare with Safari…**,
whose note says that this Mac's own Safari will open, not a profile, the same page in a new tab of
Safari — and in each runs the scripts CI's live comparison runs (`scripts/live_compare.py`): the fingerprint probe
(`Resources/fingerprint_probe.js`), the window's geometry, the request headers in the order the
listener received them, and the APIs a WebKit app may answer differently
(`Resources/SiteProbes/`, bundled with the app and read by CI from there). The page then makes an
https request to a second port of the listener, which reads the ClientHello — versions, cipher
suites, extensions in their order, groups, signature algorithms, ALPN, server name, JA3 and JA4,
GREASE left out (`TLSClientHello`) — and closes the connection: a ClientHello is what any https
server sees before anything is encrypted, and reading it takes no certificate. The page posts its
report to the listener, and the two reports are listed signal by signal, grouped as navigator,
screen, window, request headers, TLS, APIs and rendering: **same**, or **differs** with both
values and, for known differences, what they mean (`window.safari`, which Safari up to 27.1 has, and the Apple Pay interfaces
only Safari has, the height of the window's bars, a built-in function that a profile's wrapper
changes). The window's own size and place are shown and not compared — each browser's window has
its own; what the bars take of it ("chrome") is compared.

**Local, on the button only.** The listener (`SiteSnapshotServer`) is on 127.0.0.1 only, on two
ports the system picks, for as long as the snapshot takes; it answers only the snapshot's own
tokens and only requests that name this Mac by its loopback address (a page's name that resolves
here — DNS rebinding — is refused). The page, its scripts, its requests and the reports never
leave this Mac, and nothing is kept: the comparison is shown and gone with the sheet. In the
sandboxed build this needs `network.server` (§9). The page is not written to the profile's
history; a profile of this process closes the page's window when it has reported, a profile in
Safari's own window leaves it to the user (the page says it is done), and that window's own
History menu, which Safari keeps in the profile's home (sealed with it), can list it as it lists
any page. Safari opens the page in a tab of its own, as any page, and keeps it in its history.

**What it does not measure.** HTTP/2 settings and the TCP SYN (they take a site's own server; CI's
live comparison reads them on tls.peet.ws), and anything a third-party fingerprinting site adds on
its own. Safari is the user's Safari as it is — its window, its extensions, its settings — so a
difference can be Safari's (a window of another size changes nothing compared; its bars do). A
Safari that does not answer within 90 seconds leaves the profile's values listed alone.

**Measured on the CI runner** (macOS 26.6.2, Safari 26.6.2, the sandboxed build, run 426), a new
profile without a proxy next to Safari: navigator 22 of 22, screen 9 of 9, the window's bars 1 of 1,
request headers 31 of 31, TLS 9 of 9 and rendering 17 of 17 the same; of the APIs 407 the same and
11 not — WebRTC's interfaces, off in a profile by default (`RTCPeerConnection`, `RTCDataChannel`,
`RTCEncodedVideoFrame`, `RTCRtpScriptTransform`), Apple Pay's and Payment Request's, which only
Safari has (`ApplePaySession`, `ApplePaySetup`, `MerchantValidationEvent`, `PaymentRequest`),
`PushManager`, and with them the count of the window's own properties (1006 against 1044). The
window's own size and place differed, as two windows do, and were not compared.

That profile was in this app's own window, with no proxy: not what a customer's profile is. In the
build without the App Sandbox a profile runs in a process of its own, in Safari's window, whose
web views Safari's own code builds — Safari's preferences, with the profile's store, privacy
preferences and scripts put into them (`SafariChromeHost`) — and a customer's profile has a proxy,
which turns more of WebKit off (`BrowserSession.featuresOffWithAProxy`). CI measures that case
too: a new profile with an HTTP proxy in Safari's window, and one without a proxy in Safari's
window to tell the window's part from the proxy's (the steps under *Checked by*).

**Checked by** unit tests (a ClientHello parsed as a server reads it, also across two records;
JA3 and JA4 against values computed apart from the code; what is not a ClientHello; the report
flattened; the comparison and its groups; the page's escaping), the self-test (the listener
answers its own page and refuses another token and another name; a profile's window, its local
requests protected, measures every part — navigator, screen, window, headers in order, a
ClientHello, APIs; its ClientHello is a plain WebKit view's; the page is neither in its history
nor left open; all of it inside the egress capture), and CI's three "What sites see" steps, after
the capture, each a new profile's snapshot next to the runner's real Safari
(`--what-sites-see-check`): the sandboxed build's, a profile in this app's window; and the build's
without the App Sandbox, a profile in Safari's window (`--safari-window`, refused when the window
would not be Safari's) with an HTTP proxy (`--proxy 127.0.0.1:9`: nothing answers there; the
measuring page is on this Mac and loads directly, and the proxy's location is not found, so the
profile keeps this Mac's language and time zone, as Safari does) and without one. Each prints the
count of the window's own properties on both sides, every group's summary and the signals that
differ, as notices on the job; a Safari that does not answer is a warning.

Until 1 November the snapshot opened Safari by itself, every time (the owner's finding): a window
of the person's own browser, outside every profile, that nobody had asked for. Everything this app
hands to the system — an address to another app, a folder to the Finder, System Settings, the
update's installer — now goes through one place, `SystemOpen`, which names each kind with why it
is allowed and refuses all of them in a profile's own process; `scripts/check_system_opens.py`
fails CI on any other call (and its self-check fails unless it finds each forbidden form planted
for it). The self-test takes a snapshot and checks that nothing was handed to the system, then
compares with Safari and checks that exactly one address went — the measuring page, for Safari —
and asks `SystemOpen` from a profile's own process, which must refuse.

### What remains impossible with public APIs

FINGERPRINTING LIMITATION. Each of the following would require private WebKit API, a
modified WebKit, or different hardware. None is attempted:

| Signal | Why a profile can't change it |
|---|---|
| Canvas 2D / WebGL pixels, WebGL renderer and vendor strings, extensions, limits | produced by the Mac's GPU and driver; WebKit exposes them as is |
| AudioContext output | the Mac's audio stack |
| Text drawn into a canvas (`fillText`, `measureText`), and so every canvas hash that includes text | the glyphs come from macOS's fonts and its text rasteriser; an iPhone draws the same string with iOS's, so the pixels and the widths differ. Making them an iPhone's would mean forging the pixels a page reads back, which this project does not do: an honest limit of an iPhone view, as decided by the owner on 8 November |
| The window's own properties and the interfaces a page can find (`Object.getOwnPropertyNames(window)`: 950 on the owner's iPhone, 1008 in an iPhone view, 1045 in his Mac's Safari, 8 November) — one of the differences, `window.browser`, closed since (every profile has WebKit's own, as Safari) | they follow the features this Mac's WebKit is built with, which are not iOS WebKit's: an iPhone view can take away what a script may take away, but cannot add what iOS has and the Mac's engine lacks, nor make the count an iPhone's. An honest limit of an iPhone view, as decided by the owner on 8 November |
| Fonts (measured via text metrics) | macOS system fonts; iOS has a different font set. As in Safari, fonts the user installed are hidden from pages (the WebKit preference Safari sets, `_shouldAllowUserInstalledFonts`; it has no public API, so it is applied only when this WebKit has it, which the self-test checks) |
| Screen size, colour depth, device pixel ratio, `matchMedia` results | the real display. The device pixel ratio has a per-view override, WKWebView's `_overrideDeviceScaleFactor`: an iPhone view renders at an iPhone's 3× and says so, `resolution` media queries included (`PhoneEngine`, measured on macOS 26 and 27). The screen has no override a WKWebView can reach on the Mac (WebKit's `setOverrideScreenSize` is called only by the Web Inspector). WebKit's screen-size override exists only on iOS (`WebPageCreationParameters.overrideScreenSize`, iOS-only in WebKit's source); on macOS `screen.*` and CSS `device-width` both come from the window's real `NSScreen`. An iPhone view's full disguise says an iPhone's screen to scripts (`screen.*` and `matchMedia('(device-width…)')`, below); CSS `@media` in a stylesheet still sees this Mac's. So a profile's **window size** (editor → Window: a MacBook's screen, a size of its own, or a random size for a new profile) is a real window — a page measures it (`outerWidth`, `innerWidth`, its viewport), checked by the self-test against the window's frame — and the screen stays this Mac's: a declared screen would be given away by CSS `device-width` and by full screen. A size larger than the screen opens as large as the screen allows, and the editor says so |
| `navigator.platform`, `vendor`, `maxTouchPoints` | engine and hardware; `customUserAgent` changes only the UA string. A Mac profile and the iPad view keep the native values. An iPhone view's page and frames say `platform` "iPhone" with the engine's own getter — WebKit's `_customNavigatorPlatform`, the setting Safari uses for an iPad's desktop sites (`PhoneEngine`, measured on macOS 26 and 27); its workers keep "MacIntel" (`NavigatorBase::platform`), which only a script changes. `maxTouchPoints` has no setting on the Mac (WebKit's is iOS-only); an iPhone view's full disguise says 5 by a script (below) |
| `navigator.hardwareConcurrency` | WebKit's own answer from the processor count it is given: 4 below 8 cores, 8 from 8 up (`NavigatorBase::hardwareConcurrency`), so most Macs say 8 and a real iPhone 4. An iPhone view's process gives its WebKit processes an iPhone's six cores (`DeviceGeneration.processorCores`, through libxpc as `__XPC_WTF_numberOfProcessorCores`, the way the time zone reaches them), so the page, its frames of any origin and every worker — blob, URL, nested, shared, service — say 4, with the engine's own getter; no script is involved. A Mac profile and the iPad view (the Mac's User-Agent) keep this Mac's count. Only where a profile runs in a process of its own (the released build); the self-test checks it on a stand-in ten-core Mac, a Mac profile as the control. Not hidden: how fast eight workers run side by side on this Mac's real cores |
| Touch and pointer behaviour, `ontouchstart`, orientation and motion events | macOS WebKit is a desktop engine; there is no touch-input emulation API (WebKit's touch events and its synthesised-touch mouse policy are iOS-only). An iPhone view's **full disguise** (editor → View for websites; on by default, decided by the owner on 8 November) does it by a script, the engine's way: an iPhone's screen (`screen.*`, `outerWidth`/`outerHeight`), five touch points, `Touch`, `TouchList`, `TouchEvent` and the `ontouch*` handlers, `touchstart`/`touchmove`/`touchend` dispatched from a press (a `PointerEvent` says `touch`; a click after a cancelled `touchend` is swallowed), `pointer: coarse` and `hover: none` (and `any-*`, `device-width`/`device-height`) in `matchMedia`, portrait in `orientation` and `screen.orientation` — the page, its frames and blob workers, accessors with the engine's shape. What it cannot reach: CSS `@media` in stylesheets (still the Mac's pointer, hover and screen), `env(safe-area-inset-*)`, workers loaded from a URL, `isTrusted` (false on a dispatched touch event), and the order of events against a real iPhone's (unmeasured). Off ("leave no traces of a substitution"), none of it is there and these stay the Mac's |
| `navigator.languages`, `Accept-Language` | one list per app run: WebKit reads it once, when its first process starts. The first profile launched picks it (its proxy's country, else the app's language); the shim never overrides `navigator.language(s)`, so header and script agree |
| Supported JS/CSS features, media codecs, WebKit version quirks | the installed macOS WebKit, which differs from iOS WebKit |
| TLS ClientHello, HTTP/2 settings, header order | Apple's macOS network stack |

**Why this project doesn't paper over these with JavaScript:** injected overrides for canvas,
WebGL, audio or fonts are unreliable. They don't reach workers, don't change server-side TLS
or HTTP signals, and leave measurable inconsistencies — fingerprinting pages flag the noise
itself ("Canvas: Spoofed", "Fingerprinting Resistance: Detected"). They also mainly serve
to defeat fraud and abuse detection, which is not a goal here. What the shims *do* replace
(time zone, geolocation, WebRTC) is replaced the way the engine defines it — accessors on the prototypes, strict methods with
only `length` and `name`, the native receiver errors, and a `Function.prototype.toString`
that prints them as native code even from a fresh iframe — so the replacement itself is not
the thing a page notices; the inconsistencies listed above still are. CI compares a macOS
profile's whole measured surface with this Mac's real Safari (`scripts/safari_reference.py`,
results below).
The honest options for real separation between identities are outside the browser:
- a separate macOS user account per identity (OS-level separation);
- a different Mac or VM per identity (different hardware fingerprint);
- for a genuine iPhone fingerprint, Safari on an actual iPhone.

### Measured against this Mac's Safari

Two CI steps compare a macOS profile with the runner's own Safari (macOS 26.6.2, Safari 26.6.2),
driving Safari through `safaridriver`:

- `scripts/safari_reference.py` runs `Resources/fingerprint_probe.js` in both: 434 keys identical,
  0 must-match keys differ.
- `scripts/live_compare.py` loads the same pages in Safari and in on-screen profile windows of the
  same outer size (`Lumen --capture-sites`, `SiteCapture.swift`), once for a default profile
  and once with the time-zone and WebRTC wrappers running on Safari's own values. Both JSON sets
  are kept in the `fingerprint-surfaces` artifact.

When Safari runs a WebKit of its own. A Mac whose Safari was updated beyond the WebKit the system
gives apps has two engines: CI run 718, a runner on macOS 26.7.2 with Safari 27.2, where the app
ran WebKit 21624.5.1.11.3 (Safari 26.6.2's) and Safari had WebKit 27's features and canvas. No
profile can be that Safari: pages are shown by the WebKit this Mac gives apps. Safari's own build
(its CFBundleVersion) is the build of the WebKit it runs — on macOS 26.6.2 and 27.0.1 the same as
the system WebKit.framework every app loads, measured — so the two are told apart by it, and a
profile then names the Safari of the engine it runs, not Safari.app (`SafariVersions.declared`;
before, it called itself Safari 27.2 on WebKit 26, a contradiction a page can measure). Settings ›
About says so, and so does the diagnostics report. The comparison says ENGINES DIFFER there,
compares nothing and checks only that the profile names its own engine's Safari; the comparison
on macOS 27 (`full.yml`, the owner's system), where Safari and apps share WebKit 22625.1.29.11.28,
is the one that holds a profile to Safari there.

Where Safari's engine lives, and why only macOS 27 ends it (measured on the runner image of 2
November, macOS 26.7.2, claude/measure-safari-engines). Software Update installed macOS 26.7.2, then
Safari 27.2 as a package of its own (`com.apple.pkg.Safari27.2TahoeAuto`). Safari 27.2 brought its
WebKit, WebCore and JavaScriptCore (build 21625.2.8.18.4) into Safari's part of the system, the App
cryptex: `/System/Volumes/Preboot/Cryptexes/App/System/Library/StagedFrameworks/Safari`. Safari and
its web processes load the engine from there — Safari's executable names that folder for the
dynamic loader (`DYLD_FRAMEWORK_PATH`, read in Safari 26.6.2's; Safari 27.2's processes were seen
loading from it). An app's web view loads `/System/Library/Frameworks/WebKit.framework`, which
macOS 26.7.2 left at 21624.5.1.11.3, as in 26.6.2. The machine restarted twice after Safari was
installed and once more for the job: still two engines. So a restart does not end it, nor does an
update of macOS 26; macOS 27, whose system WebKit is Safari 27's, does. On any Mac:

    defaults read /Applications/Safari.app/Contents/Info.plist CFBundleVersion
    defaults read /System/Library/Frameworks/WebKit.framework/Resources/Info.plist CFBundleVersion

Different builds: two engines. The app says so once in the profiles window for each pair of
versions, and always in Settings › About (`EngineWarning`). Not measured: whether Safari 27 comes to
a Mac on its own, without the person's say (the package's name says "Auto"; that proves nothing).

What `safari_reference.py` says, besides passing: NOT DRIVEN (Safari could not be driven, or its
probe came back short), DIVERGES (a must-match key differs, and a plain Safari window opened without
WebDriver says what WebDriver said, or could not be read), WEBDRIVER ONLY (every differing key reads
in a plain window as the profile has it), ENGINES DIFFER (above). Each fails the step under its own
name but the last (`scripts/test_safari_reference.sh`).

What is identical, key by key:

| Area | Result |
|---|---|
| Probe | UA (the profile declares the installed Safari's version), `navigator` (platform, vendor, hardwareConcurrency, `deviceMemory` undefined, maxTouchPoints, pdfViewerEnabled, the same five plugins and two MIME types — real Safari lists Chrome/Chromium/Edge PDF Viewer too, as the HTML spec requires — no own properties), language and `Intl` locale, screen and colour depth, pointer/touch media queries, time zone and offset, canvas pixels and PNG (the same data URL, byte for byte), canvas text, WebGL (vendor, renderer "Apple GPU", every extension and parameter), font metrics, `window.webkit`, the shape of `window.safari`, the toString text and shape of every native the shims touch |
| Window | `outerWidth/outerHeight`, `innerWidth/innerHeight`, `screenX/screenY`, `visualViewport`: the browser chrome is 52 px with one tab and 90 px with two, as in Safari 26 (unified toolbar; tab bar from the second tab, 38 px) |
| Network | request header set and order for navigations, `fetch` and XHR (31/31); TLS ClientHello (JA3, JA4, cipher and extension lists apart from the random GREASE values), HTTP/2 SETTINGS, WINDOW_UPDATE and pseudo-header order (Akamai fingerprint), TCP SYN — measured by tls.peet.ws |
| APIs | permission states (geolocation, notifications, camera, microphone, persistent-storage, screen-wake-lock, midi, clipboard), storage quota, speech voices, `Notification.permission`, share, Private Click Measurement, storage access, platform authenticator |

What a profile changed to get there (each was a difference before):

- **Window geometry.** A WKWebView reported `outerWidth = outerHeight = 0` and a screen position
  computed from an empty rectangle: WebKit asks the UI delegate for the window frame
  (`WKUIDelegatePrivate`, which Safari implements) and gets nothing otherwise. The tab now answers
  with its window's frame. The window itself is laid out like Safari's (see above); it used to add
  a title bar and an always-visible tab strip (~92 px).
- **Language.** Without a proxy country, websites saw the app's UI language (Russian), which
  `Localization.applyProcessLanguage` keeps in the app's own defaults; they now see this Mac's
  languages, read from the global domain, as Safari does.
- **Fonts.** A WKWebView lets pages use fonts the user installed; Safari shows them only the
  system's. The profile sets the WebKit preference Safari sets (private, applied only if present).
- **Storage quota.** Safari reports 60 % of a *standard* 128 GB volume per origin (WebKit reports a
  standard capacity rather than the real disk's, so the figure is 82 463 372 084 on every Mac, a
  tenth of it in a third-party frame). WebKit gives an app that is not a browser less: 15 % of that
  volume in a persistent store (20 615 843 021, measured in CI run 429 for a new profile next to
  Safari) and a fixed 1000 MiB in a non-persistent one — the small quota private-mode detectors look
  for. A profile's persistent store is now made with a browser's ratios, 0.6 per origin and 0.8 in
  all (`BrowserStorageQuota`: WebKit's own computation, through the data store's configuration, as
  Safari's stores are made), so WebKit itself answers Safari's figure; the self-test reads it in a
  world the profile's scripts are not in. An ephemeral profile's non-persistent store still gets
  1000 MiB from WebKit, and the profile's script maps that to Safari's figure.
- **Geolocation permission.** `permissions.query({name: 'geolocation'})` threw a TypeError (the shim
  built a fake status); it is now the engine's own `PermissionStatus`, 'prompt' until the page asks.
- **Wrappers under JavaScriptCore.** With relay-only WebRTC the wrapper added a
  `webkitRTCPeerConnection` Safari 26 no longer has and inherited from `Function.prototype` instead
  of `EventTarget`; both fixed. The shim tests run under JavaScriptCore (Bun) as well as V8.

What still differs, and why it cannot be changed from the app:

- **Apple Pay and Web Push.** `ApplePaySession`, `ApplePaySetup`, `MerchantValidationEvent`,
  `PaymentRequest` and `PushManager` are Safari's: WebKit turns them on for an app only through
  private preferences (`ApplePayEnabled`, `PushAPIEnabled`). A profile in Safari's window has them
  from Safari's own code, and every call answers as Safari's (`scripts/payments_check.py`, full
  run 17: 17 of 17). In this app's own window (an iPhone view, the simplified mode) Apple Pay is
  turned on the same way (`BrowserSession`, the owner's decision of 8 November: the interface is
  there and its calls refuse as Safari's do — on a Mac without a card `canMakePayments()` false, a
  session without a user gesture refused; the "on-page" variant: all six Apple Pay and Payment
  Request calls as Safari's). What `canMakePayments()` answers on a Mac whose Wallet has a card is
  not measured yet: it needs the owner's Mac. Push stays off there: with it on, two calls answer
  otherwise (`permissions.query` for notifications and push throws `NotSupportedError` where Safari
  answers). CI measures it call by call in the variants of `scripts/payments_check.py`.
  `Object.getOwnPropertyNames(window).length` follows (1044 in Safari, 1029 in a profile with
  WebRTC on, 1022 with the default policy that removes it).
- **WebRTC** is switched off by the default policy, and with a proxy unless it goes through the
  relay, held there by the network guard (SOCKS5 with UDP only, relay candidates only;
  [TUNNEL.md](TUNNEL.md)). Without a proxy, `relayOnly` and `unrestricted` keep it.
- **The replacement `Date` and `Intl.DateTimeFormat`** (only with a time zone set) list `length`
  and `name` before their statics: JavaScriptCore orders a script function's own properties that
  way whatever the definition order.
- **Media devices before permission.** On the CI runner Safari lists `audioinput,videoinput`, a
  profile `audioinput` only. WebKit hides a kind the app has no capture authorisation for (macOS
  privacy settings, per app); granting the app camera access once aligns it.
- **Advanced Fingerprinting Protection.** Safari can add noise to canvas readback for scripts it
  classifies as fingerprinting; there is no WKWebView switch for it. On the probe page (no such
  script) the pixels are identical.
- `navigator.webdriver` (true only under safaridriver) and the error-stack depth (WebDriver vs.
  `callAsyncJavaScript`) differ only in the comparison harness.

**deviceinfo.me** shows "Canvas: Spoofed" and "Fingerprinting Resistance: Detected" in a profile
and equally in Safari 26 on the same Mac: its canvas test accepts only PNG data URLs of 142, 150,
158 or 186 characters, and this WebKit's encoder writes 274 for the same five exact colours. The
row sets the resistance verdict (`me()` in its script). Nothing in the profile causes it, and
nothing a profile could do short of rewriting `toDataURL` (which would be a real lie) changes it.

**The ceiling for a profile with a proxy, in this architecture.** Full parity with Safari is not
reachable for a profile with an HTTP or SOCKS5 proxy, and this says why, so that nobody has to work
out again why the count is not Safari's. In Safari's window, a page of such a profile sees 1005 of
the window's own properties where Safari has 1044 (macOS 26.6.2; CI runs 430 and 501, by name). Each
group was measured with WebKit's own switch for it on, against this Mac's Safari, on one page that
measures itself (`scripts/payments_check.py`, variant `parity`; CI runs 514 and 515, measurement
branch `claude/measure-parity`, macOS 26 and 27):

- **WebRTC, 23** — off with a proxy unless the relay carries WebRTC, held by the network guard
  (relay candidates over SOCKS5 with UDP, [TUNNEL.md](TUNNEL.md)).
- **WebTransport, 8** — HTTP/3, QUIC over UDP, which no HTTP CONNECT or SOCKS5 proxy carries. On
  macOS 26 a profile with its proxy and WebTransport on sent the QUIC handshake to the page's
  address over UDP from this Mac's address, outside the proxy (ten packets from the profile's WebKit
  networking process, retried at 1, 2, 4 and 8 seconds): a leak. On macOS 27 WebKit refused it at
  once (`WebTransportError` after 4 ms, no UDP), where Safari waits on QUIC and has no answer in 60
  seconds: told apart at once. They stay off.
- **Web Authentication and Credential Management, 6** — `PublicKeyCredential`, the three
  `Authenticator…Response`s, `Credential`, `CredentialsContainer` (and `navigator.credentials`).
  Their ceremonies are the system's — iCloud Keychain passkeys shared with Safari and every profile,
  Touch ID, a phone's hybrid sign-in from this Mac's address, attestation — and in this app there is
  no ceremony to take: WebKit refuses every one at once (`NotAllowedError`, "The request is not
  allowed by the user agent or the platform…", in 4 to 24 ms, with a user gesture or without), shows
  no sheet, and never asks the app — the web authentication panel's delegate method
  (`_webView:runWebAuthenticationPanel:initiatedByFrame:completionHandler:`) was never called. Safari's
  ceremony stays open, its sheet up, until the person answers (no answer within 10 seconds on the
  runner). `PublicKeyCredential.isConditionalMediationAvailable()` answers false where Safari answers
  true. So the owner's proposal — the interfaces in place, the profile's own question before the
  system's sheet, a cancel the way a person cancels — has nothing to stand on here: holding the
  request open while the person decides would take a JavaScript wrapper, which the rule above rules
  out. The one other road is Apple's managed entitlement for browsers
  (`com.apple.developer.web-browser.public-key-credential`), with which WebKit takes the system's
  ceremony as it does for Safari — a matter of signing and of Apple's approval, not measured. They
  stay off with a proxy. (Without a proxy a profile has them today and answers as above.)
- **DigitalCredential, 1** — absent without a proxy too: WebKit turns it on for an app with the
  `com.apple.developer.web-browser` entitlement (WebKit's `defaultDigitalCredentialsEnabled`), which
  Safari has and this app has not. With WebKit's switch on, a request for an mDL over OpenID4VP is
  answered otherwise than in Safari (`TypeError`, no supported request, where Safari answers
  `NotAllowedError`, the document not focused). It stays off.
- **MediaSessionCoordinator, 1** — absent without a proxy too, for the same reason (the SharePlay
  entitlement, `com.apple.developer.group-session.urlactivity`). With WebKit's switch on it answers
  as Safari does with no SharePlay session — the coordinator there, its prototype the same, `join()`
  refused with `InvalidStateError`, "Unable to join when state is closed", with a user gesture or
  without — and no session can start without the entitlement. It could come back; the owner decides.

So, measured: a profile with a proxy reaches 1006 of 1044 with the MediaSession coordinator, 1029
with WebRTC carried by the relay as well; WebTransport's 8, Web Authentication's 6 and
DigitalCredential are out of reach in this architecture. Until then it is 1005. A profile without a
proxy has 1019: WebRTC's 23 by the default policy (`relayOnly` and `unrestricted` keep them) and the
two entitlements' own.

So a page that fingerprints *feature support* can still tell "Safari" from "a WKWebView app on the
same Mac" by Apple Pay and Web Push, the same way it tells Safari from a Safari View Controller or
a Mail or Slack preview. It cannot tell two profiles of this app apart by any of this: they are the
same engine on the same Mac. What separates profiles is what they declare (table above) and their
storage and network (§1, §4).

## 3. Encryption at rest

| Data | At rest | While the app is unlocked | While the profile runs |
|---|---|---|---|
| Profile list (names) | encrypted (`index.bin`) | in memory | in memory |
| Profile settings (proxy credentials and so on) | encrypted (`config.bin`) | decrypted only during launch and edit | in memory |
| Saved passwords | encrypted (`passwords.bin`) | decrypted on demand | in memory |
| Imported cookies for a stopped profile | encrypted (`cookies-import.bin`) until its next launch puts them into the website data | — | in WebKit's cookie store (as the profile's other cookies) |
| Warm-up plan (addresses, search, times) | encrypted (`warmup.bin`, this Mac only, not synced) | decrypted when the sheet opens | — |
| Warm-up schedule (every N hours, last run) | encrypted (`warmup-schedule.bin`, this Mac only, not synced, not in a profile export) | decrypted at unlock (the timer needs it) | — |
| Last warm-up (when, pages, cookies) | encrypted (`warmup-last.bin`, this Mac only, not synced, not in a profile export) | decrypted when the inspector shows the profile | — |
| Restore points (copies of the profile's site data, cookies, history, open tabs) | the copied files as they were, still encrypted (`restore-points/<id>/`, with `point.bin`; this Mac only, not synced, not in a profile export) | listed when the sheet opens | — |
| The profile's history of events (`journal.bin`) | encrypted (this Mac only, not synced, not in a profile export) | decrypted when the inspector shows the profile | — |
| Synced cookies (persistent cookies, with cookie sync on) | encrypted (`cookies.bin`; its local baseline `cookies-baseline.bin`) | encrypted | encrypted; written at launch and stop |
| History | encrypted (`history.bin`); ephemeral profiles: never written | encrypted | in memory, saved encrypted (debounced, ≤ 3 s) |
| Bookmarks | encrypted (`bookmarks.bin`) | encrypted | in memory, saved encrypted on every change |
| Sync target and token | encrypted (`settings.bin`, not synced) | in memory | — |
| Proxy list (addresses, credentials, labels, last checks) | encrypted (`proxies.bin`, this Mac only, not synced) | in memory | — (a profile has its own copy of its proxy in `config.bin`) |
| WebKit website data | encrypted (`webdata.pbsa`) | encrypted | **plaintext on disk** in WebKit's directories |

**Why WebKit data is plaintext while a profile runs.** WebKit chooses the location of an
identifier-based data store itself and writes ordinary SQLite and LevelDB-style files
there. There is no public API to hand it a key, or to point the store at an encrypted
volume. `_WKWebsiteDataStoreConfiguration` can set directories, but it is private API.
The closest viable approach is to archive, encrypt and remove the data on stop, and
restore it on launch. `WebDataStoreVault` does this.

**Known gaps in that approach:**

1. *Directory discovery.* Apple doesn't document the layout. `WebKitDataLayout` finds
   directories by the profile UUID below the app's WebKit and Caches subtrees, and translates
   archive locations between the sandboxed and unsandboxed layouts. The self-test checks both
   on each CI run. If a future macOS stores per-identifier data elsewhere, that data won't be
   sealed, and the self-test's "plaintext removed after seal" check is meant to catch it.
   By hand: `find ~/Library -iname '<profile-uuid>'` while the profile is stopped should
   return nothing.
2. *No flush/close API.* WebKit tears a session down asynchronously after the last
   reference to its store is released. The vault waits, archives, then calls
   `WKWebsiteDataStore.remove(forIdentifier:)`, which fails while the store is still in
   use, and retries with backoff (1+2+3+5+8 s). A write that lands between the archive
   and the successful removal is lost. It is not leaked. If WebKit never releases the
   store, the app reports an error and the data stays in plaintext until the next stop
   or unlock.
3. *Crashes.* If the app crashes or is force-quit while a profile runs, the plaintext
   stays on disk until the next unlock, when `recoverUnsealedProfiles` seals it. Until
   then it is protected only by FileVault, the 0700 directory permissions, and (sandboxed)
   the container. History written in the last ≤ 3 s before a crash is lost.
4. *Backups and snapshots.* What is plaintext while a profile runs is excluded from Time Machine,
   and so from its hourly local snapshots, which would otherwise keep it after the seal: WebKit's
   directories of this app, and a profile process's home (`home.noindex`, a name Spotlight does
   not index). An APFS snapshot taken by another tool, or a backup tool that ignores the exclusion,
   still copies it; the self-test checks the exclusion is set. **Not in the sandboxed build:** there
   the mark is accepted without an error and does not stay on the container's WebKit and Caches
   folders (measured in CI, runs 383–384), so Time Machine can copy a running profile's website
   data; the self-test reports it instead of checking it. The build without the sandbox keeps it.
5. *Deleted plaintext isn't securely erased.* APFS is copy-on-write on SSDs, so
   overwriting doesn't reliably erase data, and the code doesn't try. FileVault is the
   real protection for deleted blocks; enable it.
6. *Memory.* Swift and CryptoKit offer no guaranteed zeroisation. Keys of an unlocked
   vault live in process memory, and anyone who can read process memory (root, a
   debugger, a core dump) can recover them. What the app's own code holds is overwritten
   with `memset_s` once used — the password's bytes, derived keys, the unwrapped vault key
   and Argon2's 64 MiB of working memory — but copies inside `String`, `Data` and CryptoKit
   are out of its reach.

**KDF.** Argon2id (RFC 9106, version 1.3) with 64 MiB, 3 passes and 4 lanes — the RFC's second
recommended option — derives the key that unwraps the vault key. It is memory-hard: a GPU tries
far fewer guesses per second than against PBKDF2. CryptoKit and the macOS SDK have no Argon2, so
it is implemented in Swift in the core (`Argon2.swift`, no C dependency) and checked against the
RFC's test vector and the reference implementation's. A vault created before (PBKDF2-HMAC-SHA256,
600 000 iterations) is re-wrapped under Argon2id the next time the app unlocks it, with the
password that opened it; only the header (`vault.json`) changes, atomically. A header's Argon2id
costs are capped (2 GiB, 10 passes, 16 lanes), so a header fetched for sync cannot make the app
allocate without bound.

## 4. Network and proxy

**Native (enforced by WebKit for the data store):** `proxyConfigurations` covers HTTP(S),
WebSocket, fetch/XHR, media and service-worker loads of that store.
`allowFailover = false` makes it fail closed. Supported proxies are SOCKS5 and HTTP
CONNECT, optionally TLS to the proxy, with or without username/password, plus a
per-profile bypass list. The CONNECT tunnelling, remote DNS for SOCKS5, and fail-closed
behaviour are verified by the self-test (§0).

**QUIC / HTTP/3 stays on the proxy.** With a data store proxy, WebKit's network stack does not
use HTTP/3: measured on every push by `scripts/leak_check.py`, which runs real forwarding
proxies on the CI Mac. cloudflare-quic.com answers a profile without a proxy over HTTP/3 and the
same requests through an HTTP CONNECT or SOCKS5 proxy over HTTP/2, each one seen by the proxy;
the SOCKS5 proxy was never asked for UDP. So QUIC needs nothing more. WebRTC does: the relay and
the network guard ([TUNNEL.md](TUNNEL.md)), below.

**App Transport Security:** `NSAllowsArbitraryLoadsInWebContent` lets the browser load
`http://` pages. The app's own URLSession traffic (HTTP sync) remains HTTPS-only.

**macOS 27: a jump to a fragment reloads a proxied page.** WebKit 27 (macOS 27.0.1, WebKit
22625) makes a new document of a navigation to a fragment of the page shown — `location.hash`, an
in-page anchor, a load of `page#x` — whenever the data store has a proxy: the same-document
navigation runs, then WebKit loads the same address again; the page's state is gone and the proxy
is asked for the page a second time. Measured in CI (runs 435–437, the self-test's `fragment
jump` lines on every push): in profiles with an HTTP CONNECT or a SOCKS5 proxy, by name and by
address, and in a plain web view with nothing but the data store's proxy setting (no profile,
script or rule list). A page loaded directly keeps its document, as in Safari 27; macOS 26 keeps
it with a proxy too. It is WebKit's own behaviour and nothing in the app changes it: sites that
route by the fragment (single-page apps) lose their state at each route change in a proxied
profile on macOS 27. To be reported to Apple.

**Not covered:**

| Path | Status | Mitigation |
|---|---|---|
| WebRTC (STUN, TURN over UDP or TCP, media) | Never proxied by WebKit: it opens these sockets itself, without the data store's proxy. STUN reveals the real public IP to the page (seen by the CI leak check); a TURN server sees it too | With a SOCKS5 proxy that relays UDP and the network guard ready: through the proxy's UDP ASSOCIATE, via a per-profile TURN relay on 127.0.0.1, the profile's other connections dropped by the guard ([TUNNEL.md](TUNNEL.md)). Otherwise WebRTC is **off** in a proxied profile, whatever its setting (§5) |
| DNS prefetch | `<link rel="dns-prefetch">` (also as a `Link:` header) makes the network process resolve the host through the system resolver — WebKit skips it only for a *system-wide* proxy, not for a data store's `proxyConfigurations` | A content rule list blocking `ping`-type loads is added to every proxied profile (`ContentRules`), Safari's chrome included: WebKit 7621 and later runs dns-prefetch through it as a ping. Before 7621 dns-prefetch is a preference instead, which proxied profiles have off (and pinned off in Safari's chrome, which turns it on). It also blocks `<a ping>` click trackers; beacons are another load type and go through the proxy. A proxied profile does not start without the list (compiled into the default rule-list store, or, failing that, a temporary one). In Safari's chrome the list stays through "Reload Without Content Blockers" and a site's content-blocker switch (§4a). Verified by the self-test with an `<a ping>`, and in Safari's chrome by the egress capture (no DNS question for the leak page's prefetch, header, link or late-prefetch names) |
| WebTransport, Private Click Measurement, Web Authentication | QUIC an HTTP or SOCKS5 proxy cannot carry; attribution reports sent later outside the page's session; passkeys from the owner's iCloud Keychain, checked by system services | Off in every web view of a proxied profile (pinned in Safari's chrome); attribution reports already stored are removed at launch |
| Safe Browsing lookups | Made by a system service, outside the data store's network session | Off by default (`safeBrowsingEnabled`); in Safari's chrome both its setters are pinned to the profile's choice and the service is not reached unless asked for (§4a) |
| `mailto:`, `tel:`, custom schemes | Would hand the URL to another app, outside the profile | Blocked by the navigation policy |
| Camera and microphone streams | Local capture; their WebRTC transport goes through the proxy only via the relay (SOCKS5 with UDP, the network guard ready), otherwise WebRTC is off with a proxy | Asks the user every time |
| Sync traffic | Goes from the app process through the system network, not the profile proxy | Folder transport makes no network requests; HTTP sync is HTTPS and carries only encrypted blobs |

**Proxy authentication:** credentials go into the data store's `ProxyConfiguration`
(`applyCredential`), which Network.framework sends when the proxy answers 407. WebKit does not
show the proxy's challenge to the app (it keeps it to itself; with no credentials to send the
page simply loads forever), so a profile without credentials cannot find out from a page that
its proxy wants them. The launch-time lookup through the proxy (§6, time zone from the proxy)
does see the 407: the launch is refused with a message when the lookup answers while the launch
waits for it; when it answers later (the launch stopped waiting, below), the profile is stopped with
the same message. Nothing opens directly either way. With that lookup switched off, a proxy that
wants credentials shows as pages that never load.

**SOCKS5 authentication** (RFC 1929 username/password): the credentials go into the same
`ProxyConfiguration` through `applyCredential` and are sent in the SOCKS5 handshake. SOCKS5 has
no 407: a proxy that rejects missing or wrong credentials makes every load fail (nothing goes
direct), but the launch does not learn why and is not refused, so the profile opens and its
pages show load errors. The self-test runs a SOCKS5 proxy that accepts only username/password
and checks that wrong or missing credentials fail closed against a real host.

**Several proxied profiles at once:** each profile has its own data store, and so its own network
session with its own proxy configuration and credentials. Its launch-time lookup has its own
URLSession too. Nothing about a proxy is shared between profiles. The self-test launches three
SOCKS5 profiles together and loads pages in all of them at the same time (§0). Two things are
process-wide, not per profile:
- the language websites see (§6), set by the first profile launched;
- the network guard, which holds each profile whose WebRTC goes through its own relay to its own
  proxy ([TUNNEL.md](TUNNEL.md)).

**Launch and the lookup through the proxy:** the lookup (time zone, country, exit IP) runs while
the profile's data decrypts. A launch waits for it only when the profile takes its location
from the proxy (*Time zone of the proxy's location*, on by default; with *Override time zone*
the zone is the explicit one, but the lookup still runs and is waited for, for the country and
so the language): at most 3 s when nothing is remembered for that proxy yet, at most 1 s when a
location is. A location is remembered per proxy: kind, host, port and credentials (gateway
proxies pick the exit country or session from the username or password). Without an answer by then, the remembered location (or the
host's zone) is used and the lookup finishes in the background. Its answer is remembered for the
next launch. A time zone different from the one the profile runs in is noted, and applies from
the next launch (pages already open keep theirs). So is a language the proxy's country would
want when the first profile launched got no answer in time (§6). A late answer is dropped when
the profile was launched again since, or the app is locking or quitting. Several messages from
one launch are shown together (a message already shown is not repeated).

**Exit-IP warning** (per profile, off by default): the launch compares the proxy's exit IP, as
the lookup sees it, with the one seen at the previous launch through the same proxy and
credentials, and warns when it changed (a rotating or reassigned proxy). It needs the lookup,
which then runs even without the time-zone matching. The last IP is stored, encrypted with the
profile, only while the option is on: turning it off (or removing the proxy) deletes it when the
profile is saved. A lookup still under way when the option is turned off, or the proxy removed
or replaced, neither stores an IP nor warns.

**Proxy list and its checker** (the Profiles window's sidebar → Proxies): proxies kept to give to profiles, encrypted
in the vault under their own key (`proxies.bin`, this Mac only; §3). A check talks to the proxy
and to nothing else, in two parts:

1. The probe (`ProxyProbe`): this Mac resolves the proxy's own name (there is nothing else to reach
   a proxy by), connects to it, and tries a SOCKS5 greeting and an HTTP `CONNECT` at once, on two
   connections; with the login it has, it asks for a tunnel to the first geolocation service (at a
   profile's launch: to its start page's site). The target is a name the proxy resolves (SOCKS5
   ATYP 3, `CONNECT host:port`): this Mac never resolves it and never connects to it. The tunnel
   is closed as soon as the proxy says it is open; two more are opened for the latency (the median
   of three is shown). Each way of failing is its own verdict, so that the report can say what to
   do: the name does not exist, or the resolver failed; the port refuses the connection, cannot be
   reached, or never answers it; the port takes the connection and then says nothing — the most
   common case, what a proxy whose IP whitelist does not have this Mac's address does, or one
   whose back end is gone; it closes at once, or answers as something that is not a proxy; it
   wants a login, refuses the one given, or refuses this Mac (403); it cannot reach the site.
2. When it works: the launch's lookup made for this proxy, as the type the probe found — the same
   geolocation services through the proxy itself with the `ProxyConfiguration` a profile's data
   store would get (`allowFailover = false`), in a URLSession of its own (no cookies, no cache,
   this Mac's Safari User-Agent): exit IP, country, time zone, city and network.

At most eight proxies are checked at a time, and only when the user asks (the Proxies section, or
**Check Proxy** after a launch), never in the background. A proxy that does not work never falls
back to a direct connection, so this Mac's own address is never what a service sees; a proxy whose
settings cannot be applied is not checked at all. The self-test checks this against an
unreachable proxy with a real website among the services, which a request made directly would
have reached, and runs every check of the checker inside a packet capture that fails on any packet
of the app past loopback (§0). Like the launch's lookup, a check is a request to a third-party
service. What a check keeps — the verdict, what the proxy answered (a status line, never a user
name or password), the exit details — is stored with the list, encrypted; the system log gets the
verdict, never the proxy's address or login.

**A profile whose proxy does not work** is not left blank without a word: its launch runs the
probe once beside it (one tunnel, to the start page's site, or the first geolocation service
without a start page; through the proxy only, and the launch never waits for it), and a proxy that
does not work is said in the Profiles window — which profile, which step failed, what to do — with
Check (the list's check of that profile's own proxy) and Show in Proxies. The profile itself still
loads nothing until its proxy answers: fail-closed is unchanged.

**The list and the profiles' copies.** Each profile keeps its own copy of its proxy (what it
connects with, what syncs); the list knows which of its entries a profile uses by the proxy itself
— host, port and user name. The proxies typed into profiles before the list existed are taken into
it once, at the first unlock. An edit of an entry, or a check that found its type, reaches the
profiles whose copy is that entry as it was (same type, TLS and password); a copy changed in a
profile's own editor since is never overwritten. An entry whose type is still unknown (an import
line without a scheme) is given to no profile until a check finds it. **Export** writes the list
in the form Import reads, with the user names and passwords in plaintext — said in the sheet before
anything is written — into a file only its owner can read (0600).

**One proxy, one line.** Wherever one proxy is entered — the profile editor's *New*, the list's
*Add* and *Edit* — it is one field, read by the same parser as a line of Import
(`ProxyListImport.readField`): `host:port:user:pass`, `user:pass@host:port`,
`scheme://user:pass@host:port`, `host:port`. A string the field takes is one Import takes, and a
proxy written back (`ProxyListImport.line(for:)`, also what Export writes) reads back as the same
proxy (unit-tested). The type comes from the scheme; without one it is **not known** — never
taken from a default — until a check finds it (both handshakes are tried, `ProxyProbe`), or, while
the line still names the same proxy (host, port, user name), it is the type already known for it.
A profile never gets a proxy whose type is not known: Save checks such a line first and refuses it
when no handshake answers. A check whose found type differs from the line's scheme wins over the
scheme, as a check corrects a list entry. While the field is not being edited its password is
covered by dots, found where it was written (`ProxyListImport.passwordRange`, unit-tested); where
it cannot be found, the field shows the proxy's address with dots instead — never the password.
Check from the field talks to the proxy alone (the probe), then makes the geolocation request
through it, exactly as a check in the list; a check from *New* adds nothing to the list.

**Giving profiles proxies of the list** (one to many, or several in turn, round-robin; the editor's
*From the List*) writes each profile's own configuration as an edit of its proxy would
(`ProfileConfiguration.assigning`): the profile keeps a copy, so removing a proxy from the list
changes no profile, and the copy syncs with the profile. The location remembered for the previous
proxy is about another proxy and is dropped; the check's location of the new one is remembered in
its place (its exit IP only while the exit-IP warning is on). A running profile keeps the proxy it
was launched with until it stops: like every setting, the proxy is given to the profile's data
store when the profile launches.

**Verify the proxy by hand:** set a SOCKS5 proxy, for example `ssh -D 1080 host`, open
`https://ifconfig.me`, and confirm it shows the proxy's IP. Then stop the proxy and
reload: the page must fail, not show your own IP.

### Local requests (this Mac and the local network)

A page from the internet could load from this Mac and from the local network — `127.0.0.1:<port>`,
`192.168.1.1`, a printer's `.local` name — and learn from what answers which ports this Mac has
open and which devices share its network: the same in every profile, so something that tells
the profiles apart from other people's, or links them. Each profile protects its local requests
unless the person allows them (editor → Privacy → **Local requests**; Settings → New Profiles →
**Block local requests**, on by default; a profile from before reads as protected):

| | Protected (default) | Allowed |
|---|---|---|
| Without a proxy | the local-network rule list (`LocalNetworkRules`): every load to this Mac (loopback, `0.0.0.0`) or a private network — 10/8, 172.16/12, 192.168/16, 169.254/16, 100.64/10, fc00::/7, fe80::/10, their IPv4-mapped forms, `.local`, `.home.arpa`, `.lan`, `.internal` names — is blocked, unless the page itself is on this Mac or that network | as in Safari |
| With a proxy | this Mac: always blocked by the proxied list (the system never sends loopback through a proxy); the local network: through the proxy, to its network, not this one | the same — not a choice with a proxy |

Fail-closed: a profile that needs the list does not start without it (checked by the self-test
before anything has touched WebKit: such a profile's session is refused, "the local-network rule
list is not ready"), and in Safari's chrome the list is one of those no "content blockers off"
switch turns off. Checked by the self-test in a real web view, with a page whose address is a public name: protected, its fetches to the loopback
canary, to `10.255.255.1` and to a `.local` name are refused and the canary takes no connection;
allowed, the loopback fetch reaches the canary. The patterns by unit tests (each range, the
internet next to it, a page on the network keeping its own loads).

## 4a. A profile in its own process, and Safari's chrome

In the build without the App Sandbox every profile runs in a process of its own (`ProfileProcess`),
and there its window is Safari's own chrome (docs/SAFARI_PROCESS.md §9) — except an iPhone or iPad
profile, which gets our own window presenting its device. The emergency switch back to every profile
in the manager process, in our own windows: `PB_PROFILE_PROCESS=0`, or
`defaults write <bundle id> PBProfileProcess -bool NO`. The sandboxed build keeps every profile in
the one process (it cannot load Safari's frameworks).

A profile in our own window is in a **simplified mode**: its proxy and its data are the same, but
without Safari's frameworks hosting the window it is plain WebKit to a site, and does not match
Safari. That window says so, never only the log (`SimplifiedModeNotice`): a "Simplified mode" chip
in its toolbar — the toolbar, whose height a page measures, keeps its height — whose tooltip gives
the reason and whose popover, opened by itself once when the app's first such window becomes key,
says what the mode is and why. An iPhone or iPad profile's window has no chip since 9 November (the
owner): its window is ours by design, not a fallback, and its limits are in this document instead
(its reason is still kept and named). The reasons a chip gives, each in words of its own: the
sandboxed build; Safari's window turned off
(`PB_SAFARI_CHROME=0`); profiles kept in the manager's process (`PB_PROFILE_PROCESS`,
`PBProfileProcess`); and, in a profile's own process, what failed — Safari's frameworks not loading,
a structural piece missing (by name), the process not becoming Safari's application, Safari's window
factory giving no window (`SafariChromeHost.reasonForOwnWindow`). Until 1 November none of these
was shown in the window: the log had them, and a missing structural piece was told in the profile
list as "some of Safari's window may misbehave", when there was no Safari window (that message is
now kept for pieces missing while the chrome is hosted). The self-test checks the chip, its reason
and its popover in our windows of both builds. A profile's process holds Safari's frameworks
next to the profile, and Safari builds the web views; so the profile's proxy is held for the **whole process**, not only for
the web views it knows about (`ProfileNetworkGuard`), and it is decided before Safari's frameworks
load (the child opens the vault and reads the profile first).

| Lock | What it does | Verified by |
|---|---|---|
| 1. Every web view on the profile's store | Safari's configuration factories are patched, and so are the initializers every web view goes through (`initWithFrame:configuration:`, `_initializeWithConfiguration:`): each gets the profile's data store, its privacy preferences and scripts; a navigation's `WKWebpagePreferences` cannot name another store | The self-test's network report: every web view on the profile's store with its proxy. Measured on macOS 26: Safari's factories **missed** the chrome's web view, which only the initializer gave the profile's store — the leak of the hosted chrome came from exactly there |
| 2. Every other store closed | Any other data store the process makes — WebKit's own default store included — points at a proxy that does not exist (127.0.0.1:1, no failover): a web view that ends up on one loads nothing instead of loading as this Mac | The report: default store closed |
| 3. The process's own connections | The default Network.framework privacy context and every URLSession configuration carry the profile's proxy; a background session runs in-process | The report's three probe requests (shared, ephemeral, explicit session), each seen at the proxy as one CONNECT to its host |
| Pinned preferences | Safari re-applies its own settings to live web views, so the setters themselves keep to the profile: WebRTC (off unless the profile's routing allows it — through its own setter and through the feature switches, which reach every boolean preference), Safe Browsing (both setters), installed fonts, ICE candidate filtering on; with a proxy also dns-prefetch, WebTransport, Private Click Measurement, Web Authentication, Digital Credentials and web archives on an ephemeral store | The leak page in Safari's chrome: no `RTCPeerConnection` in the page, a frame of another site or an about:blank frame; no `WebTransport`. The report tries every setter on preferences of no web view and lists any that turns one of them on again (none), and reads every web view's engine |
| Workers | WebKit gives every shared and service worker of a process the preferences of the first web view the process built, copied once: the first web view of a profile's process is one of ours on the closed store with WebRTC and the features above off, and a profile's service workers get the profile's own preferences (`_setServiceWorkerOverridePreferences:`). The manager's process makes no such template: measured in CI run 383, it kept a stopped profile's session (and its session cookies) alive in WebKit until the profile's next launch | The secure half of the leak page in Safari's chrome: no `WebTransport` in a dedicated, a shared or a service worker, each of which must answer; the same on a page of a proxied profile in our own window, in the manager's process, after profiles without a proxy |
| The profile's content stays | A navigation's own content controller gets the profile's scripts first; a controller Safari empties of scripts or rule lists gets the profile's back; with a proxy, "Reload Without Content Blockers" and a site's "content blockers off" keep the ping-load blocker on (it stops a page's dns-prefetch, `ContentRules`) | — |
| Certificates | With a proxy, a site's certificate is checked without this Mac fetching anything for it (`ServerTrust`): the system's trust service would otherwise download a missing intermediate, or ask a revocation server, from the address the certificate names — as this Mac, outside the proxy, and a page can serve such a certificate at will. Answered so in our tabs and downloads, for the profile's data store (service workers), for every delegate Safari's chrome gives its web views and downloads, for the process's URL sessions without a delegate, and for the proxy lookup. A chain that cannot be completed from what the server sent is refused | The canary certificate (§0): refused at the handshake, and no query for its name in the capture, while the control's is there. The report counts the evaluations |
| Kernel | A sandbox profile, applied before Safari's frameworks load, that allows everything else: with a proxy no UDP at all (QUIC goes around any proxy, and Network.framework ignores a privacy context's proxies for it); and no read or write in the real Safari's places (`~/Library/Safari`, Safari's containers, caches, website data, cookies, preferences, group containers); and no XPC service of Safari's frameworks (`com.apple.Safari*`): such a service starts for whichever process asks, as a process of its own outside the profile's home, proxy and sandbox, and the one seen starting for the hosted chrome, SafariPlatformSupport's helper, may read and write the real Safari's container and history and the owner's passwords in the keychain, and reaches the network itself (CI: its entitlements in the inventory; started on macOS 26 and 27). A view Safari's code shows from such a service is asked for once: SafariPlatformSupport's completion list asked for its view again each time that view's refused service ended, which it did at once, and the process's main thread did little else (`SafariChrome.stubLateFeatures`; docs/SAFARI_MENU.md). Safari's frameworks find their folders from the account's real home, not the profile's: their path getters are redirected to the profile's home (`SafariPaths`), and whatever they find another way is refused | The report: UDP, the real Safari's places and Safari's XPC services closed; no `com.apple.Safari*` XPC service started for the profile (watched as `lsof` would, every half second); a UDP datagram and a QUIC connection to documentation addresses never sent (the capture). Measured on macOS 26 before this: the hosted chrome wrote its history index, icons, top sites, per-site settings and content-blocker statistics in the real `~/Library/Safari` |
| Services in other processes | A connection to an XPC service that would fetch for the profile from another process — as this Mac — or keep its browsing in the user's own stores goes to a name that does not exist: Safari's SearchHelper (search suggestions, OpenSearch descriptions a page names), Safe Browsing (unless asked for), parsecd (Safari Suggestions), cloudd and the sync agents, webpushd, passd (Apple Pay), translationd (page translation), the password breach check, Screen Time (web usage, synced through iCloud), Siri Suggestions, the personalization store, shortcuts and link context, input analytics, Safari's notification agent, the shared web credentials daemon (which fetches a site's associated-domains file), the Spotlight index, usage tracking, Biome, the knowledge store, and sharing. Every service the process connects to is listed in its report | The egress capture below. Measured on macOS 26 before this: the hosted chrome woke passd and translationd, and one of Safari's services sent QUIC to Apple, all as this Mac |
| Handoff | No `NSUserActivity` becomes current or is eligible for Handoff or indexing: Safari advertised the page in front to the owner's devices on their Apple ID | — |
| Handed to another app | What the user can hand onward from a page stays in the profile (`HandOffs`): no link preview (Quick Look fetches the link with no proxy, and a click opens it in the real Safari), no Look Up by Quick Look, no Services for a selection; an address is never opened in another app (a link from a PDF, `webcal:`, the default browser), only a file; no sharing service — the system's share picker, only shown with an address, fetches the page and its icons itself with no proxy, and Add to Reading List, AirDrop, Freeform, Journal and Reminders fetch it again when chosen (claude/measure-share, run 42476723090, macOS 26.7.2 and 27.0.1), so Share offers only Copy Link; Safari opens no download by itself; a copy stays on this Mac (no Universal Clipboard); no recent documents; a password remembered here is for the session only, never the owner's keychain. In our own windows the same for previews and Services, and the context menu loses "Search with Google", Look Up, Translate, Share, Quick Note and Writing Tools | The report: no web view with link preview, an address handed to another app not opened (it would show in the capture), no sharing service, a "permanent" password kept for the session only, the clipboard local. In our windows: the stripped context menu, no Services requestor |
| Keychain | A profile's process puts itself, before Safari's frameworks load, in a sandbox that refuses securityd's services (`com.apple.SecurityServer`, every `com.apple.securityd.*`) and the account's `~/Library/Keychains`, and does not run if securityd still answers it (`ProfileNetworkGuard.closeTheProcess`): neither the login keychain nor the data-protection one, whatever its signature holds. Its executable is also `Contents/MacOS/LumenProfile`, signed without any entitlement that gives a keychain access group (`ProfileExecutable`); the app reads that signature before every start and starts nothing that carries one | The report (`KeychainIsolation`): each profile's process holds none of those entitlements, where the app's own executable does; in the login keychain profile A keeps nothing and profile B is shown nothing, where two processes of the profile's executable outside the sandbox keep an item and see it (without the lock: CI run 659 fails, profile B shown profile A's item); on a build signed by the team, the same in the data-protection keychain. CI: the release's app with LumenProfile signed with the app group starts no profile. On the real signature (0.1.1, `NE=1`, Developer ID, notarized; the owner's Mac, macOS 27.0.1, 3 November): the kernel's log shows a profile's process refused `com.apple.SecurityServer` and `com.apple.securityd.xpc` by its sandbox |
| Disk | Safari's state goes to the profile's home (`SafariPaths`) and is sealed with it; the home is out of Time Machine and Spotlight while it runs; an ephemeral profile's Safari state is discarded, not sealed; a home a crashed manager's process still holds is sealed once that process is gone; no window is restorable (page titles would go to the saved state, outside the home) | The file-system trace (below); the self-test checks the home is excluded from backups |
| Safari's own services | In the profile's `com.apple.Safari` domain, before Safari's frameworks load (and in the process's argument domain): Safari's AutoFill (iCloud Keychain), Safari Suggestions, search suggestions, Quick Website Search, top-hit preloading, notification prompts and extensions off; Safe Browsing as the profile says. "New Private Window" is not in the hosted menu (its window would keep everything in the profile). The setting alone did not hold: Safari offered to save a password after ours (the owner's Mac). So Safari's AutoFill is closed where a form comes in — every class of Safari's that WebKit hands a submitted form to lets it go on and does nothing else — its offers to save a password or a card do nothing, its offers to fill (its passwords, cards, the user's own contact card) are off, and the Edit menu's AutoFill items that insert them are gone | The report: the keys read back; the leak page's login form went on without Safari's AutoFill, and nothing reached its offers to save |

**Measured from outside, on every push.** Around the unsandboxed self-test CI captures every
packet that leaves the runner, with the process it belongs to (`tcpdump` on `pktap`), while the
self-test runs a proxied profile in Safari's chrome on a leak page that makes every kind of request
a page can make — IPv4 and IPv6 documentation-range literals, host names carrying the run's id, a
WebSocket, a worker, an image, a frame, a font, a video, dns-prefetch, preconnect, `<a ping>`, a
beacon, an icon, a touch icon, an OpenSearch description, WebRTC and WebTransport where they
exist, a link whose name a browser may prefetch (with `X-DNS-Prefetch-Control: on`), a dns-prefetch
added after load, an HTTPS request to a host name, an HTTPS image whose certificate needs a fetch,
fetches to this Mac (refused) and to a `.local` name; and its secure half on loopback, with workers.
`scripts/egress_check.py` fails on any packet to a documentation address, any packet carrying the
run id or the canary certificate's names, any DNS question for a leak page's name, any non-loopback
packet of the app's processes (or made on their behalf), and any packet of the services above —
as the packet's process or the one it was sent for — during the check. A control the self-test
makes on purpose (a certificate fetch from a profile without a proxy) must be seen, or that part
is reported inconclusive. In the same window `fs_usage` records every file the app's, WebKit's and
cfprefsd's processes write, and `scripts/disk_check.py` fails on a write into the real Safari's
places (`~/Library/Safari`, its container, cookies, caches, preferences); a call the sandbox
refused is listed, not failed on. The checks that each request reached the proxy are in the
self-test (§0).

**This Mac's own addresses.** The system never sends a request to this Mac through a proxy: in
CI (run 382, macOS 26) a page in Safari's chrome fetched `127.0.0.1`, `localhost` and `::1` and
each reached a listener on the runner directly. A page could so probe which ports this Mac has open
— the same in every profile, and a way to tell the profiles apart from other people's or link them.
A profile with a proxy therefore refuses every load to this Mac (127.0.0.0/8, `localhost` and
`*.localhost`, `::1` and its IPv4-mapped form, `0.0.0.0`, `::`) from a page that is not itself on
this Mac, in WebKit's own content blocker (`ProxiedContentRules`): fetches, frames, images,
WebSockets and dedicated workers. A page the user opens on this Mac (`http://127.0.0.1:…`) is the
user's own machine: it loads from it directly, as in any browser, and keeps its own loads.
**Checked by the self-test** in Safari's chrome: each of those fetches is refused and the loopback
canary takes no connection. **Not proven now:** a service worker of a remote HTTPS site — whether
content blockers apply to its fetches; the self-test proxy cannot serve a trusted HTTPS origin to
register one. A private-network address (10.255.255.1) goes through the proxy: measured in CI run
383, and checked.

**The process itself.** It is not given the vault's master key: only its own profile's key and
that profile's entry in the index (`ProfileGrant`), on its standard input — never in `argv`, the
environment or a file. A vault opened with that grant reads and writes the one profile's files and
refuses the rest (`CoreError.notGranted`): the other profiles' keys and names, the proxy list,
this Mac's settings and the sync keys stay with the manager, and the index is written only by the
manager. So a compromise of the process that loads websites and Safari's frameworks reaches the
profile it runs, not the vault (`ProfileGrantTests`). It quits — sealing
its data — when the manager's channel closes (the manager quit or crashed), and holds a lock on its
home while it runs, so that a manager started after a crash seals a home left in plaintext only
once its process is gone.

Its environment is built from a list (`ProfileProcess.childEnvironment`), not inherited: the
user's name and shell, the text encoding, the app's language and Safari-chrome switches, a fixed
`PATH`, and the profile's own home, vault folder, time zone and warm-up switch. Nothing else of
the manager's reaches it — not a shell's or CI's variables, debug switches or the self-test's.
`HOME` is the profile's home as well as `CFFIXED_USER_HOME`, and `TMPDIR` a folder inside it, so
temporary files of the run are in the home (excluded from backups), and are removed, not sealed,
when the profile stops. **Checked by the self-test**: two variables set in the manager before the
launch (one that would make the process windowless) are not in the process, and its `HOME` and
`TMPDIR` are in the profile's home. Foundation's own temporary directory is reported, not
checked: where it reads it from is the system's.

**Safari's own paths, moved once.** Safari's frameworks find their folders from the account's real
home, not the one the process is given, so their path getters are patched to answer with the
profile's home (`SafariPaths`). A user's vault — and so a profile's home — is itself under the
real ~/Library (Application Support): up to 1 November a path the frameworks had already built in
the profile's home was moved into it again, one home deeper each time a getter built on another's
answer (the owner's Mac, 31 October: Safari's databases three homes deep,
`home.noindex/Library/Application Support/PrivacyBrowser/profiles/<id>/home.noindex/…`, growing).
A path already in the home now stays where it is (`SafariPaths.moved`), and before a profile's
process starts the manager brings what earlier builds nested back into the home
(`SafariHomeVault.flattenNested`: where two levels hold a file the newer stays, an SQLite database
goes with its own journal files and never meets another level's, and the nested folders go).
CI never saw it: the self-test's vault was in a temporary folder, outside ~/Library; it is in
Application Support now, as a user's is. **Checked by the self-test**: in Safari's window, Safari's
own files are in the home's `Library/Safari` and no home is nested in it (skipped, and said, where
the home is not under ~/Library or Safari wrote nothing of its own); the flattening and the moving
on a home made for the purpose.

**No home outside a profile.** `--safari-chrome`, a developer's way to try Safari's chrome without
a profile, gave itself the home `<vault>/SafariChromeHome` up to 1 November, kept from run to run
in plaintext, in no profile, never sealed (the owner's Mac: 868 files of 29 October — WebKit's
caches, local storage and databases of the sites browsed in it). It now runs in a temporary home of
its own, removed when it ends, and the app removes a `SafariChromeHome` left in the vault folder
when it starts.

**Preferences.** `CFFIXED_USER_HOME` moves what asks the process for its home; it does not move
where cfprefsd keeps a preferences domain, which stays the account's real `~/Library/Preferences`
(measured by the menu walk, CI run 457, macOS 26 and 27: no preferences file in a profile's home).
So nothing of a profile's that must stay its own is written to a domain:

- The settings a profile gives Safari's own services (AutoFill, Safari Suggestions, Safe Browsing,
  DNS prefetching, and the rest of `SafariChrome.servicePreferenceValues`) live in its process's
  argument domain only, which every lookup sees first and which is never written. They used to be
  written to `com.apple.Safari` as well, which put them in the account's
  `~/Library/Preferences/com.apple.Safari.plist` — among the real Safari's places, the same file for
  every profile. **Checked by the self-test**: Safari's lookups in the profile's process answer
  with the profile's values, and that file is not written while the profile runs.
- The real Safari does not read that file (CI run 488, measurement branch
  `claude/measure-safari-prefs`, macOS 26 and 27, `scripts/safari_prefs_reach.py`): cfprefsd's log
  has Safari asking for `com.apple.Safari` only from its container, `/Library/Preferences` and
  managed preferences; a home page put in the file next to the 15 keys, as those versions wrote
  them, did not open in a new window — with Safari's container in use, and on Safari's first launch
  with a new container, which took none of the keys — while the same page given as a launch argument
  did. The one process seen reading the file is AppKit's open and save panel service, for the
  panels' own settings. On the owner's Mac, Safari's four AutoFill settings are on, the file saying
  off. The keys are ours all the same: once, after the vault's first unlock in a version with it,
  each that still holds a value a profile of the vault would have written is taken out
  (`SafariAccountPreferences`); one changed since, and every other key of the file, stays; the log
  says which went and which stayed. **Checked by the self-test**, on a domain of its own.
- **Safari's code names the real Safari's container plist by its path.** In a profile's process it
  writes some ten keys through an `NSUserDefaults` suite named by
  `~/Library/Containers/com.apple.Safari/Data/Library/Preferences/com.apple.Safari.plist` — the
  search provider's identifier and name (removed), the start page's sections, the Browsing
  Assistant's consent, Reader's last use, the offline search model's state and others (CI run 496,
  every write logged with the instance it went through). Such a write is cfprefsd's to make, not
  the process's: from a process like a profile's but without its sandbox, it reached the real
  Safari — its container's file, `defaults read com.apple.Safari`, and a home page its next launch
  opened (run 503, macOS 26 and 27, measurement branch `claude/measure-safari-container`). From a
  profile's process it did not: the menu walk left the real Safari's own preferences as they were,
  sentinels set in them first — the search provider's two keys among them — kept (run 504, macOS 26
  and 27, `claude/measure-container-walk`). Most likely cfprefsd asks the sandboxed process's
  sandbox whether it may write that file, and the kernel's refusal of the real Safari's places
  answers no; that is not measured. The file-system trace saw neither: cfprefsd writes through a
  directory descriptor, which fs_usage shows as a relative path (`[3]/name.plist`), and names only
  the source of the rename that puts the file in place. Since the owner's week of 1 November it
  names them: `disk_check.Resolver` follows the descriptors each process opens in the trace (CI's
  measurement run 521: a canary by name, by a path in a home and by a path in a container, all
  named whole), and the self-test's disk check and the menu walk each write a canary through
  cfprefsd and fail when the trace does not name it. What cfprefsd writes in the real Safari's
  places is listed, not failed on: it writes for whichever process asks, and the trace cannot say
  which. So the menu walk still reads the real
  Safari's own preferences before and after (`defaults export com.apple.Safari`), with sentinels
  set first on CI's runners, and fails on any change; the self-test reads them around its
  Safari-chrome profile, without sentinels. Both skip the comparison while the real Safari runs.
  The sandbox stays the first defense; the second is below: Safari's code no longer names that
  domain at all.
- **Safari's preferences are the profile's, in its home** (`SafariDefaults`; the owner's decision).
  What Safari's chrome saves — through the standard defaults its window's frame, its toolbar,
  sidebar and favorites bar, the start page's sections, some WebKit preferences, the dates of its
  own updates; through its own accessor, `+[NSUserDefaults safari_browserDefaults]`, the keys above
  — went to two places: this app's own domain in the account's real home (53 keys a walk on macOS 26,
  56 on 27, run 496; shared by every profile and the manager, outside the vault), and the real
  Safari's container, which the sandbox refuses (none of it kept). Both are one domain of the
  profile's now, as Safari has one: named by a path in its home,
  `<home>/Library/PrivacyBrowser/SafariDefaults`, which cfprefsd keeps in the file at that path —
  not under the home's `Library/Preferences`, where a domain named by a path is the account's own
  domain of that name (runs 496 and 503). The standard defaults are made that domain before
  Safari's frameworks load, Safari's accessor right after they do; the argument domain (the
  profile's settings for Safari's services) still answers through it (24 of 24 keys, run 508), and
  this app's own domain no longer does. As the process starts the domain is what the file restored
  with the home says (empty without one: cfprefsd keeps a domain in memory after its file is gone);
  as it exits it is written to the file, before the manager seals the home. Measured on both macOS
  (runs 508 and 510, measurement branches `claude/measure-ui-state-2` and `-3`): every write went
  to the profile's domain (291 to 297 a self-test, 290 to 295 a walk) but the toolbar's
  configuration on macOS 26 (below); the walk added no
  key to this app's domain and none to the real Safari's, and matched its record item for item;
  the file held 52 to 56 keys after a walk; a second launch got the first's back (38 and 42 keys);
  with a key left to cfprefsd as the process exits, nothing was in the home 5, 10 and 30 seconds
  after its seal. **Checked by the self-test**: both ways reach the profile's domain, the home stays
  sealed after a stop, a second launch gets what the first saved, and none of it is in this app's
  domain. Every profile starts once from Safari's defaults for these, which is the owner's call;
  earlier versions' keys stay in this app's domain, unread.
- **Not covered, on macOS 26:** AppKit saves the toolbar's configuration through an
  `NSObservableDefaults` of its own, made for this app's domain before any of this runs: one key,
  `NSToolbar Configuration BrowserStandaloneTabBarToolbarIdentifier-v3.1`, still goes there (run 510;
  on macOS 27 nothing does). It says which toolbar buttons are shown, nothing of a page.

**The system log.** Lines the app writes to the unified log (kept on disk at notice level and
above, and in a sysdiagnose) carry the user's data only as `<private>`: profile names, proxy hosts
and exit IPs, addresses, paths, settings and error texts. In clear are only a profile's random id,
counts, statuses, an error's type, domain and code, and the names of classes and hooks from the
code. `scripts/check_log_privacy.py` fails CI on a public interpolation that is none of those.

**Not covered:** traffic of system daemons that run for every app and are not started on the
profile's behalf (the capture lists them: `webprivacyd`, `mobileassetd`, the system's time
synchronisation), and anything Safari reaches through C-level XPC (`xpc_connection_create`)
rather than `NSXPCConnection` — the capture would show it. URL sessions Safari makes with a
delegate of its own answer their certificate questions Safari's way (the system's); the pages'
loads are not among them. WebKit's C preference setters (`WKPreferencesSetPeerConnectionEnabled`)
cannot be pinned; the report reads every web view's engine instead. A site whose certificate holds only with a fetch fails in a proxied profile
rather than being completed, and Safari's automatic upgrade of an `http://` address to HTTPS does
not fall back to http after such a refusal (it is a cancelled check, not a failed one). In Safari's
chrome, Safari's own context menu keeps Look Up, Translate and
Writing Tools (the system's services, which send the selection to Apple); a profile's process
shares the user's temporary and cache folders under `/var/folders` with the others; a crash
report of a profile's process goes to the user's DiagnosticReports.

## 5. WebRTC

WebKit offers no public preference to disable WebRTC or set an IP-handling policy, and its
WebRTC sockets — STUN, TURN over UDP or TCP, media — never use a data store's proxy (WebKit's
network process opens them with plain Network.framework parameters). Its default hides local
IPs behind mDNS host candidates, but STUN still discovers the public IP. WKWebView on macOS 15
and 26 exposes a native `RTCPeerConnection` (observed by the self-test).

**With a proxy, WebRTC goes through the proxy or is off** (`ProfileConfiguration.webRTCRouting`),
whatever the profile's setting, because any other policy sends the page's ICE traffic from this
Mac's own address:

- **SOCKS5 proxy with UDP, the network guard ready, WebRTC setting not Disabled**: the page's only
  ICE server is a TURN relay on 127.0.0.1 in the app's own process, under
  `iceTransportPolicy: "relay"`; the relay sends everything through the proxy's UDP ASSOCIATE, so
  the page, STUN servers and peers see the proxy's address. The user script keeps the page on the
  relay (hardened against pages that tamper with built-ins; a peer's candidates named by host names
  are dropped, so nothing is resolved); behind it the network guard, a content-filter system
  extension, drops every other connection of the profile's process and of what WebKit opens for
  it. The page keeps seeing its own configuration; its STUN servers are not contacted, and the urls
  that would name the relay name the page's own server. Design, limits and signing:
  [TUNNEL.md](TUNNEL.md).
- **HTTP CONNECT proxy**: off. CONNECT cannot carry UDP.
- **A SOCKS5 proxy without UDP, one whose UDP leaves from another address than its TCP (or whose
  TCP exit could not be found out), the guard not in the build, not installed, not answering, not
  yet checked on this Mac, or the profile inside the app's process (the sandboxed build)**: off, and
  the launch says which, with what to do. Without the relay and the guard, UDP would leave from this
  Mac's real IP; from another address of the proxy than its pages', it would show a site two
  addresses (TUNNEL.md, "One address").

The editor shows the setting as off (or "through the proxy, relay only") while a proxy is set,
and keeps the stored choice for when the proxy is removed.

**Decided (October 2026): WebRTC stays off in a profile with a proxy.** The deciding reason: a
page that reaches WebRTC learns an address from it, and that address has to be the one its HTTP
requests come from — the proxy's exit. Through a SOCKS5 proxy's UDP association it need not be: a
proxy can relay UDP from another address than its TCP connections leave from, or relay none, and a
WebRTC address that differs from the HTTP address tells a site more than WebRTC being off, as it
is in Lockdown Mode. So the relay carries a profile's WebRTC only when the user chooses it for that
profile (a WebRTC setting other than Disabled), only when the proxy relays UDP (asked at each
launch: the address the relay finds through it is the one pages see), and never before the guard
is ready on that Mac ([TUNNEL.md](TUNNEL.md)). `scripts/release.sh` builds without the guard until
the owner's signed build has passed the hardware checklist (`NE` unset), so a released app's
proxied profiles run with WebRTC off until then.

The profile setting:

- `disabled` (default) switches WebRTC off in the engine (`WKPreferences._setPeerConnectionEnabled:`,
  a private property; Lockdown Mode turns off the same setting): no `RTC*` interface exists
  in any frame. Where WebKit lacks that property, the document-start user script removes
  every `RTC*` interface from the window instead, as in an engine built without WebRTC.
- `relayOnly` wraps the constructor and `setConfiguration` to force
  `iceTransportPolicy: "relay"`. No host or srflx candidates are gathered, so peers see
  only the TURN server's address. The TURN server still sees your real IP. With a proxy,
  only the app's relay is used.
- `unrestricted` uses the WebKit default; never applied with a proxy.

**Limits of the shim (relay-only, and the fallback removal):** it isn't applied in workers, which have no RTCPeerConnection
anyway. The script runs in every same-origin frame when its document starts, so a frame
created by the page (`window.frames[i]`, `window[i]`) is already patched when the page
reaches it; `contentWindow`, `contentDocument` and `window.open` are hooked as well for a
window reached before its own copy ran. A cross-origin frame is patched by its own copy and
cannot be inspected from the page anyway.

## 6. Time zone, geolocation, user agent

| Setting | Implementation | Native? | Gaps |
|---|---|---|---|
| User agent | `WKWebView.customUserAgent`, with presets in the editor | yes (string only) | `navigator.platform`, vendor, feature set and TLS fingerprint still identify WebKit on macOS (§2). Use the *Safari on macOS* preset; iPhone/iPad presets are UA-only and inconsistent |
| Time zone | JS: `Intl.DateTimeFormat` default `timeZone`; `Date` local getters and setters, `getTimezoneOffset` (with the sub-minute offsets of historical dates), the local constructor forms `new Date(y, m, d, …)`, `Date.parse` and `new Date(string)` for strings without an offset, `toString`, `toDateString`, `toTimeString`, `toLocale*String`, `getYear`/`setYear`. A worker made from a blob of the page (how fingerprinting scripts make theirs) starts with the same shim: the blob is handed to the engine as [shim, page's blob], so the worker keeps its blob: location, relative URLs, CSP, strict mode and line numbers | no | Workers loaded from a URL and service workers use the host zone (rewriting them would change their location); under a CSP without `'unsafe-eval'` a blob worker does too. JavaScriptCore lists the replacement `Date`'s and `Intl.DateTimeFormat`'s `length`/`name` before their statics (`Object.getOwnPropertyNames(Date)`), which no script function can avoid. `Intl.DateTimeFormat().format()` without an explicit zone follows the shim; other `Intl` constructors carry no zone |
| Geolocation, engine-level | In a profile's own process WebKit is given the profile's place the way Safari gives it its own: on macOS the engine has no location source and takes positions from the app that hosts it (`WKGeolocationManagerSetProvider`; WebGeolocationManagerProxy has a built-in CoreLocation provider on iOS only). `NativeGeolocation` hands it a provider on every web view's engine (a `WKProcessPool` is the C API's `WKContextRef` in Cocoa's WebKit) and answers the engine's permission question on whatever UI delegate Safari's code gives a web view (`_webView:requestGeolocationPermissionForOrigin:…`, and the older form): a fixed place allowed, Deny denied — as Safari answers a site its settings allow or deny. The page script is told `mode: 'native'` and leaves `navigator.geolocation` alone, so positions, errors and permission states are the engine's own, in every frame. The functions are looked up at run time; where one is missing the script answers as before. Checked in CI by `--geolocation-safari-check` (scripts/geolocation_safari_check.sh): a page in Safari's window must get the profile's place, 'prompt' before it asks and 'granted' after. The editor picks the place on a map (`LocationPicker`: Apple Maps' search and tiles, asked from the app's own process, not through the profile's proxy). |
| Geolocation | JS: `navigator.geolocation` answers as WebKit does for a user who said no ("User denied Geolocation") or who allowed the fixed coordinates; positions and errors are instances of the real interfaces with no own properties (values from the prototype getters and `toJSON`); `permissions.query({name:'geolocation'})` returns the engine's own `PermissionStatus`, 'prompt' until the page asks (WebKit's `hasBeenRequested`), then 'denied'/'granted' | no | The IP address (proxy) is what most sites actually use. The app has no `NSLocationUsageDescription` and no location entitlement, so CoreLocation can't be reached even if the shim is bypassed |
| Time zone from the proxy | At launch, a geolocation service (ipinfo.io, then geojs.io, ipwho.is, ipapi.co — one waited for alone at most 3 s, after which the next is asked as well, at once when one fails: a proxy that blocks or holds one leaves time for the others, and a slow one that answers is not cut off) is asked *through the profile's proxy* where it exits; the profile runs in that zone. The last answer per proxy is used on later launches when the new lookup takes over 1 s (and when a lookup fails), that lookup finishing in the background; with nothing remembered the launch waits for it at most 3 s (§4); a profile in a process of its own is not asked again by that process when the launch just found its location | — | A third-party request per launch (HTTPS, via the proxy only, no cookies). Editor → Location and Language → **Time zone and language**: *From the connection* (this), *Manual* (a time zone and a language of the profile's own; "this Mac's languages" is a choice) or *Random* (a place's own pair — a country's time zone and language, `LocalePlaces` — picked once and kept until another is picked). A time zone of the profile's own that is not where its proxy was last seen to come out is warned about: a page that compares the time zone with the IP's location sees they differ. Without any answer the host zone is used, and that is said where the user looks — a message, a mark in the profile's row and a line in the editor's location card, until the next launch — not only logged; a time zone that changed applies from the next launch |
| Language | Process-wide: set before WebKit's first process from the first launched profile's language of its own, else its proxy country's (`ProfileConfiguration.webLanguage(for:)`, `WebContentLanguage`) | partly | WKWebView has no per-view `Accept-Language` / `navigator.languages` API; later profiles of the same run share the first one's language — a profile in its own process (Settings → Behavior) has its own. The editor says so |

The shim logic is tested under Node (`scripts/test-shims.mjs`) against ICU, across
fixed-offset zones, DST transitions, 30-minute shifts and pre-1900 offsets, together with
the function-shape checks CreepJS runs (toString from the window and from a frame, own
keys, receiver errors). The key cases are also checked under JavaScriptCore by the self-test,
whose surface checks compare a macOS profile with a plain WKWebView key by key.

**Mobile views (iPhone, iPad):** the browser window is the declared device's screen (content
size and maximum size); nothing else is the device's. `navigator`, `screen`, the touch points,
CSS media queries, fonts, GPU and TLS say "Mac", as they do in Safari on a Mac told to send an
iPhone's User-Agent — the state this is.

## 7. History and bookmarks

- Recorded per profile, only for `http(s)` pages. User/password components and fragments
  are stripped before storing. Visits to the same URL are coalesced (count + last visit).
- Retention is per profile (default 90 days, cap 10 000 entries). Recording can be turned
  off; ephemeral profiles keep history in memory only.
- Same-document navigations (`history.pushState`) are recorded once WebKit has made them
  the current back/forward item. Provisional loads that never commit are not recorded.
- Bookmarks persist even for ephemeral profiles, because they are explicit user actions;
  they are encrypted like everything else.
- The Library window (bookmarks and history) is available only while the profile runs,
  because that is the only time the data is decrypted.

## 8. Passwords

Each profile has its own password vault (`passwords.bin`, AES-GCM under a key derived from the
profile key, §3). Safari's profiles share one set of passwords; here a login saved in one
profile is never offered in another. WKWebView on macOS 26 has no AutoFill API (Safari's
AutoFill and the system credential provider are not available to third-party web views), so
the browser does it itself, as close to Safari as that allows.

**What matches Safari**

| Safari | Here |
|---|---|
| After a sign-in: "Do you want to save your password for “site”?" — **Save Password / Not Now / Never for This Website** | The same question as a window sheet, after a submitted form, or after a click or Return when the sign-in fields leave the page (a sign-in by script). Navigation is not held up by it |
| A saved user name with a new password: **Update Password / Not Now** | The same; the same password again asks nothing |
| Change-password and sign-up forms (`autocomplete="new-password"`, two or three password fields) | The new password is the one saved, only when it equals its confirmation |
| Two-step sign-ins (user name, then password on the next page) | The user name of the first page is kept for 10 minutes for the password page of the same site |
| Nothing is filled without the user (Safari has asked for interaction since 2014) | Focusing a login field (or clicking it, or ↓) lists the site's saved logins under it; a login is filled only when chosen (click, or ↓/↑ and Return). A click in the list's first half second picks nothing (a page can focus a field just as the user clicks), Return only a row chosen with ↓/↑, and typing closes the list. Never on page load, never into hidden fields |
| Logins grouped by site; a saved login offered on other hosts of the same site | Registrable domain from the Public Suffix List (`login.example.co.uk` and `www.example.co.uk` share; `alice.github.io` and `bob.github.io` do not); the page's own host first, then the most recently used. The list shows the host of a login saved on another host |
| Filling fires `input`, then `change` (plain bubbling events) | The same events; React, Vue and Angular forms take the values |
| `autocomplete="off"` ignored for logins | Ignored |
| HTTP authentication sheet with **Remember this password** | The same; the next challenge is answered from the vault |
| Passwords app: locked until authenticated; search, view, copy, edit, delete; excluded websites | **⋯ → Passwords and Codes…**: locked until the master password is entered; the same operations, and the "Never" websites with **Remove** |
| AutoFill switch ("User names and passwords") | Per profile: **AutoFill user names and passwords** in the profile editor (on by default) |

**Where it differs, and why**

- **Detection is heuristic.** Without an AutoFill hook, a sign-in is a submitted form whose
  password the user typed (trusted `input` events), a form navigation (read during the policy
  decision, held for at most 0.3 s; `form.submit()` fires no `submit` event), or the password
  field leaving the page within 5 s of a click on a button or Return. A sign-in that does none
  of these (fields kept on the page after a fetch) is not offered; the toolbar's save button
  then saves what the fields hold. A failed sign-in is offered too, as Safari does at form
  submission.
- **What counts as typed.** Trusted `input` events: a page script that inserts text with
  `document.execCommand('insertText')` produces those too, so it can make a password look typed.
  The user still has to answer the question, which names the site.
- **Events are untrusted.** Values are set from the isolated world, so the `input`/`change`
  events have `isTrusted == false` (Safari's are trusted); a site that rejects untrusted
  events must be typed into. macOS 27 adds trusted events for AutoFill worlds; not used yet.
- **`:autofill` highlight and the key button** need a world with AutoFill scripting: public API
  from macOS 27, WebKit SPI from macOS 15.4 (`_WKContentWorldConfiguration.allowAutofill`,
  used only when present, as the private `WKPreferences` in §2). Without it the fields keep
  their own style. The self-test reports which world this WebKit gave.
- **Stricter than Safari:** a login saved on an https page is never offered on an http page
  (Chrome and Firefox refuse too; Safari offers it with a warning); ports must match.
- **Not implemented:** strong-password suggestions for sign-up forms, Touch ID before filling,
  "Recently Deleted", import/export, shared credentials between related domains, passkeys.
  (One-time codes are: see below.)
- **Frames.** A frame of another site is offered that site's logins only, under a header that
  names it; the frame's origin always comes from WebKit, never from the page. An opaque origin
  (sandboxed frame, `data:`) gets nothing. Placing the list under a field in a cross-origin
  frame uses the click into it.

**Isolation from pages.** The script runs in its own `WKContentWorld`, and its message handler
is registered only there: the page world has no `window.webkit` (as in Safari, checked against
a plain WKWebView and the runner's Safari, §2), cannot see or call the script, cannot post to
the handler, and cannot replace the prototypes it uses. A page script that writes a password and
submits the form is not offered for saving (self-test). Before writing a value the script checks
that the document is the one the user focused and that `location.origin` is the frame's.

**One-time codes.** A login can hold what makes its one-time codes (TOTP, RFC 6238: SHA-1,
SHA-256 or SHA-512, 6 to 8 digits; `OneTimeCode` in BrowserCore, checked against the RFC's
vectors). It is added in the login's editor: the secret as text, an `otpauth://totp/…` link, or
the site's QR code as a picture — pasted from the clipboard (⌃⇧⌘4 copies a part of the screen),
chosen as a file, or dropped in; Vision reads it on this Mac. The password manager shows the code
that stands now with the time it has left, and a click copies it (marked as concealed, like a
password). On a page, a field for a code — `autocomplete="one-time-code"`, or one named like it
(`otp`, `totp`, `2fa`, `mfa`, "verification code", …) — is offered the site's logins that have a
code, under the field, as a login's fields are; the code is made when the row is chosen, and
pages with one box a digit get a digit in each. A login may be a code alone, with no password.
A login without a code has **Add a One-Time Code…**. Nothing of a code is kept until the login is
saved: the editor says so of a code just added, and of a saved one that Save would remove (with
**Put the Code Back**); deleting a login that has a code says that the code goes with it.

- **The screen is not captured.** That needs the Screen Recording permission; the clipboard does
  the same for a QR code with none.
- **Not generated:** counter-based codes (HOTP), an authenticator app's export of several
  accounts (`otpauth-migration://`), Steam's and other sites' own schemes. Each is refused with
  its reason.
- **The second factor is in the vault.** Whoever opens the vault has both the password and the
  code; Help says to keep the site's backup codes.
- **Older versions.** `passwords.bin` is format 3 once a login holds a code (docs/UPDATES.md §4):
  a version from before codes refuses that profile's passwords rather than write the login back
  without its code. A profile with no code stays format 2.

**Storage.** Entries: origin, user name, password, note, changed and last-used dates, and the
one-time code's generator where there is one. The
"Never" websites and the switch are in the profile's encrypted configuration. The password
manager asks for the master password (one Argon2id derivation) each time it is opened.

## 8a. Cookie import

**⋯ → Import Cookies…** imports a cookie export into one profile. Formats: JSON (an array, an
object with `cookies` as Playwright's `storageState` and the DevTools protocol write it, a single
object, or JSON Lines; field names of EditThisCookie, Cookie-Editor, Puppeteer, Playwright,
Selenium and of Chrome's and Firefox's cookie databases, matched without regard to case, `_` or
`-`) and Netscape `cookies.txt` (curl, wget, yt-dlp and extensions; `#HttpOnly_` lines).

**Damaged files.** Everything importable is imported, the rest is reported with its place in the
file and the reason, before anything is imported:
- Text: UTF-8 with or without BOM (also a BOM at the start of a later line, from files joined
  together), UTF-16 with a BOM or recognised by its zero bytes, UTF-32 with a BOM. Bytes that are
  not valid text spoil only the cookie they are in ("damaged bytes").
- Files of another kind are named instead of being read as text: a browser's SQLite cookie
  database, Safari's binary cookies, a Selenium pickle, an archive, a web page.
- Netscape: read line by line (CRLF too); an empty value without its tab and fields separated by
  spaces are accepted; a line without seven fields is reported (eight: a tab in the value).
- JSON: also inside a string (AdsPower, Multilogin), under a wrapper (`{"result": {"cookies":
  …}}`, `{"data": […]}`) and as JSON Lines. When the file does not parse as a whole, each cookie
  object it still holds is read on its own (trailing commas tolerated): a broken entry, a cut-off
  end or text around the JSON costs only what it touches; the report names the damaged line.
- Each cookie is checked as a browser checks it: name and value characters (`;`, `=` in a name,
  control characters), 4096 bytes for name and value, a valid ASCII domain that is not a public
  suffix for a domain cookie (`.com`, `.co.uk`, `.github.io`: Public Suffix List), a path starting
  under 1024 bytes (a missing or relative one is `/`), an expiry that can be read and is not past
  (seconds, milliseconds, microseconds, Chrome's 1601-based time — also in yt-dlp's cookies.txt —,
  HTTP dates and ISO 8601; the DevTools protocol's `null` for "never" is 400 days, the most a
  browser keeps one), and the `__Secure-`/`__Host-` rules. Spaces around a name or value are
  dropped. The same cookie (name, domain, path) twice: the later one is imported, the earlier one
  listed as replaced.
- Refused with their own reason: a Chrome database row with an encrypted value (it would otherwise
  arrive empty and overwrite the real cookie), and partitioned (CHIPS) cookies: WebKit has no
  public way to set one in its partition, and without it the cookie would reach more sites.

**Into which store, and when.** A running profile gets the cookies at once. WebKit's
`setCookie` reports nothing, so the store is read back afterwards and every cookie WebKit did not
keep (missing, or with another value) is listed. A cookie that is not HttpOnly cannot replace an
HttpOnly one in WebKit (it keeps the old one, silently), so the import deletes the old one first.
CFNetwork keeps new cookies in memory and writes them to disk later, so after an import, and when
any profile stops before its data is sealed, the cookie store is asked to write them now
(`WKHTTPCookieStore`'s `_flushCookiesToDiskWithCompletionHandler:`, WebKit's own call; used only
where this WebKit has it, as the private `WKPreferences` in §2). Without it, cookies set in the
last moments before a stop could miss the sealed archive; the self-test found exactly that for
imported cookies. A stopped profile's website data is sealed (§3), so its cookies are queued,
encrypted with the profile's key, and put into its store at its next launch, before its first page
loads (they then show in the start page's request); the queue is removed. Session cookies live
until the profile stops, as in the browser they came from: the stop deletes them from the store.
WebKit's network process, which the profiles in this app's windows share, handed them back at the
profile's next launch while it kept running for another profile (CI run 436, macOS 26 and 27
alike; with no other profile running they went with it). For an ephemeral profile all imported cookies last for
that run only.

**Limits.** Domains in Unicode (IDN) are refused rather than converted; a value in a legacy encoding
(Windows-1251, Latin-1) shows as damaged bytes; the queue itself is local to this Mac (with cookie
sync on, the cookies join the synced ones at the profile's next launch, §8b); a profile that is
starting or being encrypted asks to try again a moment later.

## 8b. Profile sync: cookies and settings

With sync set up (**More → Sync…**), a profile's settings, passwords, bookmarks, history and —
with **Sync cookies with other devices** on (the default; never for an ephemeral profile) — its
persistent cookies sync between Macs, encrypted with the profile's key inside the sync envelope
(the server or folder sees no cookie name, value or domain). Format and rules:
[SYNC_FORMAT.md](SYNC_FORMAT.md).

- **Cookies** merge cookie by cookie (name, domain, path): the newer change wins, deletions
  included, and both devices end with the same set. A device records what a run changed when
  the profile stops (before its data is sealed), and applies the synced cookies when it launches,
  before the first page loads; cookies imported into a stopped profile are recorded at that
  launch, after the synced ones went in. Session cookies never sync; partitioned (CHIPS) cookies
  neither (WebKit cannot set them in their partition elsewhere). Turning the switch off empties the
  synced cookies on every device at the next sync; the cookie stores keep what they hold.
- **Settings** changed on two devices: the newer edit wins (the time of the last change made in
  the editor or the passwords' "Never" list), and the other device's version is kept next to it
  as `config.bin.conflict`, encrypted. A difference only in what the browser stores for itself
  (the proxy's location found at a launch) is no conflict.
- **Not synced:** localStorage, IndexedDB, caches and service workers, so a site that keeps its
  sign-in there rather than in a cookie is signed in on one Mac only. Changes reach another Mac
  only through a sync with every profile stopped, and at its next launch of the profile; a
  profile running on two Macs at once diverges until each has stopped and synced (then the
  later change of each cookie wins — the one recorded at the later stop).

## 8c. Session warm-up robot

**⋯ → Warm Up…** visits a list of pages in one profile, one after the other, to give it a
browsing past (cookies, history, site preferences) before it is used: a search first if one is
given (with the profile's search engine — DuckDuckGo unless the profile's editor names another;
see **Searches typed** below), then the addresses in their order (http and https
only, at most 50; other lines are listed with the reason and skipped). For each page it:
- loads it in **its own tab of the profile** — the profile's data store, proxy (fail-closed as
  always), User-Agent, shims and AutoFill, exactly as when the user browses; the visits go into
  the profile's history and their cookies into its store (and sync with the profile's cookies);
- stays a **random time** between the plan's two times (5–15 s by default, 2–300 s allowed), then
  waits 1–3 s before the next page;
- **scrolls** now and then (about every four seconds, at most six times per page, never in the
  last second; mostly down, sometimes back up), in flicks of slowing wheel steps;
- optionally **follows one link** before leaving: a plain link in view (`WarmUpLinkPolicy`) — on
  the same site for the user's addresses, to another site from the search results — never one
  opening a new window or a download, one to a file (`.zip`, `.pdf`, …) or one whose text or
  address speaks of signing out, deleting, buying, paying, ordering, subscribing or downloading,
  nor one hidden (by its own or an ancestor's opacity or visibility) or covered by something
  else; each link is judged by itself, `<base target>` included; it stays on that page half as long.

Nothing is typed or submitted but a search's words in the engine's own search box, and nothing is downloaded: while a run drives its tab, a response
the browser would save as a file fails as a load instead. A page that does not load is reported and skipped; one still
loading after 30 s is left as it is. A page counts as come once its own load has committed (or
ended, or — an address that only jumps within the page shown — the tab shows that page) and
nothing loads any more, not merely once the tab's address changed with nothing loading. The robot
asks for its first page while its new tab's blank load is still being decided, and WebKit drops
the pending address when it decides on that load, which can leave the tab with no address and
nothing loading until the page's own load starts. An earlier version could take that moment for
the page: the likely cause of an intermittent self-test failure in which a run's first page was
never scrolled.

**How it acts, and what a page can see.** The robot reads pages (scroll position, links) in a
content world of its own: it installs no script and no message handler, so the page world —
`window.webkit`, its globals, what `fingerprint_probe.js` measures — is the same as without it
(a one-shot `mousemove` listener it adds before a click lives in its world too).
While its window is the key window it scrolls with wheel events and clicks with mouse events
sent to the web view, as from a mouse with smooth scrolling (the click only after a trusted
pointer move was seen to reach that very link); these events are trusted. Otherwise — another app in
front, or a WebKit that does not take the events — it scrolls with `scrollBy` from its world
(the page sees the scrolling, with trusted `scroll` events, but no `wheel`) and clicks with the
link's `click()`, an **untrusted** click a page can tell apart. The sheet's run does not say which
was used; the self-test reports it. On the CI runner (macOS 26) the wheel events reached the pages
but synthesized pointer events did not, through any of the three ways tried (Quartz events and
AppKit events to the view, AppKit events to the window): there every followed link was clicked
with `click()`.

**Searches typed.** Seven searches in ten are typed as a person does: the robot opens the
engine's own page (`SearchEngine.homeURL`), accepts its consent page if one stands in the way,
takes the pointer to its search box on a curved path and clicks in it (only once a trusted
pointer move is seen to reach the box), types the words key by key on this Mac's keyboard
layout — 80–240 ms between letters, longer after a space, now and then a hesitation — checks the
box holds exactly what was typed, and presses Return. The others, and every search that cannot be
typed that way (a character no key of the layout types, as `ü` on a US layout; the engine's page
not loading; no search box in view; the click not reaching it or not focusing it; nothing loading
after Return), open the results by their address, as Safari's address bar does with words typed
into it. Never a script's click, focus or value: the box gets the same trusted key events a
keyboard gives (docs/PAGE_INPUT.md).

**Cookie banners.** A page's cookie banner is accepted when it is one of the well-known consent
tools — OneTrust, Didomi, Quantcast, Cookiebot, Usercentrics, TrustArc, Google's Funding Choices
and Google's own consent page — by that tool's own "accept" button, one to two seconds after the
page loads, as most people answer it. Nothing else on a page is pressed. The press is the
button's `click()` from the robot's world (untrusted); the consent it records is the same.

**User activation.** WebKit runs every script an app sends into a page as if the user had just
interacted (`callAsyncJavaScript` forces a user gesture), in any content world. The robot's reads
(scroll position, links) therefore mark the page as activated: `navigator.userActivation` reports
`hasBeenActive` even on a page the robot only scrolled with the wheel, where a visitor's would not
(wheel scrolling is no activation). It loads a page only while its tab is the one shown, because
a page loading in a tab out of sight has no window (outer size 0×0), which no visitor's has; it
waits meanwhile.

**Stopping.** Stop in the sheet; closing the robot's tab; stopping the profile (the robot is
stopped first, before the data store is released, and holds its tab only weakly, so the seal is
not held up); Lock and Quit (they stop every profile); a page that shows a dialog (alert, sign-in)
stops it and leaves the dialog to the user. The run goes on when the sheet is closed; the
profile list shows its progress.

**What a run left.** When a run is over the sheet lists the profile's cookies per site — the
registrable domain by the Public Suffix List, so `www.example.co.uk` and `.example.co.uk` are one
site and `alice.github.io` and `bob.github.io` are two — with how many of them the run added. The
robot reads the profile's own cookie store (`WKHTTPCookieStore`) when the run starts and when it
ends, where the profile runs: in a profile's own process the list comes back to the manager in the
run's status, like the page counts. A cookie counts as added when no cookie of the same name,
domain and path was there at the start; one a page set again with a new value is not new, and a
cookie that expired during the run is simply no longer listed. A run stopped part-way gets its
list a moment after it stops. At most 100 sites are listed, those the run added to first.

**Several profiles.** **More → Warm Up Several Profiles…** warms the ticked profiles with one plan
(a list composed for the proxy's country is put together for each profile's own country), up to
**Profiles at once** of them together — 1, 2 (the default) or 3, set on the queue's sheet; each
runs in its own profile process. A stopped profile is started without a window, warmed up, then
stopped and sealed again, and only then does the next waiting one start, so no more profiles than
that are ever decrypted for the queue. A profile the user already has open is warmed up where it runs and stays open. The sheet
says which profile is on ("profile 2 of 5") and what each run came to; the rest of the queue can
be cancelled, or the run going on stopped as well. A run started from a profile's own warm-up
sheet runs on its own and counts as one of those at once: the queue waits for a place rather than
run more beside it.

**Why a run stopped.** A run that did not finish says why at the foot of the sheet: the profile
was stopped, the robot's tab was closed, or a page asks for the user (a dialog); a run waiting for
its tab to be shown again says so while it waits. Stopped by the user it says nothing more.

**Last run.** When a run ends having visited at least one page — whoever started it — how it went
is kept for the profile (`warmup-last.bin`: when, pages that loaded, of how many, cookies gained,
finished or not), and the inspector says it beside **Warm Up…**: "2 days ago, pages: 14", or "not
yet" for a profile never warmed on this Mac.

**Repeating.** "Repeat on a schedule" in a profile's warm-up sheet runs the plan the sheet shows
every 1–168 hours, while the app is unlocked — never while it is locked, since nothing can be
decrypted then. A timer looks once a minute and puts the runs that are due into the same queue, so
scheduled runs take turns too and are started without a window like any queued run. A profile that
is running when its run comes up is taken to be in use — its windows are the user's — and is left
alone; the run is tried again ten minutes later. The first run comes one interval after repeating
is turned on (Start is there for a run now); after that, one interval after the profile's last run,
whoever started it. A run that could not start (the launch failed, the plan has no page) counts
as one, so a profile whose proxy is down is not relaunched every minute. A Mac that slept through
several intervals runs the profile once when it wakes, not once per interval missed. The schedule
and its last run (`warmup-schedule.bin`, with `warmup-last.bin`) stay on this Mac: they are not synced, and a profile
export does not carry them, since another Mac should not start a profile in the background
because this one was told to. The plan a scheduled run uses is the profile's saved one; a
ready-made or composed choice is cut and shuffled anew for each run, for the country the proxy
exits in at that time.

**Limits.** No browsing intelligence: the order is the list's, the links are chosen at random
among the allowed ones in view, the timing is random within fixed ranges. Rhythm and paths are
still a robot's, and sites that profile behaviour (or ask for a CAPTCHA) can tell; a CAPTCHA is not
answered, and a cookie banner of a tool not listed above is left as it is. It does not sign in,
fill forms (but a search box), play media or open new windows. Only one run per profile at a
time, and the queue runs at most three profiles at once; the plan (`warmup.bin`), the schedule
(`warmup-schedule.bin`) and the last run (`warmup-last.bin`) stay on this Mac. A
schedule only runs while the app is open and unlocked: it is a timer in the app, not a system
job. The ready-made lists (general, by interest, and 43 countries) are part of the app; nothing is
fetched to build one.

## 8c′. Restore points and a profile's history

**⋯ → Restore Points and History…** (and **Restore Points** in the inspector) keeps a stopped
profile as it is — its website data (`webdata.pbsa`), Safari's own state (`safarihome.pbsa`), its
history, its synced cookies and their baseline, its open tabs — to put back later: before a
sign-up, a warm-up or a cookie import, and back again if it went wrong. Not its settings,
passwords, codes or bookmarks: a restore never takes away what the person set up. The files are
copied as they are on disk, still encrypted under the profile's key (on APFS a copy is a clone), into
`restore-points/<id>/` in the profile's folder, with a description sealed under the profile's key
(`point.bin`). At most 20 per profile. A restore keeps the state it replaces as a point first
("Before a restore"), so it can be undone, then puts each file back atomically; a file the point
did not have (say no open tabs then) is removed — its copy is in the point just made.

Points are made and restored only while the profile is stopped and its data sealed: a profile
whose last session did not end properly (data still unsealed on disk) is to be launched and
stopped once first, and the sheet says so. A profile whose cookies sync: the next sync can bring
back cookies another Mac has — the point is this Mac's, the server's copy is not rolled back.

**History** (`journal.bin`): what happened to the profile, newest first — launched, warmed up (pages),
cookies imported (how many), its proxy changed (the proxy's name), a new IP (the IP), a point made,
restored. Nothing of a page — no address, no title. At most 300 events. The inspector shows the
latest four; the sheet, the rest.

Both stay on this Mac: not synced, not in a profile export; the profile's deletion takes them with
its folder.

## 8d. Paste as Typed

⌃⌘V types the clipboard's text into the page's focused field instead of pasting it, for a field
that refuses pasting or a page that watches how a field is filled (`HumanPaste`, with the plan
from `HumanTyping` in BrowserCore).

**What the page gets.** For each character, a key down and a key up on the key a Mac's US
layout has for it, or the Russian layout (ЙЦУКЕН) for a Cyrillic letter: `key` is the character,
`code` its key (`М` is `KeyV`, as on a Mac set to Russian), `shiftKey` for a capital or a shifted
symbol, with a `keydown` and `keyup` of `Shift` (`ShiftLeft`) around it, and an `input` event of
the inserted text. They are AppKit key events sent to the window (`NSWindow.sendEvent`), handled
by WebKit as the keyboard's: `isTrusted` is true, and the characters "ignoring modifiers" are
what a keyboard gives (Shift still applies: Shift-1 is `!` in both). The first key comes once the
shortcut's keys are let go and a moment later; then 60–180 ms between keys, 50–250 ms more after a
space or a punctuation mark, on about one key in 33 a pause of 0.4–1 s, each key held 30–110 ms.

**What a page can still tell.**
- The rhythm is random within fixed ranges: no person's rhythm, no typing mistakes and no
  corrections, no speed that changes with the word. A site that models typing can tell.
- The layout is the US one for Latin letters and the Russian one for Cyrillic, whatever this
  Mac's own layout is: on a Mac set to AZERTY or German, `code` differs from what its keyboard
  would send; a text that mixes the scripts switches layouts between letters as no one types.
- A character no key types on these layouts — an emoji, an accented letter, a new line, a tab —
  comes as an input method commits text: an `input` event with no `keydown` (Return would send a
  form, Tab would leave the field).
- Before typing, the app asks the page whether a field has the focus, in a content world of its
  own (`callAsyncJavaScript`): no page script sees it, but as every script an app runs, it counts
  as a user gesture — the page has had one anyway, the click into its field.

**Limits.** It types only while the page has the keyboard — the window is the key window and the
web view its first responder — as a person's typing goes only there: a key or a click of the
user's stops it (seen by a local event monitor, which the typed keys, sent to the window, never
reach), and so does another window or tab; the word after it says how many characters were
typed. At most 2000 characters. One typing at a time. In a profile shown in Safari's own window
(its own process) the item is added to Safari's Edit menu and types into Safari's web view that
has the keyboard; the command palette (⌘K) is the manager's and is not in that window's menu.

## 9. App Sandbox

**Releases are the build without the sandbox** (`SANDBOX=0`): only there does a profile get a process
of its own and Safari's own window, and `scripts/release.sh` refuses the sandboxed one and any app
that does not host Safari's chrome (docs/UPDATES.md §6, "Which build is released", which also says
what the build without the sandbox changes in signing, notarization and the system's trust).
`scripts/build-app.sh` still makes the sandboxed build by default, for development and CI.
`build-app.sh` checks the signature and fails if the sandbox state isn't what was requested.

**Entitlements** (`Resources/PrivacyBrowser.entitlements`):

| Entitlement | Needed for |
|---|---|
| `com.apple.security.app-sandbox` | the sandbox itself |
| `com.apple.security.network.client` | all WKWebView networking (WebKit's network process acts on the app's behalf), proxies, HTTP sync |
| `com.apple.security.network.server` | "What sites see" only: a listener on 127.0.0.1 (two ports the system picks), open while a snapshot is taken, that the measuring page in the profile's window and in Safari reports to (§2, *What sites see*). Nothing else listens: the automation API stays in the build without the sandbox |
| `com.apple.security.device.camera`, `…device.audio-input` | `getUserMedia`, after the in-app prompt (also required under the hardened runtime) |
| `com.apple.security.files.user-selected.read-write` | `<input type=file>` uploads; choosing the sync folder (Powerbox) |
| `com.apple.security.files.downloads.read-write` | saving downloads to `~/Downloads` |
| `com.apple.security.files.bookmarks.app-scope` | remembering the sync folder across launches (security-scoped bookmark) |
| `com.apple.security.temporary-exception.files.home-relative-path.read-write`: `/Library/Caches/<bundle-id>.update/` | the one folder outside the container the app writes: where it stages a checked update for the installer helper, which runs outside the sandbox and so never reads the container (docs/UPDATES.md §3) |

Not requested: location, contacts, calendars, printing, Apple Events, JIT (WebKit's JIT runs
in Apple's own WebContent process).

**What changes inside the sandbox:**

- Every path comes from `FileManager.urls(for:in:)`, so the vault, WebKit data, caches and
  temporary files all live in `~/Library/Containers/<bundle-id>/Data/`.
  `PRIVACYBROWSER_VAULT_DIR` must point inside the container.
- WebKit omits the bundle ID from its data paths when the process has a container.
  `WebKitDataLayout` handles both layouts and translates archives sealed by the
  unsandboxed build.
- The container is another layer of protection for the plaintext WebKit data of running
  profiles: other sandboxed apps can't read it. Unsandboxed processes of the same user still
  can, subject to macOS's container privacy protection (TCC "App Data" prompts on macOS 14+).

**Migrating from an unsandboxed build:** `Contents/Resources/container-migration.plist`
makes macOS move `~/Library/Application Support/PrivacyBrowser` (and any unsealed WebKit
data left by a crash) into the container on the sandboxed build's first launch. This is
one-way, and happens only when the container doesn't exist yet. CI verifies it with a
separate bundle ID.
`WebDataStoreVault` then restores archives sealed by the old build at the sandboxed
locations.

## 10. Threat model summary

**Protects against:**

- Someone who gets a copy of the disk or a backup while the app is locked, or while the
  relevant profile is stopped. They see only ciphertext and `vault.json` (KDF parameters).
- Websites in one profile reading another profile's cookies, storage, history or bookmarks.
- Casual IP and location leaks: fail-closed proxy, WebRTC off, geolocation denied.
- A sync server or sync folder learning profile names, settings, passwords, history,
  bookmarks, cookies or browsing data.
- Other sandboxed apps reading the app's data (App Sandbox).

**Does not protect against:**

- Malware or root on the running machine (it can read memory and live plaintext).
- Device fingerprinting that links profiles through hardware or rendering
  characteristics (§2).
- Offline guessing of a weak master password by anyone holding `vault.json`.
- A sync server rolling back to an older complete snapshot (no signed manifest).

**What other programs on this Mac can reach.** The app registers no URL scheme, no AppleScript
dictionary, no Services and no XPC service. The one way in from another program is the local
automation API ([docs/AUTOMATION_API.md](AUTOMATION_API.md)), and only once it is turned on (it is
off by default, and in the unsandboxed build only): HTTP on the loopback address, while the vault
is unlocked, answering only requests that carry its token and name `127.0.0.1` in `Host`, and none
from a web page (`Origin`, `Sec-Fetch-*`). Whoever has the token can start and stop the profiles,
open pages in them and read and write their cookies — not the passwords, the proxy credentials or
the vault. A program running as this user that can read the app's memory or watch the user type
is out of scope either way (above).

## 11. App lifecycle, appearance and language

**Window lifecycle.**
- Closing a profile's last window stops that profile and seals its website data. The app
  stays open, and the Profiles window comes back to the front.
- Only ⌘Q or **Lock** stops everything. Quitting with profiles running closes every window
  and seals every profile in the normal run loop, then quits (`QuitCoordinator`); sealing
  inside `terminate:` failed on ⌘Q because WebKit still held the focused page. A second ⌘Q
  during that wait doesn't start a second shutdown. If WebKit never lets go of a store, the
  quit forces the seal (archive + delete, `webdata.forced` marker) and logs it.
- Clicking the Dock icon with no window open shows the Profiles window again.
- **Settings → Startup** can ask before quitting: the question comes once the event that called
  `terminate:` has returned, before anything is stopped, and "no" leaves everything running
  (never asked at a logout, restart or shutdown). It can also start again, after the next unlock,
  the profiles that had a window when the app quit: their ids are kept in the encrypted
  `settings.bin`, only while that setting is on, and used once. **Restore tabs** keeps the http(s)
  addresses a profile left open (`tabs.bin`, encrypted with the profile's key, never synced or
  exported) and opens them at its next start: never for an ephemeral profile or one that keeps no
  history, and turning it off forgets them at the profile's next stop. What a file holds is
  filtered again when read: only web addresses are ever opened from it.
- **Settings** are this Mac's, in the app's defaults (per key; nothing secret in them — a chosen
  download folder is its path, and in the App Sandbox a bookmark to it). A profile in its own
  process gets the browsing ones over its channel when it starts and whenever they change
  (`ProfileCommand.preferences`), the download folder written out as a path, since that
  process's home is the profile's own. In Safari's own window, tabs, zoom and downloads follow
  Safari's settings instead.

**Crash fix.** Earlier builds released a browser window's controller from inside
`windowWillClose`. That could free the `NSWindow` while AppKit was still closing it (a
use-after-free), and the resulting crash took the whole app down, so it looked as if closing a
profile window quit the app. The callback now runs on the next run-loop turn, and
`BrowserSession.shutDown()` is idempotent. The self-test's `lifecycle:` checks cover this.

**Appearance.** The app's own windows are always dark (Lumen's theme, `Theme.swift`): each
window the app draws gets the Dark Aqua appearance and its SwiftUI views the dark colour
scheme. `NSApp.appearance` is left unset, so web content keeps following the Mac's
light/dark setting, as in Safari: the container of a window's web views is given the
system's appearance explicitly, and again whenever the setting changes
(`WebContentAppearance`). Pages therefore get the `prefers-color-scheme`, form controls and
scroll bars Safari would give them. Earlier builds forced the light appearance on
everything, web content included, so on a Mac set to dark, pages saw light where Safari
reports dark. Web content is not restyled; pages render as their sites define them.

**Launch screen.** Setting up and unlocking the vault happen on a dark launch screen: the
mark, a title and the form. While the key is derived (Argon2id), the form gives way to a
progress line, and the Profiles window fades in once the vault is open. Lock fades back to
the same screen. Under Reduce Motion the screen and the start page appear without motion.

**Browser window.** The toolbar is flat: the window's dark colour under a transparent title
bar, with no glass behind its items (macOS 26 would add it). It holds the Lumen mark, the
navigation buttons, the address field and the profile chip. The chip shows the profile's
glyph and name and, through a proxy, the flag of the country its exit IP is in. That country
comes from this launch's lookup, else from the location remembered for the same proxy, and
it is updated when a lookup finishes after launch.
- An empty new tab (⌘T, or a window opened without an address) shows a start page:
  - the profile's favourites (its top-level bookmarks);
  - its last visited pages;
  - where its proxy exits.
- The start page is a native view laid over the tab, not web content. Pages never see it,
  and nothing is loaded for it: no favicons are fetched, and the tiles show the site's
  initial instead. The tab's web view stays blank underneath until something is opened, and
  popups, links and tabs opened with an address never show it.
- The toolbar keeps Safari's 52 pt and the tab strip its 38 pt, so the `outerHeight −
  innerHeight` that pages measure is unchanged. CI's comparison with this Mac's Safari
  checks it.

**Language.**
- The interface is in Russian or English: Settings › Application › Language — as the system, Russian,
  English — and the same choice on the first screen, before the vault exists. "As the system" is the
  first of the Mac's own languages the app is translated into, else English. `-AppleLanguages` on
  the command line (`open Lumen.app --args -AppleLanguages "(en)"`) sets it for that run;
  `PRIVACYBROWSER_LANG` for the self-test and CI. A change takes a restart, which the setting offers:
  menus and windows take their language when the app starts.
- Until 1 November the interface was Russian whatever the Mac or the command line said, and every
  start wrote `AppleLanguages = (ru, en)` into the app's preferences on disk — which is why
  `open … --args -AppleLanguages "(en)"` came up in Russian (CI run 577: the English tables were in
  the bundle; the code chose Russian). The value earlier versions wrote is removed once, at the next
  start; a list the person set stays. `scripts/interface_language_check.sh` (CI) starts the app
  every way it can be started and fails on any other language than the expected one.
- Strings live in `Resources/{ru,en}.lproj/Localizable.strings` (both languages complete), which
  `build-app.sh` copies into the app bundle. Lookups go through an explicitly chosen bundle
  (`Localization.swift`), so the language is the same everywhere in a run; AppKit's own menus and
  panels follow it through this run's `AppleLanguages` (the argument domain, never the preferences
  on disk).
- A profile's own window takes the interface's language too: Safari's toolbar and its menu bar
  (measured on macOS 26.6.2 and 27.0.1, CI run 580). Safari's nibs are Base nibs with a strings
  table per language; made from the file's bytes, as the chrome's nibs had been, a nib kept Base's
  English — "File | Edit | View" over Russian items (CI run 579). Where Safari's bundle answers for
  the nib — Safari.app's, the menu bar's among them — it is now loaded by name and comes in the
  interface's language; nibs of Safari's frameworks, which do not answer from the cryptex, keep
  Base's words.
- Dates, times, sizes and numbers in the app's own windows are written in the interface's
  language with this Mac's region (`Localization.locale`, `Date.shown`), not in the Mac's
  language: a Russian interface on a Mac set to English said "yesterday" and "Oct 31" among
  Russian words. When the Mac's language is the interface's, the Mac's own locale is used, with
  its preferences. `scripts/check_localization.py` fails on formatting that takes the system's
  locale; the self-test checks "yesterday" in the interface's language.
- Run outside the app bundle (`swift run`, or Xcode's SwiftPM scheme), the strings tables
  are missing and keys are shown instead.
- Pluralisation is simplified ("Профилей: 3"); there is no `.stringsdict` yet.
- The interface's language and the language websites see are apart, both ways: an interface in
  Russian with a profile that looks American to every site, or the other way round.
  `navigator.language` and `Accept-Language` follow the profile — its own language (its editor),
  else its proxy country's, else this Mac's — never the interface's; and the profile's language
  never changes its window's. A profile's process is started with the websites' list on its
  command line, which WebKit reads; its interface's language is given apart and fixed before any
  bundle is asked for its words (`Localization.pinInterfaceLanguage`): a bundle keeps the
  language it is first asked in, and Safari's frameworks follow the app's. Switching the list
  after Safari's chrome is up is too late for WebKit, which has read it by then (CI run 579). The
  self-test's group "interface and websites' languages" starts profiles in their own processes
  with the two apart — interface Russian and profile German, interface English and profile
  Russian — and fails if either side shows the other's language. CI run 583 (a measurement branch)
  ran it on the build as committed, green on macOS 26.6.2 and 27.0.1, and on three builds broken on
  purpose, each red: the interface's language given to websites (pages saw "ru" for a German
  profile); the process's bundles left to its command line (Safari's chrome German-profile English,
  Russian-profile Russian, whatever the interface); and the manager's old way, below.
- Until 1 November, a profile's own language (set by hand or at random in its editor) did not
  reach its own process: the manager gave the process its proxy country's language or this Mac's,
  and the profile's own came too late inside it, after WebKit had read the list — a German profile
  showed websites "en-US" on CI's English runners (CI run 583).

