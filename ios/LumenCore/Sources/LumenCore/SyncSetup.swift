import BrowserCore
import Foundation

/// Connecting this iPhone to the Mac's vault (the sync's step 2, ios/SYNC_PLAN.md): which vaults the
/// account has (`GET /v1/device/sync/vaults`, CONTRACT.md §16.1), and the master password turned once
/// into the key the iPhone keeps (`MasterVault.deviceUnlockKey`, the Mac's own code).
public enum SyncSetup {
    public struct Vault: Equatable, Sendable {
        public var vaultID: UUID
        public var changedAt: Date?

        public init(vaultID: UUID, changedAt: Date?) {
            self.vaultID = vaultID
            self.changedAt = changedAt
        }
    }

    /// The account's vaults from the server's answer, the last changed first; nil: not that answer.
    public static func vaults(_ data: Data) -> [Vault]? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let list = object["vaults"] as? [[String: Any]] else { return nil }
        let vaults = list.compactMap { entry -> Vault? in
            guard let text = entry["vaultID"] as? String, let id = UUID(uuidString: text) else { return nil }
            return Vault(vaultID: id, changedAt: AccountWire.time(entry["changedAt"] as? String))
        }
        return vaults.sorted { ($0.changedAt ?? .distantPast) > ($1.changedAt ?? .distantPast) }
    }

    public enum KeyOutcome: Equatable, Sendable {
        /// The password opens the vault: the key to keep.
        case key(Data)
        case wrongPassword
        /// The header is a newer version's: this iPhone needs the app updated first.
        case newerApp
        /// Not the vault asked for, or not a header at all: nothing is kept.
        case notThisVault
    }

    /// The key to keep for `vaultID`, from its header as the server gave it and the master password.
    /// Slow on purpose (the vault's key derivation, Argon2id on a Mac's vault): call it off the main thread.
    public static func unlockKey(password: String, header data: Data, vaultID: UUID) -> KeyOutcome {
        let header: VaultHeader
        do {
            header = try VaultHeader.decodeChecked(data)
        } catch CoreError.newerFormat {
            return .newerApp
        } catch CoreError.unsupportedFormat {
            return .newerApp
        } catch {
            return .notThisVault
        }
        // A server that serves another vault's header under this one's id is not believed.
        guard header.vaultID == vaultID || Faults.isActive(.syncHeaderOfAnotherVault) else { return .notThisVault }
        do {
            return .key(try MasterVault.deviceUnlockKey(password: password, header: header))
        } catch {
            return .wrongPassword
        }
    }

    /// Whether a kept key still opens the vault's header (false after the master password changed on
    /// the Mac: the iPhone asks for the new one).
    public static func opens(key: Data, header data: Data) -> Bool {
        guard let header = try? VaultHeader.decodeChecked(data) else { return false }
        return (try? MasterVault.unlock(header: header, root: FileManager.default.temporaryDirectory, deviceUnlockKey: key)) != nil
    }
}
