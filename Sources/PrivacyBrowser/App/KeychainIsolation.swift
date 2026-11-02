import BrowserCore
import Foundation
import Security

/// Whether one profile can reach the keychain, its own or another's — the check the self-test and
/// the release check make (docs/IDENTITY.md, "The keychain").
///
/// Two profiles run in processes of their own; each, asked from inside (`ProfileCommand.checkKeychain`),
/// says which of the entitlements that give a keychain it holds — as the kernel has them — whether it
/// reaches securityd, and what each keychain lets it do: profile A tries to keep an item, profile B
/// looks. Beside them, those that must do more, or the check could not have told:
///
///   * this process, the app itself, outside every profile: it keeps an item of its own in each
///     keychain first, and must still see it — the app's keychain stays as it was;
///   * two processes of the profile's own executable outside a profile's sandbox — the isolation
///     broken by hand: one keeps an item in the account's login keychain, the other must see it;
///   * a process of the app's own executable — a profile as it was started before LumenProfile: it
///     must hold the entitlements the profiles do not, and see the app's item in the data-protection
///     keychain where that keychain opens at all.
///
/// Three verdicts. The entitlements, wherever the app's executable holds one of them. The login
/// keychain, wherever the control could keep an item there and have another process see it: on every
/// Mac with an unlocked login keychain, CI's runners included, whatever the signature — the keychain a
/// profile's process could write before its sandbox refused it securityd. The data-protection
/// keychain, only where it takes the app's own item: a build signed by the team, as the release check
/// runs it in release.sh; an ad hoc signature cannot open it even with the app group (CI run 646), and
/// there that verdict is a skip, never a pass.
@MainActor
enum KeychainIsolation {
    enum Verdict: Equatable {
        case pass
        case fail(String)
        case skip(String)
    }

    struct Outcome {
        var entitlements: Verdict
        var login: Verdict
        var items: Verdict
        /// What each process said, for the log.
        var details: [String]
        /// Whether this process holds the application identifier: only a signature by the team can
        /// carry it (CI run 646: an ad hoc one is not let start), so a skipped verdict there is a
        /// failure of the check, not of the machine.
        var appHoldsTeamIdentity: Bool
    }

    /// Each verdict of `outcome` with its check's name, in the order they are said.
    static func verdicts(_ outcome: Outcome) -> [(name: String, verdict: Verdict)] {
        [(entitlementsName, outcome.entitlements), (loginName, outcome.login), (itemsName, outcome.items)]
    }

    static let entitlementsName = "keychain: a profile's process holds none of the entitlements that give a keychain — "
        + "the app's own executable, as profiles were started before, does (the control)"
    static let loginName = "keychain: the account's login keychain is closed to a profile's process — profile A keeps nothing there "
        + "and profile B is shown nothing of it, while a process of the profile's executable outside a profile's sandbox keeps an item "
        + "and another sees it (the control), and the app keeps and sees its own"
    static let itemsName = "keychain between profiles: an item one profile tries to keep in the data-protection keychain "
        + "is not kept, the other does not see it, nor the app's own — which a process of the app's executable sees (the control)"

    /// The accounts of the check's items, by whose they are.
    private struct Accounts {
        let app = "app-\(UUID().uuidString)"
        let first = "profile-a-\(UUID().uuidString)"
        let control = "control-\(UUID().uuidString)"
    }

