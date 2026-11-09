import Foundation
import LumenCore
import Security

/// What the account keeps on this iPhone, in the app's own Keychain items — never in the person's
/// Passwords, never in iCloud (this device only):
/// - the iPhone's random identifier (the server's docs/IPHONE.md §2.1): made once, it outlives a
///   reinstall, and only its hash ever leaves the device (`PhoneID.machineID`);
/// - the record of this iPhone's place in a license (`AccountRecord`): the device token and the last
///   document of rights.
enum AccountStore {
    static let service = "io.lumenbrowser.ios.account"
    private static var cachedPhoneID: String?

    private static func read(_ name: String) -> Data? {
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: name,
                                      kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    private static func write(_ name: String, _ data: Data?) {
        SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: name] as CFDictionary)
        guard let data else { return }
        let item: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: name,
                                     kSecValueData: data, kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemAdd(item as CFDictionary, nil)
        if status != errSecSuccess { NSLog("Lumen: the Keychain refused the account's item %@: %ld", name, Int(status)) }
    }

    /// This iPhone's identifier, made the first time it is asked for.
    static func phoneID() -> String {
        if let cachedPhoneID { return cachedPhoneID }
        if let data = read("phone-id"), let id = String(data: data, encoding: .utf8), id.count == 64 {
            cachedPhoneID = id
            return id
        }
        let id = PhoneID.random()
        write("phone-id", Data(id.utf8))
        cachedPhoneID = id
        return id
    }

    /// What the server knows this iPhone by.
    static var machineID: String { PhoneID.machineID(of: phoneID()) }

    static func record() -> AccountRecord? {
        read("record").flatMap { try? JSONDecoder().decode(AccountRecord.self, from: $0) }
    }

    /// Keeps the record; nil removes it (signed out, unlinked).
    static func save(_ record: AccountRecord?) {
        write("record", record.flatMap { try? JSONEncoder().encode($0) })
    }
}
