# docs-vault — facts

Source: `/home/user/product-src` at 194828b (branch `claude/secret-partner-setup-e505tc`), read-only; #change follows the same branch at 83f931a (the fix of the password change and sync). Paths are relative to it
unless they start with `/`. `Localizable.strings` keys sit on the same line in `Resources/ru.lproj` and `Resources/en.lproj`.

Word count (lead + body; tokens containing letters, markdown markers excluded): ru 806, en 883 (with numbers counted: ru 821,
en 895).

## Claims → evidence

### #contents — What the vault holds

| Claim | Evidence |
|---|---|
| The vault is the folder `PrivacyBrowser` in the account's Application Support; `~/Library/Containers/…/Data/Library/Application Support/PrivacyBrowser` with the App Sandbox, `~/Library/Application Support/PrivacyBrowser` without it | `Sources/PrivacyBrowser/App/AppEnvironment.swift:15-26`; `docs/ARCHITECTURE.md:119-123`; `docs/ISOLATION_AND_LIMITATIONS.md:1452-1488` (§9: in the sandbox every path is inside the container). The bundle id in the container path is the release's, not decided in code (`scripts/build-app.sh` defaults to `dev.local.PrivacyBrowser`), hence the `…`. |
| **Настройки → О приложении → Сборка** shows which build | `Sources/PrivacyBrowser/UI/SettingsView.swift:690-696` (fact `settings.about.build`, value `settings.about.build.sandboxed` / `.unsandboxed` from `AppEnvironment.isSandboxed`). |
| Encrypted: profile list; each profile's settings with its proxy and the proxy's login and password, tags and notes | `docs/ARCHITECTURE.md:124-132` (`index.bin`, `config.bin` incl. tags, notes, glyph); proxy credentials live in the profile's configuration (`docs/SYNC_FORMAT.md:45-47`: “each profile's settings with its proxy and its credentials”). |
| Saved passwords, history, bookmarks | `docs/ARCHITECTURE.md:92-94, 133, 142-143`; `Sources/BrowserCore/Passwords/PasswordVault.swift:124-127`, `Library/HistoryStore.swift:57-58`, `Library/BookmarkStore.swift:39-40`. |
| Cookies for sync and cookies imported before a launch; warm-up plan and schedule; open tabs if restoring them is on | `docs/ARCHITECTURE.md:95-99, 134-140`; `Sources/BrowserCore/Profiles/ProfileRepository.swift:268-269, 305-310, 346-347, 365-366, 383-384` (keys `cookie-import`, `cookies`, `cookie-baseline`, `warm-up`, `warm-up-schedule`, `open-tabs`). |
| Website data archive (cookies, localStorage, IndexedDB, cache) and the state of the profile's Safari window | `docs/ARCHITECTURE.md:100, 144, 156-169` (`webdata.pbsa`); `ProfileRepository.swift:59-61` (`safarihome.pbsa`); `Sources/PrivacyBrowser/Browser/SafariHomeVault.swift:107, 129`; `Sources/PrivacyBrowser/Browser/SafariDefaults.swift:5-6` (Safari's window preferences kept in the profile's home, sealed into the vault). |
| The proxy list and this Mac's sync settings | `docs/ARCHITECTURE.md:86-88, 126-127`; `Sources/BrowserCore/Vault/MasterVault.swift:183-185` (`device-settings`, `proxy-list` keys); `Sources/BrowserCore/Vault/DeviceSettings.swift` (sync target incl. server token, last status; also the automation API settings and the profiles to reopen at the next unlock — `AppModel.swift:259-278`). |
| Outside the vault, unencrypted: downloaded files | `settings.downloads.note` (1171: «Загруженные файлы — вне зашифрованного хранилища профилей…»). |
| …the choices in the Settings window (ordinary app preferences, nothing secret) | `docs/ISOLATION_AND_LIMITATIONS.md:1544-1546` (“Settings are this Mac's, in the app's defaults (per key; nothing secret in them…)”); `docs/ARCHITECTURE.md:457-459`. |
| …files you export: cookies and the proxy list in plain text, a profile under the file's own password | `cookieExport.warning` (1042: “The file is not encrypted…”); `proxies.export.warning` (528: “…user names and passwords in plaintext…”); `Sources/BrowserCore/Profiles/ProfileTransfer.swift:8-30` (`.pbprofile`, “encrypted with a password of its own”, Argon2id); `transfer.password.note` (956). |

