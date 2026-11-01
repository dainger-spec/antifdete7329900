import Foundation

/// A banner about the license above the profiles (the server's `docs/CONTRACT.md` §8.5). One is
/// shown — the most important whose condition holds — with "N more" beside it; the order below is
/// the contract's (the owner's decision of 1 November). Texts: §17.4, word for word, in the app's
/// localization under the contract's keys.
public enum LicenseBanner: Equatable, Sendable {
    /// `device.revoked`: the server said this Mac was unlinked.
    case deviceRevoked
    /// `device.machine_mismatch`: the token belongs to another Mac (the app's files were moved).
    case machineMismatch
    /// `mode.not_signed_in`.
    case notSignedIn
    /// `error.account_disabled`: export-only because the account is blocked.
    case accountDisabled
    /// `export.period_ended` / `export.period_ended.member`.
    case periodEnded(owner: Bool, endedAt: Date?)
    /// `export.no_license`.
    case noLicense
    /// `mode.grace.unreachable` / `mode.grace.outdated`; `until`: the GRACE date.
    case grace(outdated: Bool, lastSuccessAt: Date?, until: Date)
    /// `app.outdated` (not shown with `grace(outdated: true)`, which says it already).
    case appOutdated
    /// `clock.skew`: this Mac's clock is off from the server's by `seconds`.
    case clockSkew(seconds: TimeInterval)
    /// `period.ending` / `period.ending.member`: the period ends soon. `final`: within a day — the
    /// last warning (the owner asked for a week and a day before, 1 November).
    case periodEnding(owner: Bool, endsAt: Date, final: Bool)
    /// `trial.started`: until the person closes it.
    case trialStarted(until: Date)

    /// Its place in the contract's order (§8.5): 1 is the most important.
    public var rank: Int {
        switch self {
        case .deviceRevoked: return 1
        case .machineMismatch: return 2
        case .notSignedIn: return 3
        case .accountDisabled: return 4
        case .periodEnded: return 5
        case .noLicense: return 6
        case .grace: return 7
        case .appOutdated: return 8
        case .clockSkew: return 9
        case .periodEnding: return 10
        case .trialStarted: return 11
        }
    }
}

/// Why this Mac is signed out, when the server said so (§9.4): kept until the next sign-in, so that
/// its banner says why rather than only "sign in".
public enum SignedOutReason: String, Codable, Equatable, Sendable {
    case deviceRevoked = "device_revoked"
    case machineMismatch = "machine_mismatch"
}

public enum LicenseBanners {
    /// How long before the period's end the warnings start: a week, and the last one a day before
    /// (the owner, 1 November: "за неделю и за день" — above all for accounts without an email,
    /// whom no letter can reach).
    public static let periodEndingWarning: TimeInterval = 7 * 86_400
    public static let periodEndingFinalWarning: TimeInterval = 86_400

    public struct Input: Equatable, Sendable {
        public var mode: LicenseMode
        /// The stored document, checked; nil when there is none or it did not pass.
        public var entitlement: Entitlement?
        public var signedOutReason: SignedOutReason?
        public var appOutdated: Bool
        public var lastSuccessAt: Date?
        /// The clock's difference found at the last contact with the server, when over ten minutes.
        public var clockSkew: TimeInterval?
        /// The trial's banner was closed (for this license).
        public var trialNoticeClosed: Bool
        public var now: Date

        public init(mode: LicenseMode, entitlement: Entitlement?, signedOutReason: SignedOutReason? = nil, appOutdated: Bool = false,
                    lastSuccessAt: Date? = nil, clockSkew: TimeInterval? = nil, trialNoticeClosed: Bool = false, now: Date) {
            self.mode = mode
            self.entitlement = entitlement
            self.signedOutReason = signedOutReason
            self.appOutdated = appOutdated
            self.lastSuccessAt = lastSuccessAt
            self.clockSkew = clockSkew
            self.trialNoticeClosed = trialNoticeClosed
            self.now = now
        }
    }

    /// Every banner whose condition holds, most important first (§8.5).
    public static func banners(_ input: Input) -> [LicenseBanner] {
        var banners: [LicenseBanner] = []
        let p = input.entitlement
        switch input.mode {
        case .notSignedIn:
            // A revocation or a moved Mac is the reason: then "sign in" is not said again.
            switch input.signedOutReason {
            case .deviceRevoked?: banners.append(.deviceRevoked)
            case .machineMismatch?: banners.append(.machineMismatch)
            case nil: banners.append(.notSignedIn)
            }
        case .exportOnly:
            if let p, let reason = exportReason(p, at: input.now) {
                switch reason {
                case "account_disabled": banners.append(.accountDisabled)
                case "no_license": banners.append(.noLicense)
                default: banners.append(.periodEnded(owner: p.isOwner, endedAt: p.periodEndsAt))
                }
            }
        case .grace:
            if let p {
                banners.append(.grace(outdated: input.appOutdated, lastSuccessAt: input.lastSuccessAt, until: LicenseDecision.graceDate(p)))
            }
        case .full:
            break
        }
        if input.appOutdated && !(input.mode == .grace) && input.mode != .notSignedIn {
            banners.append(.appOutdated)
        }
        if let skew = input.clockSkew, input.mode != .notSignedIn {
            banners.append(.clockSkew(seconds: skew))
        }
        if input.mode.allowsWork, let p, let end = p.periodEndsAt {
            let left = end.timeIntervalSince(input.now)
            if left > 0 && left < periodEndingWarning {
                banners.append(.periodEnding(owner: p.isOwner, endsAt: end, final: left < periodEndingFinalWarning))
            }
        }
        if input.mode.allowsWork, let p, p.plan == "trial", !input.trialNoticeClosed, let end = p.periodEndsAt, end > input.now {
            banners.append(.trialStarted(until: end))
        }
        return banners.sorted { $0.rank < $1.rank }
    }

    /// Why a document leaves only export (§8.2, §13): its own reason when it says export-only; a
    /// period that ended by this Mac's time while the document still said active; no period at all.
    /// Nil when the document lets this Mac work — export-only then comes from the time without the
    /// server (after the GRACE date), which no banner of the contract names.
    public static func exportReason(_ p: Entitlement, at t: Date) -> String? {
        if p.status == .exportOnly { return p.exportReason ?? "period_ended" }
        guard let end = p.periodEndsAt else { return "no_license" }
        if t >= end { return "period_ended" }
        return nil
    }
}
