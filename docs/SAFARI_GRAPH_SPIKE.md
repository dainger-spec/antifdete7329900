# Safari.framework in our process (SAFARI_GRAPH spike)

Status: research spike, with a prototype behind a flag in the unsandboxed build only. The
one-process and process-per-profile modes stay on WKWebView and keep passing the whole self-test
(CI run 261: 294/294 in each build; Safari reference 449 keys identical, 0 must-match keys differ).

The question: can this app load the system `Safari.framework` into its own process and use Safari's
own interface instead of its WKWebView chrome? Measured on GitHub's macOS 26 and macOS 15 runners
(`scripts/safari_graph/`, CI job `safari-graph`), with a script for the same check on a Mac with SIP
on (`scripts/safari_graph/manual_check.sh`, instructions in Russian in
`scripts/safari_graph/MANUAL_CHECK.ru.md`).

## 1. Answer

**NO-GO for using Safari's interface; the frameworks do load, which is the one surprise.** The system
`Safari.framework` and its whole stack load into our ordinary unsandboxed, hardened-runtime, ad-hoc
process with **no** entitlement exception — library validation admits Apple platform code, and there
is no code-signing wall (CI runs 262–264, macOS 26 and 15, SIP off). But Safari's *interface* does not
run: started through its own entry point `SafariMain()`, Safari loads its menu and begins
`-[AppController awakeFromNib]`, then aborts inside WebKit at a private `WKWebViewConfiguration`
selector during Safari's web-extension setup (run 264, both runners). No window, no page, in any
configuration. Safari's UI is built for Safari's identity — its private entitlements, document and
application controllers, nib and services — which a third-party process cannot have and cannot sign
for. The spike therefore keeps the app on WKWebView and ships only the **compatibility gate with
automatic fallback** (§7), which is green (20/20, §8). Details and the effort a hypothetical GO would
take: §11.

**SIP.** SIP is off on every GitHub macOS runner (`csrutil status`: disabled, printed by each run).
Everything below that CI measured is therefore an upper bound for a stock Mac: what fails there
fails with SIP on too; what works there needs the manual check. Each result says which it is.

## 2. Results

CI runs (each has a macOS 26 and a macOS 15 job):

