# docs-profile — facts

Sources: `/home/user/product-src` at 194828b (paths below are relative to it). Every key of
`Resources/ru.lproj/Localizable.strings` and `Resources/en.lproj/Localizable.strings` used here sits on the
same line number in both files (checked key by key), so one line number is given per key.
Every bold label in `docs-profile.ru.md` / `docs-profile.en.md` was matched by script against the values of the
matching Localizable.strings; the only bold text that is not a string value is the menu glyph **⋯** (an SF Symbol
`ellipsis`, as in the sample article). All labels exist in both languages.

## Claims → evidence

### Как создать профиль / Creating a profile {#create}

| Claim | Evidence |
|---|---|
| **New Profile** button in the profiles window, ⌘N | `Sources/PrivacyBrowser/UI/ProfileListView.swift:570-574` (`Label(L("profiles.action.new"))`, `.keyboardShortcut("n")`) |
| **New Profile…** in the command palette, ⌘K | `ProfileListView.swift:114-117` (⌘K sheet), `:135` (command `palette.newProfile`); the palette's own name: `menu.commandPalette` (291) «Командная палитра…» / "Command Palette…" |
| With no profiles, the button is also mid-window | `ProfileListView.swift:600-601` (`rows.isEmpty → EmptyProfilesView`), `:1131-1154` (centred, button at `:1148`) |
| Editor titled **New Profile** | `Sources/PrivacyBrowser/UI/ProfileEditorForm.swift:193`; `editor.title.new` (214) |
| Name pre-filled «Профиль N» / "Profile N", N = number of profiles + 1 | `Sources/PrivacyBrowser/UI/ProfileEditorView.swift:458`; `editor.defaultName` (95) |
| The name cannot be empty | `Sources/BrowserCore/Profiles/ProfileRepository.swift:563-568` (trimmed, 1–128 characters); the error shows in the editor's footer (`ProfileEditorView.swift:574-576`, `ProfileEditorForm.swift:238-244`) |
| Every field has a default | `ProfileEditorView.swift:31-96` (draft defaults), `:457-470` (new-profile settings) |
| **Save** creates the profile, it appears under **Ready**, it is not launched | `ProfileEditorView.swift:549-573` (`createProfile`, then `dismiss()`; no launch); `Sources/PrivacyBrowser/App/AppModel.swift:355-361`; groups `ProfileListView.swift:615-618` |
| **Cancel** closes without saving | `ProfileEditorView.swift:426` (`onCancel: { dismiss() }`) |

### Поля редактора / The editor's fields {#editor}

