# Real Safari as a separate process per profile

Can the genuine Safari.app run as one isolated process per profile on macOS 14+, each with its own
website data and settings, the way this project runs one `WKWebsiteDataStore` per profile? This
document answers that from two sources: a research pass over Apple's documentation, WebKit's
source and first-hand reports, and experiments on GitHub's macOS 14, 15 and 26 runners
(`scripts/safari_process/`, `.github/workflows/safari-process.yml`), which launched Safari every way
we could find and measured what each process stores and what it sends on the wire.

## 1. Answer

**The `Safari` executable: no.** It always keeps its data in its own App Sandbox container
(`~/Library/Containers/com.apple.Safari`), chosen by macOS from its bundle identifier, code signature
and user account. A second Safari process is easy to start (`open -n`, direct exec, LaunchServices),
but it opens the same cookie file and the same localStorage and IndexedDB databases; `HOME`,
`CFFIXED_USER_HOME` and `TMPDIR` are ignored. A copy with another identity loses Apple's signature and
with it Safari's entitlements, and injection is closed by SIP and the hardened runtime. Measured on
all three runners: every second Safari process saw the first one's cookies, localStorage and
IndexedDB (§3).

**Safari's own code, Apple-signed, one process per profile with its own data: yes, two ways.** Apple
ships two siblings of the Safari executable that do keep data apart:

| | SafariForWebKitDevelopment (inside Safari.app) | Safari web app (File > Add to Dock) |
|---|---|---|
| What runs | Safari's full UI (tabs, address bar, `window.safari`), Apple-signed, from the Safari cryptex | Apple's `Web App.app` host from the Safari cryptex: Safari's version and a superset of Safari's entitlements |
| One process per profile | yes, one per profile folder | yes, one per web app |
| Own data | in the folder given as `CFFIXED_USER_HOME` (`Library/WebKit/SafariForWebKitDevelopment/…`); nothing shared with Safari or other profiles (measured) | in a per-app container inside `~/Library/Containers/com.apple.Safari.WebApp`; nothing shared with Safari or the other web app (measured; Safari's cookies are copied once, at creation) |
| Sites | any | one site (out-of-scope links open in the default browser) |
| Own proxy | yes, an HTTP CONNECT proxy per process through WebKit's `-WebKit2HTTPSProxy` / `-WebKit2HTTPProxy` launch arguments (measured: only the profile given one went through it) | no: a web app launched with any arguments never loads its page (measured); no proxy setting exists |
| Created by | `safari_profile.py dev-launch --profile <folder>` | Safari's UI only; `safari_profile.py webapp-create` scripts the menu |
| Catch | no App Sandbox and none of Safari's entitlements: pages see `ApplePaySession` and `PushManager`, but the process lacks the entitlements both need; no iCloud, no Safari passwords; a developer binary Apple can change or drop in any update | not a browser: one site, no address bar, no AppleScript or WebDriver; creation needs Accessibility |
| TLS / HTTP/2 | identical to Safari on the same macOS (measured) | identical to Safari on the same macOS (measured) |

`scripts/safari_process/safari_profile.py` is the prototype for both (§6).

**TLS is not a reason to run Safari.** Safari does not build its ClientHello; the operating system
does, for Safari and for every WebKit app alike. Every process measured here — Safari, a second
Safari, both siblings — sent the same ClientHello and HTTP/2 preface as plain Safari on the same Mac,
and the harness agrees with tls.peet.ws. What changes the fingerprint is the macOS version (§5).
This project's WKWebView profiles already match Safari on TLS (ISOLATION_AND_LIMITATIONS.md §2).

**Where the wall is:** Safari's data follows Safari's identity, and Safari's identity is what grants
Apple Pay, Web Push, iCloud and the Keychain. You can have Safari's code with your own data folder
(SafariForWebKitDevelopment) or Safari's identity with Apple's per-site data separation (web apps),
but not Safari's identity with data folders you choose — not on stock macOS, not with any public or
private interface reachable from outside the process. The full table of what was tried is in §3,
the reasons in §4.

## 2. How Safari itself keeps data apart

Safari separates data in exactly three ways, and none of them is "one Safari process per profile".

**Per macOS user.** Safari's UI process is App Sandboxed (`com.apple.security.app-sandbox` is in its
entitlements on all three runners). Its preferences, cookies, WebKit website data and tab database
live in the user's container, `~/Library/Containers/com.apple.Safari/Data/Library/` (measured:
`WebKit/WebsiteData/Default/<origin>/<origin>/LocalStorage/localstorage.sqlite3`, `…/IndexedDB/…`,
`Safari/SafariTabs.db`, `Preferences/`); a few files stay in `~/Library/Safari` (History.db,
TopSites, favicon caches). macOS picks the container from the bundle identifier, the code signature
(bound to the container since macOS 14) and the user account when the sandbox is set up inside the
process, and points `HOME` and `CFFIXED_USER_HOME` at it. Another user = another home = another
container ([App Sandbox containers](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox),
[Safari data layout](https://github.com/moonD4rk/HackBrowserData/blob/main/rfcs/011-safari-data-storage.md)).

**Per Safari profile (Safari 17+, macOS 14+).** A named profile's website data sits in
`Container/WebKit/WebsiteDataStore/<lowercase-uuid>/` and its history in
`Container/Safari/Profiles/<UUID>/History.db` — the path WebKit builds for a data store created with
an identifier ([WebsiteDataStoreCocoa.mm](https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/WebsiteData/Cocoa/WebsiteDataStoreCocoa.mm)),
the mechanism this project uses through `WKWebsiteDataStore(forIdentifier:)` (whether Safari calls
the public initializer or the private `_WKWebsiteDataStoreConfiguration` is not documented; the
isolation is the same). Per profile: history, cookies and website data, Tab Groups, favourites,
which extensions are on, Web Push subscriptions. Shared: bookmarks, passwords/Keychain, general
settings, installed extensions, the proxy, the UI process, and one WebKit Networking process — on
Cocoa every data store of a UI process uses the same network process (`ensureDefaultNetworkProcess`
in [WebsiteDataStore.cpp](https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/WebsiteData/WebsiteDataStore.cpp)).
There is no API to create a profile or open a window in one: Safari's AppleScript dictionary has no
profiles ([safari-profile, tested on Safari 26.6](https://github.com/goreckim/safari-profile)), so
it is UI scripting (File > New Window > New *Profile* Window) or a Focus filter
([Apple: profiles](https://support.apple.com/en-us/105100)).

**Per web app (Safari 17+, macOS 14+).** File > Add to Dock writes a bundle without code to
`~/Applications` (Info.plist, icon, an ad-hoc signature made by LaunchServices) with
`LSTemplateApplication = true` and its own `CFBundleIdentifier`. LaunchServices runs it with Apple's
`Web App.app` from the Safari cryptex (`/System/Volumes/Preboot/Cryptexes/App/System/Library/CoreServices/Web App.app`,
present on all three runners, same version as Safari). Its entitlements are Safari's plus nine
web-app ones (TCC, location, notification scheduling); on macOS 15 and 26 one App Intents key of
Safari's is missing (measured). Each web app is its
own process with its own WebKit helpers. Its website data lives in a nested container,
`~/Library/Containers/com.apple.Safari.WebApp/Data/Library/Containers/com.apple.Safari.WebApp.<UUID>/Library/WebKit/WebsiteData/`
(measured), so all web apps share one OS sandbox container and the separation between two of them is
Web App's own bookkeeping. Apple says a web app shares no cookies, website data, history or settings
with Safari; Safari copies the site's cookies once, at creation, and nothing else
([WWDC23: What's new in web apps](https://developer.apple.com/videos/play/wwdc2023/10120/),
[Apple: web apps](https://support.apple.com/en-us/104996),
[tomayac](https://blog.tomayac.com/2023/06/07/web-apps-on-macos-sonoma-14-beta/),
[Oakley](https://eclecticlight.co/2023/10/05/how-do-sonomas-web-apps-work/)). The runners showed
exactly that: a new web app saw the HttpOnly and script cookies Safari had for the origin, and
none of Safari's localStorage or IndexedDB.

## 3. What was tried, and what happened

Each experiment starts processes at a page of a local server that reports what storage the process
already sees, writes markers of its own (an HttpOnly cookie, a script cookie, localStorage,
IndexedDB), waits until every other process of the experiment has written its markers, and reports
again; each process is then quit and launched again alone, to see whether its markers persisted. A
local TLS server records every connection's ClientHello and, with a throwaway CA the runner trusts,
the HTTP/2 preface. No WebDriver drives these pages. Runners: macOS 14.8.9 (Safari 26.6), 15.7.9
(Safari 26.6.1), 26.6.2 (Safari 26.6.2), all Apple silicon. The results were the same on all three
unless a row says otherwise.

RESULTS_TABLE

Notes on the rows:

RESULTS_NOTES

## 4. The walls

**Safari's data follows Safari's identity, and nothing outside the process can move it.** The
container comes from bundle ID + code signature + user, chosen inside the process when the sandbox is
set up; the system itself points `HOME`/`CFFIXED_USER_HOME` at it (measured: `open --env` and direct
exec with other values changed nothing). Every WebKit data path is derived from the process's
Library and Caches directories; no defaults key or environment variable overrides them
([WebsiteDataStoreCocoa.mm](https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/WebsiteData/Cocoa/WebsiteDataStoreCocoa.mm)).
The old WebKit1 keys (`WebDatabaseDirectory`, `WebKitLocalStorageDatabasePathPreferenceKey`) are read
only by WebKitLegacy. WebKit does have directory SPI (`_WKWebsiteDataStoreConfiguration`
`initWithDirectory:`, `_setCookieStorageFile`, …), but only the embedding app can call it — Safari's
code, not a launcher. `NSWorkspace.OpenConfiguration.environment` and `.arguments` are ignored when
the caller is sandboxed ([docs](https://developer.apple.com/documentation/appkit/nsworkspace/openconfiguration/environment)),
and `open --env HOME=…` was a LaunchServices sandbox-escape vector Apple closed
([CVE-2023-27966](https://nvd.nist.gov/vuln/detail/CVE-2023-27966)).

**A second process is not a second profile.** LaunchServices starts another instance on request
(`open -n`, `createsNewApplicationInstance`); it is the same bundle, signature and user, so the same
container. Each Safari process starts its own Networking process
([`_MultipleInstances`](https://github.com/WebKit/WebKit/blob/main/Source/WebKit/NetworkProcess/EntryPoint/Cocoa/XPCService/NetworkService/Info-OSX.plist))
over the same cookie file and databases, and the second process also restores the first one's tabs
(measured: the first instance's page loaded again in the second).

**A copy is not Safari.** Since macOS 13 Safari ships in the sealed App cryptex;
`/Applications/Safari.app` is a symlink to `/System/Cryptexes/App/System/Applications/Safari.app`
(measured). Safari is a platform binary with library validation, signed "macOS Software Signing",
and holds 147–162 entitlements, 74–82 of them Apple-only `com.apple.private.*` (macOS 14–26), among them
`com.apple.private.webkit.webpush`, `com.apple.private.in-app-payments` and
`com.apple.private.launchservices.templateapp.creation` (measured on all three runners). A
bit-identical copy run from elsewhere meets launch constraints kept in the trust cache by cdhash
([Apple: launch constraints](https://developer.apple.com/documentation/security/defining-launch-environment-and-library-constraints),
[Oakley](https://eclecticlight.co/2023/10/24/where-safari-hides-and-bundled-apps-crash/)). A copy with
another bundle ID needs a new signature; an ad-hoc signature cannot carry restricted entitlements
— AMFI refuses them ([Apple DTS](https://developer.apple.com/forums/thread/791996)) — so it either does
not start or starts as an unentitled, unsandboxed program: Safari's UI without what makes Safari
Safari. That is SafariForWebKitDevelopment, which Apple already signs. The WebKit XPC services
(WebContent, Networking, GPU) are shared system components every WebKit app uses, so they are not
the wall.

**No injection with SIP on.** Safari has the hardened runtime and library validation: dyld ignores
`DYLD_*` without `com.apple.security.cs.allow-dyld-environment-variables`, foreign dylibs are refused,
and `task_for_pid`/debugger attach is denied
([hardened runtime](https://developer.apple.com/documentation/security/hardened-runtime)). All of it
needs SIP off (and usually `amfi_get_out_of_my_way`), which is not stock macOS.

**Another user needs its own GUI session.** Separate macOS users do give separate, genuine Safaris,
but GUI code must start inside the target user's own GUI login session
([TN2083](https://developer.apple.com/library/archive/technotes/tn2083/_index.html),
[Apple DTS](https://developer.apple.com/forums/thread/692749)). Measured: `launchctl asuser <uid>
sudo -u <user> open -b com.apple.Safari` for a user without a GUI login fails with
`OSLaunchdErrorDomain Code=125 "Domain does not support specified action"`. Apple provides no command
to create a second GUI session headlessly (Fast User Switching or a Screen Sharing "log in as
yourself" session).

**VMs are capped.** A macOS guest per profile is fully isolated (Safari, network, proxy, OS version),
but Apple silicon runs at most two macOS guests
([VZError.virtualMachineLimitExceeded](https://developer.apple.com/documentation/virtualization/vzerror/code/virtualmachinelimitexceeded)),
and GitHub's arm64 runners, being VMs, cannot run them at all.

**safaridriver is ephemeral.** Automation windows are isolated from the user's data and "like a
private browsing session … start from a clean slate"; one session per Safari; `navigator.webdriver`
is true ([About WebDriver for Safari](https://developer.apple.com/documentation/webkit/about-webdriver-for-safari)).
Safari plus Safari Technology Preview (a different WebKit build with its own container; current
builds need macOS 26.4+) is the most it gives: two
([Testing with WebDriver](https://developer.apple.com/documentation/webkit/testing-with-webdriver-in-safari)).

**The features that differ are gated by identity, not by the process.** Web Push works only for a
host app that `webpushd` accepts — current WebKit checks the host's audit token for
`com.apple.private.webkit.webpush` ([PushClientConnection.mm](https://github.com/WebKit/WebKit/blob/main/Source/WebKit/webpushd/PushClientConnection.mm));
Apple Pay needs Safari's payment entitlements. Their *presence* in JavaScript (`PushManager`,
`ApplePaySession`) is a WebKit preference (`EnabledBySetting=PushAPIEnabled` / `ApplePayEnabled` in
[PushManager.idl](https://github.com/WebKit/WebKit/blob/main/Source/WebCore/Modules/push-api/PushManager.idl),
[ApplePaySession.idl](https://github.com/WebKit/WebKit/blob/main/Source/WebCore/Modules/applepay/ApplePaySession.idl))
that WebKit turns on for any process whose bundle identifier starts with `com.apple.Safari`
([RuntimeApplicationChecksCocoa.mm](https://github.com/WebKit/WebKit/blob/main/Source/WTF/wtf/cocoa/RuntimeApplicationChecksCocoa.mm)).
That is why SafariForWebKitDevelopment, which runs under Safari's bundle identifier without Safari's
entitlements, exposes both objects (measured) while neither can work there.

## 5. TLS and HTTP/2

Safari does not build its ClientHello. WebKit's Networking process opens an `NSURLSession`, and
CFNetwork / Network.framework run the handshake on the operating system's private BoringSSL; the only
TLS setting WebKit makes is the minimum version (TLS 1.2, in WebKit builds for macOS 26+)
([NetworkSessionCocoa.mm](https://github.com/WebKit/WebKit/blob/main/Source/WebKit/NetworkProcess/cocoa/NetworkSessionCocoa.mm),
[PlatformEnable.h](https://github.com/WebKit/WebKit/blob/main/Source/WTF/wtf/PlatformEnable.h),
[Apple DTS](https://developer.apple.com/forums/thread/765432)). So the fingerprint belongs to the
macOS version, not to the process or the Safari version. Measured, with Safari 26.6.x on all three:

| macOS (runner) | Safari | JA4 | JA3 | HTTP/2 (Akamai) |
|---|---|---|---|---|
| 14.8.9 | 26.6 (19624.4.5.18.1) | `t13d2014h2_a09f3c656075_14788d8d241b` | `773906b0efdefa24a7f2b8eb6985bf37` | `2:0;4:4194304;3:100\|10485760\|0\|m,s,p,a` |
| 15.7.9 | 26.6.1 (20624.5.1.18.3) | `t13d2014h2_a09f3c656075_e42f34c56612` | `773906b0efdefa24a7f2b8eb6985bf37` | `2:0;3:100;4:2097152;9:1\|10420225\|0\|m,s,a,p` |
| 26.6.2 | 26.6.2 (21624.5.1.11.3) | `t13d2013h2_a09f3c656075_7f0f34a4126d` | `ecdf4f49dd59effc439639da29186671` | `2:0;3:100;4:2097152;9:1\|10420225\|0\|m,s,a,p` |

- Every process in §3 that loaded its page — Safari, `open -n`, `open --env`, direct exec, both
  SafariForWebKitDevelopment profiles, the web apps — sent a ClientHello identical to plain Safari's
  on the same runner in every non-random field (cipher, extension, group, signature-algorithm,
  ALPN, key-share and version lists, GREASE removed), and the same HTTP/2 SETTINGS, WINDOW_UPDATE and
  pseudo-header order. Navigations and `fetch` differ only in their request headers, as they do in
  Safari.
- The harness's own reading (`harness.py`: JA3, JA4 per the FoxIO specification, Akamai) matches
  tls.peet.ws's reading of the same Safari under safaridriver on macOS 14 and 26 (macOS 15:
  safaridriver failed to start a session in that run). It also reproduces published captures:
  `t13d2014h2_a09f3c656075_e42f34c56612` for Safari 18.4 on macOS 15.4 and
  `t13d2013h2_a09f3c656075_7f0f34a4126d` for Safari 26.4 on macOS 26.4
  ([testssl.sh](https://github.com/testssl/testssl.sh/blob/3.3dev/etc/client-simulation.txt)).
- macOS 26 adds the X25519MLKEM768 key share and drops TLS 1.0/1.1 from `supported_versions`
  ([WWDC25 314](https://developer.apple.com/videos/play/wwdc2025/314/)); macOS 14 still offers
  signature algorithm `0x0203`, which macOS 15 dropped; JA3 cannot tell macOS 14 from 15
  (`773906b0…` on both). macOS 14 sends Safari 17's HTTP/2 SETTINGS and `m,s,p,a`; 15 and 26 send
  Safari 18's.

What can differ at the network level is above TLS: iCloud Private Relay carries all of Safari's
traffic but only plain-HTTP traffic of other apps ([Apple DTS](https://developer.apple.com/forums/thread/683957)),
Advanced Tracking and Fingerprinting Protection hooks into Network.framework for Safari, and WebKit
picks its newer HTTP loader for Safari and for apps linked against the macOS 15 SDK or later. None of
these runs on a CI runner without iCloud, and none changes the ClientHello.

## 6. The prototype

`scripts/safari_process/`:

- **`safari_profile.py`** — Safari's code as one process per profile.
  ```bash
  # Safari's UI with its own data folder (SafariForWebKitDevelopment), optionally its own proxy
  python3 scripts/safari_process/safari_profile.py dev-launch --profile ~/SafariProfiles/a https://example.com
  python3 scripts/safari_process/safari_profile.py dev-launch --profile ~/SafariProfiles/b \
      --https-proxy http://127.0.0.1:3128 https://example.com
  python3 scripts/safari_process/safari_profile.py dev-open --profile ~/SafariProfiles/a https://example.org
  python3 scripts/safari_process/safari_profile.py dev-quit --profile ~/SafariProfiles/a
  python3 scripts/safari_process/safari_profile.py list --profiles ~/SafariProfiles

  # A Safari web app per site (Safari's entitlements, its own data)
  python3 scripts/safari_process/safari_profile.py webapp-create "Shop A" https://shop.example
  python3 scripts/safari_process/safari_profile.py webapp-launch "Shop A"
  ```
  A `dev` profile is a folder; the process gets it as `HOME` and `CFFIXED_USER_HOME` and keeps
  everything there. URLs and quit requests go to the process by PID (a GURL / quit Apple Event:
  macOS asks once for Automation permission), so several profiles run side by side, and a quit lets
  Safari write its cookies. `webapp-create` drives File > Add to Dock through System Events (the
  terminal needs Accessibility).
- **`experiments.py`** — everything in §3, using `safari_profile.py` for the two working paths:
  `python3 scripts/safari_process/experiments.py --out build/safari-process --setup-hosts --trust facts reference baseline webapps webapp-proxy open-n env-home exec-home sfwd copy other-user`
  (`--setup-hosts`, `--trust` and `other-user` use sudo: hosts entries, a throwaway CA, a throwaway
  user — meant for disposable machines).
- **`harness.py`** — the report page and server, the TLS/HTTP2 capture (JA3, JA4, Akamai), a logging
  CONNECT proxy; `test_harness.py` checks it (JA4 against the FoxIO examples, capture with curl).
- CI: `.github/workflows/safari-process.yml` runs the tests on Linux and the experiments on
  macos-14, macos-15 and macos-26; results are in the job log and the `safari-process-*` artifacts.

## 7. What this means for PrivacyBrowser

- **Keep WKWebView.** On the network, real Safari per profile gains nothing: the ClientHello and
  HTTP/2 preface are the operating system's (§5), and this project's profiles already match Safari on
  them. It would also lose the per-profile proxy: Safari has one proxy for all its profiles, and the
  only per-process knob is an HTTP CONNECT proxy through launch arguments, with no SOCKS5 and no
  authentication, against `WKWebsiteDataStore.proxyConfigurations` per data store here.
- **What Safari's identity gives is Apple Pay and Web Push that work, and only Apple-signed Safari
  processes have it.** SafariForWebKitDevelopment does not (it only shows the objects); a web app does,
  for one site. So the honest options for "Apple Pay / Web Push must work" are a web app per site, or
  Safari itself with Safari's own profiles (one process, no per-profile proxy).
- **SafariForWebKitDevelopment is not something to ship.** It is a developer executable without the
  App Sandbox, run with Safari's bundle identifier; Apple can change or remove it with any Safari
  update, and nothing in it is documented. It is useful as a measurement target: Safari's UI on a
  data folder we choose.
- **Two findings for the app itself.** (1) Within one app, every data store shares one WebKit
  Networking process (WebKit routes all sessions of a UI process to one network process on Cocoa);
  profiles are separate network sessions there, not separate processes. Process-level separation per
  profile would need one app process per profile. (2) WebKit decides "this is Safari" from the main
  bundle identifier, and turns on Safari-only behaviour (the `PushManager`/`ApplePaySession`
  preferences, the `WebKit2HTTP(S)Proxy` defaults, site quirks) for any `com.apple.Safari*`
  identifier — which is how SafariForWebKitDevelopment gets them without Safari's entitlements.

## 8. Caveats

- **SIP is disabled on GitHub's macOS runners** (`csrutil status`: disabled, on all three). Storage
  isolation does not depend on SIP (the App Sandbox works either way), but anything SIP guards —
  launch constraints for copies, `DYLD_*` stripping, debugger attach — behaves more permissively on
  a runner than on a stock Mac. The copy experiment's results are therefore an upper bound; the SIP-on
  behaviour in §4 comes from Apple's documentation and first-hand reports, not from these runs.
  SafariForWebKitDevelopment was run with SIP off; WebKit's own `run-safari` uses it on ordinary
  developer Macs, but it was not verified here with SIP on.
- Apple Pay and Web Push were checked for presence only (`typeof ApplePaySession`, `typeof
  PushManager`), not for function: that needs a Wallet card and an APNs-backed push service.
- The web apps were created from a plain-HTTP local origin; their scope is that origin. Cookie copy at
  creation took cookies only, as Apple documents.
- Research hosts some subagents could not reach (eclecticlight.co, support.apple.com, webkit.org)
  were read through search excerpts; claims that rest on them are marked by their links.

## Sources

Primary: Apple developer documentation and DTS answers linked above; WebKit source
([WebKit/WebKit](https://github.com/WebKit/WebKit), `main` as of October 2026); the runners' own
`codesign`, `sw_vers`, `csrutil` and file listings (the `facts` step of the workflow). Secondary:
[Howard Oakley](https://eclecticlight.co/), [tomayac](https://blog.tomayac.com/2023/06/07/web-apps-on-macos-sonoma-14-beta/),
[a macOS 14.3.1 LaunchServices dump](https://github.com/JJTech0130/launchservices/blob/cfd49f75854df2311a4db53be1266854fe36beb5/samples/all.txt),
[testssl.sh client simulations](https://github.com/testssl/testssl.sh/blob/3.3dev/etc/client-simulation.txt),
[curl-impersonate signatures](https://github.com/lexiforest/curl-impersonate/tree/main/tests/signatures),
[FoxIO JA4](https://github.com/FoxIO-LLC/ja4/blob/main/technical_details/JA4.md),
[TrackMe (tls.peet.ws)](https://github.com/pagpeter/TrackMe),
[actions/runner-images](https://github.com/actions/runner-images/blob/main/images/macos/scripts/build/configure-tccdb-macos.sh).
