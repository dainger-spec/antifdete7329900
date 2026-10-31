# docs-mobile — facts

Sources: `/home/user/product-src` at 194828b (paths below are relative to it). Localizable.strings keys sit on the
same line in `ru.lproj` and `en.lproj` (checked key by key). Every bold label in `docs-mobile.ru.md` /
`docs-mobile.en.md` was matched by script against the values of the matching Localizable.strings; all exist in
both languages.

## What a "mobile profile" is in this product

There is no separate mobile profile type. A profile has a **device generation** (`deviceGenerationID`), chosen
with the editor's **View for websites** / **Вид для сайтов** picker; three of the four generations are iPhone or
iPad views (`Sources/BrowserCore/Profiles/DeviceGeneration.swift:112-140`). Since commit 7baa672
(2026-10-31 10:33, "An iPhone or iPad profile is a mobile view…", the owner's decision of 31 October) such a view
changes **only** the User-Agent and the window's size. Before it, the profile's script also told pages
`platform` "iPhone", five touch points, four cores and a 390×844 screen at 3× (commit message of 7baa672;
`git show ce64ca1:Sources/PrivacyBrowser/Browser/PrivacyScripts.swift`, lines 97 and 102). Nothing of that is in
the code now. iPhone profiles on Apple's iOS Simulator are not in the product (`docs/IOS_SIMULATOR.md:3-6`).

## Claims → evidence

### Что такое мобильный вид / What a mobile view is {#what}

| Claim | Evidence |
|---|---|
| A mobile view = Safari on this Mac calling itself an iPhone/iPad, in a window of that device's screen size; nothing else | `editor.generation.footer` (104); `DeviceGeneration.swift:16-20`; `Sources/PrivacyBrowser/Browser/PrivacyScripts.swift:18-22`, `:94-104`; `docs/ISOLATION_AND_LIMITATIONS.md:310-319`, `:1146-1149`; `README.md:21`, `:221-223` |
| Pages are shown by this Mac's WebKit, the engine of its Safari | `DeviceGeneration.swift:11-14`; `ISOLATION_AND_LIMITATIONS.md:330-333` |
| A real state of Safari: its Develop menu can set an iPhone UA the same way | `ISOLATION_AND_LIMITATIONS.md:311-313` ("which is a real state, Safari's own Develop › User Agent"); `DeviceGeneration.swift:17-20`; `PrivacyScripts.swift:20-22`. Safari's menu is named without its exact (Safari's own, not Lumen's) label |

### Как включить / Turning it on {#enable}

| Claim | Evidence |
|---|---|
| Editor via **New Profile** or ⋯ → **Edit…** | `Sources/PrivacyBrowser/UI/ProfileListView.swift:256-263`, `:1033` |
| **Identity** → **View for websites**, three mobile choices, in this order | `Sources/PrivacyBrowser/UI/ProfileEditorForm.swift:310-319` (`ForEach(DeviceGenerations.all)`); order `DeviceGeneration.swift:122-140` (macos-26, ios-27, ios-26, ipados-26); labels `gen.*` (233-236) |
| The editor explains the view below the list | `ProfileEditorForm.swift:320-323` (`editor.generation.inconsistent` 105 for iPhone, `editor.generation.ipad` 106 for iPad, shown as warnings) |
| Applies at the next launch | `editor.footer.note` (102); `Sources/PrivacyBrowser/App/AppModel.swift:369` |
| **Appears as** shows «Мобильный вид · Safari 27» / "Mobile view · Safari 27" or «Вид iPad · Safari 26» / "iPad view · Safari 26" | `ProfileListView.swift:340-349` (device word + `osVersionLabel`), `:636-638`, `:888-894`; `profiles.appearsAs` (407), `profiles.device.iphone` (418), `profiles.device.ipad` (417); `DeviceGeneration.swift:128`, `:132`, `:136` (`osVersionLabel` "27", "26", "26"). The column is hidden in a narrow window (`ProfileListView.swift:695-703`) |
| Back: **Safari on macOS 26 (matches this engine)**, the default | `DeviceGeneration.swift:115`; `Sources/PrivacyBrowser/UI/ProfileEditorView.swift:33` |

### Что меняется / What changes {#changes}

| Claim | Evidence |
|---|---|
| Exactly two things: the User-Agent (request header and `navigator.userAgent`) and the window size | `editor.generation.footer` (104); `Sources/BrowserCore/Profiles/ProfileConfiguration.swift:12-16`; `PrivacyScripts.swift:82-84` ("changes the User-Agent and the window's size, nothing a page measures") |
| iPhone UA: `iPhone OS 18_7`, `Version/27.0` (Safari 27) or `Version/26.6` (Safari 26) | `DeviceGeneration.swift:127-134`; `Tests/BrowserCoreTests/FingerprintConsistencyTests.swift:289-294`; `Sources/PrivacyBrowser/App/SelfTest.swift:2182-2184` |
| iPad UA: the Mac's Safari string with `Version/26.6`; an iPad asks for desktop sites by default and calls itself a Mac | `DeviceGeneration.swift:25-26`, `:135-139`; `editor.generation.ipad` (106); `ISOLATION_AND_LIMITATIONS.md:308-309`; `FingerprintConsistencyTests.swift:295-297` |
| Window: 390 × 844 points (iPhone), 820 × 1180 points (iPad) | `PrivacyScripts.swift:94-104`; `Sources/PrivacyBrowser/Browser/BrowserWindowController.swift:65-72` |
| `18_7`: Safari on iOS 26.1 and later freezes the OS token; only `Version/` names the release | `DeviceGeneration.swift:22-26`; `ISOLATION_AND_LIMITATIONS.md:304-308` |
| The **User agent** field shows the whole string | `ProfileEditorForm.swift:335-346` (`editor.ua.effective` 218) |
| The version is fixed in the app, does not follow this Mac's Safari | `DeviceGeneration.swift:66-74` ("Mobile generations keep their fixed UA"); `ProfileConfiguration.swift:119-122`; `FingerprintConsistencyTests.swift:12-13`, `:41-42`, `:46-54` |
| No **Safari version in the User-Agent** choice for a mobile view | `ProfileEditorForm.swift:324-326` (only when `matchesEngine`) |
| **Custom user agent** replaces the string; the window keeps the device's size | `ProfileConfiguration.swift:235-238`; size from the generation's platform only: `PrivacyScripts.swift:98-104`; override checked: `SelfTest.swift:2191-2195`, `Tests/BrowserCoreTests/LibraryTests.swift:231-233` |
| The size is the page area below the toolbar; from the second tab the tab bar takes part of it | `BrowserWindowController.swift:65-72` (`contentRect` = the device size), `:170-200` (the tab strip and the web view inside that content view), `:323-326` (tab strip shown from two tabs, `TabStripView.height`) |
| Not wider or taller than that | `BrowserWindowController.swift:72` (`contentMaxSize = deviceScreen`) |
| The **Window** size does not apply to a mobile view | `BrowserWindowController.swift:96-102` (`if deviceScreen == nil, let size = …windowSize`) |
| In the Safari-window mode, a mobile view still opens in the app's window | `Sources/PrivacyBrowser/Browser/SafariChromeHost.swift:38-41`, `:114-121`; `SelfTest.swift:1390-1392`; `ISOLATION_AND_LIMITATIONS.md:858-861` |

### Что остаётся от Mac / What stays the Mac's {#same}

| Claim | Evidence |
|---|---|
| Engine features, CSS, JavaScript | `ISOLATION_AND_LIMITATIONS.md:432`; `DeviceGeneration.swift:11-14`; `editor.safari.far` (150) |
| `navigator.platform`, `maxTouchPoints`, processor cores | `ISOLATION_AND_LIMITATIONS.md:429`; `PrivacyScripts.swift:18-22`, `:94-97`; `scripts/test-shims.mjs:379-396`; self-test `SelfTest.swift:2301-2307` |
| Screen: size, colour depth, pixel density, CSS media queries | `ISOLATION_AND_LIMITATIONS.md:428`, `:1146-1149`; `Sources/BrowserCore/Profiles/WindowSize.swift:7-11` |
| No touch; WebKit on the Mac is a desktop engine | `ISOLATION_AND_LIMITATIONS.md:430`, `:314-317`; `editor.generation.inconsistent` (105) |
| Fonts, graphics (WebGL), audio | `editor.generation.inconsistent` (105); `ISOLATION_AND_LIMITATIONS.md:425-427`, `:1148` |
| TLS handshake and header order | `ISOLATION_AND_LIMITATIONS.md:433`, `:1148` |
| Time zone, language, proxy and other settings are the profile's own | the generation feeds only the User-Agent (`ProfileConfiguration.swift:235-238`), the window (`PrivacyScripts.swift:98-104`), Safari's chrome or not (`SafariChromeHost.swift:119-121`), and defaults for a new profile (`ProfileConfiguration.swift:213-218`); the time zone, language and proxy are separate fields (`ProfileConfiguration.swift:18-47`, `:124-135`); self-test: an iPhone view's `timeZone`, `tzOffset`, `dateString` are the plain web view's when none is set (`SelfTest.swift:2304-2307`) |
| Warning text (RU paraphrase, EN verbatim) | `editor.generation.inconsistent` (105) |

### Как проверить / Checking it {#check}

| Claim | Evidence |
|---|---|
| ⋯ → **What Sites See…** → **Take Snapshot** | `ProfileListView.swift:1038`, `:72-76`; `Sources/PrivacyBrowser/UI/WhatSitesSeeView.swift:28-35`; the same button in the editor's header for an existing profile: `ProfileEditorForm.swift:200-206` |
| One page of this Mac in a profile window, then in Safari, compared | `whatSites.subtitle` (317); `ISOLATION_AND_LIMITATIONS.md:351-366` |
| A mobile view has no reference; the panel says so and names touch, fonts, graphics, audio, motion sensors, the screen | `whatSites.mobileView` (329), shown for any iPhone/iPad view (`WhatSitesSeeView.swift:5-11`, `:50-57`); `whatSites.allSame.mobile` (328); the flag is passed at `ProfileListView.swift:75` and `ProfileEditorView.swift:407` |
| The self-test checks an iPhone view: navigator, screen, touch, rendering, fonts as plain WebKit; only the UA says iPhone | `SelfTest.swift:2241-2316` (engine keys incl. `ownNavigator`, `ownScreen`, `fonts`, `canvas.*`, `webgl.*` at `:2242-2246`; `platform`, `maxTouchPoints`, `hardwareConcurrency`, `screen`, `pointer`, `touch` at `:2304-2307`; UA at `:2313-2314`); runs in CI on every push, both builds: `ISOLATION_AND_LIMITATIONS.md:9-13`; doc row `:32` |

### Чего мобильный вид не делает / What a mobile view cannot do {#limits}

| Claim | Evidence |
|---|---|
| No other screen: the screen-size override exists only in WebKit for iOS | `ISOLATION_AND_LIMITATIONS.md:428`; `WindowSize.swift:7-11` |
| No touch emulation in WebKit for macOS | `ISOLATION_AND_LIMITATIONS.md:430` |
| No iPhone engine, fonts or graphics | `DeviceGeneration.swift:11-14`; `ISOLATION_AND_LIMITATIONS.md:425-427`, `:432` |
| An iPhone's real signals take Safari on a real iPhone | `ISOLATION_AND_LIMITATIONS.md:446-449` |
| No profile running Safari for iOS | `docs/IOS_SIMULATOR.md:3-6` ("not in the product, shelved"), `:25-27` |

## Numbers in visible text

| As written | Source |
|---|---|
| `27` in **…Safari 27…** labels and «Safari 27» | `gen.ios27` (234); `DeviceGeneration.swift:128` (`osVersionLabel: "27"`) |
| `26` in **…Safari 26…**, **Safari на macOS 26…**, «Safari 26» | `gen.ios26` (233), `gen.ipados26` (235), `gen.macos26` (236); `DeviceGeneration.swift:124`, `:132`, `:136` |
| `18_7`, `27.0`, `26.6` (code spans) | `DeviceGeneration.swift:129`, `:133`, `:138` |
| `26.1` (iOS 26.1 and later) | `DeviceGeneration.swift:23-24`; `ISOLATION_AND_LIMITATIONS.md:305` |
| `390 × 844` | `PrivacyScripts.swift:101` (`CGSize(width: 390, height: 844)`) |
| `820 × 1180`; `1180` | `PrivacyScripts.swift:102` (`CGSize(width: 820, height: 1180)`) |
| `1117` (the tallest MacBook screen in the editor's list) | `WindowSize.swift:66-69` (MacScreen points: 956, 982, 1107, 1117 high) |
| «две вещи» / "two things" (words) | `editor.generation.footer` (104): the User-Agent and the window's size |
| `1.`–`4.` | ordered-list markers, not figures |

None of the CI numbers in `site-prototype/.../copy/facts.mjs` are used: they were measured before the mobile view
changed (see unv 1).

## unv markers (3)

1. **Inline in {#check}: this check's result in a registered CI run.** The only runs registered for the site —
   CI #388 (ce64ca1, 29 Oct) and #385 (d1d1db7) — predate 7baa672 (31 Oct). At ce64ca1 the self-test checked the
   *old* iPhone view: `surface (iPhone): navigator` wanted `platform` "iPhone", 5 touch points, 4 cores, and
   `surface (iPhone): screen` wanted "390x844x390x844x3", with `window.safari` absent
   (`git show ce64ca1:Sources/PrivacyBrowser/App/SelfTest.swift`, the `for generationID` loop, ~lines 1332-1384).
   So a passed #388 says nothing about the current mobile view. No CI script outside the self-test touches a
   mobile view (grep of `scripts/` and `.github/workflows/` for ios-26/ios-27/ipados/iphone/mobile: none).
   Confirmed by: registering a CI run at or after 7baa672 whose self-test passed with the
   `surface (iPhone view): …` lines.
2. **Block in {#limits}: whether the window fits the screen.** The mobile window is created at the device size,
   given that as its maximum and only centred (`BrowserWindowController.swift:65-72`, `:96-102`); unlike a profile's
   **Window** size, it is not passed through `WindowSizing.fitted` (`Sources/PrivacyBrowser/Browser/WindowSizing.swift:11-23`).
   The iPad window's page area alone is 1180 points high, more than any MacBook screen in `MacScreen`
   (`WindowSize.swift:66-69`; their visible area is smaller still, without the menu bar and Dock). What AppKit then
   does is not measured anywhere in the repository; the self-test check named "an iPhone or iPad view gets our own
   window, of that device's size" asserts only `SafariChromeHost.canHost` (`SelfTest.swift:1390-1392`). Confirmed
   by: launching an iPad view (and an iPhone view on a 13″ MacBook Air with the Dock shown) and measuring
   `innerHeight`/`outerHeight` against the screen's visible frame, or a self-test check of the mobile window's frame.
3. **Block in {#limits}: whether a profile with Safari for iOS will come.** `docs/IOS_SIMULATOR.md:3-6` (status
   2026-10-31): "not in the product, shelved", the owner's decision; `docs/ROADMAP.md:270-274` (state 30 Oct) still
   lists "Профили iPhone на симуляторе" under stage 5, "after launch". The documents disagree on its status.
   Confirmed by: the owner's decision (and whether the site should mention it at all).

## UI labels → Localizable.strings keys

| RU | EN | Key (line) |
|---|---|---|
| Новый профиль | New Profile | `profiles.action.new` (406) |
| Изменить… | Edit… | `profiles.row.edit` (444) |
| Идентичность | Identity | `editor.topic.identity` (144) |
| Вид для сайтов | View for websites | `editor.generation` (103) |
| Мобильный вид: iPhone, Safari 27 (только User-Agent) | Mobile view: iPhone, Safari 27 (User-Agent only) | `gen.ios27` (234) |
| Мобильный вид: iPhone, Safari 26 (только User-Agent) | Mobile view: iPhone, Safari 26 (User-Agent only) | `gen.ios26` (233) |
| Вид iPad: Safari 26, окно размером с iPad | iPad view: Safari 26, an iPad-sized window | `gen.ipados26` (235) |
| Safari на macOS 26 (соответствует движку) | Safari on macOS 26 (matches this engine) | `gen.macos26` (236) |
| Сохранить | Save | `common.save` (46) |
| Видится как | Appears as | `profiles.column.appearsAs` (408) |
| «Мобильный вид · Safari 27», «Вид iPad · Safari 26» (quoted cell text) | "Mobile view · Safari 27", "iPad view · Safari 26" | `profiles.appearsAs` (407) + `profiles.device.iphone` (418) / `profiles.device.ipad` (417) |
| User-Agent (the field) | User agent | `editor.ua.effective` (218) |
| Версия Safari в User-Agent | Safari version in the User-Agent | `editor.safari.version` (146) |
| Свой User-Agent | Custom user agent | `editor.ua.useCustom` (220) |
| Окно | Window | `editor.topic.window` (145) |
| Что видят сайты… | What Sites See… | `profiles.row.whatSitesSee` (313) |
| Сделать снимок | Take Snapshot | `whatSites.take` (318) |
| warning paraphrased (RU) / quoted (EN) | — | `editor.generation.inconsistent` (105) |
| panel text described | — | `whatSites.mobileView` (329), `whatSites.allSame.mobile` (328) |

## Notes for the owner (found while checking)

- **Measurements predate the feature as it is.** The registered CI runs measured the old iPhone profile (told
  "iPhone", touch points, a phone's screen). The site should not cite them for mobile views (unv 1).
- **The Window section stays editable for a mobile view and is silently ignored.** `ProfileEditorForm.swift:455-491`
  shows **Window size** whatever the view; `BrowserWindowController.swift:96-99` ignores it for iPhone/iPad.
  The editor says nothing about it; the article does.
- **Stale code comment.** `SafariChromeHost.swift:116-118` still says a mobile profile "would show its device's
  navigator and screen next to a Mac's window", and its log line (`:39`) says the window "presents that device";
  since 7baa672 nothing of the device is presented but the window's size.
- **A self-test check's name promises more than it checks**: "…gets our own window, of that device's size…"
  (`SelfTest.swift:1390-1392`) asserts only `canHost`.
- **iPad view in What Sites See**: the panel always says it compares with an iPhone ("с настоящим iPhone сравнить
  не с чем" / "nothing to compare with a real iPhone", `whatSites.allSame.mobile` 328), also for the iPad view.
- **ROADMAP vs IOS_SIMULATOR** disagree on simulator iPhone profiles (after launch vs. shelved) — unv 3.
- **Checker.** "видеокарта" (the app's own word in `editor.generation.inconsistent` and `whatSites.mobileView`) was
  replaced by «графика» in the Russian text so that a naive substring check for payment words cannot match it.
