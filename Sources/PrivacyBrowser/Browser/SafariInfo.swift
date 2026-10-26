import BrowserCore
import Foundation

/// The version of Safari installed on this Mac, for the "Safari for Mac" user agent: WKWebView's
/// default UA lacks Safari's "Version/x Safari/605.1.15" suffix, and with it every profile sends
/// exactly the UA Safari itself sends on this Mac. Detection (reading Safari's Info.plist, with a
/// per-macOS fallback) lives in `SafariVersion` so the core can test it; this caches the result
/// and logs whether it is the real version or the fallback estimate.
enum SafariInfo {
    static let version: SafariVersion = {
        let detection = SafariVersion.detection()
        if detection.isFallback {
            Log.notice("ua", "Safari Info.plist not readable; using the macOS fallback estimate \(detection.version.string)")
        } else {
            Log.info("ua", "Safari \(detection.version.string)")
        }
        return detection.version
    }()
}
