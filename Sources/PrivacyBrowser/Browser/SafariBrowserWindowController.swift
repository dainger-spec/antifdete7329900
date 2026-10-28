import AppKit
import SafariBridge
import WebKit

/// Experimental (profile setting `useSafariChrome`, unsandboxed build only): a profile's first
/// window as Safari's own browser window from Safari.framework, instead of this app's.
///
/// Safari's window is kept only when every tab in it uses this profile's data store (its cookies,
/// storage and proxy) and its user content controller (the fingerprint and WebRTC shims, AutoFill,
/// the ping-load blocker). Otherwise it is closed again and `init` throws, with the reason, so the
/// caller opens the usual window: a window on Safari's own data store would run outside the
/// profile's isolation and proxy. See docs/SAFARI_FRAMEWORK_PATH.md.
@MainActor
final class SafariBrowserWindowController {
    struct Unavailable: Error, CustomStringConvertible {
        let description: String
    }

    private let controller: NSWindowController
    private var closeObserver: NSObjectProtocol?
    private let onClose: (SafariBrowserWindowController) -> Void

    var window: NSWindow? { controller.window }

    init(profileName: String, dataStore: WKWebsiteDataStore, userContentController: WKUserContentController,
         url: URL?, onClose: @escaping (SafariBrowserWindowController) -> Void) throws {
        guard !AppEnvironment.isSandboxed else {
            throw Unavailable(description: "the sandboxed build does not load Safari.framework")
        }
        let controller: NSWindowController
        do {
            try PBSafariBridge.loadFramework()
            controller = try PBSafariBridge.makeWindowController()
        } catch {
            throw Unavailable(description: error.localizedDescription)
        }
        // Offered for Safari to pick up; whether its tabs use it is what the check below finds out.
        try? PBSafariBridge.set(dataStore, forKey: "websiteDataStore", of: controller)
        let webViews = controller.window.map { Self.webViews(in: $0.contentView) } ?? []
        let mismatch: String?
        if controller.window == nil {
            mismatch = "Safari's window controller has no window"
        } else if webViews.isEmpty {
            mismatch = "Safari's window has no web view"
        } else if !webViews.allSatisfy({ $0.configuration.websiteDataStore === dataStore }) {
            mismatch = "Safari's tabs do not use this profile's data store (cookies, storage, proxy)"
        } else if !webViews.allSatisfy({ $0.configuration.userContentController === userContentController }) {
            mismatch = "Safari's tabs do not run this profile's scripts (fingerprint and WebRTC shims, AutoFill)"
        } else {
            mismatch = nil
        }
        if let mismatch {
            try? PBSafariBridge.close(controller)
            throw Unavailable(description: mismatch)
        }

        self.controller = controller
        self.onClose = onClose
        let window = controller.window!
        Self.applyShell(to: window, title: profileName)
        closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window,
                                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.windowWillClose() }
        }
        if let url { webViews[0].load(URLRequest(url: url)) }
        do {
            try PBSafariBridge.show(controller)
        } catch {
            close()
            throw Unavailable(description: "showing Safari's window: \(error.localizedDescription)")
        }
    }

    func close() {
        try? PBSafariBridge.close(controller)
    }

    private func windowWillClose() {
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        closeObserver = nil
        // As BrowserWindowController: report on the next run-loop turn, once AppKit has finished
        // closing the window this object keeps alive.
        DispatchQueue.main.async { [self] in onClose(self) }
    }

    private static func webViews(in view: NSView?) -> [WKWebView] {
        guard let view else { return [] }
        if let webView = view as? WKWebView { return [webView] }
        return view.subviews.flatMap { webViews(in: $0) }
    }

    /// Safari's window as a bare browser shell. Window-scoped only: the app's other windows (Profiles,
    /// other profiles) keep their Dock icon and menu bar, and the window stays titled underneath,
    /// so it can still become key and take typing in its address field.
    private static func applyShell(to window: NSWindow, title: String) {
        window.title = title
        window.styleMask.insert(.fullSizeContentView)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }
}
