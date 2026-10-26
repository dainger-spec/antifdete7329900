import AppKit
import BrowserCore
import CryptoKit
import WebKit

/// `PrivacyBrowser --self-test`: headless end-to-end checks against the real WebKit of the
/// running macOS, in the real (sandboxed or not) process. Exit code 0 = all checks passed.
///
/// Unit tests cover the platform-independent core. This covers what only WebKit can answer:
///   * where WebKit actually stores identifier-based data stores (the undocumented layout),
///   * that cookies, localStorage and IndexedDB survive seal → restore,
///   * that two running profiles do not see each other's data,
///   * that the JavaScript shims behave under JavaScriptCore,
///   * per-profile proxies (HTTP CONNECT, SOCKS5 with remote DNS), fail-closed behaviour, the
///     proxy check and the error page for a broken proxy,
///   * the tab model with history recording and bookmarks, and saved/restored tabs,
///   * user agent modes and the per-profile language,
///   * cookie import/export through WebKit's cookie store,
///   * profile duplication and export → import of a profile with its website data.
///
/// Proxy checks need `scripts/selftest_proxy.py` and the env vars
/// `PB_SELFTEST_HTTP_PROXY_PORT` / `PB_SELFTEST_SOCKS_PROXY_PORT`; they are skipped otherwise.
/// Everything is created in a temporary vault and removed afterwards.
@MainActor
final class SelfTest {
    private var failures = 0
    private var passes = 0
    private let origin = URL(string: "https://selftest.invalid/")!
    private let page = "<html><head><title>PB self-test</title></head><body>self-test</body></html>"

    static func start() {
        setvbuf(stdout, nil, _IOLBF, 0)
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        DispatchQueue.main.asyncAfter(deadline: .now() + 300) {
            print("SELFTEST TIMEOUT after 300 s")
            exit(3)
        }
        Task { @MainActor in
            let test = SelfTest()
            await test.run()
            print("SELFTEST \(test.failures == 0 ? "PASSED" : "FAILED"): \(test.passes) passed, \(test.failures) failed")
            exit(test.failures == 0 ? 0 : 1)
        }
        app.run()
    }

    // MARK: Container migration check (two processes)

    /// `--selftest-write-vault` (run by an unsandboxed build) creates a small vault at the
    /// default location; `--selftest-read-vault` (run by the sandboxed build of the same bundle
    /// ID, first launch) checks that macOS moved it into the container per container-migration.plist.
    static func migrationStep(write: Bool) -> Never {
        setvbuf(stdout, nil, _IOLBF, 0)
        let root = AppEnvironment.vaultDirectory
        let password = "migration-check"
        do {
            if write {
                guard !AppEnvironment.isSandboxed else { throw CoreError.invalidConfiguration("run the unsandboxed build") }
                let repository = try ProfileRepository(vault: MasterVault.create(in: root, password: password, iterations: 10_000))
                try repository.create(name: "Migrated", configuration: ProfileConfiguration())
                print("PASS wrote vault at \(root.path)")
            } else {
                guard AppEnvironment.isSandboxed else { throw CoreError.invalidConfiguration("run the sandboxed build") }
                let repository = try ProfileRepository(vault: MasterVault.unlock(in: root, password: password))
                guard repository.list().map(\.name) == ["Migrated"], root.path.contains("/Library/Containers/") else {
                    throw CoreError.corruptData("unexpected vault contents at \(root.path)")
                }
                print("PASS migrated vault unlocked inside the container at \(root.path)")
            }
            exit(0)
        } catch {
            print("FAIL container migration step (\(write ? "write" : "read")): \(error)")
            exit(1)
        }
    }

    // MARK: Reporting

    private func check(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
        if condition {
            passes += 1
            print("PASS \(name)")
        } else {
            failures += 1
            let extra = detail()
            print("FAIL \(name)\(extra.isEmpty ? "" : " — \(extra)")")
        }
    }

    private func info(_ text: String) { print("INFO \(text)") }

    // MARK: Run

    private func run() async {
        let layout = WebDataStoreVault.layout
        info("sandboxed=\(AppEnvironment.isSandboxed) bundle=\(layout.bundleID) library=\(layout.library.path)")
        info("macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        environmentChecks()

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pb-selftest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            let repository = try ProfileRepository(vault: MasterVault.create(in: root, password: "self-test", iterations: 10_000))
            try await storageIsolationAndShims(repository)
            try await userAgentModesAndLocale(repository)
            try await cookieTransfer(repository)
            try await duplicateAndBackup(repository)
            try await recoverySealing(repository)
            try await proxies(repository)
            try await tabsAndLibrary(repository)
            try await sessionRestore(repository)
            try await windowLifecycle(repository)
        } catch {
            check("self-test ran without unexpected errors", false, String(describing: error))
        }
    }

    // MARK: Sandbox / environment

    private func environmentChecks() {
        let sandboxed = AppEnvironment.isSandboxed
        let vaultPath = AppEnvironment.vaultDirectory.path
        check("vault location matches sandbox state", vaultPath.contains("/Library/Containers/") == sandboxed, vaultPath)
        // Probe: a sandboxed process must not be able to write into the real home directory.
        if let home = getpwuid(getuid())?.pointee.pw_dir.map({ String(cString: $0) }) {
            let probe = URL(fileURLWithPath: home).appendingPathComponent(".pb-sandbox-probe-\(UUID().uuidString)")
            let wrote = FileManager.default.createFile(atPath: probe.path, contents: Data("x".utf8))
            if wrote { try? FileManager.default.removeItem(at: probe) }
            check(sandboxed ? "sandbox blocks writes outside the container" : "unsandboxed build can write to home",
                  wrote != sandboxed, "wrote=\(wrote)")
        }
    }

