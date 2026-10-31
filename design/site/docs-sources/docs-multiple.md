# docs-multiple — facts, evidence and verification

Article: «Несколько профилей сразу» / "Several profiles at once" (`docs-multiple.ru.md`, `docs-multiple.en.md`).
Product code: `/home/user/product-src` at 194828b. Paths are relative to it; `L.strings:NN` = line NN of both
`Resources/ru.lproj/Localizable.strings` and `Resources/en.lproj/Localizable.strings` (same keys, same lines).

Counts (words, markdown stripped): ru 816, en 885. Links: [docs-mobile](docs-mobile.html) (iPhone/iPad profiles), [docs-trouble](docs-trouble.html). `unv` markers: **3 per language** (all block markers):
windows (does Safari's window show the profile's name), scale (timing of the queued Launch), crash (what survives a
profile-process crash).

---

## 0. The one thing to settle first: which build ships

The whole article describes **one process per profile with Safari's own window**. In code that is the default only in the
build **without** the App Sandbox:

- `Sources/PrivacyBrowser/Browser/ProfileProcess.swift:32-41` — `isEnabled` = `PB_PROFILE_PROCESS` env, else the
  `PBProfileProcess` default, else `!AppEnvironment.isSandboxed`.
- `scripts/build-app.sh:4-5, 33` and `scripts/release.sh:19, 37` — the default build and the default *release* are
  `SANDBOX=1`; `README.md:40-50` "The default build is **sandboxed**"; `docs/ISOLATION_AND_LIMITATIONS.md:863-864` "The
  sandboxed build keeps every profile in the one process (it cannot load Safari's frameworks)".
- Settings shows it: `SettingsView.swift:428-440` — in a sandboxed build the row reads `settings.behavior.ownProcesses.off`
  «Не в этой сборке» / "Not in this build" with `…ownProcesses.sandboxed` (L.strings:1146-1147).

The brief and the site (`copy/source/ru/common.mjs`, `how-it-works.mjs`) position "every profile in its own process", so the
release must be built with `SANDBOX=0` for the article to hold as written. The article's note covers the other case with the
app's own words (**Не в этой сборке** → all profiles in {{name}}'s windows, one process). **Owner's decision needed.**

---

## 1. Every statement → evidence

### process — Профиль — отдельный процесс / Each profile is a process
| Statement | Evidence |
|---|---|
| Every running profile is its own macOS process, with its own Safari window | `ProfileProcess.swift:6-29`; `ProfileManager.swift:217-238` (`startInOwnProcess`); `SafariChromeHost.swift:114-133`; `docs/ISOLATION_AND_LIMITATIONS.md:856-861`; `docs/SAFARI_PROCESS.md:715-726` |
| …and its own WebKit processes | measured: `docs/SCALE.md:79-84` ("Each profile runs 6 to 12 processes: its own…, one or two of WebKit's web content…, WebKit's networking (8 MB)…"); contrast `docs/SAFARI_PROCESS.md:401-404` (within one app process every store shares one networking process) |
| It holds only its own profile's key; the other profiles and the proxy list stay in the main process | `ProfileProcess.swift:16-24`; `ProfileGrant` over stdin `:117-134`; `docs/ARCHITECTURE.md:107-111`; `ISOLATION_AND_LIMITATIONS.md:920-926`; tests `Tests/BrowserCoreTests/ProfileGrantTests.swift` |
| Language, region and time zone are set for the process as it starts | `ProfileProcess.swift:8-14, 84-115` (`-AppleLanguages`, `-AppleLocale`), `:206-211` (`TZ`, `__XPC_TZ` for its WebKit processes); `ProfileManager.swift:222-236, 375-389` |
| Note: holds while **Профили — отдельными приложениями в Dock** is on (on by default) | `AppSettings.swift:188-202`; `SettingsView.swift:428-433`; `settings.behavior.ownProcesses(.detail)` L.strings:1144-1145; default = `ProfileProcess.isEnabled` (above) |
| Off, or **Не в этой сборке**: all profiles in {{name}}'s windows, one process | `settings.behavior.ownProcesses.detail` :1145 ("Если выключено — все профили в окнах этого приложения"), `…sandboxed` :1146, `…off` :1147 |
| …then the first profile launched sets the language sites see until you quit | `Sources/PrivacyBrowser/Browser/HostIdentity.swift:40-65` (`WebContentLanguage.decide`: only the first call counts per run); `ProfileManager.swift:300-304, 614-619`; `launch.languageFixed` L.strings:253; `ISOLATION_AND_LIMITATIONS.md:431` |
| iPhone and iPad profiles always open in a {{name}} window | `SafariChromeHost.swift:114-121` (`canHost` = macOS generation only); `ISOLATION_AND_LIMITATIONS.md:858-860` |

