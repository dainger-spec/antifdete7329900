import AppKit
import Foundation
import ObjectiveC
import WebKit

/// Runtime surgery the framework window path needs, and nothing else.
///
/// **Binding the profile's data store.** `-[WKWebView configuration]` hands back a *copy*, so
/// assigning `websiteDataStore` on it after the view exists changes nothing the page will ever
/// see: WebKit read the store when the page was created and never looks again. The store has to
/// be in place before that, and the window's web views are built by the framework, out of
/// configurations we never touch. What every one of them does go through is
/// `-[WKWebViewConfiguration websiteDataStore]` — the getter WebKit itself calls while building
/// a page, and the getter that otherwise hands out the *default* store. Overriding it for the
/// span of one window's creation puts the profile's store in front of WebKit at the one moment
/// it is read, and keeps the default store from being instantiated at all.
///
/// A plain getter is also the safe thing to replace. An `init`-family method returns +1 while a
/// block returns +0, and a swizzle across that line miscounts the window controller's web view.
///
/// **Key window.** A borderless window is not key-capable unless its class says so, and a browser
/// shell that cannot take keystrokes is not a browser. `canBecomeKeyWindow` is overridden on the
/// framework's own window class, once, when shell mode is applied.
///
/// Both swizzles keep the original `IMP` and install a block, so nothing is exchanged onto a
/// shared superclass and no method is added to `NSObject`.
enum SafariHooks {
    /// Set only for the span of `bindDataStore(_:during:)`, on the main thread.
    private static var pendingDataStore: WKWebsiteDataStore?
    /// How often the getter was consulted while a store was bound, and what it handed back.
    private(set) static var observations: [String] = []
    private static var originalDataStoreGetter: IMP?
    private static var keyWindowForced: Set<String> = []

    private static let dataStoreSelector = NSSelectorFromString("websiteDataStore")

    // MARK: Data store binding

    /// Runs `body` with `store` standing in for every `WKWebViewConfiguration`'s data store.
    /// The substitution ends when `body` returns, so nothing outside this call ever sees a
    /// configuration it did not set up itself.
    @MainActor
    @discardableResult
    static func bindDataStore<T>(_ store: WKWebsiteDataStore?, during body: () -> T) -> T {
        guard store != nil, installDataStoreHook() else { return body() }
        pendingDataStore = store
        defer { pendingDataStore = nil }
        return body()
    }

    /// Clears the record before a window is built, so a report covers that window only.
    static func forgetObservations() {
        observations = []
    }

    /// Installs the getter override once. False when this WebKit has no such getter, which is
    /// the one case where the store cannot be bound at all.
    @discardableResult
    private static func installDataStoreHook() -> Bool {
        if originalDataStoreGetter != nil { return true }
        guard let method = class_getInstanceMethod(WKWebViewConfiguration.self, dataStoreSelector) else {
            NSLog("SafariHooks: -[WKWebViewConfiguration websiteDataStore] -> nil; no way to bind a store")
            return false
        }
        let block: @convention(block) (AnyObject) -> WKWebsiteDataStore? = { receiver in
            if let store = pendingDataStore {
                observations.append("websiteDataStore read on \(NSStringFromClass(type(of: receiver))) -> \(describe(store))")
                return store
            }
            // Outside a binding this must behave exactly as WebKit's own getter, including its
            // lazy creation of the default store.
            typealias Original = @convention(c) (AnyObject, Selector) -> WKWebsiteDataStore?
            guard let original = originalDataStoreGetter else { return nil }
            return unsafeBitCast(original, to: Original.self)(receiver, dataStoreSelector)
        }
        originalDataStoreGetter = method_setImplementation(method, imp_implementationWithBlock(block))
        NSLog("SafariHooks: bound -[WKWebViewConfiguration websiteDataStore]")
        return true
    }

    static func describe(_ store: WKWebsiteDataStore?) -> String {
        guard let store else { return "nil" }
        if let identifier = store.identifier { return "persistent \(identifier.uuidString)" }
        return store.isPersistent ? "persistent (default, no identifier)" : "non-persistent"
    }

    // MARK: Shell mode

    /// Accessory policy, borderless, floating. Applied only once a window exists; `undoShell`
    /// puts the process back the way it was when the window did not come up.
    @MainActor
    static func applyShell(to window: NSWindow) {
        NSApp.setActivationPolicy(.accessory)   // what takes the app out of the Dock
        forceKeyWindowCapable(type(of: window))
        window.styleMask.remove(.titled)
        window.styleMask.insert(.borderless)
        window.isMovableByWindowBackground = true
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        NSLog("SafariHooks: shell applied to \(NSStringFromClass(type(of: window)))")
    }

    /// Back to a regular app. Called on every failure path, so a window that never appeared
    /// cannot leave the process without a Dock tile or a menu bar.
    @MainActor
    static func undoShell() {
        NSApp.setActivationPolicy(.regular)
    }

    /// A borderless window refuses key status unless its class says otherwise, and the framework's
    /// window class is not ours to subclass.
    private static func forceKeyWindowCapable(_ windowClass: AnyClass) {
        let name = NSStringFromClass(windowClass)
        guard !keyWindowForced.contains(name) else { return }
        keyWindowForced.insert(name)
        let selector = NSSelectorFromString("canBecomeKeyWindow")
        let block: @convention(block) (AnyObject) -> Bool = { _ in true }
        let imp = imp_implementationWithBlock(block)
        guard let method = class_getInstanceMethod(windowClass, selector) else {
            NSLog("SafariHooks: canBecomeKeyWindow -> nil on \(name)")
            return
        }
        // Declared on NSWindow, so add an override on this class rather than replacing it there;
        // only windows of this class are affected.
        if !class_addMethod(windowClass, selector, imp, method_getTypeEncoding(method)) {
            method_setImplementation(method, imp)
        }
        NSLog("SafariHooks: \(name) canBecomeKeyWindow forced to true")
    }
}