    // MARK: Storage, isolation, shims

    private func storageIsolationAndShims(_ repository: ProfileRepository) async throws {
        let vault = WebDataStoreVault(repository: repository)
        var configA = ProfileConfiguration()
        configA.userAgentMode = .custom
        configA.userAgent = "PrivacyBrowserSelfTest/1.0"
        configA.geolocation = .fixed(latitude: 48.8566, longitude: 2.3522, accuracyMeters: 25)
        configA.timeZoneIdentifier = "Asia/Tokyo"
        configA.webRTCPolicy = .disabled
        let a = try repository.create(name: "SelfTest A", configuration: configA)
        var configB = ProfileConfiguration()
        configB.webRTCPolicy = .relayOnly
        let b = try repository.create(name: "SelfTest B", configuration: configB)
        do {
            try await storageChecks(repository, vault: vault, a: a.id, b: b.id)
        } catch {
            await vault.deleteData(profileID: a.id)
            await vault.deleteData(profileID: b.id)
            throw error
        }
        await vault.deleteData(profileID: a.id)
        await vault.deleteData(profileID: b.id)
    }

    private func storageChecks(_ repository: ProfileRepository, vault: WebDataStoreVault, a: UUID, b: UUID) async throws {
        let layout = WebDataStoreVault.layout
        let keyA = try repository.profileKey(for: a)
        let keyB = try repository.profileKey(for: b)
        let token = UUID().uuidString

        // --- Profile A, first run: write data, check shims.
        try await vault.prepareForLaunch(profileID: a, key: keyA)
        var sessionA: BrowserSession? = try makeSession(repository, a, key: keyA)
        var webA: WKWebView? = WKWebView(frame: .zero, configuration: sessionA!.makeWebViewConfiguration())
        webA!.customUserAgent = "PrivacyBrowserSelfTest/1.0"
        try await PageLoader.load(webA!, html: page, baseURL: origin)

        check("shim: getTimezoneOffset in Asia/Tokyo",
              try await js(webA!, "return new Date(Date.UTC(2024, 0, 15, 12)).getTimezoneOffset();") as? Int == -540)
        check("shim: Intl default time zone",
              try await js(webA!, "return Intl.DateTimeFormat().resolvedOptions().timeZone;") as? String == "Asia/Tokyo")
        check("shim: local getters use profile zone",
              try await js(webA!, "return new Date(Date.UTC(2024, 0, 15, 20)).getHours();") as? Int == 5)
        check("shim: WebRTC disabled",
              try await js(webA!, "return typeof RTCPeerConnection;") as? String == "undefined")
        let coords = try await js(webA!, """
            return await new Promise((resolve) => navigator.geolocation.getCurrentPosition(
              (p) => resolve(p.coords.latitude + ',' + p.coords.longitude), (e) => resolve('error ' + e.code)));
            """) as? String
        check("shim: fixed geolocation", coords == "48.8566,2.3522", coords ?? "nil")
        check("native: custom user agent",
              try await js(webA!, "return navigator.userAgent;") as? String == "PrivacyBrowserSelfTest/1.0")

        check("write localStorage + IndexedDB", try await js(webA!, """
            localStorage.setItem('pb', token);
            await new Promise((resolve, reject) => {
              const req = indexedDB.open('pb', 1);
              req.onupgradeneeded = () => req.result.createObjectStore('s');
              req.onerror = () => reject(req.error);
              req.onsuccess = () => {
                const db = req.result;
                const tx = db.transaction('s', 'readwrite');
                tx.objectStore('s').put(token, 'k');
                tx.oncomplete = () => { db.close(); resolve(); };
                tx.onerror = () => reject(tx.error);
              };
            });
            return true;
            """, ["token": token]) as? Bool == true)
        let cookie = HTTPCookie(properties: [.domain: "selftest.invalid", .path: "/", .name: "pb", .value: token,
                                             .secure: "TRUE", .expires: Date().addingTimeInterval(3_600)])!
        await setCookie(cookie, in: sessionA!.dataStore!)

        // --- Profile B running at the same time: must not see A's data.
        try await vault.prepareForLaunch(profileID: b, key: keyB)
        var sessionB: BrowserSession? = try makeSession(repository, b, key: keyB)
        var webB: WKWebView? = WKWebView(frame: .zero, configuration: sessionB!.makeWebViewConfiguration())
        try await PageLoader.load(webB!, html: page, baseURL: origin)
        check("isolation: localStorage not shared",
              try await js(webB!, "return localStorage.getItem('pb') ?? 'null';") as? String == "null")
        check("isolation: IndexedDB not shared", try await js(webB!, Self.readIndexedDB) as? String == "missing")
        let cookiesB = await cookies(in: sessionB!.dataStore!)
        check("isolation: cookies not shared", !cookiesB.contains { $0.name == "pb" })
        check("isolation: profile B keeps host time zone",
              try await js(webB!, "return Intl.DateTimeFormat().resolvedOptions().timeZone;") as? String != "Asia/Tokyo")
        let nativeRTC = try await js(webB!, "return typeof RTCPeerConnection;") as? String
        if nativeRTC == "function" {
            let policy = try await js(webB!, "return new RTCPeerConnection({ iceTransportPolicy: 'all' }).getConfiguration().iceTransportPolicy;") as? String
            check("shim: WebRTC relay-only under JavaScriptCore", policy == "relay", policy ?? "nil")
        } else {
            info("WKWebView exposes no RTCPeerConnection here (typeof = \(nativeRTC ?? "nil")); relay check skipped")
        }

        // --- Stop A: release everything, seal.
        webA = nil
        sessionA?.shutDown()
        sessionA = nil
        let sealed = try await vault.seal(profileID: a, key: keyA)
        check("WebKit directories found by UUID", !sealed.directories.isEmpty,
              "nothing found under \(layout.searchRoots.map(\.path))")
        for directory in sealed.directories {
            let label = (try? layout.label(for: directory)) ?? "?"
            info("WebKit data directory: \(directory.path)  label=\(label)")
            let roundTrip = try? layout.destination(forLabel: label, profileID: a)
            check("layout round-trips \(label)", roundTrip?.standardizedFileURL.path == directory.standardizedFileURL.path,
                  roundTrip?.path ?? "nil")
        }
        info("sealed \(sealed.stats.files) files, \(sealed.stats.bytes) bytes in \(sealed.attempts) attempt(s)")
        check("plaintext removed after seal", layout.discoverDirectories(for: a).isEmpty)
        let archive = (try? Data(contentsOf: repository.webDataArchiveURL(for: a))) ?? Data()
        check("archive written", archive.count > 64, "\(archive.count) bytes")
        check("archive does not contain the token in plaintext", archive.range(of: Data(token.utf8)) == nil)

        // --- Relaunch A: restore and read back.
        try await vault.prepareForLaunch(profileID: a, key: keyA)
        check("data restored into WebKit directories", !layout.discoverDirectories(for: a).isEmpty)
        sessionA = try makeSession(repository, a, key: keyA)
        webA = WKWebView(frame: .zero, configuration: sessionA!.makeWebViewConfiguration())
        try await PageLoader.load(webA!, html: page, baseURL: origin)
        let restoredLocal = try await js(webA!, "return localStorage.getItem('pb') ?? 'null';") as? String
        check("restore: localStorage", restoredLocal == token, restoredLocal ?? "nil")
        let restoredIDB = try await js(webA!, Self.readIndexedDB) as? String
        check("restore: IndexedDB", restoredIDB == token, restoredIDB ?? "nil")
        let restoredCookies = await cookies(in: sessionA!.dataStore!)
        check("restore: cookie", restoredCookies.contains { $0.name == "pb" && $0.value == token },
              restoredCookies.map(\.name).joined(separator: ","))

        // --- Stop both and seal again.
        webA = nil
        sessionA?.shutDown()
        sessionA = nil
        webB = nil
        sessionB?.shutDown()
        sessionB = nil
        try await vault.seal(profileID: a, key: keyA)
        try await vault.seal(profileID: b, key: keyB)
        check("both profiles sealed", layout.discoverDirectories(for: a).isEmpty && layout.discoverDirectories(for: b).isEmpty)
    }

