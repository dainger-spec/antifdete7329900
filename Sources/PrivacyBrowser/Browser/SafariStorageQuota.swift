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
/// Persistent stores only. WebKit applies the ratio to the capacity of the volume a store's files
/// are on; a non-persistent store has none, so its quota would stay 1000 MiB whatever the ratio
/// (and lifting it with a capacity override would let one origin keep tens of gigabytes in memory).
/// Ephemeral profiles keep WebKit's default store and the shim.
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
        return ["initWithIdentifier:", "setOriginQuotaRatio:", "setTotalQuotaRatio:", "setStandardVolumeCapacity:",
                "isPersistent"].allSatisfy { configurationClass.instancesRespond(to: NSSelectorFromString($0)) }
            && WKWebsiteDataStore.instancesRespond(to: NSSelectorFromString("_initWithConfiguration:"))
    }

    /// A persistent data store with Safari's quota, under `identifier` (the same directories as
    /// `WKWebsiteDataStore(forIdentifier:)`). Nil without the SPI.
    static func makeStore(identifier: UUID, platform: DeviceGeneration.Platform) -> WKWebsiteDataStore? {
        guard isAvailable,
              let configuration = WebKitObjects.make("_WKWebsiteDataStoreConfiguration", "initWithIdentifier:", identifier as NSUUID)
        else { return nil }
        configuration.setValue(NSNumber(value: originRatio), forKey: "originQuotaRatio")
        configuration.setValue(NSNumber(value: totalRatio), forKey: "totalQuotaRatio")
        configuration.setValue(NSNumber(value: standardVolumeCapacity(for: platform)), forKey: "standardVolumeCapacity")
        // `--page-speed` only: one of the store's settings changed to measure it (empty otherwise).
        MeasurementFactors.apply(MeasurementFactors.storeSettings, to: configuration)
        return WebKitObjects.make(WKWebsiteDataStore.self, "_initWithConfiguration:", configuration) as? WKWebsiteDataStore
    }

    /// `store` reports Safari's quota for `platform` in every scope: a persistent store made with its
    /// ratio and standard volume (a store handed back by WebKit keeps the configuration it was made with).
    static func isApplied(to store: WKWebsiteDataStore, platform: DeviceGeneration.Platform) -> Bool {
        guard isAvailable, store.responds(to: NSSelectorFromString("_configuration")),
              let configuration = store.value(forKey: "_configuration") as? NSObject else { return false }
        return (configuration.value(forKey: "persistent") as? NSNumber)?.boolValue == true
            && (configuration.value(forKey: "originQuotaRatio") as? NSNumber)?.doubleValue == originRatio
            && (configuration.value(forKey: "standardVolumeCapacity") as? NSNumber)?.uint64Value == standardVolumeCapacity(for: platform)
    }
}
