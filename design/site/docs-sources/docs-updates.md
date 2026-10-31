# docs-updates — facts

Source: `/home/user/product-src` at 194828b (branch `claude/secret-partner-setup-e505tc`), read-only. Paths are relative to it
unless they start with `/`. `Localizable.strings` keys sit on the same line in `Resources/ru.lproj` and `Resources/en.lproj`.

Word count (lead + body; tokens containing letters, markdown markers excluded): ru 873, en 891 (with numbers counted: ru 880,
en 898). Both are near the 900 ceiling; the English one was cut to fit, so it is a little terser than the Russian (it drops
the CI sentence in #after and the list of what Install Now stops — marked in those rows below).

## Claims → evidence

### #find — How updates are found

| Claim | Evidence |
|---|---|
| Updates are in **Настройки** (⌘,) → **Обновления**; ⌘K → **Настройки: Обновления** | `Sources/PrivacyBrowser/UI/SettingsView.swift:86-98` (section `updates`), `:532-548` (`UpdateSettings`); `Sources/PrivacyBrowser/App/PrivacyBrowserApp.swift:69-75` (Settings scene, ⌘,); `Sources/PrivacyBrowser/UI/ProfileListView.swift:163-169` (palette: `palette.settings` “Settings: %@” per section). |
| No menu item for checking | `PrivacyBrowserApp.swift:26-68` (the app's menu commands: new tab, reopen tab, command palette, paste as typed, Browser, Bookmarks — no update item); `checkNow` is called only by `UpdatesView.swift:43`, the timer (`AppUpdater.swift:196`) and the update self-test. |
| Only a release build asks: it carries the feed's address and signing keys; otherwise the section says `updates.unavailable` and nothing is requested | `Sources/PrivacyBrowser/App/Updates/AppUpdater.swift:93-107` (`Configuration.main()` is nil without an https `PBUpdateFeedURL` or without valid `PBUpdatePublicKeys` → no updater); `AppModel.swift:684-688`; `SettingsView.swift:537-546`; `scripts/build-app.sh:77-93` (feed and keys go into Info.plist only when `UPDATE_FEED_URL` is set); `README.md:61-65, 411`; `docs/UPDATES.md:285-288`. |
| unv — no release with a feed published, no update server named | See *unv markers*. |
| The feed is one static file listing the releases | `Sources/BrowserCore/Updates/Appcast.swift:8-39`; `docs/UPDATES.md:111-121`. |
| Automatic checks on by default; the first no sooner than a minute after launch, then every 6 hours from the last check | `AppUpdater.swift:125-128` (`interval = 6 * 3600`, `firstCheckDelay = 60`), `:162` (default `true`), `:187-200` (due = max(60 s, 6 h − time since the last check), rescheduled after each check); `updates.state.idle` (845); `docs/UPDATES.md:305-307`. (The EN article shortens this to “then every 6 hours”.) The updater starts when the Profiles window first appears, so the first check can run while the vault is still locked (`PrivacyBrowserApp.swift:15-20` → `AppModel.swift:684-704`). |
| **Проверить сейчас** asks at once | `UpdatesView.swift:43`; `AppUpdater.swift:202-239`. |
| Automatic checks off → no timer, no request | `AppUpdater.swift:133-139` (turning it off reschedules), `:187-190` (`guard automaticChecks` → no timer); `docs/UPDATES.md:305-307`; CI scenario `docs/UPDATES.md:363-365` (“with automatic checks off, not one request … the capture holds not one packet of the app”). |

### #screen — The Updates section

| Claim | Evidence |
|---|---|
| **Версия** (number and build), a status line, **Когда найдено обновление**: **Скачать и установить при выходе** (default) / **Только сообщить** | `UpdatesView.swift:12-16, 20-41, 80-87`; `AppUpdater.swift:37-43`, `:163` (default `.atQuit`). |
| **Только сообщить** → «Доступна версия …» and **Скачать** | `AppUpdater.swift:232-233` (download only under `.atQuit`); `UpdatesView.swift:46-49, 124`. |
| A downloaded update installs at quit either way | `AppUpdater.swift:265-269` (`isReady` does not look at the policy); `PrivacyBrowserApp.swift:94-95`; `QuitCoordinator.swift:71-78`. |
| Row “Up to date (checked …).” = nothing newer | `updates.state.upToDate` (850); `AppUpdater.swift:218-222`. |
| Row “Version … is downloaded and checked…” → **Установить сейчас…** appears | `updates.state.ready` (848); `UpdatesView.swift:50-54`. |
| Row “The last check failed: …” = the feed or the archive did not arrive or failed a check | `updates.state.failed` (844); `AppUpdater.swift:234-238` (a failed check: fetch, signature, freshness…), `:256-260` (a failed download or archive check also lands here). |
| Rows for a temporary place / a folder that can't be written | `updates.state.translocated` (849), `updates.state.notWritable` (847); `AppUpdater.swift:306-328`. |

### #check — How an update is checked

| Claim | Evidence |
|---|---|
| An update is the whole app in a zip archive | `Appcast.swift:41` (“One release: a zip of the signed app”); `scripts/release.sh:105-107`; `docs/UPDATES.md:79` (no delta updates). |
| The feed is signed with Ed25519 and isn't read until the signature checks with a key built into the app | `Appcast.swift:137-159` (the envelope's signature is checked before the payload is decoded; unknown key → refused), `:115-134` (keys from Info.plist `PBUpdatePublicKeys`); `scripts/build-app.sh:83-90`; `Tests/BrowserCoreTests/UpdateTests.swift:81, 89`. |
| A feed older than one already accepted is refused | `Appcast.swift:161-167`; `AppUpdater.swift:213-215`; `UpdateTests.swift:152`. |
| Only a release newer than the installed one and made for this macOS; never an older one | `Appcast.swift:169-195` (`build > running`, `minimum <= system`); `UpdateTests.swift:164, 182`; checked again by the installer: `Sources/UpdateInstaller/Installer.swift:141`; `Tests/UpdateInstallerTests/InstallerTests.swift:212`. |
| The archive's size, SHA-256 and Ed25519 signature must match the feed | `Appcast.swift:197-209`; `AppUpdater.swift:249-252, 419-420`; `UpdateTests.swift:200`. |
| After the quit, the installer inside the app checks the archive again, then the new app's code signature (strict, nested code), identifier and version | `Installer.swift:5-22`, `:105-106` (first the installed app's own signature), `:139-145` (release and archive again), `:150-157, 205-217` (one app, same identifier, the release's versions, `CodeSignature.check`); `Sources/UpdateInstaller/CodeSignature.swift:12-36` (`kSecCSCheckAllArchitectures \| kSecCSCheckNestedCode \| kSecCSStrictValidate`, requirement `identifier "<id>"`); `Tests/UpdateInstallerTests/InstallerTests.swift:184, 189, 197, 202, 207`. The helper is `Contents/Helpers/PrivacyBrowser Updater.app` (`Sources/PrivacyBrowserUpdater/main.swift:7-12`). |
| If the build is signed with an Apple developer certificate, the new version must come from the same developer | `CodeSignature.swift:21-22` (with a developer team built in: `anchor apple generic and certificate leaf[subject.OU] = …`); `Installer.swift:72-73` (`PBUpdateTeamID` read from the installed app's signed Info.plist); `scripts/build-app.sh:93`; `scripts/release.sh:61-67`; `docs/UPDATES.md:137-142` (without it, any validly signed bundle of the same identifier whose zip's Ed25519 signature checks is accepted: the signature proves integrity, the Ed25519 key proves origin). The article avoids the term the site's checker forbids. |
| unv — whether releases are signed with an Apple developer certificate | See *unv markers*. |
| The quarantine flag is cleared only after these checks | `Installer.swift:150-157` (`releaseFromQuarantine` after `check`), `:225-233`; `docs/UPDATES.md:78`. |

### #install — When an update is installed

| Claim | Evidence |
|---|---|
| Only at a quit the person started (⌘Q, the menu, the Dock), once every profile is stopped and encrypted | `Sources/PrivacyBrowser/App/QuitCoordinator.swift:3, 19-22, 64-80` (the update is handed over only when sealed or nothing ran, and never for a system quit); `AppModel.swift:712-722`. |
| The check: nothing runs/starts/is being encrypted; no profile process had to be stopped by force (the quit waits 30 seconds for one); no profile's data unencrypted on disk | `Sources/PrivacyBrowser/App/Updates/UpdateGate.swift:4-39`; `Sources/PrivacyBrowser/Browser/ProfileManager.swift:770` (`waitUntilExit(timeout: 30)`); `Sources/PrivacyBrowser/Browser/ProfileProcess.swift:65-68, 234-247` (killed → `forcedExits`); `docs/UPDATES.md:156-170`. Profile processes exist only in the build without the App Sandbox. |
| If anything fails, the update waits for the next quit; the next launch says why | `AppModel.swift:714-722` (`rememberNotInstalled`); `AppUpdater.swift:300-303, 369-380`; `AppModel.swift:699-700` (`updates.notice.deferred`, 830). The reason inside is English (see *single-language*). |
| Never at a logout, restart or shutdown, never after a crash | `QuitCoordinator.swift:19-22, 66, 71, 121-135`; `docs/UPDATES.md:168-175`. |
| **Установить сейчас…**: the alert lists what stops (profiles with windows, warm-ups without one, launches and encryption under way); **Остановить, зашифровать и установить**, or **Выйти и установить** when nothing runs | `UpdatesView.swift:50-54, 89-117`; `AppModel.swift:747-760` (`updates.stops.*` 851-854); keys `updates.installNow.title` (826), `.confirmStopping` (823), `.confirm` (822), `.stops` (825), `.nothingRuns` (824). The EN article keeps the buttons but drops the list of kinds (word limit). |
| If the check fails then, the app doesn't quit: it stays locked and says why | `AppModel.swift:724-745` (`lock(forQuit:)`, then the gate; `.refused` → `updates.now.refused`, 836); `docs/UPDATES.md:179-183`. |
| The installer waits for every process of the app, stops none, and after 10 minutes backs off until the next quit | `Installer.swift:42` (`patience: 600`), `:125-137` (“…none was stopped” → `.gaveUp`); the archive is kept (`Installer.swift:96, 113-117`: not consumed) and is ready again at the next launch (`AppUpdater.swift:356-365`); `updates.notice.gaveUp` (831); `Tests/UpdateInstallerTests/InstallerTests.swift:139, 148`. |
| Then it swaps the old and the new app in one operation and starts the new one | `Installer.swift:159-183` (`renamex_np(RENAME_SWAP)`, check in place, launch); `Tests/UpdateInstallerTests/InstallerTests.swift:113`. |

### #after — What is kept, and rollback

| Claim | Evidence |
|---|---|
| An update replaces only the app; the vault and the settings stay in the account's Library | `Installer.swift:147-183` (only the bundle path is touched); `AppEnvironment.swift:15-26`; `docs/ISOLATION_AND_LIMITATIONS.md:1544-1546` (settings in the app's defaults). |
| (ru only) CI runs the whole path: the new build opens the old build's vault and starts a profile from website data the old build encrypted | `docs/UPDATES.md:358-379` (§8: the new build's `--selftest-updates verify` opens the old build's vault, profiles, settings and bookmarks, starts a profile from the website data the old build sealed), `:14` (first passed in CI run 410 — not a run registered in `facts.mjs`, so no number is shown); `scripts/update_check.py`. |
| An older version installed by hand neither reads nor changes the newer one's files, and says «Файл … сохранён более новой версией {{name}}…» | `docs/UPDATES.md:232-239` (R2); `Sources/BrowserCore/Support/DocumentFormat.swift`; `Sources/PrivacyBrowser/App/Localization.swift:56-64` (`errorText`); `error.newerFormat` (229); `Tests/BrowserCoreTests/FormatPolicyTests.swift`. |
| New app fails its check in place or doesn't start → the installer puts the previous one back and starts it; the next launch says so | `Installer.swift:171-182`; `AppModel.swift:695` (`updates.notice.rolledBack`, 833); `Tests/UpdateInstallerTests/InstallerTests.swift:126`. |
| If even that fails, the previous version stays beside it with “(previous version)” in its name | `Installer.swift:164-170` (`"<name> (previous version).app"`). English-only file name. |
| No command to go back a version | No downgrade anywhere (`Appcast.swift:185-190`, `Installer.swift:141`); the Updates section offers only Check Now / Download / Install Now (`UpdatesView.swift:42-55`). |
| After a successful update: «Обновлено до … (…).» | `UpdatesView.swift:142-146` (`updates.installed`, 827: the version and the date of the install). |

