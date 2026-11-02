import BrowserCore
import Foundation

/// Whether one profile can see another's keychain — the check the self-test and the release check
/// make (docs/IDENTITY.md, "The keychain"; `ProfileExecutable` says why it could).
///
/// Two profiles run in processes of their own; each, asked from inside (`ProfileCommand.checkKeychain`),
/// says which of the entitlements that give a keychain it holds — as the kernel has them — and what
/// the data-protection keychain lets it do: profile A tries to add an item, profile B looks. Beside
/// them, two that must see more, or the check could not have told:
///
///   * this process, the app itself: in a build with the network guard it holds the app's keychain,
///     and it puts an item of its own there first;
///   * a process of the app's own executable — a profile as it was started before LumenProfile, the
///     isolation broken by hand: it must hold the entitlements the profiles do not, and see the app's
///     item.
///
/// Two verdicts. The entitlements are shown wherever the app's executable holds one of them: in an
/// NE=1 build, and in CI's NE=check build, which gives it the app group (the one an ad hoc signature
/// can carry). The items are shown only where the keychain takes the app's item at all — a build
/// signed by the team, as the release check runs it in release.sh; an ad hoc signature cannot open it
/// even with the app group (CI run 646), and there that verdict is a skip, never a pass.
@MainActor
enum KeychainIsolation {
    enum Verdict: Equatable {
        case pass
        case fail(String)
        case skip(String)
    }

    struct Outcome {
        var entitlements: Verdict
        var items: Verdict
        /// What each process said, for the log.
        var details: [String]
        /// Whether this process holds the application identifier: only a signature by the team can
        /// carry it (CI run 646: an ad hoc one is not let start), so a skipped `items` verdict there
        /// is a failure of the check, not of the machine.
        var appHoldsTeamIdentity: Bool
    }

    static let entitlementsName = "keychain: a profile's process holds none of the entitlements that give a keychain — "
        + "the app's own executable, as profiles were started before, does (the control)"
    static let itemsName = "keychain between profiles: an item one profile tries to keep in the data-protection keychain "
        + "is not kept, the other does not see it, nor the app's own — which a process of the app's executable sees (the control)"

    /// The profiles `first` and `second` must be running in processes of their own, started by
    /// `manager`.
    static func look(manager: ProfileManager, profiles first: UUID, _ second: UUID) async -> Outcome {
        let service = "io.lumenbrowser.keychain-check.\(UUID().uuidString.prefix(8))"
        let appAccount = "app-\(UUID().uuidString)"
        let firstAccount = "profile-a-\(UUID().uuidString)"
        var details: [String] = []

        // The app's own item first: whether the keychain is there at all for this signature.
        let app = KeychainCheck.run(KeychainProbe(service: service, add: appAccount))
        details.append("the app (this process): holds \(app.heldDescription); its item: added \(status(app.added)), shown \(app.seen.count)")

        var reports: [UUID: KeychainReport] = [:]
        let previous = manager.onKeychainReport
        manager.onKeychainReport = { id, report in reports[id] = report }
        defer { manager.onKeychainReport = previous }
        if manager.checkKeychain(first, KeychainProbe(service: service, add: firstAccount)) {
            _ = await waitUntil(timeout: 20) { reports[first] != nil }
        }
        if manager.checkKeychain(second, KeychainProbe(service: service)) {
            _ = await waitUntil(timeout: 20) { reports[second] != nil }
        }
        let a = reports[first]
        let b = reports[second]
        for (name, report) in [("profile A", a), ("profile B", b)] {
            guard let report else {
                details.append("\(name): no answer")
                continue
            }
            details.append("\(name): holds \(report.heldDescription) (the reader's control \(report.readerSawItsControl ? "seen" : "NOT seen")); "
                           + "added \(status(report.added)); shown \(report.seen.isEmpty ? "nothing" : label(report.seen, app: appAccount, a: firstAccount))")
        }

        // A profile as it was started before LumenProfile: a process of the app's own executable.
        var before: KeychainReport?
        if let executable = Bundle.main.executableURL {
            before = await KeychainCheck.probe(executable, KeychainProbe(service: service))
        }
        if let before {
            details.append("a process of the app's executable (as profiles were started before): holds \(before.heldDescription); "
                           + "shown \(before.seen.isEmpty ? "nothing" : label(before.seen, app: appAccount, a: firstAccount))")
        } else {
            details.append("a process of the app's executable: no answer")
        }

        // Nothing of the check's is left: this process removes what it can see, and profile A what it
        // kept, if it kept anything.
        _ = KeychainCheck.run(KeychainProbe(service: service, removeAfter: true))
        if a?.added == 0 {
            reports[first] = nil
            if manager.checkKeychain(first, KeychainProbe(service: service, removeAfter: true)) {
                _ = await waitUntil(timeout: 10) { reports[first] != nil }
            }
        }

        let appHoldsTeamIdentity = app.held?.contains("com.apple.application-identifier") == true
        return Outcome(entitlements: entitlementsVerdict(a: a, b: b, before: before),
                       items: itemsVerdict(app: app, a: a, b: b, before: before, appAccount: appAccount, firstAccount: firstAccount),
                       details: details, appHoldsTeamIdentity: appHoldsTeamIdentity)
    }

