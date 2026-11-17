import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Sync through the Lumen account (`DeviceSettings.SyncTarget.account`; the account server's
/// docs/CONTRACT.md §16): the same encrypted vault as a folder's or a server's of one's own — the same
/// engine, the same objects, ciphertext only — kept by the Lumen server, which Lumen for iPhone reads
/// with the same account (it finds the vault with `GET /v1/device/sync/vaults`, and opens it with the
/// master password).
///
/// The transport is `HTTPSyncTransport` with the account server's address (`PBAccountServerURL`) and
/// this Mac's device token (§16.1): no address or token is typed in, and none is stored with the target.
public enum AccountSync {
    /// Whether "Lumen account" is offered as a place to sync to: this Mac signed in to an account (it
    /// holds a device token). A Mac's sync is in every plan, the free level included — the server does
    /// not hold it back after the paid period, and its space follows the plan, 100 MiB at least (the
    /// server's docs/SYNC_SERVER.md, question 6 and "Квота") — but not on an account the server has
    /// disabled, whose sync it refuses (`403 account_disabled`).
    public static func isOffered(signedIn: Bool, entitlement: Entitlement?) -> Bool {
        guard signedIn else { return false }
        return entitlement?.exportReason != "account_disabled"
    }

    /// The transport for this Mac's vault: `vaultID` is the vault's own (`UnlockedVault.vaultID`), the
    /// one its header names and an iPhone checks. `allowInsecureLocalhost` only for a development
    /// build's own server on this Mac.
    public static func transport(server: URL, deviceToken: ServerToken, vaultID: UUID, allowInsecureLocalhost: Bool = false,
                                 session: URLSession = .shared) throws -> HTTPSyncTransport {
        try HTTPSyncTransport(configuration: .init(baseURL: server, vaultID: vaultID, bearerToken: deviceToken.unredacted(),
                                                   allowInsecureLocalhost: allowInsecureLocalhost),
                              session: session)
    }

    /// What a failed run through the account means — a state, said to the person, and what the app
    /// does about it (§16.1). Nothing on this Mac is changed by any of them.
    public enum Outcome: Equatable, Sendable {
        /// `409 generation_changed`: the server's data changed under the run (§16.2). Nothing more was
        /// written and nothing is said; the next run starts over — at once, once.
        case generationChanged
        /// `401`: the server no longer knows the device token. The license is renewed: the server
        /// then says `device_revoked`, and this Mac is signed out (§9.4).
        case unauthorized
        /// `403 forbidden`: this Mac's vault is synced by another Lumen account.
        case anotherAccount
        /// `403 too_many_vaults`: the account has as many vaults as it may.
        case tooManyVaults
        /// `403 account_disabled`.
        case accountDisabled
        /// `403 sync_on_hold`: a device new to the account; sync opens then (nil: the server did not
        /// say when). Nothing is asked of the server before.
        case onHold(until: Date?)
        /// `403 sync_not_in_plan`: an iPhone's refusal, which a Mac is not given; said if it ever is.
        case notInPlan
        /// `429`: too many requests; in how many seconds to ask again, when the server said it.
        case rateLimited(retryAfter: Int?)
        /// `507 quota_exceeded` / `413 too_large` on what had to go first (the vault's header): the
        /// engine defers every other object it is said of, and the run goes on.
        case overQuota
        case tooLarge
        /// Anything else: said as the error it is.
        case other
    }

    public static func outcome(of error: Error) -> Outcome {
        if let refusal = error as? SyncServerRefusal {
            switch (refusal.status, refusal.code) {
            case (409, "generation_changed"): return .generationChanged
            case (401, _): return .unauthorized
            case (403, "forbidden"): return .anotherAccount
            case (403, "too_many_vaults"): return .tooManyVaults
            case (403, "account_disabled"): return .accountDisabled
            case (403, "sync_on_hold"): return .onHold(until: refusal.availableAt)
            case (403, "sync_not_in_plan"): return .notInPlan
            case (429, _): return .rateLimited(retryAfter: refusal.retryAfter)
            case (507, _): return .overQuota
            case (413, _): return .tooLarge
            default: return .other
            }
        }
        if case CoreError.syncServer(let status, _) = error {
            switch status {
            case 401: return .unauthorized
            case 429: return .rateLimited(retryAfter: nil)
            case 507: return .overQuota
            case 413: return .tooLarge
            default: return .other
            }
        }
        return .other
    }
}
