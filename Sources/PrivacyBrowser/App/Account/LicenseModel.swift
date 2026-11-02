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
    /// (`AccountKeyVault`), and while the vault is unlocked; never anywhere else. Not kept ("don't
    /// remember the key", §10.1): only from the sign-in until its request is answered.
    private(set) var key: AccountKey?
    /// The account's password, as an HMAC under a key made for this once, until the master
    /// password's step compares it (§10.1, the owner's decision): never the password itself, never on
    /// disk; forgotten after the comparison.
    private var passwordEcho: (key: SymmetricKey, code: Data)?
    /// The key typed in this session, the same way (`AccountKeyEcho`): the master password must not be
    /// the key either (§10.1) — even when the key itself is not kept and was forgotten after its request.
    private var keyEcho: AccountKeyEcho?
    /// The choice on the key's screen (§10.1): keep the key in the vault — the default — or ask for it
    /// each time it is needed. Written to `account.json` (`rememberKey`) when the key connects this Mac.
    private var rememberTypedKey = true
    /// The vault while it is unlocked: where a kept key is written, replaced or removed.
    private weak var openVault: UnlockedVault?

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
    /// The decision changed (mode, banners, document, limit): the subscription's reminders follow it
    /// (`ExpiryNotifications`, set by the app's model; never for the self-test's licenses).
    var onStateChanged: (() -> Void)?
    /// A key has just connected this Mac.
    var onActivatedWithKey: (() -> Void)?

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
            onStateChanged?()
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
        switch result {
        case .unreachable, .notSignedIn:
            // Nothing came: the record stays as it is now — with whatever changed here meanwhile.
            break
        default:
            // The app's own notes made while the request was out (a banner closed, a session dropped,
            // an email learned) are kept: the answer is about the document. Signed out by the server,
            // its session goes as `signOut(because:)` says.
            var merged = updated
            merged.periodEndingClosed = record.periodEndingClosed
            merged.trialNoticeClosedFor = record.trialNoticeClosedFor
            if case .signedOut = result {} else {
                merged.session = record.session
                merged.emailLinked = record.emailLinked
            }
            record = merged
        }
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

    /// What the password gave.
    enum SignInResult: Equatable {
        /// A session: on to the activation.
        case signedIn
        /// The password is right; the server sent a code to the account's address first (§5.2).
        case code(LoginCode)
        case failed(AccountFailure)
    }

    /// `POST /v1/auth/login` (§5.2). The session is kept for the activation that follows; the
    /// password goes no further than the request and the comparison of §10.1. `robotToken`: the robot
    /// check's, after the server asked for one (§5.5) — good for this one request.
    func signIn(email: String, password: String, robotToken: String? = nil) async -> SignInResult {
        guard let client else { return .failed(.unreachable) }
        isWorking = true
        defer { isWorking = false }
        switch await client.login(email: email.trimmingCharacters(in: .whitespacesAndNewlines), password: password, robotToken: robotToken) {
        case .success(.session(let session)):
            pendingSession = session
            key = nil
            rememberForComparison(password)
            return .signedIn
        case .success(.code(let code)):
            // The password was right: §10.1's comparison holds it as for a session.
            pendingSession = nil
            key = nil
            rememberForComparison(password)
            return .code(code)
        case .failure(let failure):
            return .failed(failure)
        }
    }

    /// `POST /v1/auth/login/confirm`: the letter's code (§5.2); its session kept for the activation.
    func confirmLogin(email: String, code: String) async -> AccountFailure? {
        guard let client else { return .unreachable }
        isWorking = true
        defer { isWorking = false }
        let digits = code.filter { !$0.isWhitespace }
        switch await client.confirmLogin(email: email.trimmingCharacters(in: .whitespacesAndNewlines), code: digits) {
        case .success(let session):
            pendingSession = session
            key = nil
            return nil
        case .failure(let failure):
            return failure
        }
    }

    /// `POST /v1/auth/login/resend`: the same code once more, by the attempt's challenge (§5.2).
    func resendLoginCode(_ code: LoginCode) async -> Result<LoginCode, AccountFailure> {
        guard let client else { return .failure(.unreachable) }
        guard let challenge = code.challenge else { return .failure(.server(AccountServerError(status: 400, code: "login_expired"))) }
        isWorking = true
        defer { isWorking = false }
        return await client.resendLoginCode(challenge)
    }

    /// A key typed in: checked here before anything is sent, then kept in memory for the activation.
    /// `remember`: the vault keeps it after the activation (§10.1); false — forgotten right after it.
    func useKey(_ key: AccountKey, remember: Bool = true) {
        self.key = key
        rememberTypedKey = remember
        keyEcho = AccountKeyEcho(key)
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
            if case .key = credential {
                record.rememberKey = rememberTypedKey ? nil : false
                // Not remembered (§10.1): forgotten right after the request that needed it.
                if !rememberTypedKey { key = nil }
            }
            floor = record.clock
            save()
            savedFloor = record.floorTime
            failures = 0
            nextRetry = nil
            pendingSession = nil
            if let vault = vault ?? openVault { vaultOpened(vault) }
            recompute()
            if case .key = credential { onActivatedWithKey?() }
            return .success(ActivationOutcome(entitlement: activation.entitlement, trial: activation.trialStarted, clockSkew: activation.clockSkew))
        case .failure(let failure):
            if case .document(let check) = failure, check.meansAppOutdated { onAppOutdated?() }
            return .failure(failure)
        }
    }

    /// The person left the sign-in: nothing of it stays.
    func cancelSignIn() {
        pendingSession = nil
        if !record.isSignedIn || record.signedInWith != .key || !record.keepsKey { key = nil }
        passwordEcho = nil
        keyEcho = nil
    }

    // MARK: The vault

    /// The vault was created or unlocked: a key signed in with is kept in it now; a key kept there
    /// before is read for the account screen. "Don't remember the key" (§10.1): no copy is kept, and
    /// one kept before goes now.
    func vaultOpened(_ vault: UnlockedVault) {
        openVault = vault
        guard record.isSignedIn, record.signedInWith == .key else { return }
        do {
            if !record.keepsKey {
                try AccountKeyVault.remove(from: vault)
            } else if let key {
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
        openVault = nil
        if record.signedInWith == .key { key = nil }
    }

    private func forgetKey() { key = nil }

    /// `404 key_not_found` for the key the vault kept: it was replaced — by support, or on another
    /// Mac — so it goes from the vault, and the key is asked for anew (§10.1, §11.1). A key typed for
    /// one request is only told to be wrong.
    private func keptKeyNotFound(_ failure: AccountFailure, usedKeptKey: Bool) {
        guard usedKeptKey, case .server(let error) = failure, error.code == "key_not_found" else { return }
        key = nil
        if let openVault {
            do {
                try AccountKeyVault.remove(from: openVault)
            } catch {
                log.error("The replaced key could not be removed from the vault: \(error.logKind, privacy: .public)")
            }
        }
        log.notice("The key kept in the vault is no longer the license's (key_not_found): removed, to be asked for anew")
    }

    /// `emailLinked` of the key's view of its license (§11.1): kept for the texts shown offline.
    private func noteEmailLinked(_ linked: Bool?) {
        guard let linked, record.emailLinked != linked else { return }
        record.emailLinked = linked
        save()
    }

    /// No email is linked to this Mac's purchase: no letter will remind of the period's end (§11.1).
    var hasNoEmail: Bool { record.signedInWith == .key && record.emailLinked != true }

    /// The key is kept in the vault, and the vault is open: no field for it is needed.
    var keyAtHand: Bool { key != nil && record.keepsKey }

    /// A key typed for one request needs no vault; a kept key is replaced in the vault, which then
    /// must be open (else the old key would stay there).
    var vaultNeededForKeyReplacement: Bool { record.keepsKey && openVault == nil }

    // MARK: §10.1 — the master password is neither the account's password nor the license's key

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

    /// Whether `candidate` is the license's key (§10.1): the key typed in this session (its echo), or
    /// the key held now — kept in the vault and read from it at the unlock. Read as a key is read (§18)
    /// and compared in canonical form, in memory; never anything made of the master password but this
    /// comparison, never a try to open the vault with the key.
    func isLicenseKey(_ candidate: String) -> Bool {
        if keyEcho?.matches(candidate) == true { return true }
        return key?.isTyped(as: candidate) == true
    }

    /// After the master password's step: the comparisons are done, the echoes go.
    func forgetComparisons() {
        passwordEcho = nil
        keyEcho = nil
    }

    // MARK: Signing out, devices

    /// `DELETE /v1/device` (§6.3): this Mac leaves the license whatever the server says — the key
    /// goes from the vault, the profiles stay — except under the unlink cooldown: then nothing
    /// changes, and the account screen says until when (`signout.cooldown`).
    func signOut(vault: UnlockedVault?) async -> LicenseClient.SignOut? {
        guard let client else { return nil }
        isWorking = true
        defer { isWorking = false }
        let (updated, outcome) = await client.signOut(record)
        if case .cooldown = outcome {
            log.notice("Signing out of the account on this Mac waits for the license's unlink cooldown")
            return outcome
        }
        record = updated
        save()
        if let vault { try? AccountKeyVault.remove(from: vault) }
        key = nil
        pendingSession = nil
        let confirmed = outcome == .signedOut(confirmed: true)
        log.notice("Signed out of the account on this Mac (server confirmed: \(confirmed, privacy: .public))")
        recompute()
        return outcome
    }

    /// How the account screen asks for the license's Macs: the session, or the key — the one kept;
    /// a key account with an email linked may have a session too (§11.1).
    var deviceCredential: AccountAPI.Credential? {
        if record.signedInWith == .key, let key { return .key(key) }
        return validSession.map { .session($0) }
    }

    /// The session stored for the account screen, while it has not expired.
    var validSession: ServerToken? {
        guard let token = record.session?.sessionToken, !token.isEmpty else { return nil }
        if let expires = record.session?.expiresAt, expires <= Date() { return nil }
        return token
    }

    /// The license's Macs. `typedKey`: a key typed for this request alone — not kept, forgotten by the
    /// caller after it (§10.1: the key not remembered, or the vault locked).
    func devices(typedKey: AccountKey? = nil) async -> Result<AccountDevices, AccountFailure> {
        if isPreview { return previewDevices.map { .success($0) } ?? .failure(.unreachable) }
        guard let client, let credential = typedKey.map({ AccountAPI.Credential.key($0) }) ?? deviceCredential else {
            return .failure(.server(AccountServerError(status: 401, code: "unauthorized")))
        }
        let result = await client.devices(credential)
        switch result {
        case .success(let list):
            if case .key = credential { noteEmailLinked(list.emailLinked) }
        case .failure(let failure):
            if case .server(let error) = failure, error.code == "unauthorized" { dropSession() }
            if case .key = credential { keptKeyNotFound(failure, usedKeptKey: typedKey == nil) }
        }
        return result
    }

    func unlink(_ device: AccountDevice, typedKey: AccountKey? = nil) async -> Result<Void, AccountFailure> {
        guard let client, let credential = typedKey.map({ AccountAPI.Credential.key($0) }) ?? deviceCredential else {
            return .failure(.server(AccountServerError(status: 401, code: "unauthorized")))
        }
        let result = await client.unlink(deviceID: device.deviceID, credential)
        if case .failure(let failure) = result {
            if case .server(let error) = failure, error.code == "unauthorized" { dropSession() }
            if case .key = credential { keptKeyNotFound(failure, usedKeptKey: typedKey == nil) }
        }
        return result
    }

    // MARK: A purchase without registration: an email, a new key (§11.1)

    /// No key to send: neither kept nor typed.
    private static let noKey = AccountFailure.server(AccountServerError(status: 400, code: "invalid_key"))

    /// `POST /v1/anonymous/email`: an email to link, proved with the key — kept, or typed for this —
    /// and the purchase code, which the app asks for each time and never keeps.
    func linkEmail(typedKey: AccountKey?, purchaseCode: PurchaseCode, email: String, password: String) async -> Result<AccountAPI.CodeSent, AccountFailure> {
        guard let client else { return .failure(.unreachable) }
        guard let key = typedKey ?? key else { return .failure(Self.noKey) }
        isWorking = true
        defer { isWorking = false }
        let result = await client.linkEmail(key: key, purchaseCode: purchaseCode, email: email.trimmingCharacters(in: .whitespacesAndNewlines),
                                            password: password, locale: Localization.languageCode == "ru" ? "ru" : "en")
        if case .failure(let failure) = result { keptKeyNotFound(failure, usedKeptKey: typedKey == nil) }
        return result
    }

    /// `POST /v1/anonymous/email/confirm`: the six digits from the letter. The email is then linked —
    /// a way to recover access, nothing reissued: the key works on, and this Mac stays connected by it
    /// (`via` stays the key's). The session is kept for the account screen (§4.2).
    func confirmEmail(typedKey: AccountKey?, email: String, code: String) async -> AccountFailure? {
        guard let client else { return .unreachable }
        guard let key = typedKey ?? key else { return Self.noKey }
        isWorking = true
        defer { isWorking = false }
        switch await client.confirmEmail(key: key, email: email.trimmingCharacters(in: .whitespacesAndNewlines),
                                         code: code.trimmingCharacters(in: .whitespacesAndNewlines)) {
        case .success(let session):
            record.session = AccountRecord.Session(sessionToken: session.token, expiresAt: session.expiresAt, idleTimeoutSeconds: session.idleTimeoutSeconds)
            record.emailLinked = true
            save()
            log.notice("An email was linked to this Mac's purchase")
            return nil
        case .failure(let failure):
            if case .server(let error) = failure, error.code == "email_already_linked" { noteEmailLinked(true) }
            keptKeyNotFound(failure, usedKeptKey: typedKey == nil)
            return failure
        }
    }

    /// What a key's replacement did.
    struct KeyReplacement {
        /// The new key: shown once (`key.replaced`); kept nowhere else unless the vault keeps it.
        var key: AccountKey
        /// The vault keeps it instead of the old one (§10.1).
        var kept: Bool
        /// Nil: this Mac is connected again with it. Else why not — it is unlinked with every Mac of
        /// the license, and asks for the new key at its next refresh (§9.4).
        var reconnection: AccountFailure?
    }

    /// Replaces the license's key (§11.1): the old one stops working at once and every Mac of the
    /// license is unlinked, this one too — so this Mac is connected again right away with the new key,
    /// which the vault keeps instead of the old one when the key is remembered. `label`: this Mac's, as
    /// the license's list showed it; an activation sends only what the person typed (§1).
    func replaceKey(_ proof: AccountAPI.KeyReplacementProof, label: String) async -> Result<KeyReplacement, AccountFailure> {
        guard let client else { return .failure(.unreachable) }
        isWorking = true
        defer { isWorking = false }
        let newKey: AccountKey
        switch await client.replaceKey(proof) {
        case .success(let value):
            newKey = value
        case .failure(let failure):
            if case .purchase(let used, _) = proof { keptKeyNotFound(failure, usedKeptKey: used == key) }
            return .failure(failure)
        }
        // The old key works no more: it is not held, and not kept.
        key = nil
        var kept = false
        if record.keepsKey, let vault = openVault {
            do {
                try AccountKeyVault.save(newKey, to: vault)
                kept = true
            } catch {
                log.error("The new key could not be kept in the vault: \(error.logKind, privacy: .public)")
            }
        }
        keyEcho = AccountKeyEcho(newKey)
        log.notice("The license's key was replaced; this Mac connects again with the new one")
        // Replaced with the key and the purchase code, a linked email is unlinked and its sessions
        // closed (v2026.11.04, F3): this Mac's session goes now — whether or not it connects again
        // below — and whether an email is linked is asked again (an older server kept it; the
        // license's view says which).
        if case .purchase = proof {
            record.session = nil
            record.emailLinked = nil
            save()
        }
        // Every Mac of the license is unlinked (§11.1): this one is connected again, with the new key.
        let emailLinked = record.emailLinked
        let session = record.session
        let result = await client.activate(.key(newKey), label: String(label.prefix(64)), profileCount: profilesHere().count, record: record,
                                           wall: Date(), uptime: ProcessInfo.processInfo.systemUptime)
        var reconnection: AccountFailure?
        switch result {
        case .success(let activation):
            record = activation.record
            record.emailLinked = emailLinked
            record.session = session
            floor = record.clock
            save()
            savedFloor = record.floorTime
            failures = 0
            nextRetry = nil
        case .failure(let failure):
            reconnection = failure
        }
        if kept { key = newKey }
        recompute()
        return .success(KeyReplacement(key: newKey, kept: kept, reconnection: reconnection))
    }

    /// For "Lost your key?" (`key.no_reset`): how long after a payment the key can be fetched again on
    /// the site — from the server alone (§17.1); nil when it did not answer.
    func keyRetrievalSeconds() async -> Int? {
        guard !isPreview, let client else { return nil }
        return try? await client.keyRetrievalSeconds().get()
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

    /// The period-end warning closed (§8.5 item 10): for this end of the period, at the level it
    /// was shown — the week's comes back for the last day, the last day's does not.
    func closePeriodEnding(endsAt: Date, final: Bool) {
        record.periodEndingClosed = AccountRecord.PeriodEndingClosed(endsAt: endsAt, final: final)
        save()
        recompute()
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
