import AppKit
import BrowserCore
import WebKit

/// One running profile: its isolated `WKWebsiteDataStore`, its decrypted library (history,
/// bookmarks), its downloads, and all of its windows and tabs.
///
/// ISOLATION MODEL (native WebKit, macOS 14+):
///   * Persistent profiles use `WKWebsiteDataStore(forIdentifier: profileID)`. WebKit keeps
///     cookies, localStorage/sessionStorage, IndexedDB, Cache API, service workers, the HTTP
///     disk cache, HSTS state, and credentials for that store separately from every other
///     store, and serves it through a separate network *session*.
///   * Temporary profiles use `WKWebsiteDataStore.nonPersistent()` (in-memory only).
///   * Every web view of this profile — every tab of every window, and `window.open` popups,
///     which WebKit creates from the opener's configuration — uses this data store.
///
/// PLATFORM LIMITATIONS:
///   * All profiles share one WebKit networking process (separate sessions inside it). This
///     is session isolation, not OS-level process/user isolation.
///   * The Mac itself is shared: fonts, screen, GPU / WebGL renderer and canvas rasterisation,
///     `hardwareConcurrency`, the TLS/HTTP2 fingerprint and the Accept-Language header are the
///     same in every profile, because WKWebView has no public API to change them. A site that
///     fingerprints the device can tell that two profiles run on the same Mac even though their
///     storage and IP differ. See docs/ISOLATION_AND_LIMITATIONS.md §2.
@MainActor
final class BrowserSession {
    let profileID: UUID
    let profileName: String
    let configuration: ProfileConfiguration
    let passwordVault: PasswordVault
    let library: ProfileLibrary
    let downloads: DownloadsController
    var onAllWindowsClosed: (() -> Void)?
    /// Page loads report here (the proxy status in the sidebar and toolbar).
    var onLoadFinished: (() -> Void)?
    var onLoadFailed: ((UserFacingMessage) -> Void)?
    /// The app's proxy status board (toolbar badge, proxy check).
    weak var proxyCenter: ProxyStatusCenter?

    private(set) var dataStore: WKWebsiteDataStore?
    private let userContentController: WKUserContentController
    private let userAgent: UserAgentResolution
    private let sessionStore: SessionStore?
    private var windows: [BrowserWindowController] = []
    private var libraryWindow: LibraryWindowController?
    private var isClosing = false
    /// The state of the last window, captured as it closed (its tabs are gone by the time the
    /// profile stops).
    private var lastClosedWindow: SessionState.Window?

    init(profileID: UUID, profileName: String, configuration: ProfileConfiguration,
         passwordVault: PasswordVault, library: ProfileLibrary, sessionStore: SessionStore?) {
        self.profileID = profileID
        self.profileName = profileName
        self.configuration = configuration
        self.passwordVault = passwordVault
        self.library = library
        self.sessionStore = sessionStore
        self.downloads = DownloadsController(profileName: profileName)
        self.userAgent = configuration.userAgentResolution(safari: SafariInfo.version)

        let store: WKWebsiteDataStore = configuration.ephemeral
            ? .nonPersistent()
            : WKWebsiteDataStore(forIdentifier: profileID)
        // Applies to all network loads of this data store. An empty array = this Mac's normal
        // connection (no proxy); with a proxy, failover is off: nothing goes around it.
        store.proxyConfigurations = ProxyConfigurationFactory.make(configuration.proxy)
        self.dataStore = store
        self.userContentController = PrivacyScripts.makeUserContentController(for: configuration)
    }

    var windowCount: Int { windows.count }
    var hasProxy: Bool { configuration.proxy != nil }

    var tabContext: BrowserTabContext {
        BrowserTabContext(profileID: profileID, profileName: profileName, userAgent: userAgent.customUserAgent,
                          proxyConfigured: hasProxy, passwordVault: passwordVault, library: library,
                          downloads: downloads,
                          onLoadFinished: { [weak self] in self?.onLoadFinished?() },
                          onLoadFailed: { [weak self] message in self?.onLoadFailed?(message) })
    }

    func makeWebViewConfiguration() -> WKWebViewConfiguration {
        let webConfiguration = WKWebViewConfiguration()
        if let dataStore { webConfiguration.websiteDataStore = dataStore }
        webConfiguration.userContentController = userContentController
        // "Version/x Safari/605.1.15" for the Safari-for-Mac mode; popups inherit it.
        webConfiguration.applicationNameForUserAgent = userAgent.applicationNameForUserAgent
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

    /// Opens the windows and tabs saved when the profile last stopped. Only the selected tab of
    /// each window loads right away; the others load when first selected.
    /// Returns false if there was nothing to restore.
    @discardableResult
    func restore(_ state: SessionState) -> Bool {
        var opened = false
        for window in state.windows where !window.tabs.isEmpty {
            let controller = BrowserWindowController(session: self)
            windows.append(controller)
            controller.showWindow(nil)
            controller.restoreTabs(window)
            opened = true
        }
        return opened
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

    var frontmostWindow: BrowserWindowController? {
        let ordered = NSApp.orderedWindows.compactMap { $0.windowController as? BrowserWindowController }
        return ordered.first { controller in windows.contains { $0 === controller } } ?? windows.last
    }

    /// Called from the window's `windowWillClose`, while its tabs still exist.
    func windowWillClose(_ controller: BrowserWindowController, state: SessionState.Window) {
        if windows.count == 1, windows.first === controller { lastClosedWindow = state }
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

    // MARK: Session state

    /// What would be restored next time: every open window, or the last one closed.
    var currentState: SessionState {
        let open = windows.map(\.sessionWindow).filter { !$0.tabs.isEmpty }
        let list = open.isEmpty ? [lastClosedWindow].compactMap { $0 } : open
        return SessionState(windows: list, savedAt: Date()).normalized()
    }

    private func saveSessionState() {
        guard let sessionStore else { return }
        do {
            if configuration.restoreTabs && !configuration.ephemeral {
                try sessionStore.save(currentState)
            } else {
                try sessionStore.clear()
            }
        } catch {
            Log.error("session", "could not save the open tabs of \(Log.id(profileID)): \(Log.describe(error))")
        }
    }

    // MARK: Shutdown

    /// Saves the open tabs, closes every window, writes pending history, and drops this
    /// session's reference to the data store so that WebKit can release the store's network
    /// session (precondition for sealing it).
    func shutDown() {
        guard !isClosing else { return } // idempotent: window-close stop and lock/quit can both call this
        saveSessionState()
        isClosing = true
        downloads.cancelAll()
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
