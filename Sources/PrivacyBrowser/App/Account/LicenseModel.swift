import AppKit
import BrowserCore
import CryptoKit
import Foundation
import Network
import os

/// Why a profile does not open or is not made: the license's rule, said as a rule and not as a
/// fault (the owner, 1 November: "это правило, а не поломка").
struct LicenseRefusal: LocalizedError, Equatable {
    let text: String
    var errorDescription: String? { text }
}

/// The license of this Mac, as the app's windows see it (the server's `docs/CONTRACT.md` §8–§11):
/// decided here, from the signed document in `account.json` and this Mac's own time — every minute,
/// before a profile opens or is made, and after each word from the server. The server is asked only
/// to refresh the document (§9.1), to sign in and out, and for the account screen; never to open a
/// profile (§1).
@MainActor
final class LicenseModel: ObservableObject {
    /// The account server of this build; nil — no licensing in this build (a development build
    /// without a server): profiles open as before.
    let configuration: AccountConfiguration?
    @Published private(set) var record: AccountRecord
    /// Nil when licensing is off in this build.
    @Published private(set) var state: LicenseState?
    /// A conversation with the server is under way (sign-in, activation, refresh, sign-out).
    @Published private(set) var isWorking = false
    /// The last refresh's outcome, for the account screen ("Права проверены…", the retry).
    @Published private(set) var lastRefresh: LicenseClient.Refresh?
    /// The last refresh moved the paid period on (`account.payment_received`), until it is seen.
    @Published var paymentReceived: Entitlement?
    /// `account.json` could not be read (a newer version's, or damaged): this Mac is treated as not
    /// signed in, and the file is never written over (`AccountFile`).
    @Published private(set) var fileProblem: String?

    /// After an email and a password: the session, until this Mac is activated with it.
    private(set) var pendingSession: AccountSession?
    /// The key of an account without an email: in memory from the sign-in until the vault keeps it
    /// (`AccountKeyVault`), and while the vault is unlocked; never anywhere else.
    private(set) var key: AccountKey?
    /// The account's password, as an HMAC under a key made for this once, until the master
    /// password's step compares it (§10.1, the owner's decision): never the password itself, never on
    /// disk; forgotten after the comparison.
    private var passwordEcho: (key: SymmetricKey, code: Data)?

    /// Asked to check for an update when the server sent what this app cannot judge (§9.4).
    var onAppOutdated: (() -> Void)?
    /// The number of profiles on this Mac (sent with each refresh, §6.2), and their creation times.
    var profilesHere: () -> [ProfileSummary] = { [] }

    private let file: AccountFile
    private let log = Logger(subsystem: "PrivacyBrowser", category: "License")
    private var timer: Timer?
    private var pathMonitor: NWPathMonitor?
    private var observers: [NSObjectProtocol] = []
    private var failures = 0
    private var nextRetry: Date?
    private var nextScheduledCheck = Date.distantPast
    private var lastActiveRefresh = Date.distantPast
    private var savedFloor: Date?
    /// The effective time's floor as it moves (§8.3): kept out of `record`, so that the minute's
    /// tick redraws nothing; written with it to `account.json`.
    private var floor: EffectiveClock?
    private var refreshing = false

    init(root: URL, configuration: AccountConfiguration? = .main) {
        self.configuration = configuration
        file = AccountFile(directory: root)
        do {
            record = try file.load() ?? AccountRecord()
        } catch {
            record = AccountRecord()
            fileProblem = String(describing: error)
            log.error("account.json could not be read: \(error.logKind, privacy: .public)")
        }
        savedFloor = record.floorTime
        floor = record.clock
        recompute()
    }

    /// The UI's snapshots: a license shown as `state` says, its Macs as `devices` — nothing read,
    /// written or asked of any server.
    init(preview record: AccountRecord, state: LicenseState?, devices: AccountDevices? = nil,
         configuration: AccountConfiguration? = AccountConfiguration(serverURL: URL(string: "https://account.invalid")!,
                                                                    siteURL: URL(string: "https://site.invalid")!, keys: [:], source: .environment)) {
        self.configuration = configuration
        file = AccountFile(directory: FileManager.default.temporaryDirectory.appendingPathComponent("lumen-preview-\(UUID().uuidString)"))
        self.record = record
        self.state = state
        previewDevices = devices
        isPreview = true
    }

    /// A snapshot's: never decided again, never saved, never asks.
    private var isPreview = false
    private var previewDevices: AccountDevices?

    var isConfigured: Bool { configuration != nil }

