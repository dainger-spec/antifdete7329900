import Foundation
import LocalAuthentication
import Security

/// What the sync keeps on this iPhone (ios/SYNC_PLAN.md, decisions 1 and 11): the key that opens the
/// vault in place of the master password (`MasterVault.deviceUnlockKey`), and which vault it is. The
/// master password itself is kept nowhere.
///
/// The key is a Keychain item of this app's, this device only — never iCloud, never the person's
/// Passwords — behind the person's presence: Face ID, Touch ID or the passcode at each read. Signing
/// out and "forget the vault" erase it (`erase`).
enum SyncKeychain {
    static let service = "io.lumenbrowser.ios.sync"

    /// The vault this iPhone syncs with, and its kept key.
    struct Kept: Equatable {
        var vaultID: UUID
        var unlockKey: Data
    }

    private static func base(_ name: String) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: name]
    }

    /// Whether a key is kept, without reading it (no Face ID asked).
    static var hasKey: Bool {
        var query = base("unlock-key")
        query[kSecUseAuthenticationUI] = kSecUseAuthenticationUISkip
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        return status == errSecSuccess || status == errSecInteractionNotAllowed
    }

    static var vaultID: UUID? {
        var query = base("vault-id")
        query[kSecReturnData] = true
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data,
              let text = String(data: data, encoding: .utf8) else { return nil }
        return UUID(uuidString: text)
    }

    /// Keeps the key behind the person's presence. False: the Keychain refused it (no passcode set on
    /// this iPhone: such a key would lie unprotected, and the app does not keep it then).
    @discardableResult
    static func keep(_ kept: Kept) -> Bool {
        erase()
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(nil, protection.accessible, protection.flags, &error) else { return false }
        var item = base("unlock-key")
        item[kSecValueData] = kept.unlockKey
        item[kSecAttrAccessControl] = access
        guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { return false }
        var id = base("vault-id")
        id[kSecValueData] = Data(kept.vaultID.uuidString.utf8)
        id[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(id as CFDictionary, nil) == errSecSuccess else { erase(); return false }
        return true
    }

    /// The kept key, read behind Face ID or the passcode (`reason` is shown with the prompt). Nil:
    /// none kept, or the person cancelled.
    static func read(reason: String) -> Kept? {
        guard let vaultID else { return nil }
        let context = LAContext()
        context.localizedReason = reason
        var query = base("unlock-key")
        query[kSecReturnData] = true
        query[kSecUseAuthenticationContext] = context
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let key = result as? Data else { return nil }
        return Kept(vaultID: vaultID, unlockKey: key)
    }

    /// Forgets the vault on this iPhone: the key, which vault it was, the iPhone's copy of it and the
    /// server's generation kept for it. The sessions made from its profiles stay, as the iPhone's own.
    static func erase() {
        SecItemDelete(base("unlock-key") as CFDictionary)
        SecItemDelete(base("vault-id") as CFDictionary)
        try? FileManager.default.removeItem(at: vaultFolder)
        UserDefaults.standard.removeObject(forKey: generationKey)
    }

    /// The iPhone's copy of the vault (the Mac's files, encrypted as on the Mac).
    static var vaultFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("sync-vault", isDirectory: true)
    }

    /// The server's generation of the vault, kept for the next run (CONTRACT.md §16.2; nothing secret).
    static let generationKey = "sync.generation"
    static var generation: String? {
        get { UserDefaults.standard.string(forKey: generationKey) }
        set { UserDefaults.standard.set(newValue, forKey: generationKey) }
    }

    /// Only while a passcode is set, Face ID, Touch ID or the passcode at each read. A DEBUG build's
    /// test may keep the key without them (LUMEN_TEST_SYNC_NO_PRESENCE): a simulator in a test has
    /// no passcode and no one to look at it.
    private static var protection: (accessible: CFString, flags: SecAccessControlCreateFlags) {
        #if DEBUG
        if ProcessInfo.processInfo.environment["LUMEN_TEST_SYNC_NO_PRESENCE"] == "1" {
            return (kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly, [])
        }
        #endif
        return (kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly, .userPresence)
    }
}
