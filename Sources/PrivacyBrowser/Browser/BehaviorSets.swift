import BrowserCore
import WebKit

/// Maps a profile's device generation to the injected-script behaviour set it uses.
///
/// This is the forward-looking extension point for the version-aware system. Today every
/// generation resolves to the same WebKit shims (`PrivacyScripts`): with the current public
/// API the observable behaviour is the same whatever OS version the profile declares, so there
/// is nothing honest to vary yet.
///
/// When a future Apple/WebKit version ships behaviours worth matching (and public API to do it),
/// add a builder here and point new `DeviceGeneration`s at it via `behaviorSetID`. The profile
/// format and the rest of the app don't change. This deliberately does NOT inject per-version
/// spoofing of engine signals (canvas, WebGL, audio, feature presence): that is unreliable and
/// detectable — see docs/ISOLATION_AND_LIMITATIONS.md §2. Mobile platforms only get their device
/// class's navigator and screen values (see `PrivacyScripts`).
@MainActor
enum BehaviorSets {
    /// `timeZoneByEngine`: the profile's process pool already runs in its time zone;
    /// `storageQuotaByEngine`: its data store already reports Safari's quota (`BrowserSession`).
    static func makeUserContentController(for configuration: ProfileConfiguration, timeZoneByEngine: Bool = false,
                                          storageQuotaByEngine: Bool = false) -> WKUserContentController {
        switch configuration.deviceGeneration.behaviorSetID {
        case DeviceGenerations.desktopBehavior, DeviceGenerations.mobileBehavior:
            return PrivacyScripts.makeUserContentController(for: configuration, timeZoneByEngine: timeZoneByEngine,
                                                            storageQuotaByEngine: storageQuotaByEngine)
        default:
            // Unknown behaviour set (e.g. a profile from a newer build): fall back to the shims.
            return PrivacyScripts.makeUserContentController(for: configuration, timeZoneByEngine: timeZoneByEngine,
                                                            storageQuotaByEngine: storageQuotaByEngine)
        }
    }
}
