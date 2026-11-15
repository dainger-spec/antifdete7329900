import BrowserCore
import Foundation
import Security

/// The self-test's checks of unlocking with Touch ID that need this Mac (`--self-test`): its texts,
/// that it is absent where it cannot work, the key in the keychain, and that a profile's process
/// is not shown it. The rule itself — when Touch ID may open the vault, what ends it — is tested
/// without a Mac (BiometricUnlockTests).
///
/// Nothing here asks Touch ID, and no dialog is shown: the key is kept and looked for, never
/// read. Where the build cannot keep it (no application identifier: every ad hoc build, CI's) or
/// the Mac has no Touch ID with a fingerprint enrolled (a GitHub runner), the checks that need it
/// are skipped by name, with which of the two it was.
@MainActor
enum TouchIDChecks {
    enum Verdict {
        case pass
        case fail(String)
        /// Not made here: `inBuild` — because of how this build is signed, else because of this Mac.
        case skip(String, inBuild: Bool)
    }

    struct Result {
        let name: String
        let verdict: Verdict
    }

    static let keychainName = "touch id: the key for unlocking is kept in this Mac's data-protection keychain, "
        + "found there without a dialog, and removed"
    static let profileName = "touch id: a profile's process is not shown the key kept for unlocking, in either keychain — "
        + "the app sees its own (the control)"

    /// Why the checks that keep a key cannot be made here; nil when they can.
    private static var cannotKeep: Verdict? {
        guard TouchIDUnlock.buildCanKeepKey else {
            return .skip("this build's signature holds no application identifier, so this Mac's data-protection keychain "
                         + "does not open to it: unlocking with Touch ID is absent in it (a build signed with the "
                         + "provisioning profile has it)", inBuild: true)
        }
        guard TouchIDUnlock.sensor().sensor == .ready else {
            return .skip("this Mac has no Touch ID with a fingerprint enrolled, without which the keychain keeps no such item",
                         inBuild: false)
        }
        return nil
    }

    static func run() -> [Result] {
        var results: [Result] = []

        // Every text the lock screen and the setting can say, in every language of the interface.
        var keys = ["touchid.unlock", "touchid.reason", "touchid.prompt.cancel", "touchid.failed", "touchid.password.restarted",
                    "touchid.password.tooLong", "touchid.ended.passwordChanged", "touchid.ended.fingerprintsChanged",
                    "touchid.ended.anotherVault", "touchid.sensor.notEnrolled", "touchid.sensor.notNow", "touchid.on.title",
                    "touchid.on.fact.opens", "touchid.on.fact.kept", "touchid.on.fact.password", "touchid.on.action",
                    "touchid.on.keychain", "settings.security.touchID", "settings.security.touchID.detail",
                    "settings.security.touchID.kept", "unlock.keys.touchID"]
        keys.sort()
        var missing: [String] = []
        var tables = 0
        for language in Localization.supported {
            guard let text = UsabilityChecks.table(language) else { continue }
            tables += 1
            missing += keys.filter { text($0) == $0 }.map { "\(language): \($0)" }
        }
        // Each reason the password is asked has words of its own (none falls through to a key).
        let reasons = BiometricUnlock.PasswordReason.allCases.map { TouchIDText.passwordAsked($0) }
        results.append(Result(name: "touch id: every reason the master password is asked, and every text of the setting, is said in "
                              + "every language of the interface (\(keys.count) texts)",
                              verdict: tables == Localization.supported.count && missing.isEmpty && reasons.allSatisfy { !$0.hasPrefix("touchid.") }
                                  ? .pass : .fail("tables \(tables); missing \(missing.joined(separator: ", "))")))

        // Absent, not broken: where this copy on this Mac cannot offer it, nothing leads to it.
        let offered = TouchIDUnlock.isOfferedHere
        let searched = SettingsSearch.entries.contains { $0.titleKey == "settings.security.touchID" }
        let absent = TouchIDStatus()
        results.append(Result(name: "touch id: where it cannot work it is absent — not offered, not turned on, and the Settings search "
                              + "does not lead to it (offered here: \(offered ? "yes" : "no"))",
                              verdict: searched == offered && !absent.offered && !absent.isOn && !absent.unlocksNow
                                  && (offered || !TouchIDUnlock.buildCanKeepKey || TouchIDUnlock.sensor().sensor == .none)
                                  ? .pass : .fail("offered \(offered), searched \(searched), can keep \(TouchIDUnlock.buildCanKeepKey)")))

        // The key in the keychain: kept, found without a dialog, removed.
        if let cannot = cannotKeep {
            results.append(Result(name: keychainName, verdict: cannot))
        } else {
            let vault = UUID()
            let kept = TouchIDUnlock.keep(Data(repeating: 0xA5, count: 32), vaultID: vault)
            let found = TouchIDUnlock.isKept(vaultID: vault)
            let listed = TouchIDUnlock.keptAccounts().contains(vault.uuidString)
            let other = TouchIDUnlock.isKept(vaultID: UUID())
            let removed = TouchIDUnlock.remove(vaultID: vault)
            let after = TouchIDUnlock.isKept(vaultID: vault)
            results.append(Result(name: keychainName,
                                  verdict: kept == errSecSuccess && found && listed && !other && removed == errSecSuccess && !after
                                      ? .pass : .fail("kept \(kept), found \(found), listed \(listed), another vault's \(other), "
                                                      + "removed \(removed), there after \(after)")))
        }
        return results
    }

    /// With `profile` running in a process of its own (the self-test's keychain group): the app
    /// keeps a key under the service, sees it itself, and the profile's process, asked to look for
    /// the service's items in both keychains, is shown none.
    static func keyApartFromProfile(manager: ProfileManager, profile: UUID) async -> Result {
        if let cannot = cannotKeep { return Result(name: profileName, verdict: cannot) }
        let vault = UUID()
        let kept = TouchIDUnlock.keep(Data(repeating: 0x5A, count: 32), vaultID: vault)
        defer { TouchIDUnlock.remove(vaultID: vault) }
        guard kept == errSecSuccess else {
            return Result(name: profileName, verdict: .fail("the keychain did not keep the app's own item (\(kept)): nothing to show"))
        }
        guard TouchIDUnlock.keptAccounts().contains(vault.uuidString) else {
            return Result(name: profileName, verdict: .fail("the app is not shown its own item (the control): the check could not have told"))
        }
        var report: KeychainReport?
        let previous = manager.onKeychainReport
        manager.onKeychainReport = { id, answer in
            if id == profile { report = answer }
        }
        defer { manager.onKeychainReport = previous }
        guard manager.checkKeychain(profile, KeychainProbe(service: TouchIDUnlock.service)) else {
            return Result(name: profileName, verdict: .fail("the profile has no process of its own to ask"))
        }
        let deadline = Date().addingTimeInterval(20)
        while report == nil, Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        guard let report else { return Result(name: profileName, verdict: .fail("the profile's process did not answer in 20 s")) }
        let shown = report.seen + report.loginSeen
        return Result(name: profileName,
                      verdict: shown.isEmpty ? .pass
                          : .fail("the profile's process was shown \(shown.count) item(s) under the service"
                                  + (shown.contains(vault.uuidString) ? ", the app's key among them" : "")))
    }
}
