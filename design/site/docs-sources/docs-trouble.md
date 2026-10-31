# docs-trouble — facts

Evidence for `docs-trouble.ru.md` and `docs-trouble.en.md`. Paths are relative to `/home/user/product-src`
(detached checkout of `claude/secret-partner-setup-e505tc` at 194828b). In `Localizable.strings` every key used
here sits on the same line number in `en.lproj` and `ru.lproj`, so one number is given.

Quoting conventions: the app's `%@` (a profile name, a host, a reason) is shown as `…`. Long messages are cut
after the part the reader needs, marked `…`. Nested quotes are set typographically: in English the app's inner
“%@” becomes ‘…’, in Russian the app's inner «%@» becomes „…“. Nothing else in a quoted text was changed.

## 1. UI labels (bold in the articles)

| EN label | RU label | Key | Line |
|---|---|---|---|
| Error | Ошибка | `common.error` (title of the app's one alert, `UI/ProfileListView.swift:24-29`) | 44 |
| “…” loads no pages | «…» не загружает страницы | `proxyProblem.title` | 715 |
| “…” was not started | «…» не запущен | `proxyProblem.title.notStarted` | 1200 |
| Check Proxy | Проверить прокси | `proxyProblem.check` | 709 |
| Settings | Настройки | `settings.title` | 1090 |
| Proxies (Settings section) | Прокси | `settings.section.proxies` | 1094 |
| A proxy that does not work | Если прокси не работает | `settings.proxies.failure` | 1159 |
| Do not start the profile | Не запускать профиль | `settings.proxies.failure.doNotLaunch` | 1162 |
| Edit… (profile’s ⋯ menu) | Изменить… | `profiles.row.edit` | 444 |
| Launch | Запустить | `profiles.row.launch` | 449 |
| Stop | Остановить | `profiles.row.stop` | 458 |
| And the profiles open at quit | И профили, открытые при выходе | `settings.startup.open.reopen` | 1118 |
| Forgot password… | Не помню пароль… | `unlock.reset.action` | 809 |
| Sync… (⋯ menu) | Синхронизация… | `profiles.menu.sync` | 439 |
| Sync (sheet title) | Синхронизация | `sync.title` | 771 |
| Sync Now | Синхронизировать сейчас | `sync.now` | 755 |
| Last sync failed | Сбой синхронизации | `profiles.sync.failed` | 466 |
| Updates | Обновления | `settings.section.updates` | 1096 |
| Check Now | Проверить сейчас | `updates.checkNow` | 819 |
| Diagnostics | Диагностика | `settings.section.diagnostics` | 1098 |
| Collect Diagnostics… | Собрать диагностику… | `settings.diagnostics.collect` | 1100 |
| Copy Short Report | Скопировать краткий отчёт | `settings.diagnostics.copy` | 1101 |
| About | О приложении | `settings.section.about` | 1107 |
| Build | Сборка | `settings.about.build` | 1189 |
| Not imported: … | Не импортировано: … | `cookies.problemsTitle` | 61 |
| Profiles window (not bold) | окно профилей (not bold) | `window.profiles.title` = Profiles / Профили (932); the ru phrase «окно профилей» is the app's own, `settings.proxies.failure.detail` (1160) | — |

Every key above exists in both languages (`scripts/check_localization.py` fails otherwise). Labels that exist in
one language only: none. Texts the app shows that are in **no** table (English in both UIs) are in §3.

`⌘,` opens Settings: the app's SwiftUI `Settings` scene (`App/PrivacyBrowserApp.swift:69-75`, comment "⌘, and the
app menu's Settings…"). The menu item's own text is the system's, not a key, so the articles name the shortcut.

## 2. Messages quoted (localized ones)

| EN | RU | Key | Line |
|---|---|---|---|
| The proxy works now | Сейчас прокси работает | `proxyProblem.worksNow` (shown after Check Proxy succeeds, `UI/ProxyProblemView.swift:70-76`) | 716 |
| The proxy at ‘…’ requires a user name and password… | Прокси „…“ требует имя пользователя и пароль… | `launch.error.proxyNeedsCredentials` | 252 |
| The profile's proxy is misconfigured… | Прокси профиля настроен неверно… | `launch.error.proxyInvalid` | 251 |
| The file … was saved by a newer version of {{name}}… | Файл … сохранён более новой версией {{name}}… | `error.newerFormat` (text says “Lumen”) | 229 |
| Profile ‘…’ ended unexpectedly. Its data is encrypted… | Профиль „…“ неожиданно завершился. Его данные зашифрованы… | `profile.crashed` | 975 |
| Could not encrypt the data of profile ‘…’ again: … | Не удалось заново зашифровать данные профиля „…“: … | `recovery.webDataNotSealed` | 973 |
| Stop all profiles first. | Сначала остановите все профили. | `sync.stopFirst` | 770 |
| The update was not installed at the last quit: … | При прошлом выходе обновление не установлено: … | `updates.notice.deferred` | 830 |
| The last check failed: … | Последняя проверка не удалась: … | `updates.state.failed` | 844 |

## 3. Messages quoted that are English in both UIs

| Text | Where it comes from |
|---|---|
| Wrong master password | `CoreError.wrongPassword.description` (`BrowserCore/Support/CoreError.swift:30`), shown through `errorText` → `localizedDescription` (`App/Localization.swift:59-64`) by `perform` (`App/AppModel.swift:774-781`). The localized `passwords.locked.wrong` (390) is used only by the Passwords lock, not the unlock screen. |
| Authentication failed (wrong key or data was modified) | `CoreError.authenticationFailed` (`CoreError.swift:29`), thrown by `AEAD.open` on a bad tag (`BrowserCore/Crypto/AEAD.swift:42`) |
| Sync failed: … | hard-coded, `App/AppModel.swift:606` |
| …holds a different vault | `CoreError.corruptData("sync location holds a different vault")`, `BrowserCore/Sync/SyncEngine.swift:93-94, 116-117` (full alert: “Sync failed: Corrupt data: sync location holds a different vault”) |

That is why the Russian article says «текст на английском» / «на английском» next to them.

## 4. Claims → evidence

### At a glance (table)
Each row restates a section below; the cookie row: the report title `cookies.problemsTitle` is shown by
`UI/CookieImportView.swift:87`; details belong to docs-cookies.

### A profile does not start
- Never around the proxy; nothing loads: `allowFailover = false` (`Browser/ProxyConfigurationFactory.swift:51`, doc
  comment line 10); `proxyProblem.subtitle` (714); `settings.proxies.failure.detail` (1160).
- The Profiles window says why: at a launch the manager probes the proxy (`Browser/ProfileManager.swift:211-216,
  497-506`) and `AppModel.reportProxyProblem` opens the sheet (`App/AppModel.swift:229-235`).
- “… loads no pages”: sheet title/subtitle and step-by-step report with advice (`UI/ProxyProblemView.swift:4-8,
  57-77`); Check Proxy re-runs the list's check (`:101, 111-119`); success text `proxyProblem.worksNow` (`:70-76`).
- “… was not started” with **Do not start the profile**: probe before anything is decrypted and refusal
  (`ProfileManager.swift:199-210`; `AppModel.swift:233-235`); the setting (`UI/SettingsView.swift:475-478`); default is
  “Start the profile, say why” (`App/AppSettings.swift:153`).
- The two **Error** texts: `ProfileManager.LaunchError` (`ProfileManager.swift:127-135`), thrown at `:240-243`
  (invalid proxy) and `:291-296` (proxy wants credentials the profile lacks); same text after a late lookup stops a
  running profile, `launch.proxyNeedsCredentialsStopped` (`:656`). Fix in **⋯ → Edit…** (`UI/ProfileListView.swift:1033`).
- Newer version: `error.newerFormat` via `errorText` (`Localization.swift:59-64`); docs/UPDATES.md §4 table:
  `config.bin` “newer: the profile does not start, nothing is written”.

### A profile crashed or hangs
- “In its own process (with its own Dock icon)”: `settings.behavior.ownProcesses.detail` (1145); on by default
  without the App Sandbox (`Browser/ProfileProcess.swift:37-41`).
- Lumen notices the end of the process: `terminationHandler` → `onExit` (`ProfileProcess.swift:144-155`); the
  manager seals the profile's home and, for a non-zero status, shows `profile.crashed` (or `profile.crashedUnsealed`
  if sealing failed) (`ProfileManager.swift:437-475`, message at `:469-471`).
