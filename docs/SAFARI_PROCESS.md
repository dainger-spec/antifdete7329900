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
with it Safari's entitlements, and injection is closed by SIP (Safari is a SIP-protected platform
binary with library validation). Measured on all three runners: every second Safari process saw the
first one's cookies, localStorage and IndexedDB (§3).

**Safari's own code, Apple-signed, one process per profile with its own data: yes, two ways.** Apple
ships two siblings of the Safari executable that do keep data apart:

| | SafariForWebKitDevelopment (inside Safari.app) | Safari web app (File > Add to Dock) |
|---|---|---|
| What runs | Safari's full UI (tabs, address bar, `window.safari`), Apple-signed, from the Safari cryptex | Apple's `Web App.app` host from the Safari cryptex: Safari's version, and Safari's entitlements plus nine web-app ones (on macOS 15 and 26 minus one App Intents key) |
| One process per profile | yes, one per profile folder | yes, one per web app |
| Own data | in the folder given as `CFFIXED_USER_HOME` (`Library/WebKit/SafariForWebKitDevelopment/…`, plus caches and `Library/Safari`); no cookie, localStorage or IndexedDB marker crossed to Safari or to the other profile (measured). **Cookies are not saved to disk** in such a folder: they last until the process quits. Settings are probably not per profile: no `Library/Preferences` appeared in a profile folder, so Safari's preferences most likely stay in the account's own, shared by every dev profile (not verified) | in a per-app container inside `~/Library/Containers/com.apple.Safari.WebApp`; no cookie, localStorage or IndexedDB marker crossed to Safari or to the other web app (measured; Safari's cookies are copied once, at creation). Shared by design: iCloud Keychain AutoFill and Safari's AutoFill settings, Safari's installed extensions and content blockers (Safari 18+, turned on per app), the system proxy, and one OS sandbox container for all web apps |
| Sites | any | one site (out-of-scope links open in the default browser) |
| Own proxy | yes, but only a host:port HTTP proxy (CONNECT for https://; no SOCKS5, no credentials) for this process's WebKit loads, through WebKit's `-WebKit2HTTPSProxy` / `-WebKit2HTTPProxy` launch arguments (measured with `-WebKit2HTTPSProxy`: only the profile given one went through it; `-WebKit2HTTPProxy`, for http:// loads, is read by the same WebKit code but was not tested; WebRTC was not tested) | no: launched with `--args -WebKit2HTTPSProxy …` (the only argument tried) a web app never loaded its page. With that proxy written to the shared `com.apple.Safari.WebApp` defaults domain instead, one web app loaded and bypassed it and the other never reported (macOS 14); on macOS 26 the value did not take (one run). Per-app defaults domains were not tried, and a web app has no proxy setting of its own |
| Created by | `safari_profile.py dev-launch --profile <folder>` | Safari's UI only; `safari_profile.py webapp-create` scripts the menu |
| Catch | session-only cookies; settings probably shared between dev profiles; no App Sandbox and none of Safari's entitlements: pages see `ApplePaySession` and `PushManager`, but the process lacks the entitlements both need; no iCloud, no Safari passwords; a developer binary Apple can change or drop in any update | not a browser: one site, no address bar, no AppleScript or WebDriver; creation needs Accessibility |
| TLS / HTTP/2 | identical to Safari on the same macOS (measured) | identical to Safari on the same macOS (measured) |

`scripts/safari_process/safari_profile.py` is the prototype for both (§6).

**TLS is not a reason to run Safari.** Safari does not build its ClientHello; the operating system's
TLS stack does, for Safari and for the other apps that load through it. Every process measured here
— Safari, a second Safari, both siblings — sent the same ClientHello and HTTP/2 preface as plain
Safari on the same Mac, and the harness agrees with tls.peet.ws. What changes the fingerprint is the
macOS version (§5). This project's WKWebView profiles already match Safari on TLS
(ISOLATION_AND_LIMITATIONS.md §2).

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

**Per web app (Safari 17+, macOS 14+).** File > Add to Dock writes a bundle with no executable to
`~/Applications`: Info.plist and an icon, with `LSTemplateApplication = true` and its own
`CFBundleIdentifier`. On macOS 26 the bundle soon carries an ad-hoc signature as well, added by the
system after it is written (LaunchServices, per Oakley); on macOS 14 and 15 it was still unsigned
when checked (§3). LaunchServices runs it with Apple's `Web App.app` from the Safari cryptex
(`/System/Volumes/Preboot/Cryptexes/App/System/Library/CoreServices/Web App.app`, present on all
three runners, same version as Safari). Its entitlements are Safari's plus nine web-app ones (TCC,
location, notification scheduling); on macOS 15 and 26 one App Intents key of Safari's is missing
(measured). Each web app is its own process with its own WebKit helpers. Its website data lives in a
nested container,
`~/Library/Containers/com.apple.Safari.WebApp/Data/Library/Containers/com.apple.Safari.WebApp.<UUID>/Library/WebKit/WebsiteData/`
(measured), so all web apps share one OS sandbox container, and the separation between two of them
is presumably Web App's own bookkeeping (an inference, not tested). Apple says a web app shares no
cookies, website data, history or settings with Safari; Safari copies the site's cookies once, at
creation, and no other website data
([WWDC23: What's new in web apps](https://developer.apple.com/videos/play/wwdc2023/10120/),
[Apple: web apps](https://support.apple.com/en-us/104996),
[tomayac](https://blog.tomayac.com/2023/06/07/web-apps-on-macos-sonoma-14-beta/),
[Oakley](https://eclecticlight.co/2023/10/05/how-do-sonomas-web-apps-work/)). The runners showed
exactly that: a new web app saw the HttpOnly and script cookies Safari had for the origin, and
none of Safari's localStorage or IndexedDB. Some things are deliberately not separated: iCloud
Keychain and credential-provider AutoFill work in web apps, Safari's AutoFill settings apply to them
(Safari 17.2+), and from Safari 18 the Safari Web Extensions and content blockers installed in
Safari can be turned on in a web app
([Safari 17.2](https://developer.apple.com/documentation/safari-release-notes/safari-17_2-release-notes),
[Safari 18](https://developer.apple.com/documentation/safari-release-notes/safari-18-release-notes)
release notes); the system proxy applies to them as to Safari.

## 3. What was tried, and what happened

Each experiment starts processes at a page of a local server that reports what storage the process
already sees, writes markers of its own (an HttpOnly cookie, a script cookie, localStorage,
IndexedDB), waits until every other process of the experiment has written its markers, and reports
again; each process is then quit and launched again alone, to see whether its markers persisted. A
local TLS server records every connection's ClientHello and, with a throwaway CA the runner trusts,
the HTTP/2 preface. No WebDriver drives these pages. Runners: macOS 14.8.9 (Safari 26.6), 15.7.9
(Safari 26.6.1), 26.6.2 (Safari 26.6.2), all Apple silicon. The results were the same on all three,
and in every round, unless a row says otherwise. The job logs of the "Safari process experiments"
workflow on this branch hold the raw data; the runs this table comes from are
[40744245384](https://github.com/dainger-spec/antifdete7329900/actions/runs/40744245384),
[40747713223](https://github.com/dainger-spec/antifdete7329900/actions/runs/40747713223) and
[40751872846](https://github.com/dainger-spec/antifdete7329900/actions/runs/40751872846).

| What was launched | Separate process | Own storage | Survives a relaunch | ClientHello and HTTP/2 = Safari's | Verdict |
|---|---|---|---|---|---|
| Safari, `open -b com.apple.Safari <url>` | — | Safari's container | yes | (the reference) | reference |
| A second Safari: `open -n -b com.apple.Safari` | yes: a new UI process with its own Networking process | **no**: it saw the first one's HttpOnly and script cookies, localStorage and IndexedDB at once, and reopened its tabs | yes (shared) | yes | not a profile |
| A second Safari with other `HOME`, `CFFIXED_USER_HOME`, `TMPDIR` (`open -n --env …`) | yes | **no**: same container; nothing was written under the other home | yes (shared) | yes | the environment is ignored |
| Safari's executable started directly with another home; URL by a PID-addressed Apple Event | yes | **no**: same container | yes (shared) | yes | the environment is ignored |
| A second Safari with `--args -WebKit2HTTPSProxy http://127.0.0.1:<port>` | yes | no (shared) | — | yes | **per-process proxy works**: that process's HTTPS went through the proxy; the first Safari's did not, except for its tab when the second process reopened it |
| Bit-identical copy of Safari.app run from another folder | yes (SIP is off on the runners) | **no**: it used Safari's own container and saw everything Safari had stored | yes (shared) | — | same identity, same data |
| Copy with a new bundle identifier, ad-hoc signed without entitlements | macOS 14 and 15: `Launchd job spawn failed` (errno 153); macOS 26: started, then crashed within seconds; kernel: `AppleMobileFileIntegrity _process_matches_constraint: Requirement not satisfied: Constraint not matched` | — | — | — | launch constraints |
| Copy with a new bundle identifier, ad-hoc signed with Safari's entitlements | no: `Launchd job spawn failed` (errno 153 on 14 and 15, 162 on 26); started directly it was killed (SIGKILL); kernel: `code signature validation failed fatally … Code has restricted entitlements, but the validation of its code signature failed` | — | — | — | AMFI |
| Safari as another macOS user, `launchctl asuser <uid> sudo -u <user> open -b com.apple.Safari` | no: `OSLaunchdErrorDomain Code=125 "Domain does not support specified action"` | — | — | — | needs that user's own GUI session |
| **SafariForWebKitDevelopment, two profile folders** (`safari_profile.py dev-launch`) | yes, one per profile | **yes**: neither saw the other's or Safari's markers | localStorage and IndexedDB yes; **cookies no**: they live in the process's memory only | yes | **works**, but cookies last one session |
| … SafariForWebKitDevelopment with the user's own home (control; last run only) | yes | its own store, apart from Safari's container | **yes, cookies included**: written to the real `~/Library/Cookies/com.apple.Safari.binarycookies` | yes | one such profile per user |
| … the second profile with `--https-proxy` (`-WebKit2HTTPSProxy`) | yes | yes | — | yes | **per-profile proxy works** |
| **Two Safari web apps** of one origin (File > Add to Dock, UI-scripted) and Safari | yes, one `Web App` process each | **yes**: neither saw the other's or Safari's markers, except Safari's cookies, copied once at creation | yes, all four markers | yes | **works**, one site per app |
| A web app launched with `--args -WebKit2HTTPSProxy …` | a process | — | — | — | never loads its start page |
| The same proxy written to the web apps' shared defaults domain (`com.apple.Safari.WebApp`; one run, macOS 14 and 26; since dropped from `experiments.py`) | a process each | — | — | — | macOS 14: one web app loaded and bypassed the proxy, the other never reported; macOS 26: the value did not take, neither reported. No proxy per web app found |

Notes on the rows:

- **Second processes share everything.** In every `open -n`, `--env` and direct-exec run the new
  process's first report already listed the other instance's HttpOnly cookie, script cookie,
  localStorage key and IndexedDB key; Safari's container files (`WebKit/WebsiteData/Default/…`,
  `Safari/SafariTabs.db`) were the ones written, and the alternative home stayed empty. The second
  process also reopened the first one's tab, so that tab's page ran in both.
- **Per-process proxy.** WebKit reads `WebKit2HTTPProxy`/`WebKit2HTTPSProxy` from the user defaults
  of a process whose bundle identifier starts with `com.apple.Safari`
  ([WebsiteDataStoreCocoa.mm](https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/WebsiteData/Cocoa/WebsiteDataStoreCocoa.mm));
  as launch arguments they land in that process's argument domain only. Measured: on
  SafariForWebKitDevelopment the CONNECT proxy saw only the profile started with the argument (g5,
  never f5). On Safari itself it saw the second instance and, in 7 of 9 runs, also the first
  instance's page: in every such run the second process had restored the first one's tab and loaded
  it again. The proxy belongs to the process, but a proxied second Safari also carries the first
  instance's restored tabs through it. These are HTTP CONNECT proxies given as URLs: no SOCKS5, no
  credentials.
- **SafariForWebKitDevelopment** is Apple-signed (`Software Signing` on 14 and 15, `macOS Software
  Signing` on 26), has no hardened runtime, and its only entitlements are
  `com.apple.security.cs.allow-dyld-environment-variables` and `…disable-library-validation`: no App
  Sandbox. Its main bundle is Safari.app, so it runs as `com.apple.Safari` with Safari's UI
  (`window.safari`, Safari's User-Agent, `ApplePaySession` and `PushManager` present). With
  `CFFIXED_USER_HOME=<profile>` it wrote `Library/WebKit/SafariForWebKitDevelopment/WebsiteData/…`
  (LocalStorage, IndexedDB, ResourceLoadStatistics), `Library/Caches/SafariForWebKitDevelopment/WebKit/…`
  (NetworkCache, HSTS, CacheStorage), `Library/Safari/SafariTabs.db` and `Library/HTTPStorages/…`
  inside the profile folder, and nothing in Safari's container. Cookies are the exception: with a
  profile home they were never written to disk — not in the profile, not in the real home — even
  after a clean quit by Apple Event, so they did not survive a relaunch (macOS 14, 15 and 26), while
  localStorage and IndexedDB did. Started with the user's own home (the control, in the last run),
  the same binary did persist cookies, to `~/Library/Cookies/com.apple.Safari.binarycookies` of the
  real home (macOS 14, 15 and 26). So with a profile home the process keeps cookies in memory only:
  it writes no cookie file, in the profile or in the real home, and it does not read the real-home
  file either — the profiles relaunched after the control had written it did not see the control's
  cookies. Why was not established. At most one SafariForWebKitDevelopment profile per user — the
  one on the real home — keeps cookies across restarts. Pages see two (macOS 26) or one
  (macOS 14, 15) fewer window properties than in Safari: `MediaSessionCoordinator`, and on 26
  `DigitalCredential`.
- **Web apps.** The bundle Add to Dock writes has no executable, only `Info.plist` and an icon. Its
  signature, checked right after creation, depended on the runner: on macOS 14 and 15 none
  (`codesign`: "code object is not signed at all"); on macOS 26 an ad-hoc bundle signature
  (`_CodeSignature/`, `Format=bundle`, `Executable=…/Contents/Info.plist`, `Signature=adhoc`) in 5 of
  6 checks, the sixth still unsigned, so the system adds it some time after creation. The Info.plist:
  `CFBundleIdentifier = com.apple.Safari.WebApp.<UUID>`, `LSTemplateApplication = 1`,
  `LSTemplateApplicationParameters = {CFBundleIdentifier = com.apple.Safari.WebApp, TemplateAppUUID,
  teamIdentifier = 0000000000, defaultarguments = 1}`, `Manifest = {name, start_url}`. The
  registration is kept in `~/Library/Application Support/com.apple.LaunchServicesTemplateApp.dv/HashesV1`.
  Each web app got its own nested container,
  `~/Library/Containers/com.apple.Safari.WebApp/Data/Library/Containers/com.apple.Safari.WebApp.<UUID>/`.
  A web app reports `navigator.standalone = true`, has no `window.safari` (its only window-property
  difference from Safari), and keeps `ApplePaySession` and `PushManager`. Launched with `--args
  -WebKit2HTTPSProxy …` it never requested its start page — plausibly because `defaultarguments` asks
  LaunchServices to pass the template's own arguments, which `--args` replaces (an inference).
- **UI scripting works on the runners.** GitHub's images grant Accessibility and Apple Events (to
  Safari and System Events) to `osascript` and `bash`, so File > Add to Dock was driven by
  `add_to_dock.applescript` on all three runners. On a user's Mac the terminal needs the same two
  permissions.
- **Copies.** `ditto` was refused copying Safari.app out of the cryptex (`Operation not permitted` on
  `Contents`); `cp -R` worked. The bit-identical copy kept Apple's signature and Safari's identifier,
  and with SIP off it ran — as Safari, in Safari's container. Both re-signed copies failed even with
  SIP off: the one that kept Safari's entitlements was killed by AMFI at exec ("Code has restricted
  entitlements, but the validation of its code signature failed"; through LaunchServices:
  `RBSRequestErrorDomain Code=5 "Launch failed"`, "Launchd job spawn failed", errno 153 on macOS 14,
  162 on 26); the one without entitlements was refused at spawn on macOS 14 and, on 26, started and
  crashed within seconds after AMFI logged "Constraint not matched" launch-constraint failures.

## 4. The walls

**Safari's data follows Safari's identity, and nothing outside the process can move it.** The
container comes from bundle ID + code signature + user, chosen inside the process when the sandbox is
set up; the system itself points `HOME`/`CFFIXED_USER_HOME` at it (measured: `open --env` and direct
exec with other values changed nothing). Every WebKit data path is derived from the process's
Library and Caches directories; no defaults key or environment variable overrides them
([WebsiteDataStoreCocoa.mm](https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/WebsiteData/Cocoa/WebsiteDataStoreCocoa.mm)).
The old WebKit1 keys (`WebDatabaseDirectory`, `WebKitLocalStorageDatabasePathPreferenceKey`) are read
only by WebKitLegacy. WebKit does have directory SPI (`_WKWebsiteDataStoreConfiguration`
`initWithDirectory:`, `_setCookieStorageFile`, …), but only code inside the process can call it. For
Safari that means Safari's own code: a launcher cannot inject into it (below).
SafariForWebKitDevelopment is the exception: its two entitlements (§3) exist so that `run-safari` can
load a locally built WebKit through `DYLD_FRAMEWORK_PATH`, so a launcher can also load its own code
into it (`DYLD_INSERT_LIBRARIES`), and that code could, for example, give each profile its own
cookie file through this SPI. This was not tried here, nor verified with SIP on; it also means that
anything able to set this process's environment can run code in it.
`NSWorkspace.OpenConfiguration.environment` and `.arguments` are ignored when the caller is sandboxed
([docs](https://developer.apple.com/documentation/appkit/nsworkspace/openconfiguration/environment)),
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
(measured). Safari is a platform binary with library validation (`flags=0x2000(library-validation)`,
no hardened-runtime flag), signed "Software Signing" on macOS 14 and 15 and "macOS Software
Signing" on 26, and holds 147–162 entitlements, 74–82 of them Apple-only `com.apple.private.*`
(macOS 14–26), among them `com.apple.private.webkit.webpush`, `com.apple.private.in-app-payments` and
`com.apple.private.launchservices.templateapp.creation` (measured on all three runners). A
bit-identical copy run from elsewhere meets launch constraints kept in the trust cache by cdhash
([Apple: launch constraints](https://developer.apple.com/documentation/security/defining-launch-environment-and-library-constraints),
[Oakley](https://eclecticlight.co/2023/10/24/where-safari-hides-and-bundled-apps-crash/)). A copy with
another bundle ID needs a new signature; an ad-hoc signature cannot carry restricted entitlements
— AMFI refuses them ([Apple DTS](https://developer.apple.com/forums/thread/791996)). Measured even with
SIP off: the copy that kept Safari's entitlements was killed at exec ("Code has restricted
entitlements, but the validation of its code signature failed"), and the one without them failed
launch constraints and crashed. A bit-identical copy ran (SIP off) but was simply Safari again, in
Safari's container. Safari's UI without Safari's identity is what SafariForWebKitDevelopment already
is, signed by Apple. The WebKit XPC services
(WebContent, Networking, GPU) are shared system components every WebKit app uses, so they are not
the wall.

**No injection with SIP on.** Safari is a SIP-protected platform binary with library validation; it
does not carry the hardened-runtime flag (`flags=0x2000(library-validation)` on all three runners).
With SIP on, dyld purges `DYLD_*` for it, library validation refuses foreign dylibs, and the kernel
denies `task_for_pid`/debugger attach
([SIP runtime protections](https://developer.apple.com/library/archive/documentation/Security/Conceptual/System_Integrity_Protection_Guide/RuntimeProtections/RuntimeProtections.html)).
All of it needs SIP off (and usually `amfi_get_out_of_my_way`), which is not stock macOS.

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
`ApplePaySession`) is a WebKit embedder preference (`EnabledBySetting=PushAPIEnabled` /
`ApplePayEnabled` in
[PushManager.idl](https://github.com/WebKit/WebKit/blob/main/Source/WebCore/Modules/push-api/PushManager.idl),
[ApplePaySession.idl](https://github.com/WebKit/WebKit/blob/main/Source/WebCore/Modules/applepay/ApplePaySession.idl)).
Both are off by default in WebKit on macOS
([UnifiedWebPreferences.yaml](https://github.com/WebKit/WebKit/blob/main/Source/WTF/Scripts/Preferences/UnifiedWebPreferences.yaml)),
and Safari's own (closed) code turns them on. That is why SafariForWebKitDevelopment, which runs
Safari's UI code without Safari's entitlements, exposes both objects (measured) while neither can
work there.

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
  tls.peet.ws's reading of the same Safari under safaridriver on macOS 14, 15 and 26: identical JA3
  hash, JA4 and Akamai string (on macOS 15 the first run's safaridriver session failed with HTTP 500;
  later runs matched). It also reproduces published captures:
  `t13d2014h2_a09f3c656075_e42f34c56612` for Safari 18.4 on macOS 15.4 and
  `t13d2013h2_a09f3c656075_7f0f34a4126d` for Safari 26.4 on macOS 26.4
  ([testssl.sh](https://github.com/testssl/testssl.sh/blob/3.3dev/etc/client-simulation.txt)).
- macOS 26 adds the X25519MLKEM768 key share
  ([WWDC25 314](https://developer.apple.com/videos/play/wwdc2025/314/)), and WebKit's build for
  macOS 26 sets the TLS 1.2 minimum, so `supported_versions` drops 1.0/1.1
  ([PlatformEnable.h](https://github.com/WebKit/WebKit/blob/main/Source/WTF/wtf/PlatformEnable.h));
  WebKit builds are per macOS version, so this too goes with the macOS version. macOS 14 still offers
  signature algorithm `0x0203`, which macOS 15 dropped; JA3 cannot tell macOS 14 from 15
  (`773906b0…` on both). macOS 14 sends Safari 17's HTTP/2 SETTINGS and `m,s,p,a`; 15 and 26 send
  Safari 18's.

What can differ at the network level is above TLS: iCloud Private Relay carries all of Safari's
traffic but only plain-HTTP traffic of other apps ([Apple DTS](https://developer.apple.com/forums/thread/683957)),
Advanced Tracking and Fingerprinting Protection hooks into Network.framework for Safari, and WebKit
picks its newer HTTP loader for Safari and for apps linked against the macOS 15 SDK or later. Private
Relay needs iCloud+, which the runners lack, and ATFP was not exercised here. The loader choice did
run, but every process measured here counts as Safari to WebKit (bundle identifier
`com.apple.Safari*`), so all of them used Safari's loader; a WKWebView app linked against an older
SDK gets the older loader, whose HTTP/2 SETTINGS and header order may differ from Safari's. That was
not measured here; this project's own match with Safari was measured separately
(ISOLATION_AND_LIMITATIONS.md §2).

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
  A `dev` profile is a folder; the process gets it as `HOME` and `CFFIXED_USER_HOME` and keeps its
  website data, caches and Safari files there — but not cookies, which last until the process quits
  (§3). URLs and quit requests go to the process by PID (a GURL / quit Apple Event: macOS asks once
  for Automation permission), so several profiles run side by side. A clean quit (`dev-quit`) keeps a
  profile's localStorage and IndexedDB, but its cookies are lost all the same. `webapp-create` drives
  File > Add to Dock through System Events (the terminal needs Accessibility).
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
  HTTP/2 preface are the operating system's, given an app linked against the macOS 15+ SDK (§5), and
  this project's profiles already match Safari on them. It would also lose the per-profile proxy:
  Safari has one proxy for all its profiles, and the only per-process knob is an HTTP CONNECT proxy
  through launch arguments, with no SOCKS5 and no authentication, against
  `WKWebsiteDataStore.proxyConfigurations` per data store here.
- **What Safari's identity gives is Apple Pay and Web Push that work, and only Apple-signed Safari
  processes have it.** SafariForWebKitDevelopment does not (it only shows the objects). A web app
  holds Safari's Apple Pay and Web Push entitlements (measured), and Apple documents Web Push for web
  apps ([WWDC23](https://developer.apple.com/videos/play/wwdc2023/10120/)); whether Apple Pay works in
  one was not tested (§8). So the likely options for "Apple Pay / Web Push must work" are a web app
  per site (Apple Pay still to be verified there with a Wallet card), or Safari itself with Safari's
  own profiles (one process, no per-profile proxy).
- **SafariForWebKitDevelopment is not something to ship.** Cookies do not persist in a profile
  folder, which alone rules it out for profiles people sign in with, short of the untested injection
  route in §4. It is also a developer executable without the App Sandbox, run with Safari's bundle
  identifier; Apple can change or remove it with any Safari update, and nothing in it is documented. It is useful as a measurement target: Safari's UI on a
  data folder we choose.
- **Two findings for the app itself.** (1) Within one app, every data store shares one WebKit
  Networking process (WebKit routes all sessions of a UI process to one network process on Cocoa);
  profiles are separate network sessions there, not separate processes. Process-level separation per
  profile would need one app process per profile. (2) WebKit decides "this is Safari" from the main
  bundle identifier (`com.apple.Safari`, Safari Technology Preview, or any `com.apple.Safari.*`;
  [RuntimeApplicationChecksCocoa.mm](https://github.com/WebKit/WebKit/blob/main/Source/WTF/wtf/cocoa/RuntimeApplicationChecksCocoa.mm))
  and gives such a process a few Safari-only defaults, such as the `WebKit2HTTP(S)Proxy` user
  defaults and the newer HTTP loader. `PushManager`/`ApplePaySession` are not among them: Safari's
  own code turns those preferences on (§4).

## 8. Caveats

- **SIP is disabled on GitHub's macOS runners** (`csrutil status`: disabled, on all three). Storage
  isolation does not depend on SIP (the App Sandbox works either way), but anything SIP guards —
  launch constraints for copies, `DYLD_*` stripping, debugger attach — behaves more permissively on
  a runner than on a stock Mac. The copy experiment's results are therefore an upper bound; the SIP-on
  behaviour in §4 comes from Apple's documentation and first-hand reports, not from these runs.
  SafariForWebKitDevelopment was run with SIP off; WebKit's own `run-safari` uses it on ordinary
  developer Macs, but it was not verified here with SIP on.
- Apple Pay and Web Push were checked for presence only (`typeof ApplePaySession`, `typeof
  PushManager`), not for function, in every process including the web apps: that needs a Wallet card
  and an APNs-backed push service.
- The web apps were created from a plain-HTTP local origin; their scope is that origin. Cookie copy at
  creation took cookies only, as Apple documents.
- Research hosts some subagents could not reach (eclecticlight.co, support.apple.com, webkit.org)
  were read through search excerpts; claims that rest on them are marked by their links.

## 9. What a shipping competitor does: BlackBird 2.5.19 (measured)

BlackBird (`cc.blckbrd.BlackBirdMac`, Team ID `DC2528FGSC`) is an anti-detect browser for macOS that
looks, to a user, as if it opened Safari's own window per profile. It does not run Safari, and it does
not run one of Safari's Apple-signed siblings (§1). It hosts **Safari's private UI frameworks inside
its own process**, one such process per profile. Measured on macOS (Apple silicon) with the app
running and one profile open: `pgrep`, `sudo launchctl procinfo`, `sudo lsof`, `ps -Eww`,
`codesign -d --entitlements`, `nm -mu` and `strings` over the bundle.

**One process per profile.** The manager process (`.../MacOS/BlackBird`, no arguments) spawns the same
executable again per profile:

```
BlackBird --session-id=<profile UUID> --native-storage-proof=<base64 JSON> \
          -AppleLanguages ("de-DE") -AppleLocale de-DE
```

Every WebKit helper of that profile reports `responsible pid` = the child and
`responsible path = /Applications/BlackBird.app/Contents/MacOS/BlackBird`, so the `WebContent`,
`Networking` and `GPU` processes seen while it runs are plain WKWebView helpers of the child, not
Safari's. The base64 argument is a licence binding (`"purpose":
"blackbird.native-profile-storage-binding"`, an account ID, a profile ID and a digest) and names the
scheme `"construction": "safari-profile-v2"`; passing it in `argv` makes it readable by any process of
the user.

**Why the separate process.** It buys what a single process cannot: `AppleLanguages`, `AppleLocale`
and `TZ` are read once per process, by WebKit for `Accept-Language`, `navigator.language(s)` and
`Intl`/`Date` — the limitation this project documents in `HostIdentity.swift` (`WebContentLanguage`),
where the first profile launched decides for the whole run. A process per profile makes each profile's
language and time zone native rather than a script override.

**Safari's own UI, by `dlopen`.** The profile process has
`/System/Library/PrivateFrameworks/Safari.framework` and `SafariShared.framework` open, down to
Safari's nibs (`StartPageCollectionSectionTitleView.nib`, `StartPageEmptyFolderItem.nib`,
`StartPagePasswordBreachWarningCollectionViewItem.nib`) and Safari's localized strings for the
profile's language (`de.lproj/Localizable.strings`), plus `PasswordManagerUI.framework`. The binaries
carry `" SafariShared not loaded?"` as a diagnostic, so this is the normal path, not a fallback.

**Private WebKit API.** `strings` over the main binary and `BBNativeNoiseSafari.framework` shows
`_WKWebsiteDataStoreConfiguration`, `_WKProcessPoolConfiguration`, `setInjectedBundleURL:`,
`setInjectedBundlePath:`, `injectedBundleInitializationUserData`, `_WKInspector`,
`_WKIconLoadingDelegate`, `_WKResourceLoadInfo`, and a path to Safari's injected bundle
(`Safari.framework/.../PlugIns/Safari.wkbundle`). None of these appear in `nm -mu`: they are loaded by
name at runtime. **The injected bundle was not in use when measured** — `lsof` over the profile's
`WebContent` processes shows no `.wkbundle` and nothing of BlackBird's mapped into them, so the web
processes run stock WebKit.

**Profile state in Safari's own file formats.** Under
`~/Library/Application Support/BlackBird/SafariFullGraph/<profile UUID>/`: `Bookmarks.plist`,
`History/History.db`, and a `PrivateSafariState/` directory holding `PerSitePreferences.db`,
`TabSnapshots/Metadata.db`, `BlockedBannerHighlights.db`, `Embeddings.db`,
`IgnoredSiriSuggestedSites.db`, `UserDefinedContentBlockers.db` — the databases Safari keeps in its
container, written per profile by Safari's frameworks pointed at that directory. Favicon and link
metadata caches (`Cache/favicons.db`, `Cache/LPLinkMetadata.db`) sit alongside.

**Everything is configured by environment variable** on the child process (`ps -Eww`), which is also
how the feature set reads:

```
BB_WK_DATASTORE_MODE=safari-profile-v2     BB_WK_DATASTORE_MODE_SOURCE=default
BB_SAFARI_CHROME=1                         BB_FULL_SAFARI_APPGRAPH=1
BB_FULLGRAPH_APPLE_HISTORY_VIEW=0           BB_FULLGRAPH_BLACKBIRD_HISTORY_WINDOW=1
BB_FULLGRAPH_KEEP_APPLE_HISTORY_MENU=1      BB_FULLGRAPH_ALLOW_NATIVE_BOOKMARKS_VISUALS=1
BB_FULLGRAPH_ALLOW_NATIVE_SIDEBAR_UPDATE=1  BB_FULLGRAPH_FAST_STARTUP=1
BB_OVERRIDE_LANGUAGES=de-DE                 BB_OVERRIDE_TIMEZONE=Europe/Berlin
BB_APP_LANGUAGE=1                           BB_UPDATE_USER_AGENT_AUTOMATICALLY=1
BB_NATIVE_AUTOFILL_ENABLED=1                BB_SEARCH_ENGINE=google
BB_ALLOW_QUIC=1                             BB_QUIC_FULL_TRANSPORT=0
BB_STORE_BROWSER_CACHE=1                    BB_SHOW_IP_CHANGE_WARNING=0
BB_RANDOMIZE_NEW_PROFILE_WINDOW_SIZE=1
DYLD_INSERT_LIBRARIES=/Applications/BlackBird.app/Contents/Frameworks/SafariZoomFix.dylib
```

So: Safari's chrome with their own history window over it, per-profile language and time zone at the
process level, a per-profile randomized window size, and a dylib of their own inserted into each
profile process to patch Safari's zoom behaviour.

**No special entitlements.** The signature carries only Developer ID keys, and notably **no
`com.apple.security.app-sandbox`**:

```
com.apple.security.cs.disable-library-validation       com.apple.security.cs.allow-jit
com.apple.security.cs.allow-dyld-environment-variables com.apple.security.cs.allow-unsigned-executable-memory
com.apple.developer.authentication-services.autofill-credential-provider
com.apple.developer.system-extension.install           com.apple.security.automation.apple-events
com.apple.security.network.client / .server            com.apple.security.device.camera / .audio-input / .microphone
com.apple.security.personal-information.location       keychain-access-groups: <team>.cc.blckbrd.BlackBirdMac,
                                                                               <team>.cc.blckbrd.vault.autofill
```

Its provisioning profile ("BlackBird Host") adds the NetworkExtension provider types, including
`packet-tunnel-provider-systemextension` — the same mechanism as this project's
`PacketTunnelExtension`. Nothing in the list is Apple-granted private entitlement: the whole of the
above follows from **not being sandboxed** plus `disable-library-validation` and
`allow-dyld-environment-variables`, which is what lets an unsandboxed process `dlopen` the private
Safari frameworks and insert its own dylib. This project signs its default build **with** App Sandbox
(`Resources/PrivacyBrowser.entitlements`) and treats `PrivacyBrowser-NoSandbox.entitlements` as a
debugging build, so this route is closed in the shipping configuration as it stands.

**What is worth taking, in order.** (1) One process per profile, for native per-profile
`AppleLanguages`/`AppleLocale`/`TZ` — the only item here that removes a limitation this project has
documented rather than adding surface. Keys must not travel in `argv`, where BlackBird puts its
licence blob. (2) `_WKWebsiteDataStoreConfiguration` for explicit per-profile WebKit directories,
alongside the public `WKWebsiteDataStore(forIdentifier:)` already used, in the style of
`WebKitPreferences.setBool`. (3) Per-profile window-size randomization. Hosting Safari's private UI
frameworks is a separate decision with a different risk profile: it requires giving up the App
Sandbox, and Apple can change or remove those frameworks in any update.

### 9.1 Hosting Safari's own window: measured, and what each blocker was

Safari's window class does run in a foreign process. On macOS 27.0.1 (Safari 26, framework build
22625), from an ad-hoc signed probe (`scripts/safari_chrome_probe.swift`), `BrowserWindowController`
was created, its window nib read, and the window shown on screen. Getting there meant four
blockers, each named by its own crash:

1. **A missing singleton.** `-windowDidLoad` sends new-window telemetry, which reads
   `WBSFeatureAvailability` and asserts: *"sharedSearchEngineObserver" in
   `+[WBSSearchEnginePreferenceObserver sharedObserver]`*. The frame under it in the trace names the
   cure, `+setUpSharedObserverWithSearchProviderContext:`, and it accepts `nil` — no context object
   is needed. In Safari this call comes from its app delegate.
2. **Safari's preferences are unreadable.** Its frameworks read the `com.apple.Safari` domain,
   which in a foreign process resolves to Safari's own container and is refused: *"accessing these
   preferences requires user-preference-read or file-read-data sandbox access"*. Everything they
   would have read comes back `nil`, and the first `-addAttribute:value:range:` with a `nil`
   `NSColor` (the address bar's "Not Secure" badge) is turned into a crash by
   `+[NSApplication _crashOnException:]`. `CFFIXED_USER_HOME` moves the domain into a directory of
   ours (§9, and `--paths` confirms `NSHomeDirectory()`, Application Support and Caches all follow),
   which is both the fix and the per-profile layout; a seeded `com.apple.Safari.plist` there is what
   supplies the values rather than skipping them.
3. **The main bundle is not Safari's.** Its chrome asks the main bundle for icons by name — CoreUI
   says so: *"unable to find a bundle 'NSBundle </tmp>' with identifier '(null)'"* — so icons are
   `nil` and an array built from one throws, in
   `-[UnifiedField _assistantButtonIconForContentOption:withSparkle:]`. Falling back to the private
   frameworks' own bundles in `+[NSImage imageNamed:]` was not enough for that button, which fetches
   its icon another way; stubbing that one method cleared the address bar entirely.
4. **Swift preconditions in features that need Safari's services.** Past layout,
   `-windowDidLoad` calls `autoTabClusteringEnabledDidChange` →
   `_setUpClusterManagerIfNeeded`, whose Swift code traps (SIGTRAP, `__swift__destructor` in the
   frames). Stubbing that method got the window on screen.

The working invocation, as a record of the minimum set:

```
CFFIXED_USER_HOME=<profile dir> ./sprobe \
  --prepare \                      # +[WBSSearchEnginePreferenceObserver setUpSharedObserver…:nil]
  --tolerate-nil-attributes \      # skip nil values in -addAttribute:value:range:
  --bridge-images \                # +[NSImage imageNamed:] falls back to the Safari bundles
  --stub image/UnifiedField/_assistantButtonIconForContentOption:withSparkle: \
  --stub nil/BrowserWindowController/_setUpClusterManagerIfNeeded \
  --try-init BrowserWindowController --show-window
```

Two things this does not tell us. The window was reached with telemetry and two features stubbed and
`nil` attribute values dropped, so what it draws is Safari's chrome minus whatever those supplied;
and the list is specific to this Safari build — each of the four is a private method or an
undocumented singleton, and any macOS update can add to it. That is the cost the competitor pays
with its own patch dylib and its `BB_FULLGRAPH_*` switches, and it is the reason items 1-3 of §9's
"what is worth taking" do not depend on any of this.

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
