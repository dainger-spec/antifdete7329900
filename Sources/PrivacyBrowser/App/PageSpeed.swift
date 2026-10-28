import AppKit
import BrowserCore
import ObjectiveC
import WebKit

/// `PrivacyBrowser --page-speed <spec.json> <out-dir>`: loads pages in on-screen profile windows and
/// records how fast they load, for `scripts/page_speed.py`, which loads the same pages in this Mac's
/// Safari (safaridriver) and compares. Measurement only: nothing here changes how a profile is
/// built, except the `MeasurementFactors` a variant names (one part of the profile left out, or one
/// WebKit setting changed), which nothing outside this mode sets.
///
/// For each variant (a profile built one way) and page: `runs` cold loads — the store's website
/// data cleared, a new tab — each followed by a warm load of the same URL in that tab. Each load:
/// the wall-clock time from `load()` until WebKit stops loading, then `metricsScript` (the page's
/// own timing entries) after `settleMs`.
///
/// Also written: the configuration of the profile's process pool, data store and preferences next
/// to a plain WKWebView's (`dump`), and whether a persistent profile's HTTP cache survives a stop
/// and a start, sealed and restored by `WebDataStoreVault` (`cache`).
///
/// Spec (JSON): {"window": {"width": W, "height": H}, "runs": 5, "settleMs": 800, "timeoutMs": 30000,
///               "metricsScript": "<async function body>",
///               "pages": [{"name": "…", "url": "…"}],
///               "variants": [{"name": "baseline", "pages": ["…"], "persistent": true, "timeZone": null,
///                             "generation": null, "sharedPool": false, "changes": ["shims"],
///                             "pool": {"prewarmsProcessesAutomatically": true}, "store": {}}],
///               "cacheProbe": {"url": "…", "hits": "…"}}
/// Output: <out-dir>/page-speed.json.
@MainActor
final class PageSpeed {
    struct Spec: Decodable {
        struct Window: Decodable { var width: Double; var height: Double }
        struct Page: Decodable { var name: String; var url: String }
        struct Variant: Decodable {
            var name: String
            /// Page names; nil: every page.
            var pages: [String]?
            var persistent: Bool?
            var timeZone: String?
            var generation: String?
            /// WebKit's shared process pool instead of the profile's own (`ProfileProcessPool`).
            var sharedPool: Bool?
            var changes: [String]?
            var pool: [String: Bool]?
            var store: [String: Bool]?
        }
        struct CacheProbe: Decodable {
            /// A cacheable resource (Cache-Control: max-age) of the measuring server.
            var url: String
            /// Answers with how many times the server sent `url`.
            var hits: String
        }
        var window: Window
        var runs: Int
        var settleMs: Int
        var timeoutMs: Int
        var metricsScript: String
        var pages: [Page]
        var variants: [Variant]
        var cacheProbe: CacheProbe?
    }

    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ text: String) { errorDescription = text }
    }

    static func start(arguments: [String]) {
        setvbuf(stdout, nil, _IOLBF, 0)
        guard let index = arguments.firstIndex(of: "--page-speed"), arguments.count > index + 2 else {
            print("usage: PrivacyBrowser --page-speed <spec.json> <out-dir>")
            exit(64)
        }
        let specPath = arguments[index + 1], outPath = arguments[index + 2]
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1500) {
            print("PAGE-SPEED TIMEOUT after 1500 s")
            exit(3)
        }
        Task { @MainActor in
            do {
                let spec = try JSONDecoder().decode(Spec.self, from: Data(contentsOf: URL(fileURLWithPath: specPath)))
                try await PageSpeed().run(spec, out: URL(fileURLWithPath: outPath))
                print("PAGE-SPEED DONE")
                exit(0)
            } catch {
                print("PAGE-SPEED FAILED: \(error.localizedDescription)")
                exit(1)
            }
        }
        app.run()
    }

    private func run(_ spec: Spec, out: URL) async throws {
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pb-page-speed-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try ProfileRepository(vault: MasterVault.create(in: root, password: "page-speed", iterations: 10_000))
        print("INFO macOS \(ProcessInfo.processInfo.operatingSystemVersionString), Safari \(HostSafari.version)")
        var output: [String: Any] = [:]
        var variants: [String: Any] = [:]
        for variant in spec.variants {
            print("INFO variant \(variant.name)")
            do {
                var measured = try await measure(variant, spec: spec, repository: repository, withDump: output["dump"] == nil)
                if let dump = measured.removeValue(forKey: "dump") { output["dump"] = dump }
                variants[variant.name] = measured
            } catch {
                print("INFO variant \(variant.name) failed: \(error.localizedDescription)")
                variants[variant.name] = ["error": error.localizedDescription]
            }
            reset()
        }
        output["variants"] = variants
        if let probe = spec.cacheProbe {
            do {
                output["cache"] = try await cacheAcrossStop(probe, repository: repository)
            } catch {
                output["cache"] = ["error": error.localizedDescription]
            }
            reset()
        }
        let data = try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: out.appendingPathComponent("page-speed.json"))
    }

    private func reset() {
        MeasurementFactors.changes = []
        MeasurementFactors.poolSettings = [:]
        MeasurementFactors.storeSettings = [:]
        MeasurementFactors.traceShim = false
        ProfileProcessPool.isDisabledForTesting = false
    }

    // MARK: A variant

    private func measure(_ variant: Spec.Variant, spec: Spec, repository: ProfileRepository,
                         withDump: Bool) async throws -> [String: Any] {
        MeasurementFactors.changes = Set(variant.changes ?? [])
        MeasurementFactors.poolSettings = variant.pool ?? [:]
        MeasurementFactors.storeSettings = variant.store ?? [:]
        MeasurementFactors.traceShim = true
        ProfileProcessPool.isDisabledForTesting = variant.sharedPool ?? false
        if MeasurementFactors.has("contentRules") { await ContentRules.prepare() }

        let persistent = variant.persistent ?? true
        let configuration = ProfileConfiguration(timeZoneIdentifier: variant.timeZone == "host" ? TimeZone.current.identifier : variant.timeZone,
                                                 ephemeral: !persistent, deviceGenerationID: variant.generation)
        let summary = try repository.create(name: "Speed \(variant.name)", configuration: configuration)
        let session = try makeSession(summary.id, repository: repository)
        var result: [String: Any] = ["persistent": persistent]
        var failure: Error?
        do {
            let controller = session.openWindow(url: nil)
            place(controller, spec.window)
            result["applied"] = applied(session)
            if withDump {
                var everything = configurationDump(session)
                everything["shimTrace"] = try? await shimTrace(controller, url: spec.pages.first?.url)
                result["dump"] = everything
            } else if variant.changes?.isEmpty == false || variant.timeZone != nil {
                result["shimTrace"] = try? await shimTrace(controller, url: spec.pages.first?.url)
            }
            var pages: [String: Any] = [:]
            for page in spec.pages where variant.pages?.contains(page.name) ?? true {
                guard let url = URL(string: page.url) else { continue }
                var cold: [Any] = [], warm: [Any] = []
                for run in 0..<spec.runs {
                    if let store = session.dataStore {
                        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
                    }
                    // A new tab for the cold load; the previous one goes.
                    let tab = controller.addTab(url: nil)
                    while controller.tabCount > 1 { controller.closeTab(at: 0) }
                    guard let tab else { throw Failure("no tab") }
                    cold.append(await load(url, in: tab, spec: spec))
                    warm.append(await load(url, in: tab, spec: spec))
                    print("INFO [\(variant.name)] \(page.name) run \(run + 1)/\(spec.runs)")
                }
                pages[page.name] = ["cold": cold, "warm": warm]
            }
            result["pages"] = pages
        } catch {
            failure = error
        }
        session.shutDown()
        if persistent { await WebDataStoreVault(repository: repository).deleteData(profileID: summary.id) }
        try? repository.delete(summary.id)
        if let failure { throw failure }
        return result
    }

    private func makeSession(_ id: UUID, repository: ProfileRepository) throws -> BrowserSession {
        let key = try repository.profileKey(for: id)
        let configuration = try repository.loadConfiguration(id, key: key)
        let name = "Speed"
        let library = ProfileLibrary(
            history: try repository.historyStore(for: id, key: key, policy: configuration.historyPolicy, persistent: false),
            bookmarks: try repository.bookmarkStore(for: id, key: key),
            recordsHistory: false)
        return try BrowserSession(profileID: id, profileName: name, configuration: configuration,
                                  passwordVault: try repository.passwordVault(for: id),
                                  passwordSettings: ProfilePasswordSettings(repository: repository, profileID: id, profileName: name,
                                                                            launchConfiguration: configuration),
                                  library: library)
    }

    private func place(_ controller: BrowserWindowController, _ window: Spec.Window) {
        // 60 pt from the screen's top-left corner, where page_speed.py puts Safari's window too.
        let screen = controller.window?.screen?.frame ?? NSScreen.main?.frame ?? .zero
        controller.window?.setFrame(NSRect(x: screen.minX + 60, y: screen.maxY - 60 - window.height,
                                           width: window.width, height: window.height), display: true)
    }

    /// One load: wall-clock time until WebKit stops loading, then the page's own timing entries.
    private func load(_ url: URL, in tab: BrowserTab, spec: Spec) async -> [String: Any] {
        let webView = tab.webView
        let started = Date()
        tab.load(url)
        let deadline = started.addingTimeInterval(TimeInterval(spec.timeoutMs) / 1000)
        // Until the load has begun (isLoading may lag the call), then until it ends.
        while !webView.isLoading && webView.estimatedProgress == 0 && Date() < started.addingTimeInterval(1) {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        while webView.isLoading && Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        var metrics: [String: Any] = ["wallMs": Int(Date().timeIntervalSince(started) * 1000)]
        if webView.isLoading {
            metrics["error"] = "did not finish loading in \(spec.timeoutMs) ms"
            return metrics
        }
        try? await Task.sleep(nanoseconds: UInt64(spec.settleMs) * 1_000_000)
        do {
            let body = "const __value = await (async () => {\n" + spec.metricsScript + "\n})();\nreturn JSON.stringify(__value);"
            if let text = try await evaluate(body, in: webView) as? String,
               let page = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] {
                metrics.merge(page) { current, _ in current }
            }
        } catch {
            metrics["error"] = error.localizedDescription
        }
        return metrics
    }

    private func evaluate(_ body: String, in webView: WKWebView, timeout: TimeInterval = 15) async throws -> Any? {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Any?, Error>) in
            var answered = false
            let answer: (Result<Any?, Error>) -> Void = { result in
                guard !answered else { return }
                answered = true
                continuation.resume(with: result)
            }
            webView.callAsyncJavaScript(body, arguments: [:], in: nil, in: .page) { result in
                answer(result.map { $0 as Any? })
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
                answer(.failure(Failure("script did not finish in \(Int(timeout)) s")))
            }
        }
    }

    // MARK: What the variant got

    /// Which of the variant's changes took effect (a key this WebKit lacks is not set).
    private func applied(_ session: BrowserSession) -> [String: Any] {
        var out: [String: Any] = ["changes": MeasurementFactors.changes.sorted(),
                                  "ownPool": session.processPool != nil, "timeZoneByEngine": session.timeZoneByEngine]
        if let pool = session.processPool, let configuration = Self.poolConfiguration(pool) {
            out["pool"] = MeasurementFactors.poolSettings.keys.sorted().map { key in
                "\(key)=\(Self.properties(of: configuration)[key] ?? "absent")"
            }
        }
        if let store = session.dataStore, let configuration = Self.storeConfiguration(store) {
            out["store"] = MeasurementFactors.storeSettings.keys.sorted().map { key in
                "\(key)=\(Self.properties(of: configuration)[key] ?? "absent")"
            }
        }
        return out
    }

    /// What the shim installed in the page's window (`MeasurementFactors.traceShim`).
    private func shimTrace(_ controller: BrowserWindowController, url: String?) async throws -> Any? {
        guard let address = url, let url = URL(string: address), let tab = controller.selectedTab else { return nil }
        tab.load(url)
        try? await Task.sleep(nanoseconds: 300_000_000)
        let deadline = Date().addingTimeInterval(20)
        while tab.webView.isLoading && Date() < deadline { try? await Task.sleep(nanoseconds: 50_000_000) }
        let body = """
            const trace = window[Symbol.for('pb.measurement')];
            return JSON.stringify({ trace: trace === undefined ? 'no shim' : trace,
                                    zone: Intl.DateTimeFormat().resolvedOptions().timeZone,
                                    offset: new Date(2024, 0, 15).getTimezoneOffset() });
            """
        guard let text = try await evaluate(body, in: tab.webView) as? String else { return nil }
        return try JSONSerialization.jsonObject(with: Data(text.utf8))
    }

    // MARK: Configuration, next to a plain WKWebView's

    private func configurationDump(_ session: BrowserSession) -> [String: Any] {
        var out: [String: Any] = [:]
        let profileConfiguration = session.makeWebViewConfiguration()
        let plainConfiguration = WKWebViewConfiguration()
        func described(_ object: NSObject?) -> Any { object.map { Self.properties(of: $0) as Any } ?? "none" }
        out["poolProfile"] = described(session.processPool.flatMap { Self.poolConfiguration($0) })
        out["poolShared"] = described(ProfileProcessPool.pool(of: plainConfiguration).flatMap { Self.poolConfiguration($0) })
        out["storeProfile"] = described(session.dataStore.flatMap { Self.storeConfiguration($0) })
        // Not WebKit's default store, which the app never opens (BrowserSession): an ephemeral one.
        out["storeEphemeral"] = described(Self.storeConfiguration(WKWebsiteDataStore.nonPersistent()))
        out["preferencesProfile"] = Self.properties(of: profileConfiguration.preferences)
        out["preferencesPlain"] = Self.properties(of: plainConfiguration.preferences)
        out["featuresProfile"] = Self.features(of: profileConfiguration.preferences)
        out["featuresPlain"] = Self.features(of: plainConfiguration.preferences)
        out["webViewConfigurationProfile"] = Self.properties(of: profileConfiguration)
        out["webViewConfigurationPlain"] = Self.properties(of: plainConfiguration)
        out["userScripts"] = session.makeWebViewConfiguration().userContentController.userScripts.map {
            "\($0.injectionTime == .atDocumentStart ? "start" : "end") \($0.isForMainFrameOnly ? "main" : "all") \($0.source.utf8.count) bytes"
        }
        return out
    }

    private static func poolConfiguration(_ pool: NSObject) -> NSObject? {
        pool.responds(to: NSSelectorFromString("_configuration")) ? pool.value(forKey: "_configuration") as? NSObject : nil
    }

    private static func storeConfiguration(_ store: WKWebsiteDataStore) -> NSObject? {
        store.responds(to: NSSelectorFromString("_configuration")) ? store.value(forKey: "_configuration") as? NSObject : nil
    }

    /// Every BOOL, number and string property of `object` (its class and superclasses below NSObject),
    /// read through its getter.
    static func properties(of object: NSObject) -> [String: String] {
        var out: [String: String] = [:]
        var cls: AnyClass? = type(of: object)
        while let current = cls, current != NSObject.self {
            var count: UInt32 = 0
            if let list = class_copyPropertyList(current, &count) {
                for index in 0..<Int(count) {
                    let property = list[index]
                    let name = String(cString: property_getName(property))
                    guard out[name] == nil, let attributes = property_getAttributes(property).map({ String(cString: $0) }) else { continue }
                    let parts = attributes.split(separator: ",").map(String.init)
                    guard let kind = parts.first else { continue }
                    let getter = parts.first(where: { $0.hasPrefix("G") }).map { String($0.dropFirst()) } ?? name
                    let selector = NSSelectorFromString(getter)
                    guard object.responds(to: selector), let method = class_getInstanceMethod(type(of: object), selector) else { continue }
                    let implementation = method_getImplementation(method)
                    switch kind {
                    case "Tc", "TB":
                        typealias Getter = @convention(c) (NSObject, Selector) -> Bool
                        out[name] = unsafeBitCast(implementation, to: Getter.self)(object, selector) ? "true" : "false"
                    case "Tq", "Tl", "Ti", "Ts":
                        typealias Getter = @convention(c) (NSObject, Selector) -> Int
                        out[name] = String(unsafeBitCast(implementation, to: Getter.self)(object, selector))
                    case "TQ", "TL", "TI", "TS":
                        typealias Getter = @convention(c) (NSObject, Selector) -> UInt
                        out[name] = String(unsafeBitCast(implementation, to: Getter.self)(object, selector))
                    case "Td":
                        typealias Getter = @convention(c) (NSObject, Selector) -> Double
                        out[name] = String(unsafeBitCast(implementation, to: Getter.self)(object, selector))
                    case "T@\"NSString\"", "T@\"NSNumber\"", "T@\"NSURL\"":
                        typealias Getter = @convention(c) (NSObject, Selector) -> Unmanaged<AnyObject>?
                        out[name] = unsafeBitCast(implementation, to: Getter.self)(object, selector).map { "\($0.takeUnretainedValue())" } ?? "nil"
                    default:
                        continue
                    }
                }
                free(list)
            }
            cls = class_getSuperclass(current)
        }
        return out
    }

    /// Each of WebKit's features (`+[WKPreferences _features]`) on or off in `preferences`.
    static func features(of preferences: WKPreferences) -> [String: String] {
        let list = NSSelectorFromString("_features"), keyGetter = NSSelectorFromString("key")
        let preferencesClass: AnyObject = WKPreferences.self
        guard preferencesClass.responds(to: list),
              let features = preferencesClass.perform(list)?.takeUnretainedValue() as? [NSObject] else { return [:] }
        var out: [String: String] = [:]
        for feature in features {
            guard feature.responds(to: keyGetter), let key = feature.perform(keyGetter)?.takeUnretainedValue() as? String else { continue }
            out[key] = WebKitPreferences.isFeatureEnabled(preferences, key).map { $0 ? "on" : "off" } ?? "?"
        }
        return out
    }

    // MARK: The HTTP cache across a stop and a start

    /// A persistent profile loads a cacheable resource, stops (its data sealed into the vault's
    /// archive, as ProfileManager.stop does), starts again (unsealed) and loads it again: the
    /// server's count says whether the second load came from the restored cache.
    private func cacheAcrossStop(_ probe: Spec.CacheProbe, repository: ProfileRepository) async throws -> [String: Any] {
        guard let url = URL(string: probe.url) else { throw Failure("bad cache probe URL") }
        let summary = try repository.create(name: "Speed cache", configuration: ProfileConfiguration())
        defer { try? repository.delete(summary.id) }
        let key = try repository.profileKey(for: summary.id)
        let vault = WebDataStoreVault(repository: repository)
        var out: [String: Any] = [:]
        func hits() async -> String {
            guard let address = URL(string: probe.hits),
                  let response = try? await URLSession.shared.data(from: address) else { return "?" }
            return String(decoding: response.0, as: UTF8.self)
        }
        func visit(_ label: String) async throws {
            let session = try makeSession(summary.id, repository: repository)
            let controller = session.openWindow(url: nil)
            guard let tab = controller.selectedTab else { throw Failure("no tab") }
            let started = Date()
            tab.load(url)
            try? await Task.sleep(nanoseconds: 200_000_000)
            while tab.webView.isLoading && Date().timeIntervalSince(started) < 20 { try? await Task.sleep(nanoseconds: 20_000_000) }
            // CFNetwork writes the cache entry a moment after the load.
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            out["\(label)LoadMs"] = Int(Date().timeIntervalSince(started) * 1000)
            out["\(label)Hits"] = await hits()
            session.shutDown()
        }
        try await vault.prepareForLaunch(profileID: summary.id, key: key)
        try await visit("first")
        let before = WebDataStoreVault.discoverDirectories(for: summary.id)
        out["directoriesBeforeSeal"] = before.map { $0.path.replacingOccurrences(of: NSHomeDirectory(), with: "~") }
        out["cacheFilesBeforeSeal"] = before.filter { $0.path.contains("/Caches/") }.map(Self.fileCount).reduce(0, +)
        let sealed = try await vault.seal(profileID: summary.id, key: key)
        out["sealed"] = "\(sealed.stats.files) files, \(sealed.stats.bytes) bytes, \(sealed.attempts) attempts"
        out["directoriesAfterSeal"] = WebDataStoreVault.discoverDirectories(for: summary.id).count
        try await vault.prepareForLaunch(profileID: summary.id, key: key)
        let restored = WebDataStoreVault.discoverDirectories(for: summary.id)
        out["cacheFilesAfterRestore"] = restored.filter { $0.path.contains("/Caches/") }.map(Self.fileCount).reduce(0, +)
        try await visit("second")
        _ = try? await vault.seal(profileID: summary.id, key: key)
        await vault.deleteData(profileID: summary.id)
        return out
    }

    private static func fileCount(_ directory: URL) -> Int {
        let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey])
        var count = 0
        while let item = enumerator?.nextObject() as? URL {
            if (try? item.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true { count += 1 }
        }
        return count
    }
}
