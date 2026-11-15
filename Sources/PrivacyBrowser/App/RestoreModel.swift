import AppKit
import BrowserCore
import Foundation
import os

/// Bringing back a vault that is already somewhere — kept by the Lumen account, in a sync folder, on
/// a server of one's own — to a Mac that has none (`VaultRestore`, docs/SYNC_FORMAT.md "A Mac without
/// a vault"): the first launch's other way, beside creating a vault, and the way a second Mac joins
/// the vault another one still syncs.
///
/// The steps, as the setup screen shows them (`RestoreFlow`): where the vault is → which one (the
/// account's list, each by the dates its header and the server say) → its master password → it comes
/// down into a folder of its own, and is moved into place once all of it is here → it opens.
///
/// What is kept where while there is no vault yet: nothing new. The server is asked with this Mac's
/// device token (`account.json`, as before — the rights are decided with it before a vault opens);
/// the account's session stays in memory until the vault opens and is sealed into it then
/// (`LicenseModel.vaultOpened`); the master password is held only while it opens the vault; a
/// server's token typed here goes into the restored vault's `settings.bin`, encrypted, and nowhere
/// else.
@MainActor
final class RestoreModel: ObservableObject {
    /// Where the vault is kept.
    enum Place: Equatable {
        case account
        case folder(path: String)
        case server(host: String)
    }

    /// A vault found at a place, as it is told before its master password: by its dates.
    struct Candidate: Equatable, Identifiable {
        var vaultID: UUID
        /// When it was made, by its header; nil when the header was not read.
        var createdAt: Date?
        /// When it was last written to, by the account's list.
        var changedAt: Date?
        /// Its master password was changed since it was made: the latest one opens it.
        var passwordChanged = false
        /// Why it cannot be brought (a newer version's, a header that did not read); nil: it can.
        var problem: String?

        var id: UUID { vaultID }
    }

    enum Step: Equatable {
        case source, account, server, password, bringing, done
    }

    /// What the Lumen server said of the account's vaults.
    enum AccountAnswer: Equatable {
        case asking
        case vaults([Candidate])
        /// Everything that is not a list: none, the plan, the hold, signed out, no answer.
        case state(AccountVaults.State)
    }

    /// What came, said before the vault opens.
    struct Summary: Equatable {
        var profiles: Int
        /// The names of the profiles whose settings the place did not hold.
        var withoutSettings: [String]
        var place: Place
    }

    @Published private(set) var step: Step = .source
    @Published private(set) var place: Place?
    @Published private(set) var account: AccountAnswer = .asking
    /// The vault chosen in the account's list.
    @Published var selected: UUID?
    @Published private(set) var candidate: Candidate?
    @Published private(set) var isWorking = false
    /// What stopped the step, said under its form; cleared when the person goes on.
    @Published var problem: String?
    /// Counts the wrong passwords: the field shakes once for each.
    @Published private(set) var wrongPasswords = 0
    /// The names of the vault's profiles by its index, in the list's order, once read; nil before.
    @Published private(set) var profileNames: [String]?
    @Published private(set) var progress: VaultRestore.Progress?
    /// A restore of this vault was begun before, and this one goes on from it.
    @Published private(set) var continued = false
    /// All of it is here, and it is being moved into place.
    @Published private(set) var moving = false
    /// The run stopped before the vault was whole: why. What came is kept.
    @Published private(set) var interrupted: String?
    @Published private(set) var summary: Summary?
    /// Restores begun on this Mac and not finished (`VaultRestore.unfinished`).
    @Published private(set) var unfinished: [VaultRestore.Unfinished] = []

    private var headers: [UUID: VaultHeader] = [:]
    private var header: VaultHeader?
    private var target: DeviceSettings.SyncTarget?
    private var makeTransport: (() throws -> SyncTransport)?
    /// A folder's size, known before it is brought; nil for a server, which says none.
    private var knownBytes: Int64?
    private var scopedFolder: URL?
    private var staged: UnlockedVault?
    private var restored: UnlockedVault?
    private var warning: String?
    /// The Lumen server refused this Mac's token while the vault was brought: the license is renewed
    /// after the run, and says why (§9.4).
    private var tokenRefused = false
    private var running: Task<Void, Never>?
    private let log = Logger(subsystem: "PrivacyBrowser", category: "Restore")

    init() {}

