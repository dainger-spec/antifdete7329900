# docs-install — facts

Source: `/home/user/product-src` at 194828b (branch `claude/secret-partner-setup-e505tc`), read-only. Paths below are relative
to it unless they start with `/`. `Localizable.strings` keys sit on the same line number in `Resources/ru.lproj` and
`Resources/en.lproj` (both 1203 lines), so one line number is given per key.

Word count (lead + body; tokens containing letters, markdown markers and list numbers excluded): ru 512, en 644 (counting numbers too: ru 523, en 655).

## Claims → evidence

### #download — What you need and what you download

| Claim | Evidence |
|---|---|
| Macs with Apple Silicon, macOS 26 or later; Intel not supported | Owner's decision, as the brief states it and as registered in `/home/user/site-prototype/design/site/copy/facts.mjs` (value `'26'`, «решение владельца (вопрос 11, сквозная правка 3)»). **Discrepancy (not in the article):** `Resources/Info.plist:30-31` still declares `LSMinimumSystemVersion` 14.0 (also `Resources/Updater/Info.plist:18-19`, `README.md:33`), and `scripts/release.sh:110-112` copies that value into the release's `minimumSystemVersion` in the update feed — a release built today would advertise 14.0. `docs/ROADMAP.md:113-119` (1.6) still plans an Intel column in the compatibility matrix. |
| One app is downloaded; it creates the vault for its data at first launch | `Sources/PrivacyBrowser/App/AppModel.swift:72` (no `vault.json` → `.setup`); `Sources/BrowserCore/Vault/MasterVault.swift:64-81` (`create` writes the header and returns the unlocked vault); `Sources/PrivacyBrowser/App/AppEnvironment.swift:15-26` (vault folder). |
| unv — what the download page offers (disk image or zip) and the file's name | See *unv markers* below. |

### #install — Installing

| Claim | Evidence |
|---|---|
| Move the app to «Программы» / Applications and open it from there; otherwise updates cannot be installed when macOS runs the app from a temporary place, from a read-only disk, or when the user cannot write the app's folder; the Updates section says so | `Sources/PrivacyBrowser/App/Updates/AppUpdater.swift:306-312` (`installBlock`: path contains `/AppTranslocation/` → `.translocated`; read-only volume → `.notWritable`; folder not writable by this user → `.notWritable`), `:317-328` (`userCanWrite`); `Sources/PrivacyBrowser/UI/UpdatesView.swift:127-128`; strings `updates.state.translocated` (849, ru says «Переместите Lumen в «Программы»»), `updates.state.notWritable` (847); `docs/UPDATES.md:73-74`. The word «Программы» comes from the app's own ru string 849. |
| The data lives in the user account's Library, not next to the app; moving or replacing the app does not touch it | `AppEnvironment.swift:15-26` (`FileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)` + `PrivacyBrowser`; inside the container when sandboxed); `docs/ARCHITECTURE.md:117-121`; the installer replaces only the bundle: `Sources/UpdateInstaller/Installer.swift:147-183`. |
| unv — what macOS shows on the first open of a downloaded copy | See *unv markers*. |
| The app's windows are in Russian whatever language macOS uses; no language switch in the app | `Sources/PrivacyBrowser/App/Localization.swift:21-28` (language = env `PRIVACYBROWSER_LANG` if `ru`/`en`, else `ru`; the system language is never read), `:41-44` (sets `AppleLanguages` = [chosen, en] for the process, so even AppKit's menus follow); no other reader of `languageCode` but `UI/CountryFlag.swift:61-62`; `App/AppSettings.swift` has no language setting (grep); `README.md:71-73`; `docs/ISOLATION_AND_LIMITATIONS.md:1591-1597`. EN article: “switches to English only when started with an environment variable meant for development” = `PRIVACYBROWSER_LANG=en` (README.md:71-73 lists it among build/run notes). |

### #setup — The first screen

