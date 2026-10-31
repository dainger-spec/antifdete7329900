# docs-cookies — facts, evidence and verification

Article: «Импорт и экспорт cookies» / "Importing and exporting cookies" (`docs-cookies.ru.md`, `docs-cookies.en.md`).
Product code: `/home/user/product-src` at 194828b (branch claude/secret-partner-setup-e505tc). All paths below are
relative to it; `L.strings:NN` = line NN of `Resources/ru.lproj/Localizable.strings` and of
`Resources/en.lproj/Localizable.strings` (the two files have the same keys on the same lines).

Counts (words, markdown stripped): ru 740, en 857. `unv` markers: **0** (every statement below has code, test or
measurement evidence; see "Not stated / left out" for what was deliberately not claimed).

---

## 1. Verification of the old draft (the `article.body` of `copy/source/{ru,en}/docs.mjs`, saved as `old-article.*.txt`)

| # | Draft statement | Verdict | Evidence / what changed |
|---|---|---|---|
| 1 | Reads cookie exports in JSON and Netscape `cookies.txt` | **kept** | `Sources/BrowserCore/Cookies/CookieImport.swift:135-137` (doc of `CookieImporter`), `:175-198` (only `.json` / `.netscape`); `Sources/PrivacyBrowser/UI/CookieImportView.swift:5`; `cookies.explanation` L.strings:54 |
| 2 | JSON — EditThisCookie, Cookie-Editor | **kept** | `CookieImport.swift:136`; `Tests/BrowserCoreTests/CookieImportTests.swift:76-96` |
| 3 | JSON — Puppeteer and Chrome DevTools, Playwright, Selenium | **kept**, worded "Puppeteer and the DevTools protocol, Playwright (its `storageState` too), Selenium" | `CookieImport.swift:136-137`; `CookieFileReaders.swift:124-126` (`storageState`, DevTools `cookies`); tests `CookieImportTests.swift:98-122` |
| 4 | JSON — "базы cookies Chrome и Firefox" / "Chrome and Firefox cookie databases" | **corrected** | The database *file* (SQLite) is refused: `CookieImport.swift:226` → "SQLite database (a browser's cookie database: export it with an extension)", test `CookieImportTests.swift:305-306`. What is read is *rows of those databases exported to JSON* (`host_key`, `expires_utc`, `is_secure`…): `CookieImport.swift:137` ("exports of Chrome's and Firefox's cookie databases"), `CookieFileReaders.swift:341, 361-366, 385-386`, test `:124-144`. Now: «строки баз cookies Chrome и Firefox, выгруженные в JSON» |
| 5 | Netscape — curl, yt-dlp, "cookies.txt" extensions | **kept** (+ wget) | `CookieImport.swift:135`; `CookieFileReaders.swift:3-7` |
| 6 | File up to 32 MB | **kept** | `CookieImport.swift:146-147` (`maximumFileSize = 32 * 1024 * 1024`), `:157-161` (refused before reading), `:169`; `cookies.reason.fileTooLarge` L.strings:67 «не больше 32 МБ» / "at most 32 MB"; test `CookieImportTests.swift:235-236`. Note: the limit is 32 MiB (33 554 432 bytes); the UI calls it МБ/MB |
| 7 | ⋯ menu → **Импорт cookies…** | **kept** (+ the row's right-click menu) | `Sources/PrivacyBrowser/UI/ProfileListView.swift:1007-1019` (⋯ = SF Symbol `ellipsis`, disabled while starting/encrypting: `:1018`), `:1024-1035` (menu items), `:914` (same items as the row's context menu); `profiles.row.importCookies` L.strings:447 |
| 8 | **Выбрать файл…**; checked before importing: how many can come across, which cannot, with line and reason | **kept** | `CookieImportView.swift:5-9, 28, 36-41, 72-105`; `cookies.chooseFile` L.strings:47; `cookies.empty` :52 |
| 9 | "Нажмите **Импортировать cookies** — на кнопке будет их число" / "**Import Cookies** — the button shows how many" | **corrected (label)** | The button text is `cookies.import` L.strings:58: ru «Импортировать cookies: %ld», en "Import %ld Cookies" → written **Импортировать cookies: N** / **Import N Cookies**. It is shown only when at least one cookie can be imported: `CookieImportView.swift:52-57` |
| 10 | Note: a damaged file does not stop the import; a broken entry costs only itself | **kept** | `CookieImport.swift:139-144`; `CookieFileReaders.swift:6` (Netscape line by line), `:129-131, 223-286` (JSON recovery); tests `CookieImportTests.swift:64-72, 161-208` |
| 11 | A running profile gets the cookies at once | **kept** | `Sources/PrivacyBrowser/Browser/ProfileManager.swift:1012-1030` (own process: `:1014-1025` → `ProfileSessionHost.swift:251-256`); self-test `Sources/PrivacyBrowser/App/SelfTest.swift:4585-4600` (in-process), `:1569-1574` (profile in its own process) |
| 12 | A stopped one at its next launch, before the first page loads; until then encrypted in the vault | **kept** | `ProfileManager.swift:1031-1033` (queue), `:318-320` + `:1143-1161` (applied before the first page, then the queue file removed); `Sources/BrowserCore/Profiles/ProfileRepository.swift:62-63, 264-286` (AEAD, key derived from the profile key, AAD `cookie-import:v1:<uuid>`); `docs/ARCHITECTURE.md:95, 134, 194-199`; test `CookieImportTests.swift:313-330` (no value or domain readable on disk); self-test `SelfTest.swift:4553-4583` |
| 13 | Session cookies (no expiry) last until the profile stops, "as in Safari" | **kept**, made precise: the stop deletes them, as quitting Safari ends its browsing session | `ProfileManager.swift:789-798` (comment: "as quitting Safari does"), `:817-822`; `docs/ISOLATION_AND_LIMITATIONS.md:1272-1276`; self-test `SelfTest.swift:4626-4630` (present at CI #388's commit ce64ca1) and `:4634-4665` (added after ce64ca1) |
| 14 | The report lists every entry it skipped | **kept** | `CookieImportView.swift:86-97` (all `problems`, the replaced ones greyed as notices `:161-165`) |
| 15 | "Срок действия истёк — Ничего: такой cookie сайт уже не примет" | **corrected** | The reason text is `cookies.reason.expired` L.strings:66 «Истёк %@» / "Expired on %@". The code refuses it as a browser would (`CookieImport.swift:416-418`); "the site would not take it" is not what the code says → advice now «нужен свежий экспорт» / "export the cookies again" |
| 16 | Encrypted value from Chrome's database — only Chrome can read it, export with an extension | **kept** (exact string) | `cookies.reason.encryptedValue` L.strings:65; `CookieFileReaders.swift:344-346`; test `CookieImportTests.swift:275-276` |
| 17 | "Недопустимый домен — общедоступный суффикс вроде co.uk или пустой" | **corrected** | Three separate reasons: `missingDomain` «Нет домена» (L.strings:74), `invalidDomain` «Недопустимый домен «%@»» (:69 — bad characters, non-ASCII/IDN, bad labels), `publicSuffixDomain` «Для всего «%@» — публичного суффикса: браузеры такие cookies не принимают» (:78). `CookieImport.swift:390-405`; tests `CookieImportTests.swift:254-257` |
| 18 | `__Host-` rules: Secure, host-only, path `/` | **kept** (+ `__Secure-` must be Secure) | `cookies.reason.hostPrefix` L.strings:68, `cookies.reason.securePrefix` :80; `CookieImport.swift:423-426`; tests `:259-260` |
| 19 | Damaged bytes — the entry is broken, the others are imported | **kept** | `cookies.reason.damagedText` L.strings:64; `CookieImport.swift:361`; test `:64-72` |
| 20 | Export: **⋯ → Экспорт cookies…** | **kept** | `ProfileListView.swift:1036`; `profiles.row.exportCookies` L.strings:1035 |
| 21 | "Все cookies профиля, включая сеансовые" go into the file | **corrected (qualified)** | Partitioned (CHIPS) cookies are left out (`Sources/PrivacyBrowser/Browser/CookieStoreSync.swift:30-33`); `cookies.txt` leaves out a cookie with a tab/CR/LF in a field and has no SameSite (`CookieExport.swift:26-27, 45-47`; tests `CookieExportTests.swift:26-37, 67-74`); a stopped profile has no session cookies left (self-test `SelfTest.swift:4620-4625`) |
| 22 | Three formats: cookies.txt, JSON for EditThisCookie/Cookie-Editor, JSON for Playwright/Puppeteer | **kept**, with the exact picker labels | `CookieExport.swift:7-15, 20-24`; `ProfileTransferViews.swift:244-258`; L.strings:1039-1041 |
| 23 | Warning: «Файл экспорта не зашифрован. …» / "The export file is not encrypted. Whoever has it signs in…" | **corrected to the app's exact text** | `cookieExport.warning` L.strings:1042: ru «Файл не зашифрован. Тот, у кого он окажется, войдёт как этот профиль везде, где cookies — это вход.»; en "The file is not encrypted. Anyone who has it is signed in as this profile wherever its cookies are a sign-in."; shown at `ProfileTransferViews.swift:260` |
| — | Meta "Обновлено 29 октября 2026", "Читать около пяти минут", prev/next | not carried | the new file format has no meta; dates/reading time are not facts of the code |

---

## 2. Every statement of the new article → evidence

### formats — Какие файлы подходят / Which files work
| Statement | Evidence |
|---|---|
| JSON and Netscape `cookies.txt` | row 1 above |
| Table rows (EditThisCookie/Cookie-Editor; Puppeteer + DevTools protocol, Playwright incl. `storageState`, Selenium; rows of Chrome/Firefox databases exported to JSON; JSON Lines; curl, wget, yt-dlp, cookie extensions) | `CookieImport.swift:135-137`; `CookieFileReaders.swift:3-7, 124-131, 157-167` (JSON Lines); tests `CookieImportTests.swift:16-62, 76-157, 279-297` |
| The content decides, not the file name; `[`/`{` → JSON; else `cookies.txt` lines; then JSON inside the text | `CookieImport.swift:175-198` (`trimmed.first == "[" \|\| "{"` → JSON; Netscape; "Neither: maybe JSON after some junk"); the file panel accepts any file (`CookieImportView.swift:62`: `.json, .plainText, .text, .data`); test `CookieImportTests.swift:191-197` |
| UTF-8 and UTF-16 with or without BOM, UTF-32 with BOM | `CookieImport.swift:242-266`; tests `CookieImportTests.swift:212-227, 298-303` |
| Up to 32 MB | row 6 above |
| A browser's database file (SQLite), Safari binary cookies, an archive, PDF or a web page is not read; the report says what the file is | `CookieImport.swift:170, 222-238` (signatures: SQLite, `cook`, mozLz40, ZIP, gzip, PDF, Python pickle, HTML) → `cookies.reason.unsupportedFile` L.strings:85 «Это не экспорт cookies, а файл другого вида: %@»; tests `:305-308` |

### steps — Как импортировать / How to import
| Statement | Evidence |
|---|---|
| ⋯ menu or right-click → **Импорт cookies…** | row 7 |
| **Выбрать файл…** reads and checks without changing the profile | `CookieImportView.swift:127-137` (only reads; import is a separate action `:139-149`); `AppModel.swift:448-454` |
| **Импортировать cookies: N**, N = how many can come across; no button when there is nothing | `CookieImportView.swift:52-57` (`report.cookies.count`) |
| The profile editor: **Данные** tab, **Cookies** field — paste an export or drop a file; imported on save | `Sources/PrivacyBrowser/UI/ProfileEditorForm.swift:712-716, 846-909` (paste field, drop, Choose File); `ProfileEditorView.swift:410-421, 559-571`; `editor.cookies.placeholder` L.strings:171; `editor.cookies.note.new`/`.existing` :173-174 |
| Note: damaged file, readable entries imported, broken line/entry costs itself, non-text bytes cost only their cookie | row 10; `CookieImport.swift:122-123, 361` |

### report — Что покажет проверка / What the check shows
| Statement | Evidence |
|---|---|
| «Можно импортировать N из M записей» | `cookies.summary` L.strings:87; `CookieImportView.swift:74` |
| «Формат: JSON, прочитан как UTF-8» | `cookies.formatLine` L.strings:57 + `cookies.format.json` :55; encoding names from `CookieImport.swift:120, 250-265`; `CookieImportView.swift:77-81` |
| «Не импортировано: N»; each entry: «Строка N» / «Запись N (строка M)», name, reason | `cookies.problemsTitle` :61, `cookies.where.line` :93, `cookies.where.entry` :91; `CookieImportView.swift:86-97, 153-159` |
| Checked as a browser checks a cookie | `CookieImport.swift:142-144, 356-430` |
| Reason table (exact strings, abbreviated with "…" in the article) | see section 4 (keys) and `CookieImportView.swift:167-196`; checks in `CookieImport.swift:361-426` |
| Cyrillic domain (`пример.рф`) refused, not converted to `xn--…` | `CookieImport.swift:391` (non-ASCII → `invalidDomain`); test `CookieImportTests.swift:256`; `docs/ISOLATION_AND_LIMITATIONS.md:1279` ("Domains in Unicode (IDN) are refused rather than converted") |
| Windows-1251 value shows as damaged bytes | `CookieImport.swift:268-283` (invalid UTF-8 → U+FFFD, counted) + `:361`; `ISOLATION_AND_LIMITATIONS.md:1279-1280` |
| Eight fields = a tab in the value | `CookieFileReaders.swift:40-48`; test `CookieImportTests.swift:284-287` (`wrongFieldCount(8)`) |
| Same cookie (name, domain, path) twice → the later is imported, the earlier listed greyed «Заменён тем же cookie дальше в файле», not an error | `CookieImport.swift:207-217`; `CookieImport.swift:129-132` (`failures` exclude it); `CookieImportView.swift:95, 161-165` (`Color.secondary`); `cookies.reason.replaced` L.strings:79; test `:31, 56-61` |

### when — Запущенный и остановленный профиль / Running and stopped profiles
| Statement | Evidence |
|---|---|
| Running: at once; store read back; cookies WebKit did not keep listed by name and domain | row 11; `Sources/PrivacyBrowser/Browser/CookieStoreImport.swift:7-10, 20-45`; `CookieImportView.swift:110-117` (`cookies.done.refused` L.strings:51, up to ten shown as `name (domain)`) |
| An import replaces the profile's same cookie, even an HttpOnly one | `CookieStoreImport.swift:10-12, 29-33` |
| Stopped: next launch, before the first page; encrypted with (a key derived from) the profile key; a later import joins the waiting ones | row 12; `ProfileRepository.swift:272-286` (added, same identity replaced); message `cookies.done.queued` L.strings:50 counts all waiting |
| Starting/being encrypted: «Профиль запускается или шифруется; повторите через несколько секунд.» | `ProfileManager.swift:1005-1008, 1015, 1031-1032`; `cookies.error.busy` L.strings:53 |
| Session cookies (no expiry) last until the stop, which deletes them, as quitting Safari | row 13 |
| Ephemeral profile: every imported cookie lasts only until it stops | `ISOLATION_AND_LIMITATIONS.md:116` (`nonPersistent()` store), `:1276-1277`; `docs/ARCHITECTURE.md:191-192` |

### export — Экспорт cookies / Exporting cookies
| Statement | Evidence |
|---|---|
| ⋯ → **Экспорт cookies…** | row 20 |
| **Формат** with the three labels; cookies.txt is the default | `ProfileTransferViews.swift:239` (`format = .netscape`), `:244-258`; L.strings:1038-1041 |
| Playwright JSON = the cookies array of a `storageState` (Puppeteer's `page.setCookie` takes it too) | `CookieExport.swift:13-15, 79-92` |
| **Экспортировать…** → save panel | `ProfileTransferViews.swift:282, 293-312` (file name "<profile name> cookies.txt/.json" `:295`) |
| Every cookie, session included, except partitioned (CHIPS) | `ProfileManager.swift:1040-1074`; `CookieStoreSync.swift:16-19, 30-43`; `cookieExport.explanation` L.strings:1037; self-test `SelfTest.swift:4603-4612` |
| `cookies.txt`: no SameSite; a cookie with a tab or line break in a field is left out | `CookieExport.swift:26-27, 45-61`; tests `CookieExportTests.swift:26-37` ("the format has no SameSite"), `:67-74` |
| «Сохранено cookies: N» gives the count in the file | `cookieExport.done` L.strings:1045; `ProfileTransferViews.swift:306` (`CookieExport.count`) |
| The file can be imported into another profile | `CookieExport.swift:3-5` ("a file exported here imports here unchanged"); tests `CookieExportTests.swift:26-65`; self-test `SelfTest.swift:4606-4611` |
| A stopped profile is started without a window, then stopped and encrypted again; it has no session cookies | `ProfileManager.swift:1043-1057`; `cookieExport.stopped` L.strings:1043; self-test `SelfTest.swift:4620-4625` (`!fromStopped.contains { $0.name == "session" }`) |
| Warning text (exact) | row 23 |

### storage — Где хранятся cookies / Where cookies are kept
| Statement | Evidence |
|---|---|
| Stopped profile: website data incl. the cookie store in an encrypted archive, under a key the master password opens | `docs/ARCHITECTURE.md:73-101` (key hierarchy: master password → KEK → VMK → profile key → HKDF "webdata-archive"), `:144, 156-169` (`webdata.pbsa`), `:171-189`; `ISOLATION_AND_LIMITATIONS.md:595, 608` |
| While it runs, WebKit keeps cookies in its own files on disk, unencrypted | `ISOLATION_AND_LIMITATIONS.md:608-615`; `ARCHITECTURE.md:146-147` |
| At a stop {{name}} asks WebKit to write the last cookies, then encrypts the data and deletes the plain files | `ProfileManager.swift:789-798, 805-814`; `CookieStoreImport.swift:41-65` (flush through WebKit's `_flushCookiesToDiskWithCompletionHandler:`, **used only where this WebKit has it** — `canFlush`, logged by the self-test `SelfTest.swift:4602`); `ARCHITECTURE.md:179-189`; outcome measured: persistent cookies survive stop + launch (self-test `:4626-4630`), quit with ten running → every cookie there at the next launch, 10/10 (`docs/SCALE.md:125-127`) |
| Imported cookies for a stopped profile wait in a separate encrypted file, deleted once the launch moved them in | `ProfileRepository.swift:62-63, 264-297`; `ProfileManager.swift:1154-1155`; `ARCHITECTURE.md:134`; self-test `SelfTest.swift:4578-4582` ("the queue is gone") |
| The export file is not encrypted | `CookieExport.swift:17-18`; `ProfileTransferViews.swift:231-233, 305` |

---

## 3. Numbers in the visible text → source

| Number (ru / en) | Meaning | Source | In `copy/facts.mjs`? |
|---|---|---|---|
| 32 (МБ / MB) | cookie file size limit | `CookieImport.swift:146-147`; `cookies.reason.fileTooLarge` L.strings:67 | **yes** ('32') |
| 4096 (байт / bytes) | name + value limit of one cookie | `CookieImport.swift:148-149, 375`; `cookies.reason.tooLarge` L.strings:81; test `CookieImportTests.swift:253` | **no — add** |
| 7 (in «Полей: N вместо 7» / "N fields instead of 7") | fields of a `cookies.txt` line | `cookies.reason.wrongFieldCount` L.strings:86; `CookieFileReaders.swift:3-4, 41` | value '7' exists with another meaning — **add this meaning** |
| "восемь" / "eight" (words) | eight fields = a tab in the value | `CookieFileReaders.swift:40`; test `CookieImportTests.swift:284-287` | written as a word |
| UTF-8, UTF-16, UTF-32, Windows-1251 | encoding names | technical identifiers; `CookieImport.swift:120, 242-266`; `ISOLATION_AND_LIMITATIONS.md:1237-1239, 1279-1280` | technical identifiers (not counted) — if the checker counts them, add '8', '16', '32', '1251' as identifiers |
| 1., 2., 3. | ordered-list markers | markdown | — |
| N, M | placeholders for the app's own counts (`%ld`) | `cookies.import`, `cookies.summary`, `cookies.problemsTitle`, `cookies.where.*`, `cookieExport.done` | no digits |

---

## 4. UI labels and quoted app texts → Localizable.strings keys (line = same in ru and en)

| Key (line) | ru (as written in the article) | en |
|---|---|---|
| `profiles.row.importCookies` (447) | **Импорт cookies…** | **Import Cookies…** |
| `profiles.row.exportCookies` (1035) | **Экспорт cookies…** | **Export Cookies…** |
| `cookies.chooseFile` (47) | **Выбрать файл…** | **Choose File…** |
| `cookies.import` (58) | **Импортировать cookies: N** («Импортировать cookies: %ld») | **Import N Cookies** ("Import %ld Cookies") |
| `editor.topic.data` (191) | **Данные** | **Data** |
| `editor.cookies` (170) | **Cookies** | **Cookies** |
| `cookieExport.format` (1038) | **Формат** | **Format** |
| `cookieExport.format.netscape` (1039) | **cookies.txt (Netscape: curl, yt-dlp, расширения)** | **cookies.txt (Netscape: curl, yt-dlp, extensions)** |
| `cookieExport.format.extension` (1040) | **JSON (EditThisCookie, Cookie-Editor)** | same |
| `cookieExport.format.playwright` (1041) | **JSON (Playwright, Puppeteer)** | same |
| `cookieExport.action` (1044) | **Экспортировать…** | **Export…** |
| `cookieExport.warning` (1042) | «Файл не зашифрован. Тот, у кого он окажется, войдёт как этот профиль везде, где cookies — это вход.» | "The file is not encrypted. Anyone who has it is signed in as this profile wherever its cookies are a sign-in." |
| `cookieExport.done` (1045) | «Сохранено cookies: N» (full: «Сохранено cookies: %1$ld — %2$@») | "N cookies saved to …" ("%1$ld cookies saved to %2$@") |
| `cookies.summary` (87) | «Можно импортировать N из M записей» | "N of M entries can be imported" |
| `cookies.formatLine` (57), `cookies.format.json` (55) | «Формат: JSON, прочитан как UTF-8» | "Format: JSON, read as UTF-8" |
| `cookies.problemsTitle` (61) | «Не импортировано: N» | "Not imported: N" |
| `cookies.where.line` (93), `cookies.where.entry` (91) | «Строка N», «Запись N (строка M)» | "Line N", "Entry N (line M)" |
| `cookies.reason.expired` (66) | Истёк … | Expired on … |
| `cookies.reason.encryptedValue` (65) | Зашифрованное значение из базы Chrome… | Encrypted value from Chrome's database… |
| `cookies.reason.partitioned` (77) | Разделённый (CHIPS) cookie… | A partitioned (CHIPS) cookie… |
| `cookies.reason.missingDomain` (74), `cookies.reason.invalidDomain` (69) | Нет домена; Недопустимый домен «…» | No domain; Invalid domain “…” |
| `cookies.reason.publicSuffix` (78) | Для всего «…» — публичного суффикса… | For all of “…”, a public suffix… |
| `cookies.reason.hostPrefix` (68), `cookies.reason.securePrefix` (80) | Cookie «__Host-» должен быть Secure, только для хоста, с путём / ; cookie «__Secure-» должен быть Secure | A “__Host-” cookie must be Secure, host-only, with path / ; a “__Secure-” cookie must be Secure |
| `cookies.reason.tooLarge` (81) | Имя и значение вместе длиннее 4096 байт | Name and value together are longer than 4096 bytes |
| `cookies.reason.damagedText` (64) | Повреждённые байты (не текст) в этом cookie | Damaged bytes (not valid text) in this cookie |
| `cookies.reason.wrongFieldCount` (86) | Полей: N вместо 7 (через табуляцию) | N fields instead of 7 tab-separated ones |
| `cookies.reason.cutOff` (62), `cookies.reason.unreadableEntry` (82) | Обрезано…; Некорректный JSON | Cut off…; Not valid JSON |
| `cookies.reason.replaced` (79) | «Заменён тем же cookie дальше в файле» | "Replaced by the same cookie later in the file" |
| `cookies.error.busy` (53) | «Профиль запускается или шифруется; повторите через несколько секунд.» | "The profile is starting or being encrypted; try again in a moment." |
| (symbol) | **⋯** — SF Symbol `ellipsis` (`ProfileListView.swift:1010`); its accessibility label `profiles.row.moreFor` (451) «Ещё для «%@»» / "More for %@" | |

Reasons not in the article's table but in the app (full list, `CookieImportView.swift:167-196`): `cookies.reason.unrecognizedFormat` (84),
`fileTooLarge` (67), `unreadableFile` (83), `unsupportedFile` (85), `damagedJSON` (63), `notACookie` (76), `missingName` (75),
`invalidName` (71), `invalidValue` (73), `invalidPath` (72), `invalidExpiry` (70).

Every key above exists in both languages. **One language only:** the *kind* inserted into `cookies.reason.unsupportedFile`
comes from BrowserCore in English and is not localized (`CookieImport.swift:226-236`: "SQLite database (a browser's cookie
database: export it with an extension)", "Safari binary cookies", "ZIP archive", "web page (HTML)"…), so the Russian UI shows
«Это не экспорт cookies, а файл другого вида: SQLite database (…)». The article therefore does not quote the kinds. The header
line of an exported `cookies.txt` ("# Exported by Lumen. Every value here is in plaintext.", `CookieExport.swift:50`) is English
only too (file content, not UI).

---

## 5. unv markers

None. Points that were checked and deliberately **not** stated (so no marker was needed):
- The flush before sealing relies on WebKit's private `_flushCookiesToDiskWithCompletionHandler:`, used only when present
  (`CookieStoreImport.swift:47-65`). The article says {{name}} *asks* WebKit to write the last cookies; the outcome (cookies kept
  across a stop) is measured (self-test, SCALE.md quit 10/10).
- Cookie **sync** between Macs (editor toggle `editor.sync.cookies` L.strings:210; `CookieJar.swift`, `ISOLATION_AND_LIMITATIONS.md:1284-1307`):
  left out — `docs/ROADMAP.md:141-165` says "Сервера нет" and lists profile sync as not done.
- The **Automation API** cookie endpoints (`AutomationServer.swift:248-275`, `docs/AUTOMATION_API.md:36-37`, menu `profiles.menu.automation`):
  left out — `docs/ROADMAP.md` Этап 5 lists "API для автоматизации" as after-launch.

---

## 6. Findings worth the owner's attention

1. **Draft errors fixed**: the import button label (row 9), "Chrome/Firefox databases" (row 4 — the SQLite file is refused), the
   merged domain reasons (row 17), "all cookies" without the CHIPS / `cookies.txt` exceptions (row 21), the warning text not the
   app's (row 23).
2. **English inside the Russian UI**: `unsupportedFile` kinds (section 4).
3. **Export file permissions**: `CookieExportView` writes with `Data.write(options: .atomic)` (`ProfileTransferViews.swift:305`),
   i.e. default permissions, while the proxy-list export, also plaintext secrets, is written owner-only (`SecureFile.writeOwnerOnly`,
   `docs/ARCHITECTURE.md:324`). Not stated in the article.
4. **Busy menu**: the ⋯ menu is disabled while a profile starts or is encrypted (`ProfileListView.swift:1018`) but the row's
   right-click menu is not (`:914`), which is how a user reaches the «Профиль запускается или шифруется…» answer.
5. **CI evidence age**: the latest green run registered in `facts.mjs` is CI #388 at ce64ca1 (29 Oct); 194828b is 140 commits
   later. The import/export self-test checks cited above (`SelfTest.swift:4546-4630` and `:1569-1577` at 194828b) already
   existed at ce64ca1 (`git show ce64ca1:Sources/PrivacyBrowser/App/SelfTest.swift`, lines 1057, 2309-2380), so they ran green
   in CI #388 («SELFTEST PASSED: 274 passed, 0 failed»). Only `sessionCookieAfterStop` (`SelfTest.swift:4634-4665`) is newer
   (its comment cites CI run 436, not registered in `copy/facts.mjs`); the session-cookie claim also rests on the older check
   at `:4626-4630` (in #388) and on the code (`ProfileManager.swift:789-798`).
