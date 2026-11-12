import Foundation
import LumenCore

/// Signing in, and what follows (the owner and the lead, 9 November; the server's docs/IPHONE.md and
/// CONTRACT.md §5–§9): login and password, an activation that says "ios", the signed document of
/// rights kept on the iPhone and read again every minute — the rights are its features and limits —
/// a fresh one asked for when it says so, and the server's final answers obeyed.
extension AppModel {
    /// How a step of signing in ended.
    enum SignInOutcome: Equatable {
        case signedIn
        /// The right password, and a code sent to the account's email first (§5.2).
        case needsCode(challenge: String)
        /// The robot check first (§5.5): shown in the app's own window, then the sign-in again.
        case needsRobotCheck
        case failed(String)
    }

    /// At launch: the decision from what is kept, a fresh document if signed in, and the minute's tick.
    func startAccount() {
        guard fixedAccess == nil else { return }
        decide()
        if account != nil { Task { await refreshAccount() } }
        accountTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.accountTick() }
        }
    }

    /// The decision (§8.2), from the kept record and the time that never goes back (§8.3).
    func decide() {
        guard fixedAccess == nil else { return }
        guard var record = AccountStore.record() else {
            apply(License.state(signedIn: false, entitlement: nil, at: Date()), account: nil, entitlement: nil)
            return
        }
        let before = record.clock.floorTime
        let t = record.clock.now(wall: Date(), uptime: ProcessInfo.processInfo.systemUptime)
        if record.clock.floorTime.timeIntervalSince(before) > 60 { AccountStore.save(record) }
        let checked = record.entitlement.flatMap {
            EntitlementVerifier.check($0, keys: AccountClient.keys, deviceID: record.deviceID, machineID: AccountStore.machineID).entitlement
        }
        apply(License.state(signedIn: true, entitlement: checked, at: t), account: record, entitlement: checked)
    }

    /// Every minute, and when the app comes to the front: decide again; ask for a fresh document
    /// when the kept one says so or gives less than everything — not sooner than the last failure allows.
    func accountTick() {
        guard fixedAccess == nil else { return }
        decide()
        guard account != nil, Date() >= nextRefreshAttempt else { return }
        if license.mode != .full || RefreshSchedule.refreshDue(entitlement: entitlement, at: Date()) {
            Task { await refreshAccount() }
        }
    }

    /// What the person is told about the account, above the plan: the server's last word, or where
    /// the document stands.
    var accountMessage: String? {
        if let accountNotice { return accountNotice }
        guard let account else { return nil }
        if account.appOutdated { return AccountText.outdated }
        switch license.mode {
        case .grace:
            let until = entitlement.map { L(" до %@", "\(Self.dateText($0.graceEndsAt))") } ?? ""
            return L("Не удаётся связаться с сервером Lumen. Lumen работает как обычно%@. Проверьте соединение.", "\(until)")
        case .unverified, .unreachable, .periodEnded:
            return license.access.reason
        case .full:
            // The document itself says the paid period ended, or the account is blocked: said as it is.
            return ["expired", "disabled"].contains(license.access.plan) ? license.access.reason : nil
        case .notSignedIn:
            return nil
        }
    }

    static func dateText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: Localization.isEnglish ? "en_US" : "ru_RU")
        formatter.dateStyle = .long
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    // MARK: Signing in

    /// Login and password (§5.2), then the activation of this iPhone.
    func signIn(email: String, password: String, robotToken: String? = nil) async -> SignInOutcome {
        let email = email.trimmingCharacters(in: .whitespaces)
        let body = AccountWire.loginBody(email: email, password: password, robotToken: robotToken)
        guard let answer = await AccountClient.send("POST", "v1/auth/login", body: body, token: nil) else {
            return .failed(AccountText.unreachable)
        }
        if answer.status == 202, let challenge = AccountClient.object(answer.data)?["challenge"] as? String {
            return .needsCode(challenge: challenge)
        }
        return await signedIn(email: email, answer: answer)
    }

    /// The code from the email (§5.2), then the activation.
    func confirmSignIn(email: String, code: String) async -> SignInOutcome {
        let email = email.trimmingCharacters(in: .whitespaces)
        let body = (try? JSONSerialization.data(withJSONObject: ["email": email, "code": code.trimmingCharacters(in: .whitespaces)])) ?? Data()
        guard let answer = await AccountClient.send("POST", "v1/auth/login/confirm", body: body, token: nil) else {
            return .failed(AccountText.unreachable)
        }
        return await signedIn(email: email, answer: answer)
    }

    /// The same code once more; what to tell the person.
    func resendCode(challenge: String) async -> String {
        let body = (try? JSONSerialization.data(withJSONObject: ["challenge": challenge])) ?? Data()
        guard let answer = await AccountClient.send("POST", "v1/auth/login/resend", body: body, token: nil) else { return AccountText.unreachable }
        if answer.status == 202 { return AccountText.codeResent }
        return AccountWire.refusal(answer.data).map(AccountText.refusal) ?? AccountText.unreachable
    }

    /// An answer to a sign-in or to its code: a session — the activation follows — or a refusal.
    private func signedIn(email: String, answer: (status: Int, data: Data)) async -> SignInOutcome {
        if answer.status == 200 || answer.status == 201, let token = AccountClient.object(answer.data)?["sessionToken"] as? String {
            return await activate(email: email, sessionToken: token)
        }
        guard let refusal = AccountWire.refusal(answer.data) else { return .failed(AccountText.unreachable) }
        // The planted fault: the robot check is not shown — the refusal's words and nothing else.
        if refusal.code == "robot_check", !Faults.isActive(.robotCheckNotShown) { return .needsRobotCheck }
        return .failed(AccountText.refusal(refusal))
    }

    /// The activation (§6.1): this iPhone's id and platform, how many profiles it holds, the app's
    /// version — nothing else. Its document is checked before anything is kept.
    private func activate(email: String, sessionToken: String) async -> SignInOutcome {
        let machineID = AccountStore.machineID
        let body = AccountWire.deviceBody(machineID: machineID, profileCount: sessions.count, appVersion: AccountClient.appVersion)
        let answer = await AccountClient.send("POST", "v1/devices/activate", body: body, token: sessionToken)
        // The session was needed for this one request: it is ended, whatever the answer.
        Task { _ = await AccountClient.send("POST", "v1/auth/logout", body: nil, token: sessionToken) }
        guard let answer else { return .failed(AccountText.unreachable) }
        guard answer.status == 200 else {
            return .failed(AccountWire.refusal(answer.data).map(AccountText.refusal) ?? AccountText.unreachable)
        }
        guard let object = AccountClient.object(answer.data), let device = object["device"] as? [String: Any],
              let deviceID = device["deviceID"] as? String, let deviceToken = object["deviceToken"] as? String,
              let envelope = object["entitlement"], JSONSerialization.isValidJSONObject(envelope),
              let document = try? JSONSerialization.data(withJSONObject: envelope) else { return .failed(AccountText.unreachable) }
        let check = EntitlementVerifier.check(document, keys: AccountClient.keys, deviceID: deviceID, machineID: machineID)
        guard case .valid = check else {
            NSLog("Lumen: the activation's document did not pass the check: %@", check.name)
            return .failed(check.meansAppOutdated ? AccountText.outdated : AccountText.unreachable)
        }
        let serverTime = AccountWire.time(object["serverTime"] as? String) ?? Date()
        AccountStore.save(AccountRecord(email: email, deviceID: deviceID, code: device["code"] as? String ?? "", deviceToken: deviceToken,
                                        entitlement: document,
                                        clock: EffectiveClock(floorTime: serverTime, floorUptime: ProcessInfo.processInfo.systemUptime),
                                        lastSuccessAt: serverTime))
        accountNotice = nil
        refreshFailures = 0
        nextRefreshAttempt = .distantPast
        decide()
        return .signedIn
    }

    // MARK: The document, kept fresh

    /// Asks the server for a fresh document (§6.2) and obeys its answer (§9.3, §9.4). True: the
    /// server answered in its own words (a document, or a final refusal).
    @discardableResult
    func refreshAccount() async -> Bool {
        guard fixedAccess == nil, !refreshing, let record = AccountStore.record() else { return false }
        refreshing = true
        defer { refreshing = false }
        let machineID = AccountStore.machineID
        // The synced profiles' tokens (CONTRACT.md §6.2): a profile on the Mac and here takes one place.
        // Refused for them (400 field profileTokens), the renewal is made again without them.
        var answer = await AccountClient.send("POST", "v1/device/entitlement", token: record.deviceToken,
                                              body: AccountWire.deviceBody(machineID: machineID, profileCount: sessions.count,
                                                                           appVersion: AccountClient.appVersion, profileTokens: SyncKeychain.profileTokens))
        if let refused = answer, refused.status == 400, AccountWire.refusal(refused.data)?.field == "profileTokens" {
            answer = await AccountClient.send("POST", "v1/device/entitlement", token: record.deviceToken,
                                              body: AccountWire.deviceBody(machineID: machineID, profileCount: sessions.count,
                                                                           appVersion: AccountClient.appVersion))
        }
        guard let answer else { return refreshFailed() }
        // Signed out, or signed in anew, while the request was on its way: its answer is nobody's.
        guard var kept = AccountStore.record(), kept.deviceToken == record.deviceToken else { return false }
        if answer.status == 200 {
            guard let object = AccountClient.object(answer.data), let envelope = object["entitlement"],
                  JSONSerialization.isValidJSONObject(envelope),
                  let document = try? JSONSerialization.data(withJSONObject: envelope) else { return refreshFailed() }
            let check = EntitlementVerifier.check(document, keys: AccountClient.keys, deviceID: kept.deviceID, machineID: machineID)
            if case .valid = check {
                // The new document replaces the kept one — also when it gives less (§9.4).
                let serverTime = AccountWire.time(object["serverTime"] as? String) ?? Date()
                kept.entitlement = document
                kept.clock = EffectiveClock(floorTime: serverTime, floorUptime: ProcessInfo.processInfo.systemUptime)
                kept.lastSuccessAt = serverTime
                kept.appOutdated = false
            } else if check.meansAppOutdated {
                // The server works and this app is too old to judge what it sent: the kept document stays.
                kept.appOutdated = true
            } else {
                // Changed on its way, or not the server's at all: nothing changes.
                NSLog("Lumen: a fresh document did not pass the check: %@", check.name)
                return refreshFailed()
            }
            AccountStore.save(kept)
            refreshFailures = 0
            nextRefreshAttempt = .distantPast
            decide()
            return true
        }
        if let refusal = AccountWire.refusal(answer.data),
           (answer.status == 401 && refusal.code == "device_revoked") || (answer.status == 409 && refusal.code == "machine_mismatch") {
            // Final (§9.4): this iPhone is no longer in the license. The token and the document go;
            // the profiles stay. (The planted fault: the answer is passed over.)
            if Faults.isActive(.revokedStaysSignedIn) { return true }
            AccountStore.save(nil)
            accountNotice = refusal.code == "device_revoked" ? AccountText.revoked : AccountText.machineMismatch
            decide()
            return true
        }
        return refreshFailed()
    }

    /// "Unreachable" (§9.3): nothing changes; the next try waits 1, 5, 15, 30, 60 minutes.
    private func refreshFailed() -> Bool {
        refreshFailures += 1
        nextRefreshAttempt = Date().addingTimeInterval(RefreshSchedule.retryDelay(afterFailures: refreshFailures))
        return false
    }

    /// Signing this iPhone out (§6.3): the token and the document go at once, whatever the server
    /// says or does not; the profiles stay, the ones that lived behind a proxy locked.
    func signOut() async {
        guard fixedAccess == nil, let record = AccountStore.record() else { return }
        // Signing out forgets the vault on this iPhone too (the sync plan's decision 1).
        SyncKeychain.erase()
        AccountStore.save(nil)
        accountNotice = nil
        decide()
        _ = await AccountClient.send("DELETE", "v1/device", body: nil, token: record.deviceToken)
    }
}