### #keys — How the data is encrypted

| Claim | Evidence |
|---|---|
| The master password isn't stored; at each unlock Argon2id (RFC 9106: 64 MiB, 3 passes, 4 lanes) derives a key from it and a random 16-byte salt | `Sources/BrowserCore/Crypto/KeyDerivation.swift:29-38` (`recommended()`: 64·1024 KiB, 3 passes, 4 lanes; `secureRandomBytes(16)` salt), `:60-89` (`deriveKey`); `Sources/BrowserCore/Vault/MasterVault.swift:88-105` (unlock derives the key every time); `Sources/BrowserCore/Crypto/Argon2.swift:9-12` (Argon2id v1.3, RFC 9106, checked against the RFC vector — `Tests/BrowserCoreTests/Argon2Tests.swift:18`); `docs/ARCHITECTURE.md:73-76`; registered in `facts.mjs` (`['64','3','4']`, `'9106'`, `'16'`). |
| That key opens only the vault key | `MasterVault.swift:24-25, 73, 98` (the password-derived KEK wraps/unwraps the VMK and nothing else); `docs/ARCHITECTURE.md:78-81`. |
| Vault key: random, 256-bit; encrypts the profile list, the profile keys, the proxy list, this Mac's settings, sync | `MasterVault.swift:70` (`SymmetricKey(size: .bits256)`), `:179-190` (HKDF purposes `profile-index`, `profile-key-wrap`, `sync-envelope`, `sync-object-id`, `device-settings`, `proxy-list`); `docs/ARCHITECTURE.md:81-88`; `facts.mjs` `'256'`. |
| Profile key: random, 256-bit, one per profile; encrypts the profile's files | `ProfileRepository.swift:140` (`SymmetricKey(size: .bits256)` per new profile), `:18-22` (stored only wrapped in the index); `docs/ARCHITECTURE.md:90-100`. |
| Different kinds of files use different keys — these two or ones derived from them | `docs/ARCHITECTURE.md:90-105` (`config.bin` under the profile key directly, every other file under an HKDF key of its own; HKDF salted with the vault/profile id); `Sources/BrowserCore/Crypto/AEAD.swift:65-69`. |
| AES-256-GCM throughout | `AEAD.swift:8-16` (every small object); `Sources/BrowserCore/Archive/EncryptedChunkStream.swift:13-17, 50-53` (the website-data archive: AES-GCM chunks, a fresh per-archive key from HKDF with a random salt). |
| Every encrypted file is bound to its purpose and owner; moved elsewhere it won't decrypt | `AEAD.swift:14-16` (AAD names purpose and owner), `:41-42`; `docs/ARCHITECTURE.md:103-105`; `Tests/BrowserCoreTests/BrowserCoreTests.swift:244` (`testTamperingTruncationAndWrongKeyLeaveNoPlaintext`). |
| A profile in its own process gets only its profile key, never the vault key | `docs/ARCHITECTURE.md:107-111`; `Sources/BrowserCore/Vault/ProfileGrant.swift`; `MasterVault.swift:107-112, 187-190` (`CoreError.notGranted`); `Tests/BrowserCoreTests/ProfileGrantTests.swift`. (Only the build without the App Sandbox runs profiles in their own processes.) |
| Website data is decrypted on disk only while the profile runs, sealed again when it stops | `docs/ARCHITECTURE.md:171-192` (profile lifecycle); `README.md:422` (“Plaintext on disk while the profile runs”). |
| After a crash, what was left decrypted is encrypted at the next unlock | `AppModel.swift:253-256` → `Sources/PrivacyBrowser/Browser/ProfileManager.swift:1208-1240` (`recoverUnsealedProfiles`); `README.md:422` (“a crash leaves plaintext until the next unlock”); string `profile.crashedUnsealed` (976). |
| Warn: `vault.json` is plaintext (salt, Argon2id parameters, wrapped vault key); whoever has it can guess passwords offline, slowed only by Argon2id; a weak password won't hold | `MasterVault.swift:8-13` (“Anyone holding this file can run an offline password-guessing attack, bounded only by the KDF cost… choose a strong master password”); `docs/ARCHITECTURE.md:124`; `docs/ISOLATION_AND_LIMITATIONS.md:1506-1511` (“Does not protect against … Offline guessing of a weak master password by anyone holding `vault.json`”). |