    /// The snapshots': the flow as it stands at `step`, nothing asked of any server or disk.
    init(sample step: Step, place: Place? = nil, account: AccountAnswer = .asking, selected: UUID? = nil, candidate: Candidate? = nil,
         problem: String? = nil, profileNames: [String]? = nil, progress: VaultRestore.Progress? = nil, continued: Bool = false,
         interrupted: String? = nil, summary: Summary? = nil, unfinished: [VaultRestore.Unfinished] = []) {
        self.step = step
        self.place = place
        self.account = account
        self.selected = selected
        self.candidate = candidate
        self.problem = problem
        self.profileNames = profileNames
        self.progress = progress
        self.continued = continued
        self.interrupted = interrupted
        self.summary = summary
        self.unfinished = unfinished
        isSample = true
    }

    private var isSample = false

    deinit {
        scopedFolder?.stopAccessingSecurityScopedResource()
    }

    // MARK: Where it is

    /// As the flow appears: what was begun here before.
    func begin(app: AppModel) {
        guard !isSample else { return }
        unfinished = VaultRestore.unfinished(in: app.root)
    }

    /// The Lumen account is a place to bring a vault from: this build has an account server.
    func offersAccount(_ app: AppModel) -> Bool { app.license.isConfigured }

    /// Back to the choice of the place. What a run brought stays where it is.
    func backToSource(app: AppModel) {
        guard running == nil, !isWorking else { return }
        step = .source
        problem = nil
        interrupted = nil
        candidate = nil
        header = nil
        staged = nil
        profileNames = nil
        progress = nil
        continued = false
        begin(app: app)
    }

    // MARK: The Lumen account

    /// Asks the Lumen server for the account's vaults with this Mac's device token, after a renewal
    /// of this run (CONTRACT §16.1), then reads each one's header: its dates are what tells two
    /// vaults apart, the server knowing neither a name nor a size.
    func chooseAccount(app: AppModel) async {
        guard !isSample, !isWorking else { return }
        place = .account
        step = .account
        account = .asking
        problem = nil
        selected = nil
        isWorking = true
        defer { isWorking = false }
        let state = await app.license.syncVaults()
        guard case .vaults(let vaults) = state else {
            account = .state(state)
            return
        }
        var candidates: [Candidate] = []
        for vault in vaults {
            do {
                let found = try await VaultRestore.header(at: accountTransport(vault.vaultID, app: app), expecting: vault.vaultID)
                headers[vault.vaultID] = found
                candidates.append(Candidate(vaultID: vault.vaultID, createdAt: found.createdAt, changedAt: vault.changedAt,
                                            passwordChanged: (found.passwordRevision ?? 0) > 0))
            } catch {
                // A refusal of the account's — the plan, the hold, this Mac unlinked — is the answer
                // for every vault of it, not one vault's trouble.
                if let refused = AccountVaults.state(of: error), Self.isAboutTheAccount(refused) {
                    account = .state(refused)
                    return
                }
                candidates.append(Candidate(vaultID: vault.vaultID, createdAt: nil, changedAt: vault.changedAt,
                                            problem: RestoreText.vaultProblem(error)))
            }
        }
        account = .vaults(candidates)
        selected = candidates.first { $0.problem == nil }?.vaultID
    }

    private static func isAboutTheAccount(_ state: AccountVaults.State) -> Bool {
        switch state {
        case .notInPlan, .onHold, .accountDisabled, .signedOut, .rateLimited: return true
        case .vaults, .noVaults, .unreachable, .refused: return false
        }
    }

    /// The vault chosen in the list: on to its master password.
    func continueWithSelected(app: AppModel) {
        guard case .vaults(let candidates) = account, let chosen = candidates.first(where: { $0.vaultID == selected }),
              chosen.problem == nil, let found = headers[chosen.vaultID] else { return }
        let id = chosen.vaultID
        candidate = chosen
        header = found
        target = .account
        knownBytes = nil
        makeTransport = { [weak self, weak app] in
            guard let self, let app else { throw AccountSyncUnavailable(reason: .notSignedIn) }
            return try self.accountTransport(id, app: app)
        }
        toPassword()
    }