| Claim | Evidence |
|---|---|
| One screen, seven parts, the list on the left jumps to each | `ProfileEditorForm.swift:6-8`, `:12-26` (Topic: profile, connection, identity, window, location, privacy, data), `:93-113`, `:123-162` |
| Changes apply at the next launch | `editor.footer.note` (102), shown at `ProfileEditorForm.swift:252-256`; `AppModel.swift:369` ("Changes take effect the next time the profile is launched") |
| Fields per part (table, column 2) | Profile `ProfileEditorForm.swift:273-306`; Connection `:391-451`; Identity `:310-349` and `:353-375`; Window `:455-491`; Location `:516-604`; Privacy `:643-665`; Data `:712-740` |
| Default: blank start page | `Sources/BrowserCore/Profiles/ProfileConfiguration.swift:9-10` ("nil → blank page"); `ProfileEditorView.swift:32` |
| Default: DuckDuckGo | `Sources/BrowserCore/WarmUp/WebAddress.swift:9` (`standard = .duckDuckGo`); `Sources/PrivacyBrowser/App/AppSettings.swift:150`; `ProfileEditorView.swift:463` |
| Default: persistent (not ephemeral) | `ProfileEditorView.swift:57` |
| Default: **No Proxy**, WebRTC **Disabled** | `ProfileEditorView.swift:36`, `:56` |
| Default: **Safari on macOS 26 (matches this engine)** | `Sources/BrowserCore/Profiles/DeviceGeneration.swift:115` (`defaultID = "macos-26"`), `:123-126`; `ProfileEditorView.swift:33` |
| Default: Safari version as this Mac's (Auto) | `ProfileEditorView.swift:76-77` (nil = Auto); `ProfileEditorForm.swift:359` (`editor.safari.auto` 147) |
| Default: **Custom size**, picked at random | `ProfileEditorView.swift:465-469`, `:111-119`; `AppSettings.swift:151` (default true); `Sources/BrowserCore/Profiles/WindowSize.swift:39-50` |
| Default: **Deny**, **From the connection** | `ProfileEditorView.swift:43`, `:49`, `:459-462`; `AppSettings.swift:149` |
| Default: **Protect**, Safe Browsing off | `ProfileEditorView.swift:58`, `:464`; `AppSettings.swift:152`; why off: `ProfileConfiguration.swift:56-58`, `editor.privacy.footer` (126) |
| Default: history recorded, kept **3 months**; AutoFill and cookie sync on | `ProfileEditorView.swift:59-63` (90 days), `:127-133` (90 → `editor.retain.quarter`) |
| Search engine, time zone and language, local requests, window size come from Settings → **New Profiles**; ⌘, opens Settings | `Sources/PrivacyBrowser/UI/SettingsView.swift:371-395`; `AppSettings.swift:149-152`; `Sources/PrivacyBrowser/App/PrivacyBrowserApp.swift:69-70` |
| Glyph, tags, notes: yours alone, the list finds profiles by them, no site sees them | `editor.labels.note` (203); search `ProfileListView.swift:520-525` |
| Glyph = a colour and up to two letters | `ProfileEditorForm.swift:745-792`; `Sources/BrowserCore/Profiles/ProfileLabels.swift:41-42`; `editor.avatar.letters` (193) |
| Start URL = first page at launch | `ProfileConfiguration.swift:9-10`; `Sources/PrivacyBrowser/Browser/ProfileManager.swift:346-347` |
| Ephemeral: no website data or history on disk; gone after a stop | `editor.ephemeral.detail` (97); `ProfileConfiguration.swift:51-54`; `ProfileManager.swift:248-250`, `:269-272`, `:788-815` |
| Ephemeral keeps bookmarks | `editor.history.footer` (113); `ProfileConfiguration.swift:51-54` |
| Row label «Временный, без следов» / "Ephemeral · nothing kept"; **Ephemeral** filter | `profiles.row.ephemeral` (446), shown on a stopped row `ProfileListView.swift:967-972`; `profiles.filter.ephemeral` (426), `ProfileListView.swift:359-392`, `:734-735` |
| **View for websites**: Safari on this Mac, iPhone, iPad | `DeviceGeneration.swift:122-140`; `gen.*` (233-236) |
| The engine never changes | `DeviceGeneration.swift:8-20`; `editor.safari.honest` (149); `docs/ISOLATION_AND_LIMITATIONS.md:328-333` |
| **Safari version in the User-Agent** changes only the version named; another major release marked risky | `ProfileEditorForm.swift:353-381`; `DeviceGeneration.swift:85-110`; `editor.safari.honest/risky/far` (148-150); `ISOLATION_AND_LIMITATIONS.md:334-341` |
| **Custom user agent** replaces the whole string | `ProfileConfiguration.swift:231-238`; `Sources/PrivacyBrowser/App/SelfTest.swift:2190-2195`; `Tests/BrowserCoreTests/LibraryTests.swift:231-234` |
| Window choices: as it is, a MacBook Air/Pro screen below the menu bar, custom size in points | `ProfileEditorForm.swift:455-497`; `WindowSize.swift:12-37`, `:53-90` (two MacBook Air, two MacBook Pro screens); `editor.window.preset` (184), `editor.window.points` (183) |
| New profiles get a random size that fits, so they do not open alike | `settings.newProfiles.randomWindow.detail` (1134); `editor.window.random` (185); `WindowSize.swift:39-50` |
| Pages measure the real window; the screen stays this Mac's | `editor.window.note` (188); `WindowSize.swift:3-11`; `ISOLATION_AND_LIMITATIONS.md:428`; self-test `SelfTest.swift:3504-3547` |
| No separate "country" field | `ProfileConfiguration.swift:8-135` (no country field), `ProfileEditorView.swift:31-96`, `ProfileEditorForm.swift:516-604` |
| From the connection = where the proxy exits, looked up through it at each launch; without a proxy, this Mac's | `editor.locale.connection.proxy` (164), `editor.locale.connection.direct` (165); `Sources/BrowserCore/Profiles/LocaleChoice.swift:5-7`; `ProfileManager.swift:254-266` |
| Manual = your own; Random = one country's pair, kept until **Pick another** | `editor.locale.manual/random` (162-163), `editor.locale.randomChosen` (168), `editor.locale.pickAnother` (169); `LocaleChoice.swift:8-11`, `:14-57`; `ProfileEditorView.swift:212-219` |
| WebKit takes the language once per run; shared process → the first profile's; own app → its own | `editor.language.note` (177); `ISOLATION_AND_LIMITATIONS.md:431`, `:1138` |
| No warm-up country in the editor; chosen under **Warm Up…** (**Ready-made list** → **By country**, or **Put together for me**, proxy country's sites first) | no warm-up field in any editor part (`ProfileEditorForm.swift:273-740`); `Sources/PrivacyBrowser/UI/WarmUpView.swift:386-391` (source picker), `:405-430` (groups), `:443-459` (composed by the proxy's country); `Sources/BrowserCore/WarmUp/WarmUpChoice.swift:10-17`, `:40-52`; `warmup.composed.explanation` (860) |
| Cookies pasted or dropped reach a new profile at its first launch, before the first page | `editor.cookies.note.new` (173); `ProfileEditorView.swift:559-572`; `ProfileEditorForm.swift:846-909` |