### #lock — Unlocking and locking

| Claim | Evidence |
|---|---|
| **Хранилище заблокировано**, «Введите мастер-пароль, чтобы продолжить.», **Разблокировать** → the Profiles window | `Sources/PrivacyBrowser/UI/VaultViews.swift:119-176`; `AppModel.swift:110-139, 198-257`. |
| **Настройки → Запуск → После разблокировки** decides whether the profiles open at the last quit start too | `Sources/PrivacyBrowser/App/AppModel.swift:259-278` (`reopenProfilesFromLastQuit`, `settings.startup == .reopenProfiles`); strings `settings.startup.open` (1115), `.detail` (1116). |
| Wrong password: alert **Ошибка** / **Error** with “Wrong master password”; under the field, when the vault was created and its folder; another build has its own vault and password | `AppModel.swift:133-136` (`unlockFailed = true`, rethrow) + `:774-782` (`perform` → `showError(errorText(error))`); `Sources/PrivacyBrowser/UI/ProfileListView.swift:24-29` (alert titled `common.error`); the text is `CoreError.description` (`Sources/BrowserCore/Support/CoreError.swift:30`: “Wrong master password”) — **English only, also in the Russian UI**; `VaultViews.swift:135-150` (`unlock.vault.info` with `vaultCreatedDescription`, `vaultPathDescription`, `AppModel.swift:145-154`). |
| **Заблокировать** at the bottom of the sidebar, also in ⌘K: stops every profile, encrypts their data, forgets the keys | `ProfileListView.swift:757-761` (sidebar button, help `profiles.action.lock.help` 405 «Остановить все профили, зашифровать их данные и забыть все ключи»), `:162` (⌘K command); `AppModel.swift:287-329` (`lock` → `performLock`: manager shut down — every profile stopped and sealed — then repository, manager, keys dropped, `phase = .locked`). |
| ⌘Q does the same and waits until every profile is encrypted | `Sources/PrivacyBrowser/App/QuitCoordinator.swift:1-22, 64-119`; `Sources/PrivacyBrowser/App/PrivacyBrowserApp.swift:87-96, 137-139`. |
| No automatic lock — no timer, nothing on sleep | Search of `Sources/` for `willSleep`, `screensDidSleep`, `sessionDidResignActive`, `screenIsLocked`, idle timers: nothing. `AppModel.lock` callers: `ProfileListView.swift:272` (Lock action), `PrivacyBrowserApp.swift:89` (quit), `AppModel.swift:732` (Install Now). |
| The master password is asked again before saved passwords are shown (**Пароли заблокированы**) and before it is changed | `Sources/PrivacyBrowser/UI/PasswordsView.swift:114-124` → `AppModel.swift:505-509` (`verifyMasterPassword`); string `passwords.locked.title` (388); `MasterVault.swift:200-208` (`changePassword` re-verifies the current password: “an unlocked session alone must not be enough”). |