### #server — What the update server sees

| Claim | Evidence |
|---|---|
| The quoted sentence | `updates.privacy` (840), shown under the automatic-checks setting (`UpdatesView.swift:77`). “The check never goes through a profile's proxy”: the updater exists only in the manager process with its own session (`AppUpdater.swift:77-78, 95-96`); `docs/UPDATES.md:294-304`. |
| No parameters, cookies or cache; the same headers on every Mac: a User-Agent without a version, language `en` | `AppUpdater.swift:384-398` (ephemeral session; no cookie storage, URL cache or credential storage; `User-Agent: Lumen`, `Accept-Language: en`), `:400-409`; `docs/UPDATES.md:285-288, 305-312, 380-381`; CI asserts the headers: `scripts/update_check.py:426-431`. The request is a GET of the Info.plist feed URL as given (`AppUpdater.swift:401`); “no query string” is the design (UPDATES.md:285-286) and the CI scenario's check, not something the code enforces on the configured URL. |
| No licence check exists to tie it to | Search of `Sources/` for licence/license/activation/subscription code: nothing (only the Public Suffix List's MPL header); `docs/UPDATES.md:290-292`. |

### #notes — Release notes

| Claim | Evidence |
|---|---|
| **Что нового в …** shows the feed's notes as plain text, not a web page; «У этого выпуска нет заметок.» without notes | `UpdatesView.swift:57-76` (`Text(verbatim:)`; comment “Plain text, never a page”); `updates.notes` (828), `updates.notes.none` (829); `Appcast.swift:58-59`; `docs/UPDATES.md:144-148`. |
| The next release's notes are written | `docs/release-notes-next.txt:1-3`; `docs/UPDATES.md:329` (`NOTES_FILE`; release-notes-next.txt “gathers what the next release's are to say”). |
| Both changes concern the build without the App Sandbox (Safari's window) | Item 1: `Sources/PrivacyBrowser/Browser/SafariAccountPreferences.swift:76-93` (`guard !AppEnvironment.isSandboxed`); item 2: Safari's window exists only there (`settings.behavior.ownProcesses.sandboxed`, 1146). |
| Item 1: settings for Safari's services that earlier versions wrote into the account's Safari settings file (which Safari doesn't read) are removed once after the first unlock — only values {{name}} wrote that nobody changed | `docs/release-notes-next.txt:1`; `SafariAccountPreferences.swift:76-110` (once per account, `SafariAccountPreferencesCleaned`; only keys still holding a value a profile would have written); called after unlock: `AppModel.swift:248-249`. |
| Item 2: each profile's Safari window keeps its own layout in the profile's encrypted data; after the update each profile opens once with Safari's default layout | `docs/release-notes-next.txt:3`; `Sources/PrivacyBrowser/Browser/SafariDefaults.swift:1-23` (kept in the profile's home, sealed into the vault; “Every profile starts once from Safari's own defaults for these (the owner's decision)”). |

