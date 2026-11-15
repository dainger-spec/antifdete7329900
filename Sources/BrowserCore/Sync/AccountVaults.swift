import Foundation

/// One of the account's vaults on the Lumen server, as its list names it (the server's
/// docs/CONTRACT.md §16.1, `GET /v1/device/sync/vaults`): the vault's ID and when it was last
/// written to — no name, no size, no count; the server knows none.
public struct AccountVault: Equatable, Sendable, Identifiable {
    public var vaultID: UUID
    public var changedAt: Date?

    public init(vaultID: UUID, changedAt: Date?) {
        self.vaultID = vaultID
        self.changedAt = changedAt
    }

    public var id: UUID { vaultID }
}

/// The account's vaults, asked with this Mac's device token before it has a vault of its own
/// (`VaultRestore`): the answer as the state it is, each said to the person in words of its own.
/// Nothing on this Mac or on the server is changed by asking.
public enum AccountVaults {
    public enum State: Equatable, Sendable {
        /// The account's vaults, the last changed first.
        case vaults([AccountVault])
        /// `200` with none: sync was never turned on for this account, or its sync data was deleted
        /// on the account page — or the account never paid, and the server keeps none for it.
        case noVaults
        /// `403 sync_not_in_plan`: sync is the server's only while a paid plan runs — not on the
        /// trial, without a plan, or after the paid period ended (the owner's decision of 15 November
        /// 2026). A payer's vaults stay on the server and are here again after a payment.
        case notInPlan
        /// `403 sync_on_hold`: this Mac is new to the account, and the server gives it the account's
        /// vaults from then on (nil: it did not say when).
        case onHold(until: Date?)
        /// `403 account_disabled`.
        case accountDisabled
        /// `401`: the server does not know this Mac's token — it is not signed in (any more).
        case signedOut
        /// `429`: in how many seconds to ask again, when the server said it.
        case rateLimited(retryAfter: Int?)
        /// No answer of the server's.
        case unreachable
        /// Any other refusal, by its status and code.
        case refused(status: Int, code: String)
    }

    public static func state(of result: Result<[AccountVault], AccountFailure>) -> State {
        switch result {
        case .success(let vaults):
            return vaults.isEmpty ? .noVaults : .vaults(vaults)
        case .failure(.unreachable), .failure(.document):
            return .unreachable
        case .failure(.server(let error)):
            switch (error.status, error.code) {
            case (401, _): return .signedOut
            case (403, "sync_not_in_plan"): return .notInPlan
            case (403, "sync_on_hold"): return .onHold(until: error.availableAt)
            case (403, "account_disabled"): return .accountDisabled
            case (429, _): return .rateLimited(retryAfter: error.retryAfter)
            default: return .refused(status: error.status, code: error.code)
            }
        }
    }

    /// The same states for a refusal met while a vault's header or its objects are read (the sync
    /// endpoints' own answers, `SyncServerRefusal`); nil for an error that is none of them.
    public static func state(of error: Error) -> State? {
        if let refusal = error as? SyncServerRefusal {
            switch (refusal.status, refusal.code) {
            case (401, _): return .signedOut
            case (403, "sync_not_in_plan"): return .notInPlan
            case (403, "sync_on_hold"): return .onHold(until: refusal.availableAt)
            case (403, "account_disabled"): return .accountDisabled
            case (429, _): return .rateLimited(retryAfter: refusal.retryAfter)
            default: return .refused(status: refusal.status, code: refusal.code)
            }
        }
        if case CoreError.syncServer(let status, _) = error {
            switch status {
            case 401: return .signedOut
            case 429: return .rateLimited(retryAfter: nil)
            default: return .refused(status: status, code: "")
            }
        }
        return nil
    }
}
