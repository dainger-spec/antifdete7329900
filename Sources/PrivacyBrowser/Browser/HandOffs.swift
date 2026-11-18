import AppKit
import BrowserCore
import os
import WebKit

/// What a profile's page can be handed to outside the profile — another app, a system service
/// that fetches it as this Mac, the owner's other devices — closed wherever a profile's pages are
/// shown. Each of these is something the user does (force-click, a context-menu item, Share,
/// ⌘C), and each would take the profile's address or text out of its proxy and its encryption,
/// tied to the owner's own identity:
///
///   * A link preview (force-click, ⌃⌘D): Quick Look fetches the link itself, with no proxy, and
///     a click on the preview opens it in the default browser — the real Safari.
///   * The Services menu and "Search with Google" hand the selection to another app (the real
///     Safari searches it with the owner's own cookies).
///   * Share and Quick Note hand the address to the system's services. Measured (claude/measure-share,
///     run 42476723090, macOS 26.7.2 and 27.0.1): the share picker, only shown with an address,
///     fetches the page and its icons itself, with no proxy (LinkPresentation's
///     "facebookexternalhit" agent, and WebKit's networking process); Add to Reading List has the
///     real Safari fetch it; AirDrop, Freeform, Journal and Reminders fetch it for their preview;
///     Open in News hands it to Apple News; Messages, Mail and Notes fetched nothing on a runner
///     with no account in them, which says nothing of a Mac with one. Only Copy Link (ours) stays.
///   * In a profile's own process (Safari's chrome): opening an address in another app (a link
///     from a PDF, `webcal:`, "open in default browser"), Safari opening downloads by itself,
///     Universal Clipboard (a copy reaches the owner's iPhone), the recent-documents list (shared
///     by every profile), and a password Safari would keep in the owner's keychain.
@MainActor
enum HandOffs {
    private static let log = Logger(subsystem: "PrivacyBrowser", category: "HandOffs")

    /// Context-menu items that hand the page's content to something outside the profile, by the
    /// identifiers WebKit gives them.
    static let refusedMenuItems: Set<String> = [
        "WKMenuItemIdentifierSearchWeb", "WKMenuItemIdentifierLookUp", "WKMenuItemIdentifierTranslate",
        "WKMenuItemIdentifierShareMenu", "WKMenuItemIdentifierAddHighlightToNewQuickNote",
        "WKMenuItemIdentifierAddHighlightToCurrentQuickNote", "WKMenuItemIdentifierWritingTools",
    ]

    /// `menu` without those items (in submenus too), and without the contextual plug-ins and
    /// Services AppKit would add.
    static func strip(_ menu: NSMenu) -> NSMenu {
        menu.allowsContextMenuPlugIns = false
        for item in menu.items {
            if let identifier = item.identifier?.rawValue, refusedMenuItems.contains(identifier) {
                menu.removeItem(item)
            } else if let submenu = item.submenu {
                _ = strip(submenu)
            }
        }
        // No separator left at either end or twice in a row.
        while let first = menu.items.first, first.isSeparatorItem { menu.removeItem(first) }
        while let last = menu.items.last, last.isSeparatorItem { menu.removeItem(last) }
        var previousWasSeparator = false
        for item in menu.items {
            if item.isSeparatorItem && previousWasSeparator { menu.removeItem(item) }
            previousWasSeparator = item.isSeparatorItem
        }
        return menu
    }

    private static var webViewsClosed = false

