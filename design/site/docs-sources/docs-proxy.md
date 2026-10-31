# docs-proxy — facts, evidence, open points

Article files: `docs-proxy.ru.md` (882 words incl. title/lead/toc; body 835), `docs-proxy.en.md` (895; body 850). Same six anchors in both:
`types`, `where`, `list`, `location`, `traffic`, `failure`. Same claims in both; English is an equivalent, not a word-for-word copy.

Sources (read-only): product code `/home/user/product-src` (detached checkout, `194828b`), paths below are relative to it;
measurements `/home/user/site-prototype/design/site/copy/facts.mjs`. "ru:N / en:N" = line in
`Resources/{ru,en}.lproj/Localizable.strings` (the two files have the same keys on the same lines).

## 1. Claims → evidence

### Proxy types {#types}

| Claim | Evidence |
|---|---|
| SOCKS5 and HTTP, with or without user name and password | `Sources/BrowserCore/Profiles/ProfileConfiguration.swift:457-498` (`ProxySettings.Kind` = `httpConnect`, `socks5`; credentials optional, both-or-neither at 496); auth sent: `Sources/PrivacyBrowser/Browser/ProxyConfigurationFactory.swift:47-50` (`applyCredential`). Measured: self-test "HTTP CONNECT proxy", "SOCKS5 proxy", "Several SOCKS5 profiles at once" (one with auth), 407 answered with the profile's credentials — `docs/ISOLATION_AND_LIMITATIONS.md:24-25,45`; `Sources/PrivacyBrowser/App/SelfTest.swift:705` |
| HTTPS = an HTTP proxy reached over TLS | `ProfileConfiguration.swift:469-470` (`tlsToProxy`, "HTTPS proxy. httpConnect only"), 492-493 (SOCKS5 + TLS refused); `ProxyConfigurationFactory.swift:42-43` (`tlsOptions`); `Sources/BrowserCore/Profiles/ProxyHostField.swift:100` (`https://` → TLS) |

### Setting a proxy {#where}

| Claim | Evidence |
|---|---|
| Editor: ⋯ → Edit…, part Connection, field Connection with No Proxy / From the List / New | `Sources/PrivacyBrowser/UI/ProfileEditorForm.swift:12-25` (topics), 391-406 (picker with the three modes); keys in §4 |
| One line, as the provider gave it: `host:port:user:pass`, `user:pass@host:port`, `socks5://user:pass@host:port`, `host:port` | `ProxyHostField.swift:5-9, 89-157` (parser, `host:port:user:pass` at 143-149); `Sources/BrowserCore/Proxies/ProxyListImport.swift:121-144` (`readField`, same parser as Import); UI hint `proxyLine.hint` ru:1054 / en:1054 |
| The scheme sets the type: `socks5://` (also `socks5h://`, `socks://`), `http://`, `https://` | `ProxyHostField.swift:96-102` |
| Without a scheme, Check or Save finds the type; no type found → not saved | `editor.proxy.new.note` ru:1066 / en:1066 ("Save runs one if Check has not"); `editor.proxy.error.kindNotFound` ru:1077; `Sources/PrivacyBrowser/UI/ProfileEditorView.swift:256-276` (`makeProxy` throws for `kindUnknown`); ISOLATION 805-820 ("Save checks such a line first and refuses it when no handshake answers") |
| Bypass domains (comma-separated) take domains out of the proxy | Field: `ProfileEditorForm.swift:412-416`; parsed `ProfileEditorView.swift:273-274`; applied `ProxyConfigurationFactory.swift:52` (`excludedDomains`); meaning: `ProfileConfiguration.swift:471` "Domains that bypass the proxy. Empty by default". **unv** — see §3 |
| Changes apply at the next launch | `README.md:217-218` ("Changes apply at the next launch"); proxy given to the data store at launch: ISOLATION 821-829 |

### List and checks {#list}

