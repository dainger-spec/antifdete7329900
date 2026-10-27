import BrowserCore
import Foundation
import WebKit

/// Safari's storage quota for a profile's data store, set in WebKit where it allows it.
///
/// WebKit sizes an origin's storage by the app it runs in (`NetworkStorageManager::
/// originQuotaManagerParameters`). Safari, a browser to WebKit, gets 60 % of the volume per origin
/// (80 % in all) and `navigator.storage.estimate()` reports 60 % of a *standard* volume — 128 GB on a
/// Mac, 64 GB on iOS — whatever the real disk: 82 463 372 084 on every Mac. Any other app gets a fixed
/// 1000 MiB per origin, the small quota private-mode detectors look for (a tenth of either in a
/// third-party frame). `_WKWebsiteDataStoreConfiguration` (SPI, macOS 14+) takes the ratios and the
/// standard capacity, so a profile's pages, all its workers and its service workers report Safari's
/// figure as the engine's own, and can store as much as in Safari.
///
/// PLATFORM LIMITATION: private API, used only where present. Without it the store is WebKit's
/// default and the shim reports Safari's figure in pages and blob workers (`PrivacyScripts`).
@MainActor
enum SafariStorageQuota {
    /// WebKit's ratios for a browser (`WebsiteDataStoreCocoa.mm`: defaultBrowserOriginQuotaRatio,
    /// defaultBrowserTotalQuotaRatio).
    static let originRatio = 0.6
    static let totalRatio = 0.8

    /// The volume WebKit reports quotas of (`WebsiteDataStore::defaultStandardVolumeCapacity`).
    static func standardVolumeCapacity(for platform: DeviceGeneration.Platform) -> UInt64 {
        let gigabyte: UInt64 = 1024 * 1024 * 1024
        return platform == .macOS ? 128 * gigabyte : 64 * gigabyte
    }

    private static let configurationClass = NSClassFromString("_WKWebsiteDataStoreConfiguration") as? NSObject.Type

    /// This WebKit can give a data store Safari's quota.
    static var isAvailable: Bool {
        guard let configurationClass else { return false }
        return ["initWithIdentifier:", "initNonPersistentConfiguration", "setOriginQuotaRatio:", "setTotalQuotaRatio:",
                "setStandardVolumeCapacity:"].allSatisfy { configurationClass.instancesRespond(to: NSSelectorFromString($0)) }
            && WKWebsiteDataStore.instancesRespond(to: NSSelectorFromString("_initWithConfiguration:"))
    }

    /// A data store with Safari's quota: persistent under `identifier` (the same directories as
    /// `WKWebsiteDataStore(forIdentifier:)`), non-persistent without one. Nil without the SPI.
    static func makeStore(identifier: UUID?, platform: DeviceGeneration.Platform) -> WKWebsiteDataStore? {
        guard isAvailable else { return nil }
        let configuration = identifier.map { WebKitObjects.make("_WKWebsiteDataStoreConfiguration", "initWithIdentifier:", $0 as NSUUID) }
            ?? WebKitObjects.make("_WKWebsiteDataStoreConfiguration", "initNonPersistentConfiguration")
        guard let configuration else { return nil }
        configuration.setValue(NSNumber(value: originRatio), forKey: "originQuotaRatio")
        configuration.setValue(NSNumber(value: totalRatio), forKey: "totalQuotaRatio")
        configuration.setValue(NSNumber(value: standardVolumeCapacity(for: platform)), forKey: "standardVolumeCapacity")
        return WebKitObjects.make(WKWebsiteDataStore.self, "_initWithConfiguration:", configuration) as? WKWebsiteDataStore
    }

    /// `store` was made with Safari's quota (it reports it in every scope; self-test and the shim).
    static func isApplied(to store: WKWebsiteDataStore) -> Bool {
        guard store.responds(to: NSSelectorFromString("_configuration")),
              let configuration = store.value(forKey: "_configuration") as? NSObject,
              configuration.responds(to: NSSelectorFromString("originQuotaRatio")) else { return false }
        return (configuration.value(forKey: "originQuotaRatio") as? NSNumber)?.doubleValue == originRatio
    }
}
