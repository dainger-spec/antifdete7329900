import AppKit
import BrowserCore
import os
import WebKit

/// One running profile: its isolated `WKWebsiteDataStore`, its decrypted library (history,
/// bookmarks), and all of its windows and tabs.
///
/// ISOLATION MODEL (native WebKit, macOS 14+):
///   * Persistent profiles use `WKWebsiteDataStore(forIdentifier: profileID)`. WebKit keeps
///     cookies, localStorage/sessionStorage, IndexedDB, Cache API, service workers, the HTTP
///     disk cache, HSTS state, and credentials for that store separately from every other
///     store, and serves it through a separate network *session*.
///   * Ephemeral profiles use `WKWebsiteDataStore.nonPersistent()` (in-memory only).
///   * Every web view of this profile — every tab of every window, and `window.open` popups,
///     which WebKit creates from the opener's configuration — uses this data store.
///
/// PLATFORM LIMITATIONS:
///   * All profiles share one WebKit networking process (separate sessions inside it). This
///     is session isolation, not OS-level process/user isolation.
///   * FINGERPRINTING: the host machine's fingerprintable surface (fonts, screen size and
///     colour depth, GPU / WebGL renderer and parameters, canvas and audio rasterisation,
///     `hardwareConcurrency`, languages, TLS/HTTP2 fingerprint) is identical across all
///     profiles, because WKWebView has no public API to change it. A site that fingerprints
///     the device can link profiles to each other even though their storage and IP differ.
@MainActor
final class BrowserSession {
    let profileID: UUID
    let profileName: String
    let configuration: ProfileConfiguration
    let passwordVault: PasswordVault
    let library: ProfileLibrary
    var onAllWindowsClosed: (() -> Void)?

    private(set) var dataStore: WKWebsiteDataStore?
    private let userContentController: WKUserContentController
    private var windows: [BrowserWindowController] = []
    private var libraryWindow: LibraryWindowController?
    private var isClosing = false

    /// Throws when the profile's proxy cannot be applied — before any data store exists, so a
    /// profile with a broken proxy never starts on a direct connection (fail-closed).
    init(profileID: UUID, profileName: String, configuration: ProfileConfiguration,
         passwordVault: PasswordVault, library: ProfileLibrary) throws {
        let proxies = try ProxyConfigurationFactory.make(configuration.proxy)
        self.profileID = profileID
        self.profileName = profileName
        self.configuration = configuration
        self.passwordVault = passwordVault
        self.library = library

        // `.nonPersistent()` needs WebKit initialized but does not initialize it, and an ephemeral
        // profile can be the first WebKit use after unlock (see `ensureWebKitInitialized`).
        WebDataStoreVault.ensureWebKitInitialized()
        let store: WKWebsiteDataStore = configuration.ephemeral
            ? .nonPersistent()
            : WebDataStoreVault.makeStore(for: profileID)
        // Applies to all network loads of this data store. Empty only when no proxy is configured.
        store.proxyConfigurations = proxies
        self.dataStore = store
        // Routed through BehaviorSets so a profile's device generation selects its script bundle.
        self.userContentController = BehaviorSets.makeUserContentController(for: configuration)
        if configuration.proxy != nil {
            // Loads WebKit would otherwise make outside the proxy (see ContentRules).
            if let blocker = ContentRules.dnsPrefetchBlocker {
                userContentController.add(blocker)
            } else {
                Logger(subsystem: "PrivacyBrowser", category: "BrowserSession")
                    .error("No ping-load blocker: dns-prefetch of this profile may resolve outside its proxy")
            }
        }
    }

    var windowCount: Int { windows.count }

    /// The profile's browser windows (self-test hook).
    var windowControllers: [BrowserWindowController] { windows }

    var tabContext: BrowserTabContext {
        BrowserTabContext(profileName: profileName, userAgent: configuration.userAgent(hostSafariVersion: HostSafari.version),
                          passwordVault: passwordVault, library: library,
                          proxyCredential: configuration.proxy.flatMap { proxy in
                              proxy.username.map { URLCredential(user: $0, password: proxy.password ?? "", persistence: .forSession) }
                          })
    }

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

    // MARK: Windows

    @discardableResult
    func openWindow(url: URL?) -> BrowserWindowController {
        let controller = BrowserWindowController(session: self)
        windows.append(controller)
        controller.showWindow(nil)
        controller.addTab(url: url)
        return controller
    }

    /// Opens `url` in a new tab of this profile's frontmost window (or a new window).
    func openInNewTab(_ url: URL) {
        if let controller = frontmostWindow {
            controller.addTab(url: url)
            controller.window?.makeKeyAndOrderFront(nil)
        } else {
            openWindow(url: url)
        }
    }

    private var frontmostWindow: BrowserWindowController? {
        let ordered = NSApp.orderedWindows.compactMap { $0.windowController as? BrowserWindowController }
        return ordered.first { controller in windows.contains { $0 === controller } } ?? windows.last
    }

    func windowDidClose(_ controller: BrowserWindowController) {
        windows.removeAll { $0 === controller }
        if windows.isEmpty && !isClosing {
            onAllWindowsClosed?()
        }
    }

    func bringToFront() {
        frontmostWindow?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: Library window

    func showLibrary(_ section: LibraryView.Section, from controller: BrowserWindowController? = nil) {
        if libraryWindow == nil {
            libraryWindow = LibraryWindowController(session: self) { [weak self] url in
                self?.openInNewTab(url)
            } onClose: { [weak self] in
                self?.libraryWindow = nil
            }
        }
        libraryWindow?.show(section)
    }

    // MARK: Shutdown

    /// Closes every window, writes pending history, and drops this session's reference to the
    /// data store so that WebKit can release the store's network session (precondition for
    /// sealing it).
    func shutDown() {
        guard !isClosing else { return } // idempotent: window-close stop and lock/quit can both call this
        isClosing = true
        let libraryWin = libraryWindow
        libraryWindow = nil
        // Snapshot and clear first so any re-entrant `windowDidClose` sees an empty list.
        // `tearDown()` nils each window's delegate, so `close()` here never calls back into us.
        let toClose = windows
        windows.removeAll()
        libraryWin?.window?.delegate = nil
        libraryWin?.close()
        for controller in toClose {
            controller.tearDown()
            controller.close()
        }
        library.flush()
        userContentController.removeAllUserScripts()
        dataStore = nil
    }
}
