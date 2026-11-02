import Foundation

/// What the screens read of the license: the mode, the document, the banners, and how long this
/// Mac works without the server — computed from `account.json` and the effective time alone.
public struct LicenseState: Equatable, Sendable {
    public var mode: LicenseMode
    /// The stored document, checked now; nil when there is none or it did not pass.
    public var entitlement: Entitlement?
    /// The stored document's check, nil when there is none.
    public var check: EntitlementCheck?
    public var banners: [LicenseBanner]
    public var allowedProfilesHere: Int
    /// Until when this Mac works as now without hearing from the server (the GRACE date); nil when
    /// it does not work now.
    public var worksWithoutServerUntil: Date?
    /// The effective time the state was made at.
    public var now: Date

    public init(mode: LicenseMode, entitlement: Entitlement?, check: EntitlementCheck?, banners: [LicenseBanner],
                allowedProfilesHere: Int, worksWithoutServerUntil: Date?, now: Date) {
        self.mode = mode
        self.entitlement = entitlement
        self.check = check
        self.banners = banners
        self.allowedProfilesHere = allowedProfilesHere
        self.worksWithoutServerUntil = worksWithoutServerUntil
        self.now = now
    }

    /// §8.2–§8.5 for `record`, at the effective time `t`, with this app's `keys` and this Mac's
    /// `machineID`.
    public static func of(_ record: AccountRecord, keys: [String: Data], machineID: String, at t: Date) -> LicenseState {
        var check: EntitlementCheck?
        if let envelope = record.entitlement, let deviceID = record.deviceID {
            check = EntitlementVerifier.check(envelope, keys: keys, deviceID: deviceID, machineID: machineID)
        } else if record.entitlement != nil {
            check = .wrongDevice
        }
        let entitlement = check?.entitlement
        let mode = LicenseDecision.mode(signedIn: record.isSignedIn, entitlement: entitlement, at: t)
        let banners = LicenseBanners.banners(.init(
            mode: mode, entitlement: entitlement, signedOutReason: record.signedOutReason, appOutdated: record.appOutdated,
            lastSuccessAt: record.lastSuccessAt, clockSkew: record.clockSkewSeconds,
            trialNoticeClosed: entitlement.map { record.trialNoticeClosedFor == $0.licenseID } ?? false,
            periodEndingClosed: record.periodEndingClosed, now: t))
        return LicenseState(mode: mode, entitlement: entitlement, check: check, banners: banners,
                            allowedProfilesHere: entitlement.map(LicenseDecision.allowedProfilesHere) ?? 0,
                            worksWithoutServerUntil: LicenseDecision.worksWithoutServerUntil(mode: mode, entitlement: entitlement), now: t)
    }
}

/// The account server's conversations that change this Mac's account state (§6, §9): each takes the
/// record as it is and gives back the record it becomes, which the caller saves.
public struct LicenseClient: Sendable {
    public var transport: any AccountTransport
    /// `PBEntitlementPublicKeys` (`EntitlementKeys.fromInfoPlist`).
    public var keys: [String: Data]
    /// This Mac's id, computed now (`MachineID`).
    public var machineID: String
    /// `<version> (<build>)` (`AccountAPI.appVersion`).
    public var appVersion: String

    /// The time an answer came at: what an older server's sign-in code is counted from (§5.2).
    public var now: @Sendable () -> Date = { Date() }

    public init(transport: any AccountTransport, keys: [String: Data], machineID: String, appVersion: String) {
        self.transport = transport
        self.keys = keys
        self.machineID = machineID
        self.appVersion = appVersion
    }

    // MARK: Signing in

    /// `POST /v1/auth/login` (§5.2): a session, or a letter with a code to type first. `robotToken`:
    /// after `403 robot_check` (§5.5).
    public func login(email: String, password: String, robotToken: String? = nil) async -> Result<LoginAnswer, AccountFailure> {
        let request = AccountAPI.login(email: email, password: password, robotToken: robotToken)
        guard let response = try? await transport.send(request) else { return .failure(.unreachable) }
        return AccountAPI.loginAnswer(from: response, receivedAt: now())
    }

