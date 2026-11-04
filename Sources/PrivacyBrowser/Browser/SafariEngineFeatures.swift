import Foundation
import WebKit

/// The WebKit features whose default follows the SDK an app declares, set in every web view of a
/// profile as Safari has them.
///
/// WebKit gives Safari every behavior aligned with an SDK (WTF's `computeSDKAlignedBehaviors`).
/// This app's executables declare 14.0, which Xcode 27's SwiftPM writes; declaring 15.0 or newer,
/// or turning every behavior on (`SDKBehaviors`), has this Mac fetch a certificate's missing
/// intermediate outside a profile's proxy on macOS 27 (docs/ISOLATION_AND_LIMITATIONS.md). For a
/// build declaring 14.0, those behaviors change four of WebKit's features, on macOS 26 and 27 alike
/// (CI runs 495, 497 and 500): Safari has Trusted Types on, and DOM mutation events, the legacy
/// `FontFaceSet` constructor and the near-suspended assertions on background web content processes
/// off. Set here one by one with WebKit's own switches, a page sees what it sees with every behavior
/// on — and what the real Safari 26.6.2 and 27.0.1 show it, but for the names only Safari's
/// entitlements and Safari itself bring — while this Mac asks for no certificate outside the proxy
/// (run 497: the AIA canary unasked for twice with the four set, asked for with every behavior on).
///
/// Only on the macOS versions measured; on another, WebKit's defaults are left as they are, and
/// CI's check says what differs (`scripts/engine_features_check.py`).
@MainActor
enum SafariEngineFeatures {
    /// The macOS versions (major) the table was measured on.
    static let measured: Set<Int> = [26, 27]

    /// Each feature, by key, as Safari has it.
    static let asSafari: [(key: String, enabled: Bool)] = [
        ("TrustedTypesEnabled", true),
        ("MutationEventsEnabled", false),
        ("FontFaceSetConstructorEnabled", false),
        ("ShouldTakeNearSuspendedAssertions", false),
    ]

    /// Whether this macOS is one the table was measured on.
    static var appliesHere: Bool {
        measured.contains(ProcessInfo.processInfo.operatingSystemVersion.majorVersion)
    }

    static func apply(to preferences: WKPreferences) {
        guard appliesHere else { return }
        for (key, enabled) in asSafari {
            WebKitFeatures.set(preferences, key, enabled)
        }
    }
}
