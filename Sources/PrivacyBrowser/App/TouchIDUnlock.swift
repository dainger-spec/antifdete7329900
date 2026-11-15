import BrowserCore
import Darwin
import Foundation
import LocalAuthentication
import Security

/// Unlocking with Touch ID, the Mac's side (the rule and the record are the core's:
/// `BiometricUnlock`; docs/ARCHITECTURE.md, "Unlocking with Touch ID").
///
/// What is kept here is one item of this Mac's data-protection keychain: a random 256-bit key, one
/// per vault, under an access control that lets it be read only after Touch ID with the fingerprints
/// enrolled when it was kept (`biometryCurrentSet`: a fingerprint added or removed drops the item),
/// on this Mac only (`ThisDeviceOnly`: never in a backup, never on another Mac, never synced), and
/// by this app only — the keychain gives an item to the application identifier that kept it. The
/// key opens nothing alone: it unseals the vault's master key from the record beside the vault.
///
/// A profile's process cannot read it: it is started from `LumenProfile`, which is signed without
/// any entitlement that opens a keychain, and it locks itself out of securityd before Safari's code
/// loads (docs/IDENTITY.md, "The keychain"; the self-test asks a profile's process for this item).
///
/// A build that holds no application identifier — every development build, CI's, and a release made
/// without the provisioning profile — cannot keep the item at all: there the feature is absent
/// (`isOfferedHere`), not broken.
enum TouchIDUnlock {
    /// The item's service; its account is the vault's id.
    static let service = "io.lumenbrowser.Lumen.touch-id-unlock"

    // MARK: Whether it can be offered

    /// This copy of Lumen can keep the key: its signature carries the application identifier, to
    /// which the data-protection keychain opens (scripts/build-app.sh gives it with the
    /// provisioning profile, `NE=1` or `CAM=1`).
    static let buildCanKeepKey: Bool = {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        return SecTaskCopyValueForEntitlement(task, "com.apple.application-identifier" as CFString, nil) != nil
    }()

    /// What this Mac's Touch ID says now.
    enum Sensor: Equatable {
        /// No Touch ID on this Mac.
        case none
        /// It has Touch ID, and no fingerprint is enrolled.
        case notEnrolled
        /// It has Touch ID, which does not answer now: the lid is closed, or it is locked after
        /// failed tries until the Mac's password is typed.
        case notNow
        case ready
    }

    /// The sensor, and the enrolled fingerprints' set as the system names it (opaque; another
    /// value after a fingerprint is added or removed), when it can be read.
    static func sensor() -> (sensor: Sensor, fingerprints: Data?) {
        let context = LAContext()
        var error: NSError?
        let usable = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
        // Known once the policy was asked about, also when the answer is no.
        guard context.biometryType == .touchID else { return (.none, nil) }
        if usable { return (.ready, context.evaluatedPolicyDomainState) }
        if let error, error.domain == LAError.errorDomain, error.code == LAError.Code.biometryNotEnrolled.rawValue {
            return (.notEnrolled, nil)
        }
        return (.notNow, nil)
    }

    /// It is offered at all: this build can keep the key, and this Mac has Touch ID. Asked once —
    /// neither changes while the app runs.
    static let isOfferedHere: Bool = buildCanKeepKey && sensor().sensor != .none

    /// When this Mac started (Unix seconds): the same within one start, but for the clock's
    /// corrections (`BiometricUnlock.bootTolerance`). Not readable: the present moment, which no
    /// later reading equals — the master password is then asked, never skipped.
    static var bootTime: Int {
        var started = timeval()
        var size = MemoryLayout<timeval>.stride
        guard sysctlbyname("kern.boottime", &started, &size, nil, 0) == 0, started.tv_sec > 0 else {
            return Int(Date().timeIntervalSince1970)
        }
        return Int(started.tv_sec)
    }

    // MARK: The key in the keychain