    /// The profiles `first` and `second` must be running in processes of their own, started by
    /// `manager`.
    static func look(manager: ProfileManager, profiles first: UUID, _ second: UUID) async -> Outcome {
        let service = "io.lumenbrowser.keychain-check.\(UUID().uuidString.prefix(8))"
        let accounts = Accounts()
        var details: [String] = []

        // The app itself, outside every profile: an item of its own in each keychain.
        let app = KeychainCheck.run(KeychainProbe(service: service, add: accounts.app))
        details.append("the app (this process): " + describe(app, accounts))

        // The control: two processes of the profile's executable outside a profile's sandbox, one
        // keeping an item, the other looking — what a profile's process could do without its lock.
        let profileExecutable = try? ProfileExecutable.url()
        var writer: KeychainReport?
        var reader: KeychainReport?
        if let profileExecutable {
            writer = await KeychainCheck.probe(profileExecutable, KeychainProbe(service: service, add: accounts.control))
            reader = await KeychainCheck.probe(profileExecutable, KeychainProbe(service: service))
        }
        details.append("a process of the profile's executable outside a profile's sandbox, keeping an item: "
                       + (writer.map { describe($0, accounts) } ?? "no answer"))
        details.append("another, looking: " + (reader.map { describe($0, accounts) } ?? "no answer"))

        // Profile A tries to keep an item; profile B looks.
        var reports: [UUID: KeychainReport] = [:]
        let previous = manager.onKeychainReport
        manager.onKeychainReport = { id, report in reports[id] = report }
        defer { manager.onKeychainReport = previous }
        if manager.checkKeychain(first, KeychainProbe(service: service, add: accounts.first)) {
            _ = await waitUntil(timeout: 20) { reports[first] != nil }
        }
        if manager.checkKeychain(second, KeychainProbe(service: service)) {
            _ = await waitUntil(timeout: 20) { reports[second] != nil }
        }
        let a = reports[first]
        let b = reports[second]
        for (name, report) in [("profile A", a), ("profile B", b)] {
            details.append("\(name): " + (report.map { describe($0, accounts) + " (the reader's control \($0.readerSawItsControl ? "seen" : "NOT seen"))" } ?? "no answer"))
        }

        // A profile as it was started before LumenProfile: a process of the app's own executable.
        var before: KeychainReport?
        if let executable = Bundle.main.executableURL {
            before = await KeychainCheck.probe(executable, KeychainProbe(service: service))
        }
        details.append("a process of the app's executable (as profiles were started before): " + (before.map { describe($0, accounts) } ?? "no answer"))

        // Nothing of the check's is left: each removes what it kept.
        _ = KeychainCheck.run(KeychainProbe(service: service, remove: [accounts.app]))
        if let profileExecutable, writer?.loginAdded == 0 || writer?.added == 0 {
            _ = await KeychainCheck.probe(profileExecutable, KeychainProbe(service: service, remove: [accounts.control]))
        }
        if a?.added == 0 || a?.loginAdded == 0 {
            reports[first] = nil
            if manager.checkKeychain(first, KeychainProbe(service: service, remove: [accounts.first])) {
                _ = await waitUntil(timeout: 10) { reports[first] != nil }
            }
        }

        let appHoldsTeamIdentity = app.held?.contains("com.apple.application-identifier") == true
        return Outcome(entitlements: entitlementsVerdict(a: a, b: b, before: before),
                       login: loginVerdict(app: app, writer: writer, reader: reader, a: a, b: b, accounts: accounts),
                       items: itemsVerdict(app: app, a: a, b: b, before: before, accounts: accounts),
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

    private static func loginVerdict(app: KeychainReport, writer: KeychainReport?, reader: KeychainReport?,
                                     a: KeychainReport?, b: KeychainReport?, accounts: Accounts) -> Verdict {
        guard let writer, let reader, writer.loginAdded == 0, reader.loginSeen.contains(accounts.control) else {
            return .skip("a process of the profile's executable outside a profile's sandbox could not keep an item in this Mac's login "
                         + "keychain and have another process see it (kept: \(status(writer?.loginAdded)); shown to the other: "
                         + "\(label(reader?.loginSeen ?? [], accounts))): nothing here for a profile to be kept from")
        }
        guard app.loginAdded == 0, app.loginSeen.contains(accounts.app) else {
            return .fail("the app itself could not keep and see its own item in the login keychain (\(status(app.loginAdded))), "
                         + "where a process of the profile's executable could: the app's keychain must stay as it was")
        }
        guard let a, let b else { return .fail("a profile's process did not answer") }
        if a.loginAdded == 0 {
            return .fail("profile A kept an item in the account's login keychain"
                         + (b.loginSeen.contains(accounts.first) ? ", and profile B was shown it" : "")
                         + (b.loginSeen.contains(accounts.app) ? ", and the app's own" : ""))
        }
        for (name, report) in [("profile A", a), ("profile B", b)] where !report.loginSeen.isEmpty {
            return .fail("\(name) was shown \(label(report.loginSeen, accounts)) in the account's login keychain")
        }
        return .pass
    }

    private static func itemsVerdict(app: KeychainReport, a: KeychainReport?, b: KeychainReport?, before: KeychainReport?,
                                     accounts: Accounts) -> Verdict {
        guard app.added == 0, app.seen.contains(accounts.app) else {
            return .skip("the data-protection keychain takes no item from the app itself here (\(status(app.added)), holding "
                         + "\(app.heldDescription)): only a signature by the team opens it — an ad hoc one does not, even with the "
                         + "app group (CI run 646); the release check shows it on the build signed for release")
        }
        guard let a, let b else { return .fail("a profile's process did not answer") }
        if a.added == 0 {
            return .fail("profile A kept an item in the data-protection keychain: it has the app's keychain"
                         + (b.seen.contains(accounts.first) ? ", and profile B saw it" : ""))
        }
        for (name, report) in [("profile A", a), ("profile B", b)] where !report.seen.isEmpty {
            return .fail("\(name) was shown \(label(report.seen, accounts)) in the data-protection keychain")
        }
        guard let before, before.seen.contains(accounts.app) else {
            return .fail("a process of the app's executable was not shown the app's item: the check could not have told a profile "
                         + "that shares the app's keychain")
        }
        return .pass
    }

    private static func describe(_ report: KeychainReport, _ accounts: Accounts) -> String {
        "holds \(report.heldDescription); securityd: \(report.lookupsDescription); "
            + "data-protection keychain: added \(status(report.added)), shown \(label(report.seen, accounts)); "
            + "login keychain: added \(status(report.loginAdded)), shown \(label(report.loginSeen, accounts))"
    }

    private static func status(_ value: Int32?) -> String {
        guard let value else { return "-" }
        switch value {
        case 0: return "0 (kept)"
        case KeychainCheck.missingEntitlement: return "\(value) (no entitlement for a keychain)"
        case errSecNotAvailable: return "\(value) (no keychain available)"
        case errSecInteractionNotAllowed: return "\(value) (it would have asked the person)"
        default: return "\(value)"
        }
    }

    private static func label(_ accounts: [String], _ names: Accounts) -> String {
        guard !accounts.isEmpty else { return "nothing" }
        return accounts.map { account -> String in
            switch account {
            case names.app: return "the app's item"
            case names.first: return "profile A's item"
            case names.control: return "the control's item"
            default: return "another item"
            }
        }.joined(separator: ", ")
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
