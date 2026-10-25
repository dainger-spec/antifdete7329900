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
/// spoofing of engine or hardware signals (navigator, canvas, WebGL, feature presence): that is
/// unreliable, detectable, and its main use is evading detection — see
/// docs/ISOLATION_AND_LIMITATIONS.md §2.
@MainActor
enum BehaviorSets {
    static func makeUserContentController(for configuration: ProfileConfiguration) -> WKUserContentController {
        switch configuration.deviceGeneration.behaviorSetID {
        case DeviceGenerations.desktopBehavior, DeviceGenerations.mobileBehavior:
            return PrivacyScripts.makeUserContentController(for: configuration)
        default:
            // Unknown behaviour set (e.g. a profile from a newer build): fall back to the shims.
            return PrivacyScripts.makeUserContentController(for: configuration)
        }
    }
}