    private static let readIndexedDB = """
        return await new Promise((resolve) => {
          const req = indexedDB.open('pb', 1);
          req.onupgradeneeded = () => req.result.createObjectStore('s');
          req.onerror = () => resolve('open-error');
          req.onsuccess = () => {
            const db = req.result;
            const get = db.transaction('s', 'readonly').objectStore('s').get('k');
            get.onsuccess = () => { db.close(); resolve(get.result === undefined ? 'missing' : String(get.result)); };
            get.onerror = () => { db.close(); resolve('read-error'); };
          };
        });
        """

    // MARK: Proxies

    private func proxies(_ repository: ProfileRepository) async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let httpPort = environment["PB_SELFTEST_HTTP_PROXY_PORT"].flatMap(Int.init),
              let socksPort = environment["PB_SELFTEST_SOCKS_PROXY_PORT"].flatMap(Int.init) else {
            info("proxy checks skipped (PB_SELFTEST_HTTP_PROXY_PORT / PB_SELFTEST_SOCKS_PROXY_PORT not set)")
            return
        }
        let target = URL(string: "http://proxied.selftest.invalid/check")!

        let httpBody = try await loadThroughProxy(repository, ProxySettings(kind: .httpConnect, host: "127.0.0.1", port: httpPort), url: target)
        check("proxy: HTTP proxy carries the request", httpBody?.contains("PB-PROXY-OK") == true, httpBody ?? "load failed")
        info("HTTP proxy response: \(httpBody ?? "nil")")

        let socksBody = try await loadThroughProxy(repository, ProxySettings(kind: .socks5, host: "127.0.0.1", port: socksPort), url: target)
        check("proxy: SOCKS5 carries the request", socksBody?.contains("PB-PROXY-OK via=socks5") == true, socksBody ?? "load failed")
        check("proxy: SOCKS5 receives the hostname (remote DNS)", socksBody?.contains("atyp=3") == true, socksBody ?? "nil")