    /// Every web view of this process: no link preview (the setter keeps it off), no Look Up of a
    /// link through Quick Look, and no Services for its selection. Once per process.
    static func closeForWebViews() {
        guard !webViewsClosed else { return }
        webViewsClosed = true
        typealias BoolSetter = @convention(c) (AnyObject, Selector, Bool) -> Void
        let preview = NSSelectorFromString("setAllowsLinkPreview:")
        if let method = class_getInstanceMethod(WKWebView.self, preview) {
            let original = unsafeBitCast(method_getImplementation(method), to: BoolSetter.self)
            let replacement: @convention(block) (AnyObject, Bool) -> Void = { webView, _ in
                original(webView, preview, false)
            }
            method_setImplementation(method, imp_implementationWithBlock(replacement))
        }
        if let method = class_getInstanceMethod(WKWebView.self, NSSelectorFromString("quickLookWithEvent:")) {
            let replacement: @convention(block) (AnyObject, AnyObject?) -> Void = { _, _ in }
            method_setImplementation(method, imp_implementationWithBlock(replacement))
        }
        if let method = class_getInstanceMethod(WKWebView.self, NSSelectorFromString("validRequestorForSendType:returnType:")) {
            let replacement: @convention(block) (AnyObject, AnyObject?, AnyObject?) -> AnyObject? = { _, _, _ in nil }
            method_setImplementation(method, imp_implementationWithBlock(replacement))
        }
    }

    /// What `closeForProfileProcess` refused, by kind (the network report).
    private(set) static var refused: [String: Int] = [:]

    /// The rest, in a profile's own process, where the chrome is Safari's and so are its menus,
    /// its downloads and its sharing.
    static func closeForProfileProcess() {
        closeForWebViews()
        var arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        arguments["NSRecentDocumentsLimit"] = 0
        UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)

