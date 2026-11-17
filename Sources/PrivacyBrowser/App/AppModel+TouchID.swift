import BrowserCore
import Foundation
import os
import Security

/// Unlocking with Touch ID, the app model's part (docs/ARCHITECTURE.md, "Unlocking with Touch ID"):
/// what the lock screen and Settings › Security are shown, turning it on and off, and keeping what
/// is kept in step with the master password. The unlock itself is `AppModel.unlockWithTouchID`;
/// the rule is the core's (`BiometricUnlock`), the keychain and the sensor `TouchIDUnlock`'s.
extension AppModel {
    /// The state as it is now: whether this Mac and this build offer it, what the sensor says, and
    /// the rule's answer for the vault. A reason that ends it removes what is kept and says why on
    /// the lock screen; it is then off until turned on again in Settings.
    func refreshTouchID() {
        guard TouchIDUnlock.isOfferedHere else {
            if touchID != TouchIDStatus() { touchID = TouchIDStatus() }
            return
        }
        let reading = TouchIDUnlock.sensor()
        var status = TouchIDStatus(offered: true, sensor: reading.sensor, decision: .off)
        if let header = try? MasterVault.readHeader(in: root) {
            let record = BiometricUnlock.load(in: root)
            status.decision = BiometricUnlock.decide(record: record, header: header, now: Date(), bootTime: TouchIDUnlock.bootTime,
                                                     biometryState: reading.fingerprints,
                                                     keyKept: record.map { TouchIDUnlock.isKept(vaultID: $0.vaultID) } ?? false)
            if case .password(let reason) = status.decision, BiometricUnlock.ends(reason) {
                forgetTouchID(refreshing: false)
                if phase != .unlocked { touchIDNote = TouchIDText.passwordAsked(reason) }
                status.decision = .off
            }
        }
        if touchID != status { touchID = status }
    }

    /// Removes what is kept for Touch ID: the record beside the vault and every key in the keychain.
    func forgetTouchID(refreshing: Bool = true) {
        BiometricUnlock.remove(in: root)
        if TouchIDUnlock.buildCanKeepKey { TouchIDUnlock.remove() }
        if refreshing { refreshTouchID() }
    }

    /// After an unlock with the master password, while Touch ID unlocking is on: a new key and a
    /// new record, with this typing's time and this start of the Mac — the days start anew. Not
    /// kept (the keychain refused): it is off, rather than on and not working.
    func touchIDAfterPasswordUnlock(_ vault: UnlockedVault) {
        touchIDSpent = false
        touchIDNote = nil
        guard TouchIDUnlock.isOfferedHere, BiometricUnlock.load(in: root) != nil else { return }
        refreshTouchID()
        // Ended by the refresh (the password or the fingerprints changed): it stays off. With the
        // sensor not answering now (the lid is closed) what is kept stays as it is: the days start
        // anew at the next typing of the password with Touch ID there.
        guard touchID.isOn, touchID.sensor == .ready else { return }
        if keepForTouchID(vault) != nil { forgetTouchID() }
        refreshTouchID()
    }

    /// Settings › Security: turns unlocking with Touch ID on. The master password is typed once
    /// more — an unlocked, unattended Mac must not be enough to add a way in. Returns what went
    /// wrong, in the person's words; nil: it is on.
    func turnTouchIDOn(password: String) async -> String? {
        guard TouchIDUnlock.isOfferedHere, let vault = repository?.vault else { return L("touchid.on.locked") }
        guard TouchIDUnlock.sensor().sensor == .ready else { return TouchIDText.sensorNote(TouchIDUnlock.sensor().sensor) ?? L("touchid.sensor.notNow") }
        guard await verifyMasterPassword(password) else { return L("unlock.wrong") }
        if let problem = keepForTouchID(vault) {
            forgetTouchID()
            return problem
        }
        refreshTouchID()
        return nil
    }

    /// The first run's offer (`FirstRunTouchIDView`), right after the vault was made with the
    /// master password just typed — no second typing; the system's own Touch ID question first,
    /// then what is kept, as Settings › Security keeps it. Off later in Settings › Security.
    func turnTouchIDOnAtFirstRun() async -> FirstRunTouchIDOutcome {
        guard TouchIDUnlock.isOfferedHere, let vault = repository?.vault else { return .failed(L("touchid.on.locked")) }
        let sensor = TouchIDUnlock.sensor().sensor
        guard sensor == .ready else { return .failed(TouchIDText.sensorNote(sensor) ?? L("touchid.sensor.notNow")) }
        switch await TouchIDUnlock.confirm(reason: L("touchid.reason.turnOn"), cancelTitle: L("common.cancel")) {
        case nil: return .cancelled
        case false?: return .failed(L("firstRun.touchID.notRecognised"))
        case true?: break
        }
        if let problem = keepForTouchID(vault) {
            forgetTouchID()
            return .failed(problem)
        }
        refreshTouchID()
        return .on
    }

    /// Settings › Security: turns it off. Nothing is asked: it only takes a way in away.
    func turnTouchIDOff() {
        forgetTouchID()
    }

    /// Makes the key and the record for `vault` and keeps them: the key first, the record once the
    /// key is kept. Returns what went wrong; nil: kept.
    private func keepForTouchID(_ vault: UnlockedVault) -> String? {
        let reading = TouchIDUnlock.sensor()
        do {
            var kept = try BiometricUnlock.enroll(vault, now: Date(), bootTime: TouchIDUnlock.bootTime, biometryState: reading.fingerprints)
            defer { kept.key.resetBytes(in: 0..<kept.key.count) }
            let status = TouchIDUnlock.keep(kept.key, vaultID: vault.vaultID)
            guard status == errSecSuccess else {
                Logger(subsystem: "PrivacyBrowser", category: "Vault").error("Touch ID unlock: the keychain did not keep the key: \(status, privacy: .public)")
                return String(format: L("touchid.on.keychain"), Int(status))
            }
            try BiometricUnlock.save(kept.record, in: root)
            return nil
        } catch {
            return errorText(error)
        }
    }
}