### launch — Запуск и остановка / Launching and stopping
| Statement | Evidence |
|---|---|
| ⌘-click adds/removes a row, ⇧-click selects a range | `ProfileBulkBar.swift:4-45` (`ProfileSelection`) |
| With two or more selected a bar offers **Запустить, Остановить, Прогрев…, Назначить прокси…, Удалить…** | `ProfileListView.swift:485-489` (`selectedRows.count >= 2`); `ProfileBulkBar.swift:95-119`; L.strings:673-681 |
| **Запустить**: the stopped ones, four at a time; each next one when one of those has its window up, has ended, or after two minutes | `ProfileBulkBar.swift:92, 103` (stopped only); `AppModel+Proxies.swift:75-88` (`LaunchQueue.run`, `waitForWindow(id, seconds: 120)`); `Sources/BrowserCore/Profiles/LaunchQueue.swift:3-10` (`atOnce = 4`, "the owner's choice"), `:18-38`; `ProfileManager.swift:152-166` (window up / process ended / time out); tests `Tests/BrowserCoreTests/LaunchQueueTests.swift:15-33`; `docs/SCALE.md:151-154` |
| **Остановить**: the selected running ones, all at once, data encrypted | `AppModel+Proxies.swift:90-104` (task group); `profiles.bulk.stop.help` L.strings:676 |
| A profile also stops when its last window closes | `ProfileSessionHost.swift:166-170` (own process quits → seals); `ProfileManager.swift:327-332` (one-process mode); `docs/ARCHITECTURE.md:440-444`; `docs/SAFARI_PROCESS.md:715-721` |
| **Заблокировать** stops every profile, encrypts their data, forgets the keys | `ProfileListView.swift:757-761` (sidebar button); `profiles.action.lock(.help)` L.strings:404-405; `AppModel.swift:280-290`; `ProfileManager.swift:870-894` |
| ⌘Q does the same before quitting; with **Подтверждать выход** on it first lists what it stops | `AppModel.swift:287-290` (`lock(forQuit:)`); `docs/ARCHITECTURE.md:242-250`; `settings.startup.confirmQuit(.detail)` L.strings:1121-1122; default on: `AppSettings.swift:148` |

### windows — Как различать окна / Telling windows apart
| Statement | Evidence |
|---|---|
| Each profile is an app of its own in the Dock and ⌘-Tab | `ProfileSessionHost.swift:96-103` (`.regular` activation policy unless warm-up only); `AppSettings.swift:190-191`; `settings.behavior.ownProcesses.detail` L.strings:1145 ("со своим значком в Dock") |
| Its Dock icon shows the first letters of the profile's name; **Букв имени на значке в Dock** (**Поведение**): two by default, or one, three, **Нет** | `Sources/PrivacyBrowser/App/DockIcon.swift:3-34`; `ProfileSessionHost.swift:272-274`; `AppSettings.swift:25-27` (`dockInitials = 2`), `:163-165` (0…3); `SettingsView.swift:441-448` (None, 1, 2, 3; disabled when not in own processes); L.strings:1148-1150 |
| Started without a window (warm-up, cookie export) → not in the Dock | `ProfileManager.swift:236` (`forWarmUpOnly: !openingWindow`), `:1043-1047` (export launches `openingWindow: false`); `ProfileProcess.swift:212-214` (`PB_WARM_UP_ONLY`); `ProfileSessionHost.swift:98-102` (`.accessory`: out of the Dock and ⌘-Tab) |
| A {{name}} window shows the profile's chip: **Значок**, name, flag of the exit country | `Sources/PrivacyBrowser/Browser/BrowserChrome.swift:59-102`; `BrowserWindowController.swift:139-140`; `README.md:11-13`; glyph label `editor.avatar` L.strings:192 |

