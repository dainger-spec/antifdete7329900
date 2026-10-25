import Foundation

/// How a base-image update relates to existing profiles.
///
/// A profile's VM is an independent `tart clone` of the base taken at creation
/// time. Pulling a newer base into Tart's cache does NOT change those clones —
/// there is no in-place migration. So the honest policy is: new profiles pick
/// up the new base; to put an existing profile on it you recreate the profile
/// (which resets its VM state). We surface that rather than pretend to migrate.
///
/// Whether `:latest` has actually moved is answered by an OCI registry digest
/// check (OCIReference + RegistryClient): the app compares the digest recorded
/// at the last pull with the registry's current one, so "update available" is a
/// fact, not a guess. The pull itself stays a manual action.
/// Whether a newer base image is available, from comparing the recorded
/// (last-pulled) digest with the registry's current one.
public enum BaseUpdateState: Equatable, Sendable {
    case upToDate
    case updateAvailable
    case unknown   // never pulled via the app, or the registry couldn't be read
}

public enum BaseImagePolicy {
    /// Compare the digest we recorded at last pull with the registry's current
    /// one. Unknown unless we have both.
    public static func updateState(stored: String?, remote: String?) -> BaseUpdateState {
        guard let remote, !remote.isEmpty, let stored, !stored.isEmpty else { return .unknown }
        return stored == remote ? .upToDate : .updateAvailable
    }

    /// Profiles whose recorded base image differs from the current default —
    /// i.e. candidates for recreation onto the current base.
    public static func profilesOnOtherBase(_ profiles: [Profile], currentBase: String) -> [Profile] {
        profiles.filter { $0.baseImage != currentBase }
    }

    /// User-facing explanation of the no-auto-migration reality.
    public static let migrationNote =
        "Обновление базы скачивает свежий образ для новых профилей. "
        + "Существующие профили — независимые копии: чтобы перевести их на новый образ, "
        + "пересоздайте профиль (его текущее состояние при этом сбросится)."
}
