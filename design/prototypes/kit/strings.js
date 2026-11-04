// The strings the prototypes show, in both UI languages, taken from Resources/{en,ru}.lproj/Localizable.strings
// under the same keys. Keys in NEW do not exist in the app yet: the proposals need them, and they are listed
// in design/README.md ("Новые строки"). Add ?marknew=1 to any prototype to outline them on screen.
(function (L) {
  'use strict';

  const EXISTING = {
    // common
    'common.cancel': ['Cancel', 'Отмена'],
    'common.save': ['Save', 'Сохранить'],
    'common.done': ['Done', 'Готово'],
    'common.delete': ['Delete', 'Удалить'],
    // profiles window
    'profiles.title': ['Profiles', 'Профили'],
    'profiles.count': ['%ld profiles', 'Профилей: %ld'],
    'profiles.countRunning': ['%1$ld profiles · %2$ld running', 'Профилей: %1$ld · запущено: %2$ld'],
    'profiles.search': ['Search', 'Поиск'],
    'profiles.search.clear': ['Clear Search', 'Очистить поиск'],
    'profiles.menu.more': ['More', 'Ещё'],
    'profiles.menu.sync': ['Sync…', 'Синхронизация…'],
    'profiles.menu.syncNow': ['Sync Now', 'Синхронизировать сейчас'],
    'profiles.menu.tunnel': ['WebRTC through proxies (network extension)…', 'WebRTC через прокси (сетевое расширение)…'],
    'profiles.menu.changePassword': ['Change Master Password…', 'Сменить мастер-пароль…'],
    'profiles.action.new': ['New Profile', 'Новый профиль'],
    'profiles.action.lock': ['Lock', 'Заблокировать'],
    'profiles.action.lock.help': ['Stop all profiles, encrypt their data, and forget all keys', 'Остановить все профили, зашифровать их данные и забыть все ключи'],
    'profiles.filter.all': ['All Profiles', 'Все профили'],
    'profiles.filter.running': ['Running', 'Запущенные'],
    'profiles.filter.proxied': ['Through a Proxy', 'Через прокси'],
    'profiles.filter.ephemeral': ['Ephemeral', 'Временные'],
    'profiles.filters': ['Filters', 'Фильтры'],
    'profiles.sync.off': ['Sync is off', 'Без синхронизации'],
    'profiles.sync.notYet': ['Not synced yet', 'Ещё не синхронизировано'],
    'profiles.sync.syncing': ['Syncing…', 'Синхронизация…'],
    'profiles.sync.failed': ['Last sync failed', 'Сбой синхронизации'],
    'profiles.sync.synced': ['Synced %@', 'Синхронизировано %@'],
    'profiles.column.name': ['Name', 'Имя'],
    'profiles.column.exit': ['Exit', 'Выход в сеть'],
    'profiles.column.appearsAs': ['Appears as', 'Видится как'],
    'profiles.column.lastUsed': ['Last used', 'Запускался'],
    'profiles.group.running': ['Running', 'Запущены'],
    'profiles.group.ready': ['Ready', 'Готовы к запуску'],
    'profiles.row.running': ['Running', 'Работает'],
    'profiles.row.starting': ['Starting…', 'Запуск…'],
    'profiles.row.encrypting': ['Encrypting data…', 'Шифрование данных…'],
    'profiles.row.ephemeral': ['Ephemeral · nothing kept', 'Временный, без следов'],
    'profiles.row.launch': ['Launch', 'Запустить'],
    'profiles.row.stop': ['Stop', 'Остановить'],
    'profiles.row.newWindow': ['New Window', 'Новое окно'],
    'profiles.row.library': ['Bookmarks & History…', 'Закладки и история…'],
    'profiles.row.edit': ['Edit…', 'Изменить…'],
    'profiles.row.passwords': ['Passwords…', 'Пароли…'],
    'profiles.row.importCookies': ['Import Cookies…', 'Импорт cookies…'],
    'profiles.row.warmUp': ['Warm Up…', 'Прогрев…'],
    'profiles.row.delete': ['Delete…', 'Удалить…'],
    'profiles.row.moreFor': ['More for %@', 'Ещё для «%@»'],
    'profiles.row.warmUpShort': ['Warm-up %1$ld/%2$ld', 'Прогрев %1$ld/%2$ld'],
    'profiles.row.warmUpCookies': ['· cookies: %ld', '· cookies: %ld'],
    'profiles.row.warmingUp': ['Warming up: page %1$ld of %2$ld', 'Прогрев: страница %1$ld из %2$ld'],
    'profiles.exit.direct': ['Direct', 'Напрямую'],
    'profiles.exit.viaProxy': ['Through the proxy %@', 'Через прокси %@'],
    'profiles.exit.unknownCountry': ['The exit country shows after a launch that looks the proxy up (time zone from the proxy, or the exit-IP warning).', 'Страна выхода появится после запуска, при котором прокси проверяется (часовой пояс по прокси или предупреждение о смене IP).'],
    'profiles.lastUsed.now': ['Now', 'Сейчас'],
    'profiles.lastUsed.never': ['Never', 'Никогда'],
    'profiles.footnote.sealed': ['Stopped profiles are sealed with your master password.', 'Остановленные профили зашифрованы мастер-паролем.'],
    'profiles.empty.title': ['No profiles yet', 'Пока нет профилей'],
    'profiles.empty.subtitle': ['Create your first isolated profile to start browsing.', 'Создайте первый изолированный профиль, чтобы начать работу.'],
    'profiles.noMatches': ['No profiles match', 'Подходящих профилей нет'],
    'profiles.showAll': ['Show All Profiles', 'Показать все профили'],
    'profiles.device.mac': ['Mac', 'Mac'],
    'profiles.device.iphone': ['iPhone', 'iPhone'],
    'profiles.appearsAs': ['%1$@ · Safari %2$@', '%1$@ · Safari %2$@'],
    'launch.error.proxyInvalid': ['The profile\'s proxy is misconfigured (address “%@”). The profile was not started, so no site opens directly. Fix the proxy address in the profile settings.', 'Прокси профиля настроен неверно (адрес «%@»). Профиль не запущен, чтобы сайты не открылись напрямую. Исправьте адрес прокси в настройках профиля.'],
    // lock screen
    'unlock.title': ['Vault locked', 'Хранилище заблокировано'],
    'unlock.subtitle': ['Enter your master password to continue.', 'Введите мастер-пароль, чтобы продолжить.'],
    'unlock.action.unlock': ['Unlock', 'Разблокировать'],
    'unlock.working': ['Unlocking…', 'Разблокировка…'],
    'unlock.reset.action': ['Forgot password…', 'Не помню пароль…'],
    'setup.field.password': ['Master password', 'Мастер-пароль'],
    // editor
    'editor.title.new': ['New Profile', 'Новый профиль'],
    'editor.tabs': ['Sections', 'Разделы'],
    'editor.section.general': ['General', 'Основные'],
    'editor.tab.identity': ['Identity', 'Идентичность'],
    'editor.section.network': ['Network', 'Сеть'],
    'editor.section.privacy': ['Privacy', 'Конфиденциальность'],
    'editor.tab.data': ['Data', 'Данные'],
    'editor.footer.note': ['Changes apply at the next launch.', 'Изменения вступят в силу при следующем запуске.'],
    'editor.proxy.use.title': ['Use a proxy', 'Использовать прокси'],
    'editor.proxy.detail': ['Every page of this profile goes through it — never around it.', 'Все страницы этого профиля идут через него — никогда в обход.'],
    'editor.proxy.type': ['Type', 'Тип'],
    'editor.proxy.host': ['Host', 'Хост'],
    'editor.proxy.port': ['Port', 'Порт'],
    'editor.proxy.username': ['Username (optional)', 'Имя пользователя (необязательно)'],
    'editor.proxy.password': ['Password', 'Пароль'],
    'editor.proxy.bypass': ['Bypass domains (comma-separated)', 'Домены в обход (через запятую)'],
    'editor.proxy.warnIPChange': ['Warn when the proxy\'s IP changes', 'Предупреждать, если IP прокси сменился'],
    'editor.proxy.warnIPChange.note': ['At each launch the proxy\'s exit IP is looked up through the proxy (as for its time zone) and compared with the previous launch of this profile. Proxies that rotate addresses change it every time.', 'При каждом запуске внешний IP прокси узнаётся через сам прокси (как и его часовой пояс) и сравнивается с прошлым запуском этого профиля. У прокси с ротацией адресов он меняется каждый раз.'],
    'editor.location.exitsIn': ['Exits in %@', 'Выход в сеть: %@'],
    'editor.location.checked': ['checked through the proxy %@', 'проверено через прокси %@'],
    'editor.location.followsProxy': ['Time zone follows proxy', 'Часовой пояс по прокси'],
    'editor.tz.fromProxy.note': ['At launch the proxy\'s exit IP is looked up through the proxy (ipinfo.io, geojs.io or ipwho.is) and the profile runs in its time zone. The first profile launched also sets the language websites see (Accept-Language) for the whole app until it quits.', 'При запуске выходной IP прокси определяется через сам прокси (ipinfo.io, geojs.io или ipwho.is), и профиль работает в его часовом поясе. Первый запущенный профиль также задаёт язык для сайтов (Accept-Language) — для всего приложения до выхода из него.'],
    'editor.webrtc': ['WebRTC', 'WebRTC'],
    'editor.webrtc.disabled': ['Disabled', 'Отключён'],
    'editor.webrtc.tunnelOff': ['The network extension is off: WebRTC is off, otherwise its UDP would go around the proxy from the real IP.', 'Сетевое расширение выключено: WebRTC отключён, иначе UDP шёл бы мимо прокси с реального IP.'],
    'editor.webrtc.tunnelSettings': ['Network extension…', 'Сетевое расширение…'],
    'editor.network.footer': ['Native per-profile proxy, fail-closed (no direct fallback). WebRTC goes through the proxy only with the network extension and SOCKS5; otherwise it is off.', 'Нативный прокси для профиля, с жёстким запретом прямого соединения. WebRTC идёт через прокси только с сетевым расширением и SOCKS5, иначе отключён.'],
    'editor.error.port': ['Proxy port must be a number', 'Порт прокси должен быть числом'],
    'editor.name': ['Name', 'Название'],
    'editor.startURL': ['Start URL', 'Начальный адрес'],
    'editor.defaultName': ['Profile %ld', 'Профиль %ld'],
    'editor.subtitle.new': ['Its own cookies, identity and network', 'Свои cookie, идентичность и сеть'],
    'editor.subtitle.direct': ['Connects directly', 'Подключается напрямую'],
    'editor.ephemeral.title': ['Ephemeral', 'Временный профиль'],
    'editor.ephemeral.detail': ['No website data or history is written to disk; nothing is left once it stops.', 'Данные сайтов и история не записываются на диск — после остановки ничего не остаётся.'],
    'editor.generation': ['Device / version', 'Устройство / версия'],
    'gen.macos26': ['Safari on macOS 26 (matches this engine)', 'Safari на macOS 26 (соответствует движку)'],
    'editor.ua.useCustom': ['Custom user agent', 'Свой User-Agent'],
    'editor.ua.effective': ['User agent', 'User-Agent'],
    'editor.generation.footer': ['Tags the profile with a target Apple OS version: it sets the self-declared User-Agent and some defaults. It does not switch the real WebKit core (not possible with public APIs) and does not make a Mac look like an iPhone — see docs/ISOLATION_AND_LIMITATIONS.md §2.', 'Помечает профиль целевой версией ОС Apple: задаёт заявляемый User-Agent и часть настроек по умолчанию. Не переключает реальный движок WebKit (невозможно через публичные API) и не превращает Mac в iPhone — см. docs/ISOLATION_AND_LIMITATIONS.md §2.'],
    'editor.geo': ['Geolocation', 'Геолокация'],
    'editor.geo.deny': ['Deny', 'Запретить'],
    'editor.tz.override': ['Override time zone', 'Переопределить часовой пояс'],
    'editor.tz.fromProxyHint': ['Without an override, the time zone follows the proxy\'s location (Network).', 'Без своего пояса профиль берёт часовой пояс места выхода прокси (вкладка «Сеть»).'],
    'editor.safeBrowsing': ['Safe Browsing (lookups bypass the proxy)', 'Safe Browsing (запросы идут в обход прокси)'],
    'editor.privacy.footer': ['WebRTC, geolocation and time zone are JavaScript shims (not applied in workers, detectable). See docs/ISOLATION_AND_LIMITATIONS.md.', 'WebRTC, геолокация и часовой пояс реализованы JavaScript-обёртками (не действуют в worker’ах, обнаруживаются). См. docs/ISOLATION_AND_LIMITATIONS.md.'],
    'editor.section.history': ['History', 'История'],
    'editor.history.record': ['Record history', 'Записывать историю'],
    'editor.history.keep': ['Keep history for', 'Хранить историю'],
    'editor.retain.quarter': ['3 months', '3 месяца'],
    'editor.history.footer': ['History and bookmarks are encrypted with the profile key. Ephemeral profiles keep history in memory only; bookmarks are always saved.', 'История и закладки шифруются ключом профиля. Эфемерные профили хранят историю только в памяти; закладки сохраняются всегда.'],
    'editor.section.passwords': ['Passwords', 'Пароли'],
    'editor.passwords.autoFill': ['AutoFill user names and passwords', 'Автозаполнение имён и паролей'],
    'editor.passwords.footer': ['After a sign-in the browser offers to save the password, encrypted with this profile; a login field then lists the saved logins for its site. Nothing is filled until you choose a login.', 'После входа на сайт браузер предлагает сохранить пароль (он хранится зашифрованным вместе с профилем); затем в поле входа появляется список сохранённых логинов этого сайта. Ничего не подставляется, пока вы не выберете логин.'],
    'editor.section.sync': ['Sync', 'Синхронизация'],
    'editor.sync.cookies': ['Sync cookies with other devices', 'Синхронизировать cookies с другими устройствами'],
    'editor.sync.footer.ephemeral': ['An ephemeral profile keeps no website data, so it has no cookies to sync.', 'Эфемерный профиль не хранит данные сайтов, поэтому синхронизировать ему нечего.'],
    'warmup.counter.cookies': ['cookies collected', 'cookies собрано'],
    'warmup.progress.page': ['Page %1$ld of %2$ld', 'Страница %1$ld из %2$ld'],
    // sync / tunnel / password (settings)
    'sync.title': ['Sync', 'Синхронизация'],
    'sync.to': ['Sync to', 'Куда синхронизировать'],
    'sync.mode.off': ['Off', 'Выключена'],
    'sync.mode.folder': ['Folder (local-only)', 'Папка (только локально)'],
    'sync.mode.server': ['Server', 'Сервер'],
    'sync.folder.label': ['Folder', 'Папка'],
    'sync.folder.choose': ['Choose…', 'Выбрать…'],
    'sync.folder.note': ['Encrypted blobs are written to this folder (a NAS share, an external disk). Use one folder per vault. Concurrent writes from two Macs through a file-syncing service can produce conflict copies, which are ignored.', 'В эту папку пишутся зашифрованные блоки (сетевой диск, внешний накопитель). Используйте отдельную папку на хранилище. Одновременная запись с двух Mac через облачную синхронизацию может создать конфликтные копии, которые игнорируются.'],
    'sync.status': ['Status', 'Состояние'],
    'sync.status.ok': ['Last sync %@: %@', 'Последняя синхронизация %@: %@'],
    'sync.status.uploaded': ['%ld uploaded', 'отправлено: %ld'],
    'sync.status.downloaded': ['%ld downloaded', 'получено: %ld'],
    'sync.now': ['Sync Now', 'Синхронизировать сейчас'],
    'sync.stopFirst': ['Stop all profiles first.', 'Сначала остановите все профили.'],
    'sync.footer': ['Synced, end-to-end encrypted: profile list, settings, saved passwords, bookmarks, history. Not synced: website data (cookies, storage, cache). The sync location can see object counts, sizes, timing, and the vault header needed to unlock with the master password.', 'Синхронизируется со сквозным шифрованием: список профилей, настройки, пароли, закладки, история. Не синхронизируется: данные сайтов (cookie, хранилище, кэш). Месту синхронизации видны число объектов, их размеры, время и заголовок хранилища, нужный для разблокировки мастер-паролем.'],
    'tunnel.title': ['WebRTC through proxies', 'WebRTC через прокси'],
    'tunnel.status': ['Status', 'Состояние'],
    'tunnel.state.off': ['Off', 'Выключено'],
    'tunnel.state.ready': ['On: connects when a profile needs it', 'Включено: подключится, когда понадобится профилю'],
    'tunnel.enable': ['Enable', 'Включить'],
    'tunnel.openSettings': ['Open System Settings', 'Открыть Системные настройки'],
    'tunnel.refresh': ['Check again', 'Проверить снова'],
    'tunnel.warning.off': ['While the extension is off, WebRTC is off in profiles with a proxy: otherwise its UDP (STUN, TURN, media) would go around the proxy, from this Mac\'s real IP.', 'Пока расширение выключено, WebRTC в профилях с прокси отключён: иначе его UDP (STUN, TURN, медиа) шёл бы мимо прокси с реального IP этого Mac.'],
    'changepw.title': ['Change master password', 'Сменить мастер-пароль'],
    'changepw.current': ['Current password', 'Текущий пароль'],
    'changepw.new': ['New password', 'Новый пароль'],
    'changepw.repeat': ['Repeat new password', 'Повторите новый пароль'],
    'changepw.note': ['Only the wrapped vault key is re-encrypted; profile data is unchanged.', 'Перешифровывается только обёрнутый ключ хранилища; данные профилей не меняются.'],
    'changepw.action.change': ['Change', 'Сменить'],
    'setup.rule.length': ['Use at least 10 characters.', 'Используйте не менее 10 символов.'],
    'setup.rule.match': ['Passwords do not match.', 'Пароли не совпадают.'],
    'setup.title': ['Create a master password', 'Создайте мастер-пароль'],
    'setup.subtitle': ['The master password encrypts the profile list, every profile\'s settings, saved passwords, history, bookmarks and archived website data. It cannot be recovered — if you forget it, the data is lost.', 'Мастер-пароль шифрует список профилей, настройки каждого профиля, сохранённые пароли, историю, закладки и архив данных сайтов. Его нельзя восстановить — если вы его забудете, данные будут потеряны.'],
    'setup.field.repeat': ['Repeat master password', 'Повторите мастер-пароль'],
    'setup.action.create': ['Create Vault', 'Создать хранилище'],
    'tunnel.intro': ['PrivacyBrowser\'s network extension sends the WebRTC of profiles with a SOCKS5 proxy through that proxy: pages get a relay (TURN) on a virtual address, which sends their UDP through the proxy\'s UDP ASSOCIATE. Sites and peers see the proxy\'s address, not this Mac\'s. The extension leaves the rest of the Mac\'s traffic alone.', 'Сетевое расширение PrivacyBrowser пропускает WebRTC профилей с SOCKS5-прокси через их прокси: страницы получают ретранслятор (TURN) на виртуальном адресе, а он отправляет UDP через UDP ASSOCIATE прокси. Сайты и собеседники видят адрес прокси, а не этого Mac. Остальной трафик Mac расширение не трогает.'],
    'tunnel.limits': ['Only the WebRTC of profiles with a SOCKS5 proxy without TLS goes through the extension (an HTTP proxy cannot carry UDP); the proxy must support UDP ASSOCIATE. Pages get relay candidates only. While the tunnel is connected macOS shows a VPN, and it runs one such VPN at a time: starting this tunnel disconnects another VPN app\'s tunnel (WireGuard, Tailscale, …), and when that one starts, this one stops — WebRTC in proxied profiles then fails, it does not fall back to this Mac\'s address.', 'Через расширение идёт только WebRTC профилей с SOCKS5-прокси без TLS (HTTP-прокси UDP не переносит); у прокси должен работать UDP ASSOCIATE. Страницы получают только кандидаты-ретрансляторы. Пока туннель подключён, macOS показывает VPN, и таких VPN одновременно работает только один: запуск этого туннеля отключает туннель другого VPN-приложения (WireGuard, Tailscale…), а когда тот запускается, останавливается этот — тогда WebRTC в профилях с прокси не работает, но и на адрес этого Mac не переключается.'],
    'sync.folder.none': ['None chosen', 'Не выбрана'],
  };

  // Proposed: strings the prototypes need that the app does not have yet.
  const NEW = {
    'profiles.column.status': ['Status', 'Статус'],
    'profiles.status.stopped': ['Stopped', 'Остановлен'],
    'profiles.status.failed': ['Didn’t start', 'Не запустился'],
    'profiles.countries': ['Exit countries', 'Страны выхода'],
    'profiles.countries.unknown': ['Not checked yet', 'Ещё не проверены'],
    'profiles.search.prompt': ['Name, country, proxy', 'Имя, страна, прокси'],
    'profiles.selection.count': ['%ld selected', 'Выбрано: %ld'],
    'profiles.selection.launch': ['Launch %ld', 'Запустить %ld'],
    'profiles.selection.stop': ['Stop %ld', 'Остановить %ld'],
    'profiles.selection.clear': ['Deselect All', 'Снять выделение'],
    'profiles.filter.clearAll': ['Clear Filters', 'Сбросить фильтры'],
    'profiles.banner.didNotStart': ['“%@” didn’t start: its proxy address is not valid.', 'Профиль «%@» не запустился: адрес прокси неверный.'],
    'profiles.banner.fix': ['Edit Proxy…', 'Исправить прокси…'],
    'profiles.noMatches.hint': ['Nothing matches “%@” with these filters.', 'По запросу «%@» с этими фильтрами ничего нет.'],
    'common.details': ['Details', 'Подробнее'],
    'settings.tab.security': ['Security', 'Безопасность'],
    'settings.security.password': ['Master password', 'Мастер-пароль'],
    'settings.security.password.hint': ['Encrypts the vault; it cannot be recovered.', 'Шифрует хранилище; восстановить его нельзя.'],
    'settings.security.change': ['Change…', 'Сменить…'],
    'settings.security.lock': ['Lock now', 'Заблокировать сейчас'],
    'settings.security.lock.hint': ['Stops all profiles and forgets all keys.', 'Останавливает все профили и забывает ключи.'],
    'sync.to.hint': ['Only encrypted data leaves this Mac.', 'Этот Mac покидают только зашифрованные данные.'],
    'sync.folder.hint': ['One folder per vault: a NAS share or a disk.', 'Одна папка на хранилище: сетевой диск или накопитель.'],
    'sync.whatSyncs': ['What syncs, and what the location can see', 'Что синхронизируется и что видно месту хранения'],
    'tunnel.hint': ['Carries the WebRTC of SOCKS5 profiles through their proxy.', 'Пропускает WebRTC профилей с SOCKS5 через их прокси.'],
    'editor.proxy.type.hint': ['SOCKS5 can also carry WebRTC.', 'Только SOCKS5 может нести и WebRTC.'],
    'editor.proxy.warnIPChange.hint': ['Compares the exit IP with the previous launch.', 'Сверяет внешний IP с прошлым запуском.'],
    'editor.webrtc.hint.off': ['Off: the network extension is off.', 'Отключён: сетевое расширение выключено.'],
    'editor.proxy.bypass.hint': ['These domains open without the proxy.', 'Эти домены открываются без прокси.'],
    'editor.group.proxy': ['Proxy', 'Прокси'],
    'editor.group.webrtc': ['WebRTC', 'WebRTC'],
    'editor.errors.count': ['Fix 1 field to save', 'Чтобы сохранить, исправьте 1 поле'],
    'editor.generation.hint': ['Sets the declared User-Agent; the engine stays this Mac’s WebKit.', 'Задаёт заявляемый User-Agent; движок остаётся WebKit этого Mac.'],
    'editor.ua.hint': ['Replaces the User-Agent the device above sets.', 'Заменяет User-Agent, заданный устройством выше.'],
    'editor.geo.hint': ['What a site gets when it asks for your location.', 'Что получит сайт, когда спросит местоположение.'],
    'editor.tz.override.hint': ['Otherwise the time zone of the proxy’s exit.', 'Иначе — пояс места выхода прокси.'],
    'editor.safeBrowsing.hint': ['Warns about phishing and malware pages.', 'Предупреждает о фишинговых и вредоносных страницах.'],
    'editor.history.record.hint': ['Encrypted with the profile key.', 'Шифруется ключом профиля.'],
    'editor.passwords.autoFill.hint': ['Offers to save after a sign-in; never fills by itself.', 'Предлагает сохранить после входа; сам ничего не подставляет.'],
    'editor.sync.cookies.hint': ['Persistent cookies, merged one by one; the newer wins.', 'Постоянные cookies, по одному; побеждает более новое.'],
    'editor.tz.follow.hint': ['The profile runs in the time zone of its exit.', 'Профиль живёт по часовому поясу места выхода.'],
    'editor.errors.show': ['Show', 'Показать'],
    'editor.tab.hasError': ['This section has a field to fix', 'В этом разделе есть поле с ошибкой'],
    'settings.window.hint': ['Settings of this Mac’s app; a profile’s own settings stay in its editor.', 'Настройки приложения на этом Mac; настройки профиля — в его редакторе.'],
    'tunnel.limits.title': ['Limits', 'Ограничения'],
    'changepw.rule.ok': ['At least 10 characters', 'Не менее 10 символов'],
  };

  const lang = (() => {
    const q = new URLSearchParams(globalThis.location ? location.search : '');
    const v = (q.get('lang') || '').toLowerCase();
    return v === 'en' ? 'en' : 'ru'; // Russian is the app's default
  })();
  const index = lang === 'en' ? 0 : 1;
  const markNew = globalThis.location ? new URLSearchParams(location.search).get('marknew') === '1' : false;

  /// String(format:) for the %ld / %@ / %1$ld patterns the app's strings use.
  function format(template, ...args) {
    let next = 0;
    return template.replace(/%(?:(\d)\$)?(ld|@|d)/g, (_, position) => {
      const value = position ? args[Number(position) - 1] : args[next++];
      return value === undefined ? '' : String(value);
    });
  }

  function L_(key, ...args) {
    const entry = EXISTING[key] || NEW[key];
    if (!entry) return key;
    return format(entry[index], ...args);
  }

  /// The same, as HTML: new strings get a marker the page can outline (?marknew=1).
  function H(key, ...args) {
    const text = escapeHTML(L_(key, ...args));
    return NEW[key] && markNew ? `<span class="new-string" title="NEW: ${key}">${text}</span>` : text;
  }

  function escapeHTML(s) {
    return String(s).replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
  }

  L.lang = lang;
  L.L = L_;
  L.H = H;
  L.isNewString = (key) => key in NEW;
  L.strings = { EXISTING, NEW };
  L.escapeHTML = escapeHTML;
  L.format = format;
})(globalThis.Lumen = globalThis.Lumen || {});