### isolation — Что раздельно, а что общее / What is separate, what is shared
| Statement | Evidence |
|---|---|
| Own: cookies, localStorage, IndexedDB, cache, service workers | `ISOLATION_AND_LIMITATIONS.md:113-124` (per `WKWebsiteDataStore`), `:282` |
| Own: the proxy, for the whole process | `ISOLATION_AND_LIMITATIONS.md:864-884` (`ProfileNetworkGuard`); `ProfileSessionHost.swift:51-65` |
| Own: language, region, time zone | process section above |
| Own: history, bookmarks, passwords, Safari's settings | `docs/ARCHITECTURE.md:90-99, 129-143` (per-profile encrypted files); `ISOLATION_AND_LIMITATIONS.md:1017-1042` (Safari's preferences in the profile's home, `SafariDefaults`) |
| Shared: GPU (canvas, WebGL), audio, system fonts, screen; CPU core count, `navigator.platform`; Safari and WebKit versions; the macOS network stack (TLS, HTTP/2) | `ISOLATION_AND_LIMITATIONS.md:418-433` ("What remains impossible with public APIs": GPU, audio stack, fonts, real display, `platform`/`hardwareConcurrency`, installed WebKit, "TLS ClientHello, HTTP/2 settings, header order — Apple's macOS network stack"); `README.md:21` (macOS profiles declare this Mac's real Safari version); `docs/SAFARI_PROCESS.md:299-307` |
| Shared: the master password, the vault, the proxy list | `docs/ARCHITECTURE.md:71-101` (one vault, one VMK; `proxies.bin` is vault-level) |
| Self-test on every build: a running profile cannot see another's site data; profiles behind different SOCKS5 proxies load at once, each through its own | `SelfTest.swift:504-513` (localStorage, IndexedDB, cookies of A invisible to B, same origin, same time), `:2466-2553` (three SOCKS5 profiles launched together, each page through its own proxy, the others keep loading after one stops); `ISOLATION_AND_LIMITATIONS.md:21, 45`; CI on every push: `ISOLATION_AND_LIMITATIONS.md:9-11`, `.github/workflows/ci.yml`; both checks exist at CI #388's commit ce64ca1 (green: «SELFTEST PASSED: 274 passed, 0 failed», `copy/facts.mjs`). **Caveat:** the self-test runs these with every profile in its own test process's sessions (`SelfTest.swift:39-41`, `PB_PROFILE_PROCESS=0`); with per-profile processes the separation is the same stores plus separate processes |
| Note: hardware/macOS traits are the same and not altered; a site can link profiles by them; full separation = separate macOS accounts or Macs | `ISOLATION_AND_LIMITATIONS.md:131-134` ("Device fingerprint — Profiles can be linked by fingerprinting"), `:418-449` (none is attempted; "a separate macOS user account per identity; a different Mac…"); `README.md:21` (no noise, no navigator/screen overrides) |

### scale — Сколько выдержит Mac / How many a Mac holds
| Statement | Evidence |
|---|---|
| {{name}} sets no limit on how many profiles run at once | no cap anywhere in code (searched `Sources/` for running/profile/process limits: none); `ProfileManager.swift:18` "Any number of profiles can run at once"; owner's decision (brief): no limit in any plan. `LaunchQueue.atOnce = 4` limits only how many are *starting* at a time, not how many run |
| Measured on a GitHub CI machine: 3 processors, 7 GB, macOS 26 and 27; nearly empty page; all launched at once | `docs/SCALE.md:10-12, 23-25, 41-44, 48-50` (macOS 26.6.2 and 27.0.1 runners, CI runs 457, 460, 461, 468, 470 of the measurement branch; scale workflow `.github/workflows/scale.yml`); `ScaleCheck.swift:34-36` (`PB_PROFILE_PROCESS=1`: own processes with Safari's window) |
| A profile = 6 to 12 processes, about 150 MB; a real site adds what it adds in Safari, often hundreds of MB a tab | `SCALE.md:79-84`, `:148-151` |
| Ten reliably, 10–40 s; twenty: macOS 26 within a minute, macOS 27 one to six minutes; thirty past it — macOS 27 last windows after minutes or not at all | `SCALE.md:133-141` (summary), table `:66-77`, details `:98-122` |
| The processor gives out first at launch; with real sites memory bounds how many keep running | `SCALE.md:143-151` |
| Stopping: about 5–9 s up to ten, 6–35 s for twenty or thirty | `SCALE.md:123` |
| Quitting with ten running: 5.1–13.6 s until all encrypted; every profile's cookie there at its next launch | `SCALE.md:35-38, 125-127` ("ten of ten in every run") |

### warmup — Прогрев по очереди / Warm-up in turn
| Statement | Evidence |
|---|---|
| Entry: the bar's **Прогрев…**, or ⌘K → **Прогреть несколько профилей…** | `ProfileBulkBar.swift:111`; `ProfileListView.swift:212-216` (queue sheet, selection ticked), `:158` (command palette entry), `:546-547`; ⌘K `PrivacyBrowserApp.swift:174`; L.strings:677, 979 |
| Tick, choose what to visit, **Запустить**; **Добавить в очередь** while it runs | `WarmUpQueueView.swift:4-11, 62-77`; L.strings:1009-1010 |
| One at a time, one plan; a stopped one starts without a window, is stopped and encrypted again before the next; an open one warms up where it runs and stays open | `Sources/BrowserCore/WarmUp/WarmUpQueue.swift:3-8, 88-94`; `WarmUpCoordinator.swift:6-13, 151-192`; `warmupQueue.explanation` L.strings:999, `warmupQueue.open.help` :1006; self-test `ISOLATION_AND_LIMITATIONS.md:53` ("never both at once, each without a window…sealed before the next") |
| **Отменить остальные** drops the waiting; **Остановить всё** also stops the current run | `WarmUpCoordinator.swift:123-137`; L.strings:1011-1012 |
| Scheduled warm-ups join the queue; an open profile is tried again 10 minutes later | `WarmUpCoordinator.swift:14-18, 164-170, 241-257`; `Sources/BrowserCore/WarmUp/WarmUpSchedule.swift:77` (`retryDelay = 10 * 60`); `docs/ARCHITECTURE.md:262-264, 295-298` |

### crash — Если профиль упал / When a profile crashes
| Statement | Evidence |
|---|---|
| A crash closes only that profile (each runs in its own process); {{name}} handles only the one that ended (ru text) | `ProfileManager.swift:437-475` (`onExit` clears only `children[id]`, its waits, its warm-up); separate OS processes (`ProfileProcess.swift`) |
| {{name}} at once encrypts what it left on disk and says it ended unexpectedly and its data is encrypted; if that fails — at the next unlock | `ProfileManager.swift:456-472` (`safariHomeVault.seal` "whatever way the process ended", then `profile.crashed` / `profile.crashedUnsealed`); L.strings:975-976 |
| If {{name}} itself crashes, every running profile encrypts its data and quits | `ProfileSessionHost.swift:141-145` (channel closed → `NSApp.terminate` → seal); `ISOLATION_AND_LIMITATIONS.md:926-929` |

(Removed from the final text for length, still true: with all profiles in one process an app crash closes them all and
the plaintext is sealed at the next unlock — `ISOLATION_AND_LIMITATIONS.md:633-636`, `ProfileManager.swift:1173-1185`.)

---

## 2. Numbers in the visible text → source

| Number | Meaning | Source | In `copy/facts.mjs`? |
|---|---|---|---|
| 3 | processors of the CI machine | `docs/SCALE.md:43` "(3 processors, 7 GB)" | '3' exists (other meanings) — **add this meaning** |
| 7 (ГБ / GB) | memory of the CI machine | `SCALE.md:43` | '7' exists (other meaning) — **add** |
| 26, 27 | macOS of the CI runners (26.6.2, 27.0.1) | `SCALE.md:48-50` | '26' yes; **'27' no — add** |
| 6, 12 | processes per profile | `SCALE.md:80` | '12' exists (other meaning); **'6' no — add** |
| 150 (МБ / MB) | memory per profile on a nearly empty page | `SCALE.md:148-149` "about 150 MB a profile" | **no — add** |
| 10–40 (с / s) | ten at once start reliably | `SCALE.md:137-138` | '10' exists; **'40' no — add** |
| 5–9 (с / s) | stopping up to ten | `SCALE.md:123` | '5' exists; **'9' no — add** |
| 6–35 (с / s) | stopping twenty or thirty | `SCALE.md:123` | '35' exists (other meaning) — **add** |
| 5,1–13,6 / 5.1–13.6 (с / s) | quit with ten running until all sealed | `SCALE.md:125-126` | **no — add** ('5,1', '5.1', '13,6', '13.6') |
| 10 (минут / minutes) | scheduled warm-up retry when the profile is open | `WarmUpSchedule.swift:77`; `ARCHITECTURE.md:264` | **yes** ('10' — «минут до новой попытки прогрева по расписанию») |
| words: два/two (selection ≥ 2) | bulk bar threshold | `ProfileListView.swift:485` | word |
| words: по четыре / four at a time | Launch queue width | `LaunchQueue.swift:10` | word |
| words: две минуты / two minutes | wait per window in the queue | `AppModel+Proxies.swift:78, 86` (120 s) | word |
| words: две; одну, три / two; one, three | Dock letters default and choices | `AppSettings.swift:27, 163`; `SettingsView.swift:443-444` | word |
| words: десять, двадцать, тридцать / ten, twenty, thirty; «в пределах минуты», «одну–шесть минут» | SCALE groups and summary | `SCALE.md:66-77, 133-141` | words |
| HTTP/2, SOCKS5, ⌘K, ⌘Q, ⌘-Tab | technical identifiers / shortcuts | — | not counted |
| 1., 2., 3. | list markers | markdown | — |

---

## 3. unv markers (same three in ru and en)

| Where | Marker (ru) | Why it is not confirmed | What would confirm it |
|---|---|---|---|
| windows | «Показывает ли само окно Safari имя профиля (в заголовке, меню «Окно», Mission Control), не проверялось…» | The hosted Safari chrome draws its own window; nothing in `SafariChromeHost.swift` / `SafariChrome.swift` sets a title, badge or colour for the profile, and no test or capture records what the window shows. (Our own window's title is "[name] page" — `BrowserWindowController.swift:77, 334`, `window.browser.title` L.strings:930 — but its title bar is hidden, `:80`.) | A screenshot of a profile's Safari window, or a self-test check reading the window's title and the Window menu |
| scale | «Сколько занимает запуск очередью по четыре через кнопку **Запустить**, не измерялось…» | `SCALE.md:151-154`: the groups were "started all at once, as Launch did before"; the queue (`LaunchQueue`, commit c7b8896) came after the measurement and has unit tests only for ordering (`LaunchQueueTests.swift`), not for time | Re-run `scripts/scale_check.py` with the groups launched through `AppModel.launchProfiles` (the queue) |
| crash | «Что остаётся у профиля после сбоя его процесса, тестом не проверено…» | The app's message `profile.crashed` (L.strings:975) promises sign-ins and cookies kept and tabs lost, but no test kills a profile's process mid-run; `docs/ROADMAP.md:130-139` (1.8 «Восстановление после сбоя») lists exactly this test (`kill -9` of a profile's process) as not done. CFNetwork writes cookies to disk late (`CookieStoreImport.swift:52-55`), so cookies of the last moments may not be on disk at a crash | The ROADMAP 1.8 test: kill a profile's process mid-run, relaunch, check sign-in cookies and tabs |

---

## 4. UI labels → Localizable.strings keys (line = same in ru and en)

| Key (line) | ru | en |
|---|---|---|
| `settings.section.behavior` (1093) | **Поведение** | **Behavior** |
| `settings.behavior.ownProcesses` (1144) | **Профили — отдельными приложениями в Dock** | **Each profile its own app in the Dock** |
| `settings.behavior.ownProcesses.off` (1147) | **Не в этой сборке** | **Not in this build** |
| `settings.behavior.dockLetters` (1148) | **Букв имени на значке в Dock** | **Letters of the name on the Dock icon** |
| `settings.behavior.dockLetters.none` (1150) | **Нет** | **None** |
| `profiles.bulk.launch` (673) | **Запустить** | **Launch** |
| `profiles.bulk.stop` (675) | **Остановить** | **Stop** |
| `profiles.bulk.warmUp` (677) | **Прогрев…** | **Warm Up…** |
| `profiles.bulk.assignProxy` (679) | **Назначить прокси…** | **Assign Proxy…** |
| `profiles.bulk.delete` (681) | **Удалить…** | **Delete…** |
| `profiles.action.lock` (404) | **Заблокировать** | **Lock** |
| `settings.startup.confirmQuit` (1121) | **Подтверждать выход** | **Confirm quitting** |
| `editor.avatar` (192) | **Значок** | **Glyph** |
| `profiles.menu.warmUpSeveral` (979) | **Прогреть несколько профилей…** | **Warm Up Several Profiles…** |
| `warmupQueue.start` (1009) | **Запустить** | **Start** |
| `warmupQueue.add` (1010) | **Добавить в очередь** | **Add to Queue** |
| `warmupQueue.cancelRest` (1011) | **Отменить остальные** | **Cancel the Rest** |
| `warmupQueue.stopAll` (1012) | **Остановить всё** | **Stop All** |
| `profile.crashed` (975), `profile.crashedUnsealed` (976) | paraphrased, not quoted | paraphrased |
| `profiles.title` (471) | «окно профилей» (the window titled «Профили») | "the Profiles window" |

All keys exist in both languages. "Settings"/«настройки» is the app's Settings window (`settings.title` L.strings:1090, opened with ⌘,).

---

## 5. Findings (code vs docs, and things the owner should know)

1. **Sandboxed default vs the positioning** — section 0. With `SANDBOX=1` (the default of `build-app.sh` and `release.sh`) every
   profile runs in one process, in {{name}}'s own windows, and the first profile launched fixes the language for the whole run.
2. **Two more exceptions to "one process per profile"** (kept out of the article text, both code-confirmed):
   a profile whose WebRTC goes through the packet tunnel (SOCKS5 proxy, WebRTC not "Disabled", tunnel ready) stays in the manager
   process, in our window (`ProfileManager.swift:217-221, 1036-1038`; `ISOLATION_AND_LIMITATIONS.md:858-861, 1061-1064`) — only in
   `NE=1` builds with the system extension approved (`docs/TUNNEL.md:160-166`); and a macOS without a structural piece of Safari's
   chrome opens our own window instead (`SafariChromeHost.swift:130-133`; `SAFARI_PROCESS.md:728-736`).
3. **Launch help text vs code**: `profiles.bulk.launch.help` (L.strings:674) says «один за другим» / "one after the other"; the code
   starts four at a time (`LaunchQueue.atOnce = 4`).
4. **Outdated docs**: `docs/ARCHITECTURE.md:383-385` says `warmUpSeveral` "today opens the warm-up of the first"; the code opens the
   warm-up queue with the selection ticked (`ProfileListView.swift:212-216`). `README.md:270` says **More → Warm Up Several
   Profiles…**; the Profiles window's ⋯ menu no longer has it (`ProfileListView.swift:546-558`) — the entry points are the selection
   bar and ⌘K. `docs/ISOLATION_AND_LIMITATIONS.md:133` ("WebKit networking process shared") holds for the one-process mode; with a
   process per profile each has its own (measured, `SCALE.md:80-84`).
5. **SCALE.md inconsistencies**: the summary says thirty on macOS 26 "come within a minute and a half" (`:139-140`) while the table's
   slowest is 46.8–94.0 s (`:76`); and "on macOS 27 the last window takes minutes or does not come" (`:140-141`) predates run 476, after
   the SafariPlatformSupport fix, where all thirty came within 108 s (one run, `:119-122`). The article gives the summary for 27 in the
   past tense ("came after minutes or not at all") and leaves the 30-on-26 figure out.
6. **Warm-up concurrency**: the queue waits for any other warm-up (`WarmUpCoordinator.swift:157-160`), but a warm-up started from a
   single profile's sheet does not wait for the queue (`AppModel.swift:477-498`) — two can run at once that way. The article
   therefore says only that the queue's profiles warm up one at a time.
7. **Crash message promises more than is tested** (`profile.crashed`) — see the crash `unv`; ROADMAP 1.8.
8. **Info.plist** still says `LSMinimumSystemVersion` 14.0 (`Resources/Info.plist:30-31`); the site follows the owner (macOS 26+, Apple
   silicon). Not mentioned in the article.
9. **CI evidence age**: CI #388 (ce64ca1, 29 Oct) is 140 commits before 194828b. The Launch queue (c7b8896), the Dock-letters and
   own-process Settings rows, and the SCALE measurements (9082cb3, runs 457–476 of a measurement branch) are newer than #388; their
   evidence is the code at 194828b and SCALE.md's own runs, which are not registered in `copy/facts.mjs`.
