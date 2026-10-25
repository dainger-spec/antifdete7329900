import AppKit
import BrowserCore
import WebKit

/// One running profile: its isolated `WKWebsiteDataStore` and all of its windows.
///
/// ISOLATION MODEL (native WebKit, macOS 14+):
///   * Persistent profiles use `WKWebsiteDataStore(forIdentifier: profileID)`. WebKit keeps
///     cookies, localStorage/sessionStorage, IndexedDB, Cache API, service workers, the HTTP
///     disk cache, HSTS state, and credentials for that store separately from every other
///     store, and serves it through a separate network *session*.
///   * Ephemeral profiles use `WKWebsiteDataStore.nonPersistent()` (in-memory only).
///   * Every web view created for this profile — including `window.open` popups, which
///     WebKit creates from the opener's configuration — uses this data store.
///
/// PLATFORM LIMITATIONS:
///   * Process separation is per *site* and per data store for web content processes, but
///     all profiles share one WebKit networking process (separate sessions inside it). This
///     is session isolation, not OS-level process/user isolation.
///   * The host machine's fingerprintable surface (fonts, screen, GPU/WebGL renderer,
///     canvas rasterisation, audio stack, hardware concurrency, languages) is identical
///     across profiles. No public WKWebView API changes it.
@MainActor
final class BrowserSession {
    let profileID: UUID
    let profileName: String
    let configuration: ProfileConfiguration
    let passwordVault: PasswordVault
    var onAllWindowsClosed: (() -> Void)?

    private(set) var dataStore: WKWebsiteDataStore?
    private let userContentController: WKUserContentController
    private var windows: [BrowserWindowController] = []
    private var isClosing = false

    init(profileID: UUID, profileName: String, configuration: ProfileConfiguration, passwordVault: PasswordVault) {
        self.profileID = profileID
        self.profileName = profileName
        self.configuration = configuration
        self.passwordVault = passwordVault

        let store: WKWebsiteDataStore = configuration.ephemeral
            ? .nonPersistent()
            : WKWebsiteDataStore(forIdentifier: profileID)
        // Applies to all network loads of this data store. An empty array = direct connection.
        store.proxyConfigurations = ProxyConfigurationFactory.make(configuration.proxy)
        self.dataStore = store
        self.userContentController = PrivacyScripts.makeUserContentController(for: configuration)
    }

    var windowCount: Int { windows.count }

    func makeWebViewConfiguration() -> WKWebViewConfiguration {
        let webConfiguration = WKWebViewConfiguration()
        if let dataStore { webConfiguration.websiteDataStore = dataStore }
        webConfiguration.userContentController = userContentController
        // Safe Browsing lookups bypass the per-profile proxy; opt-in per profile.
        webConfiguration.preferences.isFraudulentWebsiteWarningEnabled = configuration.safeBrowsingEnabled
        // Popups only in response to a user gesture.
        webConfiguration.preferences.javaScriptCanOpenWindowsAutomatically = false
        return webConfiguration
    }

    @discardableResult
    func openWindow(url: URL?) -> BrowserWindowController {
        let controller = BrowserWindowController(session: self, configuration: makeWebViewConfiguration())
        windows.append(controller)
        controller.showWindow(nil)
        if let url {
            controller.load(url)
        } else {
            controller.focusAddressBar()
        }
        return controller
    }

    /// For `window.open` / `target=_blank`. WebKit requires that the returned web view is
    /// created with the configuration it supplies (it inherits our data store and scripts).
    func openPopup(configuration webConfiguration: WKWebViewConfiguration) -> WKWebView {
        let controller = BrowserWindowController(session: self, configuration: webConfiguration)
        windows.append(controller)
        controller.showWindow(nil)
        return controller.webView
    }

    func windowDidClose(_ controller: BrowserWindowController) {
        windows.removeAll { $0 === controller }
        if windows.isEmpty && !isClosing {
            onAllWindowsClosed?()
        }
    }

    func bringToFront() {
        windows.last?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Closes every window and drops this session's reference to the data store, so that
    /// WebKit can release the store's network session (precondition for sealing it).
    func shutDown() {
        isClosing = true
        for controller in windows {
            controller.tearDown()
            controller.close()
        }
        windows.removeAll()
        userContentController.removeAllUserScripts()
        dataStore = nil
    }
}
