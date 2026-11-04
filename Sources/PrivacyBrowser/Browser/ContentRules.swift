import BrowserCore
import os
import WebKit

/// The content rule list added to every web view of a profile with a proxy
/// (`ProxiedContentRules`, which says what it blocks and why).
///
/// `<link rel="dns-prefetch">` (also sent as a `Link:` header) makes WebKit's network process
/// resolve the host through the system resolver, outside the profile's proxy: WebKit only skips
/// the prefetch when a proxy is set system-wide (`DNSResolveQueue::isUsingProxy` reads
/// `CFNetworkCopySystemProxySettings`), not for a data store's `proxyConfigurations`. With
/// SOCKS5 the proxy resolves every other name, so this would be the one DNS query a page can
/// make the Mac send itself. WebKit 7621 and later runs the prefetch through the content rule
/// lists as a `ping`-type load, so a rule blocking `ping` stops it there; before 7621 the prefetch
/// is a preference instead, which `BrowserSession.applyPrivacyPreferences` turns off. The same rule
/// stops `<a ping>` (a click tracker, which content blockers block too); a beacon is another type
/// of load and goes through the proxy like any other. Loads to this Mac itself, which the system
/// never sends through a proxy, are blocked from every page not itself on this Mac.
@MainActor
enum ContentRules {
    /// The compiled list; nil until `prepare()` compiled it (or when compiling failed).
    private(set) static var proxiedProfileRules: WKContentRuleList?
    /// `prepare()` ran and WebKit refused the list: a profile with a proxy then does not start.
    private(set) static var failedToCompile = false
    /// What WebKit said when it refused the list (the self-test shows it).
    private(set) static var compileErrors: [String] = []
    private static var preparation: Task<Void, Never>?
    private static let log = Logger(subsystem: "PrivacyBrowser", category: "ContentRules")

    static let identifier = ProxiedContentRules.identifier

    /// Compiles the lists once per process (the store caches the compiled form on disk). Call
    /// before a `BrowserSession` with a proxy is created; a failure is logged, not fatal.
    static func prepare() async {
        if proxiedProfileRules != nil { return }
        if preparation == nil {
            preparation = Task { @MainActor in
                // The store completes on WebKit's main run loop, which exists only once WebKit is
                // initialized (see WebDataStoreVault.ensureWebKitInitialized).
                WebDataStoreVault.ensureWebKitInitialized()
                // The default store (its compiled lists are cached on disk), then, if that one
                // cannot be written, a store of this run's own in the temporary folder.
                let stores: [() -> WKContentRuleListStore?] = [
                    { WKContentRuleListStore.default() },
                    { WKContentRuleListStore(url: FileManager.default.temporaryDirectory
                        .appendingPathComponent("pb-rules-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)) },
                ]
                for store in stores {
                    guard let store = store() else { continue }
                    do {
                        proxiedProfileRules = try await store.compileContentRuleList(
                            forIdentifier: identifier, encodedContentRuleList: ProxiedContentRules.json)
                        log.notice("Compiled the rule list of profiles with a proxy (\(identifier, privacy: .public))")
                        break
                    } catch {
                        compileErrors.append(String(describing: error))
                        log.error("Could not compile the rule list of profiles with a proxy in a store: \(error.logKind, privacy: .public) \(String(describing: error), privacy: .private)")
                    }
                }
                if proxiedProfileRules == nil {
                    failedToCompile = true
                    log.error("No rule list for profiles with a proxy: they will not start")
                }
            }
        }
        await preparation?.value
    }
}