### #missing — What isn't there yet

| Claim | Evidence |
|---|---|
| Installing where only an administrator can write — the app says it can't install there | `docs/UPDATES.md:390-393` (§9); `AppUpdater.swift:306-328` → `updates.state.notWritable` (847). |
| Partial (delta) updates | `docs/UPDATES.md:79, 394`. |
| Updating the WebRTC system extension by this path | `docs/UPDATES.md:395-396` (a new extension version is activated by `OSSystemExtensionRequest` at the next launch that needs it). |

## Numbers in visible text

| Number | Where | Source |
|---|---|---|
| 6 (hours) | #find | `AppUpdater.swift:127`; `docs/UPDATES.md:307`; `README.md:411`. **Not yet in `facts.mjs`.** |
| 30 (seconds) | #install | `ProfileManager.swift:770`; `docs/UPDATES.md:159-160`. **Not yet in `facts.mjs`.** |
| 10 (minutes) | #install | `Installer.swift:42` (600 s); `docs/UPDATES.md:75, 207-208`. `facts.mjs` has `'10'` for other things (minutes of the warm-up retry, characters, …); this use needs its own entry. |
| “a minute” / «минуту» | #find | written as a word; `AppUpdater.swift:128` (60 s); `updates.state.idle` (845). |
| Ed25519, SHA-256, zip | #check | technical identifiers. |
| 1–4 | numbered steps | list markers. |