### Запуск и остановка / Launching and stopping {#launch}

| Claim | Evidence |
|---|---|
| **Launch** on a stopped row; «Запуск…» / "Starting…" while starting | `ProfileListView.swift:1001-1003`, `:954-956` |
| Then **Running** group, buttons **New Window** and **Stop** | `ProfileListView.swift:615-618`, `:995-1000` |
| **Stop** closes the profile and encrypts its data, «Шифрование данных…» / "Encrypting data…", back to **Ready** | `ProfileManager.swift:759-815` (stop → seal); `ProfileListView.swift:957-958`; `profiles.footnote.sealed` (431) |
| Closing the last window stops the profile | `ProfileManager.swift:327-332`; `Sources/PrivacyBrowser/App/ProfileSessionHost.swift:166-170`; `settings.behavior.warnClosing.detail` (1141); `README.md:237-239` |

### Окно профиля / The profile's window {#window}

| Claim | Evidence |
|---|---|
| Depends on **Each profile its own app in the Dock**, Settings → **Behavior** | `SettingsView.swift:428-437`; `AppSettings.swift:192-202`; `settings.behavior.ownProcesses` (1144), `.detail` (1145) |
| On by default (in the build without the App Sandbox) | `Sources/PrivacyBrowser/Browser/ProfileProcess.swift:32-41` (`return !AppEnvironment.isSandboxed`) |
| On: own process, own Dock icon with the name's first letters, Safari's own window (address bar, tabs, menus) | `settings.behavior.ownProcesses.detail` (1145); `Sources/PrivacyBrowser/App/DockIcon.swift:3-12`; `AppSettings.swift:27` (2 letters by default), `settings.behavior.dockLetters` (1148); `Sources/PrivacyBrowser/Browser/SafariChromeHost.swift:6-15`, `:43-66` (Safari's main menu); `docs/SAFARI_PROCESS.md:689-692`; `ISOLATION_AND_LIMITATIONS.md:856-863` |
| Tabs, zoom and downloads follow Safari's settings there | `settings.behavior.safariNote` (1151) |
| Off: the app's windows, address field and the chip (glyph, name, exit flag) | `Sources/PrivacyBrowser/Browser/BrowserWindowController.swift:120-160`; `Sources/PrivacyBrowser/Browser/BrowserChrome.swift:5-8`; `README.md:11-13`; `toolbar.address.placeholder` (781) |
| iPhone/iPad views always in the app's window | `SafariChromeHost.swift:38-41`, `:114-121`; `SelfTest.swift:1390-1392`; `ISOLATION_AND_LIMITATIONS.md:858-861` |
| A profile whose WebRTC goes through the network extension too | `ProfileManager.swift:216-221`, `:1036-1038` (it stays in the manager process, where Safari's chrome is not hosted: `SafariChromeHost.swift:16-20`, `:123-124`); `ISOLATION_AND_LIMITATIONS.md:860-861` |

### Изменение, копия и удаление / Editing, copying and deleting {#edit}

| Claim | Evidence |
|---|---|
| ⋯ menu or right-click → **Edit…** opens the same editor | `ProfileListView.swift:914` (context menu), `:1007-1019`, `:1025-1044`, `:261-263`; `ProfileEditorView.swift:361-371` |
| A running profile gets the changes after a restart | `editor.footer.note` (102); `AppModel.swift:369` |
| There is no Duplicate command | no profile duplicate/clone in `Sources/PrivacyBrowser`, `Sources/BrowserCore`, `Resources/*.lproj`, `README.md`, `docs/ROADMAP.md` (grep `duplicat|clone|дублир`: only passwords, proxy import and warm-up lists); the row menu `ProfileListView.swift:1025-1044` has none |
| Export + import = a copy with all the data, added as a new profile | `Sources/BrowserCore/Profiles/ProfileTransfer.swift:8-17`, `:162-173` (`repository.create`); `transfer.export.explanation` (949), `transfer.import.explanation` (958); self-test row `ISOLATION_AND_LIMITATIONS.md:41` |
| The export file has a password of its own | `transfer.export.explanation` (949), `transfer.password` (954); `ProfileTransfer.swift:20-25` |
| **⋯** next to **New Profile** → **Import Profile…** | `ProfileListView.swift:548-575` (header menu, then the New Profile button); `profiles.menu.more` (438) is that menu's tooltip |
| **Profile name** can rename the import | `transfer.import.name` (961); `ProfileTransfer.swift:162-173` (`name ?? manifest.name`) |
| **Delete…** → **Delete Profile and All Its Data**; what is deleted | `ProfileListView.swift:90-98`, `:1042`; `profiles.delete.title/confirm/message` (414-416) |
| A running profile is stopped first | `ProfileManager.swift:907-919` |

## Numbers in visible text

| As written | Source |
|---|---|
| `26` in **Safari на macOS 26 (соответствует движку)** / **Safari on macOS 26 (matches this engine)** | label `gen.macos26` (236); `DeviceGeneration.swift:124` (`osVersionLabel: "26"`) |
| `3` in **3 месяца** / **3 months** | label `editor.retain.quarter` (133); `ProfileEditorView.swift:61` (90 days), `:130` |
| «семи» / "seven" parts (word) | `ProfileEditorForm.swift:13` (seven `Topic` cases) |
| «двух» / "two" letters (word) | `ProfileLabels.swift:42` (`maximumLetters = 2`); label `editor.avatar.letters` (193) |
| `1.`–`4.` | ordered-list markers, not figures |

No other figures. ⌘N, ⌘K and ⌘, are key combinations (`ProfileListView.swift:574`, `:114-117`, `PrivacyBrowserApp.swift:69`).

## unv markers (1)

1. **Block in {#window}: which build customers get.** The Safari-window behaviour exists only in the build
   without the App Sandbox: `ProfileProcess.swift:37-41`, `AppSettings.swift:202`
   (`canChooseProfileProcesses = !isSandboxed`); the sandboxed build shows `settings.behavior.ownProcesses.off`
   (1147) «Не в этой сборке» / "Not in this build" with `settings.behavior.ownProcesses.sandboxed` (1146), and
   every profile runs in the app's windows. `scripts/release.sh:19`, `:37` releases `SANDBOX=1` (sandboxed) by
   default, and `README.md:40`, `:48` call the sandboxed build the default/release build. The site
   (`features.mjs`, `how-it-works.mjs`, `download.mjs`) and the brief describe Safari's own window per
   profile. Confirmed by: the owner's decision on which build is released (and `release.sh` run with that
   `SANDBOX` value).

## UI labels → Localizable.strings keys

| RU | EN | Key (line) |
|---|---|---|
| Новый профиль | New Profile | `profiles.action.new` (406), `editor.title.new` (214) |
| Новый профиль… | New Profile… | `palette.newProfile` (300) |
| Сохранить / Отмена | Save / Cancel | `common.save` (46), `common.cancel` (40) |
| Готовы к запуску / Запущены | Ready / Running | `profiles.group.ready` (432), `profiles.group.running` (433) |
| Профиль, Соединение, Идентичность, Окно, Место и язык, Конфиденциальность, Данные | Profile, Connection, Identity, Window, Location and Language, Privacy, Data | `editor.topic.profile/connection/identity/window` (142-145), `editor.topic.location/privacy/data` (189-191) |
| Название, Значок, Теги, Заметки, Начальный адрес, Поисковик | Name, Glyph, Tags, Notes, Start URL, Search engine | `editor.name` (122), `editor.avatar` (192), `editor.tags` (196), `editor.notes` (201), `editor.startURL` (141), `editor.search` (205) |
| Временный профиль | Ephemeral | `editor.ephemeral.title` (98) |
| Подключение: Без прокси, Из списка, Новый | Connection: No Proxy, From the List, New | `editor.proxy.connection` (1061), `editor.proxy.mode.none/saved/new` (1062-1064) |
| WebRTC, Отключён | WebRTC, Disabled | `editor.webrtc` (221), `editor.webrtc.disabled` (222) |
| Вид для сайтов | View for websites | `editor.generation` (103) |
| Safari на macOS 26 (соответствует движку) | Safari on macOS 26 (matches this engine) | `gen.macos26` (236) |
| Версия Safari в User-Agent | Safari version in the User-Agent | `editor.safari.version` (146) |
| Свой User-Agent | Custom user agent | `editor.ua.useCustom` (220) |
| Размер окна, Как есть (реальное устройство), Свой размер | Window size, As it is (real device), Custom size | `editor.window.size` (178), `editor.window.app` (179), `editor.window.custom` (180) |
| Геолокация, Запретить | Geolocation, Deny | `editor.geo` (107), `editor.geo.deny` (109) |
| Часовой пояс и язык: Из подключения, Вручную, Случайно; Выбрать другое | Time zone and language: From the connection, Manual, Random; Pick another | `editor.locale` (160), `editor.locale.connection/manual/random` (161-163), `editor.locale.pickAnother` (169) |
| Локальные запросы, Защищать | Local requests, Protect | `editor.local` (152), `editor.local.protected` (153) |
| Safe Browsing (запросы идут в обход прокси) | Safe Browsing (lookups bypass the proxy) | `editor.safeBrowsing` (136) |
| Cookies, История, Пароли, Синхронизация | Cookies, History, Passwords, Sync | `editor.cookies` (170), `editor.section.history/passwords/sync` (137, 139, 140) |
| 3 месяца | 3 months | `editor.retain.quarter` (133) |
| Новые профили | New Profiles | `settings.section.newProfiles` (1092) |
| Временные | Ephemeral | `profiles.filter.ephemeral` (426) |
| «Временный, без следов» (quoted row text) | "Ephemeral · nothing kept" | `profiles.row.ephemeral` (446) |
| Прогрев… | Warm Up… | `profiles.row.warmUp` (459) |
| Готовый список, По странам, Умный подбор | Ready-made list, By country, Put together for me | `warmup.source.preset` (913), `warmup.group.country` (874), `warmup.source.composed` (911) |
| Запустить, Новое окно, Остановить | Launch, New Window, Stop | `profiles.row.launch` (449), `profiles.row.newWindow` (453), `profiles.row.stop` (458) |
| «Запуск…», «Шифрование данных…» (quoted row text) | "Starting…", "Encrypting data…" | `profiles.row.starting` (457), `profiles.row.encrypting` (445) |
| Профили — отдельными приложениями в Dock | Each profile its own app in the Dock | `settings.behavior.ownProcesses` (1144) |
| Поведение | Behavior | `settings.section.behavior` (1093) |
| «Не в этой сборке» (unv block) | "Not in this build" | `settings.behavior.ownProcesses.off` (1147) |
| Изменить… | Edit… | `profiles.row.edit` (444) |
| Экспортировать профиль… | Export Profile… | `profiles.row.export` (946) |
| Импортировать профиль… | Import Profile… | `profiles.menu.import` (947) |
| Имя профиля | Profile name | `transfer.import.name` (961) |
| Удалить… | Delete… | `profiles.row.delete` (443) |
| Удалить профиль и все его данные | Delete Profile and All Its Data | `profiles.delete.confirm` (414) |
| командная палитра (lower case, in prose) | command palette | `menu.commandPalette` (291) |

## Notes for the owner (found while checking)

- **Build vs. site.** See the unv marker: the release script's default build has no Safari window per profile.
- **No warm-up country at profile creation.** `site-prototype/.../copy/source/en/download.mjs:30` says "Create a
  profile: A name, a proxy and, if you like, a country for warm-up". The editor has no such field; the
  warm-up's country is chosen on the Warm Up screen or follows the proxy's exit country.
- **English-only error.** An empty name is refused with the core's text "Invalid configuration: profile name
  must be 1–128 characters" (`ProfileRepository.swift:566`, `Sources/BrowserCore/Support/CoreError.swift:35`) —
  in the Russian UI too. The article therefore does not quote it.
- **"Appears as" for Mac profiles always reads "Mac · Safari 26".** `ProfileListView.swift:340-349` shows the
  generation's `osVersionLabel` ("26", `DeviceGeneration.swift:124`), not the Safari version the profile's
  User-Agent names (this Mac's, or the one chosen under **Safari version in the User-Agent**). The article does not
  quote the column for Mac profiles.
- **Stale comment.** `PrivacyBrowserApp.swift:69` mentions "⋯ → Settings… in the Profiles window"; that header
  menu (`ProfileListView.swift:548-569`) has no Settings… item, and `profiles.menu.settings` (1203) is unused.
- **Wording.** `editor.language.note` (177) points to "Settings → Behavior → each profile its own app", while the
  switch is labelled "Each profile its own app in the Dock" (1144).
- **Checker.** The Safe Browsing label contains «в обход» / "bypass" (`editor.safeBrowsing`, 136): the app's own
  label, not one of the phrases the brief forbids. The articles contain no other "обход"/"bypass".
- Not mentioned in the article, so no discrepancy to flag here: system requirements (Info.plist's 14.0).