    /// The account server with this Mac's device token, for that vault — as a sync makes it
    /// (`AppModel.syncTransport`).
    private func accountTransport(_ vaultID: UUID, app: AppModel) throws -> SyncTransport {
        guard let configuration = app.license.configuration, let token = app.license.record.deviceToken, !token.isEmpty else {
            throw AccountSyncUnavailable(reason: .notSignedIn)
        }
        guard app.license.renewedForSync else { throw AccountSyncUnavailable(reason: .notChecked) }
        return try AccountSync.transport(server: configuration.serverURL, deviceToken: token, vaultID: vaultID,
                                         allowInsecureLocalhost: configuration.source == .environment,
                                         session: AccountSyncText.session)
    }

    // MARK: A folder

    /// A folder a Mac synced to. Kept as Settings → Sync keeps one — a security-scoped bookmark — and
    /// read as the bookmark gives it back: the path the next sync will name, so that sync goes on
    /// from the restore's records.
    func chooseFolder(_ folder: URL, app: AppModel) async {
        guard !isSample, !isWorking else { return }
        problem = nil
        isWorking = true
        defer { isWorking = false }
        let shown = Place.folder(path: folder.path)
        do {
            let bookmark = try folder.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            var stale = false
            let resolved = try URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale)
            scopedFolder?.stopAccessingSecurityScopedResource()
            scopedFolder = resolved.startAccessingSecurityScopedResource() ? resolved : nil
            let found = try await VaultRestore.header(at: LocalDirectorySyncTransport(directory: resolved))
            knownBytes = await Task.detached { VaultRestore.bytes(in: resolved) }.value
            place = .folder(path: resolved.path)
            candidate = Candidate(vaultID: found.vaultID, createdAt: found.createdAt, changedAt: nil,
                                  passwordChanged: (found.passwordRevision ?? 0) > 0)
            header = found
            target = .folder(bookmark: bookmark, path: resolved.path)
            makeTransport = { LocalDirectorySyncTransport(directory: resolved) }
            toPassword()
        } catch {
            problem = RestoreText.text(error, place: shown, root: app.root)
        }
    }

    // MARK: A server of one's own

    func showServerForm() {
        guard !isWorking else { return }
        problem = nil
        step = .server
    }

    /// A server that speaks docs/SYNC_SERVER_API.md: its address, its token, and the vault's ID — such
    /// a server lists no vaults.
    func chooseServer(address: String, token: String, vaultID: String, app: AppModel) async {
        guard !isSample, !isWorking else { return }
        problem = nil
        guard let url = URL(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
              (try? HTTPSyncTransport.validate(url)) != nil else {
            problem = L("restore.server.address.bad")
            return
        }
        guard let id = UUID(uuidString: vaultID.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            problem = L("restore.server.vaultID.bad")
            return
        }
        let secret = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let shown = Place.server(host: url.host ?? url.absoluteString)
        isWorking = true
        defer { isWorking = false }
        do {
            let make: () throws -> SyncTransport = {
                try HTTPSyncTransport(configuration: .init(baseURL: url, vaultID: id, bearerToken: secret))
            }
            let found = try await VaultRestore.header(at: make(), expecting: id)
            place = shown
            candidate = Candidate(vaultID: id, createdAt: found.createdAt, changedAt: nil, passwordChanged: (found.passwordRevision ?? 0) > 0)
            header = found
            target = .server(baseURL: url, token: secret)
            knownBytes = nil
            makeTransport = make
            toPassword()
        } catch {
            problem = RestoreText.text(error, place: shown, root: app.root)
        }
    }

    private func toPassword() {
        problem = nil
        interrupted = nil
        staged = nil
        profileNames = nil
        progress = nil
        continued = false
        step = .password
    }

    // MARK: The master password, and bringing it

    /// Opens the vault with its master password — checked here, against the header; sent nowhere —
    /// and brings it. A wrong password leaves nothing on this Mac.
    func bring(password: String, app: AppModel) async {
        guard !isSample, !isWorking, running == nil, step == .password, let header, !password.isEmpty else { return }
        problem = nil
        let root = app.root
        if let short = VaultRestore.spaceProblem(free: VaultRestore.freeBytes(at: root), known: knownBytes) {
            problem = RestoreText.text(short, place: place, root: root)
            return
        }
        isWorking = true
        do {
            // The vault's key derivation (Argon2id on a vault the app made): off the main thread.
            let opened = try await Task.detached(priority: .userInitiated) {
                try VaultRestore.open(header, password: password, root: root)
            }.value
            staged = opened.vault
            continued = opened.continued
            // §10.1, later: the vault's master password is the account's password or the license's
            // key, typed in this session — said once it opens, not refused: it is that vault's already.
            if app.license.isAccountPassword(password) {
                warning = L("contract.master_password.same_as_account_existing")
            } else if app.license.isLicenseKey(password) {
                warning = L("contract.master_password.same_as_key")
            } else {
                warning = nil
            }
        } catch VaultRestore.Problem.wrongPassword {
            wrongPasswords += 1
            problem = L("restore.password.wrong")
            isWorking = false
            return
        } catch {
            problem = RestoreText.text(error, place: place, root: root)
            isWorking = false
            return
        }
        isWorking = false
        step = .bringing
        await run(app: app)
    }

    /// After a run that stopped short: on from what it brought.
    func goOn(app: AppModel) async {
        guard !isSample, step == .bringing, running == nil, staged != nil else { return }
        await run(app: app)
    }

    /// The person's Stop: the run ends between two objects. What came is kept.
    func stop() {
        running?.cancel()
    }

    private func run(app: AppModel) async {
        guard let staged, let makeTransport, running == nil else { return }
        interrupted = nil
        moving = false
        let target = self.target
        let root = app.root
        let place = self.place ?? .account
        let task = Task { @MainActor [weak self] in
            do {
                let transport = try makeTransport()
                if self?.profileNames == nil {
                    let listed = try await VaultRestore.profiles(of: staged, at: transport)
                    self?.profileNames = listed.map(\.name)
                }
                let outcome = try await VaultRestore.download(into: staged, from: transport, target: target) { progress in
                    Task { @MainActor [weak self] in self?.note(progress) }
                }
                try Task.checkCancellation()
                self?.moving = true
                let vault = try VaultRestore.moveIntoPlace(staged, root: root)
                self?.arrived(vault, outcome, place: place)
            } catch {
                self?.stoppedShort(error, place: place, root: root)
            }
        }
        running = task
        await task.value
        running = nil
        if tokenRefused {
            tokenRefused = false
            _ = await app.license.renewForSync(again: true)
        }
    }

    /// Progress comes from the run's own thread, one message for each object: the furthest is shown.
    private func note(_ next: VaultRestore.Progress) {
        if let progress, progress.fetched > next.fetched { return }
        progress = next
    }

    private func arrived(_ vault: UnlockedVault, _ outcome: VaultRestore.Outcome, place: Place) {
        restored = vault
        staged = nil
        moving = false
        summary = Summary(profiles: outcome.profiles.count, withoutSettings: outcome.withoutSettings.map(\.name), place: place)
        log.notice("A vault was brought from its sync location: \(outcome.profiles.count, privacy: .public) profile(s), \(outcome.withoutSettings.count, privacy: .public) without settings there, \(Int(outcome.withheld), privacy: .public) write(s) left for the first sync")
        step = .done
    }

    private func stoppedShort(_ error: Error, place: Place, root: URL) {
        moving = false
        log.error("Bringing a vault from its sync location stopped: \(error.logKind, privacy: .public)")
        // A refusal of the account's met on the way is said as the state it is.
        if place == .account, let state = AccountVaults.state(of: error), Self.isAboutTheAccount(state) {
            interrupted = RestoreText.text(state)
            tokenRefused = state == .signedOut
        } else {
            interrupted = RestoreText.text(error, place: place, root: root)
        }
    }

    // MARK: It is here

    /// The vault is in place: it opens, as an unlock opens one.
    func open(app: AppModel) {
        guard let restored else { return }
        scopedFolder?.stopAccessingSecurityScopedResource()
        scopedFolder = nil
        app.adoptRestoredVault(restored, warning: warning)
    }

    // MARK: An unfinished restore, discarded

    /// The person's own Discard, from its confirmation: what an unfinished restore downloaded to this
    /// Mac goes. Nothing at the sync location is touched.
    func discardUnfinished(_ vaultID: UUID, app: AppModel) {
        guard running == nil, !isWorking else { return }
        do {
            try VaultRestore.discardStagingBecauseThePersonAsked(vaultID, in: app.root)
            if staged?.vaultID == vaultID { staged = nil }
        } catch {
            problem = errorText(error)
        }
        unfinished = VaultRestore.unfinished(in: app.root)
    }
}