    /// Made once: one session for the account server, this Mac's id computed once per run.
    private lazy var client: LicenseClient? = {
        guard let configuration, let machineID = MachineIdentity.machineID else { return nil }
        let info = Bundle.main.infoDictionary ?? [:]
        return LicenseClient(transport: AccountHTTP(base: configuration.serverURL), keys: configuration.keys, machineID: machineID,
                             appVersion: AccountAPI.appVersion(version: info["CFBundleShortVersionString"] as? String ?? "0",
                                                               build: info["CFBundleVersion"] as? String ?? "0"))
    }()

    // MARK: The decision

    /// The effective time now (§8.3); the floor moves with it, and is saved when it grew by more
    /// than a minute.
    private func effectiveNow() -> Date {
        let wall = Date()
        let uptime = ProcessInfo.processInfo.systemUptime
        guard var clock = floor else { return wall }
        let t = clock.now(wall: wall, uptime: uptime)
        floor = clock
        if savedFloor.map({ t.timeIntervalSince($0) > 60 }) ?? true { save() }
        return t
    }

    /// The mode, the banners, the limit — from `account.json` and the effective time.
    func recompute() {
        guard !isPreview else { return }
        guard let configuration, let machineID = MachineIdentity.machineID else {
            state = nil
            return
        }
        let new = LicenseState.of(record, keys: configuration.keys, machineID: machineID, at: effectiveNow())
        // Published only when something shown changed: the minute's tick alone redraws nothing.
        guard let state, new.mode == state.mode, new.banners == state.banners, new.entitlement == state.entitlement,
              new.check == state.check, new.allowedProfilesHere == state.allowedProfilesHere,
              new.worksWithoutServerUntil == state.worksWithoutServerUntil else {
            state = new
            return
        }
    }

    var mode: LicenseMode? { state?.mode }

    /// A profile of this Mac may open fully: a working mode, and among the first by creation time
    /// when there are more than the plan allows here (§8.4). Licensing off: every profile.
    func refusalToOpen(_ id: UUID) -> LicenseRefusal? {
        recompute()
        guard let state else { return nil }
        guard state.mode.allowsWork else { return LicenseRefusal(text: Self.exportOnlyRefusal(state)) }
        let profiles = profilesHere().map { (id: $0.id, createdAt: $0.createdAt) }
        if !LicenseDecision.fullyOpen(profiles, allowed: state.allowedProfilesHere).contains(id) {
            return LicenseRefusal(text: L("license.refusal.overLimit"))
        }
        return nil
    }

    /// A new profile may be made here: a working mode and room under the limit (§8.4).
    func refusalToCreate() -> LicenseRefusal? {
        recompute()
        guard let state else { return nil }
        guard state.mode.allowsWork else { return LicenseRefusal(text: Self.exportOnlyRefusal(state)) }
        let here = profilesHere().count
        guard let p = state.entitlement else { return LicenseRefusal(text: L("license.refusal.notChecked")) }
        guard here < state.allowedProfilesHere else { return LicenseRefusal(text: LicenseText.limitProfiles(p)) }
        return nil
    }

    /// Whether a profile opens only for export (the row's mark, §8.4).
    func isExportOnly(_ id: UUID) -> Bool {
        guard let state else { return false }
        guard state.mode.allowsWork else { return true }
        let profiles = profilesHere().map { (id: $0.id, createdAt: $0.createdAt) }
        return !LicenseDecision.fullyOpen(profiles, allowed: state.allowedProfilesHere).contains(id)
    }

    private static func exportOnlyRefusal(_ state: LicenseState) -> String {
        switch state.mode {
        case .notSignedIn: return L("license.refusal.notSignedIn")
        default: return L("license.refusal.exportOnly")
        }
    }

    // MARK: Running