- Brings the Profiles window forward: `onReturnToProfiles` (`ProfileManager.swift:473`) → `activateProfilesWindow`
  (`AppModel.swift:89-95, 203-206`).
- Sign-ins and cookies kept, tabs not: the app's own message `profile.crashed` (975).
- Not restarted: the exit handler has no relaunch (`ProfileManager.swift:437-475`).
- Other profiles keep running: one `Process` per profile (`ProfileProcess.swift:89-161`); the exit handler changes
  only that profile's state (`ProfileManager.swift:437-475`).
- No hang detection: the manager learns about a profile's process only from its exit and its own events
  (`ProfileProcess.swift:144-155`, `ProfileChannel`); no watchdog or heartbeat in `ProfileProcess.swift` or
  `ProfileManager.swift` (the only watchdog in the app is the menu-walk test's, `Browser/SafariMenuWalk.swift:166`).
- **Stop**: row button (`ProfileListView.swift:999`) → `ProfileManager.stop` sends `.stop` and SIGTERM, waits 30 s, then
  SIGKILL (`ProfileManager.swift:759-775`; `ProfileProcess.swift:222-247`). For a profile in Lumen's windows there is no
  process of its own to end (`ProfileManager.swift:776-814`), hence “its own process”.
- Page reload in a Lumen window: `webViewWebContentProcessDidTerminate` → `webView.reload()`
  (`Browser/BrowserTab.swift:398-401`). Nothing is shown to the user.

### Lumen itself quit
- Profiles in Lumen's windows end with the app; their WebKit data stays plaintext until the next unlock:
  docs/ISOLATION_AND_LIMITATIONS.md:633-636.
- Profiles in their own processes quit when the manager is gone: the command channel's end calls
  `NSApp.terminate` (`App/ProfileSessionHost.swift:141-145`). Whether they seal on the way out: unv (§6, marker 3).
- Re-encryption after the next unlock, and its error: `AppModel.swift:252-256` → `ProfileManager.recoverUnsealedProfiles`
  (`:1211-1241`; `recovery.homeNotSealed` at `:1223`, `recovery.webDataNotSealed` at `:1237`); a home still held by a
  surviving process is sealed when it lets go (`:1187-1206`). Self-test: “Crash-recovery sealing”
  (`App/SelfTest.swift:3220-3262`; docs/ISOLATION_AND_LIMITATIONS.md:29).
- Vault files never half-written: `SecureFile.write` = temp file + `synchronize()` + rename
  (`BrowserCore/Support/SecureFile.swift:5-8, 41-56`), used by `BrowserCore/Support/EncryptedDocumentFile.swift:35` and
  `BrowserCore/Passwords/PasswordVault.swift:210`; archives the same way
  (`BrowserCore/Archive/EncryptedDirectoryArchive.swift:42-68`).
- Website data on disk comes back: recovery seal then restore, checked by the self-test (“recovery: data restored after
  recovery seal”, `SelfTest.swift:3257-3263`). Last-moment writes can be lost: docs/ISOLATION_AND_LIMITATIONS.md item 2.
- History: debounced, “at most the last `saveDelay` seconds” lost, `saveDelay = 3` (`Browser/ProfileLibrary.swift:10-12,
  25`); docs/ISOLATION_AND_LIMITATIONS.md:636 “≤ 3 s”. Safari's window records into the same library
  (`Browser/SafariChromeHost.swift:227`).
- Profiles not reopened: the list is read and cleared at each unlock (`AppModel.swift:261-269`) and written only at the
  start of a quit (`:272-279`, called only from `lock(forQuit:)`, `:286-290`). Default is the Profiles window only
  (`AppSettings.swift:147`). Restore tabs is off by default (`AppSettings.swift:166`).
- A crash never installs an update: `App/QuitCoordinator.swift:19-22`; docs/UPDATES.md:168-170.

### The vault does not open
- Wrong password → `unlockFailed = true` and the Error alert (`AppModel.swift:133-135, 774-781`); the lock screen then
  shows `unlock.vault.info` — creation date and folder — and **Forgot password…** (`UI/VaultViews.swift:135-151`;
  `AppModel.swift:145-155`). “Another build keeps its own vault”: `unlock.vault.info` (815).
- Damaged file, right password: e.g. `index.bin` fails `AEAD.open` (`ProfileRepository.swift:540-545`) inside
  `didUnlock` before `phase = .unlocked` (`AppModel.swift:197-200, 246`) → alert with the error's text, phase stays
  locked.
- No repair: the only way out offered at the lock screen is `startOver` (`AppModel.swift:164-176`).
- Diagnostics while locked: `Diagnostics.snapshot` handles `.locked` (`App/Diagnostics.swift:44-50`); Settings is an
  app-level scene (`PrivacyBrowserApp.swift:69-75`).
- Damaged header looks like a wrong password: a failed unwrap of the master key is reported as `wrongPassword`
  (`BrowserCore/Vault/MasterVault.swift:94-101`).
- Cannot be recovered: `setup.subtitle` (739). Forgot password… moves the folder aside, deletes nothing
  (`VaultViews.swift:151-165`; `AppModel.swift:164-176`; `MasterVault.swift:114-133`; `unlock.reset.message`, 811).

### Sync failed
- Only while no profile runs: `AppModel.swift:563-580`; Sync Now disabled with `sync.stopFirst`
  (`UI/SyncSettingsView.swift:62-67`); docs/SYNC_FORMAT.md:254-258.
- Failure: alert `AppModel.swift:603-607`; sidebar state `.failed` → `profiles.sync.failed`
  (`ProfileListView.swift:248-249, 857`), and the sidebar line opens the Sync sheet (`:755`); the sheet shows
  `sync.status.failed` with the reason (`SyncSettingsView.swift:89-92`).
- Different vault: `SyncEngine.swift:93-94, 116-117`; “one folder per vault”: `sync.folder.note` (749).
- Conflicts: settings newer-wins, the other kept as `config.bin.conflict`; passwords keep the remote copy, local kept
  as `passwords.bin.conflict` (docs/SYNC_FORMAT.md:150-162; `ProfileRepository.swift:577-578`); copies encrypted, stay
  on that Mac, not offered for restore (docs/SYNC_FORMAT.md:288-291); counted in the status (`SyncSettingsView.swift:96`).

### An update was not installed
- Installs only at a quit that sealed every profile: docs/UPDATES.md §3 (lines ~150-170); `App/Updates/UpdateGate.swift:4-39`;
  `QuitCoordinator.swift:64-80`.
- Not installed → remembered → said at the next launch: `AppModel.swift:714-724` (`rememberNotInstalled`) and
  `:699-700` (`updates.notice.deferred`, whose text ends “It installs at the next quit that encrypts every profile.”).
- Failed check: `AppUpdater.swift:234-237, 257-260` → `UpdatesView.swift:129`; Check Now `UpdatesView.swift:43`.

### Reporting a problem
- Steps: the Diagnostics section (`SettingsView.swift:85-113, 260-343`); ZIP saved where the person chooses, suggested
  name `Lumen-Diagnostics-<date>.zip` (`Diagnostics.swift:202-208`); “Saved: … Send it to support yourself; nothing
  was sent.” (`settings.diagnostics.saved`, 1104; `Diagnostics.swift:16-17, 220`). Short report shown on screen and
  copied (`SettingsView.swift:283-305`; content `Diagnostics.swift:87-102`). Also in the command palette as
  “Settings: Diagnostics” and “Copy Short Report” (`ProfileListView.swift:162-175`) — not in the article.
- No log files of its own: every log line goes through `os.Logger` (subsystem `PrivacyBrowser`); the ZIP reads them
  with `OSLogStore` and `log show` (`Diagnostics.swift:145-174`); no file logger in `Sources`.
- ZIP contents: `report.txt`, `state.json`, `logs/this-run.txt`, `logs/system-last-30-minutes.txt`, `README.txt`, and
  `safari-chrome.txt` without the sandbox (`Diagnostics.swift:186-200`); `settings.diagnostics.contents` (1106).
- `this-run.txt` is the current process only (`OSLogStore(scope: .currentProcessIdentifier)`, `Diagnostics.swift:147`);
  the system log is read by time and subsystem (`log show --last 30m`, predicate on subsystem/process name,
  `:163-174`), so after a crash the earlier run is only in the system-log part, for 30 minutes → “collect within that
  time” (an inference from that predicate and window).
- Sandboxed build: the file holds a Terminal command instead (`Diagnostics.swift:165-170`). Which build: Settings →
  About → Build (`SettingsView.swift:695-696`; keys 1189-1191).
- What Lumen leaves out: `state.json` holds only numbers, kinds, yes/no and counts (`Diagnostics.swift:104-141`);
  README of the ZIP (`:210-222`); `settings.diagnostics.contents` (1106).
- `<private>`: user values are logged `privacy: .private` (e.g. `ProfileProcess.swift:80, 159`).
- `check_log_privacy.py` (`scripts/check_log_privacy.py`): reads every `.swift` file under `Sources`, takes every
  string interpolation marked `privacy: .public`, and fails unless the expression is a profile's random UUID, a count or
  size, a process id, an enum raw value or status, a yes/no, an error's type/domain/code (`logKind`), a class, method or
  hook name, or one of the listed exceptions with their reasons (`:20-92`) — among them an exception's reason after
  `LogRedaction` cut out addresses, paths, e-mails, quotes and long numbers (`:89-91`), a Safari framework's path, a
  system error's text. Its success line: “every public interpolation is an id, a count, a status or a name from the
  code” (`:152`). It is static: it does not look at a running app, at text without `privacy: .public`, or at what
  WebKit and macOS write. CI runs it on every push and pull request (`.github/workflows/ci.yml:3-5, 26, 46-48`).
- Self-test: builds a ZIP for a profile with a unique name, tag, notes and proxy host/user/password, logs a private
  marker, and searches the ZIP's bytes for all of them (`SelfTest.swift:3666-3695`, list at `:3670`, search at `:3684`).
- Never send: master password — `setup.subtitle` (739); cookie export — `cookieExport.warning` (1042); proxy export —
  `proxies.export.warning` (528). Licence key: an account secret on the site (`copy/source/*/support.mjs` `never`); the
  app has no licence key (docs/ROADMAP.md:146-153, item 2.1 not done) — no app behaviour is claimed.

## 5. Numbers

| Number | Where | Source |
|---|---|---|
| 30 (seconds) | Stop ends a profile's own process after 30 s | `ProfileManager.swift:770` `waitUntilExit(timeout: 30)`; `ProfileProcess.swift:234-246`; docs/UPDATES.md:159 |
| 3 (seconds) | history lost at most | `ProfileLibrary.swift:25` `saveDelay = 3`, comment `:10-12`; docs/ISOLATION_AND_LIMITATIONS.md:636 |
| 30 (minutes) | system log in the ZIP | `Diagnostics.swift:186` `logMinutes: Int = 30`, `:193`; `settings.diagnostics.contents` (1106) |

The 1–3 of the “Reporting a problem” list are list markers. No other digit is in either article.

## 6. unv markers (4 per article: 1 block + 3 inline; same places in ru and en)

1. **#crash, block — a crash mid-write leaves the profile intact.** docs/ROADMAP.md:130-137 (1.8) is open: “`kill -9` of a
   profile's process mid-work does not lose the profile; a test checks it.” What exists: the app's message claims the
   data is encrypted, and the self-test's recovery check drops a session without sealing (`SelfTest.swift:3234-3248`) —
   no process is killed during a write. Confirms it: the 1.8 test.
2. **#crash, inline — what Safari's own window does when a page's process crashes.** Only Lumen's own tab handles it
   (`BrowserTab.swift:398-401`); in Safari's window the web view's delegate is Safari's code, and nothing in the
   repository tests it. Confirms it: kill a page's `com.apple.WebKit.WebContent` process in a profile shown in Safari's
   window and record what happens (a self-test step).
3. **#app, inline — whether profiles in their own processes encrypt their data when Lumen crashes.** Intended
   (`ProfileSessionHost.swift:141-145`), not tested (no test kills the manager). A risk seen in the code: the quit path
   first writes `.sealing` to stdout (`ProfileSessionHost.swift:25-27, 196-197`), a pipe whose reader was the dead
   manager; SIGPIPE is not ignored anywhere in the app (only `SO_NOSIGPIPE` on probe sockets,
   `BrowserCore/Proxies/ProbeSocket.swift:243`), so that write may end the process before it seals. Either way the
   next unlock re-seals (`ProfileManager.swift:1211-1241`). Confirms it: a self-test step that SIGKILLs the manager with a
   profile running in its own process and checks how that process ended and whether its home is sealed.
4. **#report, inline — whether WebKit's own lines in the system log hold page addresses in clear.**
   `check_log_privacy.py` reads only this repository's Swift code; the self-test's ZIP is built for a profile that never
   ran (`SelfTest.swift:3670-3678`), so no page address of it can be in the log. Confirms it: open a unique URL in a
   profile, collect diagnostics in the unsandboxed build, search `logs/system-last-30-minutes.txt` for the host and path.

## 7. Found while writing (for the editor; not in the articles)

1. **English texts outside the tables.** `showError("Sync failed: …")` (`AppModel.swift:606`), “Stop all profiles before
   syncing.” (`:568, :578`), “Could not remember the sync folder: …” (`:539`), “Could not save history: …”
   (`ProfileLibrary.swift:74, 91`), “WebKit did not release the data store of profile …” (`WebDataStoreVault.swift:50`) and
   every `CoreError` description (“Wrong master password”, “Authentication failed …”) reach the Russian UI in English.
   `scripts/check_localization.py` only inspects UI constructors (`:14-18`, `UI_TEXT` at `:35`), not `showError("…")`.
   The UI is Russian unless `PRIVACYBROWSER_LANG=en` (`Localization.swift:22-28`), so most users will meet these.
2. **Settings is not in the ⋯ menu.** README.md:316 and docs/UPDATES.md:336 say “⋯ → Settings…”; the Profiles window's
   ⋯ menu has no such item (`ProfileListView.swift:546-566`: “Settings is ⌘, in the app's menu”);
   `profiles.menu.settings` (1203) is unused.
3. **Conflict wording.** `sync.status.conflicts` says “remote kept, local copy saved”, but for settings the newer edit
   wins on either side (docs/SYNC_FORMAT.md:152-158). The article follows the rule, not the status text.
4. **Released build and processes.** `scripts/release.sh:19, 37` releases `SANDBOX=1` by default: every profile then
   runs in Lumen's windows, with no own process, no Safari window and no system log in the ZIP
   (`settings.behavior.ownProcesses.sandboxed`, `Diagnostics.swift:165-170`). The brief describes each profile as its own
   process. The article covers both and points to Settings → About → Build.
5. **Launch errors in a profile's own process are mostly silent.** An invalid proxy makes the child exit with status 3
   before its window (`ProfileSessionHost.swift:56-69` → `ProfileNetworkGuard.swift:101` →
   `ProxyConfigurationFactory.swift:33`), which the manager reports as “ended unexpectedly” (`ProfileManager.swift:469-471`),
   not as `launch.error.proxyInvalid`. A `LaunchError` thrown inside the child (e.g. a proxy wanting credentials) is
   only logged privately and the process quits with status 0 (`ProfileSessionHost.swift:201-214`) — no message unless the
   manager's own launch probe reported first (it requires the profile to be still running, `ProfileManager.swift:501-503`).
   The article lists the alerts as texts Lumen can show, without saying in which build.
6. **A missing `index.bin` erases every profile.** It opens as an empty index (`ProfileRepository.swift:541`), and
   `didUnlock` then runs `removeOrphanedDirectories` (`AppModel.swift:200`; `ProfileRepository.swift:195-205`), deleting
   every `profiles/<uuid>` folder as orphaned. Worth a guard before release.
7. **No way out after a damaged `index.bin`.** With the right password the alert says “Authentication failed …”, and
   `unlockFailed` stays false (`AppModel.swift:133-134`), so the lock screen shows no “Forgot password…”
   (`VaultViews.swift:135-151`) unless a wrong password is tried first.
8. `Resources/Info.plist:30-31` still declares macOS 14.0 (the site says macOS 26); not mentioned in the article.