        // Port 9 (discard) on localhost is closed on CI runners: the load must fail, not go direct.
        let direct = try await loadThroughProxy(repository, ProxySettings(kind: .httpConnect, host: "127.0.0.1", port: 9),
                                                url: URL(string: "http://example.com/")!)
        check("proxy: fail-closed when the proxy is unreachable", direct == nil, "page loaded: \(direct ?? "")")

        // The proxy check: a closed port is reported as a proxy problem, a working proxy as working.
        let broken = ProxySettings(kind: .socks5, host: "127.0.0.1", port: 9)
        let brokenStatus = await ProxyChecker.check(broken, timeout: 8)
        if case .failed(let message) = brokenStatus {
            check("proxy check: unreachable proxy is a proxy problem", message.kind == .proxy, message.technical)
        } else {
            check("proxy check: unreachable proxy is a proxy problem", false, ProxyStatusCenter.describe(brokenStatus))
        }
        let working = await ProxyChecker.check(ProxySettings(kind: .httpConnect, host: "127.0.0.1", port: httpPort),
                                               probe: URL(string: "http://proxied.selftest.invalid/probe")!, timeout: 8)
        if case .working = working {
            check("proxy check: working proxy answers", true)
        } else {
            check("proxy check: working proxy answers", false, ProxyStatusCenter.describe(working))
        }

        // A tab of a profile whose proxy is down: friendly error page, proxy status failed, no crash.
        let profile = try repository.create(name: "Broken proxy", configuration: ProfileConfiguration(proxy: broken, ephemeral: true))
        let session = try makeSession(repository, profile.id, key: repository.profileKey(for: profile.id))
        defer { session.shutDown() }
        let center = ProxyStatusCenter()
        session.onLoadFailed = { center.reportLoadFailed(profile.id, message: $0) }
        let controller = BrowserWindowController(session: session) // never shown
        controller.addTab(url: URL(string: "https://example.com/")!)
        let failed = await waitUntil(timeout: 20) { controller.selectedTab?.failedURL != nil }
        check("broken proxy: error page instead of the site", failed,
              controller.selectedTab?.url?.absoluteString ?? "nil")
        check("broken proxy: address bar keeps the address", controller.selectedTab?.url?.host == "example.com")
        check("broken proxy: status is failed", center.status(for: profile.id, hasProxy: true).isFailure,
              ProxyStatusCenter.describe(center.status(for: profile.id, hasProxy: true)))
        // The error page is loaded with loadHTMLString (async), so poll its body for the retry
        // label rather than reading once — reading immediately races the load (flaky).
        var pageText = ""
        for _ in 0..<50 {
            pageText = (try? await js(controller.selectedTab!.webView,
                                      "return document.body ? document.body.innerText : '';")) as? String ?? ""
            if pageText.contains(L("errorpage.retry")) { break }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        check("broken proxy: error page explains it with a retry link", pageText.contains(L("errorpage.retry")), pageText)
        controller.close()
    }

    /// Loads `url` in an ephemeral profile using `proxy`. Returns the page text, or nil if the load failed.
    private func loadThroughProxy(_ repository: ProfileRepository, _ proxy: ProxySettings, url: URL) async throws -> String? {
        let profile = try repository.create(name: "Proxy \(proxy.kind.rawValue)",
                                            configuration: ProfileConfiguration(proxy: proxy, ephemeral: true))
        let session = try makeSession(repository, profile.id, key: repository.profileKey(for: profile.id))
        defer { session.shutDown() }
        let webView = WKWebView(frame: .zero, configuration: session.makeWebViewConfiguration())
        do {
            try await PageLoader.load(webView, url: url)
        } catch {
            info("load of \(url.absoluteString) via \(proxy.kind.rawValue) :\(proxy.port) failed: \(error.localizedDescription)")
            return nil
        }
        return try await js(webView, "return document.body ? document.body.innerText : '';") as? String
    }

    // MARK: Tabs, history, bookmarks

