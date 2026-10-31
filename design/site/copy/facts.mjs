// Every number the site shows, and where it comes from. tools/check.mjs fails on a number in the visible
// text that is not here. Not counted: values the owner decides (yellow, .tbd), example data in mock-ups
// ([data-sample]: the account's email, dates, device codes, sync objects, invoices), code, and technical
// identifiers (HTTP/2, SHA-256, SOCKS5, JA3…).
//
// CI runs cited (workflow "CI", branch claude/secret-partner-setup-e505tc, job "macOS build, core tests,
// WebKit self-test"):
//   #388 — run 40933992353, commit ce64ca1, 29 Oct 2026, the latest green run;
//   #385 — run 40928706937, commit d1d1db7, 29 Oct 2026 (TLS was last compared here: in #388 tls.peet.ws
//          did not answer Safari — "tls.error: JSON Parse error", 0 compared).
const CI388 = 'CI #388 (run 40933992353, ce64ca1)';
const CI385 = 'CI #385 (run 40928706937, d1d1db7)';

export const FACTS = [
  // Comparison with real Safari
  { value: '448', what: 'признаков страницы-зонда сравнивается с Safari', source: `${CI388}: «SAFARI-REFERENCE PASSED: 434 keys identical, 14 differ (reported), 0 must-match keys differ» — 434 + 14 = 448; live_compare: «probe 435/448»` },
  { value: '434', what: 'признака совпадают', source: `${CI388} (то же в ${CI385}); docs/ISOLATION_AND_LIMITATIONS.md §2 «434 keys identical»` },
  { value: '14', what: 'отличий зонда (объяснены)', source: `${CI388}: «14 differ (reported)»: 5 DIFF + 9 INFO в выводе safari_reference.py` },
  { value: '0', what: 'обязательных отличий; провалов тестов и самотеста; пакетов мимо прокси', source: `${CI388}: «0 must-match keys differ»; «Executed 223 tests, with 0 failures»; «SELFTEST PASSED: 274 passed, 0 failed»; «egress check: nothing went around the profile's proxy»` },
  { value: '31', what: 'заголовок запросов — тот же состав и порядок', source: `${CI388} и ${CI385}: «LIVE-COMPARE … headers 31/31»; docs/ISOLATION_AND_LIMITATIONS.md §2 «(31/31)»` },
  { value: '15', what: 'значений TLS и HTTP/2 совпадают', source: `${CI385}: «LIVE-COMPARE [default] … tls 15/15»` },
  { value: '10', what: 'значений геометрии окна совпадают (и с двумя вкладками)', source: `${CI388}: «geometry 10/10, geometry-2tabs 10/10»` },
  { value: ['16', '17'], what: 'разрешения и API: 16 из 17', source: `${CI388}: «apis 16/17»; отличие — «apis.devices: Safari="audioinput,videoinput" profile="audioinput"» (${CI385})` },
  { value: ['5', '1', '4', '2'], what: 'число признаков в каждой строке таблицы отличий: Apple Pay и Web Push — 5, windowOwnCount — 1, язык — 4, размер окна — 2, webdriver и стек — 2', source: `${CI388}, вывод safari_reference.py: DIFF ApplePaySession, PaymentRequest, PushManager, ApplePaySetup, MerchantValidationEvent; INFO windowOwnCount; INFO language, languages, intlLocale, dateString; INFO innerSize, outerSize; INFO webdriver, errorStack` },
  { value: ['26.6.2'], what: 'macOS и Safari на машине CI', source: `${CI388}: «INFO macOS Version 26.6.2 (Build 25G83), Safari 26.6.2»` },
  { value: ['52', '90'], what: 'высота панелей окна: 52 px с одной вкладкой, 90 px с двумя', source: 'docs/ISOLATION_AND_LIMITATIONS.md §2: «the browser chrome is 52 px with one tab and 90 px with two, as in Safari 26»' },
  // Leak checks
  { value: ['2410', '2 410', '2,410'], what: 'пакетов захвачено вокруг самотеста', source: `${CI388}: «egress check: 2410 packets captured, 2406 with a process … nothing went around the profile's proxy»` },
  { value: ['606017', '606 017', '606,017'], what: 'строк трассы записей на диск', source: `${CI388}: «disk check: build/egress/fs.txt: 606017 lines … nothing was written into the real Safari's places»` },
  { value: '223', what: 'модульных тестов ядра на macOS', source: `${CI388}: «Executed 223 tests, with 0 failures»` },
  { value: '274', what: 'проверки самотеста на настоящем WebKit', source: `${CI388}: «SELFTEST PASSED: 274 passed, 0 failed» (сборка без App Sandbox — та, что с окном Safari)` },
  // Encryption
  { value: ['64', '3', '4'], what: 'Argon2id: 64 МиБ, 3 прохода, 4 потока', source: 'docs/ARCHITECTURE.md «Key hierarchy»: «Argon2id (RFC 9106): 64 MiB, 3 passes, 4 lanes»; README' },
  { value: '9106', what: 'RFC 9106 (Argon2)', source: 'docs/ARCHITECTURE.md; docs/ISOLATION_AND_LIMITATIONS.md §3' },
  { value: '16', what: 'байт соли Argon2id', source: 'docs/ARCHITECTURE.md: «16-byte random salt»' },
  { value: '256', what: 'бит: ключ хранилища и ключ профиля; AES-256-GCM', source: 'docs/ARCHITECTURE.md: «VMK (vault master key, random 256-bit)», «profile key (random 256-bit per profile)»' },
  // Warm-up
  { value: '26', what: 'стран с готовыми списками прогрева', source: 'Sources/BrowserCore/WarmUp/WarmUpPreset.swift: 26 пресетов group .country (de, fr, gb, es, it, pl, us, br, tr, nl, ua, kz, ee, lv, lt, fi, se, no, dk, cz, pt, mx, ca, au, jp, in); README «by country: 26 countries»' },
  { value: ['4–12', '10–35', '25–90', '4', '12', '10', '35', '25', '90'], what: 'секунд на странице: «Быстро» 4–12, «Обычно» 10–35, «Глубоко» 25–90', source: 'WarmUpPreset.swift, WarmUpQuality.dwell; Localizable.strings warmup.quality.*.detail' },
  { value: '10', what: 'минут до новой попытки прогрева по расписанию', source: 'Localizable.strings warmup.schedule.note: «пробуется снова через 10 минут»; README' },
  { value: ['4', '12', '84'], what: 'образец данных приложения: прогрев 4 из 12 страниц, 84 cookies (профиль Northwind)', source: 'Sources/PrivacyBrowser/App/UISnapshots.swift sampleRows: WarmUpStatus(phase: .running, visited: 3, total: 12, cookies: 84); в прототипе списка — «Прогрев 4/12 · cookies: 84»' },
  { value: ['84', '142', '1730', '1 730', '1,730'], what: 'образец списка прокси: задержка 84, 142 и 1 730 мс (медиана трёх туннелей)', source: 'UISnapshots.swift proxyList() (7064cca): works(…, [80, 84, 97]), works(…, [138, 142, 160]), works(…, [1730]); latencyMilliseconds = medianLatency' },
  // Product facts
  { value: '14', what: 'минимальная macOS 14 Sonoma', source: 'Resources/Info.plist: LSMinimumSystemVersion 14.0; README «macOS 14 Sonoma or later»' },
  { value: '26', what: 'Safari 26 (геометрия окна, «Mac · Safari 26» в образцах)', source: 'docs/ISOLATION_AND_LIMITATIONS.md §2; UISnapshots.swift' },
  { value: '10', what: 'символов — минимум мастер-пароля', source: 'Localizable.strings setup.rule.length: «Используйте не менее 10 символов.»' },
  { value: '32', what: 'МБ — предел файла cookies', source: 'Localizable.strings cookies.reason.fileTooLarge: «не больше 32 МБ»' },
  // Dates and conventions
  { value: ['2026', '29'], what: 'даты прогонов и изменений: 29 октября 2026; год в подвале', source: 'git log (все изменения ветки — 2026-10-29); CI #385, #388' },
  { value: '26', what: 'дата статьи о шуме: 26 октября 2026', source: 'README: «Fingerprint note (2026-10-26)»' },
  { value: '404', what: 'код ответа «страница не найдена»', source: 'HTTP' },
];