/// What the restore says, in the interface's language: each state in words of its own, and each says
/// what was — and was not — changed.
enum RestoreText {
    static func bytes(_ value: Int64) -> String {
        value.formatted(.byteCount(style: .file).locale(Localization.locale))
    }

    static func day(_ date: Date) -> String { date.shown(date: .long, time: .omitted) }
    static func moment(_ date: Date) -> String { date.shown(date: .long, time: .shortened) }

    /// A state of the account's vault list that is not a list (`AccountVaults.State`).
    static func text(_ state: AccountVaults.State) -> String {
        switch state {
        case .vaults: return ""
        case .noVaults: return L("restore.account.none")
        case .notInPlan: return L("restore.account.notInPlan")
        case .onHold(let until):
            return until.map { String(format: L("restore.account.onHold"), moment($0)) } ?? L("restore.account.onHold.later")
        case .accountDisabled: return L("restore.account.disabled")
        case .signedOut: return L("restore.account.signedOut")
        case .rateLimited: return L("restore.account.rateLimited")
        case .unreachable: return L("restore.account.unreachable")
        case .refused(let status, let code): return String(format: L("restore.account.refused"), status, code)
        }
    }

    /// What stopped a step, by the place the vault is at.
    static func text(_ error: Error, place: RestoreModel.Place?, root: URL) -> String {
        guard let problem = error as? VaultRestore.Problem else {
            if let state = AccountVaults.state(of: error), place == .account { return text(state) }
            return errorText(error)
        }
        switch problem {
        case .noVaultThere:
            switch place {
            case .folder?: return L("restore.problem.noVault.folder")
            case .server?: return L("restore.problem.noVault.server")
            case .account?, nil: return L("restore.problem.noVault.account")
            }
        case .filesInTheWay(let names):
            return String(format: L("restore.problem.filesInTheWay"), names.joined(separator: ", "), root.path)
        default:
            return text(problem)
        }
    }

