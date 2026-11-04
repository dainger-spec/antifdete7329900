import AppKit
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
///   * Share and Quick Note hand the address to Messages, Mail, AirDrop or Notes, which fetch it
///     for a preview, as this Mac, and keep it in the owner's iCloud.
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