    private func tabsAndLibrary(_ repository: ProfileRepository) async throws {
        guard let httpPort = ProcessInfo.processInfo.environment["PB_SELFTEST_HTTP_PROXY_PORT"].flatMap(Int.init) else {
            info("tab/history checks skipped (need the self-test proxy to serve pages)")
            return
        }
        let profile = try repository.create(name: "Tabs", configuration: ProfileConfiguration(
            proxy: ProxySettings(kind: .httpConnect, host: "127.0.0.1", port: httpPort), ephemeral: true))
        let session = try makeSession(repository, profile.id, key: repository.profileKey(for: profile.id))
        defer { session.shutDown() }
        let one = URL(string: "http://proxied.selftest.invalid/one")!
        let two = URL(string: "http://proxied.selftest.invalid/two")!

        let controller = BrowserWindowController(session: session) // never shown
        controller.addTab(url: one)
        controller.addTab(url: two)
        let loaded = await waitUntil(timeout: 20) {
            controller.tabs.count == 2 && controller.tabs.allSatisfy { !$0.isLoading && $0.webView.title?.hasPrefix("PB proxied") == true }
        }
        check("tabs: two tabs loaded", loaded, controller.tabs.map { "\($0.url?.absoluteString ?? "nil") \($0.webView.title ?? "")" }.joined(separator: ", "))
        check("tabs: new tab is selected", controller.selectedTab?.url == two, controller.selectedTab?.url?.absoluteString ?? "nil")

        let history = session.library.historyEntries(matching: "")
        check("history: visits recorded", Set(history.map(\.url)).isSuperset(of: [one.absoluteString, two.absoluteString]),
              history.map(\.url).joined(separator: ", "))
        check("history: titles recorded", history.first { $0.url == two.absoluteString }?.title == "PB proxied /two",
              history.map(\.title).joined(separator: ", "))

        controller.toggleBookmark()
        check("bookmarks: current page bookmarked", session.library.bookmark(for: two) != nil)
        let reloadedBookmarks = try repository.bookmarkStore(for: profile.id, key: repository.profileKey(for: profile.id))
        check("bookmarks: persisted encrypted", reloadedBookmarks.bookmark(for: two) != nil)
        controller.toggleBookmark()
        check("bookmarks: toggle removes", session.library.bookmark(for: two) == nil)

        controller.closeSelectedTab()
        check("tabs: close tab", controller.tabCount == 1 && controller.selectedTab?.url == one)
        controller.reopenClosedTab()
        // The URL of a new navigation is published asynchronously.
        let reopened = await waitUntil(timeout: 10) { controller.tabCount == 2 && controller.selectedTab?.url == two }
        check("tabs: reopen closed tab", reopened, controller.selectedTab?.url?.absoluteString ?? "nil")
        controller.selectTab(number: 1)
        check("tabs: select tab 1", controller.selectedTab?.url == one)
        controller.close()
    }

    // MARK: User agent modes and language

    /// The user agent mode and the language reach the page through the normal session → tab
    /// wiring: Safari for Mac = WebKit's UA plus Safari's "Version/x Safari/605.1.15"; iPhone =
    /// the iPhone UA string; custom = exactly the string; locale = navigator.language and Intl.
    private func userAgentModesAndLocale(_ repository: ProfileRepository) async throws {
        func probe(_ configuration: ProfileConfiguration, _ script: String) async throws -> Any? {
            let profile = try repository.create(name: "UA \(UUID().uuidString.prefix(4))", configuration: configuration)
            let session = try makeSession(repository, profile.id, key: repository.profileKey(for: profile.id))
            defer { session.shutDown() }
            let tab = BrowserTab(configuration: session.makeWebViewConfiguration(), context: session.tabContext)
            defer { tab.tearDown() }
            try await PageLoader.load(tab.webView, html: page, baseURL: origin)
            return try await js(tab.webView, script)
        }
        var config = ProfileConfiguration(ephemeral: true)

        let macUA = try await probe(config, "return navigator.userAgent;") as? String
        info("Safari version used for the UA: \(SafariInfo.version.string)")
        check("ua: Safari for Mac sends Safari's UA",
              macUA?.contains("Macintosh") == true && macUA?.hasSuffix("Version/\(SafariInfo.version.uaVersionToken) Safari/605.1.15") == true,
              macUA ?? "nil")

        config.userAgentMode = .iPhone
        let phoneUA = try await probe(config, "return navigator.userAgent;") as? String
        check("ua: iPhone mode sends an iPhone UA", phoneUA?.contains("iPhone") == true, phoneUA ?? "nil")

        config.userAgentMode = .custom
        config.userAgent = "PrivacyBrowserSelfTest/UA-Custom"
        let customUA = try await probe(config, "return navigator.userAgent;") as? String
        check("ua: custom string is sent as is", customUA == "PrivacyBrowserSelfTest/UA-Custom", customUA ?? "nil")

        var german = ProfileConfiguration(ephemeral: true)
        german.locale = "de-DE"
        let language = try await probe(german, "return [navigator.language, navigator.languages.join(','), Intl.NumberFormat().resolvedOptions().locale, (1234.5).toLocaleString()].join('|');") as? String
        let parts = language?.split(separator: "|").map(String.init) ?? []
        check("locale: navigator.language follows the profile", parts.first == "de-DE", language ?? "nil")
        check("locale: navigator.languages holds only the primary language", parts.count > 1 && parts[1] == "de-DE", language ?? "nil")
        check("locale: Intl and toLocaleString use it", parts.count > 3 && parts[2].hasPrefix("de") && parts[3] == "1.234,5",
              language ?? "nil")
    }

    // MARK: Cookie import / export