    /// `POST /v1/auth/login/confirm`: the code from the letter (§5.2).
    public func confirmLogin(email: String, code: String) async -> Result<AccountSession, AccountFailure> {
        guard let response = try? await transport.send(AccountAPI.confirmLogin(email: email, code: code)) else { return .failure(.unreachable) }
        return AccountAPI.session(from: response)
    }

    /// `POST /v1/auth/login/resend`: the same code again; what the attempt is now (§5.2).
    public func resendLoginCode(_ challenge: ServerToken) async -> Result<LoginCode, AccountFailure> {
        guard let response = try? await transport.send(AccountAPI.resendLoginCode(challenge)) else { return .failure(.unreachable) }
        return AccountAPI.loginCode(from: response, receivedAt: now(), keeping: challenge)
    }

    /// What an activation did.
    public struct Activation: Sendable {
        public var record: AccountRecord
        public var entitlement: Entitlement
        /// The license is on its trial (`trial.started` on the activation's screen).
        public var trialStarted: Bool
        /// The clock is off from the server's by this much (over ten minutes): `clock.skew`.
        public var clockSkew: TimeInterval?
    }

    /// `POST /v1/devices/activate` (§6.1): with the session after an email and a password, or with
    /// the key. Succeeds only when the document that came passed every check; then the record holds
    /// the device, its token, the document, the server's time as the clock's floor.
    public func activate(_ credential: AccountAPI.Credential, label: String, profileCount: Int, record: AccountRecord,
                         session: AccountSession? = nil, wall: Date, uptime: TimeInterval) async -> Result<Activation, AccountFailure> {
        let request = AccountAPI.activate(credential, machineID: machineID, label: label, profileCount: profileCount, appVersion: appVersion)
        guard let response = try? await transport.send(request) else { return .failure(.unreachable) }
        let answer: AccountAPI.DocumentAnswer
        switch AccountAPI.documentAnswer(from: response) {
        case .failure(let failure): return .failure(failure)
        case .success(let value): answer = value
        }
        guard let device = answer.device, let token = answer.deviceToken, !token.isEmpty else { return .failure(.unreachable) }
        let check = EntitlementVerifier.check(answer.document, keys: keys, deviceID: device.deviceID, machineID: machineID)
        guard let entitlement = check.entitlement, let envelope = EntitlementVerifier.envelope(of: answer.document) else {
            return .failure(.document(check))
        }
        var updated = record
        updated.signedOutReason = nil
        updated.deviceID = device.deviceID
        updated.code = device.code
        updated.deviceToken = token
        updated.entitlement = envelope
        updated.lastSuccessAt = answer.serverTime
        updated.appOutdated = false
        updated.clock = .reset(serverTime: answer.serverTime, uptime: uptime)
        let skew = EffectiveClock.skew(wall: wall, serverTime: answer.serverTime)
        updated.clockSkewSeconds = skew
        updated.unlinkCooldownSeconds = answer.unlinkCooldownSeconds
        switch credential {
        case .session:
            updated.signedInWith = .email
            updated.session = session.map { AccountRecord.Session(sessionToken: $0.token, expiresAt: $0.expiresAt, idleTimeoutSeconds: $0.idleTimeoutSeconds) }
        case .key:
            updated.signedInWith = .key
            updated.session = nil
        }
        // Learned again from the key's view of its license (§11.1); until then, no email is assumed —
        // never a reminder by email promised that will not come.
        updated.emailLinked = nil
        return .success(Activation(record: updated, entitlement: entitlement, trialStarted: entitlement.plan == "trial", clockSkew: skew))
    }

    // MARK: Refreshing

