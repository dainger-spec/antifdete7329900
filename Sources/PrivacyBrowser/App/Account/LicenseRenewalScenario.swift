import AppKit
import BrowserCore
import Foundation

/// `Lumen --selftest-license-renewal`: the license's renewals as the app's own model makes them, for
/// the "profiles" phase of scripts/license_renewal_check.py — a vault with three profiles opened
/// with its password through `AppModel.unlock` (the lock screen's way), then a fourth profile made
/// through `AppModel.createProfile` (New Profile's). The stand-in server the script runs must be
/// told 3, then 4: the real number, never the 0 a vault not yet opened would say (the owner,
/// 3 November: `profile_count = 0` with three profiles made).
///
/// Only with `PB_SELFTEST_LICENSE_RENEWAL=1` and a vault folder of its own
/// (`PRIVACYBROWSER_VAULT_DIR`) that holds no vault yet: it makes one there.
@MainActor
enum LicenseRenewalScenario {
    static let password = "license-renewal-check"

    static func start() {
        setvbuf(stdout, nil, _IOLBF, 0)
        let environment = ProcessInfo.processInfo.environment
        guard environment["PB_SELFTEST_LICENSE_RENEWAL"] == "1",
              let folder = environment["PRIVACYBROWSER_VAULT_DIR"], !folder.isEmpty else {
            print("LICENSE-RENEWAL usage: scripts/license_renewal_check.py runs this, with PB_SELFTEST_LICENSE_RENEWAL=1 "
                + "and a vault folder of its own in PRIVACYBROWSER_VAULT_DIR")
            exit(64)
        }
        let root = AppEnvironment.vaultDirectory
        guard !MasterVault.exists(in: root) else {
            print("LICENSE-RENEWAL FAIL a vault is already in its folder: this scenario makes its own")
            exit(1)
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        DispatchQueue.main.asyncAfter(deadline: .now() + 150) {
            print("LICENSE-RENEWAL FAIL no end in 150 s")
            exit(3)
        }
        Task { @MainActor in
            do {
                let repository = try ProfileRepository(vault: MasterVault.create(in: root, password: password, iterations: 10_000))
                for number in 1...3 {
                    _ = try repository.create(name: "Renewal \(number)", configuration: ProfileConfiguration())
                }
                print("LICENSE-RENEWAL a vault with 3 profiles made")
                // The app's own model, as a start makes it: its license renews at once, with the last
                // number known — the vault is not open yet.
                let model = AppModel()
                print("LICENSE-RENEWAL the app's model started, its vault \(model.phase == .locked ? "locked" : "not locked")")
                try await Task.sleep(nanoseconds: 6_000_000_000)
                await model.unlock(password: password)
                print("LICENSE-RENEWAL unlocked: \(model.profiles.count) profiles")
                try await Task.sleep(nanoseconds: 8_000_000_000)
                _ = try model.createProfile(name: "Renewal 4", configuration: ProfileConfiguration())
                print("LICENSE-RENEWAL a fourth profile made: \(model.profiles.count) profiles")
                try await Task.sleep(nanoseconds: 8_000_000_000)
                print("LICENSE-RENEWAL done")
                exit(0)
            } catch {
                print("LICENSE-RENEWAL FAIL \(error)")
                exit(1)
            }
        }
        app.run()
    }
}
