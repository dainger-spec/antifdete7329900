import BrowserCore
import Foundation

/// The version of Safari installed on this Mac, for the "Safari for Mac" user agent: WKWebView's
/// default UA lacks Safari's "Version/x Safari/605.1.15" suffix, and with it every profile sends
/// exactly the UA Safari itself sends on this Mac.
enum SafariInfo {
    /// Read once per launch. Safari lives in the system cryptex on macOS 13+; /Applications has a
    /// link to it. Both are world-readable, also from the App Sandbox. If neither can be read,
    /// fall back to the version that ships with this macOS release.
    static let version: SafariVersion = {
        let candidates = [
            "/Applications/Safari.app/Contents/Info.plist",
            "/System/Cryptexes/App/System/Applications/Safari.app/Contents/Info.plist",
            "/System/Volumes/Preboot/Cryptexes/App/System/Applications/Safari.app/Contents/Info.plist",
        ]
        for path in candidates {
            if let data = FileManager.default.contents(atPath: path), let version = SafariVersion.parse(infoPlist: data) {
                return version
            }
        }
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return SafariVersion.fallback(macOSMajor: os.majorVersion, minor: os.minorVersion)
    }()
}
