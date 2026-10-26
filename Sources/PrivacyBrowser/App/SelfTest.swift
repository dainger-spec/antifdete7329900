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
///   * per-profile proxies (HTTP CONNECT, SOCKS5 with remote DNS) and fail-closed behaviour,
///   * the tab model with history recording and bookmarks.
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
                // This writes a REAL vault (password "migration-check") into the real unsandboxed
                // vault folder, which every unsandboxed build shares and which a sandboxed build's
                // first launch moves into its container. Only CI may do that, on a throwaway runner.
                guard ProcessInfo.processInfo.environment["PB_SELFTEST_MIGRATION"] == "1" else {
                    throw CoreError.invalidConfiguration("--selftest-write-vault creates a real vault at \(root.path); it runs only in CI with PB_SELFTEST_MIGRATION=1")
                }
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
            try await firstWebKitUse(repository) // must run before anything else touches WebKit
            try await storageIsolationAndShims(repository)
            try await deviceGenerations(repository)
            try await recoverySealing(repository)
            try await deleteProfiles(repository)
            try await proxies(repository)
            try await tabsAndLibrary(repository)
            try await windowLifecycle(repository)
            try await dialogTeardown(repository)
            try await lockDuringLaunch(repository)
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
        let a = try repository.create(name: "SelfTest A", configuration: ProfileConfiguration(
            userAgent: "PrivacyBrowserSelfTest/1.0",
            geolocation: .fixed(latitude: 48.8566, longitude: 2.3522, accuracyMeters: 25),
            timeZoneIdentifier: "Asia/Tokyo",
            webRTCPolicy: .disabled))
        let b = try repository.create(name: "SelfTest B", configuration: ProfileConfiguration(webRTCPolicy: .relayOnly))
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
        // A pasted "host:port" (or any non-host) must never reach NWEndpoint.Host, and a proxy that
        // cannot be applied must never become a direct connection.
        let pasted = ProxySettings(kind: .socks5, host: "127.0.0.1:1080", port: 1080)
        check("proxy: a host with a port is refused when saving",
              (try? repository.create(name: "Bad proxy", configuration: ProfileConfiguration(proxy: pasted, ephemeral: true))) == nil)
        check("proxy: an unusable proxy never becomes a direct connection", (try? ProxyConfigurationFactory.make(pasted)) == nil)
        let field = try? ProxyHostField.parse(" socks5://u:p@127.0.0.1:1080\n")
        check("proxy: a pasted proxy string is split into host, port and credentials",
              field == ProxyHostField(host: "127.0.0.1", port: 1080, username: "u", password: "p", kind: .socks5),
              String(describing: field))

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

        // A proxy that answers 407: the profile's credentials are sent, wrong ones fail closed.
        // Loaded in a BrowserTab, whose navigation delegate answers the proxy's challenge.
        if let authPort = environment["PB_SELFTEST_HTTP_AUTH_PROXY_PORT"].flatMap(Int.init) {
            let good = try await titleThroughProxyTab(repository, ProxySettings(kind: .httpConnect, host: "127.0.0.1", port: authPort,
                                                                                username: "pb-user", password: "pb-pass"), url: target)
            check("proxy: 407 is answered with the profile's credentials", good?.hasPrefix("PB proxied") == true, good ?? "nil")
            let wrong = try await titleThroughProxyTab(repository, ProxySettings(kind: .httpConnect, host: "127.0.0.1", port: authPort,
                                                                                 username: "pb-user", password: "wrong"), url: target)
            check("proxy: rejected credentials fail closed", wrong?.hasPrefix("PB proxied") != true, wrong ?? "nil")
            let none = try await titleThroughProxyTab(repository, ProxySettings(kind: .httpConnect, host: "127.0.0.1", port: authPort),
                                                      url: target)
            check("proxy: 407 without credentials fails closed", none?.hasPrefix("PB proxied") != true, none ?? "nil")
        } else {
            info("proxy auth checks skipped (PB_SELFTEST_HTTP_AUTH_PROXY_PORT not set)")
        }
    }

    /// Loads `url` in a `BrowserTab` (the app's own navigation delegate, including its auth
    /// handling) of an ephemeral profile using `proxy`; returns the title once the page or the
    /// error page has loaded.
    private func titleThroughProxyTab(_ repository: ProfileRepository, _ proxy: ProxySettings, url: URL) async throws -> String? {
        let profile = try repository.create(name: "Proxy tab", configuration: ProfileConfiguration(proxy: proxy, ephemeral: true))
        let session = try makeSession(repository, profile.id, key: repository.profileKey(for: profile.id))
        defer { session.shutDown() }
        let tab = BrowserTab(configuration: session.makeWebViewConfiguration(), context: session.tabContext)
        defer { tab.tearDown() }
        tab.load(url)
        let errorTitle = L("errorpage.title")
        _ = await waitUntil(timeout: 20) {
            !tab.webView.isLoading && ((tab.webView.title ?? "").hasPrefix("PB proxied") || tab.webView.title == errorTitle)
        }
        info("proxy tab \(proxy.username ?? "-"):\(proxy.password == nil ? "-" : "***") -> \(tab.webView.title ?? "nil")")
        return tab.webView.title
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

    // MARK: Device generations (version-aware UA reaches the page)

    /// A profile tagged with a device generation must apply that generation's self-declared
    /// User-Agent to `navigator.userAgent` through the normal session → tab wiring, and an
    /// explicit custom UA must still win.
    private func deviceGenerations(_ repository: ProfileRepository) async throws {
        func userAgent(for configuration: ProfileConfiguration) async throws -> String? {
            let profile = try repository.create(name: "Gen \(UUID().uuidString.prefix(4))", configuration: configuration)
            let session = try makeSession(repository, profile.id, key: repository.profileKey(for: profile.id))
            defer { session.shutDown() }
            let tab = BrowserTab(configuration: session.makeWebViewConfiguration(), context: session.tabContext)
            try await PageLoader.load(tab.webView, html: page, baseURL: origin)
            return try await js(tab.webView, "return navigator.userAgent;") as? String
        }

        let iosUA = try await userAgent(for: .forGeneration(DeviceGenerations.resolved(id: "ios-26")))
        check("generation: iOS 26 UA reaches navigator.userAgent",
              iosUA?.contains("iPhone OS 26") == true, iosUA ?? "nil")

        let macUA = try await userAgent(for: .forGeneration(DeviceGenerations.resolved(id: DeviceGenerations.defaultID)))
        check("generation: default macOS UA reaches navigator.userAgent",
              macUA?.contains("Macintosh") == true, macUA ?? "nil")

        var override = ProfileConfiguration.forGeneration(DeviceGenerations.resolved(id: "ios-27"))
        override.userAgent = "PrivacyBrowserSelfTest/UA-Override"
        let overrideUA = try await userAgent(for: override)
        check("generation: explicit user agent overrides the generation",
              overrideUA == "PrivacyBrowserSelfTest/UA-Override", overrideUA ?? "nil")
    }

    // MARK: Profile deletion (regression for the delete crash)

    /// `remove(forIdentifier:)` and `WKWebsiteDataStore.nonPersistent()` crash (EXC_BAD_ACCESS on a
    /// nil `RunLoop::main()`) when they are the first WebKit use in the process — e.g. "unlock,
    /// then delete a profile" or "unlock, then open an ephemeral profile". Must run before anything
    /// else touches WebKit.
    private func firstWebKitUse(_ repository: ProfileRepository) async throws {
        let vault = WebDataStoreVault(repository: repository)
        let removalsBefore = WebDataStoreVault.removeCallCount

        // The reported crash: deleting a profile that never ran must not call WebKit at all.
        let fresh = try repository.create(name: "Delete first", configuration: ProfileConfiguration())
        await vault.deleteData(profileID: fresh.id)
        try repository.delete(fresh.id)
        check("first WebKit use: deleting a never-launched profile does not call remove(forIdentifier:)",
              WebDataStoreVault.removeCallCount == removalsBefore && (try? repository.summary(for: fresh.id)) == nil)

        // An ephemeral profile as the first WebKit use: its non-persistent store needs WebKit initialized.
        let ephemeral = try repository.create(name: "Ephemeral first", configuration: ProfileConfiguration(ephemeral: true))
        let session = try makeSession(repository, ephemeral.id, key: repository.profileKey(for: ephemeral.id))
        check("first WebKit use: ephemeral profile starts without crashing", session.dataStore != nil)
        session.shutDown()
        try repository.delete(ephemeral.id)

        // A registered store that never had a web view: removed once, then unregistered.
        let created = try repository.create(name: "Delete store only", configuration: ProfileConfiguration())
        _ = WebDataStoreVault.makeStore(for: created.id)
        await vault.deleteData(profileID: created.id)
        try repository.delete(created.id)
        check("delete: registered store without a web view is removed and unregistered",
              WebDataStoreVault.removeCallCount == removalsBefore + 1 && !WebDataStoreVault.isRegistered(created.id),
              "removals=\(WebDataStoreVault.removeCallCount - removalsBefore) registered=\(WebDataStoreVault.isRegistered(created.id))")
    }

    /// Deleting with WebKit already initialized: a never-launched profile (directory sweep only)
    /// and a profile that ran and was sealed (its store was already removed by the seal, so the
    /// delete only sweeps directories).
    private func deleteProfiles(_ repository: ProfileRepository) async throws {
        let vault = WebDataStoreVault(repository: repository)
        let layout = WebDataStoreVault.layout

        let fresh = try repository.create(name: "Delete fresh", configuration: ProfileConfiguration())
        await vault.deleteData(profileID: fresh.id)
        try repository.delete(fresh.id)
        check("delete: never-launched profile deleted without crashing",
              (try? repository.summary(for: fresh.id)) == nil)

        let ran = try repository.create(name: "Delete ran", configuration: ProfileConfiguration())
        let key = try repository.profileKey(for: ran.id)
        try await vault.prepareForLaunch(profileID: ran.id, key: key)
        var session: BrowserSession? = try makeSession(repository, ran.id, key: key)
        var web: WKWebView? = WKWebView(frame: .zero, configuration: session!.makeWebViewConfiguration())
        try await PageLoader.load(web!, html: page, baseURL: origin)
        _ = try await js(web!, "localStorage.setItem('pb', 'x'); return true;", [:])
        web = nil
        session?.shutDown()
        session = nil
        try await vault.seal(profileID: ran.id, key: key)
        let removalsAfterSeal = WebDataStoreVault.removeCallCount
        await vault.deleteData(profileID: ran.id)
        try repository.delete(ran.id)
        check("delete: stopped profile deleted without crashing",
              layout.discoverDirectories(for: ran.id).isEmpty && (try? repository.summary(for: ran.id)) == nil)
        check("delete: a store removed by the seal is not removed again",
              !WebDataStoreVault.isRegistered(ran.id) && WebDataStoreVault.removeCallCount == removalsAfterSeal)
    }

    // MARK: Crash recovery sealing (regression for the post-unlock crash)

    /// Reproduces the crash path: a profile ran and left website data on disk (the process
    /// "crashed" before sealing — here we just drop the session without sealing). Recovery must
    /// archive and delete that data WITHOUT calling `WKWebsiteDataStore.remove(forIdentifier:)`
    /// (at unlock no live store uses it and WebKit may not be initialized yet), and the data must
    /// restore cleanly.
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

    // MARK: Dialogs (regression for the teardown crash)

    /// A page waits on confirm() when the profile stops. Its sheet must be ended and WebKit's
    /// completion handler answered ("cancel" → false); a handler released uncalled raises
    /// NSInternalInconsistencyException and kills the app.
    private func dialogTeardown(_ repository: ProfileRepository) async throws {
        let profile = try repository.create(name: "Dialogs", configuration: ProfileConfiguration(ephemeral: true))
        let session = try makeSession(repository, profile.id, key: repository.profileKey(for: profile.id))
        let controller = session.openWindow(url: nil)
        guard let tab = controller.selectedTab else {
            check("dialogs: a tab to test with", false)
            session.shutDown()
            return
        }
        let webView = tab.webView
        try await PageLoader.load(webView, html: """
            <html><head><title>waiting</title><script>
            function ask() { var answer = confirm('self-test'); document.title = 'answered:' + answer; }
            </script></head><body>dialog</body></html>
            """, baseURL: origin)
        _ = try? await webView.evaluateJavaScript("setTimeout(ask, 0); true")
        let asked = await waitUntil(timeout: 5) { tab.hasPendingSheet }
        check("dialogs: confirm() is shown as a sheet", asked)
        session.shutDown() // Stop / Lock / Quit path: tears the window and its tabs down
        let answered = await waitUntil(timeout: 5) { webView.title == "answered:false" }
        check("dialogs: stopping answers the pending confirm() with cancel", answered && !tab.hasPendingSheet,
              "title=\(webView.title ?? "nil")")
    }

    // MARK: Lock during launch (regression for orphaned sessions)

    /// Lock / Quit while a profile is still decrypting its data: no window may be left without a
    /// manager, nothing may stay decrypted, and the manager must report no activity afterwards.
    private func lockDuringLaunch(_ repository: ProfileRepository) async throws {
        let vault = WebDataStoreVault(repository: repository)
        let layout = WebDataStoreVault.layout
        let profile = try repository.create(name: "Lock during launch", configuration: ProfileConfiguration())
        let key = try repository.profileKey(for: profile.id)
        // Give the profile an archive so that launching has data to decrypt (an await to land in).
        try await vault.prepareForLaunch(profileID: profile.id, key: key)
        var session: BrowserSession? = try makeSession(repository, profile.id, key: key)
        var web: WKWebView? = WKWebView(frame: .zero, configuration: session!.makeWebViewConfiguration())
        try await PageLoader.load(web!, html: page, baseURL: origin)
        _ = try await js(web!, "localStorage.setItem('pb', 'x'); return true;", [:])
        web = nil
        session?.shutDown()
        session = nil
        try await vault.seal(profileID: profile.id, key: key)

        let manager = ProfileManager(repository: repository)
        let launch = Task { @MainActor in try await manager.launch(profile.id) }
        _ = await waitUntil(timeout: 5) { manager.busyProfileIDs.contains(profile.id) || manager.isRunning(profile.id) }
        await manager.shutDown()
        _ = try? await launch.value
        check("lock during launch: no profile left running", !manager.isRunning(profile.id) && !manager.hasActivity)
        check("lock during launch: nothing left decrypted", layout.discoverDirectories(for: profile.id).isEmpty,
              layout.discoverDirectories(for: profile.id).map(\.path).joined(separator: ", "))
        check("lock during launch: the data is still in the archive",
              FileManager.default.fileExists(atPath: repository.webDataArchiveURL(for: profile.id).path))
        try? await manager.launch(profile.id)
        check("lock during launch: no launch after shutdown", !manager.isRunning(profile.id))
        await vault.deleteData(profileID: profile.id)
        try repository.delete(profile.id)
    }

    // MARK: Helpers

    private func makeSession(_ repository: ProfileRepository, _ id: UUID, key: SymmetricKey) throws -> BrowserSession {
        let configuration = try repository.loadConfiguration(id, key: key)
        let library = ProfileLibrary(
            history: try repository.historyStore(for: id, key: key, policy: configuration.historyPolicy, persistent: !configuration.ephemeral),
            bookmarks: try repository.bookmarkStore(for: id, key: key),
            recordsHistory: configuration.historyEnabled)
        return try BrowserSession(profileID: id, profileName: try repository.summary(for: id).name, configuration: configuration,
                              passwordVault: try repository.passwordVault(for: id), library: library)
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