    private func cookieTransfer(_ repository: ProfileRepository) async throws {
        let profile = try repository.create(name: "Cookies", configuration: ProfileConfiguration(ephemeral: true))
        let session = try makeSession(repository, profile.id, key: repository.profileKey(for: profile.id))
        defer { session.shutDown() }
        let expiry = Int(Date().addingTimeInterval(86_400).timeIntervalSince1970)
        let netscape = """
            # Netscape HTTP Cookie File
            .selftest.invalid\tTRUE\t/\tTRUE\t\(expiry)\tpb_visible\tv1
            #HttpOnly_selftest.invalid\tFALSE\t/\tTRUE\t\(expiry)\tpb_http_only\tv2
            selftest.invalid\tFALSE\t/\tTRUE\t1000\tpb_expired\tv3
            this line is not a cookie
            """
        guard let store = session.dataStore?.httpCookieStore else { throw CoreError.io("no data store") }
        let result = try await CookieService.importCookies(Data(netscape.utf8), into: store)
        check("cookies: import counts", result.imported == 2 && result.skipped == 2,
              "imported=\(result.imported) skipped=\(result.skipped)")
        let tab = BrowserTab(configuration: session.makeWebViewConfiguration(), context: session.tabContext)
        defer { tab.tearDown() }
        try await PageLoader.load(tab.webView, html: page, baseURL: origin)
        let visible = try await js(tab.webView, "return document.cookie;") as? String ?? ""
        check("cookies: imported cookie reaches the page", visible.contains("pb_visible=v1"), visible)
        check("cookies: HttpOnly stays hidden from scripts", !visible.contains("pb_http_only"), visible)
        let stored = await cookies(in: session.dataStore!)
        check("cookies: HttpOnly cookie is in the store", stored.contains { $0.name == "pb_http_only" && $0.isHTTPOnly },
              stored.map(\.name).joined(separator: ","))

        let (json, count) = try await CookieService.exportCookies(from: store, format: .json)
        let reparsed = try CookieTransfer.parse(json)
        check("cookies: JSON export round-trips", count >= 2 && Set(reparsed.cookies.map(\.name)).isSuperset(of: ["pb_visible", "pb_http_only"]),
              "count=\(count)")
        let (text, _) = try await CookieService.exportCookies(from: store, format: .netscape)
        check("cookies: Netscape export keeps HttpOnly", String(decoding: text, as: UTF8.self).contains("#HttpOnly_"))

        let other = try repository.create(name: "Cookies B", configuration: ProfileConfiguration(ephemeral: true))
        let otherSession = try makeSession(repository, other.id, key: repository.profileKey(for: other.id))
        defer { otherSession.shutDown() }
        let otherCookies = await cookies(in: otherSession.dataStore!)
        check("cookies: import stays in its profile", !otherCookies.contains { $0.name.hasPrefix("pb_") })
    }

    // MARK: Duplicate and export / import of a profile

    private func duplicateAndBackup(_ repository: ProfileRepository) async throws {
        let vault = WebDataStoreVault(repository: repository)
        var config = ProfileConfiguration()
        config.locale = "fr-FR"
        let source = try repository.create(name: "Backup source", configuration: config)
        let key = try repository.profileKey(for: source.id)
        let token = UUID().uuidString
        var cleanup = [source.id]
        defer { for id in cleanup { Task { @MainActor in await vault.deleteData(profileID: id) } } }

        // Run the source once, store a value, stop and seal it.
        try await vault.prepareForLaunch(profileID: source.id, key: key)
        var session: BrowserSession? = try makeSession(repository, source.id, key: key)
        var web: WKWebView? = WKWebView(frame: .zero, configuration: session!.makeWebViewConfiguration())
        try await PageLoader.load(web!, html: page, baseURL: origin)
        _ = try await js(web!, "localStorage.setItem('pb', token); return true;", ["token": token])
        web = nil
        session?.shutDown()
        session = nil
        try await vault.seal(profileID: source.id, key: key)

        // Duplicate: same settings, nothing of the data.
        let copy = try repository.duplicate(source.id, name: "Backup copy")
        cleanup.append(copy.id)
        let copyKey = try repository.profileKey(for: copy.id)
        check("duplicate: same settings", try repository.loadConfiguration(copy.id).locale == "fr-FR")
        try await vault.prepareForLaunch(profileID: copy.id, key: copyKey)
        var copySession: BrowserSession? = try makeSession(repository, copy.id, key: copyKey)
        var copyWeb: WKWebView? = WKWebView(frame: .zero, configuration: copySession!.makeWebViewConfiguration())
        try await PageLoader.load(copyWeb!, html: page, baseURL: origin)
        let copyValue = try await js(copyWeb!, "return localStorage.getItem('pb') ?? 'null';") as? String
        check("duplicate: starts with empty site data", copyValue == "null", copyValue ?? "nil")
        // Drop the web view (and with it its data-store reference) before sealing, or WebKit still
        // holds the store and the seal fails with storeStillInUse.
        copyWeb = nil
        copySession?.shutDown()
        copySession = nil
        try await vault.seal(profileID: copy.id, key: copyKey)

        // Export → import as a copy (new id, re-encrypted, WebKit data relabelled) → data is there.
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("pb-selftest-\(UUID().uuidString).pbbackup")
        defer { try? FileManager.default.removeItem(at: file) }
        try ProfileBackup.export(profile: source.id, from: repository, to: file, password: "backup-pass", iterations: 10_000)
        let exported = (try? Data(contentsOf: file)) ?? Data()
        check("backup: file does not contain the token in plaintext", exported.count > 64 && exported.range(of: Data(token.utf8)) == nil)
        let restored = try ProfileBackup.restore(from: file, password: "backup-pass", into: repository, mode: .copy)
        cleanup.append(restored.id)
        check("backup: restored as a new profile", restored.id != source.id)
        let restoredKey = try repository.profileKey(for: restored.id)
        try await vault.prepareForLaunch(profileID: restored.id, key: restoredKey)
        var restoredSession: BrowserSession? = try makeSession(repository, restored.id, key: restoredKey)
        var restoredWeb: WKWebView? = WKWebView(frame: .zero, configuration: restoredSession!.makeWebViewConfiguration())
        try await PageLoader.load(restoredWeb!, html: page, baseURL: origin)
        let restoredValue = try await js(restoredWeb!, "return localStorage.getItem('pb') ?? 'null';") as? String
        check("backup: site data restored into the imported profile", restoredValue == token, restoredValue ?? "nil")
        restoredWeb = nil
        restoredSession?.shutDown()
        restoredSession = nil
        try await vault.seal(profileID: restored.id, key: restoredKey)
        let wrong = (try? ProfileBackup.restore(from: file, password: "wrong", into: repository, mode: .copy)) == nil
        check("backup: wrong password is refused", wrong)
    }