| Claim | Evidence |
|---|---|
| The list is the sidebar item Proxies of the Profiles window | `Sources/PrivacyBrowser/UI/ProfileListView.swift:777-782` (`proxiesItem`, `L("proxies.title")`), comment 546 "the proxies are in the sidebar" |
| Encrypted, this Mac only (not synced) | `Sources/BrowserCore/Proxies/ProxyList.swift:171-176` (`proxies.bin`, AES-GCM, "This Mac's only, never synced"); `proxies.explanation` ru:598 |
| Each profile keeps its own copy | `ProxyList.swift:177-184`; `proxies.delete.message` ru:617 |
| Add: one proxy in the same one-line field | `Sources/PrivacyBrowser/UI/ProxyListView.swift:171`; `proxies.add.explanation` ru:1083 / en:1083 |
| Import: pasted or From File…, one per line; text after ` #` is the name | `ProxyListImport.swift:3-20, 89-119, 241-255` (`splitLabel`); `Sources/PrivacyBrowser/UI/ProxyImportView.swift:31-60`; `proxies.import.explanation` ru:632 |
| Unreadable lines listed with number and reason; a repeat (same host, port, user name) skipped | `ProxyListImport.swift:45-68, 104-116`; identity = host+port+user name: `ProxyList.swift:206-212`; `proxies.import.problemsTitle` ru:637, `proxies.import.line` ru:638 |
| Lines without a scheme: by default the type comes from the first check; until then given to no profile | Default picker value `Found by Check`: `ProxyImportView.swift:41-44` (`Kind?.none` first); `ProxyList.swift:108-110, 167-168` (`kindKnown`, `usableProxy`), 264-285 (`record`: type found); `Sources/BrowserCore/Proxies/ProxyAssignment.swift:65-67`; `proxies.import.kind.help` ru:532 |
| Assign to Profiles…: one proxy for all, several in turn (round-robin) | `ProxyList.swift:377-385` (`rotation`); `Sources/PrivacyBrowser/UI/ProxyAssignView.swift:4-9, 54`; `proxies.assign.explanation` ru:657 |
| A running profile keeps its proxy until it stops (no change of address on the fly) | `proxies.assign.note` ru:669 ("…при следующем запуске"); ISOLATION 826-828 ("A running profile keeps the proxy it was launched with until it stops"); `rotation(of:over:)` is used only by the assign sheet (`ProxyAssignView.swift:54`) |
| ⋯ → Edit… reaches the profiles using the proxy | `ProfileRepository.follow` — `ProxyAssignment.swift:86-113` (only profiles whose copy is the entry *as it was*; a copy changed in the profile's own editor is kept); `proxies.edit.explanation` ru:497 |
| ⋯ → Export… writes user names and passwords in plaintext | `ProxyList.swift:350-362`; `proxies.export.warning` ru:528; ISOLATION 802-804 (0600 file) |
| Check All / Check Selected check each proxy through itself, steps Address, Connection, Handshake (SOCKS5 and HTTP), Login, Tunnel, Through the proxy | `Sources/BrowserCore/Proxies/ProxyProbe.swift:3-23, 62-146` (both handshakes at once 126-129); `Sources/PrivacyBrowser/Browser/ProxyChecker.swift:4-68`; button `ProxyListView.swift:233-237`; step labels `proxies.step.*` ru:561-596 |
| Never directly | `ProxyChecker.swift:16-18, 45-51` (settings that cannot be applied are not checked at all); `ProxyGeoLookup.swift:9-11, 82` (proxy configuration with `allowFailover = false`). Measured: self-test "proxy checker: a proxy whose host does not resolve is dead (nothing goes direct)" `SelfTest.swift:2793`; ISOLATION 47 (CI run 394/395; the checker runs inside a packet capture that fails on any packet of the app past loopback) |
| Working proxy shows country, city, exit IP, network, latency = median of three tunnels | `ProxyList.swift:23-43` (stored fields); `ProxyChecker.swift:64-66, 81-90`; latency samples = 3: `ProxyProbe.swift:52`, `ProxyChecker.swift:36`; median `Sources/BrowserCore/Proxies/ProxyDiagnosis.swift:98-103`; shown: `ProxyListView.swift:440-470` (row), `Sources/PrivacyBrowser/UI/ProxyReportView.swift:369-377` (exit line with network); `proxies.step.latency.median` ru:574 |
| The selected proxy: a report with What to do | `ProxyReportView.swift:205-255` (explanation + advice); `proxies.report.advice` ru:541 |
| Checks only on request | `settings.proxies.checks.detail` ru:1157; ISOLATION 777-778 ("only when the user asks … never in the background") |

### Time zone and language {#location}

| Claim | Evidence |
|---|---|
| At launch the profile asks a geolocation service through the proxy: ipinfo.io, then geojs.io, ipwho.is, ipapi.co | `Sources/PrivacyBrowser/Browser/ProxyGeoLookup.swift:28-40` (order), 42-50 (next one asked after 3 s alone, at once when one fails), 81-94 (session with the profile's proxy configuration, no cookies, no cache); runs when `needsProxyLookup`: `ProfileConfiguration.swift:266-268` |
| The service sees the proxy's address, not this Mac's | `ProxyGeoLookup.swift:6-11` ("only through the profile's proxy — never direct"); `ProxyConfigurationFactory.swift:51` |
| Time zone of the exit; language by country (e.g. `de-DE` for Germany) | `ProfileConfiguration.swift:322-329` (`applying`), 142-146 (`webLanguage`); `Sources/BrowserCore/Profiles/ProxyLocation.swift:90-98` (`"DE": "de-DE"`). Measured: ISOLATION 43-44 (self-test: `Accept-Language` `de-DE,de;q=0.9`; time zone from the lookup); LEAK_AUDIT §10 (`docs/LEAK_AUDIT.md:104-111`, CI 382: "a new proxy's first launch: the page is asked for in the proxy's country's language") |
| This is Time zone and language → From the connection, part Location and Language, the default | `ProfileEditorForm.swift:546-566`; default `matchProxyLocation: Bool = true` `ProfileConfiguration.swift:165`; new profiles: `Sources/PrivacyBrowser/App/AppSettings.swift:149` (`?? true`) |
| The answer is awaited up to three seconds, up to a second if the exit is known | `Sources/PrivacyBrowser/Browser/ProfileManager.swift:117-124` (`firstLookupWait = 3`, `rememberedLookupWait = 1`), 273-280. Measured: self-test "Launch speed" ISOLATION 46; `SelfTest.swift:2621`; README 397. Phrased per wait on purpose — see §5, item 8 |
| No service answers → last launch's time zone and language, or this Mac's, and the app says so | `ProfileManager.swift:596-607` (`launch.proxyLocationUnknown.last` / `.mac`), 621-633; `ProfileConfiguration.swift:313-320`; ISOLATION 1137 ("said where the user looks") |
| With "Each profile its own app in the Dock" off, the first profile launched sets the language for the run | ISOLATION 1138 (process-wide language; "a profile in its own process … has its own"); `ProfileManager.swift:298-304, 609-619` (`WebContentLanguage.decide`, `launch.languageFixed` ru:253); setting `settings.behavior.ownProcesses` ru:1144; own process gets its languages at start: `ProfileManager.swift:372-392` |
| Rotating proxies: Warn when the proxy's IP changes | `ProfileEditorForm.swift:421-422`; `ProfileConfiguration.swift:41-46` (default off); message `launch.proxyIPChanged` ru:254; ISOLATION 748-754; measured: `SelfTest.swift:2658-2703`, ISOLATION 48 ("Proxy exit IP") |

### DNS, WebRTC, UDP {#traffic}

| Claim | Evidence |
|---|---|
| The proxy resolves site names (SOCKS5 and HTTP get the name) | Measured: ISOLATION 24 (HTTP CONNECT: an `.invalid` host loads → resolved by the proxy), 25 (SOCKS5 `ATYP=3`); `SelfTest.swift:652`; `docs/TUNNEL.md:14` |
| This Mac looks up only the proxy's own address | `ProxyProbe.swift:14-17` ("The only thing this Mac asks anyone but the proxy is its resolver, for the proxy's own name"); ISOLATION 760. Egress capture fails on a DNS question for a leak-page name: LEAK_AUDIT 7 (`docs/LEAK_AUDIT.md:77-84`) |
| DNS prefetching is blocked | `Sources/BrowserCore/Proxies/ProxiedContentRules.swift:3-7, 35` (ping-type loads blocked); ISOLATION 701 (table row "DNS prefetch"), 37 (self-test); `SelfTest.swift:683`; LEAK_AUDIT §7 |
| WebRTC is off with a proxy, whatever the setting | `ProfileConfiguration.swift:240-251` (`webRTCRouting`: `.off` unless SOCKS5 **and** a tunnel relay); a release has no tunnel: `docs/TUNNEL.md:21-25` ("Not in a release … `scripts/release.sh` builds without the extension"), `scripts/build-app.sh:36` (`NE` default 0), `scripts/release.sh` sets no `NE`; ISOLATION 1100-1110 ("a released app's proxied profiles run with WebRTC off"); editor picker locked: `ProfileEditorForm.swift:384-386, 425-447`. Measured: ISOLATION 35; `SelfTest.swift:648`; LEAK_AUDIT §5 |
| QUIC (HTTP/3) not used with a proxy; pages over HTTP/2 through it | ISOLATION 674-680 (measured on every push by `scripts/leak_check.py`, cloudflare-quic.com); LEAK_AUDIT §4; UI: `settings.newProfiles.quic` / `.detail` ru:1126-1127 |
| A profile in its own process may send no UDP | `Sources/PrivacyBrowser/Browser/ProfileNetworkGuard.swift:117-121` (process refused to start if UDP cannot be closed), 786 (`deny network-outbound (remote udp "*:*")`); LEAK_AUDIT 50-57; `SelfTest.swift:1530` |
| This Mac's addresses (`127.0.0.1`, `localhost`) closed to pages; local-network addresses go through the proxy | `ProxiedContentRules.swift:8-30` (loopback, `localhost`, `::1`, `0.0.0.0`; a page that is itself on this Mac keeps its own loads); `editor.local.proxy` ru:156; ISOLATION 846. Measured: LEAK_AUDIT §2 (CI 382 open → CI 383 closed; 10.255.255.1 through the proxy); `SelfTest.swift:1426` |
| Only two settings lead around the proxy: Bypass domains, Safe Browsing (both inactive by default) | Bypass: see above (empty by default, `ProfileConfiguration.swift:471`). Safe Browsing: `editor.safeBrowsing` ru:136, `editor.privacy.footer` ru:126, `ProfileConfiguration.swift:55-57` ("made by WebKit outside the per-profile proxy, so default is off"); ISOLATION 703. No other profile setting opens a path: WebRTC forced off (above), local requests "not a choice with a proxy" (ISOLATION 846), geolocation is a JS shim (ISOLATION 1136) |
| The app's own sync and update check go out directly | `docs/SYNC_FORMAT.md:14-19`; `docs/UPDATES.md:294-296` |
| In the latest registered CI run none of 2 410 packets went around the proxy | facts.mjs line 28: CI #388 (run 40933992353, ce64ca1) «egress check: 2410 packets captured, 2406 with a process … nothing went around the profile's proxy»; capture described in README 164-166 |

### When the proxy fails {#failure}

| Claim | Evidence |
|---|---|
| While the proxy is down, pages do not load; never a direct fallback | `ProxyConfigurationFactory.swift:10-11, 29-31, 51` (`allowFailover = false`; an unusable proxy throws instead of returning `[]`). Measured: self-test "fail-closed when the proxy is unreachable" / "… host does not resolve" `SelfTest.swift:666, 670`; ISOLATION 26, 34 |
| Unusable address or HTTP 407 without a login → not started, “…The profile was not started, so no site opens directly.” | `ProfileManager.swift:239-243` (`invalidProxy`), 291-296 (`proxyNeedsCredentials`, data sealed again), 126-135 (messages); `launch.error.proxyInvalid` ru:251, `launch.error.proxyNeedsCredentials` ru:252 (ru quotes only the common part «Профиль не запущен…»: the two ru messages differ after it; en has the same sentence in both). 407 seen only by the launch's lookup (`needsProxyLookup`), ISOLATION 708-716. Measured: `SelfTest.swift:612, 723-726`; ISOLATION 42. **unv** for a profile in its own process — §3 |
| Found later → the profile is stopped | `ProfileManager.swift:650-658` (`launch.proxyNeedsCredentialsStopped` ru:255); forwarded from a profile's own process through `manager.onError` (`Sources/PrivacyBrowser/App/ProfileSessionHost.swift:160-164`) |
| At launch the app asks the proxy itself once; if it fails, the Profiles window shows “…” loads no pages, the report, Check Proxy, Show in Proxies | `ProfileManager.swift:212-216, 490-508` (probe beside the launch, never waited for), 543-552 (one tunnel, to the start page's site or the first geolocation service); runs in the manager before the per-process branch (221), so in both modes; `Sources/PrivacyBrowser/App/AppModel+Proxies.swift:49-58` (window to the front); `Sources/PrivacyBrowser/UI/ProxyProblemView.swift:57-104`. Measured (app-process mode): `SelfTest.swift:3092`; ISOLATION 47 |
| Settings → Proxies → A proxy that does not work → Do not start the profile keeps it stopped; default Start the profile, say why | `ProfileManager.swift:199-211`; `AppModel.swift:233`; default `AppSettings.swift:153` (`?? .launchAndExplain`); `Sources/PrivacyBrowser/UI/SettingsView.swift:476-478`; title `proxyProblem.title.notStarted` ru:1200. Measured: `SelfTest.swift:3113` |
| Mid-session: pages stop loading; the app's window shows Page could not be loaded and the reason | `Sources/PrivacyBrowser/Browser/BrowserTab.swift:306-331` ("With a proxy configured and failover disabled, an unreachable proxy surfaces here"), proxy-login variants 352-366 (`errorpage.proxy.noCredentials` / `.rejected` ru:230-231); fail-closed measured as above. **unv** for Safari's own window — §3 |
| The Profiles window says nothing mid-session: the proxy is asked only at launch | `diagnoseProxy` is called only from `launch` (`ProfileManager.swift:215`); no other caller (`grep diagnoseProxy`) |
| State table (labels and advice) | States `ProxyReportView.swift:97-121` → `proxies.state.*`; advice paraphrased from `proxies.advice.*` (keys in §4); verdict meanings `ProxyDiagnosis.swift:14-53`; substitute DNS ranges `Sources/BrowserCore/Proxies/SubstituteDNS.swift:10-29` |
| Recovery: Check Proxy; works → reload, reopen if the type was corrected; else fix (⋯ → Edit…) or assign another and relaunch | `proxyProblem.worksNow` ru:716, `proxyProblem.worksNow.notStarted` ru:1202; Check = the list's check of the profile's proxy `AppModel+Proxies.swift:64-68`, `ProxyListModel.swift:171-185`; new proxy from next launch `proxies.assign.note` ru:669 |

## 2. Numbers in visible text

| Number | Where | Source | In facts.mjs? |
|---|---|---|---|
| 2 410 (ru) / 2,410 (en) | traffic | facts.mjs:28, CI #388 egress check | yes (`'2410', '2 410', '2,410'`) |
| three / трёх (seconds) | location | `ProfileManager.swift:120` `firstLookupWait = 3`; self-test "Launch speed" (ISOLATION 46) | written as a word; register `3` if the site ever shows it as a digit |
| a second / секунды (1 s) | location | `ProfileManager.swift:124` `rememberedLookupWait = 1`; ISOLATION 46 | word |
| three / трёх (tunnels) | list | `ProxyProbe.swift:52` `latencySamples: Int = 3`; `ProxyChecker.swift:36`; `proxies.step.latency.median` | word |
| two (en) / оба (ru) (settings) | traffic | count of the two settings named next to it (Bypass domains, Safe Browsing) | word |

Numbers inside `code` (`127.0.0.1`, `de-DE`, scheme names) and technical identifiers (SOCKS5, HTTP/2, HTTP/3, IPv4) are not counted by
`tools/check.mjs`. The unv markers carry no numbers.

## 3. unv markers (5 per language, same five in both)

1. **HTTPS proxy** (`types`) — ru «работа через HTTPS-прокси тестами не проверена» / en "no test loads anything through an HTTPS proxy".
   Why: the code configures TLS to the proxy (`ProxyConfigurationFactory.swift:42-43`), but `scripts/selftest_proxy.py` has no
   TLS-wrapped CONNECT listener; only parsing (`Tests/BrowserCoreTests/ProxyAndVaultCreateTests.swift:21`) and the probe's
   `.reachable` verdict (`Tests/BrowserCoreTests/ProxyProbeTests.swift:204`) are tested. Confirm: a TLS listener in the self-test
   proxy and a self-test load through it.
2. **Bypass domains go out directly** (`where`) — ru «уходят ли они напрямую, с адреса этого Mac, — не измерено» / en "that they
   then go out directly is not measured". Why: the field sets Network.framework's `excludedDomains` (`ProxyConfigurationFactory.swift:52`);
   no test loads a bypassed domain, and the egress capture runs only profiles without a bypass list. Confirm: a self-test profile
   with a bypass domain inside the egress capture (and in a profile's own process).
3. **Remote proxy** (`traffic`) — ru «замер — с тестовыми прокси на том же Mac, удалённый прокси не измерялся» / en "measured with
   test proxies on the same Mac, never a remote one". Why: the self-test proxy listens on loopback, `leak_check.py` runs its
   forwarding proxies on the runner; the owner's macOS 27 run also used a local proxy — LEAK_AUDIT 27 ("a remote proxy over the
   internet on macOS 27 is **not measured** yet"). Confirm: the self-test and egress capture through a proxy on another host,
   on macOS 26 and 27.
4. **Launch refusal in a profile's own process** (`failure`) — ru «по коду профиль в своём процессе этого сообщения не показывает» /
   en "by the code, a profile in its own process does not show this message". Why: in that mode the launch runs in the child;
   a thrown `LaunchError` is only logged and the child quits (`ProfileSessionHost.swift:202-214`, no `.error` sent), and an
   unusable proxy makes `ProfileNetworkGuard.engage` throw → `exit(3)` (`ProfileSessionHost.swift:63-68`), which the manager
   reports as `profile.crashed` «Профиль «…» неожиданно завершился…» (`ProfileManager.swift:469-471`). The self-test checks the 407
   refusal with per-profile processes off (`SelfTest.swift:41` sets `PB_PROFILE_PROCESS=0`). The launch probe may still show the
   "loads no pages" sheet with **Needs a login** (manager side, `ProfileManager.swift:215`) if it answers while the child runs —
   a race, not measured. Confirm: a self-test of a 407 proxy and an unusable proxy with `PB_PROFILE_PROCESS=1`, asserting what the
   Profiles window shows.
5. **Safari's own window on a mid-session failure** (`failure`) — ru «что в этом случае показывает окно Safari» / en "what Safari's own
   window shows here". Why: the error page with `errorpage.title` is `BrowserTab`'s (the app's own window); `SafariChromeHost` has
   no load-error handling of its own, and no test stops a proxy under a profile in Safari's window. Confirm: a self-test that
   stops the proxy under a profile shown in Safari's chrome and records the window.

## 4. Localizable.strings keys used as UI words (ru:line / en:line — identical lines)

| ru label | en label | key | line |
|---|---|---|---|
| Изменить… | Edit… | profiles.row.edit (editor), proxies.edit (list ⋯) | 444; 495 |
| Соединение | Connection | editor.topic.connection | 143 |
| Подключение | (Connection) | editor.proxy.connection | 1061 |
| Без прокси / Из списка / Новый | No Proxy / From the List / New | editor.proxy.mode.none / .saved / .new | 1062-1064 |
| Проверить | Check | proxyLine.check | 1051 |
| Сохранить | Save | common.save | 46 |
| Домены в обход (через запятую) | Bypass domains (comma-separated) | editor.proxy.bypass | 127 |
| Прокси (sidebar; Settings section) | Proxies | proxies.title; settings.section.proxies | 597; 1094 |
| Добавить | Add | proxies.add | 1080 |
| Импорт… | Import… | proxies.import | 602 |
| Из файла… | From File… | proxies.import.chooseFile | 634 |
| Назначить профилям… | Assign to Profiles… | proxies.assign | 607 |
| Экспорт… | Export… | proxies.export | 519 |
| Проверить все / Проверить выбранные | Check All / Check Selected | proxies.check.all / .selected | 603-604 |
| Адрес, Соединение, Рукопожатие, Логин, Туннель, Через прокси | Address, Connection, Handshake, Login, Tunnel, Through the proxy | proxies.step.name / .connection / .handshake / .login / .tunnel / .through | 581, 561, 567, 575, 594, 590 |
| Что делать | What to do | proxies.report.advice | 541 |
| Часовой пояс и язык → Из подключения | Time zone and language → From the connection | editor.locale / editor.locale.connection | 160-161 |
| Место и язык | Location and Language | editor.topic.location | 189 |
| Профили — отдельными приложениями в Dock | Each profile its own app in the Dock | settings.behavior.ownProcesses | 1144 |
| Предупреждать, если IP прокси сменился | Warn when the proxy's IP changes | editor.proxy.warnIPChange | 129 |
| WebRTC | WebRTC | editor.webrtc | 221 |
| QUIC (HTTP/3) | QUIC (HTTP/3) | settings.newProfiles.quic | 1126 |
| Safe Browsing (запросы идут в обход прокси) | Safe Browsing (lookups bypass the proxy) | editor.safeBrowsing | 136 |
| «…» не загружает страницы | “…” loads no pages | proxyProblem.title (`%@` → …) | 715 |
| Проверить прокси | Check Proxy | proxyProblem.check | 709 |
| Показать в «Прокси» | Show in Proxies | proxyProblem.showInList | 713 |
| Настройки → Прокси → Если прокси не работает | Settings → Proxies → A proxy that does not work | settings.title; settings.section.proxies; settings.proxies.failure | 1090; 1094; 1159 |
| Не запускать профиль / Запускать профиль и говорить почему | Do not start the profile / Start the profile, say why | settings.proxies.failure.doNotLaunch / .launch | 1162 / 1161 |
| Не удалось загрузить страницу | Page could not be loaded | errorpage.title | 232 |
| Хост не найден | Host not found | proxies.state.hostNotFound | 551 |
| Соединение отклонено | Connection refused | proxies.state.refused | 555 |
| Молчит после соединения | Silent after connecting | proxies.state.silent | 558 |
| Нужен логин / Логин отклонён | Needs a login / Login rejected | proxies.state.credentialsNeeded / .credentialsRejected | 549-550 |
| Отказывает этому Mac | Refuses this Mac | proxies.state.refusedByProxy | 556 |
| Нет выхода в сеть | No way out | proxies.state.noUpstream | 553 |
| Подменный DNS VPN | VPN's substitute DNS | proxies.state.substituteDNS | 559 |

Quoted messages: «…Профиль не запущен…» / “…The profile was not started, so no site opens directly.” — `launch.error.proxyInvalid` 251 and
`launch.error.proxyNeedsCredentials` 252. Table advice paraphrases `proxies.advice.hostNotFound` 479, `.refused` 484, `.silent` 487,
`.credentialsNeeded` 476, `.credentialsRejected` 477, `.refusedByProxy` 485, `.noUpstream` 482, `.substituteDNS` 488.
Every key exists in both languages (`scripts/check_localization.py` enforces it); no label used here is single-language.
The ⋯ glyph and the → path arrows are the article's notation, not strings.

## 5. Discrepancies and surprises (code vs docs, for the owner)

1. **Launch errors are swallowed in a profile's own process.** See unv 4: `ProfileSessionHost.swift:211-214` logs the thrown launch
   error and quits without `ProfileSessionHost.send(.error(…))`; an unusable proxy ends as "ended unexpectedly"
   (`exit(3)` → `profile.crashed`). All proxy-launch self-test checks run with `PB_PROFILE_PROCESS=0` (`SelfTest.swift:41`) — the
   mode the site describes ("every profile in its own process") is the one not covered for these messages.
2. **Which build is the product.** `scripts/release.sh:37` releases `SANDBOX=1` by default; in that build there are no per-profile
   processes (`ProfileProcess.swift:37-40`, `AppSettings.swift:202`): no Safari window, no kernel UDP closure
   (LEAK_AUDIT 149: "Main-process profiles (sandboxed build) have no process-wide net"), one language per run. The brief describes
   the build without the App Sandbox. The article states the own-process items as "a profile in its own process …" and the
   language rule for when that setting is off, so it holds for both.
3. **ROADMAP is behind the code.** `docs/ROADMAP.md:69-76` lists "1.2 Менеджер прокси с чекером" as to do; the list, import,
   stepwise check, assignment and the "Молчит после соединения" state exist and are self-tested (ISOLATION 47; README 415).
   ROADMAP 275 (NetworkExtension "proxy for the whole profile") is not shipped and the article does not claim it.
4. **The editor's note names three geolocation services, the code asks four.** `editor.tz.fromProxy.note` ru:217 / en:217
   lists ipinfo.io, geojs.io, ipwho.is; `ProxyGeoLookup.swift:31-40` also asks ipapi.co (the article names four, per code).
5. **Stale path in strings.** `editor.proxy.saved.empty` / `.noneKnown` ru:1067-1068 say "⋯ → «Прокси…»"; the Profiles window's
   ⋯ menu has no Proxies item (`ProfileListView.swift:548-558`) — the list is the sidebar's **Прокси** (or ⌘K **Прокси…**,
   `palette.proxies` ru:306).
6. **Lookup timeout comment.** `ProfileManager.swift:119` says "The lookup itself gives up after 6 s"; launches call
   `ProxyGeoLookup.lookUp` without a timeout (`ProfileManager.swift:588`), whose default is 12 s (`ProxyGeoLookup.swift:81`).
7. **Stale comment on DNS prefetch.** `ProxyConfigurationFactory.swift:26-27` says there is no switch to disable DNS prefetch;
   the ping-type content rule (`ProxiedContentRules.swift:35`) now blocks it (self-tested).
8. **First launch in its own process can wait twice.** With nothing remembered, the manager waits up to 3 s for the lookup
   (`ProfileManager.swift:228-233`); if it got no location, the child does not get `proxyLocationFound` and waits up to 3 s again
   (`ProfileManager.swift:260-280`, `locationFoundByManager` 578-584). The measured bound (ISOLATION 46) is from the app-process
   path; the article therefore says the *answer* is awaited up to three seconds, not that the launch takes at most three.
9. **Controls for a feature releases lack.** Releases build without the network extension (`TUNNEL.md:21-25`), yet the Profiles ⋯
   menu shows "WebRTC через прокси (сетевое расширение)…" (`ProfileListView.swift:555`, `profiles.menu.tunnel` ru:441) and the
   editor, for a SOCKS5 proxy, says the extension is off with a **Сетевое расширение…** button (`editor.webrtc.tunnelOff` ru:225,
   `ProfileEditorForm.swift:442-446`) that opens a sheet saying "Not built into this app". The article only says WebRTC is off.
10. **Unused keys:** `editor.proxy.use` (ru/en:128) and `editor.tz.fromProxy` (216) have no `L(...)` call in `Sources/`.
11. **System version.** `README.md:33` and Info.plist say macOS 14; the site follows the owner (Apple Silicon, macOS 26+). Not in the article.
12. **Scope of a measured claim.** "Local-network addresses go through the proxy" is code-confirmed; only 10.255.255.1 was measured
    (LEAK_AUDIT deferred list: 192.168/16 and 172.16/12 not probed).
13. **SOCKS5 login failures are not a launch refusal** (ISOLATION 718-724): only HTTP's 407 reaches the launch's lookup. For SOCKS5
    the article relies on the launch probe's sheet (**Нужен логин** / **Логин отклонён**, RFC 1929 in `ProxyProbe.swift:284-301`).
14. Not in the article for length: the import file limit (4 MB, `ProxyImportView.swift:31`), the list limit (10 000 entries,
    `ProxyList.swift:187`), up to eight checks at once (`ProxyChecker.swift:28`), a latency of 1 500 ms or more shown in the warning
    colour (`ProxyListView.swift:558-562`), and the macOS 27 behaviour where a jump to an anchor reloads a proxied page
    (ISOLATION 684-694, measured in CI runs 435–437) — the last one is worth a note in [docs-trouble] or a later revision.
