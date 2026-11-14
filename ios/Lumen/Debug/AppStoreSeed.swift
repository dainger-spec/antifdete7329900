#if DEBUG
import Foundation
import LumenCore

/// The App Store's screenshots (DEBUG builds only; ios/LumenUITests/ScreenshotTests.swift, run by hand
/// with the suite "ScreenshotTests"): a person's list as it looks after some weeks of work — sessions
/// with their proxies, each proxy checked — written at launch over the state a reset left empty.
///
/// The proxies' names are under `.example` (reserved, RFC 2606) and their exit addresses in the
/// documentation ranges (RFC 5737): nobody's real ones. Only Berlin works: on the CI Mac its name
/// points at the testbed (ci.sh), whose demo proxy takes `berlin`/`demo`, so its session can show a page.
enum AppStoreSeed {
    static var active: Bool { ProcessInfo.processInfo.environment["LUMEN_TEST_SEED"] == "appstore" }

    static func write(to store: LumenStore) {
        // The empty app (k-empty, p8-empty): nothing at all.
        if ProcessInfo.processInfo.environment["LUMEN_TEST_SEED_EMPTY"] == "1" {
            store.saveProxies([])
            store.saveSessions([])
            return
        }
        let english = ProcessInfo.processInfo.environment["LUMEN_TEST_LANGUAGE"] == "en"
        func t(_ ru: String, _ en: String) -> String { english ? en : ru }
        let now = Date()
        func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }
        func checked(_ ip: String, _ country: String, _ zone: String, udp: UDPSupport) -> ProxyCheck {
            ProxyCheck(checkedAt: ago(4), alive: true, exitIP: ip, country: country, timeZone: zone, udp: udp)
        }

        let berlin = ProxyEntry(name: t("Берлин", "Berlin"), kind: .http, host: "de.proxy.example", port: 8080,
                                username: "berlin", hasPassword: true,
                                check: checked("203.0.113.24", "DE", "Europe/Berlin", udp: .unsupported))
        let paris = ProxyEntry(name: t("Париж", "Paris"), kind: .socks5, host: "fr.proxy.example", port: 1080,
                               username: "paris", hasPassword: true,
                               check: checked("198.51.100.17", "FR", "Europe/Paris", udp: .supported))
        let newYork = ProxyEntry(name: t("Нью-Йорк", "New York"), kind: .socks5, host: "us.proxy.example", port: 1080,
                                 username: "nyc", hasPassword: true,
                                 check: checked("192.0.2.41", "US", "America/New_York", udp: .supported))
        // Amsterdam does not answer (nothing listens on its port on the CI Mac): its session shows p3-dead.
        let amsterdam = ProxyEntry(name: t("Амстердам", "Amsterdam"), kind: .http, host: "nl.proxy.example", port: 3128,
                                   username: "ams", hasPassword: true,
                                   check: ProxyCheck(checkedAt: ago(6), alive: false, error: t("сервер не ответил за 10 секунд",
                                                                                                 "the server did not answer in 10 seconds")))
        let tokyo = ProxyEntry(name: t("Токио", "Tokyo"), kind: .socks5, host: "jp.proxy.example", port: 1080,
                               username: "tokyo", hasPassword: true,
                               check: checked("198.51.100.230", "JP", "Asia/Tokyo", udp: .supported))
        let proxies = [berlin, paris, newYork, amsterdam, tokyo]
        store.saveProxies(proxies)
        for proxy in proxies { ProxyPasswords.set(proxy.id == berlin.id ? "demo" : "screenshot", for: proxy.id) }

        var fromMac = Session(name: t("Поддержка — тикет 4821", "Support — ticket 4821"), notes: t("Пришла с Mac", "Came from the Mac"),
                              proxyID: newYork.id, createdAt: ago(60 * 24 * 4), lastOpenedAt: ago(60 * 22))
        fromMac.syncedProfileID = UUID()
        let sessions = [fromMac, 
            Session(name: t("Магазин — Берлин", "Store — Berlin"), notes: t("Корзина и оплата", "Cart and checkout"),
                    tags: [t("магазин", "store"), "de"], proxyID: berlin.id, createdAt: ago(60 * 24 * 20), lastOpenedAt: ago(12)),
            Session(name: t("Клиент — Париж", "Client — Paris"), notes: t("Лендинг для Франции", "Landing page for France"),
                    tags: [t("клиент", "client"), "fr"], proxyID: paris.id, createdAt: ago(60 * 24 * 14), lastOpenedAt: ago(130)),
            Session(name: t("QA — США", "QA — US"), notes: t("Регион, валюта, часовой пояс", "Region, currency, time zone"),
                    tags: ["qa", "us"], proxyID: newYork.id, createdAt: ago(60 * 24 * 9), lastOpenedAt: ago(60 * 26)),
            Session(name: t("Релиз — Амстердам", "Release — Amsterdam"), notes: t("Проверка перед выкладкой", "Checks before the release"),
                    tags: [t("релиз", "release"), "nl"], proxyID: amsterdam.id, createdAt: ago(60 * 24 * 6), lastOpenedAt: ago(60 * 24 * 3)),
            Session(name: t("Мобильная версия — Токио", "Mobile site — Tokyo"), notes: t("Вёрстка на японском", "Japanese layout"),
                    tags: ["jp"], proxyID: tokyo.id, createdAt: ago(60 * 24 * 2)),
            Session(name: t("Личное", "Personal"), createdAt: ago(60 * 24 * 30), lastOpenedAt: ago(60 * 24 * 7)),
        ]
        store.saveSessions(sessions)
    }
}
#endif
