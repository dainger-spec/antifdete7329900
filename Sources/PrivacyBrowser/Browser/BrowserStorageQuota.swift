import Foundation
import ObjectiveC
import os
import WebKit

/// How much of the disk WebKit lets sites store in a profile: a browser's share, as Safari gets it.
///
/// WebKit gives each origin a share of a *standard* volume capacity (128 GB on a Mac, whatever the
/// real disk: the figure is the same on every Mac) — 0.6 for a full web browser, 0.15 for any
/// other app — and 0.8 or 0.2 to all origins together (`WebsiteDataStore::defaultOriginQuotaRatio`,
/// `defaultTotalQuotaRatio`). A site reads its share in `navigator.storage.estimate().quota`:
/// 82 463 372 084 in Safari, 20 615 843 021 in a profile's persistent store until this (measured,
/// CI run 429). A store made from a configuration with the browser's ratios answers Safari's figure
/// itself — WebKit's own computation, no script (docs/ISOLATION_AND_LIMITATIONS.md §2, *Parity with
/// Safari*). `_WKWebsiteDataStoreConfiguration` and `-[WKWebsiteDataStore _initWithConfiguration:]`
/// are private: a WebKit without them gets the store `WKWebsiteDataStore(forIdentifier:)` makes.
@MainActor
enum BrowserStorageQuota {
    /// A full web browser's ratios (`defaultBrowserOriginQuotaRatio`, `defaultBrowserTotalQuotaRatio`).
    static let originRatio = 0.6
    static let totalRatio = 0.8

    private static let log = Logger(subsystem: "PrivacyBrowser", category: "BrowserStorageQuota")

    /// Whether the last store was made with the browser's ratios (the self-test reads it).
    private(set) static var lastStoreHadBrowserRatios = false

    /// The persistent store of `identifier` — the directories `WKWebsiteDataStore(forIdentifier:)`
    /// uses — with the browser's ratios; nil when this WebKit cannot make one.
    static func persistentStore(identifier: UUID) -> WKWebsiteDataStore? {
        lastStoreHadBrowserRatios = false
        guard let configuration = makeConfiguration(identifier: identifier) else { return nil }
        let originKey = "originQuotaRatio", totalKey = "totalQuotaRatio"
        guard configuration.responds(to: NSSelectorFromString("setOriginQuotaRatio:")),
              configuration.responds(to: NSSelectorFromString("setTotalQuotaRatio:")) else {
            log.notice("This WebKit's data store configuration has no quota ratios: the default store")
            return nil
        }
        configuration.setValue(NSNumber(value: originRatio), forKey: originKey)
        configuration.setValue(NSNumber(value: totalRatio), forKey: totalKey)
        guard let store = makeStore(configuration) else { return nil }
        lastStoreHadBrowserRatios = true
        return store
    }

    /// `[[_WKWebsiteDataStoreConfiguration alloc] initWithIdentifier:identifier]`.
    private static func makeConfiguration(identifier: UUID) -> NSObject? {
        guard let configurationClass = NSClassFromString("_WKWebsiteDataStoreConfiguration") else { return nil }
        return allocateAndInitialize(configurationClass, initializer: "initWithIdentifier:", argument: identifier as NSUUID) as? NSObject
    }

    /// `[[WKWebsiteDataStore alloc] _initWithConfiguration:configuration]`.
    private static func makeStore(_ configuration: NSObject) -> WKWebsiteDataStore? {
        allocateAndInitialize(WKWebsiteDataStore.self, initializer: "_initWithConfiguration:", argument: configuration) as? WKWebsiteDataStore
    }

    /// `alloc` and an initializer that takes one object. `alloc` hands back its object retained,
    /// and an initializer consumes its receiver and hands back its result retained: the one
    /// reference goes from the first call into the second, and comes back to Swift from it.
    private static func allocateAndInitialize(_ cls: AnyClass, initializer: String, argument: AnyObject) -> AnyObject? {
        let allocSelector = NSSelectorFromString("alloc")
        let initSelector = NSSelectorFromString(initializer)
        guard let allocMethod = class_getClassMethod(cls, allocSelector),
              let initMethod = class_getInstanceMethod(cls, initSelector) else {
            log.notice("This WebKit lacks a data store configuration's initializer: the default store")
            return nil
        }
        typealias Alloc = @convention(c) (AnyClass, Selector) -> Unmanaged<AnyObject>
        typealias Initialize = @convention(c) (AnyObject, Selector, AnyObject) -> Unmanaged<AnyObject>?
        let allocated = unsafeBitCast(method_getImplementation(allocMethod), to: Alloc.self)(cls, allocSelector)
        let initialize = unsafeBitCast(method_getImplementation(initMethod), to: Initialize.self)
        return initialize(allocated.takeUnretainedValue(), initSelector, argument)?.takeRetainedValue()
    }
}