## unv markers (2)

1. **#find, block — no release with an update feed has been published, no update server named.** The repository has no feed address: `Resources/Info.plist` has no `PBUpdateFeedURL`; `scripts/release.sh:15, 30` defaults to `https://updates.invalid/privacybrowser/appcast.json`; `docs/ROADMAP.md:78-87` (1.3) lists what is missing — the Ed25519 key kept outside the repository and CI, hosting for the appcast and the downloads, the release procedure — and is done only when “an installed 0.1.0 updates itself to 0.1.1 from a real server, and a swapped file in the distribution makes the update refuse”. Confirmed by: exactly that test (ROADMAP 1.3).
2. **#check, inline — whether releases are signed with an Apple developer certificate.** `docs/ROADMAP.md:14-26` (0.1: the Apple Developer enrollment did not go through, so no Developer ID); `scripts/release.sh:62-63` (dry run: “signed ad hoc … no Developer ID”). Until then a release build carries no developer team, and the installer requires only a valid signature with the same identifier plus the Ed25519 signature (`docs/UPDATES.md:137-142`). Confirmed by: a release built with `SIGN_IDENTITY` and `TEAM_ID` (`release.sh:10-11, 61-67`) and notarized.

## UI labels used (Localizable.strings keys)

| ru | en | key | line |
|---|---|---|---|
| Настройки | Settings | `settings.title` | 1090 |
| Обновления | Updates | `settings.section.updates` | 1096 |
| Настройки: Обновления (⌘K) | Settings: Updates | `palette.settings` + `settings.section.updates` | 308, 1096 |
| (quoted) | (quoted) | `updates.unavailable` | 855 |
| Проверить сейчас | Check Now | `updates.checkNow` | 819 |
| Проверять обновления автоматически | Check for updates automatically | `updates.automatic` | 818 |
| Версия | Version | `updates.version` | 856 |
| Когда найдено обновление | When an update is found | `updates.policy` | 837 |
| Скачать и установить при выходе | Download it, install when I quit | `updates.policy.atQuit` | 838 |
| Только сообщить | Only tell me | `updates.policy.notifyOnly` | 839 |
| Доступна версия … (quoted) | Version … is available. | `updates.state.available` | 841 |
| Скачать | Download | `updates.download` | 820 |
| Установлена последняя версия (проверено …). | Up to date (checked …). | `updates.state.upToDate` | 850 |
| Версия … скачана и проверена… | Version … is downloaded and checked… | `updates.state.ready` | 848 |
| Последняя проверка не удалась: … | The last check failed: … | `updates.state.failed` | 844 |
| …macOS запускает эту копию из временного места… | …macOS runs this copy from a temporary place… | `updates.state.translocated` | 849 |
| …заменить приложение там, где оно лежит, нельзя… | …you cannot replace the app where it is… | `updates.state.notWritable` | 847 |
| Установить сейчас… | Install Now… | `updates.installNow` | 821 |
| Остановить, зашифровать и установить | Stop, Encrypt and Install | `updates.installNow.confirmStopping` | 823 |
| Выйти и установить | Quit and Install | `updates.installNow.confirm` | 822 |
| Обновление … было установлено, но не запустилось… (quoted) | Update … was installed but did not start… | `updates.notice.rolledBack` | 833 |
| Обновлено до … (…). | Updated to … (…). | `updates.installed` | 827 |
| Файл … сохранён более новой версией {{name}}… | The file … was saved by a newer version of {{name}}… | `error.newerFormat` | 229 |
| (quoted privacy sentence) | (quoted) | `updates.privacy` | 840 |
| Что нового в … | What’s new in … | `updates.notes` | 828 |
| У этого выпуска нет заметок. | This release has no notes. | `updates.notes.none` | 829 |
| «Программы» | Applications | from `updates.state.translocated` (ru) | 849 |