        let workspace: AnyClass = NSWorkspace.self
        // Another app gets nothing but a file: a link, a `webcal:` subscription or an address for
        // the default browser would be fetched there, as this Mac.
        func handsOff(_ url: URL?) -> Bool {
            guard let url, !url.isFileURL else { return false }
            refused["open", default: 0] += 1
            log.notice("An address was not handed to another app")
            return true
        }
        let openURL = NSSelectorFromString("openURL:")
        if let method = class_getInstanceMethod(workspace, openURL) {
            typealias Open = @convention(c) (AnyObject, Selector, NSURL?) -> Bool
            let original = unsafeBitCast(method_getImplementation(method), to: Open.self)
            let replacement: @convention(block) (AnyObject, NSURL?) -> Bool = { receiver, url in
                handsOff(url as URL?) ? false : original(receiver, openURL, url)
            }
            method_setImplementation(method, imp_implementationWithBlock(replacement))
        }
        typealias Completion = @convention(block) (AnyObject?, NSError?) -> Void
        let refusal = NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)
        let openConfigured = NSSelectorFromString("openURL:configuration:completionHandler:")
        if let method = class_getInstanceMethod(workspace, openConfigured) {
            typealias Open = @convention(c) (AnyObject, Selector, NSURL?, AnyObject?, Completion?) -> Void
            let original = unsafeBitCast(method_getImplementation(method), to: Open.self)
            let replacement: @convention(block) (AnyObject, NSURL?, AnyObject?, Completion?) -> Void = { receiver, url, configuration, completion in
                if handsOff(url as URL?) { completion?(nil, refusal) } else { original(receiver, openConfigured, url, configuration, completion) }
            }
            method_setImplementation(method, imp_implementationWithBlock(replacement))
        }
        let openWithApp = NSSelectorFromString("openURLs:withApplicationAtURL:configuration:completionHandler:")
        if let method = class_getInstanceMethod(workspace, openWithApp) {
            typealias Open = @convention(c) (AnyObject, Selector, NSArray?, NSURL?, AnyObject?, Completion?) -> Void
            let original = unsafeBitCast(method_getImplementation(method), to: Open.self)
            let replacement: @convention(block) (AnyObject, NSArray?, NSURL?, AnyObject?, Completion?) -> Void = { receiver, urls, application, configuration, completion in
                if ((urls as? [URL]) ?? []).contains(where: { handsOff($0) }) {
                    completion?(nil, refusal)
                } else {
                    original(receiver, openWithApp, urls, application, configuration, completion)
                }
            }
            method_setImplementation(method, imp_implementationWithBlock(replacement))
        }

        // Sharing: no service is offered, and none performs.
        if let method = class_getClassMethod(NSSharingService.self, NSSelectorFromString("sharingServicesForItems:")) {
            let replacement: @convention(block) (AnyObject, AnyObject?) -> NSArray = { _, _ in
                refused["share", default: 0] += 1
                return []
            }
            method_setImplementation(method, imp_implementationWithBlock(replacement))
        }
        for (owner, name) in [(NSSharingService.self as AnyClass, "performWithItems:"),
                              (NSSharingServicePicker.self as AnyClass, "showRelativeToRect:ofView:preferredEdge:")] {
            guard let method = class_getInstanceMethod(owner, NSSelectorFromString(name)) else { continue }
            if name.hasPrefix("show") {
                let replacement: @convention(block) (AnyObject, NSRect, AnyObject?, UInt) -> Void = { _, _, _, _ in
                    refused["share", default: 0] += 1
                }
                method_setImplementation(method, imp_implementationWithBlock(replacement))
            } else {
                let replacement: @convention(block) (AnyObject, AnyObject?) -> Void = { _, _ in
                    refused["share", default: 0] += 1
                }
                method_setImplementation(method, imp_implementationWithBlock(replacement))
            }
        }

        // Universal Clipboard: what is copied here stays on this Mac.
        let clear = NSSelectorFromString("clearContents")
        if let method = class_getInstanceMethod(NSPasteboard.self, clear) {
            typealias Clear = @convention(c) (AnyObject, Selector) -> Int
            let original = unsafeBitCast(method_getImplementation(method), to: Clear.self)
            let replacement: @convention(block) (AnyObject) -> Int = { pasteboard in
                guard let pasteboard = pasteboard as? NSPasteboard, pasteboard.name == .general,
                      Thread.current.threadDictionary["PBClearingLocally"] == nil else {
                    return original(pasteboard, clear)
                }
                Thread.current.threadDictionary["PBClearingLocally"] = true
                defer { Thread.current.threadDictionary["PBClearingLocally"] = nil }
                refused["clipboard", default: 0] += 1
                return pasteboard.prepareForNewContents(with: .currentHostOnly)
            }
            method_setImplementation(method, imp_implementationWithBlock(replacement))
        }

        // Recent documents (shared by every profile, in the real home).
        for name in ["noteNewRecentDocumentURL:", "noteNewRecentDocument:"] {
            guard let method = class_getInstanceMethod(NSDocumentController.self, NSSelectorFromString(name)) else { continue }
            let replacement: @convention(block) (AnyObject, AnyObject?) -> Void = { _, _ in }
            method_setImplementation(method, imp_implementationWithBlock(replacement))
        }

        // A password remembered here is for this session only: a permanent or synchronized one
        // would go to the owner's keychain, outside the vault, and to their other devices.
        closePermanentCredentials()

        // A text field's "Search with Google" searches in the profile.
        keepWebSearchInProfile()
    }

    /// WebKit's own identifier of its "Search with Google" item.
    static let webSearchItem = "WKMenuItemIdentifierSearchWeb"

    /// WebKit's own "Search with Google" — the item a text field's menu has; a page's selected text
    /// gets Safari's own search item instead — hands the selection to the system's search service,
    /// which the real Safari provides. Chosen in a profile's Safari window, it brought the real
    /// Safari to the front to search there, with the owner's own cookies and outside the profile's
    /// proxy, and the window stopped for three seconds meanwhile (the sweep with real input, CI run
    /// 43999545658, macOS 26.7.2). It searches in the profile instead — in a new tab, with the
    /// profile's engine, as Safari's own item does — and its title names that engine.
    private static func keepWebSearchInProfile() {
        guard let menuTarget = NSClassFromString("WKMenuTarget") else {
            log.notice("No WKMenuTarget in this WebKit: its Search with Google is not looked at")
            return
        }
        let selector = NSSelectorFromString("forwardContextMenuAction:")
        guard let method = class_getInstanceMethod(menuTarget, selector) else { return }
        typealias Forward = @convention(c) (AnyObject, Selector, AnyObject?) -> Void
        let original = unsafeBitCast(method_getImplementation(method), to: Forward.self)
        let replacement: @convention(block) (AnyObject, AnyObject?) -> Void = { target, sender in
            guard (sender as? NSMenuItem)?.identifier?.rawValue == HandOffs.webSearchItem else {
                original(target, selector, sender)
                return
            }
            refused["search", default: 0] += 1
            log.notice("Search with the system's provider: searched in the profile, not handed to another app")
            HandOffs.searchSelectionInProfile()
        }
        method_setImplementation(method, imp_implementationWithBlock(replacement))
        // As the menu opens, before it is drawn (posted on the main thread, as tracking begins).
        _ = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil) { note in
            guard let menu = note.object as? NSMenu, Thread.isMainThread else { return }
            MainActor.assumeIsolated { HandOffs.nameProfileEngine(in: menu) }
        }
    }

    /// Names the system's search providers go by in WebKit's item.
    private static let providerNames = ["Google", "Bing", "Yahoo", "DuckDuckGo", "Ecosia", "Yandex", "Яндекс", "Baidu"]

    /// WebKit's item says the system's provider ("Search with Google"): it says the profile's engine.
    static func nameProfileEngine(in menu: NSMenu) {
        guard SafariChromeHost.isHosting,
              let item = menu.items.first(where: { $0.identifier?.rawValue == webSearchItem }) else { return }
        let engine = SafariChrome.profileSearchEngine.name
        guard let shown = providerNames.first(where: { item.title.contains($0) }), shown != engine else { return }
        item.title = item.title.replacingOccurrences(of: shown, with: engine)
    }

    /// The selection of the page in front — a text field's, or the page's — searched with the
    /// profile's engine in a new tab of its window.
    static func searchSelectionInProfile() {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow, let page = SafariChromeHost.frontPage(in: window) else { return }
        let script = "const e = document.activeElement; "
            + "if (e && typeof e.selectionStart === 'number' && typeof e.value === 'string') { return e.value.substring(e.selectionStart, e.selectionEnd); } "
            + "return String(window.getSelection());"
        page.callAsyncJavaScript(script, arguments: [:], in: nil, in: .defaultClient) { result in
            guard case .success(let value) = result, let text = value as? String,
                  let address = WebAddress.searchURL(for: text, engine: SafariChrome.profileSearchEngine) else { return }
            Task { @MainActor in _ = await SafariTabs.openTab(address, in: window) }
        }
    }

    private static func closePermanentCredentials() {
        func sessionOnly(_ persistence: UInt) -> UInt {
            persistence == URLCredential.Persistence.permanent.rawValue || persistence == URLCredential.Persistence.synchronizable.rawValue
                ? URLCredential.Persistence.forSession.rawValue : persistence
        }
        let initializer = NSSelectorFromString("initWithUser:password:persistence:")
        if let method = class_getInstanceMethod(URLCredential.self, initializer) {
            typealias Initializer = @convention(c) (AnyObject, Selector, NSString?, NSString?, UInt) -> Unmanaged<AnyObject>?
            let original = unsafeBitCast(method_getImplementation(method), to: Initializer.self)
            let replacement: @convention(block) (AnyObject, NSString?, NSString?, UInt) -> Unmanaged<AnyObject>? = { receiver, user, password, persistence in
                original(receiver, initializer, user, password, sessionOnly(persistence))
            }
            method_setImplementation(method, imp_implementationWithBlock(replacement))
        }
        let factory = NSSelectorFromString("credentialWithUser:password:persistence:")
        if let method = class_getClassMethod(URLCredential.self, factory) {
            typealias Factory = @convention(c) (AnyObject, Selector, NSString?, NSString?, UInt) -> Unmanaged<AnyObject>?
            let original = unsafeBitCast(method_getImplementation(method), to: Factory.self)
            let replacement: @convention(block) (AnyObject, NSString?, NSString?, UInt) -> Unmanaged<AnyObject>? = { cls, user, password, persistence in
                original(cls, factory, user, password, sessionOnly(persistence))
            }
            method_setImplementation(method, imp_implementationWithBlock(replacement))
        }
    }
}