    private static func entitlementsVerdict(a: KeychainReport?, b: KeychainReport?, before: KeychainReport?) -> Verdict {
        guard let a, let b else { return .fail("a profile's process did not answer") }
        for (name, report) in [("profile A", a), ("profile B", b)] {
            guard let held = report.held, report.readerSawItsControl else {
                return .fail("in \(name)'s process the reader saw nothing, not even \(KeychainCheck.controlEntitlement): it could not have seen the others")
            }
            if !held.isEmpty {
                return .fail("\(name)'s process holds \(held.joined(separator: ", ")): it is given the app's keychain")
            }
        }
        guard let before, let held = before.held, before.readerSawItsControl else {
            return .fail("a process of the app's executable could not be asked: nothing to show the check could tell")
        }
        guard !held.isEmpty else {
            return .skip("this build gives the app's own executable none of them either (a build without the network guard): "
                         + "no keychain for a profile to share; an NE=1 build and CI's NE=check build give it one")
        }
        return .pass
    }

    private static func itemsVerdict(app: KeychainReport, a: KeychainReport?, b: KeychainReport?, before: KeychainReport?,
                                     appAccount: String, firstAccount: String) -> Verdict {
        guard app.added == 0, app.seen.contains(appAccount) else {
            return .skip("the data-protection keychain takes no item from the app itself here (\(status(app.added)), holding "
                         + "\(app.heldDescription)): only a signature by the team opens it — an ad hoc one does not, even with the "
                         + "app group (CI run 646); the release check shows it on the build signed for release")
        }
        guard let a, let b else { return .fail("a profile's process did not answer") }
        if a.added == 0 {
            return .fail("profile A kept an item in the data-protection keychain: it has the app's keychain"
                         + (b.seen.contains(firstAccount) ? ", and profile B saw it" : ""))
        }
        for (name, report) in [("profile A", a), ("profile B", b)] where report.seen.contains(appAccount) || report.seen.contains(firstAccount) {
            return .fail("\(name) was shown \(label(report.seen, app: appAccount, a: firstAccount))")
        }
        guard let before, before.seen.contains(appAccount) else {
            return .fail("a process of the app's executable was not shown the app's item: the check could not have told a profile "
                         + "that shares the app's keychain")
        }
        return .pass
    }

    private static func status(_ value: Int32?) -> String {
        guard let value else { return "-" }
        switch value {
        case 0: return "0 (kept)"
        case KeychainCheck.missingEntitlement: return "\(value) (no entitlement for a keychain)"
        default: return "\(value)"
        }
    }

    private static func label(_ accounts: [String], app: String, a: String) -> String {
        accounts.map { $0 == app ? "the app's item" : $0 == a ? "profile A's item" : "another item" }.joined(separator: ", ")
    }

    private static func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return false }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return true
    }
}
