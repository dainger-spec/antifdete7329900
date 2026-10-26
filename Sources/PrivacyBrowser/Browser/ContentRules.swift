import os
import WebKit

/// Content rule lists added to every web view of a profile with a proxy.
///
/// `<link rel="dns-prefetch">` (also sent as a `Link:` header) makes WebKit's network process
/// resolve the host through the system resolver, outside the profile's proxy: WebKit only skips
/// the prefetch when a proxy is set system-wide (`DNSResolveQueue::isUsingProxy` reads
/// `CFNetworkCopySystemProxySettings`), not for a data store's `proxyConfigurations`. With
/// SOCKS5 the proxy resolves every other name, so this would be the one DNS query a page can
/// make the Mac send itself. WebKit runs the prefetch through the content rule lists as a
/// `ping`-type load, so a rule blocking `ping` stops it. The same rule stops `<a ping>` and
/// `navigator.sendBeacon` (click and unload trackers, which content blockers block too).
@MainActor
enum ContentRules {
    /// Blocks every ping-type load; nil until `prepare()` compiled it (or when compiling failed).
    private(set) static var dnsPrefetchBlocker: WKContentRuleList?
    private static var preparation: Task<Void, Never>?
    private static let log = Logger(subsystem: "PrivacyBrowser", category: "ContentRules")

    static let dnsPrefetchBlockerIdentifier = "pb-block-ping-loads-v1"
    static let dnsPrefetchBlockerJSON = """
    [{"trigger": {"url-filter": ".*", "resource-type": ["ping"]}, "action": {"type": "block"}}]
    """

    /// Compiles the lists once per process (the store caches the compiled form on disk). Call
    /// before a `BrowserSession` with a proxy is created; a failure is logged, not fatal.
    static func prepare() async {
        if dnsPrefetchBlocker != nil { return }
        if preparation == nil {
            preparation = Task { @MainActor in
                // The store completes on WebKit's main run loop, which exists only once WebKit is
                // initialized (see WebDataStoreVault.ensureWebKitInitialized).
                WebDataStoreVault.ensureWebKitInitialized()
                do {
                    dnsPrefetchBlocker = try await WKContentRuleListStore.default()
                        .compileContentRuleList(forIdentifier: dnsPrefetchBlockerIdentifier,
                                                encodedContentRuleList: dnsPrefetchBlockerJSON)
                    log.info("Compiled the ping-load blocker")
                } catch {
                    log.error("Could not compile the ping-load blocker; dns-prefetch may resolve outside proxies: \(String(describing: error), privacy: .public)")
                }
            }
        }
        await preparation?.value
    }
}