The strings `updates.unavailable`, `updates.privacy`, `updates.installNow.nothingRuns`, `error.newerFormat` and `updates.state.translocated` contain the literal “Lumen”; the articles write {{name}} where they quote them.

**Single-language text:** the reasons inserted into `updates.notice.deferred` (830) and `updates.now.refused` (836) are `UpdateGate` reasons in English (`UpdateGate.swift:22-36`); the details in `updates.notice.refused/gaveUp/rolledBack` (831-833) are the installer's `UpdateOutcome.detail`, English (“Why, in English (the log's words)”, `Sources/BrowserCore/Updates/UpdateRequest.swift:129-130`); the reason in `updates.state.failed` (844) is `UpdateError.description` or a system message (`Appcast.swift:98-112`, `AppUpdater.swift:433-437`); the kept app's name “… (previous version).app” is English. The release notes themselves are one plain-text field per release (`Appcast.swift:58-59`), so they are in whatever single language the release writes them.

## Discrepancies found while writing (not in the article)

- **User-Agent:** `docs/UPDATES.md:380-381` (§8) says every request carries `User-Agent: PrivacyBrowser`; the code (`AppUpdater.swift:393`) and the CI script (`scripts/update_check.py:426`) use `Lumen`, as §5 (lines 287, 309) says. §8 is stale.
- **Signature mode on the screen:** `docs/UPDATES.md:142` says “The update screen says which of the two this build does” (bound to a developer team, or Ed25519 alone). Neither `UpdatesView.swift` nor any `updates.*` string says it.
- **“⋯ → Settings…”**: `docs/UPDATES.md:336`, `README.md:316` and `SettingsView.swift:7` give it as a way into Settings; the ⋯ menu has no such item (`profiles.menu.settings`, line 1203, is unused). The article uses ⌘, and ⌘K.
- **Minimum macOS in the feed:** `scripts/release.sh:110-112` copies `LSMinimumSystemVersion` (14.0, `Resources/Info.plist:30-31`) into each release's `minimumSystemVersion`, so a release made today would tell the updater it runs on macOS 14, while the owner supports 26 and later only.
- **Release notes name the old product:** `docs/release-notes-next.txt:1` says “the value PrivacyBrowser wrote”; if shown to people as is, the notes name the product PrivacyBrowser.
- **ROADMAP 1.3** reads as if the update code were only claimed (“Агент отчитался, что написал”); the code, unit tests, installer tests and the CI end-to-end scenario are all in the repository (UPDATES.md table, lines 7-14). What is missing is the release infrastructure, which is what the unv marker says.
