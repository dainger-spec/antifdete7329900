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
  { value: '26', what: 'минимальная macOS — 26 и новее, только Apple Silicon', source: 'решение владельца (вопрос 11, сквозная правка 3): «macOS 26 и новее», «Intel не поддерживается»; прежние 14.0 из Info.plist неверны' },
  { value: '26', what: 'Safari 26 (геометрия окна, «Mac · Safari 26» в образцах)', source: 'docs/ISOLATION_AND_LIMITATIONS.md §2; UISnapshots.swift' },
  { value: '10', what: 'символов — минимум мастер-пароля', source: 'Localizable.strings setup.rule.length: «Используйте не менее 10 символов.»' },
  { value: '32', what: 'МБ — предел файла cookies', source: 'Localizable.strings cookies.reason.fileTooLarge: «не больше 32 МБ»' },
  // The owner's decisions (questions 2, 3, 10, 16)
  { value: ['19', '59', '149'], what: 'цена в месяц, $: Личный, Профессиональный, Команда', source: 'решение владельца, вопрос 2' },
  { value: ['190', '590', '1490', '1 490', '1,490'], what: 'цена за год, $ — цена десяти месяцев', source: 'решение владельца, вопрос 2: «Годовая оплата — цена десяти месяцев»' },
  { value: ['10', '50', '200'], what: 'профилей в тарифе: Личный, Профессиональный, Команда', source: 'решение владельца, вопрос 2' },
  { value: ['2', '3', '10'], what: 'Mac в тарифе: Личный, Профессиональный, Команда', source: 'решение владельца, вопрос 2' },
  { value: ['5', '1'], what: 'мест: Команда — 5, Личный и Профессиональный — 1', source: 'решение владельца, вопрос 2' },
  { value: ['7', '3'], what: 'пробный период: 7 дней, до 3 профилей', source: 'решение владельца, вопрос 3' },
  { value: ['14', '7'], what: 'возврат: 14 дней с первой оплаты, 7 дней после продления', source: 'решение владельца, вопрос 10' },
  { value: ['20', '100', '200', '1', '4'], what: 'место для синхронизации: 20 МБ на профиль тарифа, не меньше 100 МБ — 200 МБ на «Личном», 1 ГБ на «Профессиональном», 4 ГБ на всю «Команду», 100 МБ в пробном периоде', source: 'решение владельца, вопрос 16 (1 ноября 2026): «20 МиБ на профиль тарифа, не меньше 100 МиБ. Получается 200 МБ на «Личном», 1 ГБ на «Профессиональном», 4 ГБ на «Команде»»; так считает сервер — lumen-api-server docs/SYNC_SERVER.md, «Квота»: max(100 МиБ, профилей в тарифе × 20 МиБ)' },
  { value: ['15', '5'], what: 'код из письма: действует 15 минут, ввести можно 5 раз', source: 'lumen-api-server docs/CONTRACT.md §17.3 signup.code_terms: «Код действует <срок codeValidSeconds>, ввести его можно <codeAttempts раз>»; значения по умолчанию — §15 «6 цифр, 15 минут, 5 попыток». На настоящем сайте — числа из ответа сервера (SITE_API §4)' },
  { value: ['10', '256'], what: 'символов в пароле аккаунта: от 10 до 256', source: 'lumen-api-server docs/CONTRACT.md §3: invalid_password «Пароль — от 10 до 256 символов»; §5.1' },
  // The documentation (docs-*.html), from the browser's code at 194828b and docs/SCALE.md; every source in
  // design/site/docs-sources/<article>.md
  { value: ['27', '26.1'], what: 'Safari 27 и macOS 27 (вид iPhone, раннеры CI); iOS 26.1 и новее (замороженный токен ОС)', source: 'Sources/BrowserCore/…/DeviceGeneration.swift:23-24, 128-138 (gen.ios27); docs/SCALE.md (раннеры macOS 26.6.2 и 27.0.1); docs/ISOLATION_AND_LIMITATIONS.md:304-308' },
  { value: ['390', '844', '820', '1180'], what: 'окно мобильного вида, пунктов: iPhone 390 × 844, iPad 820 × 1180', source: 'PrivacyScripts.swift:101-102 (CGSize(width: 390, height: 844), CGSize(width: 820, height: 1180))' },
  { value: '4096', what: 'байт — предел имени и значения одного cookie при импорте', source: 'CookieImport.swift:148-149, 375; cookies.reason.tooLarge; Tests/…/CookieImportTests.swift:253' },
  { value: ['30', '6'], what: '«Остановить» и выход ждут процесс профиля 30 секунд; системный журнал в диагностике — за 30 минут; обновления проверяются каждые 6 часов', source: 'ProfileManager.swift:770 (waitUntilExit(timeout: 30)); диагностика: 30 минут системного журнала (docs-sources/docs-trouble.md); AppUpdater.swift:125-128 (interval = 6 * 3600)' },
  { value: ['6', '12', '150', '3', '7'], what: 'профиль — от 6 до 12 процессов и около 150 МБ; машина замеров CI — 3 процессора, 7 ГБ', source: 'docs/SCALE.md:43, 79-84, 148-151' },
  { value: ['10–40', '40', '5–9', '9', '6–35', '35', '5,1–13,6', '5.1–13.6', '5,1', '5.1', '13,6', '13.6', '13'], what: 'замеры запуска и остановки: десять профилей стартуют за 10–40 с; остановка — 5–9 с до десяти, 6–35 с для двадцати-тридцати; выход с десятью — 5,1–13,6 с', source: 'docs/SCALE.md:35-38, 123, 125-127, 133-141' },
  { value: '10', what: 'минут ждёт установщик обновления, пока приложение закроется', source: 'Installer.swift:42 (patience: 600); docs/UPDATES.md:75, 207-208' },
  // Dates and conventions
  { value: ['2026', '29'], what: 'даты прогонов и изменений: 29 октября 2026; год в подвале', source: 'git log (все изменения ветки — 2026-10-29); CI #385, #388' },
  { value: '26', what: 'дата статьи о шуме: 26 октября 2026', source: 'README: «Fingerprint note (2026-10-26)»' },
  { value: '404', what: 'код ответа «страница не найдена»', source: 'HTTP' },
];
