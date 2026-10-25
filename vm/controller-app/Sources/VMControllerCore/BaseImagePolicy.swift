import Foundation

/// How a base-image update relates to existing profiles.
///
/// A profile's VM is an independent `tart clone` of the base taken at creation
/// time. Pulling a newer base into Tart's cache does NOT change those clones —
/// there is no in-place migration. So the honest policy is: new profiles pick
/// up the new base; to put an existing profile on it you recreate the profile
/// (which resets its VM state). We surface that rather than pretend to migrate.
///
/// (Detecting that `:latest` actually moved needs an OCI registry digest check;
/// that's future work. The app offers a manual "pull latest base".)
public enum BaseImagePolicy {
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
