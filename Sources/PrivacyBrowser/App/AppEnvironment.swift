import Foundation

/// Facts about the running process that change storage locations.
enum AppEnvironment {
    /// True when running inside the App Sandbox. The kernel sets `APP_SANDBOX_CONTAINER_ID`
    /// for sandboxed processes; all `FileManager` user-domain URLs then point into
    /// `~/Library/Containers/<bundle-id>/Data/`.
    static var isSandboxed: Bool {
        ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
    }

    /// Default vault location: `<Application Support>/PrivacyBrowser`, i.e.
    /// `~/Library/Application Support/PrivacyBrowser` (not sandboxed) or
    /// `~/Library/Containers/<bundle-id>/Data/Library/Application Support/PrivacyBrowser`.
    /// `PRIVACYBROWSER_VAULT_DIR` overrides it (inside the sandbox only paths in the container
    /// are writable).
    static var vaultDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["PRIVACYBROWSER_VAULT_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PrivacyBrowser", isDirectory: true)
    }
}