    /// What a refresh did (§9.3–§9.4).
    public enum Refresh: Equatable, Sendable {
        /// A new document is stored — even a worse one (export-only after a refund, a revoked place).
        /// `paymentReceived`: it moved the paid period's end on (`account.payment_received`).
        case accepted(paymentReceived: Bool)
        /// No answer of the server's: nothing changed; retry later (`retryAfter` seconds at the
        /// earliest, when the server said so).
        case unreachable(retryAfter: Int?)
        /// The server said this Mac is out (`device_revoked`, `machine_mismatch`): token and document
        /// removed, profiles untouched.
        case signedOut(SignedOutReason)
        /// The server works and sent what this app cannot judge: the old document stays.
        case appOutdated
        /// Nothing to refresh: no device token.
        case notSignedIn
    }

    /// `POST /v1/device/entitlement` (§6.2), and what its answer makes of `record`.
    public func refresh(_ record: AccountRecord, profileCount: Int, wall: Date, uptime: TimeInterval) async -> (AccountRecord, Refresh) {
        guard let token = record.deviceToken, !token.isEmpty, let deviceID = record.deviceID else { return (record, .notSignedIn) }
        let request = AccountAPI.refresh(deviceToken: token, machineID: machineID, profileCount: profileCount, appVersion: appVersion)
        guard let response = try? await transport.send(request) else { return (record, .unreachable(retryAfter: nil)) }
        var updated = record
        switch AccountAPI.documentAnswer(from: response) {
        case .failure(.server(let error)):
            switch (error.status, error.code) {
            case (401, "device_revoked"):
                updated.signOut(because: .deviceRevoked)
                return (updated, .signedOut(.deviceRevoked))
            case (409, "machine_mismatch"):
                updated.signOut(because: .machineMismatch)
                return (updated, .signedOut(.machineMismatch))
            default:
                // 429, 503 server_busy and every other 4xx: "unreachable" for a refresh (§3, §9.3),
                // not tried again before the server said.
                return (record, .unreachable(retryAfter: ["rate_limited", "server_busy"].contains(error.code) ? error.retryAfter : nil))
            }
        case .failure:
            return (record, .unreachable(retryAfter: nil))
        case .success(let answer):
            let check = EntitlementVerifier.check(answer.document, keys: keys, deviceID: deviceID, machineID: machineID)
            if check.meansAppOutdated {
                updated.appOutdated = true
                updated.unlinkCooldownSeconds = answer.unlinkCooldownSeconds
                return (updated, .appOutdated)
            }
            guard let entitlement = check.entitlement, let envelope = EntitlementVerifier.envelope(of: answer.document) else {
                // A changed answer on the way, another device's document: as if no answer came.
                return (record, .unreachable(retryAfter: nil))
            }
            let previous = record.entitlement.flatMap {
                EntitlementVerifier.check($0, keys: keys, deviceID: deviceID, machineID: machineID).entitlement
            }
            updated.entitlement = envelope
            updated.appOutdated = false
            updated.lastSuccessAt = answer.serverTime
            updated.clock = .reset(serverTime: answer.serverTime, uptime: uptime)
            updated.clockSkewSeconds = EffectiveClock.skew(wall: wall, serverTime: answer.serverTime)
            updated.unlinkCooldownSeconds = answer.unlinkCooldownSeconds
            let paid = entitlement.plan != "trial" && entitlement.periodEndsAt.map { end in
                previous?.periodEndsAt.map { end > $0 } ?? (previous != nil)
            } == true
            return (updated, .accepted(paymentReceived: paid))
        }
    }

    // MARK: Signing out

    /// What a sign-out did (§6.3).
    public enum SignOut: Equatable, Sendable {
        /// This Mac is signed out here. `confirmed`: the server freed its place at once; otherwise
        /// it is freed when the device is unlinked on the site.
        case signedOut(confirmed: Bool)
        /// `429 unlink_cooldown`: another Mac of the license was unlinked recently. This one is NOT
        /// signed out — its token, document and session stay, it works as before — until `availableAt`
        /// (`signout.cooldown`); support can unlink it sooner.
        case cooldown(availableAt: Date?)
    }