| Run | What it measured | macOS 26 job | macOS 15 job |
|---|---|---|---|
| [261](https://github.com/dainger-spec/antifdete7329900/actions/runs/40773287860) | round 1: `dlopen` matrix; the main self-test with the new code | (cancelled: no runner) | [log](https://github.com/dainger-spec/antifdete7329900/actions/runs/40773287860/job/123115883909) |
| [262](https://github.com/dainger-spec/antifdete7329900/actions/runs/40775459638) | round 2: Safari's staged frameworks; window controller; `SafariMain()`; new-mode self-test; surface | [log](https://github.com/dainger-spec/antifdete7329900/actions/runs/40775459638/job/123123487279) | [log](https://github.com/dainger-spec/antifdete7329900/actions/runs/40775459638/job/123123487167) |
| [263](https://github.com/dainger-spec/antifdete7329900/actions/runs/40776698799) | round 3: `SafariMain()` in a bundle with Safari's Info.plist; the gate by build | [log](https://github.com/dainger-spec/antifdete7329900/actions/runs/40776698799/job/123127738837) | [log](https://github.com/dainger-spec/antifdete7329900/actions/runs/40776698799/job/123127739041) |
| [264](https://github.com/dainger-spec/antifdete7329900/actions/runs/40777723768) | round 4: Safari's interface in a clean process; crash reports; the mapped-build fact | [log](https://github.com/dainger-spec/antifdete7329900/actions/runs/40777723768/job/123131228465) | [log](https://github.com/dainger-spec/antifdete7329900/actions/runs/40777723768/job/123131228436) |

Runners: macOS 26.6.2 (25G83) with Safari 26.6.2 (build 21624.5.1.11.3), image macos-26-arm64
20261021.0445.8; macOS 15.7.9 (24G830) with Safari 26.6.1 (20624.5.1.18.3) from the App cryptex,
image macos-15-arm64 20260907.0337.1. SIP off on both.

| # | Question | Measurement | Conclusion | SIP |
|---|---|---|---|---|
| 1 | How does Safari start its interface? | `facts.sh`: Safari.app's executable (190–192 KB) imports one symbol, `_SafariMain`, from `/System/Library/PrivateFrameworks/Safari.framework`; it carries two `LC_DYLD_ENVIRONMENT` commands, `DYLD_FRAMEWORK_PATH` and `DYLD_LIBRARY_PATH` = `/System/Cryptexes/App/System/Library/StagedFrameworks/Safari`; Info.plist: `NSPrincipalClass` = `BrowserApplication`, `NSMainNibFile` = `MainMenu`. SafariForWebKitDevelopment is the same stub. | Safari's executable is a stub: `main()` calls `SafariMain()`, which runs the application from Safari's Info.plist. The `DYLD_*` paths make dyld take the copies of WebKit and of Safari's frameworks that ship with that Safari. | none |
| 1 | Does `Safari.framework` load into our process? | Probe, plain hardened-runtime ad-hoc binary. macOS 26: no staged frameworks exist; the user's Safari.framework (21624.5.1.11.3, in the dyld shared cache only) loads in every variant. macOS 15: the install name gives the base system's older Safari.framework (20621.3.11.11.3), which loads; the user's (20624.5.1.18.3, in the App cryptex) fails: `Symbol not found: _OBJC_CLASS_$_WBSNSHTTPCookieTranscoder … Expected in: …/SafariShared` (13 of 20 staged frameworks fail the same way against the base system's copies). | **Yes on macOS 26, with no exception.** On an older macOS with a newer Safari, only by taking Safari's staged frameworks the way Safari does (next row). No code-signing refusal anywhere: library validation admits Apple platform code. | the macOS 26 load is expected to be SIP-independent (no DYLD variable involved); to confirm with the manual check |
| 1 | Minimal hardened-runtime exceptions | Each exception alone (§3), plain, with `DYLD_VERSIONED_FRAMEWORK_PATH` on the staged frameworks, and with that path linked into the binary (`LC_DYLD_ENVIRONMENT`). | **None** changes any result on the runners. macOS 26: none needed. macOS 15 + Safari 26: the staged stack (all 20 frameworks) loads with the path in the environment or linked in, in every variant including no exception. | **SIP-dependent**: with SIP off dyld kept `DYLD_VERSIONED_FRAMEWORK_PATH` for a hardened-runtime process without `allow-dyld-environment-variables`; with SIP on the hardened runtime is documented to drop it. Manual check: `base+env` against `dyld+env`, and `linked-base` |
| 2 | Does the interface come up and load a page? | No (run 264, both runners). `SafariMain()` in a bundle with Safari's Info.plist loads Safari's `MainMenu` nib and runs `-[AppController awakeFromNib]`, which sets up Safari's web extensions, builds a `WKWebViewConfiguration` and calls the private `-[WKWebViewConfiguration _setShouldRelaxThirdPartyCookieBlocking:]`, which raises `NSException` and aborts (SIGABRT, exit 134, ~0.4 s after the call; full backtrace in §4). The window-controller path aborts earlier, on Safari's `NSDocumentController` internals (`_commonInit` unrecognized). With SIP off. | **No.** Safari's interface does not come up in our process. Its app start aborts inside WebKit during Safari's own setup; no window and no page in any configuration, on the base stack or the user's staged one. | none expected (application-level); Keychain/iCloud prompts may differ on a real account |
| 3 | Pointing Safari at our profile's storage | Safari's code started by `SafariMain()` in a bundle with our bundle identifier and a throwaway `HOME`/`CFFIXED_USER_HOME` (run 263): its WebKit data store under `Library/WebKit/<our id>/WebsiteData/`, caches under `Library/Caches/<our id>/`, and `Library/Caches/com.apple.Safari/TabSnapshots` (§5). | It follows the process's home folder and bundle identifier, so one process per profile with `HOME`/`CFFIXED_USER_HOME` on that profile's folder. (Safari.app itself ignores `HOME`: its container is fixed by its identity.) | none |
| 3 | Two processes kept apart (cookies, localStorage, IndexedDB) | New mode (gate → WKWebView): two profiles, `--safari-graph-selftest`, run 262: cookies, localStorage and IndexedDB not shared. Two processes: the process-per-profile group of the main self-test (runs 243, 261). | Kept apart in the new mode, as in both existing modes. Safari's own UI in two of our processes: apart by construction (different home folders), not measured: the interface never came up (§4). | none |
| 3 | Where history and bookmarks are written | Safari: `~/Library/Safari/History.db`, per Safari profile `…/Safari/Profiles/<UUID>/History.db`, bookmarks shared by all its profiles (docs/SAFARI_PROCESS.md on `claude/macos-privacy-browser-prototype-0ns2oj`, §2). Safari's code in our process: its WebKit data store and caches under the process's home, named after our bundle identifier; it stopped before `History.db` or bookmarks. This app: `history.bin`, `bookmarks.bin` per profile, encrypted. | Safari.app: in its container and `~/Library/Safari`, fixed by its identity. Safari's code in our process: under the process's `HOME`, named after our bundle identifier. This app: per profile, encrypted, in every mode. | none |
| 4 | Language, locale, proxy, time zone, fonts, WebRTC, user scripts | New mode: language and locale set per process (`WebContentLanguage.decide`), time zone in the engine per profile (`_WKProcessPoolConfiguration.timeZoneOverride`), run 262: `de-DE`, Intl `de`, Europe/Berlin and Asia/Tokyo (−540) in two windows. | All existing configuration points apply in the new mode, since it renders in WKWebView. Safari's own UI: only language and locale reach it (process-wide); §6. | none |
| 5 | Noticing an unsuitable Safari and falling back | `SafariGraph.evaluate()` (§7); self-test: forced fallback, version gate (26.0 and 26.6.2 pass; 27.0, 18.6, empty and junk fail). Measured: macOS 26.6.2 (run 263) passes every step (both builds 21624.5.1.11.3); macOS 15.7.9 with Safari 26.6.1 falls back at the build check (20621.3.11.11.3 against 20624.5.1.18.3). | The gate takes the WKWebView chrome whenever the Safari this process would get is not the user's Safari, does not load, or lacks its browser classes. | the gate's own answer follows the measured load (row 2) |
| 6 | The profile against real Safari | `safari_reference.py` on the new-mode window, run 262 (macOS 26): **449 keys identical, 15 differ (reported), 0 must-match keys differ**, as in the existing modes (runs 243, 261). | Identical where it must be. What differs is Safari's payment and push interfaces (`ApplePaySession`, `PaymentRequest`, `PushManager`, `ApplePaySetup`, `MerchantValidationEvent`, `DigitalCredential`, `MediaSessionCoordinator`), which WebKit exposes only to a process with Safari's private entitlements; Safari's UI in our process does not carry them either. | none |
| 7 | What depends on the Safari version | Two Safari builds in the same runs (26.6.2 on macOS 26, 26.6.1 on macOS 15): where the framework is (the cryptex's staged folder on macOS 15, only the shared cache on 26), which copy a process gets (20621 or 20624 on macOS 15, 21624 on 26), and Safari's private classes and selectors. | Everything this mode would build on is private and moves with each Safari release; §9. | — |

## 3. Hardened-runtime exceptions, one at a time

The probe (`scripts/safari_graph/probe.m`) is signed ad hoc with the hardened runtime
(`codesign --options runtime`) and one entitlements file per variant
(`scripts/safari_graph/entitlements/`). Each variant runs plain, with
`DYLD_VERSIONED_FRAMEWORK_PATH` pointing at Safari's staged frameworks (`+env`), and two further runs
use a binary that carries that path itself (`linked-*`, linker flag `-dyld_env`).

| Variant | Exception | macOS 26 | macOS 15, plain | macOS 15, `+env` |
|---|---|---|---|---|
| `base` | none | Safari.framework (user's) loads | base system's Safari.framework loads; Safari 26.6.1's fails: symbol skew | all 20 staged frameworks load |
| `libval` | `com.apple.security.cs.disable-library-validation` | same | same | same |
| `dyld` | `com.apple.security.cs.allow-dyld-environment-variables` | same | same | same |
| `jit` | `com.apple.security.cs.allow-jit`, `allow-unsigned-executable-memory` | same | same | same |
| `all` | the four above and `disable-executable-page-protection` | same | same | same |
| `linked-base` | none; the path is in the binary (`LC_DYLD_ENVIRONMENT`) | loads | all 20 staged frameworks load | — |

The errors, verbatim, are in each run's log (`GRAPH dlopen=… err="…"`). The only kinds seen:
- `Symbol not found: <symbol> Referenced from: <staged framework> Expected in: <base system's copy>`:
  version skew on macOS 15 (e.g. `_OBJC_CLASS_$_WBSNSHTTPCookieTranscoder` in SafariShared,
  `JSC::ArrayBuffer::~ArrayBuffer()` in JavaScriptCore for WebKit);
- `tried: … (no such file)`: paths that do not exist on that release (`/System/Library/StagedFrameworks`,
  a `Frameworks` folder inside Safari.app).

None was a code-signing refusal (`not valid for use in process`, `library load disallowed by system
policy`): Safari.framework is Apple platform code (`Software Signing`, no Team ID), which library
validation admits into any process.

**Minimal set:** none on macOS 26. On an older macOS with a newer Safari: none on the SIP-off runners;
with SIP on, `allow-dyld-environment-variables` for the environment route, and unknown for the linked
route — the manual check answers both. The project's own threat model rules the environment route out
anyway: `allow-dyld-environment-variables` would let any process that can start this app inject code
with `DYLD_INSERT_LIBRARIES` (docs/PROCESS_PER_PROFILE.md, *Threats*).

## 4. The interface

Safari's executable is a stub: its `main()` calls `SafariMain()`, which runs `NSApplicationMain` with
Safari's Info.plist (principal class `BrowserApplication`, main nib `MainMenu`). The probe reaches
that code two ways; both abort. On the SIP-off runners (an upper bound), the frameworks were the
user's Safari (macOS 26: the shared-cache stack; macOS 15: the staged stack via
`DYLD_VERSIONED_FRAMEWORK_PATH`).

**Window controller directly.** `[[BrowserWindowController alloc] init]` (after making Safari's
`BrowserDocumentController` first) raises `NSInvalidArgumentException`: Safari's `NSDocumentController`
subclass calls `-_commonInit`, which the macOS `NSDocumentController` on the runner does not have —
Safari's window controller expects Safari's own application scaffolding, not a bare process.

**`SafariMain()` in a bundle with Safari's Info.plist** (our bundle identifier, symlinks to Safari's
resources, so `NSApplicationMain` makes `BrowserApplication` and loads `MainMenu`). It gets furthest
and aborts the same way on macOS 15 (Safari 26.6.1, staged) and macOS 26 (Safari 26.6.2), ~0.4 s in,
with this backtrace (run 264, from the crash report the probe collected):

```
+[NSException raise:format:]
WebKit    -[WKWebViewConfiguration(WKPrivate) _setShouldRelaxThirdPartyCookieBlocking:]
Safari    +[WebKitPreferencesManager webExtensionWebViewConfigurationForExtensionsController:relatedWebView:]
SafariSharedUI  -[WBSWebExtensionsController initializeWebKitControllerIfNeededFromSettings:]
Safari    -[AppController _createExtensionControllersIfNeededForProfileServerID:]
Safari    -[AppController _loadExtensionsInProfile:]
Safari    -[AppController awakeFromNib]
AppKit    -[NSIBObjectData nibInstantiateWithOwner:options:topLevelObjects:]   (loading MainMenu)
```

So Safari's application object is created and its main menu loads, but as `AppController` wakes it
sets up Safari's web extensions and calls a private WebKit configuration selector that raises.
`application:openURLs:` is never reached (`NSApp.delegate` is still nil at 15 s), so the test page is
never requested; `NSApp.windows` is empty. `SafariMain()` in the plain probe (no Safari Info.plist)
makes a plain `NSApplication` with an empty menu and no delegate, and never builds a window at all.

Before it aborts, Safari's code does write its WebKit data store and caches under the process's home,
keyed by our bundle identifier, and a `com.apple.Safari/TabSnapshots` cache (§5).

**Why this is a wall, not a bug to step over.** Getting past this one selector would only reach the
next piece of Safari's private application setup. Safari's interface assumes Safari's identity: its
168 entitlements, 86 of them `com.apple.private.*` (measured on macOS 15), its document and application controllers, its nib,
its web-extension and profile services. A third-party process has none of that and cannot sign for
the restricted entitlements (AMFI refuses them; measured even with SIP off on the earlier
`claude/macos-privacy-browser-prototype-0ns2oj` spike). The crash is the first of many, and all of it
is undocumented and version-locked (§9).

## 5. Profile data

Where Safari keeps its data, as Safari.app (docs/SAFARI_PROCESS.md on
`claude/macos-privacy-browser-prototype-0ns2oj`, §2, measured there): in its App Sandbox container,
`~/Library/Containers/com.apple.Safari/Data/Library/` (website data, cookies, tabs, preferences), chosen
by macOS from Safari's bundle identifier and signature; a few files in `~/Library/Safari` (`History.db`);
per Safari profile `…/WebKit/WebsiteDataStore/<uuid>/` and `…/Safari/Profiles/<UUID>/History.db`;
bookmarks shared by all its profiles. `HOME` and `CFFIXED_USER_HOME` do not move Safari.app's data.

**Safari's code in our process** (run 263, both runners): `SafariMain()` in a bundle with Safari's
Info.plist and our bundle identifier (`dev.local.SafariGraphProbe`), unsandboxed, with `HOME` and
`CFFIXED_USER_HOME` set to a throwaway folder, created before it stopped (§4):

| Path under the throwaway home | What |
|---|---|
| `Library/WebKit/dev.local.SafariGraphProbe/WebsiteData/` (`Default`, `LocalStorage`, `IndexedDB`, `ResourceLoadStatistics`, `MediaKeys`, `SearchHistory`, `DeviceIdHashSalts`; on macOS 26 also `EnhancedSecurity`, `MediaKeysHashSalts`, `ResourceMonitorThrottler`) | WebKit's default data store, named after **our** bundle identifier |
| `Library/Caches/dev.local.SafariGraphProbe/WebKit/` (`NetworkCache`, `CacheStorage`, `HSTS`, `ServiceWorkers`, `AlternativeServices`), `Library/Caches/dev.local.SafariGraphProbe/WebKitCache` | its caches, same name |
| `Library/Caches/com.apple.Safari/TabSnapshots/Metadata.db` | a Safari name written in Safari's code |
| `Library/WebKit/MediaKeys/v1/salt` | media keys |

It stopped before writing `History.db` or bookmarks. So Safari's code, in a process of ours, takes its
storage from the process's home folder and bundle identifier, not from a profile identifier. Pointing it
at one profile's storage would mean one process per profile (the process-per-profile mode) with `HOME`
and `CFFIXED_USER_HOME` set to that profile's folder, and the vault sealing that folder as it seals a
profile's WebKit directories today. Two such processes would be apart by construction (different
folders); that was not measured with Safari's interface, which never came up.

**The new mode** stores data exactly as both existing modes: `WKWebsiteDataStore(forIdentifier:)` per
profile, sealed into `webdata.pbsa`; history and bookmarks in `history.bin` and `bookmarks.bin`,
encrypted. Its self-test checks two profiles' cookies, localStorage and IndexedDB apart (§8).

## 6. Profile settings

The new mode renders in WKWebView, so every existing configuration point applies unchanged
(`BrowserSession.makeWebViewConfiguration`, `ProfileProcessPool`, `WebContentLanguage`):

| Setting | New mode (WKWebView), measured | Safari's UI in our process, from how Safari builds its WebKit objects (not measured: it never came up, §4) |
|---|---|---|
| Language, locale | `AppleLanguages`/`AppleLocale` in the argument domain, per process (measured: `de-DE`, Intl `de`) | would reach it: the setting is per process, not per web view |
| Time zone | the profile's pool, `timeZoneOverride` (measured: Europe/Berlin, Asia/Tokyo, in the engine) | no: Safari makes its own `WKProcessPool`; the override is ours |
| Proxy | `WKWebsiteDataStore.proxyConfigurations` | no: Safari makes its own data stores. Only WebKit's `-WebKit2HTTPSProxy`/`-WebKit2HTTPProxy` defaults (an HTTP CONNECT host:port; no SOCKS5, no credentials; docs/SAFARI_PROCESS.md, measured with SafariForWebKitDevelopment) |
| Fonts | the pool's font allowlist (`WKContextSetFontAllowList`) | no: Safari's pool |
| WebRTC | `WKPreferences` (`_setPeerConnectionEnabled:`) and the shim | no: Safari's own preferences |
| User scripts (the shim) | `WKUserContentController` | no: Safari injects scripts only from Safari Web Extensions |

## 7. The compatibility gate

`Sources/PrivacyBrowser/Browser/SafariGraphBackend.swift`, `SafariGraph.evaluate()`. In order, any
failure takes the WKWebView chrome, with the reason in the log:

1. the build is unsandboxed (the sandboxed build never tries);
2. the Safari version is one the spike measured (`supportedSafariMajors` = [26]);
3. the build of the Safari.framework this process gets (`/System/Library/PrivateFrameworks/Safari.framework`)
   equals the user's Safari build (`CFBundleVersion` of Safari.app): on macOS 15 with Safari 26 they
   differ (20621.3.11.11.3 against 20624.5.1.18.3) and the gate falls back here;
4. the framework loads in a child process of the same binary (`--safari-graph-load-check`), so a
   framework that aborts on its own checks cannot take the app down, and the app never maps Safari's code;
5. Safari's browser classes are present (`BrowserWindowController` and its predecessors).

The decision is made once per run (`SafariGraph.backend()`). The flag: `-PBSafariGraph YES` at launch,
`defaults write <bundle id> PBSafariGraph -bool YES` (a profile's own process reads it too), or
`--safari-graph`; off by default, ignored in the sandboxed build. With the flag off, both first-window
call sites (`ProfileManager`, `ProfileProcessRuntime`) open the window exactly as before.

Measured: on macOS 26.6.2 (run 263) the gate passes every step and reports *"Safari.framework of Safari
26.6.2 loads in this process (/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari); the
in-process Safari window is not built"* (both builds 21624.5.1.11.3); the window then renders in WKWebView.
On macOS 15.7.9 with Safari 26.6.1 it falls back at step 3 (builds 20621.3.11.11.3 against
20624.5.1.18.3, measured by `facts.sh`; the app itself is tested on macOS 26 only). In run 262, before
the gate read the build, it looked for the framework on disk and fell back with *"not found"*: on macOS
26 the framework has no file, only its shared-cache image — the reason step 3 reads the bundle's
Info.plist and step 4 loads by install name.

## 8. The new mode's self-test

`PrivacyBrowser --safari-graph-selftest` (unsandboxed build; CI job `safari-graph`, macOS 26):

| Check | Runs 262, 263, 264 |
|---|---|
| the gate decides, with a reason; a forced failure falls back to WKWebView | pass |
| the version gate: 26.0 and 26.6.2 pass; 27.0, 18.6, empty and junk fail | pass |
| a window opens through the gate (two profiles) | pass |
| the page loads in each window (`document.title`) | pass |
| `navigator.language` is the run's (`de-DE`); Intl's default locale is `de` | pass |
| profile A in Europe/Berlin, profile B in Asia/Tokyo (offset −540), in the engine | pass |
| A writes and reads its localStorage, IndexedDB and cookie; B sees none of them | pass |
| the new-mode window's fingerprint surface (464 keys), written for `safari_reference.py` | pass |
| **total** | **20/20** |

It runs only in the unsandboxed build and leaves the main self-test (`--self-test`) untouched.

## 9. Maintenance

What depends on the Safari version, measured on two Safari builds in one run:

- **Where Safari's code is.** In the App cryptex's `StagedFrameworks/Safari` (20 frameworks plus
  `libwebrtc` and ANGLE) when Safari is newer than the system (macOS 15 + Safari 26); in the system's
  dyld shared cache, with no file on disk, when it is the system's own (macOS 26). The older
  `/System/Library/StagedFrameworks/Safari` exists on neither.
- **Which copy a process gets.** Only Safari's own `LC_DYLD_ENVIRONMENT` makes dyld take the staged
  copies; any other process gets the system's. Safari updates arrive without a macOS update (Safari
  26.6.1 on macOS 15.7.9), so this changes with every Safari release on an older macOS.
- **Safari's private interface.** `SafariMain`, `BrowserApplication`, `BrowserWindowController`,
  `-[NSDocumentController frontmostBrowserDocument]` and the rest are undocumented and change between
  releases without notice; anything built on them has to be re-checked on every Safari update.
- **Safari's entitlements** (168 on macOS 15, 86 of them `com.apple.private.*`): what they unlock
  (Apple Pay, Web Push, iCloud, Keychain) is out of reach for any third-party signature.

How to track it: the `safari-graph` CI job runs on every push on the current macOS 26 and macOS 15
runner images and prints Safari's build, its `LC_DYLD_ENVIRONMENT`, the base and staged builds side by
side, and the load matrix. The gate falls back on its own when the version, the build match, the load
or the classes change. A scheduled run of that job (weekly, to catch runner-image updates between
pushes) would be the next step; it is not added here.

## 10. Side finding: WKWebView and Safari run different engines on macOS 15 with Safari 26

On macOS 15.7.9 with Safari 26.6.1, Safari runs WebKit 20624.5.1 from the App cryptex, while every
other app's WKWebView — this app's profiles included — runs the system's 20621.3.11 (Safari 18's line).
`HostSafari.version` reads Safari.app (26.6.1), so a macOS profile on such a Mac declares
`Version/26.6.1` with an older engine, which feature tests can tell apart. The main CI job runs only on
macOS 26, where the two are the same, so it does not see this. Ways to close it, for the owner to
decide: declare the engine's own Safari version on such hosts; or link the app with Safari's
`DYLD_VERSIONED_FRAMEWORK_PATH` (`LC_DYLD_ENVIRONMENT`), which on the SIP-off runners made the
process take Safari 26.6.1's whole stack — whether that holds with SIP on is the manual check's
`linked-base` row.

## 11. Verdict and effort

**Verdict: NO-GO** for replacing the WKWebView chrome with Safari's own interface in our process.

- Safari.framework loads (no exception, no code-signing wall), but Safari's app bring-up aborts inside
  WebKit at the first private-configuration call, before any window. Measured on macOS 26 and 15 with
  SIP off, so SIP on can only be the same or stricter.
- Even past that abort, Safari's UI needs Safari's identity (restricted entitlements for Apple Pay,
  Web Push, iCloud, Keychain; AMFI refuses them for a third-party signature) and its undocumented,
  version-locked application classes. There is no supported interface for a third party to drive
  Safari's window.
- On an older macOS with a newer Safari, reaching the user's Safari.framework at all needs Safari's
  `DYLD_FRAMEWORK_PATH`; carrying it (`LC_DYLD_ENVIRONMENT`, or the
  `allow-dyld-environment-variables` entitlement) weakens the app's own hardened runtime, against this
  project's threat model.

**What ships from the spike (done):** the compatibility gate and automatic fallback (§7), off by
default, unsandboxed-only, with a self-test (§8). On any Mac today it falls back to WKWebView, and the
new-mode profile matches real Safari exactly where it must (§6), because it *is* WKWebView — the same
engine Safari runs.

**Effort estimate.**

| Path | Effort | Note |
|---|---|---|
| The gate + fallback (shipped) | done | ~250 lines Swift, a self-test, the CI job |
| Keep the engine's own Safari version right on an older macOS (§10) | ~0.5 day | declare the engine's version, or link `LC_DYLD_ENVIRONMENT` and re-measure with SIP on |
| Drive Safari's interface in our process | not worth starting | each Safari update re-breaks it; needs Safari's private entitlements, which are unobtainable; the `awakeFromNib` abort is the first of an open-ended series |

**Recommendation:** stay on WKWebView. The WKWebView profiles already match Safari on everything a
page can measure but Safari's payment and push interfaces (§6), which need entitlements no third-party
browser can carry — the same wall the interface hit. Keep the gate as the place a future, supported
Safari-embedding interface would plug in, and keep the CI job watching the two macOS lines.

## 12. Manual check on a Mac with SIP on

```sh
git checkout claude/safari-graph-spike
scripts/safari_graph/manual_check.sh            # the load matrix (Command Line Tools are enough)
scripts/safari_graph/manual_check.sh --build    # + the app's new-mode self-test
scripts/safari_graph/manual_check.sh --with-ui  # + Safari's interface in the probe (opt-in)
```

It changes nothing on the system (no SIP or security settings, no `sudo`), writes only under `build/`,
and zips the results to send back. Instructions in Russian: `scripts/safari_graph/MANUAL_CHECK.ru.md`.
The rows to read first: `base` on macOS 26 (does the user's Safari.framework load with SIP on), and on
macOS 15 with a newer Safari `base+env`, `dyld+env` and `linked-base` (which route to Safari's own
stack survives SIP).

## 13. Files

| File | What |
|---|---|
| `scripts/safari_graph/probe.m` | the load probe: facts, the `dlopen` matrix, mapped images, Safari's window controller, `SafariMain()` |
| `scripts/safari_graph/measure.sh` | compiles and signs the probe per variant, runs the matrix and the UI attempts |
| `scripts/safari_graph/facts.sh` | how Safari is put together on this Mac (CI and the manual check) |
| `scripts/safari_graph/entitlements/` | one entitlements file per hardened-runtime variant |
| `scripts/safari_graph/manual_check.sh`, `MANUAL_CHECK.ru.md` | the owner's check with SIP on, and its instructions in Russian |
| `Sources/PrivacyBrowser/Browser/SafariGraphBackend.swift` | the gate, the flag, the new-mode window |
| `Sources/PrivacyBrowser/App/SelfTest.swift` (end) | `--safari-graph-selftest` |
| `.github/workflows/ci.yml`, job `safari-graph` | the measurements on macOS 26 and macOS 15 |