| Claim | Evidence |
|---|---|
| First launch shows **Создайте мастер-пароль** with the subtitle quoted verbatim | `Sources/PrivacyBrowser/UI/ProfileListView.swift:12-16` (`.setup` → `SetupView`); `Sources/PrivacyBrowser/UI/VaultViews.swift:83` (title `setup.title`, subtitle `setup.subtitle`). |
| Two fields: **Мастер-пароль**, **Повторите мастер-пароль** | `VaultViews.swift:96-99`. |
| Button **Создать хранилище**, Return works | `VaultViews.swift:106-112` (`.keyboardShortcut(.defaultAction)` at :110). |
| Rules: at least 10 characters and both fields equal; nothing else (no letters/digits/symbols rules) | `VaultViews.swift:76-80` — the only checks are `password.count < 10` (→ `setup.rule.length`) and `password != confirmation` (→ `setup.rule.match`). `String.count` counts characters. |
| The hint appears once typing starts | `VaultViews.swift:100` (`if let problem, !password.isEmpty`). |
| Button can't be clicked until the rules are met | `VaultViews.swift:111` (`.disabled(problem != nil || model.isWorking)`). |
| The master password can be neither recovered nor reset | `setup.subtitle` (739: «Его нельзя восстановить»); `MasterVault.swift:14-26` (the header holds one `wrappedMasterKey`, wrapped only under the password-derived key), `:94-105` (unlock = derive from password, unwrap); no recovery or reset code exists — the only way on is setting the vault aside (`AppModel.swift:164-176`, `MasterVault.swift:114-133`), described in docs-vault. |

### #after — What happens next