### #change — Changing the master password

| Claim | Evidence |
|---|---|
| **⋯** (**Ещё**) → **Сменить мастер-пароль…** | `ProfileListView.swift:548-569` (the ⋯ menu; `profiles.menu.changePassword` at :558; tooltip `profiles.menu.more`), `:86` (sheet `ChangePasswordView`). |
| Fields **Текущий пароль**, **Новый пароль**, **Повторите новый пароль**; **Сменить** available once new ≥ 10 characters and both new fields match | `VaultViews.swift:178-213` (`.disabled(current.isEmpty \|\| new.count < 10 \|\| new != confirmation)` at :207). A wrong current password is refused by `MasterVault.changePassword` (`:205`) and shown in the error alert (`AppModel.swift:331-338`). |
| The window's note, quoted word for word in both languages (three paragraphs, the last one in a warn box): «Новым паролем заново шифруется только ключ, который открывает хранилище; …» / “Only the key that opens the vault is encrypted anew with the new password; …” | `changepw.note` (33) at **83f931a** (branch `claude/secret-partner-setup-e505tc`, 1 November 2026: the fix). The developer's account of the same behaviour: `docs/ARCHITECTURE.md:116-141`, «Changing the master password: what it does, and what it does not». Code: `MasterVault.swift:230-237` (`changePassword` re-verifies the current password, re-wraps the VMK, `passwordRevision` one above both headers); `AppModel.swift:410-430` (`changePassword` then `publishPasswordChange` to the sync location right away). Inserted verbatim at the developer's request (relayed by the owner); not marked unconfirmed — the developer confirms it by reading the code and by the fix. |
| The two messages after a change, quoted word for word: the location out of reach (`(…)` stands for the error the app inserts), and another Mac's password kept there | `changepw.sync.later` (34), `changepw.sync.notThere` (35) at 83f931a; shown by `AppModel.swift:445-460` (`publishPasswordChange`: `publishVaultHeader() != .published` → `notThere`; an error → `later` with the error's text). |

### #forgot — If you forgot the master password

| Claim | Evidence |
|---|---|
| Can't be recovered: the vault key is wrapped by the password alone, no other copy | `MasterVault.swift:14-26` (one `wrappedMasterKey`), `:64-81`; `setup.subtitle` (739). |
| Nothing is deleted | `MasterVault.swift:114-133` (`moveAside`: “nothing is deleted — renaming it back restores it”); `Tests/BrowserCoreTests/BrowserCoreTests.swift:47-67` (`testMoveAsideKeepsOldVaultAndFreesTheFolder`: the backup still unlocks with the old password). |
| After a wrong password, **Не помню пароль…** | `VaultViews.swift:135-156` (shown only when `model.unlockFailed`), `:151`. |
| **Создать новое хранилище?** → **Отложить хранилище и создать новое** | `VaultViews.swift:160-165`; strings `unlock.reset.title` (812), `unlock.reset.confirm` (810), `unlock.reset.message` (811). |
| The folder is renamed `PrivacyBrowser-backup-` + date and time; the setup screen shows where | `MasterVault.swift:118-133` (`<root>-backup-<yyyy-MM-dd-HHmmss>`, a counter if taken); `AppModel.swift:164-176` (`startOver` → `movedAsideVaultPath`, `phase = .setup`); `VaultViews.swift:86-95` (`setup.movedAside`, 736). |
| Its profiles stay encrypted with the old password; to go back: quit, rename the folder back to `PrivacyBrowser` — after renaming the new vault, which has that name by then | `unlock.reset.message` (811); `setup.movedAside` (736: «…закройте приложение и переименуйте эту папку обратно в «PrivacyBrowser»»); the new vault is created at the same path (`AppModel.root` = `AppEnvironment.vaultDirectory`, `AppModel.swift:64, 70`; `MasterVault.create` refuses an existing `vault.json`, `:65`), so the name is taken until the new vault is moved. |