    /// Starts the minute's decision, the refreshes of §9.1 and their retries. Once, from the app's
    /// own process.
    func start() {
        guard isConfigured, timer == nil else { return }
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            Task { @MainActor in self?.refreshIfDue() }
        }
        monitor.start(queue: DispatchQueue(label: "PrivacyBrowser.License.path"))
        pathMonitor = monitor
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshIfDue() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.becameActive() }
        })
        recompute()
        if let state, RefreshSchedule.refreshAtLaunch(mode: state.mode, entitlement: state.entitlement, at: state.now) {
            Task { await refresh() }
        }
        nextScheduledCheck = Date().addingTimeInterval(15 * 60)
    }

    private func tick() {
        recompute()
        let now = Date()
        if let retry = nextRetry, now >= retry {
            Task { await refresh() }
        } else if now >= nextScheduledCheck {
            nextScheduledCheck = now.addingTimeInterval(15 * 60)
            refreshIfDue()
        }
    }

    private func refreshIfDue() {
        recompute()
        guard let state, state.mode != .notSignedIn,
              RefreshSchedule.refreshDue(entitlement: state.entitlement, at: state.now) else { return }
        Task { await refresh() }
    }

    private func becameActive() {
        recompute()
        guard let state, Date().timeIntervalSince(lastActiveRefresh) >= 60,
              RefreshSchedule.refreshWhenActive(mode: state.mode, entitlement: state.entitlement, at: state.now) else { return }
        lastActiveRefresh = Date()
        Task { await refresh() }
    }

    /// `POST /v1/device/entitlement` now (the account screen's "Обновить статус", the banners'
    /// "Проверить сейчас", a return from the payment page, and §9.1's moments).
    func refresh() async {
        guard !isPreview, let client, !refreshing, record.isSignedIn else { return }
        refreshing = true
        defer { refreshing = false }
        let before = state?.entitlement
        let (updated, result) = await client.refresh(record, profileCount: profilesHere().count, wall: Date(),
                                                     uptime: ProcessInfo.processInfo.systemUptime)
        record = updated
        // Only an accepted document moves the floor to the server's time; otherwise it stays where
        // this Mac's own clock brought it.
        if case .accepted = result { floor = record.clock }
        lastRefresh = result
        switch result {
        case .accepted(let paid):
            failures = 0
            nextRetry = nil
            save()
            savedFloor = record.floorTime
            recompute()
            if paid, let after = state?.entitlement, after.periodEndsAt != before?.periodEndsAt { paymentReceived = after }
        case .unreachable(let retryAfter):
            failures += 1
            let delay = max(RefreshSchedule.retryDelay(afterFailures: failures), TimeInterval(retryAfter ?? 0))
            nextRetry = Date().addingTimeInterval(delay)
            log.notice("License refresh: unreachable, retry in \(Int(delay), privacy: .public) s")
        case .signedOut(let reason):
            nextRetry = nil
            save()
            forgetKey()
            log.notice("License refresh: signed out by the server (\(reason.rawValue, privacy: .public))")
        case .appOutdated:
            failures = 0
            nextRetry = nil
            save()
            onAppOutdated?()
        case .notSignedIn:
            break
        }
        recompute()
    }

    // MARK: Signing in

    /// `POST /v1/auth/login` (§5.2). The session is kept for the activation that follows; the
    /// password goes no further than the request and the comparison of §10.1.
    func signIn(email: String, password: String) async -> AccountFailure? {
        guard let client else { return .unreachable }
        isWorking = true
        defer { isWorking = false }
        switch await client.login(email: email.trimmingCharacters(in: .whitespacesAndNewlines), password: password) {
        case .success(let session):
            pendingSession = session
            key = nil
            rememberForComparison(password)
            return nil
        case .failure(let failure):
            return failure
        }
    }

    /// A key typed in: checked here before anything is sent, then kept in memory for the activation.
    func useKey(_ key: AccountKey) {
        self.key = key
        pendingSession = nil
        passwordEcho = nil
    }

    /// What the activation gave, for its screen.
    struct ActivationOutcome {
        var entitlement: Entitlement
        var trial: Bool
        var clockSkew: TimeInterval?
    }

    /// `POST /v1/devices/activate` (§6.1) with the session or the key just given. On success the
    /// device, its token and the document are in `account.json`; the key goes to the vault as soon
    /// as there is one (`vaultOpened`).
    func activate(label: String, vault: UnlockedVault?) async -> Result<ActivationOutcome, AccountFailure> {
        guard let client else { return .failure(.unreachable) }
        let credential: AccountAPI.Credential
        if let session = pendingSession {
            credential = .session(session.token)
        } else if let key {
            credential = .key(key)
        } else {
            return .failure(.server(AccountServerError(status: 401, code: "unauthorized")))
        }
        isWorking = true
        defer { isWorking = false }
        let trimmed = String(label.trimmingCharacters(in: .whitespacesAndNewlines).prefix(64))
        let result = await client.activate(credential, label: trimmed, profileCount: profilesHere().count, record: record,
                                           session: pendingSession, wall: Date(), uptime: ProcessInfo.processInfo.systemUptime)
        switch result {
        case .success(let activation):
            record = activation.record
            floor = record.clock
            save()
            savedFloor = record.floorTime
            failures = 0
            nextRetry = nil
            pendingSession = nil
            if let vault { vaultOpened(vault) }
            recompute()
            return .success(ActivationOutcome(entitlement: activation.entitlement, trial: activation.trialStarted, clockSkew: activation.clockSkew))
        case .failure(let failure):
            if case .document(let check) = failure, check.meansAppOutdated { onAppOutdated?() }
            return .failure(failure)
        }
    }

    /// The person left the sign-in: nothing of it stays.
    func cancelSignIn() {
        pendingSession = nil
        if !record.isSignedIn || record.signedInWith != .key { key = nil }
        passwordEcho = nil
    }

    // MARK: The vault

    /// The vault was created or unlocked: a key signed in with is kept in it now; a key kept there
    /// before is read for the account screen.
    func vaultOpened(_ vault: UnlockedVault) {
        guard record.isSignedIn, record.signedInWith == .key else { return }
        do {
            if let key {
                try AccountKeyVault.save(key, to: vault)
            } else {
                key = try AccountKeyVault.load(from: vault)
            }
        } catch {
            log.error("The account's key could not be kept in the vault: \(error.logKind, privacy: .public)")
        }
    }

    /// The vault was locked: the key is no longer held.
    func vaultLocked() {
        if record.signedInWith == .key { key = nil }
    }

    private func forgetKey() { key = nil }

    // MARK: §10.1 — the master password is not the account's password

    private func rememberForComparison(_ password: String) {
        let key = SymmetricKey(size: .bits256)
        passwordEcho = (key, Data(HMAC<SHA256>.authenticationCode(for: Data(password.utf8), using: key)))
    }

    /// Whether `candidate` is the account's password typed in this session: compared directly, as
    /// the HMAC of both under the same key made for this once (§10.1). Never a key derived from it,
    /// never an attempt to open the vault with it (the owner's rule).
    func isAccountPassword(_ candidate: String) -> Bool {
        guard let echo = passwordEcho else { return false }
        return HMAC<SHA256>.isValidAuthenticationCode(echo.code, authenticating: Data(candidate.utf8), using: echo.key)
    }

    /// After the master password's step: the comparison is done, the echo goes.
    func forgetAccountPassword() { passwordEcho = nil }

    // MARK: Signing out, devices

    /// `DELETE /v1/device` (§6.3): this Mac leaves the license whatever the server says; the key
    /// goes from the vault; the profiles stay.
    func signOut(vault: UnlockedVault?) async {
        guard let client else { return }
        isWorking = true
        defer { isWorking = false }
        let (updated, confirmed) = await client.signOut(record)
        record = updated
        save()
        if let vault { try? AccountKeyVault.remove(from: vault) }
        key = nil
        pendingSession = nil
        log.notice("Signed out of the account on this Mac (server confirmed: \(confirmed, privacy: .public))")
        recompute()
    }

    /// How the account screen asks for the license's Macs: the session, or the key.
    var deviceCredential: AccountAPI.Credential? {
        if record.signedInWith == .key { return key.map { .key($0) } }
        guard let token = record.session?.sessionToken else { return nil }
        if let expires = record.session?.expiresAt, expires <= Date() { return nil }
        return .session(token)
    }

    func devices() async -> Result<AccountDevices, AccountFailure> {
        if isPreview { return previewDevices.map { .success($0) } ?? .failure(.unreachable) }
        guard let client, let credential = deviceCredential else { return .failure(.server(AccountServerError(status: 401, code: "unauthorized"))) }
        let result = await client.devices(credential)
        if case .failure(.server(let error)) = result, error.code == "unauthorized" { dropSession() }
        return result
    }

    func unlink(_ device: AccountDevice) async -> Result<Void, AccountFailure> {
        guard let client, let credential = deviceCredential else { return .failure(.server(AccountServerError(status: 401, code: "unauthorized"))) }
        let result = await client.unlink(deviceID: device.deviceID, credential)
        if case .failure(.server(let error)) = result, error.code == "unauthorized" { dropSession() }
        return result
    }

    /// Unlinks another Mac while this one is being connected (`device_limit_reached`, §10.6): with
    /// the session or the key just given — this Mac has neither stored yet.
    func unlinkDuringActivation(_ device: AccountDevice) async -> Result<Void, AccountFailure> {
        guard let client else { return .failure(.unreachable) }
        let credential: AccountAPI.Credential
        if let session = pendingSession {
            credential = .session(session.token)
        } else if let key {
            credential = .key(key)
        } else {
            return .failure(.server(AccountServerError(status: 401, code: "unauthorized")))
        }
        isWorking = true
        defer { isWorking = false }
        return await client.unlink(deviceID: device.deviceID, credential)
    }

    /// `401 unauthorized` on the account screen: the session's token goes, its idle time stays for
    /// `account.no_session` (§4.2).
    private func dropSession() {
        record.session?.sessionToken = nil
        record.session?.expiresAt = nil
        save()
    }

    /// The trial's banner closed (`trial.started` shows until then, §8.5).
    func closeTrialNotice() {
        record.trialNoticeClosedFor = state?.entitlement?.licenseID
        save()
        recompute()
    }

    // MARK: Saving

    private func save() {
        guard !isPreview else { return }
        var written = record
        if let floor { written.clock = floor }
        do {
            try file.save(written)
            savedFloor = written.floorTime
            fileProblem = nil
        } catch {
            fileProblem = String(describing: error)
            log.error("account.json could not be written: \(error.logKind, privacy: .public)")
        }
    }
}