| Claim | Evidence |
|---|---|
| The form gives way to a progress line and **Создание хранилища…** while the key is derived | `VaultViews.swift:7-69` (`LockScreen`: `isWorking` → `LumenActivityLine` + `workingLabel`), `:83-84` (`workingLabel: L("setup.working")`); `AppModel.swift:98-108` (`createVault` runs `MasterVault.create` — Argon2id — off the main thread); `docs/ISOLATION_AND_LIMITATIONS.md:1567-1570`. |
| The vault is a folder on this Mac where profiles' data is kept encrypted | `docs/ARCHITECTURE.md:117-151`; `README.md:5-9`. (Nuance kept for docs-vault: `vault.json` is plaintext; a running profile's website data is plaintext while it runs.) |
| Then the **Профили** window opens | `AppModel.swift:198-257` (`didUnlock`, `phase = .unlocked` at :246); `ProfileListView.swift:15`; `docs/ISOLATION_AND_LIMITATIONS.md:1567-1570` (“the Profiles window fades in once the vault is open”). |
| Left: **Все профили**, **Запущенные**, **Прокси**, filters **Через прокси**, **Временные**; at the bottom the sync state (**Без синхронизации**) and **Заблокировать** | `ProfileListView.swift:708-767` (`ProfilesSidebar`: `item(.all)`, `item(.running)`, `proxiesItem` (shown once the proxy list exists — it is made at unlock, `AppModel.swift:225-229`), header `profiles.filters`, `item(.proxied)`, `item(.ephemeral)`, tags only when some profile has tags, `SyncStatusButton`, Lock button :757-761); `.off` when no sync target → `profiles.sync.off` (`ProfileListView.swift:245-250` `syncLine`, `SyncStatusButton.text`). |
| Top: **Поиск**, the **⋯** menu, **Новый профиль** | `ProfileListView.swift:527-582` (search field :544, `Menu` :548-569, New Profile button :570-575). |
| Empty state **Пока нет профилей** + «Создайте первый изолированный профиль, чтобы начать работу.» | `ProfileListView.swift:600-601`, `:1131-1153` (`EmptyProfilesView`). |
| ⌘, opens **Настройки** | `Sources/PrivacyBrowser/App/PrivacyBrowserApp.swift:69-75` (SwiftUI `Settings` scene; comment “⌘, and the app menu's Settings…”); window's own title `settings.title` (`Sources/PrivacyBrowser/UI/SettingsView.swift:41-46`). |

### #first-profile — Your first profile

| Claim | Evidence |
|---|---|
| **Новый профиль** (⌘N) opens the editor **Новый профиль**, subtitle «Свои cookie, идентичность и сеть» | `ProfileListView.swift:570-575` (`.keyboardShortcut("n")` at :574; the empty state's button has no shortcut, the header's has), `:256` (`newProfile: { editing = .new }`); `Sources/PrivacyBrowser/UI/ProfileEditorForm.swift:193` (`editor.title.new`), `:223` (`editor.subtitle.new` for a new profile). |
| Name, optionally a proxy, then **Сохранить** | `ProfileEditorForm.swift:275-276` (`editor.name`), `:393-414` (connection: no proxy / from the list / new), `:261` (`common.save`); `README.md:200-236`. |
| The profile appears in the list; **Запустить** opens its window | `AppModel.swift:355-362` (`createProfile` → `refresh`); `profiles.row.launch`; `README.md:237-239`. What the window is (the app's own or Safari's, by build) is left to docs-profile. |

### #next — Later launches

| Claim | Evidence |
|---|---|
| Each later launch shows **Хранилище заблокировано**; enter the password, **Разблокировать** | `AppModel.swift:72` (vault exists → `.locked`); `ProfileListView.swift:14`; `VaultViews.swift:119-176`. |
| The vault stays open until **Заблокировать** or quitting (⌘Q); both stop every profile and encrypt its data | No automatic lock: a search of `Sources/` for sleep / screen-lock / session-resign / idle handlers finds none; `AppModel.lock` is called only from the Lock action (`ProfileListView.swift:272`, also the ⌘K command at :162), the quit (`PrivacyBrowserApp.swift:89`) and Install Now (`AppModel.swift:727-733`). `profiles.action.lock.help` (405); `AppModel.swift:280-329`; `Sources/PrivacyBrowser/App/QuitCoordinator.swift:1-22`; `README.md:273-275`. |

## Numbers in visible text

| Number | Where | Source |
|---|---|---|
| 26 (macOS 26) | #download | Owner's decision; `facts.mjs` value `'26'` («минимальная macOS — 26 и новее, только Apple Silicon»). |
| 10 (characters) | #setup | `VaultViews.swift:77`; `setup.rule.length` (737); `facts.mjs` value `'10'`. |
| 1, 2, 3 | numbered steps | list markers, not facts. |

## unv markers (2, both block markers)

1. **#download — the download's form and file name.** Not confirmed because nothing in the repository defines what the website offers. `scripts/release.sh:105-107` packs the app as `PrivacyBrowser-$VERSION.zip` (`ditto -c -k --keepParent`) — that is the archive the updater downloads; whether the website serves the same zip is not said anywhere. `docs/ROADMAP.md:248-254` (4.2) plans a DMG, not done. The bundle itself is `PrivacyBrowser.app` (`scripts/build-app.sh:35`; `Resources/Info.plist:17-20` `CFBundleName`/`CFBundleDisplayName` = PrivacyBrowser), so in Finder, the Dock and the menu bar the app is currently called PrivacyBrowser, not {{name}}. Confirmed by: the first published release (its file, and the app name inside it).
2. **#install — what macOS shows on the first open of a downloaded copy.** No code or doc describes the first-open dialog. `docs/ROADMAP.md:14-26` (0.1: no Apple Developer account, so no Developer ID and no notarization; «Сейчас приложение запускается только на твоей машине, потому что ты сам снимаешь карантин»); `scripts/release.sh:100-102` (dry run: “not notarized and not stapled … Gatekeeper would refuse this app on another Mac”); `docs/ROADMAP.md:248-254` (4.2, “ready when a DMG downloaded to someone else's Mac opens with a double click without Gatekeeper complaining”). Confirmed by: a notarized release opened on a Mac that has never run it (ROADMAP 4.2's own test).

## UI labels used (Localizable.strings keys)

| ru | en | key | line |
|---|---|---|---|
| Создайте мастер-пароль | Create a master password | `setup.title` | 740 |
| (subtitle, quoted) | (subtitle, quoted) | `setup.subtitle` | 739 |
| Мастер-пароль | Master password | `setup.field.password` | 734 |
| Повторите мастер-пароль | Repeat master password | `setup.field.repeat` | 735 |
| Создать хранилище | Create Vault | `setup.action.create` | 733 |
| Используйте не менее 10 символов. | Use at least 10 characters. | `setup.rule.length` | 737 |
| Пароли не совпадают. | Passwords do not match. | `setup.rule.match` | 738 |
| Создание хранилища… | Creating the vault… | `setup.working` | 741 |
| Профили | Profiles | `profiles.title` / `window.profiles.title` | 471 / 932 |
| Все профили | All Profiles | `profiles.filter.all` | 425 |
| Запущенные | Running | `profiles.filter.running` | 428 |
| Прокси | Proxies | `proxies.title` | 597 |
| Через прокси | Through a Proxy | `profiles.filter.proxied` | 427 |
| Временные | Ephemeral | `profiles.filter.ephemeral` | 426 |
| Без синхронизации | Sync is off | `profiles.sync.off` | 468 |
| Заблокировать | Lock | `profiles.action.lock` | 404 |
| Поиск | Search | `profiles.search` | 463 |
| Новый профиль (button) | New Profile | `profiles.action.new` | 406 |
| Пока нет профилей | No profiles yet | `profiles.empty.title` | 421 |
| Создайте первый изолированный профиль… | Create your first isolated profile… | `profiles.empty.subtitle` | 420 |
| Настройки | Settings | `settings.title` | 1090 |
| Обновления | Updates | `settings.section.updates` | 1096 |
| Новый профиль (editor title) | New Profile | `editor.title.new` | 214 |
| Свои cookie, идентичность и сеть | Its own cookies, identity and network | `editor.subtitle.new` | 208 |
| Сохранить | Save | `common.save` | 46 |
| Запустить | Launch | `profiles.row.launch` | 449 |
| Хранилище заблокировано | Vault locked | `unlock.title` | 814 |
| Разблокировать | Unlock | `unlock.action.unlock` | 808 |

`⋯` is a glyph (SF Symbol `ellipsis`); its tooltip is `profiles.menu.more` (438: «Ещё» / “More”). All labels above exist in both languages.

## Discrepancies found while writing (not in the article)

- **The site's download page contradicts the code.** `/home/user/site-prototype/design/site/copy/source/{ru,en}/download.mjs` promises “one .dmg”, “signed with a Developer ID and notarized by Apple”, and a first-launch prompt to click «Открыть». The repository has no Developer ID or notarization (ROADMAP 0.1), a zip from `release.sh`, and a DMG only as a plan (ROADMAP 4.2). Its step «Нажмите «Запустить» — откроется окно Safari этого профиля» holds only for the build without the App Sandbox (`settings.behavior.ownProcesses.sandboxed`, 1146: in the sandboxed build every profile runs in the app's own windows); `scripts/build-app.sh` and `scripts/release.sh` default to the sandboxed build (`SANDBOX=1`), and which build is released is not decided in code.
- **English UI is reachable only through an environment variable** (`Localization.swift:21-28`); the macOS language is ignored. An English-speaking customer gets Russian windows.
- **Product name:** the bundle, the app menu and the Dock say PrivacyBrowser (`Info.plist:17-20`); the UI strings say Lumen.
- **Settings path in the docs:** `README.md:316` and `SettingsView.swift:7` say Settings also opens from “⋯ → Settings…”; the ⋯ menu has no such item (`ProfileListView.swift:548-569`; the key `profiles.menu.settings`, line 1203, is not used anywhere in `Sources/`). The article gives ⌘, only.
- **ROADMAP 1.7 (onboarding) is partly out of date:** it asks for a master-password screen that explains the password cannot be recovered — `setup.subtitle` already says so. The other two items (guided first profile, a hint where to paste a proxy) do not exist: after setup there is only the empty state.