    private static func item(_ vaultID: UUID?) -> [String: Any] {
        var item: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service,
                                   kSecUseDataProtectionKeychain as String: true]
        if let vaultID { item[kSecAttrAccount as String] = vaultID.uuidString }
        return item
    }

    /// Keeps `key` for the vault, in place of any kept before. Asks for nothing: Touch ID is asked
    /// when the key is read. Returns the keychain's status (`errSecSuccess`: kept).
    static func keep(_ key: Data, vaultID: UUID) -> OSStatus {
        remove(vaultID: vaultID)
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                                                           .biometryCurrentSet, &error) else {
            error?.release()
            return errSecParam
        }
        var attributes = item(vaultID)
        attributes[kSecValueData as String] = key
        attributes[kSecAttrAccessControl as String] = access
        attributes[kSecAttrSynchronizable as String] = false
        return SecItemAdd(attributes as CFDictionary, nil)
    }

    /// Whether the vault's key is in the keychain — asked without Touch ID and without a dialog:
    /// only that the item is there.
    static func isKept(vaultID: UUID) -> Bool {
        let context = LAContext()
        context.interactionNotAllowed = true
        var query = item(vaultID)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecUseAuthenticationContext as String] = context
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        return status == errSecSuccess || status == errSecInteractionNotAllowed
    }

    /// Removes the vault's key; with no vault named, every key this app kept (a vault set aside,
    /// the setting turned off).
    @discardableResult
    static func remove(vaultID: UUID? = nil) -> OSStatus {
        SecItemDelete(item(vaultID) as CFDictionary)
    }

    /// The accounts of the items under the service that this process is shown — attributes only,
    /// never a key, never a dialog (the self-test: the app sees its own, a profile's process none).
    static func keptAccounts() -> [String] {
        let context = LAContext()
        context.interactionNotAllowed = true
        var query = item(nil)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        query[kSecUseAuthenticationContext as String] = context
        var found: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &found) == errSecSuccess, let items = found as? [[String: Any]] else { return [] }
        return items.compactMap { $0[kSecAttrAccount as String] as? String }
    }

    // MARK: Opening the vault

    enum Opened {
        case vault(UnlockedVault)
        /// The person closed Touch ID's question: nothing changed.
        case cancelled
        /// The key is not in the keychain any more: the fingerprints changed, or it was removed.
        case keyGone
        /// Touch ID did not recognise the finger, or does not answer (the keychain's status).
        case failed(OSStatus)
        /// The key was read, and the record beside the vault is not the one sealed under it.
        case recordRefused
    }

    /// Asks Touch ID — the system's own question, with `reason` after the app's name — and opens
    /// the vault in `root` with the key it releases. Off the main thread: the call waits for the
    /// finger. The key is used here and nowhere else, and its bytes are cleared after.
    static func open(root: URL, record: BiometricUnlockRecord, reason: String, cancelTitle: String) async -> Opened {
        await Task.detached(priority: .userInitiated) { () -> Opened in
            let context = LAContext()
            context.localizedReason = reason
            // No "Use Password…" of the system's: what stands in for Touch ID is the master
            // password, in its field on the lock screen.
            context.localizedFallbackTitle = ""
            context.localizedCancelTitle = cancelTitle
            var query = item(record.vaultID)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            query[kSecUseAuthenticationContext as String] = context
            var found: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &found)
            switch status {
            case errSecSuccess:
                guard let data = found as? Data, data.count == 32 else { return .keyGone }
                var key = Data(data)
                defer { key.resetBytes(in: 0..<key.count) }
                guard let vault = try? BiometricUnlock.unlock(root: root, record: record, key: key) else { return .recordRefused }
                return .vault(vault)
            case errSecUserCanceled:
                return .cancelled
            case errSecItemNotFound:
                return .keyGone
            default:
                return .failed(status)
            }
        }.value
    }
}

/// What the lock screen and Settings › Security show of unlocking with Touch ID.
struct TouchIDStatus: Equatable {
    /// This copy of Lumen on this Mac offers it at all (`TouchIDUnlock.isOfferedHere`).
    var offered = false
    var sensor = TouchIDUnlock.Sensor.none
    /// The rule's answer for the vault on this Mac (`BiometricUnlock.decide`).
    var decision = BiometricUnlock.Decision.off

    /// Turned on: something is kept for this vault.
    var isOn: Bool { decision != .off }
    /// Touch ID may open the vault now, and answers.
    var unlocksNow: Bool { offered && sensor == .ready && decision == .touchID }
}

/// The texts of unlocking with Touch ID that are said in more than one place.
enum TouchIDText {
    /// Why the master password is asked this time though Touch ID is on (the lock screen).
    static func passwordAsked(_ reason: BiometricUnlock.PasswordReason) -> String {
        switch reason {
        case .restarted: return L("touchid.password.restarted")
        case .tooLong: return String(format: L("touchid.password.tooLong"), BiometricUnlock.passwordEveryDays)
        case .passwordChanged: return L("touchid.ended.passwordChanged")
        case .fingerprintsChanged, .keyGone: return L("touchid.ended.fingerprintsChanged")
        case .anotherVault: return L("touchid.ended.anotherVault")
        }
    }

    /// What the sensor says when it does not answer now; nil when it does.
    static func sensorNote(_ sensor: TouchIDUnlock.Sensor) -> String? {
        switch sensor {
        case .none, .ready: return nil
        case .notEnrolled: return L("touchid.sensor.notEnrolled")
        case .notNow: return L("touchid.sensor.notNow")
        }
    }
}
