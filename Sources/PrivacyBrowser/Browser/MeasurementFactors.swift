import Foundation

/// Switches for `--page-speed` (PageSpeed.swift) only: each turns one part of a profile off, or one
/// WebKit setting on, so that its cost in page-load time can be measured. Nothing else sets them:
/// in every other mode they are empty and a profile is built exactly as without them.
enum MeasurementFactors {
    /// Parts of a profile left out:
    ///   "shims"        every document-start user script of PrivacyScripts;
    ///   "tzShim"       the shim's time zone part (and its check whether the engine reports the zone);
    ///   "toString"     the shim's Function.prototype.toString replacement;
    ///   "frameHooks"   the shim's hooks on child frames and windows (contentWindow, window.open);
    ///   "workerHooks"  the shim's rewriting of blob workers;
    ///   "autofill"     the password AutoFill script;
    ///   "fontAllowlist" an iPhone or iPad profile's font allowlist (its pool's);
    ///   "userFonts"    the switch that hides user-installed fonts (pages then see them, as in a WKWebView).
    /// And one part added: "contentRules", the ping-load list a profile with a proxy gets.
    static var changes: Set<String> = []
    /// `_WKProcessPoolConfiguration` keys set on a profile's own pool (e.g. "prewarmsProcessesAutomatically").
    static var poolSettings: [String: Bool] = [:]
    /// `_WKWebsiteDataStoreConfiguration` keys set on a persistent profile's store.
    static var storeSettings: [String: Bool] = [:]
    /// The shim notes which of its parts each window got, in `window[Symbol.for('pb.measurement')]`.
    static var traceShim = false

    static func has(_ change: String) -> Bool { changes.contains(change) }

    /// The shim's parts left out, in the names its `CONFIG.measurementOff` uses.
    static var shimPartsOff: [String] {
        ["tzShim", "toString", "frameHooks", "workerHooks"].filter(has)
    }

    /// Sets each BOOL key `object` has a setter for; returns the keys set.
    @discardableResult
    static func apply(_ settings: [String: Bool], to object: NSObject) -> [String] {
        settings.keys.sorted().filter { key in
            guard let first = key.first else { return false }
            let setter = "set" + first.uppercased() + key.dropFirst() + ":"
            return WebKitPreferences.setBool(object, setter, settings[key] ?? false)
        }
    }
}