### #sync — What a sync location sees

| Claim | Evidence |
|---|---|
| Off until **Папка (только локально)** or **Сервер** is chosen in **⋯ → Синхронизация…** | `docs/SYNC_FORMAT.md:41-44` (decision 4, “as built: sync stays off until the user sets a target”); `ProfileListView.swift:551` (⋯ → `profiles.menu.sync`); `Sources/PrivacyBrowser/UI/SyncSettingsView.swift:15-17, 33` (picker `sync.to` with `sync.mode.off/folder/server`). |
| (removed 1 November 2026) The line «no sync server of its own yet» | The owner's decision: sync stays on the site and in the plans — the client is written, and the server is built and deployed (lumen-api-server `docs/SYNC_SERVER.md`, to the browser's `docs/SYNC_SERVER_API.md`). The article describes the product as it ships, so the line is gone. |
| The location sees the vault header in plain text; it exists so another Mac can open the vault with the same password | `docs/SYNC_FORMAT.md:95-97` (`vault-header`: not encrypted, “a new device needs it to derive the key”); `SyncEngine.swift:30-33, 76-85` (`bootstrap`). |
| …but the app itself can't yet set up a second Mac that way | `SyncEngine.bootstrap` is called only by the self-test (`Sources/PrivacyBrowser/App/SelfTest.swift:4780`); the setup screen only creates a vault (`VaultViews.swift:71-117`); choosing a location that holds another vault fails (“sync location holds a different vault”, `SyncEngine.swift:114-118`). |
| …how many objects, their sizes, versions and when they change; a server also sees this Mac's IP address — sync goes directly, not through a profile's proxy | `docs/SYNC_FORMAT.md:128-129` (“The server learns: the vault ID, how many objects exist, their sizes, their revision counters, and when they change”), `:14-20` (decision 1: the app's own connection, no profile's proxy on that path), `:48-51`. |
| Profile list, settings, passwords, bookmarks, history and persistent cookies go encrypted (profile files twice), under opaque names | `docs/SYNC_FORMAT.md:95-103` (objects table, “yes (twice)”), `:110-126` (envelope, AES-256-GCM, HMAC object ids), `:202-206` (persistent cookies only; per-profile switch, on by default); `SyncEngine.swift:46-47`. |
| No profile names, site addresses, proxies, passwords or cookies are visible | `docs/SYNC_FORMAT.md:131-132` (“The server doesn't learn: profile names or count…, settings, proxy credentials, passwords, URLs, or cookies”). |
| Other website data doesn't sync | `docs/SYNC_FORMAT.md:105-108`; `SyncEngine.swift:50-51`. |
| The {{name}} server keeps no IP address (memory only, for rate limits), nor which Mac synced when — only when a vault last changed; the account's Sync page shows what it sees | lumen-api-server 00327fb: `docs/SYNC_SERVER.md`, «Что сервер хранит и что пишет в журнал» (approved by the owner 1 November 2026; checked by `TestSyncKeepsNoTrace`); `docs/SITE_API.md` §9, §10. Cloudflare in front of the server, seeing the IP address but unable to read sync data: `docs/SITE_API.md` §9, the Cloudflare paragraph (69169f0). |

## Numbers in visible text

| Number | Where | Source |
|---|---|---|
| 9106 (RFC 9106) | #keys | `Argon2.swift:9`; `facts.mjs` `'9106'`. |
| 64 (MiB), 3 (passes), 4 (lanes/потока) | #keys | `KeyDerivation.swift:29-33`; `facts.mjs` `['64','3','4']`. |
| 16 (bytes of salt) | #keys | `KeyDerivation.swift:36` (`secureRandomBytes(16)`); `facts.mjs` `'16'`. |
| 256 (bit keys) | #keys table | `MasterVault.swift:70`, `ProfileRepository.swift:140`; `facts.mjs` `'256'`. |
| 10 (characters, new password) | #change | `VaultViews.swift:207`; `facts.mjs` `'10'`. |
| AES-256-GCM, Argon2id | #keys | technical identifiers (`AEAD.swift:11`). |
| 1–4 | numbered steps | list markers. |

## unv markers

None. Every statement above is backed by code, a test or a repository doc; things that do not exist (automatic lock, a sync server, setting up a second Mac from sync, recovery of the password) are stated as absent because the code has no path for them.

## UI labels used (Localizable.strings keys)

| ru | en | key | line |
|---|---|---|---|
| Настройки | Settings | `settings.title` | 1090 |
| О приложении | About | `settings.section.about` | 1107 |
| Сборка | Build | `settings.about.build` | 1189 |
| Запуск | Startup | `settings.section.startup` | 1091 |
| После разблокировки | After unlocking | `settings.startup.open` | 1115 |
| Хранилище заблокировано | Vault locked | `unlock.title` | 814 |
| Введите мастер-пароль, чтобы продолжить. (quoted) | Enter your master password to continue. | `unlock.subtitle` | 813 |
| Разблокировать | Unlock | `unlock.action.unlock` | 808 |
| Профили | Profiles | `profiles.title` | 471 |
| Ошибка | Error | `common.error` | 44 |
| Заблокировать | Lock | `profiles.action.lock` | 404 |
| Пароли заблокированы | Passwords are locked | `passwords.locked.title` | 388 |
| Ещё (tooltip of ⋯) | More | `profiles.menu.more` | 438 |
| Сменить мастер-пароль… | Change Master Password… | `profiles.menu.changePassword` | 437 |
| Текущий пароль | Current password | `changepw.current` | 31 |
| Новый пароль | New password | `changepw.new` | 32 |
| Повторите новый пароль | Repeat new password | `changepw.repeat` | 34 |
| Сменить | Change | `changepw.action.change` | 30 |
| (quoted note) | (quoted note) | `changepw.note` | 33 |
| Не помню пароль… | Forgot password… | `unlock.reset.action` | 809 |
| Создать новое хранилище? | Create a new vault? | `unlock.reset.title` | 812 |
| Отложить хранилище и создать новое | Set this vault aside and create a new one | `unlock.reset.confirm` | 810 |
| Создайте мастер-пароль | Create a master password | `setup.title` | 740 |
| Синхронизация… | Sync… | `profiles.menu.sync` | 439 |
| Папка (только локально) | Folder (local-only) | `sync.mode.folder` | 752 |
| Сервер | Server | `sync.mode.server` | 754 |

**Single-language text:** the wrong-password alert's message “Wrong master password” is `CoreError.description` (`CoreError.swift:30`), English in both UIs (the alert title `common.error` is localized). The article quotes it as shown.

## Discrepancies found while writing (not in the article)

- **Password change vs. sync — fixed at 83f931a:** at 194828b nothing in the app called `publishVaultHeader()` after a master-password change, so the sync location kept the old header. The fix publishes it right after the change (`AppModel.swift:410-460`), and a header with fewer changes is never put back (`SyncEngine.publishVaultHeader`); #change now quotes the app's own text about it.
- **`sync.footer` is wrong about cookies:** both languages (line 751) say cookies are not synced («Не синхронизируется: данные сайтов (cookie, хранилище, кэш)»), but persistent cookies do sync (`ProfileRepository.swift:573-576` `ProfileSyncFile.cookies`; `docs/SYNC_FORMAT.md:189-206`; README.md:278). The article follows the code.
- **No UI joins a second Mac to a sync location** although `docs/ARCHITECTURE.md:113-115` presents “a new device unlocks with the same password” as a feature: the core has it (`SyncEngine.bootstrap`), the app does not.
- **ROADMAP 0.3 wording:** the article avoids the positioning words the ROADMAP warns about; nothing in the vault code needed them.