    /// A problem of the restore, where the place does not matter (`translatedErrorText`).
    static func text(_ problem: VaultRestore.Problem) -> String {
        switch problem {
        case .noVaultThere: return L("restore.problem.noVault.account")
        case .newerApp(let what): return String(format: L("restore.problem.newerApp"), what)
        case .notThisVault: return L("restore.problem.notThisVault")
        case .wrongPassword: return L("restore.password.wrong")
        case .vaultHere: return L("restore.problem.vaultHere")
        case .filesInTheWay(let names):
            return String(format: L("restore.problem.filesInTheWay"), names.joined(separator: ", "), AppEnvironment.vaultDirectory.path)
        case .notEnoughSpace(let free, let needed): return String(format: L("restore.problem.space"), bytes(free), bytes(needed))
        case .diskFull: return L("restore.problem.diskFull")
        case .changedMeanwhile: return L("restore.problem.changed")
        case .stopped: return L("restore.problem.stopped")
        }
    }

    /// Why one vault of the account's list cannot be brought: under its row.
    static func vaultProblem(_ error: Error) -> String {
        if case VaultRestore.Problem.newerApp = error { return L("restore.vault.newer") }
        if let problem = error as? VaultRestore.Problem { return String(format: L("restore.vault.unread"), text(problem)) }
        return String(format: L("restore.vault.unread"), errorText(error))
    }

    /// The place, as the sentence "this Mac now syncs this vault with …" ends.
    static func syncsWith(_ place: RestoreModel.Place) -> String {
        switch place {
        case .account: return L("restore.done.place.account")
        case .folder(let path): return String(format: L("restore.done.place.folder"), path)
        case .server(let host): return String(format: L("restore.done.place.server"), host)
        }
    }

    /// "Vault made 12 March 2026, kept …": under the master password step's title.
    static func kept(_ candidate: RestoreModel.Candidate?, at place: RestoreModel.Place?) -> String {
        let made = candidate?.createdAt.map(day) ?? "—"
        switch place {
        case .folder(let path)?: return String(format: L("restore.password.subtitle.folder"), made, path)
        case .server(let host)?: return String(format: L("restore.password.subtitle.server"), made, host)
        case .account?, nil: return String(format: L("restore.password.subtitle.account"), made)
        }
    }

    /// "Work, Shop, Mail and 9 more".
    static func names(_ profiles: [String], showing limit: Int = 4) -> String {
        let shown = profiles.prefix(limit).joined(separator: ", ")
        guard profiles.count > limit else { return shown }
        return shown + " " + String(format: L("restore.bringing.more"), profiles.count - limit)
    }
}
