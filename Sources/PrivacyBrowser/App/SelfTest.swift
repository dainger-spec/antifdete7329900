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
///   * several SOCKS5 profiles launched and loading at once, each through its own proxy,
///   * launches that wait only briefly on the lookup through the proxy, and the exit-IP warning,
///   * the tab model with history recording and bookmarks.
///
/// Proxy checks need `scripts/selftest_proxy.py` and the env vars
/// `PB_SELFTEST_HTTP_PROXY_PORT` / `PB_SELFTEST_SOCKS_PROXY_PORT` (and for the concurrent SOCKS5
/// checks `PB_SELFTEST_SOCKS2_PROXY_PORT` / `PB_SELFTEST_SOCKS_AUTH_PROXY_PORT`); they are
/// skipped otherwise.
/// Everything is created in a temporary vault and removed afterwards.
@MainActor
final class SelfTest {
    private var failures = 0
    private var passes = 0
    private var retainedDelegates: [NSObject] = []
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
        info("macOS \(ProcessInfo.processInfo.operatingSystemVersionString), Safari \(HostSafari.version)")
        environmentChecks()
        vaultKeyDerivation()
        // Without the packet tunnel (any build but a signed NE=1 one) proxied profiles keep WebRTC
        // off; the proxy checks below verify that, scripts/leak_check.py the relay itself.
        let tunnel = TunnelManager.shared
        check("tunnel: a build without the network extension says so (proxied profiles keep WebRTC off)",
              tunnel.extensionIdentifier != nil || (tunnel.state == .notBuilt && !tunnel.canCarryWebRTC), "\(tunnel.state)")
        // As the first launch of a profile with a German proxy would, before WebKit starts any
        // process; checked by fingerprintSurface (navigator) and proxies (Accept-Language header).
        WebContentLanguage.decide("de-DE")
        info("web content languages: \(WebContentLanguage.decided ?? [])")

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pb-selftest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            let repository = try ProfileRepository(vault: MasterVault.create(in: root, password: "self-test", iterations: 10_000))
            try await firstWebKitUse(repository) // must run before anything else touches WebKit
            try await storageIsolationAndShims(repository)
            try await deviceGenerations(repository)
            try await fingerprintSurface(repository)
            try await recoverySealing(repository)
            try await deleteProfiles(repository)
            try await proxies(repository)
            try await proxyLocationAtLaunch(repository)
            try await socksProfilesSideBySide(repository)
            try await proxyLookupAndExitIP(repository)
            try await tabsAndLibrary(repository)
            try await windowLifecycle(repository)
            try await dialogTeardown(repository)
            try await passwordAutoFill(repository)
            try await lockDuringLaunch(repository)
            try await quitFromFocusedPage(repository)
            try await forcedSealAtQuit(repository)
        } catch {
            check("self-test ran without unexpected errors", false, String(describing: error))
        }
    }

    // MARK: Vault key derivation

    /// The app's key derivation in this (release) build: a vault from before Argon2id is re-wrapped
    /// under the recommended Argon2id (64 MiB, 3 passes, 4 lanes) and opens again.
    private func vaultKeyDerivation() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pb-selftest-kdf-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            let vault = try MasterVault.create(in: root, password: "kdf", iterations: 10_000)
            let start = Date()
            let upgraded = try vault.upgradeKDFIfNeeded(password: "kdf")
            let seconds = Date().timeIntervalSince(start)
            let kdf = try MasterVault.unlock(in: root, password: "kdf").header.kdf
            check("vault: a PBKDF2 vault is re-wrapped under Argon2id (64 MiB, t=3, p=4) and opens again",
                  upgraded && kdf.algorithm == KDFParameters.argon2id && kdf.memoryKiB == 65_536
                      && kdf.iterations == 3 && kdf.parallelism == 4, "\(kdf)")
            info(String(format: "Argon2id (64 MiB, t=3, p=4) upgrade took %.2f s", seconds))
            check("vault: Argon2id at the recommended cost takes under 10 s here", seconds < 10, String(format: "%.2f s", seconds))
        } catch {
            check("vault: Argon2id upgrade ran", false, String(describing: error))
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
        // A UI delegate, as every tab has (BrowserTab): without one WebKit answers no permission query.
        let uiDelegate = SelfTestUIDelegate()
        retainedDelegates.append(uiDelegate) // the web view holds its UI delegate weakly
        webA!.uiDelegate = uiDelegate
        try await PageLoader.load(webA!, html: page, baseURL: origin)

        check("shim: getTimezoneOffset in Asia/Tokyo",
              try await js(webA!, "return new Date(Date.UTC(2024, 0, 15, 12)).getTimezoneOffset();") as? Int == -540)
        check("shim: Intl default time zone",
              try await js(webA!, "return Intl.DateTimeFormat().resolvedOptions().timeZone;") as? String == "Asia/Tokyo")
        check("shim: local getters use profile zone",
              try await js(webA!, "return new Date(Date.UTC(2024, 0, 15, 20)).getHours();") as? Int == 5)
        // A worker made from a blob (as fingerprinting scripts make theirs) runs in the same zone as
        // the page, keeps strict mode and its line numbers; the wrapper prints as native code.
        let worker = try await js(webA!, """
            const run = (code) => new Promise((resolve) => {
              const w = new Worker(URL.createObjectURL(new Blob([code], { type: 'text/javascript' })));
              w.onmessage = (e) => resolve(e.data);
              w.onerror = (e) => resolve('error line ' + e.lineno);
              setTimeout(() => resolve('timeout'), 5000);
            });
            const zone = await run("'use strict'\\npostMessage([Intl.DateTimeFormat().resolvedOptions().timeZone, new Date(Date.UTC(2024, 0, 15, 12)).getTimezoneOffset(), (function () { return this === undefined; })()].join())");
            const line = await run('\\n\\nthrow new Error("x")');
            return [zone, line, Function.prototype.toString.call(Worker).includes('[native code]')].join('|');
            """) as? String
        check("shim: a blob worker runs in the profile's zone, strict and with its own line numbers",
              worker == "Asia/Tokyo,-540,true|error line 3|true", worker ?? "nil")
        // Off in the engine (as in Lockdown Mode): no RTC interface at all, not only the constructors.
        let rtcNames = try await js(webA!, "return Object.getOwnPropertyNames(window).filter((n) => /^(webkit)?RTC/.test(n)).join();") as? String
        check("WebRTC disabled: off in the engine, no RTC interface left",
              rtcNames == "" && WebKitPreferences.bool(webA!.configuration.preferences, "_peerConnectionEnabled") == false,
              rtcNames ?? "nil")
        // WebKit says 'prompt' until the page asks (Geolocation::hasBeenRequested); the status is the
        // engine's own PermissionStatus (a fake one threw on its onchange setter before).
        let permission = "return await navigator.permissions.query({ name: 'geolocation' }).then((s) => [s.state, s instanceof PermissionStatus, Object.getOwnPropertyNames(s).length].join());"
        let before = try await js(webA!, permission) as? String
        check("shim: geolocation permission is 'prompt' until the page asks, on a real PermissionStatus", before == "prompt,true,0", before ?? "nil")
        let coords = try await js(webA!, """
            return await new Promise((resolve) => navigator.geolocation.getCurrentPosition(
              (p) => resolve([p.coords.latitude, p.coords.longitude, Object.getOwnPropertyNames(p).length + Object.getOwnPropertyNames(p.coords).length,
                              p instanceof GeolocationPosition, JSON.stringify(p.toJSON().coords.latitude)].join()),
              (e) => resolve('error ' + e.code)));
            """) as? String
        check("shim: fixed geolocation, as an engine-shaped position", coords == "48.8566,2.3522,0,true,48.8566", coords ?? "nil")
        let after = try await js(webA!, permission) as? String
        check("shim: geolocation permission 'granted' once asked (fixed position)", after == "granted,true,0", after ?? "nil")
        // A frame reached by index right after insertion, before anything touched its contentWindow.
        let indexed = try await js(webA!, """
            const frame = document.createElement('iframe');
            document.body.appendChild(frame);
            const child = window[window.length - 1];
            const value = [child.Intl.DateTimeFormat().resolvedOptions().timeZone, typeof child.RTCPeerConnection].join();
            frame.remove();
            return value;
            """) as? String
        check("shim: a frame reached as window[i] right after insertion is patched", indexed == "Asia/Tokyo,undefined", indexed ?? "nil")
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
        info("RTC interfaces with WebRTC on: " + ((try await js(webB!, "return Object.getOwnPropertyNames(window).filter((n) => /^(webkit)?RTC/.test(n)).sort().join();") as? String) ?? "nil"))
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
        check("proxy: a bracketed IPv6 proxy address is split into host and port",
              (try? ProxyHostField.parse("[::1]:1080")) == ProxyHostField(host: "::1", port: 1080))

        // Every proxied session carries the ping-load blocker (dns-prefetch would resolve outside
        // the proxy; see ContentRules).
        await ContentRules.prepare()
        check("proxy: the ping-load blocker compiled", ContentRules.dnsPrefetchBlocker != nil)

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
        // The language WebKit was given (decided at the start of the self-test) is the header too.
        let acceptLanguage = httpBody?.components(separatedBy: "accept-language=").dropFirst().first ?? "nil"
        check("language: Accept-Language carries the language WebKit was given",
              acceptLanguage.hasPrefix(WebContentLanguage.decided?.first ?? "?"), acceptLanguage)

        // WebKit opens WebRTC's sockets outside the data store's proxy: a proxied profile gets no
        // WebRTC, whatever its stored setting (ProfileConfiguration.effectiveWebRTCPolicy).
        let rtc = try await loadThroughProxy(repository, ProxySettings(kind: .httpConnect, host: "127.0.0.1", port: httpPort), url: target,
                                             webRTCPolicy: .unrestricted,
                                             script: "return typeof RTCPeerConnection + ',' + typeof RTCDataChannel;")
        check("proxy: WebRTC is off in a proxied profile, whatever its setting", rtc == "undefined,undefined", rtc ?? "load failed")

        let socksBody = try await loadThroughProxy(repository, ProxySettings(kind: .socks5, host: "127.0.0.1", port: socksPort), url: target)
        check("proxy: SOCKS5 carries the request", socksBody?.contains("PB-PROXY-OK via=socks5") == true, socksBody ?? "load failed")
        check("proxy: SOCKS5 receives the hostname (remote DNS)", socksBody?.contains("atyp=3") == true, socksBody ?? "nil")

        // A proxy at an IPv6 literal (the IPv6 loopback; the self-test proxy listens there too).
        if let http6Port = environment["PB_SELFTEST_HTTP6_PROXY_PORT"].flatMap(Int.init) {
            let v6Body = try await loadThroughProxy(repository, ProxySettings(kind: .httpConnect, host: "::1", port: http6Port), url: target)
            check("proxy: an IPv6 proxy address carries the request", v6Body?.contains("PB-PROXY-OK via=connect6") == true,
                  v6Body ?? "load failed")
        } else {
            info("IPv6 proxy check skipped (PB_SELFTEST_HTTP6_PROXY_PORT not set)")
        }

        // Port 9 (discard) on localhost is closed on CI runners: the load must fail, not go direct.
        let direct = try await loadThroughProxy(repository, ProxySettings(kind: .httpConnect, host: "127.0.0.1", port: 9),
                                                url: URL(string: "http://example.com/")!)
        check("proxy: fail-closed when the proxy is unreachable", direct == nil, "page loaded: \(direct ?? "")")
        // A proxy host that does not resolve (".invalid" never does): the load fails too.
        let unresolved = try await loadThroughProxy(repository, ProxySettings(kind: .socks5, host: "proxy.selftest.invalid", port: 1080),
                                                    url: URL(string: "http://example.com/")!)
        check("proxy: fail-closed when the proxy host does not resolve", unresolved == nil, "page loaded: \(unresolved ?? "")")

        // What WebKit would send outside the proxy is blocked by the ping-load blocker: an
        // <a ping> (the same load type as a dns-prefetch) never reaches the proxy, a fetch does.
        let served = try await servedPathsAfterPing(repository, ProxySettings(kind: .httpConnect, host: "127.0.0.1", port: httpPort))
        check("proxy: ping-type loads (dns-prefetch, <a ping>) are blocked in a proxied profile",
              served.contains("/fetch-allowed") && !served.contains("/ping-blocked"), served.joined(separator: ","))
        info("proxy: a beacon \(served.contains("/beacon") ? "still reaches" : "does not reach") the proxy (beacons are fetches, not pings)")

        // A proxy that answers 407: the profile's credentials are sent, wrong ones fail closed.
        // Loaded in a BrowserTab, whose navigation delegate answers the proxy's challenge.
        if let authPort = environment["PB_SELFTEST_HTTP_AUTH_PROXY_PORT"].flatMap(Int.init) {
            let good = try await titleThroughProxyTab(repository, ProxySettings(kind: .httpConnect, host: "127.0.0.1", port: authPort,
                                                                                username: "pb-user", password: "pb-pass"), url: target)
            check("proxy: 407 is answered with the profile's credentials", good?.hasPrefix("PB proxied") == true, good ?? "nil")
            let wrong = try await titleThroughProxyTab(repository, ProxySettings(kind: .httpConnect, host: "127.0.0.1", port: authPort,
                                                                                 username: "pb-user", password: "wrong"), url: target)
            check("proxy: rejected credentials fail closed", wrong?.hasPrefix("PB proxied") != true, wrong ?? "nil")
            // Without credentials WebKit never surfaces the proxy's challenge (the page would load
            // forever): the launch-time lookup through the proxy sees the 407 and the profile is
            // refused, with its data sealed again.
            let services = ProxyGeoLookup.services
            ProxyGeoLookup.services = [.init(url: URL(string: "http://geo.selftest.invalid/pb-geo.json")!,
                                             timeZoneKeyPath: ["timezone"], countryKeyPath: ["country"])]
            defer { ProxyGeoLookup.services = services }
            let noCredentials = try repository.create(name: "No proxy credentials", configuration: ProfileConfiguration(
                proxy: ProxySettings(kind: .httpConnect, host: "127.0.0.1", port: authPort)))
            try await WebDataStoreVault(repository: repository).prepareForLaunch(profileID: noCredentials.id,
                                                                                  key: repository.profileKey(for: noCredentials.id))
            let manager = ProfileManager(repository: repository)
            var launchError: Error?
            do { try await manager.launch(noCredentials.id) } catch { launchError = error }
            check("proxy: 407 without credentials refuses the launch (fail-closed)",
                  launchError as? ProfileManager.LaunchError == .proxyNeedsCredentials(host: "127.0.0.1") && !manager.isRunning(noCredentials.id),
                  launchError.map { String(describing: $0) } ?? "launched")
            check("proxy: the refused profile's data is sealed again",
                  WebDataStoreVault.discoverDirectories(for: noCredentials.id).isEmpty)
            try repository.delete(noCredentials.id)
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

    /// In a page served by the proxy: clicks an `<a ping>`, sends a beacon and a fetch to the
    /// proxy, then reads back which paths the proxy served (`/pb-served.json`).
    private func servedPathsAfterPing(_ repository: ProfileRepository, _ proxy: ProxySettings) async throws -> [String] {
        let profile = try repository.create(name: "Ping", configuration: ProfileConfiguration(proxy: proxy, ephemeral: true))
        let session = try makeSession(repository, profile.id, key: repository.profileKey(for: profile.id))
        defer { session.shutDown() }
        let webView = WKWebView(frame: .zero, configuration: session.makeWebViewConfiguration())
        try await PageLoader.load(webView, url: URL(string: "http://proxied.selftest.invalid/ping-page")!)
        let served = try await js(webView, """
            const a = document.createElement('a');
            a.href = '#clicked'; a.ping = '/ping-blocked'; a.textContent = 'ping';
            document.body.appendChild(a);
            a.click();
            navigator.sendBeacon('/beacon', 'x');
            await fetch('/fetch-allowed');
            await new Promise((resolve) => setTimeout(resolve, 1500));
            return await (await fetch('/pb-served.json', { cache: 'no-store' })).json();
            """) as? [String] ?? []
        return served
    }

    /// Loads `url` in an ephemeral profile using `proxy`. Returns the page text, or nil if the load failed.
    private func loadThroughProxy(_ repository: ProfileRepository, _ proxy: ProxySettings, url: URL,
                                  webRTCPolicy: WebRTCPolicy = .disabled,
                                  script: String = "return document.body ? document.body.innerText : '';") async throws -> String? {
        let profile = try repository.create(name: "Proxy \(proxy.kind.rawValue)",
                                            configuration: ProfileConfiguration(proxy: proxy, webRTCPolicy: webRTCPolicy, ephemeral: true))
        let session = try makeSession(repository, profile.id, key: repository.profileKey(for: profile.id))
        defer { session.shutDown() }
        let webView = WKWebView(frame: .zero, configuration: session.makeWebViewConfiguration())
        do {
            try await PageLoader.load(webView, url: url)
        } catch {
            info("load of \(url.absoluteString) via \(proxy.kind.rawValue) :\(proxy.port) failed: \(error.localizedDescription)")
            return nil
        }
        return try await js(webView, script) as? String
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
              iosUA?.contains("iPhone OS 18_7") == true && iosUA?.contains("Version/26.") == true, iosUA ?? "nil")

        let macUA = try await userAgent(for: .forGeneration(DeviceGenerations.resolved(id: DeviceGenerations.defaultID)))
        check("generation: macOS UA names this Mac's Safari (\(HostSafari.version))",
              macUA?.contains("Macintosh; Intel Mac OS X 10_15_7") == true
                  && macUA?.hasSuffix("Version/\(HostSafari.version) Safari/605.1.15") == true, macUA ?? "nil")

        var override = ProfileConfiguration.forGeneration(DeviceGenerations.resolved(id: "ios-27"))
        override.userAgent = "PrivacyBrowserSelfTest/UA-Override"
        let overrideUA = try await userAgent(for: override)
        check("generation: explicit user agent overrides the generation",
              overrideUA == "PrivacyBrowserSelfTest/UA-Override", overrideUA ?? "nil")
    }

    // MARK: Fingerprint surface (what deviceinfo.me-style pages test)

    /// A macOS profile must look exactly like a plain WKWebView of this Mac (no own properties,
    /// native navigator and screen values, untouched rendering), an iPhone profile like an
    /// iPhone's Safari where the shim can say so, and neither may add noise or Chromium-only
    /// properties. Compared against a web view without any profile script. The probe is
    /// Resources/fingerprint_probe.js, the one scripts/safari_reference.py runs in real Safari;
    /// with PB_SELFTEST_SURFACE_OUT set, every result is written there as JSON for that comparison.
    private func fingerprintSurface(_ repository: ProfileRepository) async throws {
        guard let probe = Self.loadProbe() else {
            check("surface: fingerprint_probe.js found (app bundle or PB_SELFTEST_PROBE)", false)
            return
        }
        let plainConfiguration = WKWebViewConfiguration()
        plainConfiguration.websiteDataStore = .nonPersistent()
        // The one engine preference a profile sets (as Safari has it), so the engine is compared
        // like for like.
        plainConfiguration.preferences.isElementFullscreenEnabled = true
        let plain = WKWebView(frame: .zero, configuration: plainConfiguration)
        try await PageLoader.load(plain, html: page, baseURL: origin)
        let reference = Self.flatten(try await js(plain, probe) as? [String: Any] ?? [:])
        writeSurface(reference, name: "plain")
        func string(_ probe: [String: String], _ key: String) -> String { probe[key] ?? "nil" }

        let colors = Int(string(reference, "canvas.colors")) ?? -1
        let urlLength = Int(string(reference, "canvas.urlLength")) ?? -1
        // deviceinfo.me wants exactly 5 colours AND a data URL of 150, 158, 142 or 186 characters.
        let verdict = colors != 5 ? "Spoofed: the pixels differ (noise)"
            : [150, 158, 142, 186].contains(urlLength) ? "Allowed"
            : "Spoofed, only because this WebKit's PNG encoding is not on the page's list (pixels exact)"
        info("plain WKWebView: canvas \(colors) colours, PNG \(urlLength) chars → deviceinfo.me verdict: \(verdict)")
        info("plain WKWebView: plugins \(string(reference, "plugins")), languages \(string(reference, "languages")), WebGL \(string(reference, "webgl.unmaskedRenderer"))")
        check("language: navigator.language is the language WebKit was given",
              string(reference, "language") == WebContentLanguage.decided?.first, string(reference, "language"))
        // A profile without a proxy country: this Mac's languages, as Safari has them — not the
        // app's UI language, which Localization.applyProcessLanguage keeps in the app's domain.
        // (scripts/live_compare.py checks the result against Safari's navigator.language.)
        let systemLanguages = WebContentLanguage.languages(for: nil)
        check("language: without a proxy country, websites get this Mac's languages, not the app's UI language",
              !systemLanguages.isEmpty && systemLanguages == WebContentLanguage.systemLanguages, systemLanguages.joined(separator: ","))
        info("this Mac's languages (Safari's): \(systemLanguages.joined(separator: ","))")

        // Everything a page measures of the engine and the Mac, which no profile may change.
        let engineKeys = reference.keys.filter { key in
            ["plugins", "mimeTypes", "pdfViewerEnabled", "language", "languages", "deviceMemory", "ownNavigator", "ownScreen",
             "navigatorProtoCount", "colorDepth", "canvas.colors", "canvas.urlLength", "canvas.url", "canvasText", "fonts",
             "webkitObject", "webdriver", "doNotTrack"].contains(key) || key.hasPrefix("webgl.")
                || (key.hasPrefix("features.") && key != "features.safari") // window.safari is added on purpose (macOS)
        }.sorted()
        for generationID in [DeviceGenerations.defaultID, "ios-26"] {
            // WebRTC left as the engine has it: its removal (the default policy) is checked by the
            // shim checks and would otherwise be the one deliberate difference here.
            let profile = try repository.create(name: "Surface \(generationID)", configuration: ProfileConfiguration(
                webRTCPolicy: .unrestricted, ephemeral: true, deviceGenerationID: generationID))
            let session = try makeSession(repository, profile.id, key: repository.profileKey(for: profile.id))
            let tabConfiguration = session.makeWebViewConfiguration()
            check("surface (\(generationID)): user-installed fonts hidden from pages, as in Safari",
                  WebKitPreferences.bool(tabConfiguration.preferences, "_shouldAllowUserInstalledFonts") == false)
            let tab = BrowserTab(configuration: tabConfiguration, context: session.tabContext)
            try await PageLoader.load(tab.webView, html: page, baseURL: origin)
            let probed = Self.flatten(try await js(tab.webView, probe) as? [String: Any] ?? [:])
            // Safari's quota (82 463 372 084 on any Mac), not the 1000 MiB WebKit gives an app that is not a browser.
            let quota = try await js(tab.webView, "return (await navigator.storage.estimate()).quota;") as? NSNumber
            let safariQuota = PrivacyScripts.safariStorageQuota(for: DeviceGenerations.resolved(id: generationID).platform).rounded(.up)
            check("surface (\(generationID)): storage quota is Safari's",
                  quota?.doubleValue == safariQuota, "\(quota?.stringValue ?? "nil") vs \(String(format: "%.0f", safariQuota))")
            tab.tearDown()
            session.shutDown()
            try repository.delete(profile.id)

            let name = generationID == DeviceGenerations.defaultID ? "macOS" : "iPhone"
            writeSurface(probed, name: name.lowercased())
            let differing = engineKeys.filter { string(probed, $0) != string(reference, $0) }
            check("surface (\(name)): engine and hardware signals as in a plain web view (\(engineKeys.count) keys)",
                  differing.isEmpty, differing.map { "\($0): \(string(probed, $0)) vs \(string(reference, $0))" }.joined(separator: "; "))
            // The shim adds no noise and no visible wrappers: toString, length and own properties
            // of the rendering functions are the engine's own.
            let renderingNatives = probed.filter { $0.key.hasPrefix("natives.") && ($0.key.contains("Canvas") || $0.key.contains("WebGL")
                || $0.key.contains("AudioContext")) }
            check("surface (\(name)): canvas, WebGL and audio functions are native",
                  !renderingNatives.isEmpty && renderingNatives.values.allSatisfy { $0.hasPrefix("native-text") || $0 == "absent" },
                  renderingNatives.map { "\($0.key)=\($0.value)" }.joined(separator: "; "))
            check("surface (\(name)): one language, as WebKit exposes", string(probed, "languages") == string(probed, "language"))
            // Safari the app exposes window.safari on the Mac and not on iOS.
            check("surface (\(name)): window.safari \(name == "macOS" ? "present, as in Safari" : "absent, as on iOS")",
                  string(probed, "features.safari") == (name == "macOS" ? "object" : "undefined"), string(probed, "safariShape"))
            if name == "macOS" {
                for key in ["ua", "platform", "maxTouchPoints", "hardwareConcurrency", "screen", "standalone", "pointer", "touch",
                            "timeZone", "tzOffset", "dateString"] where key != "ua" {
                    check("surface (macOS): native \(key)", string(probed, key) == string(reference, key),
                          "\(string(probed, key)) vs \(string(reference, key))")
                }
                check("surface (macOS): the UA is this Mac's Safari",
                      string(probed, "ua").hasSuffix("Version/\(HostSafari.version) Safari/605.1.15"), string(probed, "ua"))
            } else {
                check("surface (iPhone): navigator", string(probed, "platform") == "iPhone" && string(probed, "maxTouchPoints") == "5"
                      && string(probed, "hardwareConcurrency") == "4" && string(probed, "standalone") == "false",
                      "\(string(probed, "platform")) \(string(probed, "maxTouchPoints")) \(string(probed, "hardwareConcurrency")) \(string(probed, "standalone"))")
                check("surface (iPhone): screen", string(probed, "screen") == "390x844x390x844x3", string(probed, "screen"))
            }
        }
    }

    /// The probe from the app bundle (build-app.sh copies it), else from PB_SELFTEST_PROBE.
    private static func loadProbe() -> String? {
        if let url = Bundle.main.url(forResource: "fingerprint_probe", withExtension: "js"),
           let source = try? String(contentsOf: url, encoding: .utf8) {
            return source
        }
        if let path = ProcessInfo.processInfo.environment["PB_SELFTEST_PROBE"] {
            return try? String(contentsOfFile: path, encoding: .utf8)
        }
        return nil
    }

    /// Nested probe results as "canvas.colors" → "5" (numbers and booleans as JavaScript prints them).
    private static func flatten(_ value: [String: Any], prefix: String = "") -> [String: String] {
        var out: [String: String] = [:]
        for (key, item) in value {
            if let nested = item as? [String: Any] {
                out.merge(flatten(nested, prefix: prefix + key + "."), uniquingKeysWith: { $1 })
            } else if let number = item as? NSNumber {
                // JSONSerialization hands booleans over as NSNumber too; keep "true"/"false".
                out[prefix + key] = CFGetTypeID(number) == CFBooleanGetTypeID() ? (number.boolValue ? "true" : "false") : number.stringValue
            } else {
                out[prefix + key] = item is NSNull ? "null" : "\(item)"
            }
        }
        return out
    }

    /// PB_SELFTEST_SURFACE_OUT: a directory; one JSON file per probed surface.
    private func writeSurface(_ surface: [String: String], name: String) {
        guard let directory = ProcessInfo.processInfo.environment["PB_SELFTEST_SURFACE_OUT"], !directory.isEmpty else { return }
        var nested: [String: Any] = [:]
        for (key, value) in surface {
            let parts = key.split(separator: ".", maxSplits: 1).map(String.init)
            if parts.count == 2 {
                var inner = nested[parts[0]] as? [String: Any] ?? [:]
                inner[parts[1]] = value
                nested[parts[0]] = inner
            } else {
                nested[key] = value
            }
        }
        do {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: nested, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("surface-\(name).json"))
        } catch {
            info("could not write the \(name) surface: \(error.localizedDescription)")
        }
    }

    // MARK: Proxy location (time zone of the proxy's exit IP)

    /// A profile with a proxy and no explicit time zone runs in the time zone of the proxy's exit
    /// IP, looked up through the proxy at launch; a later failed lookup falls back to the location
    /// remembered for that proxy, and an explicit time zone always wins. The self-test proxy
    /// answers the lookup itself (Europe/Berlin, DE).
    private func proxyLocationAtLaunch(_ repository: ProfileRepository) async throws {
        guard let httpPort = ProcessInfo.processInfo.environment["PB_SELFTEST_HTTP_PROXY_PORT"].flatMap(Int.init) else {
            info("proxy location checks skipped (PB_SELFTEST_HTTP_PROXY_PORT not set)")
            return
        }
        let services = ProxyGeoLookup.services
        defer { ProxyGeoLookup.services = services }
        func lookUp(at path: String) {
            ProxyGeoLookup.services = [.init(url: URL(string: "http://geo.selftest.invalid\(path)")!,
                                             timeZoneKeyPath: ["timezone"], countryKeyPath: ["country"])]
        }
        let profile = try repository.create(name: "Proxy location", configuration: ProfileConfiguration(
            proxy: ProxySettings(kind: .httpConnect, host: "127.0.0.1", port: httpPort), ephemeral: true))
        let manager = ProfileManager(repository: repository)
        func launchedTimeZone() async throws -> String? {
            try await manager.launch(profile.id)
            var zone: String?
            if let webView = manager.session(for: profile.id)?.windowControllers.first?.selectedTab?.webView {
                try await PageLoader.load(webView, html: page, baseURL: origin)
                zone = try await js(webView, "return Intl.DateTimeFormat().resolvedOptions().timeZone;") as? String
            }
            try await manager.stop(profile.id)
            return zone
        }

        lookUp(at: "/pb-geo.json")
        let zone = try await launchedTimeZone()
        check("proxy location: the profile runs in the proxy's time zone", zone == "Europe/Berlin", zone ?? "nil")
        let stored = try repository.loadConfiguration(profile.id)
        check("proxy location: remembered for this proxy",
              stored.lastProxyLocation?.timeZoneIdentifier == "Europe/Berlin" && stored.lastProxyLocation?.webLanguage == "de-DE",
              String(describing: stored.lastProxyLocation))

        lookUp(at: "/no-location-here") // an HTML page, not a location
        let fallback = try await launchedTimeZone()
        check("proxy location: a failed lookup falls back to the remembered location", fallback == "Europe/Berlin", fallback ?? "nil")

        var explicit = stored
        explicit.timeZoneIdentifier = "Asia/Tokyo"
        try repository.saveConfiguration(explicit, for: profile.id)
        lookUp(at: "/pb-geo.json")
        let tokyo = try await launchedTimeZone()
        check("proxy location: an explicit time zone wins", tokyo == "Asia/Tokyo", tokyo ?? "nil")
        try repository.delete(profile.id)
    }

    // MARK: Several SOCKS5 profiles at once

    /// Three profiles behind three SOCKS5 proxies, one wanting username/password authentication,
    /// launched together through the app's launch path (with its lookup through each proxy) and
    /// loading at the same time. Each page arrives through its own proxy, by name (remote DNS),
    /// with its own credentials. Stopping one leaves the others loading through theirs, and wrong
    /// or missing SOCKS5 credentials fail closed.
    private func socksProfilesSideBySide(_ repository: ProfileRepository) async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let socksPort = environment["PB_SELFTEST_SOCKS_PROXY_PORT"].flatMap(Int.init),
              let socks2Port = environment["PB_SELFTEST_SOCKS2_PROXY_PORT"].flatMap(Int.init),
              let authPort = environment["PB_SELFTEST_SOCKS_AUTH_PROXY_PORT"].flatMap(Int.init) else {
            info("concurrent SOCKS5 checks skipped (PB_SELFTEST_SOCKS2_PROXY_PORT / PB_SELFTEST_SOCKS_AUTH_PROXY_PORT not set)")
            return
        }
        let services = ProxyGeoLookup.services
        ProxyGeoLookup.services = [.init(url: URL(string: "http://geo.selftest.invalid/pb-geo.json")!,
                                         timeZoneKeyPath: ["timezone"], countryKeyPath: ["country"])]
        defer { ProxyGeoLookup.services = services }
        struct Run { let name: String; let port: Int; let via: String; let id: UUID }
        let proxies: [(name: String, proxy: ProxySettings, via: String)] = [
            ("a", ProxySettings(kind: .socks5, host: "127.0.0.1", port: socksPort), "via=socks5 "),
            ("b", ProxySettings(kind: .socks5, host: "127.0.0.1", port: authPort, username: "pb-user2", password: "pb-pass2"), "via=socks5-auth "),
            ("c", ProxySettings(kind: .socks5, host: "127.0.0.1", port: socks2Port), "via=socks5 "),
        ]
        var runs: [Run] = []
        for entry in proxies {
            let profile = try repository.create(name: "SOCKS5 \(entry.name)",
                                                configuration: ProfileConfiguration(proxy: entry.proxy, ephemeral: true))
            runs.append(Run(name: entry.name, port: entry.proxy.port, via: entry.via, id: profile.id))
        }
        let manager = ProfileManager(repository: repository)
        var messages: [String] = []
        manager.onError = { messages.append($0) }
        // Launched together: the launches interleave at every await (rules, lookups, windows).
        let started = Date()
        await withTaskGroup(of: String?.self) { group in
            for run in runs {
                group.addTask { @MainActor in
                    do { try await manager.launch(run.id) } catch { return "\(run.name): \(error)" }
                    return nil
                }
            }
            for await failure in group { if let failure { messages.append(failure) } }
        }
        info(String(format: "three SOCKS5 profiles launched together in %.2f s", Date().timeIntervalSince(started)))
        check("SOCKS5 side by side: three profiles launched together all run",
              runs.allSatisfy { manager.isRunning($0.id) }, messages.joined(separator: " | "))

        // Every running profile loads its own host at the same time; the page says which proxy
        // (listener port, authentication) carried it and which host name it was asked for.
        func loadTogether(_ subset: [Run], round: Int) async -> [String: String] {
            var bodies: [String: String] = [:]
            await withTaskGroup(of: (String, String).self) { group in
                for run in subset {
                    guard let webView = manager.session(for: run.id)?.windowControllers.first?.selectedTab?.webView else { continue }
                    group.addTask { @MainActor in
                        let url = URL(string: "http://\(run.name)-\(round).selftest.invalid/side-by-side")!
                        do {
                            try await PageLoader.load(webView, url: url)
                            let body = try await self.js(webView, "return document.body ? document.body.innerText : '';") as? String
                            return (run.name, body ?? "")
                        } catch {
                            return (run.name, "load failed: \(error.localizedDescription)")
                        }
                    }
                }
                for await (name, body) in group { bodies[name] = body }
            }
            return bodies
        }
        func carried(_ run: Run, _ body: String?, round: Int) -> Bool {
            guard let body else { return false }
            return body.contains(run.via) && body.contains("atyp=3") && body.contains("target=\(run.name)-\(round).selftest.invalid:80")
                && body.contains("listener=\(run.port) ")
        }
        let first = await loadTogether(runs, round: 1)
        check("SOCKS5 side by side: each profile's page came through its own proxy, by name, at the same time",
              runs.allSatisfy { carried($0, first[$0.name], round: 1) }, String(describing: first))
        check("SOCKS5 side by side: the profile with SOCKS5 credentials authenticated with its own",
              first["b"]?.contains("via=socks5-auth ") == true, first["b"] ?? "nil")

        // One stops; the others keep loading through their own proxies.
        try await manager.stop(runs[1].id)
        let remaining = [runs[0], runs[2]]
        let second = await loadTogether(remaining, round: 2)
        check("SOCKS5 side by side: after one profile stops the others still load through their own proxies",
              !manager.isRunning(runs[1].id) && remaining.allSatisfy { carried($0, second[$0.name], round: 2) }, String(describing: second))
        for run in remaining { try await manager.stop(run.id) }

        // The launch lookups ran at the same time too, each through its profile's proxy (the geo
        // host only resolves there; b's needs its credentials): each remembers the answer.
        func zones() -> [String?] {
            runs.map { (try? repository.loadConfiguration($0.id))?.rememberedProxyLocation?.timeZoneIdentifier }
        }
        let remembered = await waitUntil(timeout: 10) { zones().allSatisfy { $0 == "Europe/Berlin" } }
        check("SOCKS5 side by side: each profile's launch lookup went through its own proxy (time zone remembered)",
              remembered, String(describing: zones()))
        for run in runs { try repository.delete(run.id) }

        // Wrong or missing SOCKS5 credentials: the load fails, nothing goes direct (a real host,
        // which a direct connection would reach).
        let target = URL(string: "http://example.com/")!
        let wrong = try await loadThroughProxy(repository, ProxySettings(kind: .socks5, host: "127.0.0.1", port: authPort,
                                                                         username: "pb-user2", password: "wrong"), url: target)
        let none = try await loadThroughProxy(repository, ProxySettings(kind: .socks5, host: "127.0.0.1", port: authPort), url: target)
        check("SOCKS5 side by side: wrong or missing SOCKS5 credentials fail closed",
              wrong == nil && none == nil, "wrong: \(wrong ?? "nil"), none: \(none ?? "nil")")
    }

    // MARK: Launch speed and the proxy's exit IP

    /// With a location remembered for the proxy, a launch waits for the lookup through it at most
    /// `ProfileManager.rememberedLookupWait`: the lookup finishes in the background, and a new time
    /// zone is remembered and noted for the next launch. Without one it waits at most
    /// `ProfileManager.firstLookupWait`.
    /// With `warnOnProxyIPChange` (off by default) a changed exit IP is reported, and only then.
    private func proxyLookupAndExitIP(_ repository: ProfileRepository) async throws {
        guard let httpPort = ProcessInfo.processInfo.environment["PB_SELFTEST_HTTP_PROXY_PORT"].flatMap(Int.init) else {
            info("proxy lookup timing and exit IP checks skipped (PB_SELFTEST_HTTP_PROXY_PORT not set)")
            return
        }
        let services = ProxyGeoLookup.services
        defer { ProxyGeoLookup.services = services }
        func geo(_ query: String) {
            ProxyGeoLookup.services = [.init(url: URL(string: "http://geo.selftest.invalid/pb-geo.json?\(query)")!,
                                             timeZoneKeyPath: ["timezone"], countryKeyPath: ["country"])]
        }
        let proxy = ProxySettings(kind: .httpConnect, host: "127.0.0.1", port: httpPort)
        let manager = ProfileManager(repository: repository)
        var messages: [String] = []
        manager.onError = { messages.append($0) }
        func launch(_ id: UUID) async throws -> (seconds: TimeInterval, zone: String?) {
            let start = Date()
            try await manager.launch(id)
            let seconds = Date().timeIntervalSince(start)
            var zone: String?
            if let webView = manager.session(for: id)?.windowControllers.first?.selectedTab?.webView {
                try await PageLoader.load(webView, html: page, baseURL: origin)
                zone = try await js(webView, "return Intl.DateTimeFormat().resolvedOptions().timeZone;") as? String
            }
            return (seconds, zone)
        }
        func lookupsDone() async -> Bool { await waitUntil(timeout: 15) { !manager.hasProxyLookupsInFlight } }

        // A location remembered for the proxy: a slow lookup holds the launch at most rememberedLookupWait.
        let remembered = try repository.create(name: "Fast launch", configuration: ProfileConfiguration(proxy: proxy, ephemeral: true))
        geo("ip=203.0.113.7")
        _ = try await launch(remembered.id)
        _ = await lookupsDone()
        try await manager.stop(remembered.id)
        geo("ip=203.0.113.7&tz=Asia/Tokyo&delay=4")
        messages.removeAll()
        let fast = try await launch(remembered.id)
        info(String(format: "launch with a remembered location and a 4 s lookup took %.2f s", fast.seconds))
        check("launch: with a remembered location it waits for the lookup through the proxy at most \(Int(ProfileManager.rememberedLookupWait)) s",
              fast.seconds < ProfileManager.rememberedLookupWait + 1.5 && fast.zone == "Europe/Berlin", String(format: "%.2f s, zone %@", fast.seconds, fast.zone ?? "nil"))
        let finished = await lookupsDone()
        let updated = try repository.loadConfiguration(remembered.id).lastProxyLocation
        check("launch: that lookup finishes in the background; its new time zone is remembered and noted for the next launch",
              finished && updated?.timeZoneIdentifier == "Asia/Tokyo" && messages.contains { $0.contains("Asia/Tokyo") },
              "\(String(describing: updated)) | \(messages)")
        try await manager.stop(remembered.id)
        try repository.delete(remembered.id)

        // Nothing remembered: it waits for the lookup, at most firstLookupWait.
        let fresh = try repository.create(name: "Slow lookup", configuration: ProfileConfiguration(proxy: proxy, ephemeral: true))
        geo("delay=8")
        let capped = try await launch(fresh.id)
        info(String(format: "launch with nothing remembered and an 8 s lookup took %.2f s", capped.seconds))
        check("launch: with nothing remembered it waits for the lookup at most \(Int(ProfileManager.firstLookupWait)) s",
              capped.seconds < ProfileManager.firstLookupWait + 1.5, String(format: "%.2f s", capped.seconds))
        try await manager.stop(fresh.id)
        _ = await lookupsDone()
        try repository.delete(fresh.id)

        // The exit IP: reported when it changed, with the option on (here without the time-zone
        // matching, which the lookup then runs for alone); never with the option off.
        let watched = try repository.create(name: "IP watched", configuration: ProfileConfiguration(
            proxy: proxy, ephemeral: true, matchProxyLocation: false, warnOnProxyIPChange: true))
        let unwatched = try repository.create(name: "IP not watched", configuration: ProfileConfiguration(proxy: proxy, ephemeral: true))
        func run(_ id: UUID, ip: String) async throws -> [String] {
            geo("ip=\(ip)")
            messages.removeAll()
            _ = try await launch(id)
            _ = await lookupsDone()
            try await manager.stop(id)
            return messages.filter { $0.contains("203.0.113.7") || $0.contains("198.51.100.4") }
        }
        let firstRun = try await run(watched.id, ip: "203.0.113.7")
        let sameIP = try await run(watched.id, ip: "203.0.113.7")
        let changed = try await run(watched.id, ip: "198.51.100.4")
        check("exit IP: with the option on a changed proxy IP is reported (and not the first launch or an unchanged IP)",
              firstRun.isEmpty && sameIP.isEmpty && changed.count == 1
                  && changed[0].contains("203.0.113.7") && changed[0].contains("198.51.100.4") && changed[0].contains("IP watched"),
              "first \(firstRun) same \(sameIP) changed \(changed)")
        let watchedIP = try repository.loadConfiguration(watched.id).lastProxyLocation?.exitIP
        check("exit IP: the lookup runs for the option alone, and remembers the new address",
              watchedIP == "198.51.100.4", watchedIP ?? "nil")
        // Turned off in the editor while a lookup is still under way: the stored IP goes, and the
        // late answer neither warns nor brings an IP back.
        geo("ip=192.0.2.44&delay=2")
        messages.removeAll()
        try await manager.launch(watched.id)
        var edited = try repository.loadConfiguration(watched.id)
        edited.warnOnProxyIPChange = false
        try repository.saveConfiguration(edited.keepingStoredState(of: repository.loadConfiguration(watched.id)), for: watched.id)
        let settled = await lookupsDone()
        try await manager.stop(watched.id)
        let afterOff = try repository.loadConfiguration(watched.id).lastProxyLocation
        check("exit IP: turned off while a lookup is under way, no IP is kept and nothing is reported",
              settled && afterOff != nil && afterOff?.exitIP == nil && !messages.contains { $0.contains("192.0.2.44") },
              "\(String(describing: afterOff)) | \(messages)")
        // The proxy replaced while a lookup is under way (the warning still on): the answer is
        // about the old proxy, so it neither warns nor is remembered.
        var watchedAgain = try repository.loadConfiguration(watched.id)
        watchedAgain.warnOnProxyIPChange = true
        try repository.saveConfiguration(watchedAgain, for: watched.id)
        _ = try await run(watched.id, ip: "203.0.113.7")
        geo("ip=198.51.100.4&delay=2")
        messages.removeAll()
        try await manager.launch(watched.id)
        var replaced = try repository.loadConfiguration(watched.id)
        replaced.proxy = ProxySettings(kind: .httpConnect, host: "127.0.0.1", port: 9)
        try repository.saveConfiguration(replaced.keepingStoredState(of: repository.loadConfiguration(watched.id)), for: watched.id)
        let replacedSettled = await lookupsDone()
        try await manager.stop(watched.id)
        let afterReplace = try repository.loadConfiguration(watched.id).lastProxyLocation
        check("exit IP: the proxy replaced while a lookup is under way, its answer neither warns nor is remembered",
              replacedSettled && afterReplace?.exitIP == "203.0.113.7" && !messages.contains { $0.contains("198.51.100.4") },
              "\(String(describing: afterReplace)) | \(messages)")
        _ = try await run(unwatched.id, ip: "203.0.113.7")
        let quiet = try await run(unwatched.id, ip: "198.51.100.4")
        let unwatchedStored = try repository.loadConfiguration(unwatched.id)
        let optionOff = !unwatchedStored.warnOnProxyIPChange
        // Its time zone is remembered, its exit IP is not.
        let ipKept = unwatchedStored.lastProxyLocation.map { $0.exitIP != nil } ?? true
        check("exit IP: off by default, a changed proxy IP is not reported, nor stored",
              quiet.isEmpty && optionOff && !ipKept, "\(quiet) | \(String(describing: unwatchedStored.lastProxyLocation))")
        try repository.delete(watched.id)
        try repository.delete(unwatched.id)
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
        // Dropping the session is not yet the crash: WebKit's network process still commits the
        // last localStorage transaction and closes the store on its own queue. Recovery seals what
        // reached the disk (a crash takes the network process down with the app), so wait for it.
        let reachedDisk = await waitUntil(timeout: 8) { webKitData(of: profile.id, contains: token) }
        if !reachedDisk { info("recovery: the value had not reached the disk after 8 s") }
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

    // MARK: Password AutoFill

    /// US keyboard key codes of the characters the AutoFill checks type.
    private static let keyCodes: [Character: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13,
        "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "9": 25, "7": 26,
        "8": 28, "0": 29, "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46,
    ]

    private enum SignInSubmit { case returnKey, button }

    /// Password AutoFill in a profile window, on the self-test proxy's sign-in pages (`/pb-login`,
    /// `/pb-frame`): the page world sees nothing of it; a sign-in the user typed is offered for
    /// saving — Save, Update for a new password, nothing anywhere on the site after "Never for This
    /// Website" — and a password a page script wrote is not; a login field lists the site's saved
    /// logins and fills the chosen one as Safari does (`input` and `change`, `:autofill` where the
    /// world allows it); a sign-in by script (fields removed after a click) and a sign-up form are
    /// recognised; a frame of another site is offered none. Clicks and typing are real events where
    /// the runner delivers them to the window; otherwise the isolated world is driven directly
    /// (reported).
    private func passwordAutoFill(_ repository: ProfileRepository) async throws {
        guard let httpPort = ProcessInfo.processInfo.environment["PB_SELFTEST_HTTP_PROXY_PORT"].flatMap(Int.init) else {
            info("password AutoFill checks skipped (PB_SELFTEST_HTTP_PROXY_PORT not set)")
            return
        }
        let profile = try repository.create(name: "Passwords", configuration: ProfileConfiguration(
            proxy: ProxySettings(kind: .httpConnect, host: "127.0.0.1", port: httpPort), ephemeral: true))
        let session = try makeSession(repository, profile.id, key: repository.profileKey(for: profile.id))
        let vault = session.passwordVault
        var answer = PasswordPromptAnswer.save
        TabPasswordAutoFill.testPrompts = []
        TabPasswordAutoFill.testFocusLog = []
        TabPasswordAutoFill.testAnswer = { _ in answer }
        let policy = NSApp.activationPolicy()
        defer {
            TabPasswordAutoFill.testAnswer = nil
            AutoFillPanel.current?.dismiss()
            session.shutDown()
            try? repository.delete(profile.id)
            NSApp.setActivationPolicy(policy)
        }
        // Real key and mouse events reach a web view in a key window, which the self-test's
        // .prohibited activation policy never gives.
        NSApp.setActivationPolicy(.accessory)
        NSApp.activate(ignoringOtherApps: true)
        let controller = session.openWindow(url: nil)
        guard let tab = controller.selectedTab, let window = controller.window else {
            check("passwords: a profile window with a tab", false)
            return
        }
        window.makeKeyAndOrderFront(nil)
        let webView = tab.webView
        info("password AutoFill world: \(PasswordAutoFill.worldKind); key window: \(window.isKeyWindow)")

        func open(_ string: String) async -> Bool {
            guard let url = URL(string: string) else { return false }
            AutoFillPanel.current?.dismiss()
            tab.load(url)
            let loaded = await waitUntil(timeout: 15) { !tab.isLoading && tab.url == url }
            _ = window.makeFirstResponder(webView)
            return loaded
        }
        func page(_ body: String, _ arguments: [String: Any] = [:]) async -> Any? {
            try? await js(webView, body, arguments)
        }
        func autoFillWorld(_ body: String, _ arguments: [String: Any] = [:]) async -> Any? {
            try? await js(webView, body, arguments, world: PasswordAutoFill.world)
        }
        func eventually(_ timeout: TimeInterval, _ condition: () async -> Bool) async -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if await condition() { return true }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            return await condition()
        }
        func sendKey(_ keyCode: UInt16, _ characters: String) {
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                if let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [],
                                                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                context: nil, characters: characters, charactersIgnoringModifiers: characters,
                                                isARepeat: false, keyCode: keyCode) {
                    window.sendEvent(event)
                }
            }
        }
        func type(_ text: String) {
            for character in text { sendKey(Self.keyCodes[character] ?? 0, String(character)) }
        }
        /// A click in the middle of `selector`; `frame`: the selector of the iframe it is in.
        func click(_ selector: String, inFrame frame: String? = nil) async -> Bool {
            let script = """
                const frame = frameSelector ? document.querySelector(frameSelector) : null;
                // In the frame: its first input, at the default 8 px body margin.
                if (frame) { const f = frame.getBoundingClientRect(); return [f.left + 8 + 40, f.top + 8 + 8]; }
                const r = document.querySelector(selector).getBoundingClientRect();
                return [r.left + r.width / 2, r.top + r.height / 2];
                """
            guard let center = await page(script, ["selector": selector, "frameSelector": frame ?? ""]) as? [Double],
                  center.count == 2 else { return false }
            let zoom = webView.pageZoom
            let point = webView.convert(NSPoint(x: center[0] * zoom, y: center[1] * zoom), to: nil)
            for (type, pressure) in [(NSEvent.EventType.leftMouseDown, Float(1)), (.leftMouseUp, Float(0))] {
                if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                                  timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                  context: nil, eventNumber: 0, clickCount: 1, pressure: pressure) {
                    window.sendEvent(event)
                }
            }
            try? await Task.sleep(nanoseconds: 150_000_000)
            return true
        }
        var realInput: Bool?
        /// Types the sign-in and submits it (Return, or the page's button); without real input on
        /// this runner, writes the values from the page and marks them typed in the AutoFill world.
        func signIn(_ username: String, _ password: String, confirm: Bool = false, submit: SignInSubmit = .returnKey) async {
            let fields = [("#user", username), ("#pass", password)] + (confirm ? [("#confirm", password)] : [])
            let selectors = fields.map { $0.0 }, values = fields.map { $0.1 }
            if realInput != false {
                for (selector, value) in fields {
                    _ = await click(selector)
                    type(value)
                }
                let typed = await eventually(2) { await self.inputValues(webView, selectors) == values }
                if realInput == nil {
                    realInput = typed
                    info(typed ? "password AutoFill: real clicks and typing reach the page"
                               : "password AutoFill: no real key events reach the page on this runner; the isolated world is driven directly")
                }
                if typed {
                    AutoFillPanel.current?.dismiss()
                    if submit == .returnKey { sendKey(36, "\r") } else { _ = await click("#go") }
                    return
                }
            }
            _ = await page("for (const [s, v] of pairs) document.querySelector(s).value = v; return true;",
                           ["pairs": fields.map { [$0.0, $0.1] }])
            for (selector, _) in fields { _ = await autoFillWorld("return globalThis.__pbPasswords.markTyped(s);", ["s": selector]) }
            if submit == .returnKey {
                _ = await page("document.querySelector('form').requestSubmit(); return true;")
            } else {
                _ = await autoFillWorld("return globalThis.__pbPasswords.arm('#go');")
                _ = await page("document.querySelector('#go').click(); return true;")
            }
        }
        func prompts(_ count: Int) async -> Bool { await waitUntil(timeout: 6) { TabPasswordAutoFill.testPrompts.count >= count } }
        func savedLogins() -> [String] { vault.allEntries().map { "\($0.origin) \($0.username) \($0.password)" } }
        let login = "http://login.selftest.invalid/pb-login"

        guard await open(login) else {
            check("passwords: the sign-in page loads through the proxy", false, tab.url?.absoluteString ?? "nil")
            return
        }
        let pageSees = await page("return [typeof window.webkit, typeof window.__pbPasswords].join(',');") as? String
        check("passwords: the page world sees no AutoFill script and no message handler (no window.webkit, as in Safari)",
              pageSees == "undefined,undefined", pageSees ?? "nil")

        // A page script that fills in and submits a password: not a sign-in by the user.
        _ = await page("document.querySelector('#user').value = 'mallory'; document.querySelector('#pass').value = 'scripted';"
                       + " document.querySelector('form').requestSubmit(); return true;")
        _ = await waitUntil(timeout: 5) { tab.url?.path == "/pb-welcome" && !tab.isLoading }
        try? await Task.sleep(nanoseconds: 700_000_000)
        check("passwords: a password a page script wrote and submitted is not offered for saving",
              TabPasswordAutoFill.testPrompts.isEmpty, "\(TabPasswordAutoFill.testPrompts)")

        // Save.
        _ = await open(login)
        await signIn("ann", "s3cret1")
        let saveAsked = await prompts(1)
        check("passwords: a sign-in the user typed is offered for saving (Save Password), with its user name, and saved",
              saveAsked && TabPasswordAutoFill.testPrompts.first == PasswordPromptRecord(kind: .save, username: "ann", host: "login.selftest.invalid")
                  && savedLogins() == ["http://login.selftest.invalid ann s3cret1"],
              "\(TabPasswordAutoFill.testPrompts) \(savedLogins())")

        // Suggestions under the field; the chosen login filled as Safari fills it.
        _ = await open(login)
        if realInput == true {
            _ = await click("#user")
        } else {
            _ = await autoFillWorld("return globalThis.__pbPasswords.suggest('#user');")
        }
        let listed = await waitUntil(timeout: 5) { AutoFillPanel.current != nil }
        check("passwords: a login field lists the site's saved logins under it",
              listed && AutoFillPanel.current?.titles == ["ann"],
              "\(AutoFillPanel.current?.titles ?? []) focus: \(TabPasswordAutoFill.testFocusLog)")
        AutoFillPanel.current?.choose(at: 0)
        let filledIn = await eventually(5) { await self.inputValues(webView, ["#user", "#pass"]) == ["ann", "s3cret1"] }
        let events = await page("return pbEvents.join(' ');") as? String ?? ""
        check("passwords: choosing a login fills user name and password, with input and change events as Safari's AutoFill",
              filledIn && events.contains("user:input user:change") && events.contains("pass:input pass:change"), events)
        if PasswordAutoFill.worldKind.hasPrefix("autofill") {
            let marked = await page("return document.querySelector('#pass').matches(':-webkit-autofill');") as? Bool
            check("passwords: filled fields are marked :autofill (Safari's highlight)", marked == true, "\(String(describing: marked))")
        } else {
            info("password AutoFill: no AutoFill world in this WebKit; filled fields are not marked :autofill")
        }
        check("passwords: the filled login is marked used (offered first next time)", vault.allEntries().first?.lastUsedAt != nil)
        _ = await page("document.querySelector('form').requestSubmit(); return true;")
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        check("passwords: submitting a filled-in login asks nothing", TabPasswordAutoFill.testPrompts.count == 1,
              "\(TabPasswordAutoFill.testPrompts)")

        // Update.
        _ = await open(login)
        await signIn("ann", "n3wpass2")
        let updateAsked = await prompts(2)
        check("passwords: a new password for a saved user name is offered as Update Password, and replaces the old one",
              updateAsked && TabPasswordAutoFill.testPrompts.last?.kind == .update
                  && savedLogins() == ["http://login.selftest.invalid ann n3wpass2"],
              "\(TabPasswordAutoFill.testPrompts) \(savedLogins())")

        // Never for This Website: nothing asked on any page of the site afterwards.
        answer = .never
        _ = await open(login)
        await signIn("bob", "b0bpass")
        let neverAsked = await prompts(3)
        let neverSites = (try? repository.loadConfiguration(profile.id).passwordNeverSaveSites) ?? []
        answer = .save
        _ = await open("http://www.selftest.invalid/pb-login")
        await signIn("cid", "c1dpass")
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        check("passwords: after Never for This Website nothing is saved or asked on the site",
              neverAsked && neverSites == ["http://login.selftest.invalid"] && TabPasswordAutoFill.testPrompts.count == 3
                  && savedLogins().count == 1,
              "\(neverSites) \(TabPasswordAutoFill.testPrompts) \(savedLogins())")

        // A sign-in by script: no form submission, the fields removed after the button's click.
        _ = await open("http://app.othersite.invalid/pb-login?spa=1")
        await signIn("dan", "d4npass", submit: .button)
        let scriptAsked = await prompts(4)
        check("passwords: a sign-in by script (fields removed after the click) is offered for saving",
              scriptAsked && TabPasswordAutoFill.testPrompts.last == PasswordPromptRecord(kind: .save, username: "dan", host: "app.othersite.invalid"),
              "\(TabPasswordAutoFill.testPrompts)")

        // A sign-up form: the new password (equal to its confirmation) is the one saved.
        _ = await open("http://signup.thirdsite.invalid/pb-login?signup=1")
        await signIn("eve", "e7epass", confirm: true)
        let signUpAsked = await prompts(5)
        check("passwords: a sign-up form's new password is offered for saving",
              signUpAsked && savedLogins().contains("http://signup.thirdsite.invalid eve e7epass"), "\(savedLogins())")

        // A frame of another site inside the page: it is offered nothing saved for the page's site.
        if realInput == true {
            TabPasswordAutoFill.testFocusLog = []
            _ = await open("http://login.selftest.invalid/pb-frame?src=http://evil.othertest.invalid/pb-login")
            try? await Task.sleep(nanoseconds: 1_500_000_000) // the frame's own page loads
            _ = await click("#user", inFrame: "#frame")
            let focused = await waitUntil(timeout: 5) { TabPasswordAutoFill.testFocusLog.contains { $0.hasPrefix("evil.othertest.invalid:") } }
            check("passwords: a login field in a frame of another site is offered none of the page's logins",
                  focused && TabPasswordAutoFill.testFocusLog.contains("evil.othertest.invalid:0") && AutoFillPanel.current == nil,
                  "\(TabPasswordAutoFill.testFocusLog)")
        } else {
            info("password AutoFill: the frame check needs real clicks (a cross-origin frame cannot be focused by script); skipped")
        }
    }

    /// The values of the inputs `selectors` in the page.
    private func inputValues(_ webView: WKWebView, _ selectors: [String]) async -> [String] {
        (try? await js(webView, "return selectors.map((s) => (document.querySelector(s) || {}).value || '');",
                       ["selectors": selectors])) as? [String] ?? []
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

    // MARK: Quit (regression for "WebKit did not release the data store" on ⌘Q)

    /// ⌘Q in a focused page reaches `terminate:` from inside WebKit, which keeps the web view —
    /// and with it the profile's data store — alive until `terminate:` returns. The quit must
    /// still close and seal every profile before the exit: no error, no forced seal (WebKit
    /// released the store), nothing left decrypted, and the data restores.
    private func quitFromFocusedPage(_ repository: ProfileRepository) async throws {
        let layout = WebDataStoreVault.layout
        let vault = WebDataStoreVault(repository: repository)
        let profile = try repository.create(name: "Quit", configuration: ProfileConfiguration())
        let manager = ProfileManager(repository: repository)
        var errors: [String] = []
        manager.onError = { errors.append($0) }
        try await manager.launch(profile.id)
        let token = UUID().uuidString

        var terminateCalls = 0
        let coordinator = QuitCoordinator(hasActivity: { manager.hasActivity },
                                          lockForQuit: {
                                              manager.prepareForQuit()
                                              await manager.shutDown()
                                          },
                                          terminate: { terminateCalls += 1 })
        let delegate = QuitTestDelegate(coordinator: coordinator)
        let previousDelegate = NSApp.delegate
        let previousMenu = NSApp.mainMenu
        NSApp.delegate = delegate
        NSApp.mainMenu = Self.menuWithQuitItem()
        defer {
            NSApp.delegate = previousDelegate
            NSApp.mainMenu = previousMenu
        }

        let path = try await pressCommandQ(in: manager.session(for: profile.id), token: token, delegate: delegate)
        info("quit: ⌘Q reached terminate: \(path)")
        check("quit: terminate: returns at once instead of sealing inside it",
              !delegate.replies.isEmpty && delegate.replies.allSatisfy { $0 == .terminateCancel },
              "replies=\(delegate.replies.map(\.rawValue)) (0 cancel, 1 now, 2 later)")
        let finished = await waitUntil(timeout: 60) { terminateCalls > 0 }
        check("quit: every profile sealed, then terminate: sent again",
              finished && terminateCalls == 1 && !manager.hasActivity,
              "terminate calls=\(terminateCalls) activity=\(manager.hasActivity)")
        check("quit: the second terminate: exits", coordinator.shouldTerminate(NSApp) == .terminateNow)
        check("quit: no seal error", errors.isEmpty, errors.joined(separator: " | "))
        check("quit: WebKit released the store (normal seal, not forced)",
              !FileManager.default.fileExists(atPath: vault.forcedSealMarkerURL(for: profile.id).path))
        check("quit: nothing left decrypted", layout.discoverDirectories(for: profile.id).isEmpty,
              layout.discoverDirectories(for: profile.id).map(\.path).joined(separator: ", "))
        let archive = (try? Data(contentsOf: repository.webDataArchiveURL(for: profile.id))) ?? Data()
        check("quit: archive written, token not in plaintext",
              archive.count > 64 && archive.range(of: Data(token.utf8)) == nil, "\(archive.count) bytes")

        // The sealed data restores on the next launch.
        let key = try repository.profileKey(for: profile.id)
        try await vault.prepareForLaunch(profileID: profile.id, key: key)
        var session: BrowserSession? = try makeSession(repository, profile.id, key: key)
        var web: WKWebView? = WKWebView(frame: .zero, configuration: session!.makeWebViewConfiguration())
        try await PageLoader.load(web!, html: page, baseURL: origin)
        let restored = try await js(web!, "return localStorage.getItem('pb') ?? 'null';") as? String
        check("quit: the sealed data restores", restored == token, restored ?? "nil")
        web = nil
        session?.shutDown()
        session = nil
        try await vault.seal(profileID: profile.id, key: key)
        await vault.deleteData(profileID: profile.id)
        try repository.delete(profile.id)
    }

    /// Loads a page in the profile's tab, writes `token` to its localStorage, focuses the page
    /// and presses ⌘Q in it. Returns how `terminate:` was reached. Holds the tab only while it
    /// runs: afterwards nothing but WebKit itself keeps the page alive.
    private func pressCommandQ(in session: BrowserSession?, token: String, delegate: QuitTestDelegate) async throws -> String {
        guard let tab = session?.windowControllers.first?.selectedTab, let window = tab.webView.window else {
            check("quit: a running profile with a window and a tab", false)
            return "not at all"
        }
        let webView = tab.webView
        try await PageLoader.load(webView, html: page, baseURL: origin)
        _ = try await js(webView, "localStorage.setItem('pb', token); return true;", ["token": token])
        _ = window.makeFirstResponder(webView)
        // WebKit hands ⌘Q to the page first, then re-sends it to AppKit while it retains the web
        // view; the Quit menu item then calls terminate: with WebKit's frames below it.
        if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                                        timestamp: ProcessInfo.processInfo.systemUptime,
                                        windowNumber: window.windowNumber, context: nil,
                                        characters: "q", charactersIgnoringModifiers: "q",
                                        isARepeat: false, keyCode: 12) {
            _ = window.performKeyEquivalent(with: event)
        }
        let reachedThroughWebKit = await waitUntil(timeout: 5) { !delegate.replies.isEmpty }
        if reachedThroughWebKit { return "through WebKit's re-sent key event" }
        // Not re-sent here (no key window on this runner): reproduce what matters, the web view
        // alive on the stack below terminate:, as WebKit holds it.
        withExtendedLifetime(webView) { NSApp.terminate(nil) }
        return "directly, with the web view held below it (WebKit did not re-send ⌘Q on this runner)"
    }

    /// A main menu whose Quit item (⌘Q → terminate:) is what the self-test's key event hits.
    private static func menuWithQuitItem() -> NSMenu {
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let appItem = NSMenuItem()
        appItem.submenu = appMenu
        let mainMenu = NSMenu()
        mainMenu.addItem(appItem)
        return mainMenu
    }

    /// Quit while WebKit keeps a store in use (here: a web view the test holds on to). Without
    /// quit the seal still fails and leaves everything in place; when quitting it is forced —
    /// archive written, plaintext deleted, marker left — and the next launch discards what WebKit
    /// wrote after it and restores the archive.
    private func forcedSealAtQuit(_ repository: ProfileRepository) async throws {
        let layout = WebDataStoreVault.layout
        let vault = WebDataStoreVault(repository: repository)
        vault.retryDelays = [1, 1]
        let profile = try repository.create(name: "Forced seal", configuration: ProfileConfiguration())
        let key = try repository.profileKey(for: profile.id)
        let marker = vault.forcedSealMarkerURL(for: profile.id)
        let token = UUID().uuidString
        try await vault.prepareForLaunch(profileID: profile.id, key: key)
        var session: BrowserSession? = try makeSession(repository, profile.id, key: key)
        var web: WKWebView? = WKWebView(frame: .zero, configuration: session!.makeWebViewConfiguration())
        try await PageLoader.load(web!, html: page, baseURL: origin)
        _ = try await js(web!, "localStorage.setItem('pb', token); return true;", ["token": token])
        session?.shutDown() // the session lets go of the store; the web view still holds it

        do {
            try await vault.seal(profileID: profile.id, key: key)
            check("forced seal: a store in use is not sealed when not quitting", false,
                  "WebKit released a store a live web view still uses")
        } catch {
            check("forced seal: a store in use is not sealed when not quitting",
                  !layout.discoverDirectories(for: profile.id).isEmpty && !FileManager.default.fileExists(atPath: marker.path))
        }

        vault.forceSealWhenStoreStaysInUse = true
        let sealed = try await vault.seal(profileID: profile.id, key: key)
        check("forced seal: used when WebKit keeps the store through every attempt", sealed.forced,
              "attempts=\(sealed.attempts)")
        check("forced seal: plaintext deleted, marker written",
              layout.discoverDirectories(for: profile.id).isEmpty && FileManager.default.fileExists(atPath: marker.path))
        let archive = (try? Data(contentsOf: repository.webDataArchiveURL(for: profile.id))) ?? Data()
        check("forced seal: archive written, token not in plaintext",
              archive.count > 64 && archive.range(of: Data(token.utf8)) == nil, "\(archive.count) bytes")

        // Stands in for the process exit: release the web view and let WebKit drop the store.
        web = nil
        session = nil
        var released = false
        for _ in 0..<15 where !released {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            await vault.deleteData(profileID: profile.id) // remove(forIdentifier:) succeeds once WebKit lets go
            released = !WebDataStoreVault.isRegistered(profile.id)
        }
        check("forced seal: WebKit lets go of the store once nothing holds it", released)

        // What the exit can leave behind: a late WebKit write after the forced seal.
        let lateWrite = sealed.directories.first?.appendingPathComponent("pb-late-write")
        if let lateWrite {
            try FileManager.default.createDirectory(at: lateWrite.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("late".utf8).write(to: lateWrite)
        }
        try await vault.prepareForLaunch(profileID: profile.id, key: key)
        check("forced seal: the next launch discards later residue and the marker",
              lateWrite.map { !FileManager.default.fileExists(atPath: $0.path) } == true
                  && !FileManager.default.fileExists(atPath: marker.path))
        session = try makeSession(repository, profile.id, key: key)
        web = WKWebView(frame: .zero, configuration: session!.makeWebViewConfiguration())
        try await PageLoader.load(web!, html: page, baseURL: origin)
        let restored = try await js(web!, "return localStorage.getItem('pb') ?? 'null';") as? String
        check("forced seal: the archive restores", restored == token, restored ?? "nil")
        web = nil
        session?.shutDown()
        session = nil
        vault.forceSealWhenStoreStaysInUse = false
        vault.retryDelays = [1, 2, 3, 5, 8]
        _ = try? await vault.seal(profileID: profile.id, key: key)
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
        let name = try repository.summary(for: id).name
        return try BrowserSession(profileID: id, profileName: name, configuration: configuration,
                                  passwordVault: try repository.passwordVault(for: id),
                                  passwordSettings: ProfilePasswordSettings(repository: repository, profileID: id, profileName: name,
                                                                            launchConfiguration: configuration),
                                  library: library)
    }

    /// Runs `body` in the page's world (or `world`), as page scripts would.
    private func js(_ webView: WKWebView, _ body: String, _ arguments: [String: Any] = [:],
                    world: WKContentWorld? = nil) async throws -> Any? {
        let world = world ?? .page
        return try await withCheckedThrowingContinuation { continuation in
            webView.callAsyncJavaScript(body, arguments: arguments, in: nil, in: world) { result in
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

    /// Whether `text` is on disk somewhere in the profile's WebKit directories, as UTF-8 or as the
    /// UTF-16 WebKit stores localStorage values in: tells that a write has been committed.
    private func webKitData(of profileID: UUID, contains text: String) -> Bool {
        let needles = [Data(text.utf8), text.data(using: .utf16LittleEndian) ?? Data()].filter { !$0.isEmpty }
        for directory in WebDataStoreVault.layout.discoverDirectories(for: profileID) {
            guard let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else { continue }
            for case let file as URL in files {
                guard let data = try? Data(contentsOf: file), !data.isEmpty else { continue }
                if needles.contains(where: { data.range(of: $0) != nil }) { return true }
            }
        }
        return false
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

/// Stands in for the app delegate while the self-test presses ⌘Q: hands `terminate:` to the
/// coordinator under test, records its answers, and never lets the self-test process exit.
@MainActor
private final class QuitTestDelegate: NSObject, NSApplicationDelegate {
    let coordinator: QuitCoordinator
    private(set) var replies: [NSApplication.TerminateReply] = []

    init(coordinator: QuitCoordinator) {
        self.coordinator = coordinator
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        replies.append(coordinator.shouldTerminate(sender))
        return .terminateCancel
    }
}

/// The UI delegate a self-test web view gets where a tab's behaviour matters (permission queries).
private final class SelfTestUIDelegate: NSObject, WKUIDelegate {}

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