    // MARK: Crash recovery sealing (regression for the post-unlock crash)

    /// Reproduces the crash path: a profile ran and left website data on disk (the process
    /// "crashed" before sealing — here we just drop the session without sealing). Recovery must
    /// archive and delete that data WITHOUT calling `WKWebsiteDataStore.remove(forIdentifier:)`,
    /// which aborts for a store this process never registered, and the data must restore cleanly.
    private func recoverySealing(_ repository: ProfileRepository) async throws {
        let vault = WebDataStoreVault(repository: repository)
        let layout = WebDataStoreVault.layout
        let profile = try repository.create(name: "Recovery", configuration: ProfileConfiguration())
        let key = try repository.profileKey(for: profile.id)
        let token = UUID().uuidString
        defer { Task { @MainActor in await vault.deleteData(profileID: profile.id) } }

        // Run the profile and write a value, then drop the session WITHOUT sealing (simulated crash).
        try await vault.prepareForLaunch(profileID: profile.id, key: key)
        var session: BrowserSession? = try makeSession(repository, profile.id, key: key)
        var web: WKWebView? = WKWebView(frame: .zero, configuration: session!.makeWebViewConfiguration())
        try await PageLoader.load(web!, html: page, baseURL: origin)
        _ = try await js(web!, "localStorage.setItem('pb', token); return true;", ["token": token])
        web = nil
        session = nil
        check("recovery: unsealed data present after simulated crash",
              !layout.discoverDirectories(for: profile.id).isEmpty)

        // Recovery seal (activeStore: false) must not crash and must archive + delete the data.
        let sealed = try await vault.seal(profileID: profile.id, key: key, activeStore: false)
        check("recovery: sealed without the WebKit removal call", sealed.stats.files > 0 && sealed.attempts == 1,
              "files=\(sealed.stats.files) attempts=\(sealed.attempts)")
        check("recovery: plaintext removed", layout.discoverDirectories(for: profile.id).isEmpty)

        // The recovered archive restores correctly on the next launch.
        try await vault.prepareForLaunch(profileID: profile.id, key: key)
        let session2 = try makeSession(repository, profile.id, key: key)
        let web2 = WKWebView(frame: .zero, configuration: session2.makeWebViewConfiguration())
        try await PageLoader.load(web2, html: page, baseURL: origin)
        let restored = try await js(web2, "return localStorage.getItem('pb') ?? 'null';") as? String
        check("recovery: data restored after recovery seal", restored == token, restored ?? "nil")
        session2.shutDown()
    }

    // MARK: Saved tabs

    /// Open tabs are saved (encrypted) when the profile stops and come back on the next launch;
    /// only the selected tab loads right away.
    private func sessionRestore(_ repository: ProfileRepository) async throws {
        guard let httpPort = ProcessInfo.processInfo.environment["PB_SELFTEST_HTTP_PROXY_PORT"].flatMap(Int.init) else {
            info("saved-tabs checks skipped (need the self-test proxy to serve pages)")
            return
        }
        let vault = WebDataStoreVault(repository: repository)
        let profile = try repository.create(name: "Saved tabs", configuration: ProfileConfiguration(
            proxy: ProxySettings(kind: .httpConnect, host: "127.0.0.1", port: httpPort)))
        let key = try repository.profileKey(for: profile.id)
        defer { Task { @MainActor in await vault.deleteData(profileID: profile.id) } }
        let one = URL(string: "http://proxied.selftest.invalid/saved-one")!
        let two = URL(string: "http://proxied.selftest.invalid/saved-two")!

        try await vault.prepareForLaunch(profileID: profile.id, key: key)
        let session = try makeSession(repository, profile.id, key: key)
        let controller = session.openWindow(url: one)
        controller.addTab(url: two)
        let loaded = await waitUntil(timeout: 20) { controller.tabs.allSatisfy { !$0.isLoading && $0.webView.url != nil } }
        check("saved tabs: two tabs loaded", loaded && controller.tabCount == 2)
        session.shutDown()
        try await vault.seal(profileID: profile.id, key: key)

        let saved = try repository.sessionStore(for: profile.id, key: key).load()
        check("saved tabs: state written on stop", saved?.windows.first?.tabs.map(\.url) == [one.absoluteString, two.absoluteString],
              String(describing: saved?.windows.first?.tabs.map(\.url)))
        check("saved tabs: selected tab remembered", saved?.windows.first?.selectedIndex == 1)
        let sessionFile = repository.directory(for: profile.id).appendingPathComponent("session.bin")
        let raw = (try? Data(contentsOf: sessionFile)) ?? Data()
        check("saved tabs: encrypted on disk", raw.count > 16 && raw.range(of: Data("saved-one".utf8)) == nil, "\(raw.count) bytes")

        try await vault.prepareForLaunch(profileID: profile.id, key: key)
        let again = try makeSession(repository, profile.id, key: key)
        defer { again.shutDown() }
        let restored = saved.map { again.restore($0) } ?? false
        let window = again.frontmostWindow
        check("saved tabs: restored on launch", restored && window?.tabCount == 2, "\(window?.tabCount ?? 0) tabs")
        check("saved tabs: selected tab restored", window?.selectedTab?.url == two)
        check("saved tabs: background tab waits until shown", window?.tabs.first?.webView.url == nil && window?.tabs.first?.url == one)
        _ = await waitUntil(timeout: 20) { window?.selectedTab?.isLoading == false }
        again.shutDown()
        try await vault.seal(profileID: profile.id, key: key)
    }

