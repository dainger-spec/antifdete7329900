import AppKit
import BrowserCore
import CryptoKit
import Network
import os
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
        // Every check but the Safari-chrome one drives sessions of this process; that one asks for a
        // process of its own explicitly.
        setenv("PB_PROFILE_PROCESS", "0", 1)
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        // A hung check must not hold CI; the whole run takes about five minutes on the runner.
        DispatchQueue.main.asyncAfter(deadline: .now() + 600) {
            print("SELFTEST TIMEOUT after 600 s")
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
        // scripts/disk_check.py: what is written in here is the self-test's own.
        info("vault \(root.path)")
        let repository: ProfileRepository
        do {
            repository = try ProfileRepository(vault: MasterVault.create(in: root, password: "self-test", iterations: 10_000))
            try await firstWebKitUse(repository) // must run before anything else touches WebKit
        } catch {
            check("self-test ran without unexpected errors", false, String(describing: error))
            return
        }
        // A profile with a proxy does not start without the proxied profile's rule list (ContentRules).
        await ContentRules.prepare()
        info("WebKit \(WebKitBuild.version)")
        debugSwitchesStayDebugSwitches()
        // Each group on its own: an error one did not expect fails that group, by name, and the
        // run goes on with the next, so that one error never hides the checks after it.
        await group("exceptions") { try await exceptionChecks() }
        await group("Safari's nibs") { try await safariNibChecks() }
        await group("storage isolation and shims") { try await storageIsolationAndShims(repository) }
        await group("device generations") { try await deviceGenerations(repository) }
        await group("fingerprint surface") { try await fingerprintSurface(repository) }
        await group("recovery sealing") { try await recoverySealing(repository) }
        await group("format policy") { try formatPolicy(repository) }
        await group("earlier versions' Safari keys") { earlierVersionsSafariKeys() }
        await group("update gate") { try updateGate(repository) }
        await group("settings") { try await appSettings(repository) }
        await group("editor labels") { try editorLabels() }
        await group("window sizes") { try await windowSizes(repository) }
        await group("named Safari version") { try await namedSafariVersion(repository) }
        await group("local requests") { try await localRequests(repository) }
        await group("cookies at creation") { try await cookiesAtCreation(repository) }
        await group("diagnostics") { try await diagnosticsBundle(repository) }
        await group("paste as typed") { try await pasteAsTyped(repository) }
        await group("what sites see") { try await whatSitesSee(repository) }
        await group("deleting profiles") { try await deleteProfiles(repository) }
        await group("proxies") { try await proxies(repository) }
        await group("certificates") { try await certificatesWithoutFetching(repository) }
        await group("hand-offs") { try await handOffsInOurWindows(repository) }
        await group("workers") { try await workersInOurWindows(repository) }
        await group("proxy location at launch") { try await proxyLocationAtLaunch(repository) }
        await group("SOCKS5 profiles side by side") { try await socksProfilesSideBySide(repository) }
        await group("proxy lookup and exit IP") { try await proxyLookupAndExitIP(repository) }
        await group("proxy checker") { try await proxyChecker(repository) }
        await group("tabs and library") { try await tabsAndLibrary(repository) }
        await group("restoring tabs") { try await restoreTabs(repository) }
        await group("window lifecycle") { try await windowLifecycle(repository) }
        await group("dialogs") { try await dialogTeardown(repository) }
        await group("password AutoFill") { try await passwordAutoFill(repository) }
        await group("cookie import") { try await cookieImport(repository) }
        await group("session cookies after a stop") { try await sessionCookieAfterStop(repository) }
        await group("profile transfer") { try await profileTransfer(repository) }
        await group("automation API") { try await automationAPI(repository) }
        await group("profile sync") { try await profileSync(repository) }
        await group("warm-up") { try await warmUp(repository) }
        await group("warm-up queue") { try await warmUpQueue(repository) }
        await group("Safari chrome") { try await safariChromeThroughTheProxy(repository) }
        await group("lock during launch") { try await lockDuringLaunch(repository) }
        await group("quit") { try await quitFromFocusedPage(repository) }
        await group("forced seal") { try await forcedSealAtQuit(repository) }
    }

    /// One group of checks: an error it throws, which none of its checks expected, fails the group
    /// by name with the error, and the self-test goes on. With `PB_SELFTEST_ONLY` set (group names,
    /// comma-separated), only those groups run: a measurement of one (scripts/aia_variants.py).
    private func group(_ name: String, _ body: () async throws -> Void) async {
        if let only = ProcessInfo.processInfo.environment["PB_SELFTEST_ONLY"],
           !only.split(separator: ",").contains(where: { $0 == name }) { return }
        do {
            try await body()
        } catch {
            check("\(name): ran without unexpected errors", false, String(describing: error))
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

        // Every proxied session carries the proxied profile's rule list (dns-prefetch would resolve outside
        // the proxy; see ContentRules).
        await ContentRules.prepare()
        check("proxy: the rule list of profiles with a proxy compiled (pings, dns-prefetch, this Mac)", ContentRules.proxiedProfileRules != nil,
              ContentRules.compileErrors.joined(separator: " | "))

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

        // What WebKit would send outside the proxy is blocked by the proxied profile's rule list: an
        // <a ping> (the same load type as a dns-prefetch) never reaches the proxy, a fetch does.
        do {
            let served = try await servedPathsAfterPing(repository, ProxySettings(kind: .httpConnect, host: "127.0.0.1", port: httpPort))
            check("proxy: ping-type loads (dns-prefetch, <a ping>) are blocked in a proxied profile",
                  served.contains("/fetch-allowed") && !served.contains("/ping-blocked"), served.joined(separator: ","))
            info("proxy: a beacon \(served.contains("/beacon") ? "still reaches" : "does not reach") the proxy (beacons are fetches, not pings)")
        } catch {
            check("proxy: ping-type loads (dns-prefetch, <a ping>) are blocked in a proxied profile", false, String(describing: error))
        }
        do {
            try await fragmentJumps(repository, http: ProxySettings(kind: .httpConnect, host: "127.0.0.1", port: httpPort),
                                    socks: ProxySettings(kind: .socks5, host: "127.0.0.1", port: socksPort))
        } catch {
            info("fragment jump: not measured — \(error)")
        }

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

    /// In a page served by the proxy: sends a beacon and a fetch to the proxy and clicks an
    /// `<a ping>`, then reads back which paths the proxy served (`/pb-served.json`).
    ///
    /// The click is the page script's last act, and the script answers right after it. The link
    /// goes to a fragment of the page, and WebKit 27 (macOS 27.0.1) makes a new document of such a
    /// jump for a page loaded through the proxy (CI runs 432–435; a page of this Mac keeps its
    /// document, in Safari 27 and in profiles alike — `fragmentJumps`): a script that waited across
    /// the click lost the document it ran in, and WebKit answered WKErrorDomain 5. The pause for
    /// the ping is waited out here, and the served paths are read afterwards, in whichever
    /// document the page then is.
    private func servedPathsAfterPing(_ repository: ProfileRepository, _ proxy: ProxySettings) async throws -> [String] {
        let profile = try repository.create(name: "Ping", configuration: ProfileConfiguration(proxy: proxy, ephemeral: true))
        let session = try makeSession(repository, profile.id, key: repository.profileKey(for: profile.id))
        defer { session.shutDown() }
        let webView = WKWebView(frame: .zero, configuration: session.makeWebViewConfiguration())
        try await PageLoader.load(webView, url: URL(string: "http://proxied.selftest.invalid/ping-page")!)
        _ = try await js(webView, Self.pingScript)
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        _ = await waitUntil(timeout: 10) { !webView.isLoading }
        return try await js(webView, Self.readServedPaths) as? [String] ?? []
    }

    /// The page's actions: a beacon, a fetch, and last an `<a ping>` clicked.
    private static let pingScript = """
        navigator.sendBeacon('/beacon', 'x');
        await fetch('/fetch-allowed');
        const a = document.createElement('a');
        a.href = '#clicked'; a.ping = '/ping-blocked'; a.textContent = 'ping';
        document.body.appendChild(a);
        a.click();
        return true;
        """
    /// What the proxy has served, as it lists it.
    private static let readServedPaths = "return await (await fetch('/pb-served.json', { cache: 'no-store' })).json();"

    /// A jump to a fragment of the page shown (`location.hash`): does the page keep its document?
    /// Measured, not checked. WebKit 27 (macOS 27.0.1) makes a new document of it for a page loaded
    /// through a proxy — by name and by address alike —, where a page of this Mac, which goes
    /// direct, keeps its document — in Safari 27, in profiles as they ship and in a plain web view
    /// alike (CI runs 435 and 436, `scripts/fragment_check.py`). Measured here: in a profile with
    /// the HTTP proxy, a page through it by name, one by address, and a page of this Mac; the page
    /// by name through a SOCKS5 profile; and in a plain web view whose non-persistent store has
    /// only WebKit's own proxy setting — no profile, no script, no rule list.
    private func fragmentJumps(_ repository: ProfileRepository, http: ProxySettings, socks: ProxySettings) async throws {
        let local = SiteSnapshotServer { _, _ in "<!doctype html><html><head><title>Plain page</title></head><body><p>A page of this Mac.</p></body></html>" }
        guard await local.start() else {
            info("fragment jump: no page of this Mac could be served")
            return
        }
        defer { local.stop() }
        let profile = try repository.create(name: "Fragment", configuration: ProfileConfiguration(proxy: http, ephemeral: true))
        let session = try makeSession(repository, profile.id, key: repository.profileKey(for: profile.id))
        defer { session.shutDown() }
        let socksProfile = try repository.create(name: "Fragment SOCKS5", configuration: ProfileConfiguration(proxy: socks, ephemeral: true))
        let socksSession = try makeSession(repository, socksProfile.id, key: repository.profileKey(for: socksProfile.id))
        defer { socksSession.shutDown() }
        enum Setup { case profile, socksProfile, plainWebView }
        let byName = URL(string: "http://proxied.selftest.invalid/fragment")!
        let pages: [(label: String, url: URL, setup: Setup)] = [
            ("through the proxy, by name", byName, .profile),
            ("through the proxy, by address", URL(string: "http://198.18.0.15/fragment")!, .profile),
            ("a page of this Mac, direct", local.newPage(.profile).url, .profile),
            ("through a SOCKS5 proxy, by name", byName, .socksProfile),
            ("through the proxy, by name, in a plain web view (WebKit's own proxy setting; no profile, script or rule list)",
             byName, .plainWebView),
        ]
        let mark = "window.__pbMark = 'marked'; return true;"
        for page in pages {
            let configuration: WKWebViewConfiguration
            switch page.setup {
            case .profile:
                configuration = session.makeWebViewConfiguration()
            case .socksProfile:
                configuration = socksSession.makeWebViewConfiguration()
            case .plainWebView:
                configuration = WKWebViewConfiguration()
                let store = WKWebsiteDataStore.nonPersistent()
                store.proxyConfigurations = try ProxyConfigurationFactory.make(http)
                configuration.websiteDataStore = store
            }
            let webView = WKWebView(frame: .zero, configuration: configuration)
            let counter = NavigationCounter()
            var line = "fragment jump, \(page.label): "
            do {
                try await PageLoader.load(webView, url: page.url)
                webView.navigationDelegate = counter
                _ = try await js(webView, mark)
                _ = try await js(webView, "location.hash = 'jump'; return true;")
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                _ = await waitUntil(timeout: 10) { !webView.isLoading }
                let same = try await js(webView, "return String(window.__pbMark);") as? String == "marked"
                line += (same ? "the same document" : "a new document") + " (navigation \(counter.summary))"
            } catch {
                line += Self.javaScriptError(error) + " (navigation \(counter.summary))"
            }
            info(line)
        }
    }

    /// Counts what WebKit tells a web view's navigation delegate, same-document navigations
    /// (`_webView:navigation:didSameDocumentNavigation:`) included.
    private final class NavigationCounter: NSObject, WKNavigationDelegate {
        private(set) var started = 0
        private(set) var committed = 0
        private(set) var finished = 0
        private(set) var failed = 0
        private(set) var sameDocument: [Int] = []

        var summary: String {
            "started \(started), committed \(committed), finished \(finished), failed \(failed), same-document \(sameDocument)"
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { started += 1 }
        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) { committed += 1 }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finished += 1 }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failed += 1 }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failed += 1 }
        @objc(_webView:navigation:didSameDocumentNavigation:)
        func sameDocumentNavigation(_ webView: WKWebView, navigation: WKNavigation?, type: Int) { sameDocument.append(type) }
    }

    /// A preferences file's keys and when it was written, as one line (or "absent"), read as a file.
    private static func preferencesFileState(_ path: String) -> String {
        guard let data = FileManager.default.contents(atPath: path),
              let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] else {
            return "absent"
        }
        let written = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        return "\(plist.count) keys (\(plist.keys.sorted().joined(separator: ", "))), written \(written.map { "\($0)" } ?? "?")"
    }

    private static func javaScriptError(_ error: Error) -> String {
        let error = error as NSError
        let message = error.userInfo["WKJavaScriptExceptionMessage"] as? String
        return "\(error.domain) \(error.code) \(error.localizedDescription)" + (message.map { " — \($0)" } ?? "")
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


    // MARK: Certificates, checked without this Mac fetching for them

    /// The certificate of a site whose server sent its chain incomplete is completed by the
    /// system's trust service, which downloads the missing certificate from the address the
    /// certificate names — as this Mac, outside every proxy (`ServerTrust`). The self-test proxy
    /// answers every TLS handshake in its tunnels with such a certificate, naming
    /// `pbaiacanary.leak.example.com`: a DNS query for that name anywhere in the capture is a
    /// fetch made for a profile with a proxy (scripts/egress_check.py). Its control is the same
    /// kind of certificate, naming `pbaiacontrol`, loaded in a profile without a proxy, where the
    /// system's default handling does fetch: the capture has to see that one.
    private func certificatesWithoutFetching(_ repository: ProfileRepository) async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let httpPort = environment["PB_SELFTEST_HTTP_PROXY_PORT"].flatMap(Int.init) else {
            info("certificate checks skipped (PB_SELFTEST_HTTP_PROXY_PORT not set)")
            return
        }
        info("egress-token pbaiacanary")
        info("egress-token pbocspcanary")
        // What the load ended with, as WebKit gave it to the tab (`describeFailure`).
        func load(_ url: URL, in configuration: ProfileConfiguration) async throws -> String {
            let profile = try repository.create(name: "Certificates", configuration: configuration)
            let session = try makeSession(repository, profile.id, key: repository.profileKey(for: profile.id))
            defer { session.shutDown() }
            let tab = BrowserTab(configuration: session.makeWebViewConfiguration(), context: session.tabContext)
            defer { tab.tearDown() }
            tab.webView.load(URLRequest(url: url))
            _ = await waitUntil(timeout: 20) { !tab.isLoading }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            return describeFailure(tab.lastProvisionalError)
        }
        if let controlPort = environment["PB_SELFTEST_TLS_CONTROL_PORT"].flatMap(Int.init) {
            _ = try await load(URL(string: "https://localhost:\(controlPort)/pb-aia-control")!, in: ProfileConfiguration(ephemeral: true))
            info("egress-control pbaiacontrol")
        }

        let run = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12)).lowercased()
        let proxy = ProxySettings(kind: .httpConnect, host: "127.0.0.1", port: httpPort)
        let before = ServerTrust.tally.counts
        let allowedBefore = ServerTrust.tally.fetchAllowed
        let failure = try await load(URL(string: "https://aia-\(run).leak.example.com/pb-leak/aia?run=\(run)")!,
                                     in: ProfileConfiguration(proxy: proxy, ephemeral: true))
        let after = ServerTrust.tally.counts
        let allowedAfter = ServerTrust.tally.fetchAllowed
        // How the load ended: what its error carried (CI compares the SDKs WebKit's behaviors
        // follow, scripts/aia_variants.py).
        info("certificates: through the proxy, the load ended with: \(failure)")
        let log = try await loadThroughProxy(repository, proxy, url: URL(string: "http://proxied.selftest.invalid/pb-leak/log.json?run=\(run)")!) ?? ""
        guard log.contains("(tls handshake)") else {
            check("certificates: the self-test proxy answers HTTPS with its certificate", false,
                  "no TLS handshake in its log (no openssl on this Mac?): \(log.prefix(300))")
            return
        }
        check("certificates: with a proxy, a certificate whose chain needs a fetch is checked without one, and refused",
              after.refused > before.refused, "evaluations \(before) → \(after)")
        // The order of the calls is what keeps the fetch off (ServerTrust.evaluate): the trusts
        // evaluated must say themselves that they may not fetch.
        check("certificates: every trust evaluated says itself it may not fetch (policies set first, then fetching off)",
              allowedAfter == allowedBefore && allowedAfter == 0, "still allowed to fetch: \(allowedBefore) → \(allowedAfter)")
        check("certificates: the browser refused it at the handshake, through the proxy",
              log.contains("tls refused by the client"), String(log.prefix(400)))
    }

    /// The error a load ended with: its domain and code and the keys it carried. A server trust
    /// among them is not read: reading one can have it evaluated, fetching allowed (`ServerTrust`).
    private func describeFailure(_ error: NSError?) -> String {
        guard let error else { return "no failure" }
        var parts = ["\(error.domain) \(error.code)", "keys [\(error.userInfo.keys.sorted().joined(separator: ", "))]"]
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            parts.append("underlying \(underlying.domain) \(underlying.code) keys [\(underlying.userInfo.keys.sorted().joined(separator: ", "))]")
        }
        return parts.joined(separator: "; ")
    }

    // MARK: Nothing of a page handed outside the profile

    /// A profile's tab in a window of ours: no link preview (Quick Look fetches the link outside
    /// the profile, and a click opens it in the default browser), no Services for the selection,
    /// and a context menu without the items that send the page's content elsewhere (`HandOffs`).
    private func handOffsInOurWindows(_ repository: ProfileRepository) async throws {
        HandOffs.closeForWebViews()
        // (And the plaintext of profiles running in this process is out of backups.)
        let excluded = WebDataStoreVault.layout.searchRoots.allSatisfy {
            (try? $0.resourceValues(forKeys: [.isExcludedFromBackupKey]))?.isExcludedFromBackup == true
        }
        let backupDetail = WebDataStoreVault.layout.searchRoots.map(\.path).joined(separator: ", ")
            + " — ran: \(WebDataStoreVault.rootsExclusionRan), failures: \(WebDataStoreVault.exclusionFailures)"
        if AppEnvironment.isSandboxed && !excluded {
            // Measured (CI runs 383–384): in the App Sandbox the mark is set without an error and
            // does not stay on the container's folders. A limitation of the sandboxed build
            // (docs/ISOLATION_AND_LIMITATIONS.md §3), reported here with what writing it directly did.
            info("backups: in the sandboxed build WebKit's directories of this app cannot be excluded from Time Machine: \(backupDetail)")
        } else {
            check("backups: WebKit's directories of this app are excluded from Time Machine", excluded, backupDetail)
        }
        let profile = try repository.create(name: "Hand-offs", configuration: ProfileConfiguration(ephemeral: true))
        let session = try makeSession(repository, profile.id, key: repository.profileKey(for: profile.id))
        defer { session.shutDown() }
        let tab = BrowserTab(configuration: session.makeWebViewConfiguration(), context: session.tabContext)
        defer { tab.tearDown() }
        tab.webView.allowsLinkPreview = true
        check("hand-offs: a profile's web view shows no link preview, and cannot be given one", !tab.webView.allowsLinkPreview)
        check("hand-offs: a profile's page offers its selection to no Service",
              tab.webView.validRequestor(forSendType: .string, returnType: nil) == nil)
        let menu = NSMenu()
        let kept = ["WKMenuItemIdentifierCopy", "WKMenuItemIdentifierOpenLinkInNewWindow"]
        for identifier in kept + HandOffs.refusedMenuItems.sorted() {
            let item = NSMenuItem(title: identifier, action: nil, keyEquivalent: "") // l10n: not text
            item.identifier = NSUserInterfaceItemIdentifier(identifier)
            menu.addItem(item)
            menu.addItem(.separator())
        }
        var stripped: NSMenu?
        tab.webView(tab.webView, contextMenuFromProposedMenu: menu, forElement: nil, userInfo: nil) { stripped = $0 }
        check("hand-offs: the context menu keeps Copy and the link items, and loses Search with Google, Look Up, Translate, Share, Quick Note and Writing Tools, and Services",
              stripped?.items.compactMap(\.identifier?.rawValue) == kept && stripped?.allowsContextMenuPlugIns == false,
              "\(stripped?.items.map(\.title) ?? [])")
    }

    // MARK: Workers of a profile with a proxy, in this process

    /// Shared and service workers take their preferences from the process, not from the page that
    /// starts them: WebKit copies the first web view's (`ProfileNetworkGuard.ensureWorkerTemplate`).
    /// The manager's process makes no template (it kept stopped profiles' sessions alive), so here
    /// the workers of a profile with a proxy are measured in a window of ours, after profiles
    /// without one have had theirs: on a page of this Mac (a secure context, where WebTransport
    /// exists at all), in the page, a dedicated, a shared and a service worker.
    private func workersInOurWindows(_ repository: ProfileRepository) async throws {
        guard let httpPort = ProcessInfo.processInfo.environment["PB_SELFTEST_HTTP_PROXY_PORT"].flatMap(Int.init) else {
            info("worker checks skipped (PB_SELFTEST_HTTP_PROXY_PORT not set)")
            return
        }
        let proxy = ProxySettings(kind: .httpConnect, host: "127.0.0.1", port: httpPort)
        // `connect`: whether the page and its service worker, where WebTransport exists, try a
        // connection to a documentation address — which the capture counts anywhere in the run.
        // The control without a proxy only says what exists (it would go straight out, as it
        // should); the profile with a proxy tries, so that one that could would be seen.
        func reports(_ configuration: ProfileConfiguration, connect: Bool) async throws -> (page: [String: Any], serviceWorker: [String: Any]) {
            let run = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12)).lowercased()
            let profile = try repository.create(name: "Workers \(run)", configuration: configuration)
            defer { try? repository.delete(profile.id) }
            let session = try makeSession(repository, profile.id, key: repository.profileKey(for: profile.id))
            defer { session.shutDown() }
            let webView = WKWebView(frame: .zero, configuration: session.makeWebViewConfiguration())
            try? await PageLoader.load(webView, url: URL(string: "http://127.0.0.1:\(httpPort)/pb-leak/secure?run=\(run)&connect=\(connect ? 1 : 0)")!)
            let logURL = URL(string: "http://proxied.selftest.invalid/pb-leak/log.json?run=\(run)")!
            var page: [String: Any] = [:], serviceWorker: [String: Any] = [:]
            for _ in 0..<12 {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard let text = try await loadThroughProxy(repository, proxy, url: logURL),
                      let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { continue }
                let found = object["reports"] as? [[String: Any]] ?? []
                page = found.first { $0["secure"] != nil } ?? page
                serviceWorker = found.first { $0["sw"] as? Bool == true && $0["secure"] == nil } ?? serviceWorker
                if !page.isEmpty && !serviceWorker.isEmpty { break }
            }
            return (page, serviceWorker)
        }
        let open = try await reports(ProfileConfiguration(ephemeral: true), connect: false)
        info("workers: a profile without a proxy has WebTransport in its page \(open.page["webTransport"] ?? "nil"), shared worker \(open.page["shared"] ?? "nil"), service worker \(open.serviceWorker["webTransport"] ?? "nil")")
        let proxied = try await reports(ProfileConfiguration(proxy: proxy, ephemeral: true), connect: true)
        check("workers: a profile with a proxy, after profiles without one, has no WebTransport in its page, a dedicated, a shared or a service worker (each answered)",
              proxied.page["secure"] as? Bool == true && proxied.page["webTransport"] as? String == "undefined"
                && proxied.page["worker"] as? String == "undefined" && proxied.page["shared"] as? String == "undefined"
                && proxied.serviceWorker["webTransport"] as? String == "undefined",
              "page \(proxied.page), service worker \(proxied.serviceWorker.isEmpty ? "no report" : "\(proxied.serviceWorker)")")
    }

    // MARK: The local automation API

    /// A script on this Mac drives a profile through the API (`AutomationServer`) as the app's own
    /// buttons do — list, start out of sight, cookies in and out, stop — and nothing else gets in:
    /// no token, a wrong one, a web page's request, a name pointed at 127.0.0.1. What it answers
    /// never holds a proxy's credentials. Requests go over a plain socket, so that their headers
    /// are exactly the ones written here.
    private func automationAPI(_ repository: ProfileRepository) async throws {
        let manager = ProfileManager(repository: repository)
        manager.onError = { _ in }
        let token = AutomationSettings.newToken()
        let handler = AutomationHandler(manager: manager, repository: repository)
        let server = AutomationServer(settings: AutomationSettings(isEnabled: true, port: 0, token: token), handler: handler)
        server.start()
        defer { server.stop() }
        guard AutomationServer.isAvailable else {
            check("automation: the sandboxed build does not listen, and says why",
                  server.state == .failed(L("automation.error.sandboxed")), "\(server.state)")
            return
        }
        _ = await waitUntil(timeout: 10) { if case .listening = server.state { return true } else { return false } }
        guard case .listening(let port) = server.state else {
            check("automation: the API listens on the loopback address", false, "\(server.state)")
            return
        }
        let run = String(UUID().uuidString.prefix(8)).lowercased()
        let secret = "api-secret-\(run)"
        let profile = try repository.create(name: "API \(run)", configuration: ProfileConfiguration(
            proxy: ProxySettings(kind: .httpConnect, host: "127.0.0.1", port: 9, username: "api-user-\(run)", password: secret),
            ephemeral: true))
        defer { try? repository.delete(profile.id) }

        func call(_ method: String, _ path: String, token given: String? = nil, host: String? = nil,
                  extra: [String: String] = [:], body: String = "") async -> (status: Int, body: String) {
            var head = "\(method) \(path) HTTP/1.1\r\nHost: \(host ?? "127.0.0.1:\(port)")\r\n"
            head += "Authorization: Bearer \(given ?? token)\r\n"
            for (name, value) in extra { head += "\(name): \(value)\r\n" }
            head += "Content-Length: \(body.utf8.count)\r\n\r\n"
            let request = Data((head + body).utf8)
            let answer = await Task.detached { Self.rawHTTP(port: port, request) }.value
            guard let answer, let text = String(data: answer, encoding: .utf8),
                  let statusText = text.split(separator: " ", maxSplits: 2).dropFirst().first, let status = Int(statusText) else {
                return (0, "")
            }
            return (status, text.components(separatedBy: "\r\n\r\n").dropFirst().joined(separator: "\r\n\r\n"))
        }
        let base = "/v1/profiles/\(profile.id.uuidString)"
        check("automation: a request without the token is refused", await call("GET", "/v1/profiles", token: "").status == 401)
        check("automation: a request with a wrong token is refused", await call("GET", "/v1/profiles", token: token + "x").status == 401)
        check("automation: a web page's request is refused, with the token too",
              await call("GET", "/v1/profiles", extra: ["Origin": "https://attacker.example"]).status == 403)
        check("automation: a name pointed at 127.0.0.1 is refused (DNS rebinding)",
              await call("GET", "/v1/profiles", host: "attacker.example:\(port)").status == 403)

        let list = await call("GET", "/v1/profiles")
        check("automation: the profiles are listed, with their proxy but not its credentials",
              list.status == 200 && list.body.contains(profile.id.uuidString) && list.body.contains("http://127.0.0.1:9")
                && !list.body.contains(secret) && !list.body.contains("api-user-\(run)"),
              "\(list.status) \(list.body.prefix(300))")
        check("automation: an unknown profile is not found", await call("GET", "/v1/profiles/nobody-\(run)").status == 404)

        let started = await call("POST", base + "/start", body: "{\"window\": false}")
        check("automation: a profile starts out of sight", started.status == 200 && manager.isRunning(profile.id),
              "\(started.status) \(started.body.prefix(200))")
        let expiry = Int(Date().addingTimeInterval(3600).timeIntervalSince1970)
        let cookieFile = "api-\(run).test\tFALSE\t/\tFALSE\t\(expiry)\tpbapi\t\(run)\n"
        let imported = await call("POST", base + "/cookies", body: cookieFile)
        check("automation: cookies go into the running profile", imported.status == 200 && imported.body.contains("\"applied\" : 1"),
              "\(imported.status) \(imported.body.prefix(200))")
        let exported = await call("GET", base + "/cookies?format=netscape")
        check("automation: the profile's cookies come back out", exported.status == 200 && exported.body.contains("\tpbapi\t\(run)"),
              "\(exported.status) \(exported.body.prefix(300))")
        check("automation: only an http or https address is opened",
              await call("POST", base + "/open", body: "{\"url\": \"file:///etc/passwd\"}").status == 400)
        let stopped = await call("POST", base + "/stop")
        check("automation: the profile stops", stopped.status == 200 && !manager.isRunning(profile.id), "\(stopped.status)")

        server.stop()
        let afterStop = await Task.detached { Self.rawHTTP(port: port, Data("GET / HTTP/1.1\r\n\r\n".utf8)) }.value
        check("automation: nothing answers once the API is off", afterStop == nil || afterStop?.isEmpty == true,
              afterStop.map { String(decoding: $0.prefix(120), as: UTF8.self) } ?? "no connection")
    }

    /// One request on a plain socket to 127.0.0.1:`port`, and everything that comes back until the
    /// other side closes; nil when no connection could be made.
    nonisolated static func rawHTTP(port: Int, _ request: Data) -> Data? {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var timeout = timeval(tv_sec: 60, tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard connected == 0 else { return nil }
        let sent = request.withUnsafeBytes { send(descriptor, $0.baseAddress, $0.count, 0) }
        guard sent == request.count else { return nil }
        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = recv(descriptor, &buffer, buffer.count, 0)
            if count <= 0 { break }
            response.append(contentsOf: buffer[0..<count])
        }
        return response
    }

    // MARK: Safari's chrome, in a profile's own process, through that profile's proxy

    /// The check this product cannot do without: a profile whose window is Safari's own chrome
    /// sends nothing outside the profile's proxy — not its pages, not anything in them, not
    /// Safari's own clients in its process.
    ///
    /// Every other proxy check here runs in a window of ours, where the web view is built from our
    /// own configuration. In Safari's chrome the web views are Safari's to build, with Safari's
    /// preferences, next to Safari's own network clients; so this runs the real thing: a profile in
    /// a process of its own (`ProfileProcess`), its window Safari's, its start page the leak page
    /// of the self-test proxy (`/pb-leak`), on a host that only the proxy answers. That page makes
    /// every kind of request a page can make, to addresses in the documentation ranges and to host
    /// names carrying this run's id, and says what it could see. Here it is checked that each of
    /// those requests reached the proxy, and what the page and the profile's process report; the
    /// other half — that nothing went around the proxy — is a capture of the machine's traffic
    /// around this check (scripts/egress_check.py, in CI), for which the lines `egress-*` below
    /// say when this check ran and which run id to look for.
    private func safariChromeThroughTheProxy(_ repository: ProfileRepository) async throws {
        guard let httpPort = ProcessInfo.processInfo.environment["PB_SELFTEST_HTTP_PROXY_PORT"].flatMap(Int.init) else {
            info("Safari-chrome proxy check skipped (PB_SELFTEST_HTTP_PROXY_PORT not set)")
            return
        }
        // A process per profile, and Safari's frameworks inside it, is a feature of the
        // unsandboxed build (it needs library validation off); the sandboxed one cannot do it.
        guard !AppEnvironment.isSandboxed else {
            info("Safari-chrome proxy check skipped (the sandboxed build runs no process per profile)")
            return
        }
        let proxy = ProxySettings(kind: .httpConnect, host: "127.0.0.1", port: httpPort)
        // The port the leak page asks for on loopback, where the proxy's canary listener notes any
        // connection that comes straight to it (1 when the proxy runs without one).
        let canaryPort = ProcessInfo.processInfo.environment["PB_SELFTEST_CANARY_PORT"].flatMap(Int.init) ?? 1
        let run = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12)).lowercased()
        // An ordinary name rather than ".invalid": the system resolver would really ask the network
        // about it (and the capture would see the run id), where ".invalid" may be answered on the Mac.
        let domain = "leak.example.com"
        let startPath = "/pb-leak?run=\(run)"
        // A time zone the runner is not in, to tell the profile's from the Mac's in workers.
        let zone = "Pacific/Chatham"
        let profile = try repository.create(name: "Safari chrome", configuration: ProfileConfiguration(
            startURL: URL(string: "http://start-\(run).\(domain)\(startPath)"), proxy: proxy, timeZoneIdentifier: zone,
            matchProxyLocation: false))
        let manager = ProfileManager(repository: repository)
        var messages: [String] = []
        manager.onError = { messages.append($0) }
        var hostsChrome: Bool?
        manager.onProfileRunning = { _, hosts in hostsChrome = hosts }
        var networkReport: ProfileNetworkReport?
        manager.onNetworkReport = { _, report in networkReport = report }
        var sealReport: ProfileSealReport?
        manager.onChildSealed = { _, report in sealReport = report }

        info("egress-token \(run)")
        info("egress-window begin \(Date().timeIntervalSince1970)")
        // The account's own com.apple.Safari preferences outside Safari's container, as a file:
        // a profile's settings for Safari's services stay in its process (SafariChrome).
        let accountSafariPreferences = SafariPaths.realHome.map { $0 + "/Library/Preferences/com.apple.Safari.plist" }
        let accountSafariBefore = accountSafariPreferences.map(Self.preferencesFileState)
        // The XPC services that start while the profile runs, and what they hold open in the real
        // Safari's places: the profile's guard does not see a service asked for through libxpc.
        let xpcWatch = SafariPaths.realHome.map { XPCServiceWatch(realHome: $0) }
        defer { _ = xpcWatch?.stop() }
        var profilePIDs: Set<pid_t> = []
        // The per-profile process is off by default; this one check is what it is for.
        setenv("PB_PROFILE_PROCESS", "1", 1)
        // Variables of the manager's own that a profile's process must not inherit: one of the
        // manager's, and one that would change what the process does (it would open no window).
        setenv("PB_INHERIT_CANARY", run, 1)
        setenv("PB_WARM_UP_ONLY", "1", 1)
        let managerEnvironment = Set(ProcessInfo.processInfo.environment.keys)
        defer {
            unsetenv("PB_INHERIT_CANARY")
            unsetenv("PB_WARM_UP_ONLY")
        }
        do {
            try await manager.launch(profile.id)
        } catch {
            setenv("PB_PROFILE_PROCESS", "0", 1)
            check("Safari chrome: the profile's own process started", false, String(describing: error))
            return
        }
        setenv("PB_PROFILE_PROCESS", "0", 1)
        unsetenv("PB_INHERIT_CANARY")
        unsetenv("PB_WARM_UP_ONLY")
        if let pid = manager.processIdentifier(of: profile.id) { info("egress-pid \(pid)"); profilePIDs.insert(pid) }
        let started = await waitUntil(timeout: 90) { hostsChrome != nil }
        check("Safari chrome: the profile's own process started and reported its window",
              started, "no 'running' came back (the process may have died; see its own log)")
        // What a selection's Launch waits for before it starts the next profile (LaunchQueue): the
        // same word from the profile's process.
        let windowSeen = await manager.waitForWindow(profile.id, seconds: 5)
        check("Safari chrome: a selection's Launch sees the profile's window up once its process says so",
              windowSeen || !started, "the process said its window was up; the manager's wait did not")
        check("Safari chrome: the window is Safari's own chrome", hostsChrome == true,
              "the profile opened our own window: this Mac would not host Safari's chrome")

        // What the proxy answered for this run, and what the page reported, asked through the same
        // proxy from a window of ours. Polled: the chrome's page loads are on their own schedule.
        struct Entry { let via: String; let target: String; let path: String; let cookie: String; let userAgent: String; let language: String }
        func leakLog() async -> (targets: [Entry], reports: [[String: Any]], canary: [String]) {
            let url = URL(string: "http://proxied.selftest.invalid/pb-leak/log.json?run=\(run)")!
            let text = try? await loadThroughProxy(repository, proxy, url: url)
            guard let data = text?.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return ([], [], []) }
            let targets = (object["targets"] as? [[String: Any]] ?? []).map {
                Entry(via: $0["via"] as? String ?? "", target: ($0["target"] as? String ?? "").lowercased(),
                      path: $0["path"] as? String ?? "", cookie: $0["cookie"] as? String ?? "",
                      userAgent: $0["userAgent"] as? String ?? "", language: $0["language"] as? String ?? "")
            }
            let canary = (object["canary"] as? [[String: Any]] ?? []).map { "\($0["listener"] ?? "?") \($0["request"] ?? "")" }
            return (targets, object["reports"] as? [[String: Any]] ?? [], canary)
        }
        // The leak page's own report, not its frame's or its secure half's.
        func isPage(_ report: [String: Any]) -> Bool { report["frame"] == nil && report["secure"] == nil && report["sw"] == nil }
        var log = (targets: [Entry](), reports: [[String: Any]](), canary: [String]())
        for _ in 0..<25 {
            log = await leakLog()
            if log.reports.contains(where: isPage) && log.reports.contains(where: { $0["frame"] != nil }) { break }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
        // WebKit names an IPv6 address in its CONNECT line without brackets.
        func reached(_ target: String, _ path: String) -> Bool {
            let forms = [target.lowercased(), target.lowercased().replacingOccurrences(of: "[", with: "").replacingOccurrences(of: "]", with: "")]
            return log.targets.contains { forms.contains($0.target) && $0.path.hasPrefix(path) }
        }
        check("Safari chrome: a profile in its own process loads its pages through its own proxy",
              reached("start-\(run).\(domain):80", startPath),
              "the proxy answered: \(log.targets.map { "\($0.target)\($0.path.prefix(40))" }.joined(separator: " "))")
        // The profile's User-Agent, not one of Safari's choosing (`ProfileNetworkGuard.pinUserAgent`).
        let startAgent = log.targets.first { $0.path.hasPrefix(startPath) }?.userAgent ?? ""
        let wantedAgent = ProfileConfiguration(proxy: proxy).userAgent(hostSafariVersion: HostSafari.version)
        check("Safari chrome: the start page goes out with the profile's User-Agent",
              startAgent == wantedAgent, "sent \(startAgent), wanted \(wantedAgent)")
        check("Safari chrome: an iPhone or iPad profile gets our own window, not Safari's desktop chrome",
              !SafariChromeHost.canHost(ProfileConfiguration(deviceGenerationID: "ios-26"))
                && SafariChromeHost.canHost(ProfileConfiguration()))
        let page = log.reports.first(where: isPage) ?? [:]
        let frame = log.reports.first { $0["frame"] != nil } ?? [:]
        check("Safari chrome: the leak page ran and reported", !page.isEmpty, "no report from the page")
        info("Safari chrome: the leak page reported \(page)")
        // WebRTC opens its sockets outside the data store's proxy: in a proxied profile without
        // the tunnel it must not exist at all, in the page, in a frame of another site and in an
        // about:blank frame (where a script-only removal is classically got round).
        check("Safari chrome: WebRTC is off in Safari's web views (page, frame, about:blank frame)",
              page["rtc"] as? String == "undefined" && frame["rtc"] as? String == "undefined"
                && page["rtcBlankFrame"] as? String == "undefined",
              "page \(page["rtc"] ?? "nil"), frame \(frame["rtc"] ?? "nil"), blank frame \(page["rtcBlankFrame"] ?? "nil")")
        // WebTransport is QUIC, which an HTTP or SOCKS5 proxy cannot carry.
        check("Safari chrome: WebTransport is off in a proxied profile",
              page["webTransport"] as? String == "undefined" && frame["webTransport"] as? String == "undefined",
              "page \(page["webTransport"] ?? "nil"), frame \(frame["webTransport"] ?? "nil")")
        for (what, target, path) in [
            ("a fetch to an IPv4 address", "192.0.2.10:8080", "/pb-leak/fetch4"),
            ("a fetch to an IPv6 address", "[2001:db8::10]:8080", "/pb-leak/fetch6"),
            ("a fetch to a host name", "fetch-\(run).\(domain):80", "/pb-leak/fetchname"),
            ("a WebSocket", "192.0.2.11:8080", "/pb-leak/ws"),
            ("a worker's fetch", "192.0.2.15:8080", "/pb-leak/worker"),
            ("an image", "img-\(run).\(domain):80", "/pb-leak/img.png"),
            ("a frame of another site", "frame-\(run).\(domain):80", "/pb-leak/frame"),
            // The local network is not an exception to the proxy.
            ("a fetch to a .local name", "lan-\(run).local:80", "/pb-leak/lan"),
        ] {
            check("Safari chrome: \(what) goes through the profile's proxy", reached(target, path),
                  "not seen by the proxy: \(target)\(path)")
        }
        // This Mac itself: the system never sends loopback through a proxy (measured in run 382: the
        // page's fetches reached the canary listener directly), so a proxied profile's pages are
        // refused it — a fetch, a frame and a worker's fetch (`ProxiedContentRules`).
        let refusedHere = ["loopback4", "loopbackName", "loopback6", "loopbackAny", "loopbackWorker"]
        check("Safari chrome: a page cannot reach this Mac (127.0.0.1, localhost, ::1, 0.0.0.0, from the page and from a worker): each is refused",
              refusedHere.allSatisfy { page[$0] as? String == "rejected" },
              refusedHere.map { "\($0)=\(page[$0] ?? "nil")" }.joined(separator: " "))
        // Measured through the proxy in run 383; kept that way.
        check("Safari chrome: a fetch to a private-network address (10.255.255.1) goes through the profile's proxy",
              reached("10.255.255.1:8080", "/pb-leak/lan10"), "not seen by the proxy (\(page["lan10"] ?? "nil"))")
        // The proxied profile's rule list (dns-prefetch, <a ping>) reaches the web views Safari builds.
        check("Safari chrome: <a ping> is blocked in Safari's web views (and dns-prefetch with it)",
              !log.targets.contains { $0.path.hasPrefix("/pb-leak/ping") }, "the ping reached the proxy")
        for (what, path) in [("the font", "/pb-leak/font.woff"), ("the video", "/pb-leak/media.mp4"), ("the beacon", "/pb-leak/beacon")] {
            info("Safari chrome: \(what) \(log.targets.contains { $0.path.hasPrefix(path) } ? "reached" : "did not reach") the proxy")
        }

        // The profile's process, from inside: where its web views are, what WebRTC their engines
        // have, and a request made by each of the process's own ways of making one — to a host
        // that only the proxy answers.
        // https: App Transport Security refuses plain http to the app's own URLSession. The test
        // proxy cannot speak TLS, so each request fails after its CONNECT — and the CONNECT, at the
        // proxy, is the proof of where it went.
        let probePath = "/pb-leak/urlsession?run=\(run)"
        _ = manager.checkNetwork(profile.id, probe: URL(string: "https://probe-\(run).\(domain)\(probePath)"))
        _ = await waitUntil(timeout: 40) { networkReport != nil }
        if let report = networkReport {
            info("Safari chrome: the profile's process reports \(report)")
            check("Safari chrome: every web view of the process is on the profile's store, with its proxy",
                  report.webViews > 0 && report.webViewsOffProfile == 0, "\(report.webViewsOffProfile) of \(report.webViews) are not")
            check("Safari chrome: no web view of the process has WebRTC in its engine",
                  report.webViewsWithWebRTC == 0, "\(report.webViewsWithWebRTC) of \(report.webViews) have")
            check("Safari chrome: WebKit's own default store is closed", report.defaultStoreClosed)
            // The leak page submits a login form before it reports: Safari's own AutoFill must not
            // see it (its save would go to the owner's own passwords; SafariChrome.closeSafarisAutoFill).
            check("Safari chrome: a login form submitted in Safari's window went on without Safari's own AutoFill (passwords, cards, other forms), and nothing reached Safari's offers to save",
                  report.safariFormSubmissionsKept >= 1 && report.safariSaveOffersReached == 0,
                  "\(report.safariFormSubmissionsKept) submission(s) kept from it, \(report.safariSaveOffersReached) offer(s) to save reached")
            check("Safari chrome: the kernel refuses the process the XPC services of Safari's frameworks (SafariPlatformSupport's helper reaches the real Safari's data and keychain)",
                  report.safariXPCServicesClosed, String(describing: report.missing))
            check("Safari chrome: the process's own connections carry the profile's proxy", report.processProxy)
            check("Safari chrome: the process made its three probe requests", report.probes.count == 3, "\(report.probes)")
            check("Safari chrome: this Safari has every class and method the chrome relies on",
                  report.missing.isEmpty, report.missing.joined(separator: ", "))
            check("Safari chrome: Safari's own services are set as the profile needs them",
                  report.safariPreferences["UniversalSearchEnabled"] == "0"
                    && report.safariPreferences["AutoFillPasswords"] == "0",
                  "\(report.safariPreferences)")
            check("Safari chrome: Safari's home page, which History › Home opens, is the profile's start page",
                  report.safariPreferences[SafariChrome.homePageKey] == "http://start-\(run).\(domain)\(startPath)",
                  "\(report.safariPreferences[SafariChrome.homePageKey] ?? "unset")")
            let accountSafariAfter = accountSafariPreferences.map(Self.preferencesFileState)
            check("Safari chrome: the profile's settings for Safari's services stay in its process — the account's ~/Library/Preferences/com.apple.Safari.plist is not written",
                  accountSafariAfter == accountSafariBefore,
                  "before: \(accountSafariBefore ?? "?"), now: \(accountSafariAfter ?? "?")")
            info("Safari chrome: WebKit \(report.webKitVersion)")
            // The preference decides dns-prefetch only before WebKit 7621; from then on the
            // content rules do (checked above with <a ping>), so this is a check only there.
            info("Safari chrome: web views whose dns-prefetch preference is on: \(report.webViewsWithDNSPrefetch) of \(report.webViews)")
            check("Safari chrome: no web view of the process has a feature on that leaves the proxy (WebTransport, PCM, WebAuthn…)",
                  report.webViewsWithFeatureOn.values.allSatisfy { $0 == 0 }, "\(report.webViewsWithFeatureOn)")
            check("Safari chrome: nothing the profile has off can be turned on again by another setter",
                  report.pinBypasses.isEmpty, report.pinBypasses.joined(separator: ", "))
            check("Safari chrome: the profile's service workers have the profile's preferences",
                  report.workerPreferences != false, "this WebKit has no service-worker preferences of a store's own")
            check("Safari chrome: nothing of a page is handed outside the profile (no link preview, no address opened in another app, no sharing service, no password kept in the keychain, copies local)",
                  report.webViewsWithLinkPreview == 0 && !report.openedInAnotherApp && report.sharingServices == 0
                    && !report.credentialsKept && (report.handOffsRefused["clipboard"] ?? 0) > 0,
                  "link previews \(report.webViewsWithLinkPreview), opened \(report.openedInAnotherApp), sharing \(report.sharingServices), credentials kept \(report.credentialsKept), refused \(report.handOffsRefused)")
            check("Safari chrome: the real Safari's places are closed to the profile's process",
                  report.safariPlacesClosed, "no sandbox over ~/Library/Safari and the rest")
            info("Safari chrome: \(report.safariPathsRedirected.count) path getters of Safari's frameworks answer with the profile's home: \(report.safariPathsRedirected.prefix(80).joined(separator: " "))")
            check("Safari chrome: UDP is closed to the profile's process (QUIC cannot go around the proxy)",
                  report.udpClosed && !report.udp.values.contains { $0 == "sent" || $0.hasPrefix("ready") },
                  "closed=\(report.udpClosed) \(report.udp)")
            let inherited = Set(report.environmentNames).intersection(managerEnvironment.subtracting(ProfileProcess.environmentNames))
            check("Safari chrome: the profile's process has only its own environment, not the manager's",
                  inherited.isEmpty && !report.environmentNames.contains { $0.hasPrefix("PB_SELFTEST_") },
                  "inherited \(inherited.sorted()), names \(report.environmentNames)")
            let home = report.places["CFFIXED_USER_HOME"] ?? ""
            check("Safari chrome: HOME and TMPDIR of the profile's process are in the profile's home",
                  !home.isEmpty && report.places["HOME"] == home && (report.places["TMPDIR"] ?? "").hasPrefix(home + "/"),
                  "\(report.places)")
            info("Safari chrome: Foundation's temporary directory in the profile's process is \(report.places["temporaryDirectory"] ?? "?")")
            check("Safari chrome: certificates are checked without fetching, and the leak page's were refused",
                  report.trustEvaluated > 0 && report.trustRefused > 0 && report.trustFetchAllowed == 0,
                  "evaluated \(report.trustEvaluated), refused \(report.trustRefused), still allowed to fetch \(report.trustFetchAllowed)")
            check("Safari chrome: Safari's Edit menu has Paste as Typed (⌃⌘V)", report.pasteAsTypedInMenu)
        } else {
            check("Safari chrome: the profile's process reported where its traffic goes", false, "no report in 40 s")
        }

        // Each of those requests reached the proxy as itself — one proxy, not the profile's proxy
        // reached through the process's own (a request whose session names its proxy explicitly,
        // as the proxy lookup's does, must not be sent through the process-wide one as well).
        log = await leakLog()
        let probes = log.targets.filter { $0.target.hasPrefix("probe-") || $0.path.contains("probe-") }
        check("Safari chrome: each of the process's own requests (shared, ephemeral and explicit URLSession) went to the proxy itself, not through another proxy",
              probes.count >= 3 && probes.allSatisfy { $0.target == "probe-\(run).\(domain):443" },
              probes.map { "\($0.target) \($0.path.prefix(40))" }.joined(separator: " | "))

        // Cookies imported while the profile runs in its own process go into its store at once,
        // and its next request carries them (the second window's start page, below).
        let imported = ImportedCookie(name: "pbimported", value: run, domain: "start-\(run).\(domain)", hostOnly: true)
        let importOutcome = try? await manager.importCookies([imported], into: profile.id)
        check("Safari chrome: cookies imported into the running profile go into its own process's store",
              importOutcome == .applied(stored: 1, refused: []), String(describing: importOutcome))
        let exportedCookies = (try? await manager.exportCookies(of: profile.id)) ?? []
        check("Safari chrome: the profile's own process exports its cookies, the imported one with them",
              exportedCookies.contains { $0.name == "pbimported" && $0.value == run }, exportedCookies.map(\.name).joined(separator: " "))

        // Another window, as ⌘N opens one: Safari builds a new web view for it, and its start page
        // goes through the proxy as well.
        let before = log.targets.filter { $0.path.hasPrefix(startPath) }.count
        manager.openNewWindow(profile.id)
        var after = before
        for _ in 0..<10 {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            log = await leakLog()
            after = log.targets.filter { $0.path.hasPrefix(startPath) }.count
            if after > before { break }
        }
        check("Safari chrome: a second window of the profile loads through its proxy", after > before,
              "start page requests: \(before) before, \(after) after")
        check("Safari chrome: the second window's request carries the cookie imported meanwhile",
              log.targets.contains { $0.path.hasPrefix(startPath) && $0.cookie.contains("pbimported=\(run)") },
              log.targets.filter { $0.path.hasPrefix(startPath) }.map(\.cookie).joined(separator: " | "))

        // The secure-context half of the leak page, on loopback (a secure context): WebTransport
        // and WebRTC exist only in secure contexts, so only there does their absence — in the
        // page, a dedicated, a shared and a service worker — mean something.
        let securePath = "/pb-leak/secure?run=\(run)"
        manager.openWindow(profile.id, url: URL(string: "http://127.0.0.1:\(httpPort)\(securePath)")!)
        var secure: [String: Any] = [:]
        var worker: [String: Any] = [:]
        for _ in 0..<15 {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            log = await leakLog()
            secure = log.reports.first { $0["secure"] != nil } ?? [:]
            // The service worker's own report (`"sw": true`), not the page's (`"sw": "registered"`).
            worker = log.reports.first { $0["sw"] as? Bool == true && $0["secure"] == nil } ?? [:]
            if !secure.isEmpty && !worker.isEmpty { break }
        }
        // A page opened on this Mac is loaded from this Mac (the system never proxies loopback); it
        // is the user's own machine, and its own loads stay there (`ProxiedContentRules`).
        info("Safari chrome: the page on this Mac was loaded \(log.targets.filter { $0.path.hasPrefix(securePath) }.map { "\($0.via) \($0.target)" }.joined(separator: " | "))")
        info("Safari chrome: the secure page reported \(secure), its service worker \(worker)")
        if secure["secure"] as? Bool == true {
            // Each worker answered, and without it: a worker that never answered proves nothing.
            check("Safari chrome: WebTransport and WebRTC are absent in a secure context (page, worker, shared worker)",
                  secure["webTransport"] as? String == "undefined" && secure["rtc"] as? String == "undefined"
                    && secure["worker"] as? String == "undefined" && secure["shared"] as? String == "undefined",
                  "\(secure)")
            check("Safari chrome: WebTransport is absent in a service worker (which reported)",
                  worker["webTransport"] as? String == "undefined", worker.isEmpty ? "no report from the service worker" : "\(worker)")
            // The profile's time zone is the engine's own in the profile's process, workers
            // included: a worker no script of ours reaches says what WebKit's process was given.
            check("Safari chrome: the profile's time zone in the page, a dedicated worker and a service worker",
                  secure["tz"] as? String == zone && secure["workerTZ"] as? String == zone
                    && worker["tz"] as? String == zone,
                  "page \(secure["tz"] ?? "nil"), worker \(secure["workerTZ"] ?? "nil"), service worker \(worker["tz"] ?? "nil")")
        } else {
            check("Safari chrome: the secure half of the leak page ran in a secure context", false, "\(secure)")
        }

        // Long enough for what Safari's chrome does on a timer (the page-text donation runs about
        // five seconds after a load) to happen while the capture is still looking.
        try? await Task.sleep(nanoseconds: 8_000_000_000)
        // What Safari's frameworks keep in the profile's home (its history, bookmarks, snapshots…):
        // listed, for the record of where a hosted chrome puts its own state.
        let home = repository.directory(for: profile.id).appendingPathComponent("home.noindex")
        // Plaintext while the profile runs: out of Spotlight (the name) and out of Time Machine.
        check("Safari chrome: the profile's home is kept out of backups and Spotlight while it runs",
              (try? home.resourceValues(forKeys: [.isExcludedFromBackupKey]))?.isExcludedFromBackup == true,
              home.path)
        if let files = FileManager.default.enumerator(at: home, includingPropertiesForKeys: [.fileSizeKey]) {
            var listed: [String] = []
            for case let file as URL in files where listed.count < 80 {
                let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                if size > 0 { listed.append("\(file.path.replacingOccurrences(of: home.path, with: "~")) \(size)") }
            }
            info("Safari chrome: the profile's home holds \(listed.joined(separator: ", "))")
        }
        // The page's https request is answered by WebKit's own timing, which can be after the page
        // reported: looked for last.
        log = await leakLog()
        check("Safari chrome: an HTTPS request goes through the proxy too (as a CONNECT)",
              log.targets.contains { $0.target == "192.0.2.14:443" })
        check("Safari chrome: an HTTPS image whose certificate needs a fetch reached the proxy, and its certificate was refused",
              log.targets.contains { $0.target == "aia-\(run).\(domain):443" && $0.path.hasPrefix("(tls refused") },
              log.targets.filter { $0.target.hasPrefix("aia-") }.map(\.path).joined(separator: " | "))
        check("Safari chrome: nothing reached this Mac directly (the canary listener took no connection: no fetch, frame or worker)",
              log.canary.isEmpty, log.canary.joined(separator: " | "))
        // Whether Safari fetches these is Safari's business; where it does, it is through the proxy
        // (https: the CONNECT is the proof), and anything it fetched another way is in the capture.
        for (what, host) in [("the page's icon", "icon-"), ("its touch icon", "touchicon-"), ("its OpenSearch description", "osd-")] {
            info("Safari chrome: \(what) \(log.targets.contains { $0.target.hasPrefix(host + run) } ? "was fetched through the proxy" : "was not fetched (not exercised)")")
        }
        // A stop: Safari's window goes first, then the seal, whose retries no longer wait for Safari
        // (it keeps the pages of the windows it closes); the process reports how the seal went.
        sealReport = nil
        let stopStarted = Date()
        try? await manager.stop(profile.id)
        let stopSeconds = Date().timeIntervalSince(stopStarted)
        _ = await waitUntil(timeout: 5) { sealReport != nil }
        check("Safari chrome: a stop ends the profile's process within 15 s, its data sealed and the seal reported (it took 20 s and more of retries)",
              stopSeconds < 15 && sealReport != nil, "\(Int(stopSeconds)) s, \(String(describing: sealReport))")
        info("Safari chrome: the stop sealed the profile's data "
             + (sealReport.map { $0.forced ? "by force (WebKit kept the store in use)" : "without force (WebKit let the store go)" } ?? "(no report)")
             + ", attempts \(sealReport?.attempts ?? 0), pages closed first \(sealReport?.pagesClosed ?? 0), seal \(Int(sealReport?.seconds ?? 0)) s, stop \(Int(stopSeconds)) s")
        // What Safari's window visited is in the profile's own, encrypted history (`HostedPageHistory`).
        let visited = (try? repository.historyStore(for: profile.id, key: repository.profileKey(for: profile.id)).entries().map(\.url)) ?? []
        check("Safari chrome: the pages Safari's window visited are in the profile's own encrypted history",
              visited.contains { $0.contains("start-\(run).\(domain)/pb-leak") }, visited.prefix(10).joined(separator: " "))

        // Again, as an owner's profile usually runs: its second launch, on the home restored from
        // its archive, through SOCKS5, following its proxy's location (the lookup goes through
        // the proxy from the profile's process). Still inside the capture's window.
        if let socksPort = ProcessInfo.processInfo.environment["PB_SELFTEST_SOCKS_PROXY_PORT"].flatMap(Int.init) {
            var again = try repository.loadConfiguration(profile.id)
            again.proxy = ProxySettings(kind: .socks5, host: "127.0.0.1", port: socksPort)
            again.matchProxyLocation = true
            again.timeZoneIdentifier = nil
            try repository.saveConfiguration(again, for: profile.id)
            // The manager looks the new proxy up before the process starts (nothing is remembered
            // for it): the self-test proxy's answer is Germany, so the process starts in German.
            let services = ProxyGeoLookup.services
            ProxyGeoLookup.services = [.init(url: URL(string: "http://geo.selftest.invalid/pb-geo.json")!,
                                             timeZoneKeyPath: ["timezone"], countryKeyPath: ["country"])]
            defer { ProxyGeoLookup.services = services }
            hostsChrome = nil
            networkReport = nil
            let before = (await leakLog()).targets.filter { $0.path.hasPrefix(startPath) }.count
            setenv("PB_PROFILE_PROCESS", "1", 1)
            do { try await manager.launch(profile.id) } catch {
                check("Safari chrome, second launch: the profile's process started", false, String(describing: error))
            }
            setenv("PB_PROFILE_PROCESS", "0", 1)
            if let pid = manager.processIdentifier(of: profile.id) { info("egress-pid \(pid)"); profilePIDs.insert(pid) }
            let restarted = await waitUntil(timeout: 90) { hostsChrome != nil }
            var arrived: [Entry] = []
            for _ in 0..<15 {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                arrived = (await leakLog()).targets.filter { $0.path.hasPrefix(startPath) }
                if arrived.count > before { break }
            }
            check("Safari chrome, second launch on the restored home through SOCKS5: Safari's window again, its start page through the proxy, by name",
                  restarted && hostsChrome == true && arrived.dropFirst(before).contains { $0.via == "via=socks5" },
                  "chrome \(String(describing: hostsChrome)), start page requests \(arrived.map(\.via))")
            check("Safari chrome, a new proxy's first launch: the page is asked for in the proxy's country's language",
                  arrived.dropFirst(before).contains { $0.language.hasPrefix("de") },
                  arrived.dropFirst(before).map(\.language).joined(separator: " | "))
            _ = manager.checkNetwork(profile.id, probe: URL(string: "https://probe-\(run).\(domain)/pb-leak/second?run=\(run)"))
            _ = await waitUntil(timeout: 40) { networkReport != nil }
            check("Safari chrome, second launch: every web view on the profile's store, none with WebRTC, the kernel's closures in place",
                  networkReport.map { $0.webViews > 0 && $0.webViewsOffProfile == 0 && $0.webViewsWithWebRTC == 0 && $0.udpClosed && $0.safariPlacesClosed } == true,
                  String(describing: networkReport))
            info("exceptions: in the profile's process with Safari's chrome, an exception passed through the preprocessor keeps its call stack: "
                 + "\(networkReport.map { String($0.exceptionCallStacks) } ?? "no report")")
            try? await manager.stop(profile.id)
        }
        await manager.shutDown()
        if let xpcWatch { reportXPCServices(xpcWatch.stop(), profilePIDs: profilePIDs) }
        info("egress-window end \(Date().timeIntervalSince1970)")
        check("Safari chrome: nothing went wrong while it ran", messages.isEmpty, messages.joined(separator: " | "))
    }

    /// What `XPCServiceWatch` saw while the profile ran in Safari's chrome: every XPC service that
    /// started, and whether this app (the self-test, or the profile's process it started) is the
    /// one the system holds responsible for it; and each one's files open in the real Safari's
    /// places. A measurement: which services a profile's process must be closed to is decided from
    /// it (the owner's Mac showed one, Safari's SafariPlatformSupport helper, in the real container).
    private func reportXPCServices(_ seen: [(service: XPCServiceWatch.Service, opened: [String])], profilePIDs: Set<pid_t>) {
        let ours = profilePIDs.union([getpid()])
        let ownResponsible = XPCServiceWatch.responsible(for: getpid())
        func whose(_ service: XPCServiceWatch.Service) -> String {
            guard let responsible = service.responsible else { return "responsible process not known" }
            return ours.contains(responsible) || responsible == ownResponsible ? "for this app" : "for pid \(responsible)"
        }
        info("XPC services started while the profile ran in Safari's chrome: "
             + (seen.isEmpty ? "none" : seen.map { "\($0.service.bundleName) (pid \($0.service.pid), \(whose($0.service)))" }.joined(separator: ", ")))
        for entry in seen where !entry.opened.isEmpty {
            info("XPC service \(entry.service.bundleName) (pid \(entry.service.pid), \(whose(entry.service))) held open in the real Safari's places: "
                 + entry.opened.prefix(20).joined(separator: ", "))
        }
        // The profile's process is closed to them (ProfileNetworkGuard.closeTheProcess). Ours: the
        // system holds this app — or what this app runs under, as CI's runner — responsible.
        let safaris = seen.filter { entry in
            entry.service.bundleName.hasPrefix("com.apple.Safari")
                && entry.service.responsible.map { ours.contains($0) || $0 == ownResponsible } ?? true
        }
        check("Safari chrome: no XPC service of Safari's frameworks started for the profile",
              safaris.isEmpty, safaris.map { "\($0.service.bundleName) (pid \($0.service.pid))" }.joined(separator: ", "))
    }

    // MARK: Exceptions

    /// An exception thrown in AppKit's run loop is written down, readably, and lived through
    /// (`ExceptionLog`), in a process of its own (`--exception-check`): with this build's hooks, and
    /// — the control — with the earlier hook, which replaced CoreFoundation's preprocessor instead
    /// of calling it and is what took a profile's process down on ⌘, in Safari's chrome.
    private func exceptionChecks() async throws {
        info("exceptions: in this process an exception passed through the preprocessor keeps its call stack: "
             + "\(ExceptionLog.preprocessorKeepsCallStacks())")
        guard let executable = Bundle.main.executableURL else {
            check("exceptions: this build's executable is there to run the check", false)
            return
        }
        let chained = await runOwnExecutable(executable, ["--exception-check"], timeout: 30)
        let logged = chained.output.split(separator: "\n").filter { $0.hasPrefix("EXCEPTION-CHECK logged:") }.joined(separator: " | ")
        check("exceptions: one thrown in AppKit's run loop is caught, reported and lived through (CoreFoundation's preprocessor kept in the chain)",
              !chained.signaled && chained.status == 0 && chained.output.contains("EXCEPTION-CHECK lived through it; reportException: saw 1"),
              chained.output.trimmingCharacters(in: .whitespacesAndNewlines))
        check("exceptions: the log has its name and its reason in clear, with the address and the quoted name cut out",
              logged.contains("PBExceptionCheck") && logged.contains("a check of this build at <url> for \"…\"")
                  && !logged.contains("bank.example") && !logged.contains("Alice"),
              logged)
        // The same in a process like a profile's: NSApp is Safari's own application object, Safari's
        // frameworks loaded and prepared. Only a build without the App Sandbox can host them.
        let inSafari = await runOwnExecutable(executable, ["--exception-check", "--safari"], timeout: 60)
        if inSafari.status == 2, inSafari.output.contains("cannot be hosted") {
            info("exceptions with Safari's application object: not in this build (\(AppEnvironment.isSandboxed ? "sandboxed" : "frameworks did not load"))")
        } else {
            check("exceptions: with Safari's own application object as NSApp, one thrown by a menu item's action reaches reportException: and is lived through",
                  !inSafari.signaled && inSafari.status == 0 && inSafari.output.contains("EXCEPTION-CHECK lived through it; reportException: saw 1"),
                  inSafari.output.trimmingCharacters(in: .whitespacesAndNewlines))
            check("exceptions: the profile's window would tell the user that the menu item's Safari feature is not available, naming the item",
                  inSafari.output.contains("EXCEPTION-CHECK the user is told:") && inSafari.output.contains("PB check item"),
                  inSafari.output.split(separator: "\n").filter { $0.contains("told") }.joined(separator: " | "))
        }
        let control = await runOwnExecutable(executable, ["--exception-check", "--replacing"], timeout: 30)
        let first = control.output.split(separator: "\n").first.map(String.init) ?? ""
        info("exceptions, the control (the earlier hook, CoreFoundation's preprocessor replaced): "
             + (control.signaled ? "died by signal \(control.status)" : "lived, exit \(control.status)") + " — \(first)")
    }

    /// Safari's Bookmarks sidebar makes its nibs itself, with this app as their bundle, and they are
    /// Safari's: in a process like a profile's, made the same way, each must come from Safari's file
    /// (`SafariChrome.bridgeNibInitializers`), with nothing thrown. A nib this Safari does not have
    /// is said, not failed on.
    private func safariNibChecks() async throws {
        guard let executable = Bundle.main.executableURL else {
            check("Safari's nibs: this build's executable is there to run the check", false)
            return
        }
        let run = await runOwnExecutable(executable, ["--nib-check"], timeout: 60)
        if run.status == 2, run.output.contains("cannot be hosted") {
            info("Safari's nibs: not in this build (\(AppEnvironment.isSandboxed ? "sandboxed" : "frameworks did not load"))")
            return
        }
        let lines = run.output.split(separator: "\n").map(String.init).filter { $0.hasPrefix("NIB-CHECK") }
        let detail = lines.joined(separator: " | ")
        let held = SafariChrome.checkedNibs.filter { !lines.contains("NIB-CHECK \($0): not in this Safari") }
        guard !held.isEmpty else {
            info("Safari's nibs: none of \(SafariChrome.checkedNibs.joined(separator: ", ")) is in this Safari — \(detail)")
            return
        }
        let made = held.filter { lines.contains("NIB-CHECK \($0): made") }
        let bridged = run.output.range(of: #"made from Safari's files: (\d+)"#, options: .regularExpression)
            .flatMap { Int(run.output[$0].split(separator: " ").last ?? "") } ?? 0
        check("Safari's chrome: the Bookmarks sidebar's nibs, asked of this app as Safari's code asks, are made from Safari's files, and nothing throws",
              !run.signaled && run.status == 0 && made.count == held.count && bridged >= held.count
                  && run.output.contains("; exceptions: 0"),
              detail.isEmpty ? run.output.trimmingCharacters(in: .whitespacesAndNewlines) : detail)
    }

    /// This build's executable with `arguments`, in a process of its own: what it printed, and how it
    /// ended (an exit status, or the signal that ended it).
    private func runOwnExecutable(_ executable: URL, _ arguments: [String], timeout: TimeInterval) async
        -> (output: String, status: Int32, signaled: Bool) {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return ("could not start: \(error)", -1, false)
        }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
            return ("did not end within \(Int(timeout)) s", -1, false)
        }
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return (output, process.terminationStatus, process.terminationReason == .uncaughtSignal)
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

    // MARK: Restore tabs (Settings → Startup)

    /// A profile stopped with tabs open keeps them, encrypted, and its next start opens them again
    /// with the same tab shown; set off, what was kept is forgotten at the next stop; an ephemeral
    /// profile never keeps any.
    private func restoreTabs(_ repository: ProfileRepository) async throws {
        guard let httpPort = ProcessInfo.processInfo.environment["PB_SELFTEST_HTTP_PROXY_PORT"].flatMap(Int.init) else {
            info("restore tabs checks skipped (need the self-test proxy to serve pages)")
            return
        }
        defer { BrowsingPreferences.current = BrowsingPreferences() }
        let proxy = ProxySettings(kind: .httpConnect, host: "127.0.0.1", port: httpPort)
        let profile = try repository.create(name: "Restore tabs", configuration: ProfileConfiguration(
            proxy: proxy, matchProxyLocation: false))
        let ephemeral = try repository.create(name: "Restore tabs, ephemeral", configuration: ProfileConfiguration(
            proxy: proxy, ephemeral: true, matchProxyLocation: false))
        let manager = ProfileManager(repository: repository)
        let one = URL(string: "http://proxied.selftest.invalid/one")!
        let two = URL(string: "http://proxied.selftest.invalid/two")!
        BrowsingPreferences.current.restoreTabs = true

        /// Starts `id`, opens `one` and `two` in its window with the first one shown, and stops it.
        func browseAndStop(_ id: UUID) async throws -> Bool {
            try await manager.launch(id)
            guard let controller = manager.session(for: id)?.windowControllers.first else { return false }
            controller.selectedTab?.load(one)
            controller.addTab(url: two)
            let loaded = await waitUntil(timeout: 20) {
                controller.tabs.compactMap(\.url) == [one, two] && controller.tabs.allSatisfy { !$0.isLoading }
            }
            controller.selectTab(at: 0)
            try await manager.stop(id)
            return loaded
        }

        let browsed = try await browseAndStop(profile.id)
        let kept = try repository.openTabs(for: profile.id)
        let keptRight: Bool = kept?.windows == [OpenTabs.Window(tabs: [one, two], selected: 0)]
        check("restore tabs: a stopped profile keeps the pages its window had open, and the tab shown",
              browsed && keptRight, String(describing: kept?.windows))

        try await manager.launch(profile.id)
        let reopened = manager.session(for: profile.id)?.windowControllers.first
        let opened = await waitUntil(timeout: 20) { reopened?.tabs.compactMap(\.url) == [one, two] }
        let shown: URL? = reopened?.selectedTab?.url
        check("restore tabs: the next start opens them again, the same tab shown",
              opened && shown == one, "\(reopened?.tabs.compactMap(\.url) ?? []) shown \(shown?.absoluteString ?? "none")")

        BrowsingPreferences.current.restoreTabs = false
        try await manager.stop(profile.id)
        let forgotten = try repository.openTabs(for: profile.id) == nil
        check("restore tabs: set off, what was kept is forgotten when the profile stops", forgotten)

        BrowsingPreferences.current.restoreTabs = true
        let ephemeralBrowsed = try await browseAndStop(ephemeral.id)
        let ephemeralKept = try repository.openTabs(for: ephemeral.id)
        check("restore tabs: an ephemeral profile never keeps its tabs", ephemeralBrowsed && ephemeralKept == nil,
              String(describing: ephemeralKept?.windows))

        await manager.shutDown()
        try repository.delete(profile.id)
        try repository.delete(ephemeral.id)
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

        // Which of WebKit's behaviors that follow an app's SDK this run has (SDKBehaviors).
        info("WebKit's behaviors that follow the SDK: \(SDKBehaviors.matched ? "every one, as Safari's (--sdk-everything)" : "this build's, the macOS \(SDKBehaviors.linkedSDK ?? "?") SDK's")")

        // A persistent profile's store is made with a browser's share of the disk
        // (BrowserStorageQuota): Safari's quota is then WebKit's own answer. Read in a world the
        // profile's scripts are not in, which would otherwise map an app's figure to Safari's.
        let persistent = try repository.create(name: "Quota", configuration: ProfileConfiguration(webRTCPolicy: .unrestricted))
        let quotaSession = try makeSession(repository, persistent.id, key: repository.profileKey(for: persistent.id))
        let madeWithRatios = BrowserStorageQuota.lastStoreHadBrowserRatios
        let quotaTab = BrowserTab(configuration: quotaSession.makeWebViewConfiguration(), context: quotaSession.tabContext)
        try await PageLoader.load(quotaTab.webView, html: page, baseURL: origin)
        let nativeQuota = try await js(quotaTab.webView, "return (await navigator.storage.estimate()).quota;", world: .defaultClient) as? NSNumber
        let macQuota = PrivacyScripts.safariStorageQuota(for: .macOS).rounded(.up)
        check("storage quota: a persistent profile's store gives a site Safari's share itself (WebKit's own answer, no script)",
              madeWithRatios && nativeQuota?.doubleValue == macQuota,
              "made with a browser's ratios: \(madeWithRatios), quota \(nativeQuota?.stringValue ?? "nil") vs \(String(format: "%.0f", macQuota))")
        quotaTab.tearDown()
        quotaSession.shutDown()
        await WebDataStoreVault(repository: repository).deleteData(profileID: persistent.id)
        try repository.delete(persistent.id)
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
        check("proxy location: a lookup no service answered is said and marked for the profile's row and editor, not only logged",
              manager.proxyLocationUnknown.contains(profile.id))

        // A first service the proxy holds open (it answers only after 20 s) leaves time for the next
        // one: it is waited for alone at most `nextServiceAfter`, then the next is asked as well. It
        // used to have the whole lookup's time, and the services after it were never asked. (A slow
        // service that is the only one is still waited for: the launch checks above, 4 and 8 s.)
        ProxyGeoLookup.services = [
            .init(url: URL(string: "http://geo.selftest.invalid/pb-geo.json?delay=20&tz=Asia/Tokyo")!,
                  timeZoneKeyPath: ["timezone"], countryKeyPath: ["country"]),
            .init(url: URL(string: "http://geo.selftest.invalid/pb-geo.json")!, timeZoneKeyPath: ["timezone"], countryKeyPath: ["country"]),
        ]
        let held = Date()
        let behindHeld = await ProxyGeoLookup.lookUp(proxy: ProxySettings(kind: .httpConnect, host: "127.0.0.1", port: httpPort),
                                                     userAgent: "PrivacyBrowser self-test")
        let heldFor = Date().timeIntervalSince(held)
        check("proxy location: a service the proxy holds open does not use up the lookup, the next one answers",
              behindHeld.location?.timeZoneIdentifier == "Europe/Berlin" && heldFor < ProxyGeoLookup.nextServiceAfter + 4,
              "\(behindHeld.location?.timeZoneIdentifier ?? "nil") after \(Int(heldFor)) s")

        var explicit = stored
        explicit.timeZoneIdentifier = "Asia/Tokyo"
        try repository.saveConfiguration(explicit, for: profile.id)
        lookUp(at: "/pb-geo.json")
        let tokyo = try await launchedTimeZone()
        check("proxy location: an explicit time zone wins", tokyo == "Asia/Tokyo", tokyo ?? "nil")
        check("proxy location: the mark of a failed lookup goes with the next launch",
              !manager.proxyLocationUnknown.contains(profile.id))
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

    // MARK: The proxy list's checker

    /// The proxy list's checker (`ProxyChecker`) against the self-test proxy, whose stand-in
    /// geolocation service (`/pb-geo.json`) only answers through it:
    ///   * the probe tells every listener of the self-test proxy apart, step by step: HTTP CONNECT
    ///     and SOCKS5 each found whatever type the settings say, the login not needed, missing,
    ///     wrong or taken (HTTP and SOCKS5), on IPv6 too, a port that takes the connection and never
    ///     answers (silent), a closed port (refused), a host name that does not exist;
    ///   * a working proxy is alive, with the exit IP, country, time zone, city and network the
    ///     service saw through it, and the probe's median latency;
    ///   * an unreachable proxy, and one whose host does not resolve, are dead — and a real website
    ///     among the services, which a request made directly would reach, did not answer either, nor
    ///     was any connection made but to the proxy: a dead proxy is never gone around;
    ///   * a proxy that wants credentials it was not given is dead for that reason, and settings
    ///     that cannot be applied are not checked at all (no request is made);
    ///   * the list's model checks several at a time and keeps each result with its proxy,
    ///     encrypted, finds the type of a line without a scheme and corrects a wrong one; a profile
    ///     given a checked proxy knows at once where it exits;
    ///   * a profile started with a silent proxy says so (`ProfileManager.onProxyProblem`), one with
    ///     a working proxy says nothing, and Check from what it said is the same check.
    /// All of it but the host name that does not resolve (this Mac's resolver is asked for the
    /// proxy's own name: there is nothing else to reach a proxy by) runs inside an egress window:
    /// scripts/egress_check.py fails on any packet of this process past loopback during it, and on
    /// any DNS question for the geolocation service's name, which carries the run's id. The host
    /// name that does not resolve is the capture's control for such questions (`egress-control`).
    private func proxyChecker(_ repository: ProfileRepository) async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let httpPort = environment["PB_SELFTEST_HTTP_PROXY_PORT"].flatMap(Int.init) else {
            info("proxy checker checks skipped (PB_SELFTEST_HTTP_PROXY_PORT not set)")
            return
        }
        func port(_ name: String) -> Int? { environment[name].flatMap(Int.init) }
        let loopback = "127.0.0.1"
        let services = ProxyGeoLookup.services
        let timeout = ProxyChecker.timeout
        let concurrentChecks = ProxyChecker.concurrentChecks
        defer {
            ProxyGeoLookup.services = services
            ProxyChecker.timeout = timeout
            ProxyChecker.concurrentChecks = concurrentChecks
        }
        // The service's name carries the run's id: asked of this Mac's resolver instead of named to
        // the proxy, it is in the capture (scripts/egress_check.py). Under selftest.invalid, the one
        // name the app's App Transport Security lets a URLSession ask over plain HTTP.
        let run = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12)).lowercased()
        ProxyGeoLookup.services = [
            .init(url: URL(string: "http://geo-\(run).selftest.invalid/pb-geo.json?ip=203.0.113.21")!,
                  timeZoneKeyPath: ["timezone"], countryKeyPath: ["country"],
                  cityKeyPath: ["city"], asnKeyPath: ["org"], organizationKeyPath: ["org"]),
            // A real website, as the fail-closed checks above use one: a request made directly would
            // reach it and be answered, so any answer through a dead proxy would have gone around it.
            .init(url: URL(string: "https://example.com/")!, timeZoneKeyPath: ["timezone"], countryKeyPath: ["country"]),
        ]
        ProxyChecker.timeout = 8

        // Before the window: the proxy's own name is asked of this Mac's resolver. It is a control
        // for the capture: seen there, a question this Mac asks for a .invalid name reaches the
        // network, and one for the service's name inside the window would have been caught too.
        let control = "pbinvalid\(run.prefix(6))"
        info("egress-control \(control)")
        let unknownHost = "proxy-\(control).selftest.invalid"
        let unresolvedProbe = await ProxyChecker.probe(latencySamples: 1).run(ProxySettings(kind: .socks5, host: unknownHost, port: 1080))
        // Behind a VPN whose DNS gives every name a substitute address (fake IP), no resolver says
        // "no such host": the probe must then say that, not that a proxy refused or closed.
        let substituted = unresolvedProbe.verdict == .substituteDNS
            && unresolvedProbe.connectedAddress.map(SubstituteDNS.isSubstitute) == true
        if substituted {
            info("this Mac's resolver gives a name that does not exist a VPN's substitute address "
                 + "(\(unresolvedProbe.connectedAddress ?? "")): the probe says so, as host not found cannot be told here")
        }
        check("proxy probe: a proxy whose host name does not exist is told apart (host not found, or a VPN's substitute DNS said as that)",
              unresolvedProbe.verdict == .hostNotFound || substituted, String(describing: unresolvedProbe))
        let unresolved = ProxyChecker.result(of: await ProxyChecker.lookUp(ProxySettings(kind: .socks5, host: unknownHost, port: 1080)))
        check("proxy checker: a proxy whose host does not resolve is dead (nothing goes direct)",
              unresolved.failure == .noAnswer, String(describing: unresolved))

        info("egress-token \(run)")
        info("egress-window begin \(Date().timeIntervalSince1970)")
        defer { info("egress-window end \(Date().timeIntervalSince1970)") }

        // Every listener, told apart. Each working one is listed as the other type: the type is
        // found, not taken from the settings.
        struct ProbeCase {
            let name: String
            let proxy: ProxySettings
            let verdict: ProxyDiagnosis.Verdict
            var kind: ProxySettings.Kind?
            var authentication: ProxyDiagnosis.Authentication?
        }
        var cases = [
            ProbeCase(name: "HTTP CONNECT, listed as SOCKS5", proxy: ProxySettings(kind: .socks5, host: loopback, port: httpPort),
                      verdict: .works, kind: .httpConnect, authentication: .notRequired),
            ProbeCase(name: "a closed port", proxy: ProxySettings(kind: .socks5, host: loopback, port: 9), verdict: .refused),
        ]
        if let socksPort = port("PB_SELFTEST_SOCKS_PROXY_PORT") {
            cases.append(ProbeCase(name: "SOCKS5, listed as HTTP", proxy: ProxySettings(kind: .httpConnect, host: loopback, port: socksPort),
                                   verdict: .works, kind: .socks5, authentication: .notRequired))
        }
        if let authPort = port("PB_SELFTEST_HTTP_AUTH_PROXY_PORT") {
            cases += [
                ProbeCase(name: "HTTP with a login, none given", proxy: ProxySettings(kind: .httpConnect, host: loopback, port: authPort),
                          verdict: .credentialsNeeded, kind: .httpConnect, authentication: .missing),
                ProbeCase(name: "HTTP with a login, a wrong one",
                          proxy: ProxySettings(kind: .httpConnect, host: loopback, port: authPort, username: "pb-user", password: "wrong"),
                          verdict: .credentialsRejected, kind: .httpConnect, authentication: .rejected),
                ProbeCase(name: "HTTP with a login, the right one",
                          proxy: ProxySettings(kind: .httpConnect, host: loopback, port: authPort, username: "pb-user", password: "pb-pass"),
                          verdict: .works, kind: .httpConnect, authentication: .accepted),
            ]
        }
        if let socksAuthPort = port("PB_SELFTEST_SOCKS_AUTH_PROXY_PORT") {
            cases += [
                ProbeCase(name: "SOCKS5 with a login, none given", proxy: ProxySettings(kind: .socks5, host: loopback, port: socksAuthPort),
                          verdict: .credentialsNeeded, kind: .socks5, authentication: .missing),
                ProbeCase(name: "SOCKS5 with a login, a wrong one",
                          proxy: ProxySettings(kind: .socks5, host: loopback, port: socksAuthPort, username: "pb-user2", password: "wrong"),
                          verdict: .credentialsRejected, kind: .socks5, authentication: .rejected),
                ProbeCase(name: "SOCKS5 with a login, the right one",
                          proxy: ProxySettings(kind: .socks5, host: loopback, port: socksAuthPort, username: "pb-user2", password: "pb-pass2"),
                          verdict: .works, kind: .socks5, authentication: .accepted),
            ]
        }
        if let http6Port = port("PB_SELFTEST_HTTP6_PROXY_PORT") {
            cases.append(ProbeCase(name: "HTTP CONNECT on the IPv6 loopback", proxy: ProxySettings(kind: .httpConnect, host: "::1", port: http6Port),
                                   verdict: .works, kind: .httpConnect, authentication: .notRequired))
        }
        let silentPort = port("PB_SELFTEST_SILENT_PROXY_PORT")
        if let silentPort {
            cases.append(ProbeCase(name: "a port that takes the connection and never answers",
                                   proxy: ProxySettings(kind: .socks5, host: loopback, port: silentPort), verdict: .silent))
        } else {
            info("proxy probe: the silent listener's checks skipped (PB_SELFTEST_SILENT_PROXY_PORT not set)")
        }
        let probe = ProxyChecker.probe()
        // All at once: the silent one alone takes the probe's whole answer timeout.
        let diagnoses = await withTaskGroup(of: (Int, ProxyDiagnosis).self) { group -> [Int: ProxyDiagnosis] in
            for (index, item) in cases.enumerated() {
                let proxy = item.proxy
                group.addTask { (index, await probe.run(proxy)) }
            }
            var found: [Int: ProxyDiagnosis] = [:]
            for await (index, diagnosis) in group { found[index] = diagnosis }
            return found
        }
        for (index, item) in cases.enumerated() {
            let diagnosis = diagnoses[index]
            var expected = item.verdict.rawValue
            if let kind = item.kind { expected += ", \(kind.rawValue)" }
            if let authentication = item.authentication { expected += ", login \(authentication.rawValue)" }
            check("proxy probe: \(item.name) — \(expected)",
                  diagnosis?.verdict == item.verdict && (item.kind == nil || diagnosis?.kinds.first == item.kind)
                      && (item.authentication == nil || diagnosis?.authentication == item.authentication)
                      && (item.verdict != .works || diagnosis?.latencies.count == probe.latencySamples),
                  String(describing: diagnosis))
        }

        // End to end through a working proxy listed with the wrong type: where it exits.
        let full = await ProxyChecker.check(ProxySettings(kind: .socks5, host: loopback, port: httpPort))
        check("proxy checker: a working proxy listed with the wrong type is checked as the type that answered, end to end — exit IP, country, city, network, and the probe's median latency",
              full.isAlive && full.exitIP == "203.0.113.21" && full.countryCode == "DE" && full.timeZoneIdentifier == "Europe/Berlin"
                  && full.city == "Berlin" && full.asn == "AS64500" && full.organization == "Example Networks"
                  && full.diagnosis?.kinds.first == .httpConnect && full.latencyMilliseconds != nil
                  && full.latencyMilliseconds == full.diagnosis?.medianLatency,
              String(describing: full))
        // And through each other listener that works: the exit the service saw came back through it.
        var throughEach: [(String, ProxySettings)] = []
        if let socksPort = port("PB_SELFTEST_SOCKS_PROXY_PORT") {
            throughEach.append(("SOCKS5 listed as HTTP", ProxySettings(kind: .httpConnect, host: loopback, port: socksPort)))
        }
        if let socksAuthPort = port("PB_SELFTEST_SOCKS_AUTH_PROXY_PORT") {
            throughEach.append(("SOCKS5 with its login", ProxySettings(kind: .socks5, host: loopback, port: socksAuthPort,
                                                                       username: "pb-user2", password: "pb-pass2")))
        }
        // The HTTP listener with a login answers CONNECT only: the lookup through it is tunnelled
        // too (measured in CI run 392, where this was an info line and came back alive).
        if let authPort = port("PB_SELFTEST_HTTP_AUTH_PROXY_PORT") {
            throughEach.append(("HTTP CONNECT with its login", ProxySettings(kind: .httpConnect, host: loopback, port: authPort,
                                                                             username: "pb-user", password: "pb-pass")))
        }
        if let http6Port = port("PB_SELFTEST_HTTP6_PROXY_PORT") {
            throughEach.append(("HTTP CONNECT on ::1", ProxySettings(kind: .httpConnect, host: "::1", port: http6Port)))
        }
        for (name, proxy) in throughEach {
            let result = await ProxyChecker.check(proxy)
            check("proxy checker: through \(name), end to end — the exit IP, country and city the service saw",
                  result.isAlive && result.exitIP == "203.0.113.21" && result.countryCode == "DE" && result.city == "Berlin",
                  String(describing: result))
        }
        if let silentPort {
            let silent = await ProxyChecker.check(ProxySettings(kind: .socks5, host: loopback, port: silentPort))
            check("proxy checker: the silent proxy fails as silent, and nothing came back from anywhere",
                  silent.failure == .noAnswer && silent.diagnosis?.verdict == .silent && silent.exitIP == nil,
                  String(describing: silent))
        }

        let working = ProxySettings(kind: .httpConnect, host: loopback, port: httpPort)
        let alive = await ProxyChecker.lookUp(working)
        let aliveResult = ProxyChecker.result(of: alive)
        info("proxy checker: through the working proxy \(aliveResult), on \(alive?.connections.map(\.description) ?? [])")
        check("proxy checker: a working proxy is alive, with the exit IP, country and time zone the service saw through it, and a latency",
              aliveResult.isAlive && aliveResult.exitIP == "203.0.113.21" && aliveResult.countryCode == "DE"
                  && aliveResult.timeZoneIdentifier == "Europe/Berlin" && (aliveResult.latencyMilliseconds ?? 0) > 0,
              String(describing: aliveResult))
        // How the URL loading system reports a proxied connection's peer is not documented: said, not checked.
        info("proxy checker: the working proxy's check was made on connections "
             + ((alive?.connections ?? []).allSatisfy { ($0.port ?? httpPort) == httpPort } ? "to the proxy only" : "NOT all to the proxy"))

        // Port 9 (discard) on localhost is closed on CI runners, as in the fail-closed check above.
        let unreachable = await ProxyChecker.lookUp(ProxySettings(kind: .httpConnect, host: loopback, port: 9))
        let unreachableResult = ProxyChecker.result(of: unreachable)
        check("proxy checker: an unreachable proxy is dead, and nothing answered — not the website a direct request would reach either",
              unreachableResult.failure == .noAnswer && unreachable?.answered == false && unreachableResult.exitIP == nil,
              String(describing: unreachableResult))
        check("proxy checker: checking the unreachable proxy connected to nothing but it",
              unreachable?.connections.allSatisfy { ($0.port ?? 9) == 9 } == true,
              unreachable?.connections.map(\.description).joined(separator: ", ") ?? "no lookup")
        let notApplicable = await ProxyChecker.lookUp(ProxySettings(kind: .socks5, host: "127.0.0.1:1080", port: 1080))
        check("proxy checker: settings that cannot be applied are not checked at all (no request without the proxy)",
              notApplicable == nil && ProxyChecker.result(of: notApplicable).failure == .invalidSettings)
        if let authPort = port("PB_SELFTEST_HTTP_AUTH_PROXY_PORT") {
            let noCredentials = await ProxyChecker.check(ProxySettings(kind: .httpConnect, host: loopback, port: authPort))
            check("proxy checker: a proxy that wants credentials it was not given is dead for that reason",
                  noCredentials.failure == .needsCredentials && noCredentials.diagnosis?.verdict == .credentialsNeeded,
                  String(describing: noCredentials))
        }

        // The list's model: an import, a check of all of it two at a time, the results kept with
        // their proxies in the encrypted file.
        var lines = "http://127.0.0.1:\(httpPort)  # working\n127.0.0.1:9  # unreachable\n"
        let socksAuthPort = port("PB_SELFTEST_SOCKS_AUTH_PROXY_PORT")
        if let socksAuthPort { lines += "socks5://pb-user2:pb-pass2@127.0.0.1:\(socksAuthPort)  # socks with credentials\n" }
        var messages: [String] = []
        let model = ProxyListModel(vault: repository.vault) { messages.append($0) }
        let added = model.add(ProxyListImport.read(lines, defaultKind: .httpConnect).proxies)
        ProxyChecker.concurrentChecks = 2
        model.check()
        let finished = await waitUntil(timeout: 40) { !model.isChecking }
        let stored = try ProxyList.load(from: repository.vault)
        let found = Dictionary(stored.entries.compactMap { entry in entry.lastCheck.map { (entry.label, $0) } },
                               uniquingKeysWith: { first, _ in first })
        check("proxy list: several proxies checked at a time, each result kept with its proxy and saved encrypted",
              finished && added?.added.count == (socksAuthPort == nil ? 2 : 3)
                  && found["working"]?.isAlive == true && found["unreachable"]?.failure == .noAnswer
                  && found["unreachable"]?.diagnosis?.verdict == .refused
                  && (socksAuthPort == nil || found["socks with credentials"]?.isAlive == true) && messages.isEmpty,
              "\(found) \(messages)")

        // The type found by the check: a line without a scheme gets the one that answered, and an
        // entry listed with the wrong one is corrected.
        if let socksPort = port("PB_SELFTEST_SOCKS_PROXY_PORT"), let socks2Port = port("PB_SELFTEST_SOCKS2_PROXY_PORT") {
            let kindLines = "127.0.0.1:\(socksPort)  # no scheme\nhttp://127.0.0.1:\(socks2Port)  # SOCKS5 listed as HTTP\n"
            let kindIDs = model.add(ProxyListImport.read(kindLines).proxies)?.added ?? []
            let unknownBefore = kindIDs.first.flatMap { model.list.entry($0) }.map { !$0.kindKnown } ?? false
            model.check(Set(kindIDs))
            let kindsFinished = await waitUntil(timeout: 30) { !model.isChecking }
            let entries = kindIDs.compactMap { model.list.entry($0) }
            check("proxy list: a line without a scheme gets the type the check found, and a wrong type is corrected",
                  kindsFinished && unknownBefore && entries.count == 2 && entries.allSatisfy { $0.kindKnown && $0.proxy.kind == .socks5 }
                      && entries[0].lastCheck?.kindFinding == .found && entries[1].lastCheck?.kindFinding == .corrected(from: .httpConnect)
                      && entries.allSatisfy { $0.lastCheck?.isAlive == true },
                  entries.map { "\($0.label): \($0.proxy.kind.rawValue) known=\($0.kindKnown) \(String(describing: $0.lastCheck?.kindFinding))" }
                      .joined(separator: " | "))
        }

        // One proxy, one line (the editor's New, the list's Add): the four forms providers sell name
        // the same proxy; without a scheme its type is not known until Check finds it; the field
        // never shows the password while it is not being edited; and a draft makes the profile's
        // proxy from it with the type found.
        struct LineCase {
            let form: String
            let kind: ProxySettings.Kind
            let port: Int
            let user: String
            let password: String
        }
        var lineCases: [LineCase] = []
        if let socksAuthPort {
            lineCases += ["127.0.0.1:\(socksAuthPort):pb-user2:pb-pass2", "pb-user2:pb-pass2@127.0.0.1:\(socksAuthPort)",
                          "socks5://pb-user2:pb-pass2@127.0.0.1:\(socksAuthPort)", " 127.0.0.1:\(socksAuthPort):pb-user2:pb-pass2\n"]
                .map { LineCase(form: $0, kind: .socks5, port: socksAuthPort, user: "pb-user2", password: "pb-pass2") }
        }
        // An HTTP proxy without a scheme: the placeholder (SOCKS5) is not what it gets.
        if let authPort = port("PB_SELFTEST_HTTP_AUTH_PROXY_PORT") {
            lineCases += ["127.0.0.1:\(authPort):pb-user:pb-pass", "http://pb-user:pb-pass@127.0.0.1:\(authPort)"]
                .map { LineCase(form: $0, kind: .httpConnect, port: authPort, user: "pb-user", password: "pb-pass") }
        }
        if !lineCases.isEmpty {
            var outcomes: [String] = []
            var allRight = true
            for item in lineCases {
                var line = ProxyLine(text: item.form)
                let shown = line.maskedText ?? ""
                let before = line.reading
                var draft = ProfileDraft()
                draft.proxyMode = .new
                draft.proxyLine = line
                let saveChecksFirst = draft.needsKindCheck
                guard let checkable = line.checkable else {
                    allRight = false
                    outcomes.append("\(shown): not read")
                    continue
                }
                let result = await ProxyChecker.check(checkable)
                line.check = ProxyLine.Check(proxy: checkable, result: result)
                draft.proxyLine = line
                let made = try? draft.makeProxy()
                let schemeGiven = item.form.contains("://")
                let typeBefore: Bool
                switch before {
                case .proxy(_, .scheme): typeBefore = schemeGiven
                case .kindUnknown: typeBefore = !schemeGiven && saveChecksFirst
                default: typeBefore = false
                }
                let right = typeBefore && result.isAlive && made?.kind == item.kind && made?.host == "127.0.0.1"
                    && made?.port == item.port && made?.username == item.user && made?.password == item.password
                    && !shown.isEmpty && !shown.contains(item.password)
                allRight = allRight && right
                outcomes.append("\(shown) → " + (right ? "\(item.kind.rawValue)"
                    : "WRONG: type before \(typeBefore), alive \(result.isAlive), made \(made?.kind.rawValue ?? "nothing")"))
            }
            check("proxy line: the forms providers sell name the same proxy; without a scheme the type is not known (Save would check first) until Check finds the one that answers, end to end; the password is never shown",
                  allRight, outcomes.joined(separator: " | "))
        }
        if let silentPort {
            // A proxy that answers neither handshake: its type is never guessed, and no profile gets it.
            var line = ProxyLine(text: "127.0.0.1:\(silentPort)")
            if let checkable = line.checkable {
                line.check = ProxyLine.Check(proxy: checkable, result: await ProxyChecker.check(checkable))
            }
            var draft = ProfileDraft()
            draft.proxyMode = .new
            draft.proxyLine = line
            let refused = (try? draft.makeProxy()) == nil
            check("proxy line: a proxy whose check found no type (silent) is not made into a profile's proxy",
                  draft.needsKindCheck && refused && line.currentCheck?.result.diagnosis?.verdict == .silent,
                  String(describing: line.currentCheck?.result.diagnosis?.verdict))
        }

        // Given that checked proxy, a profile has it, and where it exits, before any launch.
        let profile = try repository.create(name: "Proxy from the list", configuration: ProfileConfiguration(ephemeral: true))
        if let entry = stored.entries.first(where: { $0.label == "working" }) {
            let outcome = repository.assign(ProxyList.rotation(of: [entry], over: [profile.id]))
            let configuration = try repository.loadConfiguration(profile.id)
            check("proxy list: a profile given a checked proxy has it, and knows where it exits without a launch",
                  outcome.changed == [profile.id] && configuration.proxy == entry.proxy
                      && configuration.rememberedProxyLocation?.countryCode == "DE"
                      && configuration.rememberedProxyLocation?.timeZoneIdentifier == "Europe/Berlin",
                  String(describing: configuration.lastProxyLocation))
        }
        try repository.delete(profile.id)

        // A profile started with a proxy that takes the connection and never answers says so, in
        // the checker's words; one whose proxy works says nothing.
        if let silentPort {
            let manager = ProfileManager(repository: repository)
            var reported: [(id: UUID, diagnosis: ProxyDiagnosis)] = []
            manager.onProxyProblem = { id, _, diagnosis in reported.append((id, diagnosis)) }
            let silentProfile = try repository.create(name: "Silent proxy", configuration: ProfileConfiguration(
                proxy: ProxySettings(kind: .socks5, host: loopback, port: silentPort), ephemeral: true, matchProxyLocation: false))
            let workingProfile = try repository.create(name: "Working proxy", configuration: ProfileConfiguration(
                proxy: working, ephemeral: true, matchProxyLocation: false))
            try await manager.launch(workingProfile.id)
            try await manager.launch(silentProfile.id)
            let said = await waitUntil(timeout: 25) { !reported.isEmpty }
            check("launch: a profile whose proxy takes the connection and never answers says why (silent), and one whose proxy works says nothing",
                  said && reported.map { $0.id } == [silentProfile.id] && reported.first?.diagnosis.verdict == .silent,
                  reported.map { "\($0.id == silentProfile.id ? "silent" : "working"): \($0.diagnosis.verdict.rawValue)" }.joined(separator: ", "))
            // Check, as what the profile said offers it: the same check, of the profile's own proxy.
            let fromProblem = await model.checkProfileProxy(ProxySettings(kind: .socks5, host: loopback, port: silentPort))
            check("launch: Check from what the profile said is the list's check of its proxy (silent), kept in the list",
                  fromProblem.diagnosis?.verdict == .silent && !fromProblem.isAlive
                      && model.list.entry(for: ProxySettings(kind: .socks5, host: loopback, port: silentPort))?.lastCheck?.diagnosis?.verdict == .silent,
                  String(describing: fromProblem))
            await manager.shutDown()
            // Settings → Proxies → do not start it: the proxy is asked first, and a profile whose
            // proxy does not work stays stopped, saying why; one whose proxy works starts.
            let refusing = ProfileManager(repository: repository)
            var refused: [(UUID, ProxyDiagnosis.Verdict)] = []
            refusing.refusesFailingProxy = { true }
            refusing.onProxyProblem = { _, _, _ in }
            refusing.onProxyLaunchRefused = { id, _, diagnosis in refused.append((id, diagnosis.verdict)) }
            try await refusing.launch(silentProfile.id)
            try await refusing.launch(workingProfile.id)
            let refusedIDs: [UUID] = refused.map { $0.0 }
            let refusedSilent: Bool = refused.first?.1 == ProxyDiagnosis.Verdict.silent
            check("launch: set not to start a profile whose proxy does not work, the silent one stays stopped and says why; the working one starts",
                  !refusing.isRunning(silentProfile.id) && refusedIDs == [silentProfile.id] && refusedSilent
                      && refusing.isRunning(workingProfile.id),
                  refused.map { "\($0.0 == silentProfile.id ? "silent" : "working"): \($0.1.rawValue)" }.joined(separator: ", "))
            await refusing.shutDown()
            try repository.delete(silentProfile.id)
            try repository.delete(workingProfile.id)
        }
        try? FileManager.default.removeItem(at: repository.root.appendingPathComponent("proxies.bin"))
    }

    // MARK: Profile deletion (regression for the delete crash)

    /// `remove(forIdentifier:)` and `WKWebsiteDataStore.nonPersistent()` crash (EXC_BAD_ACCESS on a
    /// nil `RunLoop::main()`) when they are the first WebKit use in the process — e.g. "unlock,
    /// then delete a profile" or "unlock, then open an ephemeral profile". Must run before anything
    /// else touches WebKit.
    /// The tunnel's all-interfaces switch (hardware checks only) is not turned on by a command-line
    /// argument: only by the app's own saved settings (`DebugSwitches`).
    private func debugSwitchesStayDebugSwitches() {
        let arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        var withSwitch = arguments
        withSwitch["PBTunnelAllInterfaces"] = true
        UserDefaults.standard.setVolatileDomain(withSwitch, forName: UserDefaults.argumentDomain)
        let turnedOn = DebugSwitches.tunnelAllInterfaces
        UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        check("the tunnel's all-interfaces switch is not turned on by a command-line argument", !turnedOn)
    }

    private func firstWebKitUse(_ repository: ProfileRepository) async throws {
        let vault = WebDataStoreVault(repository: repository)
        let removalsBefore = WebDataStoreVault.removeCallCount

        // The reported crash: deleting a profile that never ran must not call WebKit at all.
        let fresh = try repository.create(name: "Delete first", configuration: ProfileConfiguration())
        await vault.deleteData(profileID: fresh.id)
        try repository.delete(fresh.id)
        check("first WebKit use: deleting a never-launched profile does not call remove(forIdentifier:)",
              WebDataStoreVault.removeCallCount == removalsBefore && (try? repository.summary(for: fresh.id)) == nil)

        // Fail-closed, before anything has touched WebKit: a profile that protects its local requests
        // (every profile without a proxy, by default) does not start without its rule list, which
        // `ContentRules.prepare` compiles.
        let protected = try repository.create(name: "Protected first", configuration: ProfileConfiguration(ephemeral: true))
        var refusal = "started"
        do {
            try makeSession(repository, protected.id, key: repository.profileKey(for: protected.id)).shutDown()
        } catch CoreError.invalidConfiguration(let message) {
            refusal = message
        }
        try repository.delete(protected.id)
        check("local requests: a profile that protects them does not start before its rule list is ready",
              refusal == "the local-network rule list is not ready", refusal)

        // An ephemeral profile as the first WebKit use: its non-persistent store needs WebKit initialized.
        // Its local requests allowed, so that it needs no rule list (compiling one initializes WebKit).
        var firstConfiguration = ProfileConfiguration(ephemeral: true)
        firstConfiguration.localRequests = .allowed
        let ephemeral = try repository.create(name: "Ephemeral first", configuration: firstConfiguration)
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

    // MARK: What earlier versions left in the account's com.apple.Safari.plist

    /// `SafariAccountPreferences`, on a domain of the self-test's own in place of
    /// `com.apple.Safari` (the account's file is left alone): the keys earlier versions wrote, as a
    /// profile with a proxy and Safe Browsing off wrote them, three of them changed since — one to
    /// the other value, one to a value no profile of the vault gives, one to a number — and a key
    /// of the open and save panel's. The keys still holding a profile's value go; the three and the
    /// panel's stay, as another process (`defaults`) reads the domain; and a second time nothing
    /// is done.
    private func earlierVersionsSafariKeys() {
        guard !AppEnvironment.isSandboxed else {
            info("earlier versions' Safari keys: not checked in the sandboxed build, which does not take them out")
            return
        }
        let domain = "PrivacyBrowser.SelfTest.SafariKeys-\(UUID().uuidString.prefix(8))"
        let suite = "PrivacyBrowser.SelfTest.SafariKeysDone-\(UUID().uuidString.prefix(8))"
        let app = domain as CFString
        func set(_ key: String, _ value: CFPropertyList?) {
            CFPreferencesSetValue(key as CFString, value, app, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        }
        /// What the `defaults` command prints: another process, which gets the domain from cfprefsd.
        func defaultsCommand(_ arguments: [String]) -> Data {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return Data() }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return data
        }
        func exported() -> [String: Any] {
            let data = defaultsCommand(["export", domain, "-"])
            return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] ?? [:]
        }
        guard let defaults = UserDefaults(suiteName: suite) else {
            check("earlier versions' Safari keys: a defaults suite of the self-test's own", false, suite)
            return
        }
        defer {
            for (key, _) in SafariAccountPreferences.written { set(key, nil) }
            set("NSNavLastRootDirectory", nil)
            CFPreferencesSynchronize(app, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
            _ = defaultsCommand(["delete", domain])
            defaults.removePersistentDomain(forName: suite)
        }
        var profile = ProfileConfiguration()
        profile.proxy = ProxySettings(kind: .httpConnect, host: "127.0.0.1", port: 9)
        profile.safeBrowsingEnabled = false
        let profiles = [profile]
        for (key, written) in SafariAccountPreferences.written {
            set(key, written.value(for: profile) ? kCFBooleanTrue : kCFBooleanFalse)
        }
        let changed = ["AutoFillPasswords", "WebKitDNSPrefetchingEnabled", "PreloadTopHit"]
        set("AutoFillPasswords", kCFBooleanTrue)
        set("WebKitDNSPrefetchingEnabled", kCFBooleanTrue)
        set("PreloadTopHit", NSNumber(value: 0))
        set("NSNavLastRootDirectory", "~/Documents" as CFString)
        CFPreferencesSynchronize(app, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        let planted = exported()
        check("earlier versions' Safari keys: the domain holds them as planted, for another process too",
              planted.count == SafariAccountPreferences.written.count + 1, "\(planted.keys.sorted())")

        let first = SafariAccountPreferences.removeOnce(from: domain, defaults: defaults) { profiles }
        let ours = SafariAccountPreferences.written.map(\.key).filter { !changed.contains($0) }
        check("earlier versions' Safari keys: those still holding a profile's value are taken out, the three changed since are left",
              first?.removed == ours && first?.left == changed, String(describing: first))
        let after = exported()
        check("earlier versions' Safari keys: another process reads the domain without them",
              ours.allSatisfy { after[$0] == nil }, "\(after.keys.sorted())")
        check("earlier versions' Safari keys: the three changed since and the panel's key are as they were",
              (after["AutoFillPasswords"] as? Bool) == true && (after["WebKitDNSPrefetchingEnabled"] as? Bool) == true
                  && (after["PreloadTopHit"] as? NSNumber)?.intValue == 0
                  && (after["NSNavLastRootDirectory"] as? String) == "~/Documents",
              "\(after)")

        set("ExtensionsEnabled", kCFBooleanFalse)
        CFPreferencesSynchronize(app, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        let second = SafariAccountPreferences.removeOnce(from: domain, defaults: defaults) { profiles }
        check("earlier versions' Safari keys: taken out once — the second time nothing is done",
              second == nil && (exported()["ExtensionsEnabled"] as? Bool) == false, String(describing: second))
    }

    // MARK: Format policy (docs/UPDATES.md §4)

    /// Safari's home archive written by a newer version: refused as one, with no home left behind
    /// — an empty one would be sealed over the archive at the next stop or unlock — and the seals
    /// that follow leave the archive as it was. (The rules for every file: FormatPolicyTests.)
    private func formatPolicy(_ repository: ProfileRepository) throws {
        let profile = try repository.create(name: "Newer archive", configuration: ProfileConfiguration())
        defer { try? repository.delete(profile.id) }
        let key = try repository.profileKey(for: profile.id)
        let homes = SafariHomeVault(repository: repository)
        let home = homes.homeDirectory(for: profile.id)
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("pb-selftest-home-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: staging) }
        try FileManager.default.createDirectory(at: staging.appendingPathComponent("Library/Safari"), withIntermediateDirectories: true)
        try Data("history".utf8).write(to: staging.appendingPathComponent("Library/Safari/History.db"))
        let archive = repository.safariHomeArchiveURL(for: profile.id)
        try EncryptedDirectoryArchive.seal(roots: [ProfileTransfer.safariHomeLabel: staging], to: archive, key: key)
        var newer = try Data(contentsOf: archive)
        newer[4] = 2 // the version, after "PBSA"
        try newer.write(to: archive)

        // A first launch, and one after a run that left an empty home (as a profile that wrote nothing does).
        for leftover in [false, true] {
            if leftover { try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true) }
            var refusal: Error?
            do { try homes.prepareForLaunch(profileID: profile.id, key: key) } catch { refusal = error }
            var refusedAsNewer = false
            if case .newerFormat? = refusal as? CoreError { refusedAsNewer = true }
            let when = leftover ? "after an empty home was left" : "at a first launch"
            check("format policy: Safari's home archive of a newer version is refused as one, \(when)", refusedAsNewer,
                  String(describing: refusal))
            check("format policy: the refused archive leaves no home to be sealed over it, \(when)",
                  !FileManager.default.fileExists(atPath: home.path))
            try? homes.seal(profileID: profile.id, key: key) // what a stop, or the recovery at unlock, does next
            check("format policy: the newer version's archive is as it was, \(when)", (try? Data(contentsOf: archive)) == newer)
        }
        // Even with a home there, nothing is sealed over the archive.
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        var sealRefusal: Error?
        do { try homes.seal(profileID: profile.id, key: key) } catch { sealRefusal = error }
        var sealRefusedAsNewer = false
        if case .newerFormat? = sealRefusal as? CoreError { sealRefusedAsNewer = true }
        check("format policy: a home is not sealed over a newer version's archive",
              sealRefusedAsNewer && (try? Data(contentsOf: archive)) == newer, String(describing: sealRefusal))
        try? FileManager.default.removeItem(at: home)
    }

    // MARK: Update gate (docs/UPDATES.md §3)

    /// The check before an update may be handed to its installer, on this Mac's real layout and
    /// vault: a sealed profile passes it; website data or a Safari home left in plaintext, or a home
    /// a process still holds, fails it and names the profile; so do activity and a killed process.
    private func updateGate(_ repository: ProfileRepository) throws {
        let profile = try repository.create(name: "Update gate", configuration: ProfileConfiguration())
        defer { try? repository.delete(profile.id) }
        let id = profile.id.uuidString
        func verdict(activity: Bool = false, killed: Int = 0) -> UpdateGate.Verdict {
            UpdateGate.check(vaultRoot: repository.root, hasActivity: activity, forcedExits: killed)
        }
        func ours(_ verdict: UpdateGate.Verdict) -> [String] { verdict.reasons.filter { $0.contains(id) } }

        check("update gate: a sealed profile passes it", ours(verdict()).isEmpty, verdict().reasons.joined(separator: "; "))
        check("update gate: a profile still running, starting or sealing fails it", !verdict(activity: true).passed)
        check("update gate: a profile process killed during the quit fails it", !verdict(killed: 1).passed)

        let leftover = WebDataStoreVault.layout.searchRoots[0].appendingPathComponent("WebsiteDataStore/\(id.lowercased())", isDirectory: true)
        try FileManager.default.createDirectory(at: leftover, withIntermediateDirectories: true)
        let withData = ours(verdict())
        try? FileManager.default.removeItem(at: leftover)
        check("update gate: website data left in plaintext fails it", withData.contains { $0.contains("website data") }, withData.joined(separator: "; "))

        let home = repository.directory(for: profile.id).appendingPathComponent("home.noindex", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let withHome = ours(verdict())
        try? FileManager.default.removeItem(at: home)
        check("update gate: a Safari home left in plaintext fails it", withHome.contains { $0.contains("Safari's home") }, withHome.joined(separator: "; "))

        // Held the way a profile's process holds its home (`SafariHomeVault.holdWhileRunning`).
        let lock = repository.directory(for: profile.id).appendingPathComponent("home.lock")
        let descriptor = open(lock.path, O_RDWR | O_CREAT, 0o600)
        flock(descriptor, LOCK_EX)
        let held = ours(verdict())
        flock(descriptor, LOCK_UN)
        close(descriptor)
        check("update gate: a home a process still holds fails it", held.contains { $0.contains("holds its home") }, held.joined(separator: "; "))
        check("update gate: passes again once all of that is gone", ours(verdict()).isEmpty, verdict().reasons.joined(separator: "; "))
    }

    // MARK: Settings (one window, ⌘,)

    /// The app's settings: each kept in its own key and read back as set, what is out of range read
    /// as the default; a quit that asks first and stops nothing on "no"; and in a browser window,
    /// where a new tab goes and the zoom it opens at, the question before closing a window of
    /// several tabs, AutoFill's switch over the profile's own, where a download goes, the letters
    /// on a profile's Dock icon, which profiles a quit keeps to reopen, and the settings as a
    /// profile's own process gets them.
    /// A profile's glyph, tags and notes: through the editor as written and held to their limits,
    /// and the Profiles list finding profiles by them.
    private func editorLabels() throws {
        var labelled = ProfileDraft(name: "Labelled", configuration: ProfileConfiguration())
        labelled.tags = [" ads ", "ADS", "US"]
        labelled.notes = "  renews monthly \n"
        labelled.avatarColor = 6
        labelled.avatarLetters = "N W"
        let labels = try labelled.makeConfiguration()
        let reopened = ProfileDraft(name: "Labelled", configuration: labels)
        let keptTags: Bool = labels.tags == ["ads", "US"]
        let keptNotes: Bool = labels.notes == "renews monthly"
        let keptGlyph: Bool = labels.avatar == ProfileAvatarStyle(color: 6, letters: "NW")
        let shownAgain: Bool = reopened.tags == labels.tags && reopened.notes == labels.notes
        let glyphAgain: Bool = reopened.avatarStyle == labels.avatar
        check("editor: tags, notes and the glyph are kept as written (each tag once, trimmed) and shown again as kept",
              keptTags && keptNotes && keptGlyph && shownAgain && glyphAgain,
              "tags \(labels.tags), notes \(labels.notes), glyph \(String(describing: labels.avatar))")
        let plain = ProfileDraft(name: "Plain", configuration: ProfileConfiguration())
        let plainConfiguration = try plain.makeConfiguration()
        let plainKept: Bool = plainConfiguration.tags.isEmpty && plainConfiguration.notes.isEmpty && plainConfiguration.avatar == nil
        check("editor: a profile without them is saved without them", plainKept)

        // Time zone and language: from the connection, chosen, or a place picked at random.
        var manual = ProfileDraft(name: "Locale", configuration: ProfileConfiguration())
        manual.localeMode = .manual
        manual.timeZone = "Asia/Tokyo"
        manual.language = "ja-JP"
        let manualSaved = try manual.makeConfiguration()
        var random = ProfileDraft(name: "Locale", configuration: ProfileConfiguration())
        random.pickRandomPlace()
        let randomSaved = try random.makeConfiguration()
        let connectionSaved = try ProfileDraft(name: "Locale", configuration: ProfileConfiguration()).makeConfiguration()
        let manualKept: Bool = manualSaved.timeZoneIdentifier == "Asia/Tokyo" && manualSaved.languageOverride == "ja-JP"
            && !manualSaved.matchProxyLocation && manualSaved.effectiveLocaleSource == LocaleSource.manual
        let randomPlace = LocalePlaces.place(timeZone: randomSaved.timeZoneIdentifier, language: randomSaved.languageOverride)
        let randomKept: Bool = randomSaved.localeSource == LocaleSource.random && randomPlace != nil
            && ProfileDraft(name: "Locale", configuration: randomSaved).localeMode == LocaleSource.random
        let connectionKept: Bool = connectionSaved.timeZoneIdentifier == nil && connectionSaved.languageOverride == nil
            && connectionSaved.matchProxyLocation && connectionSaved.localeSource == nil
        check("editor: time zone and language from the connection, chosen, or a place picked at random — saved as such and shown again so",
              manualKept && randomKept && connectionKept,
              "manual \(manualSaved.timeZoneIdentifier ?? "-") \(manualSaved.languageOverride ?? "-"), random \(randomSaved.timeZoneIdentifier ?? "-") \(randomSaved.languageOverride ?? "-")")

        let row = ProfileRowItem(id: UUID(), name: "Northwind", activity: .stopped, exit: .direct, ephemeral: false,
                                 appearsAs: "", lastUsed: nil, tags: ["ads", "US"], notes: "Renews monthly")
        let other = ProfileRowItem(id: UUID(), name: "Research", activity: .stopped, exit: .direct, ephemeral: false,
                                   appearsAs: "", lastUsed: nil, tags: ["mobile", "ads"])
        let byTag: Bool = ProfileFilter.tag("ADS").includes(row) && !ProfileFilter.tag("mobile").includes(row)
        let bySearch: Bool = ProfilesScreen.matches(row, "renews") && ProfilesScreen.matches(row, "us")
            && !ProfilesScreen.matches(row, "mobile")
        let sidebarTags: [String] = ProfileFilter.tags(of: [row, other])
        check("profiles: a tag in the sidebar shows the profiles with it, whatever its case; the search finds a profile by a tag or its notes",
              byTag && bySearch && sidebarTags == ["ads", "mobile", "US"], "sidebar tags \(sidebarTags)")
    }

    /// A profile's window size: its window really opens at it — a page measures the window it is
    /// in — and never larger than the screen allows; a new profile's random size fits.
    private func windowSizes(_ repository: ProfileRepository) async throws {
        guard let visible = WindowSizing.visibleScreen else {
            info("window size: no screen to measure against; skipped")
            return
        }
        func frame(of size: WindowSize) async throws -> (window: CGSize, page: [Int]) {
            let profile = try repository.create(name: "Window size", configuration: ProfileConfiguration(ephemeral: true, windowSize: size))
            let key = try repository.profileKey(for: profile.id)
            let session = try makeSession(repository, profile.id, key: key)
            let controller = BrowserWindowController(session: session)
            defer {
                controller.close()
                session.shutDown()
                try? repository.delete(profile.id)
            }
            let window = controller.window?.frame.size ?? .zero
            guard let tab = controller.addTab(url: nil) else { return (window, []) }
            tab.webView.loadHTMLString("<!doctype html><title>measured</title>", baseURL: nil)
            _ = await waitUntil(timeout: 10) { tab.webView.title == "measured" }
            let measured = try? await js(tab.webView, "return [window.outerWidth, window.outerHeight]")
            return (window, ((measured as? [NSNumber]) ?? []).map(\.intValue))
        }
        let wanted = WindowSize.custom(width: 1000, height: 700)
        let expected = WindowSizing.fitted(wanted, in: visible)
        let sized = try await frame(of: wanted)
        let pageSize: [Int] = [Int(sized.window.width), Int(sized.window.height)]
        check("window size: a profile's window opens at its size (as large as the screen allows)",
              sized.window == expected, "window \(sized.window), expected \(expected), screen \(visible)")
        check("window size: a page measures that window — outerWidth × outerHeight are its real frame",
              sized.page == pageSize, "page \(sized.page), window \(sized.window)")
        let huge = try await frame(of: .custom(width: 7000, height: 4000))
        check("window size: one larger than the screen opens as large as the screen allows, never larger",
              huge.window.width <= visible.width && huge.window.height <= visible.height
                && huge.window == WindowSizing.fitted(.custom(width: 7000, height: 4000), in: visible),
              "window \(huge.window), screen \(visible)")
        var generator = SystemRandomNumberGenerator()
        let fits = (0..<50).allSatisfy { _ in
            let random = WindowSize.randomSafe(fitting: (Int(visible.width), Int(visible.height)), using: &generator)
            return WindowSizing.fitted(random, in: visible) == CGSize(width: random.frame.width, height: random.frame.height)
                || visible.width < CGFloat(WindowSize.minimumWidth) || visible.height < CGFloat(WindowSize.minimumHeight)
        }
        check("window size: a new profile's random size always fits this Mac's screen", fits, "screen \(visible)")
    }

    /// A macOS profile that names another Safari version: the page's navigator.userAgent says
    /// that version, as the request headers do (the same string, WebKit's customUserAgent).
    private func namedSafariVersion(_ repository: ProfileRepository) async throws {
        let named = SafariVersions.recent.first { SafariVersions.distance(of: $0, fromHost: HostSafari.version) == .far } ?? "18.6"
        let configuration = ProfileConfiguration(ephemeral: true, safariVersion: named)
        let wanted = configuration.userAgent(hostSafariVersion: HostSafari.version)
        let profile = try repository.create(name: "Safari version", configuration: configuration)
        let session = try makeSession(repository, profile.id, key: repository.profileKey(for: profile.id))
        defer {
            session.shutDown()
            try? repository.delete(profile.id)
        }
        let tab = BrowserTab(configuration: session.makeWebViewConfiguration(), context: session.tabContext)
        defer { tab.tearDown() }
        tab.webView.loadHTMLString("<!doctype html><title>agent</title>", baseURL: nil)
        _ = await waitUntil(timeout: 10) { tab.webView.title == "agent" }
        let seen = (try? await js(tab.webView, "return navigator.userAgent")) as? String ?? ""
        check("identity: a named Safari version is what the profile calls itself — the page's User-Agent says Version/\(named), the engine stays Safari \(HostSafari.version)",
              seen == wanted && wanted.contains("Version/\(named) Safari/"), "page \(seen), wanted \(wanted)")
    }

    /// A profile without a proxy that protects its local requests: a page of the internet reaches
    /// neither this Mac nor the local network; allowed, it reaches this Mac, as in Safari. (A
    /// profile with a proxy keeps the proxied list's checks: this Mac refused, the local network
    /// through the proxy — the Safari-chrome check.)
    private func localRequests(_ repository: ProfileRepository) async throws {
        let compiled = ContentRules.localNetworkRules != nil
        check("local requests: the local-network rule list compiled", compiled, ContentRules.compileErrors.joined(separator: " | "))
        let environment = ProcessInfo.processInfo.environment
        guard compiled, let canary = environment["PB_SELFTEST_CANARY_PORT"].flatMap(Int.init) else {
            info("local requests: no canary listener (PB_SELFTEST_CANARY_PORT); the checks in a page skipped")
            return
        }
        func attempt(_ requests: LocalRequests, run: String) async throws -> [String: String] {
            let profile = try repository.create(name: "Local requests", configuration: ProfileConfiguration(ephemeral: true, localRequests: requests))
            let session = try makeSession(repository, profile.id, key: repository.profileKey(for: profile.id))
            defer {
                session.shutDown()
                try? repository.delete(profile.id)
            }
            let tab = BrowserTab(configuration: session.makeWebViewConfiguration(), context: session.tabContext)
            defer { tab.tearDown() }
            // A page of the internet: its document's address is a public name (its bytes come from here).
            tab.webView.loadHTMLString("<!doctype html><title>local</title>", baseURL: URL(string: "http://public-\(run).example/"))
            _ = await waitUntil(timeout: 10) { tab.webView.title == "local" }
            let script = """
            const attempt = async (url) => {
              const outcome = fetch(url, { mode: 'no-cors', cache: 'no-store' }).then(() => 'resolved', () => 'rejected');
              const late = new Promise((resolve) => setTimeout(() => resolve('pending'), 2500));
              return await Promise.race([outcome, late]);
            };
            return {
              loopback: await attempt(`http://127.0.0.1:${port}/pb-local?run=${run}`),
              lan: await attempt('http://10.255.255.1:8080/pb-local-lan'),
              name: await attempt(`http://printer-${run}.local/pb-local-name`),
            };
            """
            return (try? await js(tab.webView, script, ["port": canary, "run": run])) as? [String: String] ?? [:]
        }
        func canaryHits(_ run: String) async -> Int? {
            guard let httpPort = environment["PB_SELFTEST_HTTP_PROXY_PORT"].flatMap(Int.init) else { return nil }
            let proxy = ProxySettings(kind: .httpConnect, host: "127.0.0.1", port: httpPort)
            let url = URL(string: "http://proxied.selftest.invalid/pb-leak/log.json?run=\(run)")!
            guard let text = try? await loadThroughProxy(repository, proxy, url: url),
                  let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { return nil }
            return (object["canary"] as? [Any])?.count
        }
        func runID() -> String { String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12)).lowercased() }

        let protectedRun = runID()
        let protected = try await attempt(.protected, run: protectedRun)
        let protectedHits = await canaryHits(protectedRun)
        let refused: Bool = protected["loopback"] == "rejected" && protected["lan"] == "rejected" && protected["name"] == "rejected"
        check("local requests: protected, a page of the internet reaches neither this Mac (127.0.0.1) nor the local network (10.x, a .local name)",
              refused && (protectedHits ?? 0) == 0, "\(protected), canary \(protectedHits.map(String.init) ?? "not asked")")

        let allowedRun = runID()
        let allowed = try await attempt(.allowed, run: allowedRun)
        let allowedHits = await canaryHits(allowedRun)
        check("local requests: allowed, the same page reaches this Mac, as in Safari",
              allowed["loopback"] == "resolved" && (allowedHits ?? 1) > 0, "\(allowed), canary \(allowedHits.map(String.init) ?? "not asked")")
        info("local requests: allowed, the local network answered \(allowed["lan"] ?? "?") (10.255.255.1) and \(allowed["name"] ?? "?") (a .local name)")
    }

    /// Cookies pasted in the editor of a new profile: read as Import Cookies reads a file, and
    /// queued for the new profile, encrypted, until its first launch.
    private func cookiesAtCreation(_ repository: ProfileRepository) async throws {
        let expiry = Int(Date().addingTimeInterval(30 * 86_400).timeIntervalSince1970)
        var draft = ProfileDraft()
        draft.cookieText = "# Netscape HTTP Cookie File\n.example.com\tTRUE\t/\tTRUE\t\(expiry)\tsid\tabc123\n"
        draft.readCookieText()
        let netscape: [ImportedCookie] = draft.cookieReport?.cookies ?? []
        draft.cookieText = #"[{"domain":".example.org","name":"pref","value":"1","path":"/","expirationDate":\#(expiry)}]"#
        draft.readCookieText()
        let json: [ImportedCookie] = draft.cookieReport?.cookies ?? []
        let readNetscape: Bool = netscape.count == 1 && netscape.first?.name == "sid"
        let readJSON: Bool = json.count == 1 && json.first?.name == "pref"
        check("editor: cookies pasted for a new profile are read as Import Cookies reads a file (cookies.txt, JSON)",
              readNetscape && readJSON, "cookies.txt \(netscape.map(\.name)), JSON \(json.map(\.name))")

        let profile = try repository.create(name: "Cookies at creation", configuration: ProfileConfiguration())
        defer { try? repository.delete(profile.id) }
        let manager = ProfileManager(repository: repository)
        let outcome = try await manager.importCookies(netscape + json, into: profile.id)
        var queued = 0
        if case let .queued(count) = outcome { queued = count }
        check("editor: a new profile's cookies wait, encrypted, for its first launch (as Import Cookies queues them)",
              queued == 2, "outcome \(outcome)")
    }

    /// Settings → Diagnostics: the ZIP holds the report, the state and the logs, and nothing of
    /// the user's — searched for in its bytes (stored, not compressed, so the bytes are the files).
    private func diagnosticsBundle(_ repository: ProfileRepository) async throws {
        let run = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12)).lowercased()
        let secrets = ["Diag-\(run)", "tag-\(run)", "note-\(run)", "proxy-\(run).example", "user-\(run)", "pw-\(run)", run]
        let proxy = ProxySettings(kind: .socks5, host: "proxy-\(run).example", port: 1080, username: "user-\(run)", password: "pw-\(run)")
        let profile = try repository.create(name: "Diag-\(run)", configuration: ProfileConfiguration(
            proxy: proxy, ephemeral: true, tags: ["tag-\(run)"], notes: "note-\(run)"))
        defer { try? repository.delete(profile.id) }
        // A value of the user's in the log, as the app writes one: the bundle must show it as <private>.
        Logger(subsystem: "PrivacyBrowser", category: "Diagnostics").notice("Self-test diagnostics marker \(run, privacy: .private)")

        let data = await Diagnostics.bundle(Diagnostics.snapshot(repository: repository), logMinutes: 5)
        let entries = StoredZip.entries(of: data) ?? []
        let paths = Set(entries.map(\.path))
        let wanted: Set<String> = ["report.txt", "state.json", "logs/this-run.txt", "README.txt"]
        check("diagnostics: the ZIP holds the report, the state and the logs, and reads back", wanted.isSubset(of: paths),
              "\(paths.sorted())")
        let leaked = secrets.filter { data.range(of: Data($0.utf8)) != nil }
        let log = String(decoding: entries.first { $0.path == "logs/this-run.txt" }?.data ?? Data(), as: UTF8.self)
        let markerSeen: Bool = log.contains("Self-test diagnostics marker")
        check("diagnostics: nothing of the user's is in it — a profile's name, tag and notes, its proxy's address, user and password, a private log value",
              leaked.isEmpty, "found: \(leaked)")
        check("diagnostics: this run's log is in it, with the user's values as <private>",
              markerSeen, String(log.suffix(400)))
        let report = String(decoding: entries.first { $0.path == "report.txt" }?.data ?? Data(), as: UTF8.self)
        let named: Bool = report.contains("PrivacyBrowser ") && report.contains("macOS ") && report.contains("Safari \(HostSafari.version)")
        check("diagnostics: the short report names the version, macOS, Safari and WebKit, and the checks made",
              named && report.contains("✓"), report)
        info("diagnostics: the short report reads\n\(report)")
    }

    /// Paste as Typed, in a real window: in the key window the text arrives in the page's focused
    /// field as typing — trusted keydown, input and keyup events, Shift around a capital, each
    /// character's own key — and a page with no focused field is told so; a window without the
    /// keyboard gets nothing (a runner that gives none is reported: the typing is then not shown).
    /// The command palette ranks what is typed.
    private func pasteAsTyped(_ repository: ProfileRepository) async throws {
        let commands = ["Launch Northwind", "Settings: Startup", "Edit Research…", "Proxies…"].map { title in
            CommandPaletteView.Command(id: title, title: title, symbol: "circle", run: {})
        }
        let ranked = CommandPaletteView.rank(commands, query: "north").map(\.title)
        let all = CommandPaletteView.rank(commands, query: "  ").map(\.title)
        check("palette: what is typed finds the command, and nothing typed shows all of them in order",
              ranked == ["Launch Northwind"] && all == commands.map(\.title), "\(ranked)")

        let profile = try repository.create(name: "Typing", configuration: ProfileConfiguration(ephemeral: true))
        let session = try makeSession(repository, profile.id, key: repository.profileKey(for: profile.id))
        let policy = NSApp.activationPolicy()
        defer {
            session.shutDown()
            try? repository.delete(profile.id)
            NSApp.setActivationPolicy(policy)
        }
        // Key events reach a web view in a key window, which the self-test's .prohibited
        // activation policy never gives (as in the password checks).
        NSApp.setActivationPolicy(.accessory)
        NSApp.activate(ignoringOtherApps: true)
        let controller = session.openWindow(url: nil)
        guard let tab = controller.selectedTab, let window = controller.window else {
            check("paste as typed: a profile window with a tab", false)
            return
        }
        window.makeKeyAndOrderFront(nil)
        let webView = tab.webView
        let page = """
        <!doctype html><title>typing</title><input id="field">
        <script>
        window.typed = [];
        for (const kind of ['keydown', 'keyup', 'input']) {
          document.addEventListener(kind, (e) => window.typed.push([kind, e.isTrusted, e.key || e.data || '', e.code || '']), true);
        }
        </script>
        """
        webView.loadHTMLString(page, baseURL: nil)
        let loaded = await waitUntil(timeout: 10) { webView.title == "typing" && !webView.isLoading }
        let isKey = await waitUntil(timeout: 3) { window.isKeyWindow }
        _ = window.makeFirstResponder(webView)
        _ = try? await js(webView, "document.getElementById('field').focus(); return true;")
        info("paste as typed: app active: \(NSApp.isActive); key window: \(isKey)")
        guard loaded else {
            check("paste as typed: the page to type in loads", false, webView.title ?? "nil")
            return
        }
        func field() async -> String {
            (try? await js(webView, "return document.getElementById('field').value;")) as? String ?? ""
        }
        let text = "Hi, Мир 1!"
        guard isKey else {
            // A person types only where the keyboard is: into a window without it, nothing.
            let outcome = await HumanPaste.type(text, into: webView, speed: 8)
            let value = await field()
            check("paste as typed: into a window without the keyboard nothing is typed, and it says so",
                  outcome == HumanPaste.Outcome.notAField && value.isEmpty, "outcome \(outcome), field \(value)")
            info("paste as typed: this runner gives the window no keyboard — the typing itself is not shown here")
            return
        }
        // The control: one key down and up as the password checks send theirs. Where it does not
        // reach the page, no synthesized key does on this machine, Paste as Typed's included.
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            if let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [],
                                            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                            context: nil, characters: "z", charactersIgnoringModifiers: "z",
                                            isARepeat: false, keyCode: 0x06) {
                window.sendEvent(event)
            }
        }
        var control = await field()
        let controlDeadline = Date().addingTimeInterval(2)
        while control != "z", Date() < controlDeadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
            control = await field()
        }
        _ = try? await js(webView, "document.getElementById('field').value = ''; document.activeElement.blur(); return true;")
        let unfocused = await HumanPaste.type("x", into: webView, speed: 8)
        let untouched = await field()
        check("paste as typed: with no field focused in the page, nothing is typed and it says so",
              unfocused == HumanPaste.Outcome.notAField && untouched.isEmpty, "\(unfocused), field \(untouched)")
        _ = try? await js(webView, "document.getElementById('field').focus(); window.typed = []; return true;")
        guard control == "z" else {
            let none = await HumanPaste.type(text, into: webView, speed: 8)
            info("paste as typed: synthesized key events do not reach the page on this runner (the control key did not arrive; Paste as Typed: \(none)) — the typing itself is not shown here")
            return
        }
        let outcome = await HumanPaste.type(text, into: webView, speed: 8)
        var value = await field()
        let deadline = Date().addingTimeInterval(3)
        while value != text, Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
            value = await field()
        }
        let events = (try? await js(webView, "return window.typed;")) as? [[Any]] ?? []
        check("paste as typed: the clipboard's text arrives in the page's focused field, as typed",
              outcome == HumanPaste.Outcome.typed(text.count) && value == text, "outcome \(outcome), field \(value)")
        let keydowns = events.filter { $0.first as? String == "keydown" }
        let characterDowns = keydowns.filter { ($0[2] as? String) != "Shift" }
        let trusted: Bool = !events.isEmpty && events.allSatisfy { ($0[1] as? Bool) == true }
        let shift: Bool = keydowns.contains { ($0[2] as? String) == "Shift" }
        let codes: Bool = characterDowns.contains { ($0[2] as? String) == "H" && ($0[3] as? String) == "KeyH" }
            && characterDowns.contains { ($0[2] as? String) == "М" && ($0[3] as? String) == "KeyV" }
        check("paste as typed: the page sees trusted key events — a key down per character, on its own key (H on KeyH, М on KeyV), Shift around a capital",
              trusted && characterDowns.count == text.count && shift && codes,
              "\(events.prefix(16).map { $0.map { "\($0)" }.joined(separator: " ") })")
    }

    /// What sites see, in this process: the snapshot's listener answers only its own pages and
    /// only to this Mac's loopback address; a profile's window (no proxy, its local requests
    /// protected) measures every part — navigator, screen, the window, request headers in their
    /// order, TLS (a ClientHello read: JA3, JA4), APIs — and the page is neither in its history
    /// nor left open. Safari's side is stood in for by a plain WebKit view: this run is inside the
    /// egress capture, where Safari's own traffic would count. The real Safari is CI's step
    /// "What sites see" (`--what-sites-see-check`).
    private func whatSitesSee(_ repository: ProfileRepository) async throws {
        let listener = SiteSnapshotServer { token, _ in "page of \(token)" }
        guard await listener.start() else {
            check("what sites see: the snapshot listens on 127.0.0.1", false)
            return
        }
        let page = listener.newPage(.profile)
        let port = Int(listener.httpPort)
        func get(_ target: String, host: String) async -> (status: Int, body: String) {
            let request = Data("GET \(target) HTTP/1.1\r\nHost: \(host)\r\nContent-Length: 0\r\n\r\n".utf8)
            let answer = await Task.detached { Self.rawHTTP(port: port, request) }.value
            guard let answer, let text = String(data: answer, encoding: .utf8),
                  let status = text.split(separator: " ", maxSplits: 2).dropFirst().first.flatMap({ Int($0) }) else { return (0, "") }
            return (status, text.components(separatedBy: "\r\n\r\n").dropFirst().joined(separator: "\r\n\r\n"))
        }
        let own = await get("/headers.html?token=\(page.token)", host: "127.0.0.1:\(port)")
        let rebound = await get("/headers.html?token=\(page.token)", host: "rebind.example:\(port)")
        let stranger = await get("/headers.html?token=\(SiteSnapshotPage.token(.profile))", host: "127.0.0.1:\(port)")
        listener.stop()
        check("what sites see: the listener serves its own page, and refuses another token and a name that is not this Mac's",
              own.status == 200 && own.body == "page of \(page.token)" && rebound.status == 404 && stranger.status == 404,
              "own \(own.status), rebound \(rebound.status), stranger \(stranger.status)")

        let profile = try repository.create(name: "What sites see", configuration: ProfileConfiguration(ephemeral: true))
        let manager = ProfileManager(repository: repository)
        final class StandIn {
            var window: NSWindow?
            var launchError = ""
        }
        let standIn = StandIn()
        let snapshot = WhatSitesSee(profileID: profile.id, manager: { manager }, launch: { id in
            do { try await manager.launch(id) } catch { standIn.launchError = String(describing: error) }
        })
        snapshot.openInSafari = { url in
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 1000, height: 700), configuration: configuration)
            let window = NSWindow(contentRect: view.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = view
            window.orderFront(nil)
            view.load(URLRequest(url: url))
            standIn.window = window
            return true
        }
        snapshot.safariTimeout = 60
        defer {
            standIn.window?.close()
            try? repository.delete(profile.id)
        }
        await snapshot.take()
        let measured = snapshot.profileSnapshot?.values ?? [:]
        let parts = ["probe.ua", "probe.screen", "geometry.chrome", "apis.quota", "headers.navigation.order", "tls.ja4", "tls.cipherSuites"]
        let missing = parts.filter { measured[$0] == nil }
        check("what sites see: a profile's window measured every part — navigator, screen, the window, request headers in order, TLS (a ClientHello read), APIs",
              snapshot.step == WhatSitesSee.Step.done && missing.isEmpty && (measured["headers.navigation.order"] ?? "").contains("User-Agent"),
              "step \(snapshot.step), missing \(missing), launch \(standIn.launchError)")
        let ja4 = snapshot.signals.first { $0.key == "tls.ja4" }
        check("what sites see: compared with the other side; the profile's ClientHello is a plain WebKit view's (one network stack)",
              snapshot.comparedWithSafari && ja4?.verdict == .same,
              "compared \(snapshot.comparedWithSafari), ja4 \(ja4?.profile ?? "nil") / \(ja4?.safari ?? "nil")")
        info("what sites see: the profile next to a plain WebKit view — " + SiteSignalCategory.allCases.map { category in
            "\(category.rawValue) \(WhatSitesSeeView.summary(snapshot.signals.filter { $0.category == category }))"
        }.joined(separator: "; "))
        let session = manager.session(for: profile.id)
        let inHistory = session?.library.historyEntries(matching: "127.0.0.1") ?? []
        let leftOpen = session?.windowControllers.contains { controller in
            controller.tabs.contains { $0.url.map(SiteSnapshotPage.isMeasuringPage) == true }
        } ?? true
        check("what sites see: the measuring page is not in the profile's history, and its window is closed",
              session != nil && inHistory.isEmpty && !leftOpen, "history \(inHistory.map(\.url)), left open \(leftOpen)")
        try? await manager.stop(profile.id)
    }

    /// `--what-sites-see-check [--safari-window] [--proxy host:port]`: a new profile's snapshot next
    /// to this Mac's real Safari, taken as the panel takes it, printed signal by signal — CI's steps
    /// after the egress capture. `--safari-window`: the profile in a process of its own showing
    /// Safari's window, as the build without the App Sandbox shows a profile (refused when the
    /// window would not be Safari's); without it, in this process and this app's window. `--proxy`:
    /// an HTTP CONNECT proxy in the profile's settings, as a customer's profile has one; the
    /// measuring page is on this Mac and loads directly, so the proxy need not answer. Exit 0 when
    /// both were measured, 2 when Safari did not answer (CI warns), 1 when the profile's side could
    /// not be taken.
    static func whatSitesSeeCheck(arguments: [String]) {
        setvbuf(stdout, nil, _IOLBF, 0)
        let inSafariWindow = arguments.contains("--safari-window")
        let proxy: ProxySettings?
        if let index = arguments.firstIndex(of: "--proxy") {
            guard arguments.indices.contains(index + 1), let field = try? ProxyHostField.parse(arguments[index + 1]),
                  let port = field.port else {
                print("WHAT-SITES-SEE --proxy wants host:port")
                exit(64)
            }
            proxy = ProxySettings(kind: .httpConnect, host: field.host, port: port)
        } else {
            proxy = nil
        }
        // In this process, as in the self-test, or in one of its own with Safari's window.
        setenv("PB_PROFILE_PROCESS", inSafariWindow ? "1" : "0", 1)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        DispatchQueue.main.asyncAfter(deadline: .now() + 360) {
            print("WHAT-SITES-SEE TIMEOUT after 360 s")
            exit(1)
        }
        Task { @MainActor in exit(await runWhatSitesSeeCheck(inSafariWindow: inSafariWindow, proxy: proxy)) }
        app.run()
    }

    private static func runWhatSitesSeeCheck(inSafariWindow: Bool, proxy: ProxySettings?) async -> Int32 {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pb-what-sites-see-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository: ProfileRepository
        let profile: ProfileSummary
        do {
            repository = try ProfileRepository(vault: MasterVault.create(in: root, password: "what-sites-see", iterations: 10_000))
            profile = try repository.create(name: "What sites see", configuration: ProfileConfiguration(proxy: proxy))
        } catch {
            print("WHAT-SITES-SEE could not make a profile: \(error)")
            return 1
        }
        let place = inSafariWindow ? "in Safari's window (a process of its own)" : "in this app's window (this process)"
        print("WHAT-SITES-SEE measured: a new profile \(proxy == nil ? "without a proxy" : "with an HTTP proxy"), \(place), "
              + "next to this Mac's Safari \(HostSafari.version)")
        let manager = ProfileManager(repository: repository)
        var hostsChrome: Bool?
        manager.onProfileRunning = { _, hosts in hostsChrome = hosts }
        if inSafariWindow {
            do {
                try await manager.launch(profile.id)
            } catch {
                print("WHAT-SITES-SEE the profile did not start: \(error)")
                return 1
            }
            let deadline = Date().addingTimeInterval(90)
            while hostsChrome == nil, Date() < deadline { try? await Task.sleep(nanoseconds: 200_000_000) }
            guard hostsChrome == true else {
                print("WHAT-SITES-SEE the profile's window is not Safari's (\(hostsChrome == nil ? "no answer in 90 s" : "this app's own window")): "
                      + "nothing of Safari's window to measure")
                try? await manager.stop(profile.id)
                return 1
            }
        }
        let snapshot = WhatSitesSee(profileID: profile.id, manager: { manager }, launch: { id in
            do { try await manager.launch(id) } catch { print("INFO the profile's launch failed: \(error)") }
        })
        await snapshot.take()
        guard snapshot.step == .done else {
            print("WHAT-SITES-SEE the profile's side was not taken: \(snapshot.step)")
            try? await manager.stop(profile.id)
            return 1
        }
        // First, with the categories after it: what CI turns into notices on the job.
        let count = snapshot.signals.first { $0.key == "probe.windowOwnCount" }
        print("WHAT-SITES-SEE the window's own properties: profile \(count?.profile ?? "-"), Safari \(count?.safari ?? "-")")
        for category in SiteSignalCategory.allCases {
            let signals = snapshot.signals.filter { $0.category == category }
            print("WHAT-SITES-SEE \(category.rawValue): \(WhatSitesSeeView.summary(signals))")
            for signal in signals where signal.verdict != .same {
                print("  \(signal.verdict) \(signal.key): profile=\(String((signal.profile ?? "-").prefix(160))) safari=\(String((signal.safari ?? "-").prefix(160)))")
            }
        }
        let differing = snapshot.signals.filter { $0.verdict != .same && $0.verdict != .perWindow }.map(\.key)
        print("WHAT-SITES-SEE differing: \(differing.isEmpty ? "none" : differing.joined(separator: " "))")
        try? await manager.stop(profile.id)
        print("WHAT-SITES-SEE compared with this Mac's Safari: \(snapshot.comparedWithSafari)")
        return snapshot.comparedWithSafari ? 0 : 2
    }

    private func appSettings(_ repository: ProfileRepository) async throws {
        defer { BrowsingPreferences.current = BrowsingPreferences() }
        let suite = "pb-selftest-settings-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            check("settings: a defaults suite of the self-test's own", false)
            return
        }
        defer { defaults.removePersistentDomain(forName: suite) }
        let fresh = AppSettings(defaults: defaults)
        let defaultStart: Bool = fresh.startup == AppSettings.Startup.profilesWindow
        let defaultFailure: Bool = fresh.proxyFailure == AppSettings.ProxyFailure.launchAndExplain
        let defaultBrowsing: Bool = fresh.browsing == BrowsingPreferences()
        let defaultSearch: Bool = fresh.newProfileSearchEngine == SearchEngine.standard
        let defaultWindow: Bool = fresh.newProfileRandomWindowSize && fresh.newProfileBlocksLocalRequests
        check("settings: the defaults — the Profiles window after unlocking, quitting asks, new profiles follow the connection, search with the standard engine, get a random window size and block local requests, a failing proxy's profile starts and says why, AutoFill on, new tabs next to the current one, closing several tabs asks, 100 %, the Downloads folder, two letters, no tabs restored",
              defaultStart && fresh.confirmQuit && fresh.newProfileMatchesConnection && defaultSearch && defaultWindow
                && defaultFailure && defaultBrowsing,
              String(describing: fresh.browsing))
        fresh.startup = .reopenProfiles
        fresh.confirmQuit = false
        fresh.newProfileMatchesConnection = false
        fresh.newProfileSearchEngine = .ecosia
        fresh.newProfileRandomWindowSize = false
        fresh.newProfileBlocksLocalRequests = false
        fresh.proxyFailure = .doNotLaunch
        fresh.browsing.passwordAutoFill = false
        fresh.browsing.newTabsNextToCurrent = false
        fresh.browsing.warnClosingTabs = false
        fresh.browsing.pageZoom = 1.25
        fresh.browsing.askWhereToSave = true
        fresh.browsing.dockInitials = 3
        let reread = AppSettings(defaults: defaults)
        var expected = BrowsingPreferences()
        expected.passwordAutoFill = false
        expected.newTabsNextToCurrent = false
        expected.warnClosingTabs = false
        expected.pageZoom = 1.25
        expected.askWhereToSave = true
        expected.dockInitials = 3
        let rereadStart: Bool = reread.startup == AppSettings.Startup.reopenProfiles
        let rereadFailure: Bool = reread.proxyFailure == AppSettings.ProxyFailure.doNotLaunch
        let rereadBrowsing: Bool = reread.browsing == expected
        let rereadSearch: Bool = reread.newProfileSearchEngine == SearchEngine.ecosia
        let rereadWindow: Bool = !reread.newProfileRandomWindowSize && !reread.newProfileBlocksLocalRequests
        check("settings: every setting is read back as it was set, each from its own key",
              rereadStart && !reread.confirmQuit && !reread.newProfileMatchesConnection && rereadSearch && rereadWindow
                && rereadFailure && rereadBrowsing,
              String(describing: reread.browsing))
        defaults.set(3.7, forKey: "PBSettingsPageZoom")
        defaults.set(9, forKey: "PBSettingsDockInitials")
        defaults.set("sideways", forKey: "PBSettingsStartup")
        defaults.set("someEngine", forKey: "PBSettingsNewProfileSearchEngine")
        let odd = AppSettings(defaults: defaults)
        let oddZoom: Bool = odd.browsing.pageZoom == 1
        let oddLetters: Bool = odd.browsing.dockInitials == 2
        let oddStart: Bool = odd.startup == AppSettings.Startup.profilesWindow
        let oddSearch: Bool = odd.newProfileSearchEngine == SearchEngine.standard
        check("settings: what is out of range — a zoom of 370 %, nine letters, an unknown start, an unknown search engine — is read as the default",
              oddZoom && oddLetters && oddStart && oddSearch,
              "zoom \(odd.browsing.pageZoom), letters \(odd.browsing.dockInitials), start \(odd.startup.rawValue), search \(odd.newProfileSearchEngine.rawValue)")

        // A profile's search engine through the editor: one chosen is kept; the standard one is
        // stored as none, as profiles from before the choice have it, so saving such a profile
        // unchanged is no edit.
        let bingDraft = ProfileDraft(name: "Bing", configuration: ProfileConfiguration(searchEngine: .bing))
        let plainDraft = ProfileDraft(name: "Plain", configuration: ProfileConfiguration())
        let bingSaved: SearchEngine? = try bingDraft.makeConfiguration().searchEngine
        let plainSaved: SearchEngine? = try plainDraft.makeConfiguration().searchEngine
        let plainShown: Bool = plainDraft.searchEngine == SearchEngine.standard
        check("settings: the editor keeps a profile's search engine, and stores the standard one as none",
              bingSaved == SearchEngine.bing && plainSaved == nil && plainShown,
              "kept \(bingSaved?.rawValue ?? "none"), standard stored as \(plainSaved?.rawValue ?? "none")")

        // A quit that asks: "no" stops nothing and quits nothing; "yes" seals, then quits.
        var sealRounds = 0
        var terminated = 0
        var answers = [false, true]
        let coordinator = QuitCoordinator(hasActivity: { sealRounds == 0 }, lockForQuit: { sealRounds += 1 },
                                          terminate: { terminated += 1 },
                                          confirm: { answers.isEmpty ? true : answers.removeFirst() })
        let declined = coordinator.shouldTerminate(NSApp)
        _ = await waitUntil(timeout: 2) { answers.count == 1 }
        try? await Task.sleep(nanoseconds: 200_000_000)
        let declinedReply: Bool = declined == NSApplication.TerminateReply.terminateCancel
        check("settings: a quit while profiles run asks first, and \"no\" stops nothing and quits nothing",
              declinedReply && answers.count == 1 && sealRounds == 0 && terminated == 0,
              "seal rounds \(sealRounds), terminate \(terminated)")
        let accepted = coordinator.shouldTerminate(NSApp)
        let quit = await waitUntil(timeout: 5) { terminated == 1 }
        let acceptedReply: Bool = accepted == NSApplication.TerminateReply.terminateCancel
        check("settings: \"yes\" stops and encrypts every profile, then quits",
              acceptedReply && quit && sealRounds == 1, "seal rounds \(sealRounds), terminate \(terminated)")

        // In a browser window of a profile (never shown).
        let profile = try repository.create(name: "Settings", configuration: ProfileConfiguration(ephemeral: true, searchEngine: .bing))
        let key = try repository.profileKey(for: profile.id)
        let session = try makeSession(repository, profile.id, key: key)
        defer {
            session.shutDown()
            try? repository.delete(profile.id)
        }
        BrowsingPreferences.current = BrowsingPreferences()
        let controller = BrowserWindowController(session: session)
        defer { controller.close() }
        let searched: String = controller.addressURL("cats & dogs")?.absoluteString ?? ""
        let opened: String = controller.addressURL("example.com")?.absoluteString ?? ""
        check("settings: the address bar of a profile's window searches with the profile's engine, and opens an address as it is",
              searched == "https://www.bing.com/search?q=cats%20%26%20dogs" && opened == "https://example.com",
              "\(searched), \(opened)")
        let first = controller.addTab(url: nil)
        _ = controller.addTab(url: nil)
        controller.selectTab(at: 0)
        let nextTo = controller.addTab(url: nil)
        BrowsingPreferences.current.newTabsNextToCurrent = false
        controller.selectTab(at: 0)
        let atEnd = controller.addTab(url: nil)
        let nextToIndex: Int = controller.tabs.firstIndex(where: { $0 === nextTo }) ?? -1
        let atEndIndex: Int = controller.tabs.firstIndex(where: { $0 === atEnd }) ?? -1
        let lastIndex: Int = controller.tabs.count - 1
        check("settings: a new tab opens next to the current one, or — set so — after the last",
              nextToIndex == 1 && atEndIndex == lastIndex,
              "next to: \(nextToIndex), at the end: \(atEndIndex) of \(controller.tabs.count)")
        BrowsingPreferences.current.pageZoom = 1.25
        let zoomed = controller.addTab(url: nil)
        let newZoom: CGFloat = zoomed?.webView.pageZoom ?? 0
        let earlierZoom: CGFloat = first?.webView.pageZoom ?? 0
        check("settings: a new tab's pages open at the zoom the settings give",
              newZoom == 1.25 && earlierZoom == 1, "new \(newZoom), earlier \(earlierZoom)")
        // What a page sees of a zoom (said, not checked: it is WebKit's, as in Safari).
        if let plain = first?.webView, let big = zoomed?.webView {
            plain.loadHTMLString("<!doctype html><title>100</title>", baseURL: nil)
            big.loadHTMLString("<!doctype html><title>125</title>", baseURL: nil)
            _ = await waitUntil(timeout: 10) { plain.title == "100" && big.title == "125" }
            let at100 = try? await js(plain, "return [window.devicePixelRatio, window.innerWidth]")
            let at125 = try? await js(big, "return [window.devicePixelRatio, window.innerWidth]")
            info("settings: what a page sees at 100 % and at 125 % (devicePixelRatio, innerWidth): \(String(describing: at100)) → \(String(describing: at125))")
        }

        var asked: [Int] = []
        let previousAsk = BrowserWindowController.askToCloseTabs
        BrowserWindowController.askToCloseTabs = { _, count, answer in
            asked.append(count)
            answer(false)
        }
        defer { BrowserWindowController.askToCloseTabs = previousAsk }
        if let window = controller.window {
            BrowsingPreferences.current.warnClosingTabs = true
            let closedAsked = controller.windowShouldClose(window)
            BrowsingPreferences.current.warnClosingTabs = false
            let closedUnasked = controller.windowShouldClose(window)
            let askedOnce: Bool = asked == [controller.tabs.count]
            check("settings: the close button of a window of several tabs asks first, and \"no\" keeps it open; set off, it closes unasked",
                  !closedAsked && askedOnce && closedUnasked, "asked \(asked)")
        } else {
            check("settings: the browser window exists", false)
        }

        let configuration = try repository.loadConfiguration(profile.id, key: key)
        let passwords = ProfilePasswordSettings(repository: repository, profileID: profile.id, profileName: profile.name,
                                                launchConfiguration: configuration)
        BrowsingPreferences.current.passwordAutoFill = false
        let offInSettings = passwords.autoFill
        BrowsingPreferences.current.passwordAutoFill = true
        let bothOn: Bool = passwords.autoFill == configuration.passwordAutoFill
        check("settings: AutoFill works only while both the app's switch and the profile's are on", !offInSettings && bothOn)

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pb-selftest-downloads-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var chosen = BrowsingPreferences()
        chosen.downloadFolder = folder.path
        let destination = BrowserTab.uniqueDownloadURL(suggestedFilename: "../report:1.pdf", in: chosen.downloadFolderURL)
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let inFolder: Bool = destination.deletingLastPathComponent().standardizedFileURL.path == folder.standardizedFileURL.path
        let safeName: Bool = destination.lastPathComponent == "_report_1.pdf"
        let toProcess: Bool = BrowsingPreferences().forProfileProcess.downloadFolder == downloads.path
        check("settings: a download goes to the folder chosen, under a name that cannot leave it; a profile's own process is told the Downloads folder by path",
              inFolder && safeName && toProcess, destination.path)

        let twoLetters: Bool = DockIcon.letters(2, of: "North wind") == "No"
        let shortName: Bool = DockIcon.letters(3, of: "AB") == "AB"
        let noLetters: Bool = DockIcon.image(initials: 0, of: "North wind") == nil
        let withLetters: Bool = DockIcon.image(initials: 2, of: "North wind") != nil
        check("settings: a profile's Dock icon shows the first letters of its name, and none means the app's icon",
              twoLetters && shortName && noLetters && withLetters)

        let a = UUID(), b = UUID(), c = UUID(), d = UUID(), gone = UUID()
        var activity: [(id: UUID, activity: ProfileManager.Activity)] = []
        activity.append((id: a, activity: ProfileManager.Activity.window(ownProcess: false)))
        activity.append((id: b, activity: ProfileManager.Activity.warmUpOnly))
        activity.append((id: c, activity: ProfileManager.Activity.busy))
        activity.append((id: d, activity: ProfileManager.Activity.window(ownProcess: true)))
        let recorded: [UUID] = StartupReopen.toRecord(activity)
        let launched: [UUID] = StartupReopen.toLaunch(recorded: [a, gone, a, d], existing: [d, a])
        let expectedIDs: [UUID] = [a, d]
        check("settings: a quit keeps to reopen the profiles with a window, not one warming up or starting; an unlock starts those that still exist, each once",
              recorded == expectedIDs && launched == expectedIDs)

        var sent = BrowsingPreferences()
        sent.pageZoom = 1.5
        sent.dockInitials = 1
        let line = ProfileChannel.encode(ProfileCommand.preferences(sent)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        let received = ProfileChannel.decode(ProfileCommand.self, from: line.trimmingCharacters(in: .newlines))
        var receivedRight = false
        if case .preferences(let preferences)? = received { receivedRight = preferences == sent }
        check("settings: a profile's own process gets the settings over its channel as they were sent", receivedRight, line)
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
        let isKey = await waitUntil(timeout: 3) { window.isKeyWindow }
        let webView = tab.webView
        info("password AutoFill world: \(PasswordAutoFill.worldKind); app active: \(NSApp.isActive); key window: \(isKey)")

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

        // Frames: one of another site is offered none of the page's logins; one of the same site is
        // offered them under a header naming its host. The frame's origin is WebKit's.
        TabPasswordAutoFill.testFocusLog = []
        _ = await open("http://login.selftest.invalid/pb-frame?src=http://evil.othertest.invalid/pb-login%3Fpbtestfocus%3D1")
        let crossSiteAsked = await waitUntil(timeout: 8) { TabPasswordAutoFill.testFocusLog.contains { $0.hasPrefix("evil.othertest.invalid:") } }
        check("passwords: a login field in a frame of another site is offered none of the page's logins",
              crossSiteAsked && TabPasswordAutoFill.testFocusLog.contains("evil.othertest.invalid:0") && AutoFillPanel.current == nil,
              "\(TabPasswordAutoFill.testFocusLog)")
        _ = await open("http://login.selftest.invalid/pb-frame?src=http://www.selftest.invalid/pb-login%3Fpbtestfocus%3D1")
        let sameSiteListed = await waitUntil(timeout: 8) { AutoFillPanel.current != nil }
        check("passwords: a frame of the same site is offered its logins, under a header naming the frame's host",
              sameSiteListed && AutoFillPanel.current?.titles == ["ann"] && AutoFillPanel.current?.header?.contains("www.selftest.invalid") == true,
              "\(TabPasswordAutoFill.testFocusLog) \(AutoFillPanel.current?.titles ?? []) \(AutoFillPanel.current?.header ?? "nil")")
        AutoFillPanel.current?.dismiss()
    }

    // MARK: Cookie import

    /// Cookie import end to end, through the self-test proxy's `/pb-cookies` (which shows the
    /// request's Cookie header): a damaged Netscape file is read — every readable cookie, every
    /// other line reported with its reason —; into a stopped profile the cookies are queued,
    /// encrypted, and put into its store at launch before the first page loads (the start page's
    /// request carries them, HttpOnly ones too, a Secure one or another path's not over http);
    /// a cut-off JSON export's complete entries go into the running profile at once; persistent
    /// imported cookies survive a stop (sealed) and a launch, the session cookie does not.
    private func cookieImport(_ repository: ProfileRepository) async throws {
        guard let httpPort = ProcessInfo.processInfo.environment["PB_SELFTEST_HTTP_PROXY_PORT"].flatMap(Int.init) else {
            info("cookie import checks skipped (PB_SELFTEST_HTTP_PROXY_PORT not set)")
            return
        }
        let start = URL(string: "http://cookies.selftest.invalid/pb-cookies")!
        let profile = try repository.create(name: "Cookie import", configuration: ProfileConfiguration(
            startURL: start, proxy: ProxySettings(kind: .httpConnect, host: "127.0.0.1", port: httpPort), matchProxyLocation: false))
        let manager = ProfileManager(repository: repository)
        var messages: [String] = []
        manager.onError = { messages.append($0) }
        let future = Int(Date().timeIntervalSince1970) + 30 * 86_400

        // A Netscape file with CRLF, comments, an HttpOnly line and four lines that cannot be imported.
        var file = Data([
            "# Netscape HTTP Cookie File",
            "cookies.selftest.invalid\tFALSE\t/\tFALSE\t\(future)\thostonly\timported-hostonly-value",
            "#HttpOnly_.selftest.invalid\tTRUE\t/\tFALSE\t\(future)\thttponly\timported-httponly-value",
            "cookies.selftest.invalid\tFALSE\t/\tFALSE\t0\tsession\timported-session-value",
            ".selftest.invalid\tTRUE\t/\tTRUE\t\(future)\tsecureonly\timported-secure-value",
            "cookies.selftest.invalid\tFALSE\t/elsewhere\tFALSE\t\(future)\tpathonly\timported-path-value",
            "broken\tline",
            ".com\tTRUE\t/\tFALSE\t\(future)\tsuffix\tv",
            "cookies.selftest.invalid\tFALSE\t/\tFALSE\t1600000000\texpired\tv",
            "cookies.selftest.invalid\tFALSE\t/\tFALSE\t\(future)\tdamaged\tv",
        ].joined(separator: "\r\n").utf8)
        file += Data([0xC3, 0x28]) + Data("\r\n".utf8)
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("pb-cookies-\(UUID().uuidString).txt")
        try file.write(to: path)
        defer { try? FileManager.default.removeItem(at: path) }
        let report = CookieImporter.read(contentsOf: path)
        let problems = report.problems.map { "\($0.location) \($0.reason)" }
        check("cookie import: a damaged Netscape file — every readable cookie is read, every other line reported with its reason",
              report.format == .netscape && report.cookies.map(\.name) == ["hostonly", "httponly", "session", "secureonly", "pathonly"]
                  && report.problems.map(\.location) == [.line(7), .line(8), .line(9), .line(10)]
                  && report.problems.map(\.reason).first == .wrongFieldCount(2)
                  && report.problems.map(\.reason).last == .damagedText,
              "\(report.cookies.map(\.name)) \(problems)")

        // Stopped: queued, encrypted, for the next launch.
        let queued = try await manager.importCookies(report.cookies, into: profile.id)
        let queueFile = repository.directory(for: profile.id).appendingPathComponent("cookies-import.bin")
        let onDisk = (try? Data(contentsOf: queueFile)) ?? Data()
        check("cookie import: into a stopped profile the cookies are queued, encrypted, for its next launch",
              queued == .queued(5) && !onDisk.isEmpty && onDisk.range(of: Data("imported-httponly-value".utf8)) == nil,
              "\(queued) \(onDisk.count) bytes")

        // Launch: in the store before the start page is requested.
        func pageText() async -> String {
            guard let tab = manager.session(for: profile.id)?.windowControllers.first?.selectedTab else { return "" }
            _ = await waitUntil(timeout: 15) { !tab.isLoading && tab.url == start }
            return (try? await js(tab.webView, "return document.body ? document.body.innerText : '';")) as? String ?? ""
        }
        try await manager.launch(profile.id)
        let first = await pageText()
        check("cookie import: at launch, before the first page loads: its request carries them (HttpOnly too), not a Secure one or another path's over http",
              first.contains("hostonly=imported-hostonly-value") && first.contains("httponly=imported-httponly-value")
                  && first.contains("session=imported-session-value") && !first.contains("secureonly") && !first.contains("pathonly"),
              first)
        // Read in its own scope: a reference to the store held past this point would keep WebKit
        // from releasing it, and the stop below could not seal it.
        var stored: [HTTPCookie] = []
        if let store = manager.session(for: profile.id)?.dataStore { stored = await cookies(in: store) }
        let byName = Dictionary(stored.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        check("cookie import: the store holds them as the file said (host-only, domain, HttpOnly, Secure, session, path), and the queue is gone",
              byName["hostonly"]?.domain == "cookies.selftest.invalid" && byName["httponly"]?.domain == ".selftest.invalid"
                  && byName["httponly"]?.isHTTPOnly == true && byName["secureonly"]?.isSecure == true
                  && byName["session"]?.isSessionOnly == true && byName["pathonly"]?.path == "/elsewhere"
                  && !FileManager.default.fileExists(atPath: queueFile.path) && messages.isEmpty,
              "\(stored.map { "\($0.name)@\($0.domain)\($0.path) httpOnly=\($0.isHTTPOnly) secure=\($0.isSecure) session=\($0.isSessionOnly)" }) \(messages)")

        // Running: a cut-off JSON export, at once.
        let json = """
        [
          {"name": "live", "value": "imported-live-value", "domain": "cookies.selftest.invalid", "hostOnly": true,
           "path": "/", "expirationDate": \(future), "sameSite": "lax", "httpOnly": false, "secure": false},
          {"name": "cut", "value": "x", "dom
        """
        let jsonReport = CookieImporter.read(Data(json.utf8))
        let live = try await manager.importCookies(jsonReport.cookies, into: profile.id)
        manager.session(for: profile.id)?.windowControllers.first?.selectedTab?.webView.reload()
        try? await Task.sleep(nanoseconds: 300_000_000)
        let second = await pageText()
        check("cookie import: a cut-off JSON export's complete entries go into the running profile at once",
              jsonReport.cookies.map(\.name) == ["live"] && jsonReport.problems.contains { $0.reason == .cutOff }
                  && live == .applied(stored: 1, refused: []) && second.contains("live=imported-live-value"),
              "\(live) \(second)")

        info("cookie import: WebKit can write cookies to disk on request: \(CookieStoreImport.canFlush)")
        // Exported from the running profile: the file holds what the store holds, the session
        // cookie included, and this app's own import reads it back.
        let exported = (try? await manager.exportCookies(of: profile.id)) ?? []
        let exportedFile = CookieExport.data(exported, format: .netscape)
        let readBack = CookieImporter.read(exportedFile).cookies
        check("cookie export: a running profile's cookies, session ones too, in a cookies.txt this app reads back",
              exported.contains { $0.name == "live" && $0.value == "imported-live-value" }
                  && exported.contains { $0.name == "session" && $0.expires == nil }
                  && readBack.count == CookieExport.count(exported, format: .netscape) && !readBack.isEmpty,
              exported.map { "\($0.name)=\($0.value)" }.joined(separator: " "))
        // Stop (sealed) and launch: persistent imported cookies kept, the session cookie gone.
        // WebKit lets go of a stopped profile's store: one still alive is handed back at the next
        // launch (`WKWebsiteDataStore(forIdentifier:)`), session cookies and all.
        weak var storeBeforeStop = manager.session(for: profile.id)?.dataStore
        try await manager.stop(profile.id)
        let storeReleased = await waitUntil(timeout: 10) { storeBeforeStop == nil }
        check("cookie import: WebKit lets go of a stopped profile's data store", storeReleased, "still alive 10 s after the stop")
        // Exported while stopped: started without a window, read, and stopped again.
        let fromStopped = (try? await manager.exportCookies(of: profile.id)) ?? []
        let stoppedAgain = await waitUntil(timeout: 30) { !manager.isRunning(profile.id) && !manager.busyProfileIDs.contains(profile.id) }
        check("cookie export: a stopped profile's cookies are read and the profile is stopped again",
              fromStopped.contains { $0.name == "live" } && !fromStopped.contains { $0.name == "session" } && stoppedAgain,
              "\(fromStopped.map(\.name)) running=\(manager.isRunning(profile.id))")
        try await manager.launch(profile.id)
        let third = await pageText()
        check("cookie import: imported persistent cookies survive a stop and a launch; the session cookie does not",
              third.contains("hostonly=imported-hostonly-value") && third.contains("live=imported-live-value")
                  && !third.contains("session="), third)
        try await manager.delete(profile.id)
    }

    // MARK: Session cookies after a stop

    /// A stopped profile's session cookie does not come back at its next launch — with no other
    /// profile running, and while another profile of this process keeps running. In this app's
    /// windows every profile shares WebKit's one network process, and while it runs it handed the
    /// session cookies back (CI run 436, macOS 27: "still there" with another profile running,
    /// "gone" without); a stop now deletes them (`ProfileManager.stop`).
    private func sessionCookieAfterStop(_ repository: ProfileRepository) async throws {
        let manager = ProfileManager(repository: repository)
        let cookies = CookieImporter.read(Data("session.selftest.invalid\tFALSE\t/\tFALSE\t0\tpbsession\tsession-value".utf8)).cookies
        for withAnother in [false, true] {
            let measured = try repository.create(name: "Session cookie", configuration: ProfileConfiguration())
            var other: ProfileSummary?
            if withAnother { other = try repository.create(name: "Keeps running", configuration: ProfileConfiguration()) }
            try await manager.launch(measured.id, openingWindow: false)
            if let other { try await manager.launch(other.id, openingWindow: false) }
            let imported = try await manager.importCookies(cookies, into: measured.id)
            weak var store = manager.session(for: measured.id)?.dataStore
            try await manager.stop(measured.id)
            let released = await waitUntil(timeout: 10) { store == nil }
            try await manager.launch(measured.id, openingWindow: false)
            let after = (try? await manager.exportCookies(of: measured.id)) ?? []
            let kept = after.contains { $0.name == "pbsession" }
            let situation = withAnother ? "while another profile keeps running" : "with no other profile running"
            check("cookies: a stopped profile's session cookie does not come back at its next launch, \(situation)",
                  imported == .applied(stored: 1, refused: []) && !kept,
                  "import \(imported); the store \(released ? "let go" : "still alive 10 s after the stop"); "
                      + "after the launch \(after.map(\.name))")
            try await manager.delete(measured.id)
            if let other { try await manager.delete(other.id) }
        }
    }

    // MARK: Profile export and import

    /// A profile carried in a `.pbprofile` file arrives with its website data: a cookie the
    /// original had in its (sealed) WebKit store is sent by the imported profile's first request.
    /// That is what proves the website data was restored where WebKit looks for the new profile's
    /// store — the archive's directories are renamed after the new profile on the way.
    private func profileTransfer(_ repository: ProfileRepository) async throws {
        guard let httpPort = ProcessInfo.processInfo.environment["PB_SELFTEST_HTTP_PROXY_PORT"].flatMap(Int.init) else {
            info("profile transfer checks skipped (PB_SELFTEST_HTTP_PROXY_PORT not set)")
            return
        }
        let start = URL(string: "http://transfer.selftest.invalid/pb-cookies")!
        let original = try repository.create(name: "Carried", configuration: ProfileConfiguration(
            startURL: start, proxy: ProxySettings(kind: .httpConnect, host: "127.0.0.1", port: httpPort), matchProxyLocation: false))
        let manager = ProfileManager(repository: repository)
        var messages: [String] = []
        manager.onError = { messages.append($0) }
        func pageText(_ id: UUID) async -> String {
            guard let tab = manager.session(for: id)?.windowControllers.first?.selectedTab else { return "" }
            _ = await waitUntil(timeout: 15) { !tab.isLoading && tab.url == start }
            return (try? await js(tab.webView, "return document.body ? document.body.innerText : '';")) as? String ?? ""
        }
        // Into the original's WebKit store (queued, applied at launch), then sealed with it at stop.
        let cookie = ImportedCookie(name: "carried", value: "carried-value", domain: "transfer.selftest.invalid", hostOnly: true,
                                    expires: Date().addingTimeInterval(30 * 86_400))
        _ = try await manager.importCookies([cookie], into: original.id)
        try await manager.launch(original.id)
        let before = await pageText(original.id)
        try await manager.stop(original.id)
        check("profile transfer: the original profile has the cookie", before.contains("carried=carried-value"), before)

        let file = FileManager.default.temporaryDirectory.appendingPathComponent("pb-transfer-\(UUID().uuidString).\(ProfileTransfer.fileExtension)")
        defer { try? FileManager.default.removeItem(at: file) }
        let manifest = try ProfileTransfer.export(original.id, from: repository, to: file, password: "transfer pw",
                                                  kdf: .generate(iterations: 10_000))
        let bytes = (try? Data(contentsOf: file)) ?? Data()
        check("profile transfer: the export carries the website data, and nothing of it is readable in the file",
              manifest.hasWebsiteData && !bytes.isEmpty && bytes.range(of: Data("carried-value".utf8)) == nil
                && bytes.range(of: Data("Carried".utf8)) == nil, "\(manifest.hasWebsiteData) \(bytes.count) bytes")
        check("profile transfer: a wrong password opens nothing",
              (try? ProfileTransfer.manifest(of: file, password: "wrong")) == nil)

        let imported = try ProfileTransfer.importProfile(from: file, password: "transfer pw", into: repository, name: "Carried (imported)")
        try await manager.launch(imported.id)
        let after = await pageText(imported.id)
        check("profile transfer: the imported profile — a new profile — sends the original's cookie from its first request",
              imported.id != original.id && after.contains("carried=carried-value"), after)
        try await manager.stop(imported.id)
        check("profile transfer: nothing went wrong", messages.isEmpty, messages.joined(separator: " | "))
        try await manager.delete(imported.id)
        try await manager.delete(original.id)
    }

    // MARK: Profile sync (cookies and settings between two devices)

    /// Two devices, one after the other, through a sync folder: device B is a vault bootstrapped
    /// from this one (same master password) in a folder of its own, with its own ProfileManager.
    /// Cookies of A (one imported while the profile was stopped, one a page set) reach B's store
    /// before its first page loads; B's change and deletion come back to A the same way; the
    /// settings changed on both devices end as the newer ones, the older kept as a conflict copy.
    private func profileSync(_ repository: ProfileRepository) async throws {
        guard let httpPort = ProcessInfo.processInfo.environment["PB_SELFTEST_HTTP_PROXY_PORT"].flatMap(Int.init) else {
            info("profile sync checks skipped (PB_SELFTEST_HTTP_PROXY_PORT not set)")
            return
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pb-selftest-sync-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let server = folder.appendingPathComponent("server")
        let transport = LocalDirectorySyncTransport(directory: server)
        let start = URL(string: "http://sync.selftest.invalid/pb-cookies")!
        let profile = try repository.create(name: "Cookie sync", configuration: ProfileConfiguration(
            startURL: start, proxy: ProxySettings(kind: .httpConnect, host: "127.0.0.1", port: httpPort), matchProxyLocation: false))
        let configName = "profile/\(profile.id.uuidString)/config"
        var messages: [String] = []
        let managerA = ProfileManager(repository: repository)
        managerA.onError = { messages.append($0) }

        func pageText(_ manager: ProfileManager) async -> String {
            guard let tab = manager.session(for: profile.id)?.windowControllers.first?.selectedTab else { return "" }
            _ = await waitUntil(timeout: 15) { !tab.isLoading && tab.url == start }
            return (try? await js(tab.webView, "return document.body ? document.body.innerText : '';")) as? String ?? ""
        }
        func setCookies(_ manager: ProfileManager, _ cookies: [String]) async {
            guard let webView = manager.session(for: profile.id)?.windowControllers.first?.selectedTab?.webView else { return }
            _ = try? await js(webView, "for (const c of cookies) document.cookie = c; return document.cookie;", ["cookies": cookies])
        }
        func names(_ jar: CookieJarDocument) -> [String] { jar.cookies.map { "\($0.cookie.name)=\($0.cookie.value)" }.sorted() }

        // Device A. Stopped: an imported cookie waits for the launch; then a page sets a
        // persistent cookie and a session one.
        let future = Date().addingTimeInterval(30 * 86_400)
        _ = try await managerA.importCookies([ImportedCookie(name: "queued", value: "from-a-import", domain: "sync.selftest.invalid",
                                                             hostOnly: true, expires: future)], into: profile.id)
        try await managerA.launch(profile.id)
        let firstA = await pageText(managerA)
        let atLaunch = try repository.cookieJar(for: profile.id)
        check("profile sync: a cookie imported while the profile was stopped goes into the synced cookies at its launch",
              firstA.contains("queued=from-a-import") && names(atLaunch) == ["queued=from-a-import"], "\(firstA) \(names(atLaunch))")
        await setCookies(managerA, ["page=from-a-page; max-age=2592000; path=/", "session=a-session; path=/"])
        try await managerA.stop(profile.id)
        let recorded = try repository.cookieJar(for: profile.id)
        check("profile sync: at stop the run's persistent cookies are recorded for sync, its session cookies not",
              names(recorded) == ["page=from-a-page", "queued=from-a-import"], "\(names(recorded))")
        let pushed = try await SyncEngine(repository: repository, transport: transport).sync()
        var visible: [String] = []
        for file in (try? FileManager.default.contentsOfDirectory(atPath: server.path)) ?? [] {
            let blob = (try? Data(contentsOf: server.appendingPathComponent(file))) ?? Data()
            visible += ["from-a-page", "from-a-import", "sync.selftest.invalid"].filter { blob.range(of: Data($0.utf8)) != nil }
        }
        check("profile sync: the cookies are uploaded encrypted (no name, value or domain readable in the sync folder)",
              pushed.pushed.contains("profile/\(profile.id.uuidString)/cookies") && visible.isEmpty, "\(pushed.pushed) \(visible)")

        // Device B: set up from the sync folder, its first launch of the profile.
        let repoB = try ProfileRepository(vault: await SyncEngine.bootstrap(transport: transport, root: folder.appendingPathComponent("B"),
                                                                            password: "self-test"))
        _ = try await SyncEngine(repository: repoB, transport: transport).sync()
        let managerB = ProfileManager(repository: repoB)
        managerB.onError = { messages.append($0) }
        try await managerB.launch(profile.id)
        let firstB = await pageText(managerB)
        check("profile sync: on the other device the synced cookies are in the store before its first page loads (not the session cookie)",
              firstB.contains("queued=from-a-import") && firstB.contains("page=from-a-page") && !firstB.contains("session="), firstB)
        await setCookies(managerB, ["page=from-b-page; max-age=2592000; path=/", "queued=; max-age=0; path=/"])
        try await managerB.stop(profile.id)
        _ = try await SyncEngine(repository: repoB, transport: transport).sync()

        // Back on A: B's change and deletion, before the first page.
        _ = try await SyncEngine(repository: repository, transport: transport).sync()
        try await managerA.launch(profile.id)
        let secondA = await pageText(managerA)
        check("profile sync: a change and a deletion made on the other device reach the store before the first page loads",
              secondA.contains("page=from-b-page") && !secondA.contains("queued="), secondA)
        try await managerA.stop(profile.id)

        // Settings changed on both devices, B's later: B's win on both, A's kept as a copy.
        let now = Date()
        for (repo, zone, time) in [(repository, "Europe/Paris", now - 60), (repoB, "Asia/Tokyo", now)] {
            let stored = try repo.loadConfiguration(profile.id)
            var edited = stored
            edited.timeZoneIdentifier = zone
            try repo.saveConfiguration(edited.savingEdit(over: stored, at: time), for: profile.id)
        }
        _ = try await SyncEngine(repository: repository, transport: transport).sync()
        let conflict = try await SyncEngine(repository: repoB, transport: transport).sync()
        _ = try await SyncEngine(repository: repository, transport: transport).sync()
        let copy = repoB.directory(for: profile.id).appendingPathComponent("config.bin.conflict")
        let zones = [try repository.loadConfiguration(profile.id).timeZoneIdentifier, try repoB.loadConfiguration(profile.id).timeZoneIdentifier]
        check("profile sync: settings changed on two devices — the newer win on both, the older kept as a conflict copy",
              zones == ["Asia/Tokyo", "Asia/Tokyo"] && conflict.resolvedConflicts == [configName]
                  && FileManager.default.fileExists(atPath: copy.path),
              "\(zones) \(conflict.resolvedConflicts)")
        check("profile sync: no errors reported", messages.isEmpty, "\(messages)")
        try await managerA.delete(profile.id)
    }

    // MARK: Session warm-up robot

    /// The robot of a profile behind the self-test proxy, through the app's own launch path, with
    /// short waits: it visits the plan's pages in order in a tab of the profile (its proxy,
    /// cookies, User-Agent), stays on each, scrolls, follows only the plain link of the same site,
    /// leaves nothing in the page world, and stops when asked, when its tab closes, when a page
    /// shows a dialog and when the profile stops (whose data then seals as usual).
    private func warmUp(_ repository: ProfileRepository) async throws {
        guard let httpPort = ProcessInfo.processInfo.environment["PB_SELFTEST_HTTP_PROXY_PORT"].flatMap(Int.init) else {
            info("warm-up checks skipped (PB_SELFTEST_HTTP_PROXY_PORT not set)")
            return
        }
        let run = String(UUID().uuidString.prefix(8)).lowercased()
        let base = "http://warmup.selftest.invalid/pb-warmup/"
        func page(_ name: String) -> String { "\(base)\(name)?run=\(run)" }
        let profile = try repository.create(name: "Warm-up", configuration: ProfileConfiguration(
            startURL: URL(string: page("home")), proxy: ProxySettings(kind: .httpConnect, host: "127.0.0.1", port: httpPort),
            matchProxyLocation: false))
        let manager = ProfileManager(repository: repository)
        var messages: [String] = []
        manager.onError = { messages.append($0) }
        // Real mouse and wheel events reach a web view only in a key window, which the
        // self-test's .prohibited activation policy never gives (as in the password checks).
        let policy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.accessory)
        NSApp.activate(ignoringOtherApps: true)
        defer { NSApp.setActivationPolicy(policy) }
        try await manager.launch(profile.id)
        let robot = manager.warmUpRobot(for: profile.id)
        robot.limits = .init(loadTimeout: 15, startTimeout: 8, scriptTimeout: 5, dwellOverride: 3...3.5, pauseOverride: 0.2...0.4)

        struct LogEntry: Decodable {
            var path: String
            var query: String
            var referer: String
            var cookie: String
            var userAgent: String
            var time: Double
        }
        func proxyLog() async -> [LogEntry] {
            guard let webView = manager.session(for: profile.id)?.frontmostWindow?.selectedTab?.webView,
                  let text = try? await js(webView, "return await (await fetch('/pb-warmup/log.json')).text();") as? String,
                  let entries = try? JSONDecoder().decode([LogEntry].self, from: Data(text.utf8)) else { return [] }
            return entries.filter { $0.query.contains("run=\(run)") || $0.path.hasPrefix("/pb-warmup/event/\(run)/") }
        }

        // A run: three pages, a line that is no web address, and a page the proxy closes unanswered.
        let plan = WarmUpPlan(addresses: [page("a"), "javascript:alert(1)", page("b"), page("broken"), page("c")].joined(separator: "\n"),
                              scroll: true, followLinks: true)
        let started = manager.startWarmUp(profile.id, plan: plan)
        let ended = await waitUntil(timeout: 120) { robot.state != .running }
        let visits = robot.visits
        let outcomes = visits.map { visit -> String in
            switch visit.outcome {
            case .loaded?: return "loaded"
            case .failed?: return "failed"
            case .timedOut?: return "timedOut"
            case nil: return "-"
            }
        }
        check("warm-up: the plan's pages are visited one after the other in a tab of the profile, a page that does not load reported and skipped",
              started && ended && robot.state == .finished
                  && visits.map(\.url.absoluteString) == [page("a"), page("b"), page("broken"), page("c")]
                  && outcomes == ["loaded", "loaded", "failed", "loaded"],
              "started=\(started) state=\(robot.state) \(visits.map(\.url.absoluteString)) \(outcomes) \(visits.map(\.outcome))")
        let log = await proxyLog()
        let pagesServed = log.filter { !$0.path.contains("/event/") }.map(\.path)
        let userAgent = manager.session(for: profile.id)?.frontmostWindow?.selectedTab?.webView.customUserAgent ?? "?"
        let requestB = log.first { $0.path == "/pb-warmup/b" }
        check("warm-up: the pages come through the profile's proxy with its User-Agent and the cookies the pages before set",
              pagesServed.filter { ["/pb-warmup/a", "/pb-warmup/b", "/pb-warmup/c"].contains($0) } == ["/pb-warmup/a", "/pb-warmup/b", "/pb-warmup/c"]
                  && requestB?.cookie.contains("pbwarm_a=\(run)") == true
                  && log.filter { !$0.path.contains("/event/") }.allSatisfy { $0.userAgent == userAgent },
              "\(pagesServed) cookie(b)=\(requestB?.cookie ?? "-") ua=\(userAgent)")
        let loaded = visits.filter { $0.outcome == .loaded }
        // Measured at the proxy: from a page's request to its followed link's (the plan's 3-3.5 s,
        // then reading and clicking), and from there to the next page (half of it, then the pause).
        func requested(_ name: String) -> Double? { log.first { $0.path == "/pb-warmup/\(name)" }?.time }
        func span(_ from: String, _ to: String) -> Double? { requested(to).flatMap { end in requested(from).map { end - $0 } } }
        // The robot takes a page as loaded only once its own load has come, so never before the
        // proxy was even asked for it. In the run's new tab, WebKit can drop the address the robot
        // asked for while it decides on the tab's first (blank) load; the robot's earlier test
        // (address changed, nothing loading) could take that moment for the page having come.
        let tooSoon = loaded.compactMap { visit -> String? in
            let name = visit.url.lastPathComponent
            guard let at = visit.loadedAt?.timeIntervalSince1970, let asked = requested(name) else { return "\(name): no times" }
            return at >= asked ? nil : "\(name): \(String(format: "%.3f", asked - at)) s before its request"
        }
        check("warm-up: a page counts as visited only once it has come (never before the proxy was asked for it)",
              !loaded.isEmpty && tooSoon.isEmpty, "\(tooSoon)")
        let onPage = ["a", "b", "c"].map { span($0, "\($0)-next") }
        let onFollowed = [span("a-next", "b"), span("b-next", "broken")]
        check("warm-up: it stays on each page between the plan's times, and half as long on the page of the followed link (as measured at the proxy)",
              onPage.allSatisfy { ($0 ?? 0) >= 3 && ($0 ?? 99) <= 10 } && onFollowed.allSatisfy { ($0 ?? 0) >= 1.5 },
              "on pages \(onPage) on followed pages \(onFollowed)")
        let events = Set(log.compactMap { entry -> String? in
            entry.path.hasPrefix("/pb-warmup/event/\(run)/") ? String(entry.path.dropFirst("/pb-warmup/event/\(run)/".count)) : nil
        })
        check("warm-up: it scrolls each page it stays on (the pages see trusted scroll events)",
              ["a", "b", "c"].allSatisfy { events.contains("\($0)-scroll") } && loaded.allSatisfy { $0.scrolls > 0 },
              "\(events.sorted()) scrolls=\(visits.map(\.scrolls))")
        info("warm-up: scrolled with \(robot.scrollInput?.rawValue ?? "-") input (wheel events seen: \(events.contains { $0.hasSuffix("-wheel") })), clicked with \(robot.clickInput?.rawValue ?? "-") input (trusted clicks seen: \(events.contains { $0.hasSuffix("-click") }))")
        let referers = Dictionary(log.map { ($0.path, $0.referer) }, uniquingKeysWith: { first, _ in first })
        let refused = ["/pb-warmup/logout", "/pb-warmup/partner", "/pb-warmup/file.zip", "/pb-warmup/popup"]
        check("warm-up: from each page it follows only the plain link of the same site (with the page as Referer), never sign-out, another site, a file or a new window",
              ["a", "b", "c"].allSatisfy { referers["/pb-warmup/\($0)-next"] == page($0) }
                  && !log.contains { refused.contains($0.path) }
                  && loaded.allSatisfy { $0.followed?.path == "\($0.url.path)-next" && $0.followedOutcome == .loaded },
              "\(referers.filter { $0.key.hasSuffix("-next") }) refused requested: \(log.map(\.path).filter(refused.contains))")
        // Each page reports what its own world sees (window.webkit, robot-like globals) at its first
        // scroll and, through the next page, at the click that left it: "undefined-" is nothing.
        let probes = events.filter { $0.contains("globals-") }
        check("warm-up: while it scrolls and clicks, the pages' own world shows nothing of the robot (no window.webkit, no globals)",
              ["a", "b", "c"].allSatisfy { events.contains("\($0)-globals-undefined-") && events.contains("\($0)-next-clickglobals-\($0)-undefined-") }
                  && probes.allSatisfy { $0.hasSuffix("-undefined-") },
              "\(probes.sorted())")
        let history = manager.session(for: profile.id)?.library.historyEntries(matching: "pb-warmup").map(\.url) ?? []
        var stored: [String] = []
        // Read in its own scope: a store held past this point would keep the stop below from sealing.
        if let store = manager.session(for: profile.id)?.dataStore { stored = await cookies(in: store).map(\.name) }
        check("warm-up: the profile keeps what the visits leave, as when browsing: history and the pages' cookies",
              ["a", "b", "c"].allSatisfy { name in history.contains { $0.contains("/pb-warmup/\(name)?") } }
                  && ["pbwarm_a", "pbwarm_b", "pbwarm_c", "pbwarm_a_next"].allSatisfy(stored.contains),
              "history=\(history) cookies=\(stored.sorted())")

        // An address that only jumps within the page shown (the same page with a fragment). WebKit
        // 26 makes no new page for it, so nothing commits, and the robot takes it as visited once
        // the tab shows that page instead of waiting out its load time; WebKit 27 makes a new page
        // of it for a page loaded through the proxy (`fragmentJumps`), which the robot waits for as
        // for any load. Either way the page rewrites `#part` to `#/part`, as a single-page app's
        // router might.
        let jump = WarmUpPlan(addresses: [page("f"), page("f") + "#part"].joined(separator: "\n"), scroll: false, followLinks: false)
        robot.limits.dwellOverride = 1...1
        robot.limits.pauseOverride = 0.2...0.2
        let jumpStarted = Date()
        manager.startWarmUp(profile.id, plan: jump)
        // The address the robot's own tab last showed, read while the run is on: the warm-up
        // browses in a window of its own that is closed when the run ends.
        var jumpShown: URL?
        let jumped = await waitUntil(timeout: 20) {
            if let url = robot.currentTab?.url { jumpShown = url }
            return robot.state != .running
        }
        let jumpTime = Date().timeIntervalSince(jumpStarted)
        check("warm-up: an address that only jumps within the page shown counts as visited without waiting out a load time (whether or not WebKit makes a new page of it), also when the page rewrites the fragment",
              jumped && robot.state == .finished && robot.visits.map(\.outcome) == [.loaded, .loaded] && jumpTime < 10
                  && jumpShown?.fragment == "/part",
              "state=\(robot.state) \(robot.visits.map(\.outcome)) in \(String(format: "%.1f", jumpTime)) s shown=\(jumpShown?.absoluteString ?? "nil")")

        // Stopped by the user while on a page whose next one is due within a second and a half:
        // three seconds later it still has not been asked for.
        let long = WarmUpPlan(addresses: [page("s1"), page("s2")].joined(separator: "\n"), scroll: false, followLinks: false)
        robot.limits.dwellOverride = 1...1
        robot.limits.pauseOverride = 0.3...0.3
        manager.startWarmUp(profile.id, plan: long)
        _ = await waitUntil(timeout: 20) { robot.visits.first?.outcome == .loaded }
        robot.stop()
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        let after = await proxyLog()
        check("warm-up: Stop ends the run at once; the next page is never requested",
              robot.state == .stopped(.byUser) && after.contains { $0.path == "/pb-warmup/s1" } && !after.contains { $0.path == "/pb-warmup/s2" },
              "state=\(robot.state) requested=\(after.map(\.path))")
        robot.limits.dwellOverride = 30...30

        // Its tab closed by the user.
        manager.startWarmUp(profile.id, plan: long)
        _ = await waitUntil(timeout: 20) { robot.visits.first?.outcome == .loaded }
        if let tab = robot.currentTab, let controller = manager.session(for: profile.id)?.window(of: tab),
           let index = controller.tabs.firstIndex(where: { $0 === tab }) {
            controller.closeTab(at: index)
        }
        let closed = await waitUntil(timeout: 3) { robot.state == .stopped(.tabClosed) }
        check("warm-up: closing its tab stops the run", closed, "state=\(robot.state)")

        // A page that shows a dialog: the robot stops and leaves it to the user.
        manager.startWarmUp(profile.id, plan: WarmUpPlan(addresses: page("alert"), scroll: false, followLinks: false))
        let asked = await waitUntil(timeout: 20) { robot.state == .stopped(.pageNeedsAttention) }
        check("warm-up: a page waiting for an answer to a dialog stops the run", asked, "state=\(robot.state)")
        if let controller = manager.session(for: profile.id)?.frontmostWindow,
           let index = controller.tabs.firstIndex(where: { $0.hasPendingSheet }) {
            controller.closeTab(at: index) // answers the dialog
        }

        // The profile stopped during a run: the robot is stopped first — while the session still
        // has its data store, before anything of the stop waits — and the data seals as usual.
        manager.startWarmUp(profile.id, plan: long)
        _ = await waitUntil(timeout: 20) { robot.visits.first?.outcome == .loaded }
        weak var stoppingSession = manager.session(for: profile.id)
        let stopping = Task { @MainActor in try await manager.stop(profile.id) }
        for _ in 0..<5 where robot.state == .running { await Task.yield() }
        let stoppedFirst = robot.state == .stopped(.profileStopped) && stoppingSession?.dataStore != nil
        var sealError: String?
        do { try await stopping.value } catch { sealError = String(describing: error) }
        check("warm-up: stopping the profile stops its run first (its store still there); the profile's data is sealed as usual",
              stoppedFirst && sealError == nil && !manager.isRunning(profile.id)
                  && !webKitDataDirectoriesExist(profile.id) && messages.isEmpty,
              "stoppedFirst=\(stoppedFirst) state=\(robot.state) seal=\(sealError ?? "ok") messages=\(messages)")
        try await manager.delete(profile.id)
    }

    /// Two profiles warmed up through the queue (`WarmUpCoordinator`), as "Warm Up Several…" does:
    /// each started without a window, warmed up through the self-test proxy, stopped and sealed
    /// again, and only then the next — never both at once. Each run's report counts the profile's
    /// cookies per site (registrable domain) in its own store, telling the cookies the run added
    /// from one the profile already had; and a run from the queue counts as the profile's last
    /// run for its schedule.
    private func warmUpQueue(_ repository: ProfileRepository) async throws {
        guard let httpPort = ProcessInfo.processInfo.environment["PB_SELFTEST_HTTP_PROXY_PORT"].flatMap(Int.init) else {
            info("warm-up queue checks skipped (PB_SELFTEST_HTTP_PROXY_PORT not set)")
            return
        }
        let run = String(UUID().uuidString.prefix(8)).lowercased()
        func page(_ host: String, _ name: String) -> String { "http://\(host)/pb-warmup/\(name)?run=\(run)" }
        let proxy = ProxySettings(kind: .httpConnect, host: "127.0.0.1", port: httpPort)
        let first = try repository.create(name: "Queue 1", configuration: ProfileConfiguration(proxy: proxy, matchProxyLocation: false))
        let second = try repository.create(name: "Queue 2", configuration: ProfileConfiguration(proxy: proxy, matchProxyLocation: false))
        // The second profile already holds a cookie of the site it is going to visit: the report
        // has to tell it from the one the run adds.
        try repository.queueImportedCookies([ImportedCookie(name: "pbwarm_before", value: run, domain: "warmup.selftest.invalid",
                                                            hostOnly: true, expires: Date().addingTimeInterval(86_400))],
                                            for: second.id)
        // The first repeats on a schedule (not due for a day): its run from the queue counts.
        let queued = Date()
        try repository.saveWarmUpSchedule(WarmUpSchedule(everyHours: 24, since: queued), for: first.id)
        let manager = ProfileManager(repository: repository)
        var messages: [String] = []
        manager.onError = { messages.append($0) }
        // As AppModel.startWarmUp: a stopped profile is launched without a window for its run.
        let coordinator = WarmUpCoordinator(manager: manager, repository: repository) { plan, id in
            if !manager.isRunning(id) {
                do {
                    try await manager.launch(id, openingWindow: false)
                } catch {
                    manager.onError?(String(describing: error))
                    return false
                }
            }
            guard manager.isRunning(id) else { return false }
            manager.warmUpRobot(for: id).limits = .init(loadTimeout: 15, startTimeout: 8, scriptTimeout: 5,
                                                         dwellOverride: 1...1.2, pauseOverride: 0.2...0.3)
            return manager.startWarmUp(id, plan: plan)
        }
        defer { coordinator.shutDown() }
        let policy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.accessory)
        defer { NSApp.setActivationPolicy(policy) }

        let plans: [UUID: WarmUpPlan] = [
            first.id: WarmUpPlan(addresses: [page("warmup.selftest.invalid", "qa"), page("www.queue-site.invalid", "qb")].joined(separator: "\n"),
                                 scroll: false, followLinks: false),
            second.id: WarmUpPlan(addresses: page("warmup.selftest.invalid", "qc"), scroll: false, followLinks: false),
        ]
        coordinator.enqueue([first.id, second.id]) { plans[$0] ?? WarmUpPlan() }
        // Watched every tenth of a second while the queue goes.
        var bothRunning = false
        var windowShown = false
        var order: [UUID] = []
        let done = await waitUntil(timeout: 120) {
            for id in [first.id, second.id] where manager.isRunning(id) {
                if order.last != id { order.append(id) }
                if manager.session(for: id)?.hasVisibleWindow == true { windowShown = true }
            }
            if manager.isRunning(first.id) && manager.isRunning(second.id) { bothRunning = true }
            return !coordinator.queue.isActive
        }
        let entries = coordinator.queue.entries
        func report(_ id: UUID) -> WarmUpStatus? {
            guard let entry = entries.first(where: { $0.profileID == id }), case let .done(status) = entry.state else { return nil }
            return status
        }
        let firstReport = report(first.id), secondReport = report(second.id)
        check("warm-up queue: two profiles warmed up one after the other, each started without a window, then stopped and sealed before the next began",
              done && !bothRunning && !windowShown && order == [first.id, second.id]
                  && firstReport?.phase == .finished && secondReport?.phase == .finished
                  && !manager.isRunning(first.id) && !manager.isRunning(second.id)
                  && !webKitDataDirectoriesExist(first.id) && !webKitDataDirectoriesExist(second.id) && messages.isEmpty,
              "done=\(done) both=\(bothRunning) window=\(windowShown) order=\(order.map { $0 == first.id ? 1 : 2 }) "
                  + "states=\(entries.map(\.state)) messages=\(messages)")
        func counts(_ status: WarmUpStatus?, _ site: String) -> [Int] {
            guard let found = status?.sites?.first(where: { $0.site == site }) else { return [] }
            return [found.cookies, found.added]
        }
        check("warm-up report: the profile's cookies per site (registrable domain) after the run, the run's own told from those it had",
              counts(firstReport, "selftest.invalid") == [1, 1] && counts(firstReport, "queue-site.invalid") == [1, 1]
                  && firstReport?.cookies == 2
                  && counts(secondReport, "selftest.invalid") == [2, 1] && secondReport?.cookies == 1,
              "first=\(firstReport?.sites ?? []) (\(firstReport?.cookies ?? -1)) second=\(secondReport?.sites ?? []) (\(secondReport?.cookies ?? -1))")
        let stored = try repository.warmUpSchedule(for: first.id)
        check("warm-up schedule: a run from the queue counts as the profile's last run, stored with its schedule",
              (stored?.lastRunAt ?? .distantPast) >= queued && (coordinator.nextRun(of: first.id) ?? .distantPast) > Date().addingTimeInterval(23 * 3600),
              "lastRunAt=\(String(describing: stored?.lastRunAt)) next=\(String(describing: coordinator.nextRun(of: first.id)))")
        try await manager.delete(first.id)
        try await manager.delete(second.id)
    }

    /// The profile's WebKit data is not on disk in plain form (sealed).
    private func webKitDataDirectoriesExist(_ profileID: UUID) -> Bool {
        !WebDataStoreVault.discoverDirectories(for: profileID).isEmpty
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