    /// `DELETE /v1/device` (§6.3), then the session's logout. Whatever else the server answers — or
    /// if it does not answer — the token and the document go here, and this Mac is signed out; the
    /// profiles stay. Only the cooldown leaves everything as it was.
    public func signOut(_ record: AccountRecord) async -> (AccountRecord, SignOut) {
        var confirmed = false
        if let token = record.deviceToken, !token.isEmpty,
           let response = try? await transport.send(AccountAPI.signOutDevice(deviceToken: token)) {
            switch AccountAPI.failure(of: response) {
            case nil: confirmed = true
            case .server(let error)? where error.status == 401: confirmed = true
            case .server(let error)? where error.status == 429 && error.code == "unlink_cooldown":
                return (record, .cooldown(availableAt: error.availableAt))
            default: break
            }
        }
        if let session = record.session?.sessionToken {
            _ = try? await transport.send(AccountAPI.logout(session: session))
        }
        var updated = record
        updated.signOut(because: nil)
        updated.signedOutReason = nil
        return (updated, .signedOut(confirmed: confirmed))
    }

    // MARK: The account screen

    /// The license's Macs: with the session, or with the key.
    public func devices(_ credential: AccountAPI.Credential) async -> Result<AccountDevices, AccountFailure> {
        guard let response = try? await transport.send(AccountAPI.devices(credential)) else { return .failure(.unreachable) }
        return AccountAPI.devices(from: response)
    }

    // MARK: A purchase without registration: an email, a new key (§11.1)

    /// `POST /v1/anonymous/email`: a letter with a code goes to `email` when it has no account.
    public func linkEmail(key: AccountKey, purchaseCode: PurchaseCode, email: String, password: String, locale: String?) async -> Result<AccountAPI.CodeSent, AccountFailure> {
        let request = AccountAPI.linkEmail(key: key, purchaseCode: purchaseCode, email: email, password: password, locale: locale)
        guard let response = try? await transport.send(request) else { return .failure(.unreachable) }
        return AccountAPI.codeSent(from: response)
    }

    /// `POST /v1/anonymous/email/confirm`: the email linked, and a session — as after a registration.
    public func confirmEmail(key: AccountKey, email: String, code: String) async -> Result<AccountSession, AccountFailure> {
        guard let response = try? await transport.send(AccountAPI.confirmEmail(key: key, email: email, code: code)) else { return .failure(.unreachable) }
        return AccountAPI.session(from: response)
    }

    /// A new key for the license; the old one stops working and every Mac is unlinked (§11.1).
    public func replaceKey(_ proof: AccountAPI.KeyReplacementProof) async -> Result<AccountKey, AccountFailure> {
        guard let response = try? await transport.send(AccountAPI.replaceKey(proof)) else { return .failure(.unreachable) }
        return AccountAPI.newKey(from: response)
    }

    /// How long after a payment the key can be fetched again on the site (`GET /v1/plans`).
    public func keyRetrievalSeconds() async -> Result<Int, AccountFailure> {
        guard let response = try? await transport.send(AccountAPI.plans()) else { return .failure(.unreachable) }
        return AccountAPI.keyRetrievalSeconds(from: response)
    }

    /// Unlinks another Mac. `not_found` — already unlinked — is a success: the list is asked again.
    public func unlink(deviceID: String, _ credential: AccountAPI.Credential) async -> Result<Void, AccountFailure> {
        guard let response = try? await transport.send(AccountAPI.unlink(deviceID: deviceID, credential)) else { return .failure(.unreachable) }
        switch AccountAPI.failure(of: response) {
        case nil: return .success(())
        case .server(let error)? where error.code == "not_found": return .success(())
        case let failure?: return .failure(failure)
        }
    }
}