    // MARK: Window lifecycle (regression test for the close/quit crash)

    /// Closing a profile's last window must (a) not release the window controller while AppKit is
    /// still inside the close (use-after-free → crash), (b) report "all windows closed" on a later
    /// run-loop turn so the profile is stopped, and (c) leave `shutDown()` safe to call twice
    /// (window-close stop and lock/quit can both reach it).
    private func windowLifecycle(_ repository: ProfileRepository) async throws {
        let profile = try repository.create(name: "Lifecycle", configuration: ProfileConfiguration(ephemeral: true))
        let session = try makeSession(repository, profile.id, key: repository.profileKey(for: profile.id))
        var allClosedCalls = 0
        session.onAllWindowsClosed = { allClosedCalls += 1 }

        let first = session.openWindow(url: nil)
        let second = session.openWindow(url: nil)
        check("lifecycle: two windows open", session.windowCount == 2, "\(session.windowCount)")

        first.window?.close()
        let firstGone = await waitUntil(timeout: 5) { session.windowCount == 1 }
        check("lifecycle: closing one window keeps the profile running", firstGone && allClosedCalls == 0,
              "windows=\(session.windowCount) calls=\(allClosedCalls)")

        second.window?.close()
        // The callback is deferred out of windowWillClose, so it must not have run synchronously.
        check("lifecycle: stop callback deferred out of windowWillClose", allClosedCalls == 0)
        let stopped = await waitUntil(timeout: 5) { allClosedCalls == 1 && session.windowCount == 0 }
        check("lifecycle: closing the last window reports all-closed once", stopped,
              "windows=\(session.windowCount) calls=\(allClosedCalls)")

        session.shutDown()
        session.shutDown() // idempotent; must not crash or call back
        check("lifecycle: shutDown is idempotent", allClosedCalls == 1 && session.windowCount == 0)
    }

    // MARK: Helpers

    private func makeSession(_ repository: ProfileRepository, _ id: UUID, key: SymmetricKey) throws -> BrowserSession {
        let configuration = try repository.loadConfiguration(id, key: key)
        let library = ProfileLibrary(
            history: try repository.historyStore(for: id, key: key, policy: configuration.historyPolicy, persistent: !configuration.ephemeral),
            bookmarks: try repository.bookmarkStore(for: id, key: key),
            recordsHistory: configuration.historyEnabled)
        return BrowserSession(profileID: id, profileName: try repository.summary(for: id).name, configuration: configuration,
                              passwordVault: try repository.passwordVault(for: id), library: library,
                              sessionStore: try repository.sessionStore(for: id, key: key, persistent: !configuration.ephemeral))
    }

    private func js(_ webView: WKWebView, _ body: String, _ arguments: [String: Any] = [:]) async throws -> Any? {
        try await withCheckedThrowingContinuation { continuation in
            webView.callAsyncJavaScript(body, arguments: arguments, in: nil, in: .page) { result in
                switch result {
                case .success(let value): continuation.resume(returning: value)
                case .failure(let error): continuation.resume(throwing: error)
                }
            }
        }
    }

    private func setCookie(_ cookie: HTTPCookie, in store: WKWebsiteDataStore) async {
        await withCheckedContinuation { continuation in
            store.httpCookieStore.setCookie(cookie) { continuation.resume() }
        }
    }

    private func cookies(in store: WKWebsiteDataStore) async -> [HTTPCookie] {
        await withCheckedContinuation { continuation in
            store.httpCookieStore.getAllCookies { continuation.resume(returning: $0) }
        }
    }

    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return condition()
    }
}

/// Awaits one main-frame navigation of a web view.
@MainActor
private final class PageLoader: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, Error>?

    struct Timeout: LocalizedError {
        var errorDescription: String? { "navigation timed out" }
    }

    static func load(_ webView: WKWebView, html: String, baseURL: URL) async throws {
        try await PageLoader().run(webView) { $0.loadHTMLString(html, baseURL: baseURL) }
    }

    static func load(_ webView: WKWebView, url: URL) async throws {
        try await PageLoader().run(webView) { $0.load(URLRequest(url: url)) }
    }

    private func run(_ webView: WKWebView, start: (WKWebView) -> Void) async throws {
        webView.navigationDelegate = self
        defer { webView.navigationDelegate = nil }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.continuation = continuation
            start(webView)
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                self?.finish(.failure(Timeout()))
            }
        }
    }

    private func finish(_ result: Result<Void, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(with: result)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finish(.success(()))
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(.failure(error))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(.failure(error))
    }
}
